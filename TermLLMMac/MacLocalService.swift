import AppKit
import Combine
@preconcurrency import TermLLMMacKit

/// The optional local term-llm service, managed from the native Mac app.
///
/// Owns the app-wide menu-bar item (present from launch, with or without a
/// local service) and the Local Service settings window. It never installs
/// anything, starts a service or changes login items until the user asks.
/// Closing Local Service stops its status polling, not the service. Quitting
/// the app does not stop or reconfigure the independently owned service.
///
/// A verified local service is handed to the client through `onConnection`
/// only after the managed loopback endpoint and its bearer credential pass
/// LocalSessionProbe. The client revalidates it and imports it into its own
/// isolated connection/credential store; there is no second Chat UI.
@MainActor
final class MacLocalServiceController: NSObject, NSWindowDelegate, NSMenuDelegate {
    /// (base URL, bearer credential, open Chat). `open: false` only adds This Mac.
    var onConnection: ((URL, String, Bool) -> Void)?

    private var localServiceWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var applicationStarted = false
    private var localServicesEnabled = false
    private var automaticTerminationDisabled = false
    private static let lifetimeReason = "term-llm menu-bar app is running"

    // Remote-only installs stay lazy. Existing managed installs initialize the
    // model at launch for background CLI updates. Chat stays in the client.
    private lazy var model: CompanionModel = {
        let model = CompanionModel()
        model.openLocalChatHandler = { [weak self] endpoint, token in
            guard let self else { return }
            guard let onConnection = self.onConnection else {
                let alert = NSAlert()
                alert.messageText = "Chat is unavailable"
                alert.informativeText = "The app has not connected its Chat workspace to local service setup. Close and reopen Local Service from the app."
                alert.addButton(withTitle: "OK")
                if let window = self.localServiceWindow {
                    alert.beginSheetModal(for: window)
                }
                return
            }
            onConnection(endpoint.baseURL, token, true)
            self.openTermLLM()
        }
        // A verified local service joins the app's connections as This Mac on
        // its own; the client decides whether that's still wanted.
        model.connectLocalServiceHandler = { [weak self] endpoint, token in
            self?.onConnection?(endpoint.baseURL, token, false)
        }
        return model
    }()

    func startApplication() {
        guard !applicationStarted else { return }
        applicationStarted = true
        createStatusItemIfNeeded()
        ProcessInfo.processInfo.disableAutomaticTermination(Self.lifetimeReason)
        automaticTerminationDisabled = true
        NotificationCenter.default.addObserver(self, selector: #selector(willTerminate),
                                               name: NSApplication.willTerminateNotification, object: nil)
        // An older build wrote a launch agent for Open at Login, which System
        // Settings lists as a background item; move it to Open at Login.
        if let executable = Bundle.main.executableURL, let system = AppLoginItem.systemService {
            Task.detached(priority: .utility) {
                AppLoginItem(mainApp: system).refreshIfNeeded(appExecutable: executable)
            }
        }
        let provisioner = CLIProvisioner()
        // Earlier builds kept these files in ~/Library/Application Support/TermLLM.
        _ = try? provisioner.migrateLegacySupportDirectory()
        let developerMode = FileManager.default.fileExists(atPath: DeveloperModeStore(provisioner: provisioner).url.path)
        let managed = FileManager.default.fileExists(atPath: provisioner.manifestURL.path)
        if managed || developerMode {
            model.startBackgroundConnect()
        }
        if managed && !developerMode {
            model.startUpdateSchedule()
            let manager = MigrationManager(provisioner: provisioner)
            Task { [weak self] in
                let journal = try? await Task.detached(priority: .utility) { try manager.loadJournal() }.value
                guard let self, let journal, !journal.complete && !journal.rolledBack else { return }
                self.offerMigrationRecovery(journal)
            }
        }
    }

    private func offerMigrationRecovery(_ journal: MigrationJournal) {
        showLocalService()
        guard let window = localServiceWindow else { return }
        let alert = NSAlert()
        alert.messageText = "Switching to the app's copy didn't finish"
        alert.informativeText = "term-llm updates are paused until this is sorted out. Finish the switch, or undo it to put things back the way they were."
        alert.addButton(withTitle: "Finish Switching")
        alert.addButton(withTitle: "Undo Switch")
        alert.addButton(withTitle: "Later")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.model.migrate() }
            else if response == .alertSecondButtonReturn { self?.model.migrate(rollback: true) }
        }
    }

    @objc private func willTerminate() {
        if automaticTerminationDisabled {
            ProcessInfo.processInfo.enableAutomaticTermination(Self.lifetimeReason)
            automaticTerminationDisabled = false
        }
    }

    @objc func showLocalService() {
        startApplication()
        localServicesEnabled = true
        model.refreshLoginItemPathIfNeeded()
        if localServiceWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 320),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Local Service"
            window.contentMinSize = NSSize(width: 440, height: 160)
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            window.delegate = self
            let controller = LocalServiceViewController(model: model)
            window.contentViewController = controller
            controller.fitWindowToContent()
            window.center()
            localServiceWindow = window
        }
        createStatusItemIfNeeded()
        model.startPolling()
        localServiceWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        model.stopPolling()
    }

    func menuWillOpen(_ menu: NSMenu) {
        if localServicesEnabled { model.startPolling() }
    }

    func menuDidClose(_ menu: NSMenu) {
        if localServicesEnabled && localServiceWindow?.isVisible != true { model.stopPolling() }
    }

    private func createStatusItemIfNeeded() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "term-llm")
        item.button?.toolTip = "term-llm"
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        addItem("Open term-llm", action: #selector(openTermLLM), to: menu,
                enabled: MacClientWindow.shared.window != nil)
        addItem("Local Service…", action: #selector(showLocalService), to: menu)
        if localServicesEnabled {
            menu.addItem(.separator())
            let status = NSMenuItem(title: "Local service: \(model.statusTitle)", action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
            addItem("Open Local Chat", action: #selector(openLocalChat), to: menu,
                    enabled: !model.busy && model.status?.state == .ready && onConnection != nil)
            let canControl = !model.busy && model.canControlService
            addItem(model.status?.running == true ? "Stop Service" : "Start Service",
                    action: #selector(toggleService), to: menu, enabled: canControl)
            addItem("Restart Service", action: #selector(restartService), to: menu,
                    enabled: canControl && model.status?.running == true)
        }
        menu.addItem(.separator())
        addItem("Quit term-llm", action: #selector(quitTermLLM), to: menu)
    }

    private func addItem(_ title: String, action: Selector, to menu: NSMenu, enabled: Bool = true) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        menu.addItem(item)
    }

    @objc func openTermLLM() {
        MacClientWindow.shared.show()
    }

    @objc func quitTermLLM() {
        // App termination is distinct from closing/hiding a window. Do not stop
        // the independently owned local service or rewrite its login preference.
        NSApp?.terminate(nil)
    }

    @objc private func openLocalChat() {
        model.openChat { [weak self] message in self?.showChatFailure(message) }
    }

    /// The menu has nowhere to show an error, so say why Chat didn't open.
    private func showChatFailure(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn't open local chat"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Local Service…")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn { showLocalService() }
    }
    @objc private func toggleService() {
        if model.status?.running == true { model.stopService() } else { model.startService() }
    }
    @objc private func restartService() { model.restartService() }
}

/// AppKit service management.
///
/// The default view stays small: a headline, one next step, at most one notice
/// and the two login preferences. Paths, versions, conflicts and every other
/// control are under Advanced.
@MainActor
final class LocalServiceViewController: NSViewController {
    private let model: CompanionModel
    private var observation: AnyCancellable?
    private var refreshScheduled = false
    private var summary: LocalServiceSummary?
    private var showsAdvanced = false
    private var fittedHeight: CGFloat = 0

    private let content = FlippedStackView()

    // Simple view
    private let statusIcon = NSImageView()
    private let spinner = NSProgressIndicator()
    private let headline = NSTextField(wrappingLabelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private lazy var primaryButton = button("", #selector(performPrimary))
    private lazy var secondaryButton = button("", #selector(performSecondary))
    private lazy var actionRow = row([primaryButton, secondaryButton])
    private let primaryNote = NSTextField(wrappingLabelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let noticePanel = NoticePanel()
    private let noticeIcon = NSImageView()
    private let noticeLabel = NSTextField(wrappingLabelWithString: "")
    private let noticeFootnote = NSTextField(wrappingLabelWithString: "")
    private lazy var noticeButton = button("", #selector(performNotice))
    private lazy var autostartButton = NSButton(checkboxWithTitle: "Start the local service when you log in",
                                                target: self, action: #selector(setAutostart(_:)))
    private lazy var loginItemButton = NSButton(checkboxWithTitle: "Open term-llm when you log in",
                                                target: self, action: #selector(setLoginItem(_:)))
    private let loginApprovalNote = NSTextField(wrappingLabelWithString: "Allow term-llm in System Settings › General › Login Items to finish.")
    private lazy var disclosure: NSButton = {
        let button = NSButton(title: "Advanced", image: Self.chevron(expanded: false), target: self,
                              action: #selector(toggleAdvanced))
        button.isBordered = false
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        return button
    }()

    // Advanced
    private let advanced = NSStackView()
    private var infoRows: [String: (row: NSView, value: NSTextField)] = [:]
    private lazy var checkButton = button("Check for Updates", #selector(checkUpdates))
    private lazy var repairButton = button("Repair", #selector(repairCLI))
    private lazy var developerButton = button("Developer Mode…", #selector(developerMode))
    private lazy var stopManagingButton = button("Stop Managing…", #selector(stopManaging))
    private lazy var removeButton = button("Remove…", #selector(removeCLI))
    private lazy var cliRows = [row([checkButton, repairButton]), row([developerButton, stopManagingButton, removeButton])]
    private let conflictList = NSTextField(wrappingLabelWithString: "")
    private let conflictNote = NSTextField(wrappingLabelWithString: "")
    private lazy var migrateButton = button("Switch to the App's Copy…", #selector(migrateCLI))
    private lazy var rollbackButton = button("Undo Switch…", #selector(rollbackMigration))
    private lazy var brewButton = button("Remove Homebrew's Copy…", #selector(removeBrew))
    private lazy var conflictButtons = row([migrateButton, rollbackButton, brewButton])
    private lazy var restartButton = button("Restart", #selector(restartService))
    private lazy var reinstallButton = button("Reinstall Service", #selector(installService))
    private lazy var serviceButtons = row([restartButton, reinstallButton])
    private lazy var copyButton = button("Copy Diagnostics", #selector(copyDiagnostics))
    private var conflictSection = NSView()
    private var serviceSection = NSView()

    init(model: CompanionModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 320))
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 18
        content.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 20, right: 24)
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = content
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        loginApprovalNote.textColor = .secondaryLabelColor
        loginApprovalNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        for view in [makeSummary(), makeNotice(), column([autostartButton, loginItemButton, loginApprovalNote], spacing: 8),
                     separator(), disclosure, makeAdvanced()] {
            add(view, to: content)
        }
        content.setCustomSpacing(10, after: disclosure)
        advanced.isHidden = true

        // @Published emits before storage changes. Coalesce and render on the
        // next main tick so every control sees the completed model mutation.
        observation = model.objectWillChange.sink { [weak self] _ in
            self?.scheduleRefresh()
        }
        updateControls()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        fitWindowToContent()
    }

    // MARK: - Layout

    private func makeSummary() -> NSView {
        spinner.style = .spinning
        spinner.isDisplayedWhenStopped = false
        let icon = NSView()
        for child in [statusIcon, spinner] {
            child.translatesAutoresizingMaskIntoConstraints = false
            icon.addSubview(child)
            NSLayoutConstraint.activate([
                child.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
                child.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            ])
        }
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32),
        ])

        headline.font = .systemFont(ofSize: 17, weight: .semibold)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.isSelectable = true
        primaryButton.keyEquivalent = "\r"
        primaryNote.textColor = .secondaryLabelColor
        primaryNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        errorLabel.textColor = .systemRed
        errorLabel.isSelectable = true
        let text = column([headline, detailLabel, actionRow, primaryNote, errorLabel], spacing: 4)
        text.setCustomSpacing(12, after: detailLabel)
        text.setCustomSpacing(8, after: actionRow)
        text.setCustomSpacing(8, after: primaryNote)

        let summary = NSStackView(views: [icon, text])
        summary.orientation = .horizontal
        summary.alignment = .top
        summary.distribution = .fill
        summary.spacing = 14
        return summary
    }

    private func makeNotice() -> NSView {
        noticeLabel.isSelectable = true
        noticeFootnote.textColor = .secondaryLabelColor
        noticeFootnote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        noticeIcon.setContentHuggingPriority(.required, for: .horizontal)
        noticeButton.setContentHuggingPriority(.required, for: .horizontal)
        noticeButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        let text = column([noticeLabel, noticeFootnote], spacing: 2)
        let stack = NSStackView(views: [noticeIcon, text, noticeButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        noticePanel.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: noticePanel.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: noticePanel.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: noticePanel.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: noticePanel.bottomAnchor, constant: -10),
        ])
        return noticePanel
    }

    private func makeAdvanced() -> NSView {
        advanced.orientation = .vertical
        advanced.alignment = .leading
        advanced.spacing = 20

        conflictList.isSelectable = true
        conflictNote.textColor = .secondaryLabelColor
        conflictNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let cli = section("term-llm", [
            infoRow("cli.version", "Version"), infoRow("cli.location", "Location"),
            infoRow("cli.terminal", "Terminal"), infoRow("cli.updates", "Updates"),
            infoRow("cli.problem", "Problem"),
        ] + cliRows)
        conflictSection = section("Other copies of term-llm", [conflictList, conflictNote, conflictButtons])
        serviceSection = section("Local service", [
            infoRow("svc.status", "Status"), infoRow("svc.address", "Address"),
            infoRow("svc.signin", "Sign-in"), infoRow("svc.program", "Program"),
            infoRow("svc.chat", "Chat"), infoRow("svc.logs", "Logs"), infoRow("svc.problem", "Problem"),
            serviceButtons,
        ])
        for view in [cli, conflictSection, serviceSection, row([copyButton])] {
            add(view, to: advanced)
        }
        return advanced
    }

    private func section(_ title: String, _ views: [NSView]) -> NSStackView {
        let header = NSTextField(labelWithString: title)
        header.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let stack = column([header] + views, spacing: 5)
        stack.setCustomSpacing(8, after: header)
        return stack
    }

    private func infoRow(_ id: String, _ key: String) -> NSView {
        let keyLabel = NSTextField(labelWithString: key)
        keyLabel.textColor = .secondaryLabelColor
        keyLabel.translatesAutoresizingMaskIntoConstraints = false
        keyLabel.widthAnchor.constraint(equalToConstant: 72).isActive = true
        let value = NSTextField(wrappingLabelWithString: "")
        value.isSelectable = true
        value.setContentHuggingPriority(.defaultLow, for: .horizontal)
        value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [keyLabel, value])
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.distribution = .fill
        stack.spacing = 12
        infoRows[id] = (stack, value)
        return stack
    }

    private func column(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        views.forEach { add($0, to: stack) }
        return stack
    }

    /// NSStackView has no fill alignment: stretch text and rows to the stack's
    /// width so labels wrap, but leave buttons at their natural size.
    private func add(_ view: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(view)
        guard !(view is NSButton) else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                    constant: -(stack.edgeInsets.left + stack.edgeInsets.right)).isActive = true
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func separator() -> NSView {
        let separator = NSBox()
        separator.boxType = .separator
        return separator
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    /// Sizes the window to its content, keeping the top edge in place.
    func fitWindowToContent(animated: Bool = false) {
        guard let window = view.window else { return }
        view.layoutSubtreeIfNeeded()
        let wanted = ceil(content.frame.height)
        guard abs(wanted - fittedHeight) >= 1 else { return }
        fittedHeight = wanted
        let available = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        let current = window.frame
        let contentRect = window.contentRect(forFrameRect: current)
        var frame = window.frameRect(forContentRect: NSRect(x: contentRect.minX, y: contentRect.minY,
                                                            width: contentRect.width,
                                                            height: max(160, min(wanted, available - 80))))
        frame.origin.y = current.maxY - frame.height
        window.setFrame(frame, display: true, animate: animated && window.isVisible)
    }

    // MARK: - Rendering

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.updateControls()
        }
    }

    private func updateControls() {
        let summary = model.summary
        self.summary = summary
        render(summary)
        autostartButton.isHidden = !model.canControlService
        autostartButton.isEnabled = !model.busy
        autostartButton.state = model.status?.autostart == true ? .on : .off
        loginItemButton.isEnabled = !model.busy
        loginItemButton.state = model.loginItemEnabled ? .on : .off
        loginApprovalNote.isHidden = !model.loginItemNeedsApproval
        renderAdvanced()
        fitWindowToContent()
    }

    private func render(_ summary: LocalServiceSummary) {
        set(headline, summary.title)
        set(detailLabel, summary.detail)
        if summary.tone == .busy {
            statusIcon.isHidden = true
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
            statusIcon.isHidden = false
            let (name, color) = Self.symbol(for: summary.tone)
            statusIcon.image = NSImage(systemSymbolName: name, accessibilityDescription: summary.title)?
                .withSymbolConfiguration(.init(pointSize: 26, weight: .regular))
            statusIcon.contentTintColor = color
        }
        configure(primaryButton, summary.primary, enabled: summary.primaryEnabled)
        configure(secondaryButton, summary.secondary, enabled: !model.busy)
        actionRow.isHidden = primaryButton.isHidden && secondaryButton.isHidden
        set(primaryNote, summary.primaryNote)
        set(errorLabel, model.actionError)

        guard let notice = summary.notice else {
            noticePanel.isHidden = true
            return
        }
        noticePanel.isHidden = false
        set(noticeLabel, notice.text)
        set(noticeFootnote, notice.footnote)
        let info = notice.tone == .off
        noticeIcon.image = NSImage(systemSymbolName: info ? "info.circle.fill" : "exclamationmark.triangle.fill",
                                   accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        noticeIcon.contentTintColor = info ? .secondaryLabelColor : .systemOrange
        configure(noticeButton, notice.action, enabled: notice.actionEnabled)
    }

    private func renderAdvanced() {
        let busy = model.busy
        let managed = model.isManaged
        let developer = model.developerModeEnabled

        setInfo("cli.version", versionText)
        setInfo("cli.location", locationText)
        setInfo("cli.terminal", developer ? nil : terminalText)
        setInfo("cli.updates", managed ? updatesText : nil)
        let cliProblems = [model.selectionError, model.updateState.lastError].compactMap { $0 }
            + model.cliProblems.map(\.description)
        setInfo("cli.problem", cliProblems.isEmpty ? nil : cliProblems.joined(separator: "\n"))
        checkButton.isHidden = !managed
        repairButton.isHidden = developer || !(model.selection != nil || model.selectionError != nil || model.handedOver)
        stopManagingButton.isHidden = !managed
        removeButton.isHidden = !managed
        developerButton.title = developer ? "Leave Developer Mode" : "Developer Mode…"
        developerButton.isHidden = developer && [summary?.primary, summary?.notice?.action].contains(.leaveDeveloperMode)
        for button in [checkButton, repairButton, developerButton, stopManagingButton, removeButton] {
            button.isEnabled = !busy
        }
        cliRows.forEach(hideIfEmpty)

        let incomplete = model.migrationJournal.map { !$0.complete && !$0.rolledBack } ?? false
        let switchable = incomplete || model.conflicts.contains { if case .foreignCommand = $0 { return false }; return true }
        let blocker = model.migrationBlocker
        // Don't repeat a switch, or why it must wait, that the simple view shows.
        let offered = [summary?.primary, summary?.notice?.action].contains { $0 == .migrate || $0 == .resumeMigration }
        let explained = offered || summary?.notice?.footnote != nil
        conflictSection.isHidden = developer || (model.conflicts.isEmpty && !incomplete)
        set(conflictList, model.conflicts.map { $0.displayText(tilde: tilde) }.joined(separator: "\n"))
        set(conflictNote, switchable && !explained ? blocker?.shortReason : nil)
        migrateButton.title = incomplete ? "Finish Switching…" : "Switch to the App's Copy…"
        migrateButton.isHidden = !switchable || offered || blocker != nil
        migrateButton.isEnabled = !busy
        rollbackButton.isHidden = !incomplete
        rollbackButton.isEnabled = !busy
        brewButton.isHidden = summary?.notice?.action == .removeHomebrewCopy
            || !(model.migrationJournal?.complete == true || blocker == nil)
            || !model.conflicts.contains { if case .homebrewFormula = $0 { return true }; return false }
        brewButton.isEnabled = !busy
        hideIfEmpty(conflictButtons)

        serviceSection.isHidden = model.controller == nil
        let status = model.status
        let installed = status?.installed == true
        let binary = status?.binary ?? ""
        setInfo("svc.status", status.map(statusText) ?? "Checking…")
        setInfo("svc.address", installed ? status.map(addressText) : nil)
        setInfo("svc.signin", installed ? status.map(signInText) : nil)
        setInfo("svc.program", installed && !binary.isEmpty
            ? tilde(binary) + (binary == model.managedBinaryPath ? " (the app's copy)" : "") : nil)
        setInfo("svc.chat", model.endpoint != nil && status?.state == .ready && status?.auth != "passkey" ? chatText : nil)
        setInfo("svc.logs", installed ? model.controller?.logsFollowCommand() : nil)
        let serviceProblems = [model.statusError, model.endpointError].compactMap { $0 }
        setInfo("svc.problem", serviceProblems.isEmpty ? nil : serviceProblems.joined(separator: "\n"))
        restartButton.isHidden = !(model.canControlService && status?.running == true)
        reinstallButton.isHidden = !(status.map {
            $0.installed && $0.managed && $0.auth == "bearer" && $0.state != .unmanaged
                && $0.binary == (model.developerBinary?.path ?? model.managedBinaryPath)
        } ?? false)
        restartButton.isEnabled = !busy
        reinstallButton.isEnabled = !busy
        hideIfEmpty(serviceButtons)
    }

    private var versionText: String {
        if model.developerBinary != nil { return "Developer Mode" }
        if model.developerModeEnabled { return "Developer Mode — the chosen executable is missing" }
        if model.selectionError != nil { return "Needs repair" }
        if let version = model.signatureVerifiedVersion { return "\(version) · signed and verified" }
        if model.handedOver { return "Not managed by the app" }
        return model.selection == nil ? "Not installed" : "Needs setting up again"
    }

    private var locationText: String? {
        if let binary = model.developerBinary { return tilde(binary.path) }
        if model.developerModeEnabled { return nil }
        return model.selection?.source == .release || model.handedOver ? tilde(model.managedBinaryPath) : nil
    }

    private var terminalText: String? {
        for case .pathLinkOccupied(let path, let target) in model.conflicts {
            return "\(tilde(path)) → \(tilde(target))"
        }
        switch model.pathLink {
        case .linked(let path)?, .alreadyLinked(let path)?: return tilde(path)
        case .notLinked(let path)?: return "\(tilde(path)) isn't linked"
        case .collision(let path)?: return "\(tilde(path)) runs another copy"
        case .failed(let reason)?: return "Couldn't link: \(reason)"
        case nil: return nil
        }
    }

    private var updatesText: String {
        var text = model.updateState.lastCheckedAt.map { "Checked \($0.formatted(.relative(presentation: .named)))" }
            ?? "Not checked yet"
        if !model.updateState.unconfirmedReloads.isEmpty {
            text += "\nReloaded \(model.updateState.unconfirmedReloads.joined(separator: " and ")); new version not confirmed yet"
        }
        return text
    }

    private func statusText(_ status: ServiceStatus) -> String {
        let login = status.autostart ? " · starts at login" : ""
        switch status.state {
        case .ready: return "Running" + (status.pid.map { " · pid \($0)" } ?? "") + login
        case .stopped: return "Stopped" + login
        case .notInstalled: return "Not set up"
        case .notRegistered: return "Not registered with macOS"
        case .unmanaged: return "Registered by something else"
        case .unhealthy: return "Not responding" + login
        case .error: return "Error"
        }
    }

    private func addressText(_ status: ServiceStatus) -> String {
        // Only the validated, credential-free endpoint or bare host and port;
        // never raw URL text from the CLI report.
        if let endpoint = model.endpoint { return endpoint.baseURL.absoluteString }
        return "\(status.host ?? "127.0.0.1"):\(status.port.map(String.init) ?? "?")"
    }

    private func signInText(_ status: ServiceStatus) -> String {
        switch status.auth {
        case "bearer": return "Token"
        case "passkey": return status.enrollment == .pending ? "Passkey · setup pending" : "Passkey"
        case let auth?: return auth
        case nil: return "Unknown"
        }
    }

    private var chatText: String {
        if let outcome = model.sessionOutcome { return outcome.isAuthenticated ? "Signed in" : outcome.description }
        return model.token == nil ? "Waiting for the sign-in token" : "Checking sign-in…"
    }

    private func tilde(_ path: String) -> String {
        let home = model.home.path
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    private func set(_ field: NSTextField, _ text: String?) {
        field.isHidden = (text ?? "").isEmpty
        if let text, field.stringValue != text { field.stringValue = text }
    }

    private func setInfo(_ id: String, _ text: String?) {
        guard let entry = infoRows[id] else { return }
        entry.row.isHidden = text == nil
        if let text, entry.value.stringValue != text { entry.value.stringValue = text }
    }

    private func hideIfEmpty(_ row: NSStackView) {
        row.isHidden = row.arrangedSubviews.allSatisfy(\.isHidden)
    }

    private func configure(_ button: NSButton, _ action: LocalServiceSummary.Action?, enabled: Bool) {
        button.isHidden = action == nil
        guard let action else { return }
        if button.title != action.title { button.title = action.title }
        button.isEnabled = enabled
    }

    private static func symbol(for tone: LocalServiceSummary.Tone) -> (String, NSColor) {
        switch tone {
        case .ok: return ("checkmark.circle.fill", .systemGreen)
        case .attention: return ("exclamationmark.triangle.fill", .systemOrange)
        case .problem: return ("xmark.octagon.fill", .systemRed)
        case .off, .busy: return ("circle.dashed", .secondaryLabelColor)
        }
    }

    private static func chevron(expanded: Bool) -> NSImage {
        let image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
        return image?.withSymbolConfiguration(.init(pointSize: 10, weight: .semibold)) ?? NSImage()
    }

    // MARK: - Actions

    @objc private func toggleAdvanced() {
        showsAdvanced.toggle()
        advanced.isHidden = !showsAdvanced
        disclosure.image = Self.chevron(expanded: showsAdvanced)
        fitWindowToContent(animated: true)
    }

    @objc private func performPrimary() { summary?.primary.map(perform) }
    @objc private func performSecondary() { summary?.secondary.map(perform) }
    @objc private func performNotice() { summary?.notice?.action.map(perform) }

    private func perform(_ action: LocalServiceSummary.Action) {
        switch action {
        case .setUp: model.setUpCLI()
        case .repair: model.checkForUpdates(repair: true)
        case .createService, .repairService: model.installService()
        case .startService: model.startService()
        case .stopService: model.stopService()
        case .restartService: model.restartService()
        case .openChat: model.openChat()
        case .migrate, .resumeMigration: migrateCLI()
        case .finishUpdate: finishUpdate()
        case .checkForUpdates: model.checkForUpdates()
        case .removeHomebrewCopy: removeBrew()
        case .leaveDeveloperMode: model.leaveDeveloperMode()
        }
    }

    private func confirm(_ title: String, _ message: String, button: String, destructive: Bool = false,
                         proceed: @escaping () -> Void) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = destructive ? .warning : .informational
        alert.addButton(withTitle: button).hasDestructiveAction = destructive
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in if response == .alertFirstButtonReturn { proceed() } }
    }

    @objc private func installCLI() { model.setUpCLI() }
    @objc private func checkUpdates() { model.checkForUpdates() }
    @objc private func repairCLI() { model.checkForUpdates(repair: true) }
    @objc private func removeCLI() {
        confirm("Remove term-llm from this Mac?",
                "The app deletes its copy of term-llm and removes the local service if it uses that copy. Your settings, conversations and sign-in details stay on this Mac.",
                button: "Remove", destructive: true) { self.model.removeCLI() }
    }
    @objc private func stopManaging() {
        confirm("Stop managing term-llm?",
                "term-llm stays installed and the local service keeps running, but the app won't update it anymore. You can update it yourself with term-llm upgrade.",
                button: "Stop Managing") { self.model.handOverCLI() }
    }
    @objc private func migrateCLI() {
        let resuming = model.migrationJournal.map { !$0.complete && !$0.rolledBack } ?? false
        var lines: [String] = []
        for conflict in model.conflicts {
            switch conflict {
            case .serviceBinary(let kind, _):
                lines.append("• The \(kind) service restarts on the app's copy. Its settings and sign-in stay the same.")
            case .pathLinkOccupied(let path, let target):
                lines.append(target == "regular file"
                    ? "• \(tilde(path)) will run the app's copy. The file there now is kept in the app's folder."
                    : "• \(tilde(path)) will run the app's copy instead of \(tilde(target)).")
            case .legacyExternalSelection:
                lines.append("• The app stops using the copy it was set up with before.")
            case .homebrewFormula, .foreignCommand:
                break
            }
        }
        if lines.isEmpty { lines.append("• The app finishes the steps that are left.") }
        lines.append("\nOther copies of term-llm aren't deleted.")
        confirm(resuming ? "Finish switching to the app's copy?" : "Switch to the app's copy?",
                lines.joined(separator: "\n"), button: resuming ? "Finish Switching" : "Switch") { self.model.migrate() }
    }
    @objc private func rollbackMigration() {
        confirm("Undo the switch?",
                "Services go back to the copies they used before, and the Terminal command is put back. The app's copy stays installed.",
                button: "Undo Switch") { self.model.migrate(rollback: true) }
    }
    @objc private func removeBrew() {
        let first = model.migrationJournal?.complete == true ? "" : "Anything still using it switches to the app's copy first. "
        confirm("Remove Homebrew's term-llm?",
                first + "Then the app runs brew uninstall term-llm. Nothing is removed if other Homebrew packages need it.",
                button: "Remove", destructive: true) { self.model.removeHomebrewCopy() }
    }
    @objc private func finishUpdate() {
        confirm("Restart the local service?",
                "This finishes the update. Anything running in the service is interrupted.",
                button: "Restart") { self.model.finishUpdate() }
    }
    @objc private func developerMode() {
        if model.developerModeEnabled { model.leaveDeveloperMode(); return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.prompt = "Use This term-llm"
        panel.message = "Choose a term-llm executable to use instead of the app's copy. While Developer Mode is on, the app doesn't install, update or switch anything."
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url { self.model.enableDeveloperMode(binary: url) }
        }
    }
    @objc private func installService() { model.installService() }
    @objc private func restartService() { model.restartService() }
    @objc private func setAutostart(_ sender: NSButton) { model.setServiceAutostart(sender.state == .on) }
    @objc private func setLoginItem(_ sender: NSButton) { model.setLoginItem(sender.state == .on) }
    @objc private func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.diagnosticsText(), forType: .string)
        copyButton.title = "Copied"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.copyButton.title = "Copy Diagnostics" }
    }
}

/// Scroll document that starts at the top when the window can't show everything.
final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

/// Quiet rounded background for the simple view's one notice. Drawn rather than
/// layer-backed so the dynamic color follows light and dark appearance.
final class NoticePanel: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
}
