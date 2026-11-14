import AppKit
import Combine

/// Intentionally AppKit, like Local Service. This app only displays helper grant
/// state and sends controls; it never imports AX, ScreenCaptureKit, or TCC APIs.
///
/// Every permission and file appears once, with its state and the button that
/// fixes it; the menu bar item summarizes the same problems.
@MainActor
final class ComputerUseViewController: NSViewController {
    private let controller: ComputerUseController
    private var subscriptions: Set<AnyCancellable> = []
    private let enable = NSButton(checkboxWithTitle: "Let agents use apps on this Mac", target: nil, action: nil)
    private let headline = NSTextField(labelWithString: "")
    private let permissions = NSStackView()
    private let permissionRows = NSStackView()
    private let files = NSStackView()
    private let fileRows = NSStackView()
    private let error = NSTextField(wrappingLabelWithString: "")
    private let pause = NSButton(title: "Pause Computer Use", target: nil, action: nil)
    private lazy var pauseRow = row([pause, note("Esc stops a running agent.")])
    private let approvals = NSStackView()
    private let content = NSStackView()
    private var renderedPermissions: [String: Bool]?
    private var renderedFiles: ComputerUseSetup??
    private var renderedApprovals: [ComputerUseApprovedApp]?

    /// Why a missing permission matters; required ones just say so.
    static let permissionNotes = [
        "Accessibility": "Required",
        "Screen Recording": "Required",
        "Event Posting": "Needed to click and type",
        "Input Monitoring": "Needed to step back when you take over",
    ]

    init(controller: ComputerUseController) {
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 420))
        headline.font = .systemFont(ofSize: 19, weight: .semibold)
        enable.target = self
        enable.action = #selector(toggleEnabled)
        pause.target = self
        pause.action = #selector(togglePause)
        error.textColor = .systemRed
        for (section, rows, title) in [(permissions, permissionRows, "Permissions"), (files, fileRows, "Setup")] {
            rows.orientation = .vertical
            rows.alignment = .leading
            rows.spacing = 8
            section.orientation = .vertical
            section.alignment = .leading
            section.spacing = 10
            section.addArrangedSubview(sectionTitle(title))
            section.addArrangedSubview(rows)
            rows.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        }
        approvals.orientation = .vertical
        approvals.alignment = .leading
        approvals.spacing = 8
        let stack = content
        [headline, enable, error, separator(), permissions, files, separator(), approvals, pauseRow].forEach {
            stack.addArrangedSubview($0)
        }
        stack.setCustomSpacing(8, after: headline)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -24),
            error.widthAnchor.constraint(equalTo: stack.widthAnchor),
            permissions.widthAnchor.constraint(equalTo: stack.widthAnchor),
            files.widthAnchor.constraint(equalTo: stack.widthAnchor),
            approvals.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        controller.objectWillChange.sink { [weak self] in
            // Published sends before the value changes; render on the next turn.
            DispatchQueue.main.async { self?.render() }
        }.store(in: &subscriptions)
        render()
    }
    private func render() {
        headline.stringValue = controller.enabled ? "Computer Use · \(controller.statusTitle)" : "Computer Use is off"
        enable.state = controller.enabled ? .on : .off
        error.stringValue = controller.error ?? ""
        error.isHidden = controller.error == nil
        pause.title = controller.status.paused ? "Resume Computer Use" : "Pause Computer Use"
        pauseRow.isHidden = !controller.enabled
        // Grants come from the running helper; there is nothing to show while it is off.
        permissions.isHidden = !controller.enabled
        files.isHidden = !controller.enabled
        if renderedPermissions != controller.status.grants {
            renderedPermissions = controller.status.grants
            renderPermissions()
        }
        if renderedFiles != .some(controller.setup) {
            renderedFiles = .some(controller.setup)
            renderFiles()
        }
        if renderedApprovals != controller.alwaysAllowed {
            renderedApprovals = controller.alwaysAllowed
            renderApprovals()
        }
        fitWindowToContent()
    }
    private func renderPermissions() {
        clear(permissionRows)
        let grants = renderedPermissions ?? [:]
        if grants.isEmpty {
            permissionRows.addArrangedSubview(note("Checking…"))
            return
        }
        for name in grants.keys.sorted() {
            let allowed = grants[name] == true
            let allow = allowed ? nil : button("Allow…", #selector(allowGrant(_:)), id: name)
            allow?.setAccessibilityLabel("Allow \(name)…")
            add(statusRow(ok: allowed, name: name, detail: allowed ? nil : Self.permissionNotes[name], fix: allow),
                to: permissionRows)
        }
    }
    private func renderFiles() {
        clear(fileRows)
        guard let setup = renderedFiles ?? nil else {
            fileRows.addArrangedSubview(note("Checking…"))
            return
        }
        add(statusRow(ok: setup.commandInstalled, name: "Command-line tool",
                      detail: setup.commandInstalled ? nil : "Not installed",
                      fix: setup.commandInstalled ? nil : button("Install", #selector(installCommand), id: "command")),
            to: fileRows)
        let skill: (String?, String?) = switch setup.skill {
        case .installed: (nil, nil)
        case .outdated: ("Out of date", "Update")
        case .missing: ("Not installed", "Install")
        }
        add(statusRow(ok: setup.skill == .installed, name: "computer-use skill", detail: skill.0,
                      fix: skill.1.map { button($0, #selector(installSkill), id: "skill") }),
            to: fileRows)
    }
    private func renderApprovals() {
        clear(approvals)
        approvals.addArrangedSubview(sectionTitle("Always allowed apps"))
        if controller.alwaysAllowed.isEmpty {
            let none = note("None yet.")
            approvals.addArrangedSubview(none)
            none.widthAnchor.constraint(equalTo: approvals.widthAnchor).isActive = true
            return
        }
        for app in controller.alwaysAllowed {
            let label = NSTextField(labelWithString: app.name)
            label.toolTip = app.bundleID
            let remove = button("Remove", #selector(forgetApproval(_:)), id: app.bundleID)
            remove.setAccessibilityLabel("Remove \(app.name)")
            approvals.addArrangedSubview(row([label, remove]))
        }
    }
    /// Icon, name, why it matters, and the fix, aligned in columns.
    private func statusRow(ok: Bool, name: String, detail: String?, fix: NSButton?) -> NSStackView {
        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
            accessibilityDescription: ok ? "OK" : "Needs attention")
        icon.contentTintColor = ok ? .systemGreen : .systemOrange
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let label = NSTextField(labelWithString: name)
        label.widthAnchor.constraint(equalToConstant: 140).isActive = true
        let reason = NSTextField(labelWithString: detail ?? "")
        reason.textColor = .secondaryLabelColor
        reason.lineBreakMode = .byTruncatingTail
        reason.setContentHuggingPriority(.defaultLow, for: .horizontal)
        reason.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [icon, label, reason]
        if let fix {
            fix.setContentHuggingPriority(.required, for: .horizontal)
            fix.setContentCompressionResistancePriority(.required, for: .horizontal)
            views.append(fix)
        }
        let line = row(views)
        line.spacing = 8
        line.distribution = .fill
        return line
    }
    private func add(_ line: NSStackView, to rows: NSStackView) {
        rows.addArrangedSubview(line)
        line.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
    }
    private func clear(_ stack: NSStackView) {
        for child in stack.arrangedSubviews {
            stack.removeArrangedSubview(child)
            child.removeFromSuperview()
        }
    }
    func fitWindowToContent() {
        guard isViewLoaded, let window = view.window else { return }
        view.layoutSubtreeIfNeeded()
        let height = max(320, ceil(content.fittingSize.height) + 48)
        let current = window.frame
        let rect = window.contentRect(forFrameRect: current)
        var frame = window.frameRect(
            forContentRect: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: height))
        frame.origin.y = current.maxY - frame.height
        if abs(current.height - frame.height) > 1 { window.setFrame(frame, display: true) }
    }
    private func button(_ title: String, _ action: Selector, id: String? = nil) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        if let id { button.identifier = NSUserInterfaceItemIdentifier(id) }
        return button
    }
    private func row(_ children: [NSView]) -> NSStackView {
        let row = NSStackView(views: children)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        return row
    }
    private func sectionTitle(_ text: String) -> NSTextField {
        let title = NSTextField(labelWithString: text)
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        return title
    }
    private func note(_ text: String) -> NSTextField {
        let note = NSTextField(wrappingLabelWithString: text)
        note.textColor = .secondaryLabelColor
        return note
    }
    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        return line
    }
    @objc private func toggleEnabled() { controller.setEnabled(enable.state == .on) }
    @objc private func togglePause() { controller.togglePause() }
    @objc private func installCommand() { controller.installCommand() }
    @objc private func installSkill() { controller.installSkill() }
    @objc private func forgetApproval(_ sender: NSButton) {
        if let bundleID = sender.identifier?.rawValue { controller.forgetApproval(bundleID) }
    }
    @objc private func allowGrant(_ sender: NSButton) {
        if let grant = sender.identifier?.rawValue { controller.send("allow", grant: grant) }
    }
}
