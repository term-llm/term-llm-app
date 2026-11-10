import AppKit
import Combine

/// Intentionally AppKit, like Local Service. This app only displays helper grant
/// state and sends controls; it never imports AX, ScreenCaptureKit, or TCC APIs.
@MainActor
final class ComputerUseViewController: NSViewController {
    private let controller: ComputerUseController
    private var subscriptions: Set<AnyCancellable> = []
    private let enable = NSButton(checkboxWithTitle: "Enable Computer Use for term-llm", target: nil, action: nil)
    private let headline = NSTextField(labelWithString: "")
    private let grants = NSStackView()
    private let command = NSTextField(labelWithString: "")
    private let skill = NSTextField(labelWithString: "")
    private let error = NSTextField(wrappingLabelWithString: "")
    private let pause = NSButton(title: "Pause Computer Use", target: nil, action: nil)
    private let approvals = NSStackView()
    private let content = NSStackView()
    private var renderedGrants: [String: Bool]?
    private var renderedApprovals: [ComputerUseApprovedApp]?

    init(controller: ComputerUseController) {
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 420))
        headline.font = .systemFont(ofSize: 19, weight: .semibold)
        let explanation = NSTextField(
            wrappingLabelWithString:
                "Let term-llm agents read and operate apps on this Mac. Only the separate term-llm Computer Use helper holds the permissions. An agent asks before it first uses each app. While one works, press Esc or choose Stop in the menu to stop it."
        )
        explanation.textColor = .secondaryLabelColor
        enable.target = self
        enable.action = #selector(toggleEnabled)
        pause.target = self
        pause.action = #selector(togglePause)
        grants.orientation = .vertical
        grants.alignment = .leading
        grants.spacing = 10
        approvals.orientation = .vertical
        approvals.alignment = .leading
        approvals.spacing = 8
        let commandRow = row([command, button("Install / Repair…", #selector(installCommand))])
        let skillRow = row([skill, button("Install Skill", #selector(installSkill))])
        error.textColor = .systemRed
        let stack = content
        [headline, explanation, enable, separator(), grants, separator(), approvals, separator(), commandRow, skillRow, pause, error].forEach {
            stack.addArrangedSubview($0)
        }
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
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor),
            error.widthAnchor.constraint(equalTo: stack.widthAnchor),
            grants.widthAnchor.constraint(equalTo: stack.widthAnchor),
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
        command.stringValue =
            controller.commandInstalled ? "Command-line tool · Installed" : "Command-line tool · Not installed"
        skill.stringValue = controller.skillInstalled ? "term-llm skill · Installed" : "term-llm skill · Not installed"
        error.stringValue = controller.error ?? ""
        error.isHidden = controller.error == nil
        pause.title = controller.status.paused ? "Resume Computer Use" : "Pause Computer Use"
        pause.isHidden = !controller.enabled
        if renderedGrants != controller.status.grants {
            renderedGrants = controller.status.grants
            for child in grants.arrangedSubviews {
                grants.removeArrangedSubview(child)
                child.removeFromSuperview()
            }
            if controller.status.grants.isEmpty {
                let note = NSTextField(
                    wrappingLabelWithString: "Grants will appear when the helper's permissions module is available.")
                note.textColor = .secondaryLabelColor
                grants.addArrangedSubview(note)
            }
            for name in controller.status.grants.keys.sorted() {
                let allowed = controller.status.grants[name] == true
                let label = NSTextField(labelWithString: "\(name) · \(allowed ? "Allowed" : "Not allowed")")
                let allow = button("Allow…", #selector(allowGrant(_:)))
                allow.identifier = NSUserInterfaceItemIdentifier(name)
                allow.isHidden = allowed
                grants.addArrangedSubview(row([label, allow]))
            }
        }
        if renderedApprovals != controller.alwaysAllowed {
            renderedApprovals = controller.alwaysAllowed
            renderApprovals()
        }
        fitWindowToContent()
    }
    private func renderApprovals() {
        for child in approvals.arrangedSubviews {
            approvals.removeArrangedSubview(child)
            child.removeFromSuperview()
        }
        let title = NSTextField(labelWithString: "Always allowed apps")
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        approvals.addArrangedSubview(title)
        if controller.alwaysAllowed.isEmpty {
            let note = NSTextField(
                wrappingLabelWithString: "None. Apps you choose Always Allow for appear here; remove one to be asked again.")
            note.textColor = .secondaryLabelColor
            approvals.addArrangedSubview(note)
            note.widthAnchor.constraint(equalTo: approvals.widthAnchor).isActive = true
            return
        }
        for app in controller.alwaysAllowed {
            let label = NSTextField(labelWithString: app.name)
            label.toolTip = app.bundleID
            let remove = button("Remove", #selector(forgetApproval(_:)))
            remove.identifier = NSUserInterfaceItemIdentifier(app.bundleID)
            remove.setAccessibilityLabel("Remove \(app.name)")
            approvals.addArrangedSubview(row([label, remove]))
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
    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }
    private func row(_ children: [NSView]) -> NSStackView {
        let row = NSStackView(views: children)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        return row
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
