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
    private lazy var installSkillButton = button("Install Skill", #selector(installSkill))
    private let approvals = NSStackView()
    private let issues = NoticePanel()
    private let issueRows = NSStackView()
    private let content = NSStackView()
    private var renderedGrants: [String: Bool]?
    private var renderedApprovals: [ComputerUseApprovedApp]?
    private var renderedIssues: [ComputerUseIssue]?

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
        let skillRow = row([skill, installSkillButton])
        error.textColor = .systemRed
        issueRows.orientation = .vertical
        issueRows.alignment = .leading
        issueRows.spacing = 10
        issueRows.translatesAutoresizingMaskIntoConstraints = false
        issues.addSubview(issueRows)
        let stack = content
        // What needs fixing, and why the last fix failed, come before everything else.
        [headline, issues, error, explanation, enable, separator(), grants, separator(), approvals, separator(), commandRow, skillRow, pause].forEach {
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
            issues.widthAnchor.constraint(equalTo: stack.widthAnchor),
            issueRows.leadingAnchor.constraint(equalTo: issues.leadingAnchor, constant: 12),
            issueRows.trailingAnchor.constraint(equalTo: issues.trailingAnchor, constant: -12),
            issueRows.topAnchor.constraint(equalTo: issues.topAnchor, constant: 10),
            issueRows.bottomAnchor.constraint(equalTo: issues.bottomAnchor, constant: -10),
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
        let setup = controller.setup
        command.stringValue =
            "Command-line tool · " + (setup.map { $0.commandInstalled ? "Installed" : "Not installed" } ?? "Checking…")
        let skillState: String? = switch setup?.skill {
        case .installed: "Installed"
        case .outdated: "Out of date"
        case .missing: "Not installed"
        case nil: nil
        }
        skill.stringValue = "computer-use skill · " + (skillState ?? "Checking…")
        installSkillButton.title = setup?.skill == .outdated ? "Update Skill" : "Install Skill"
        if renderedIssues != controller.issues {
            renderedIssues = controller.issues
            renderIssues()
        }
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
    private func renderIssues() {
        for child in issueRows.arrangedSubviews {
            issueRows.removeArrangedSubview(child)
            child.removeFromSuperview()
        }
        let list = renderedIssues ?? []
        issues.isHidden = list.isEmpty
        for (index, issue) in list.enumerated() {
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
            icon.contentTintColor = .systemOrange
            icon.setContentHuggingPriority(.required, for: .horizontal)
            let label = NSTextField(wrappingLabelWithString: issue.detail)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let fix = button(issue.action, #selector(fixIssue(_:)))
            fix.tag = index
            if case .grant(let name) = issue { fix.setAccessibilityLabel("Allow \(name)…") }
            fix.setContentHuggingPriority(.required, for: .horizontal)
            fix.setContentCompressionResistancePriority(.required, for: .horizontal)
            let line = row([icon, label, fix])
            line.spacing = 10
            line.distribution = .fill
            issueRows.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: issueRows.widthAnchor).isActive = true
        }
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
    @objc private func fixIssue(_ sender: NSButton) {
        if let list = renderedIssues, list.indices.contains(sender.tag) { controller.fix(list[sender.tag]) }
    }
    @objc private func forgetApproval(_ sender: NSButton) {
        if let bundleID = sender.identifier?.rawValue { controller.forgetApproval(bundleID) }
    }
    @objc private func allowGrant(_ sender: NSButton) {
        if let grant = sender.identifier?.rawValue { controller.send("allow", grant: grant) }
    }
}
