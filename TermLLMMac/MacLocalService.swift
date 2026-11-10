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
    private(set) static weak var active: MacLocalServiceController?
    private var preparingForTermination = false
    private var modelInitialized = false
    private var loginRefreshTask: Task<Void, Never>?
    private(set) var loginRefreshPending = false

    /// Admission stays closed until the detached mutation itself finishes,
    /// even if a termination wait times out or the user retries quitting.
    func startLoginRefresh(_ work: @escaping @Sendable () -> Void) {
        guard !loginRefreshPending, !preparingForTermination else { return }
        loginRefreshPending = true
        loginRefreshTask = Task {
            await Task.detached(priority: .utility, operation: work).value
            loginRefreshPending = false
            loginRefreshTask = nil
        }
    }

    func waitForLoginRefresh(timeout: Duration = .seconds(30)) async throws {
        try await AppUpdateDrain.waitUntil(timeout: timeout) { !self.loginRefreshPending }
    }

    /// Normal app termination (including Sparkle) cannot complete until its
    /// filesystem/CLI mutations and its embedded helper have actually drained.
    func prepareForTermination() async throws {
        preparingForTermination = true
        computerUse.beginTerminationPreparation()
        if modelInitialized { try await model.prepareForTermination() }
        try await waitForLoginRefresh()
        try await computerUse.prepareForTermination()
    }

    func cancelTerminationPreparation() {
        preparingForTermination = false
        if modelInitialized { model.cancelTerminationPreparation() }
        computerUse.cancelTerminationPreparation()
    }

    /// (base URL, bearer credential, open Chat). `open: false` only adds This Mac.
    var onConnection: ((URL, String, Bool) -> Void)?

    private var localServiceWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var applicationStarted = false
    private var localServicesEnabled = false
    private let home: URL
    private var automaticTerminationDisabled = false
    private let injectedComputerUse: ComputerUseController?
    private lazy var computerUse: ComputerUseController = {
        let controller = injectedComputerUse ?? ComputerUseController(home: home)
        controller.onChange = { [weak self] in self?.updateComputerUseIcon() }
        return controller
    }()
    private static let lifetimeReason = "term-llm menu-bar app is running"

    /// Tests pass `computerUse` so the menu never reads this Mac's real state.
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, computerUse: ComputerUseController? = nil) {
        self.home = home
        injectedComputerUse = computerUse
        let provisioner = CLIProvisioner(home: home)
        localServicesEnabled = FileManager.default.fileExists(atPath: provisioner.manifestURL.path)
            || FileManager.default.fileExists(atPath: DeveloperModeStore(provisioner: provisioner).url.path)
        super.init()
    }

    // Remote-only installs stay lazy. Existing managed installs initialize the
    // model at launch for background CLI updates. Chat stays in the client.
    private lazy var model: CompanionModel = {
        modelInitialized = true
        let model = CompanionModel(home: home)
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
        Self.active = self
        createStatusItemIfNeeded()
        computerUse.start()
        updateComputerUseIcon()
        ProcessInfo.processInfo.disableAutomaticTermination(Self.lifetimeReason)
        automaticTerminationDisabled = true
        NotificationCenter.default.addObserver(self, selector: #selector(willTerminate),
                                               name: NSApplication.willTerminateNotification, object: nil)
        // An older build wrote a launch agent for Open at Login, which System
        // Settings lists as a background item; move it to Open at Login.
        if let executable = Bundle.main.executableURL, let system = AppLoginItem.systemService {
            startLoginRefresh {
                AppLoginItem(mainApp: system).refreshIfNeeded(appExecutable: executable)
            }
        }
        let provisioner = CLIProvisioner(home: home)
        // Earlier builds kept these files in ~/Library/Application Support/TermLLM.
        _ = try? provisioner.migrateLegacySupportDirectory()
        let developerMode = FileManager.default.fileExists(atPath: DeveloperModeStore(provisioner: provisioner).url.path)
        let managed = FileManager.default.fileExists(atPath: provisioner.manifestURL.path)
        if managed || developerMode {
            // Existing installs need controls immediately, not only after the
            // user opens setup (or restarts the service from that window).
            localServicesEnabled = true
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
        computerUse.shutdownForApplicationQuit()
        if automaticTerminationDisabled {
            ProcessInfo.processInfo.enableAutomaticTermination(Self.lifetimeReason)
            automaticTerminationDisabled = false
        }
    }

    @objc func showLocalService() {
        guard !preparingForTermination else { return }
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
        computerUse.menuOpen = true
        computerUse.refreshStatus()
        if computerUse.enabled { computerUse.refreshInstallations() }
        if localServicesEnabled { model.startPolling() }
    }

    func menuDidClose(_ menu: NSMenu) {
        computerUse.menuOpen = false
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
        // A missing grant, command or skill is said first; the window fixes it.
        let issues = computerUse.issues
        if !issues.isEmpty {
            let item = NSMenuItem(title: "Computer Use Needs Attention…", action: #selector(showComputerUse),
                                  keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [.systemOrange]))
            let summary = issues.map(\.title).joined(separator: " · ")
            if #available(macOS 14.4, *) { item.subtitle = summary } else { item.toolTip = summary }
            menu.addItem(item)
            menu.addItem(.separator())
        }
        addItem("Open term-llm", action: #selector(openTermLLM), to: menu,
                enabled: MacClientWindow.shared.window != nil)
        addItem("Local Service…", action: #selector(showLocalService), to: menu)
        addItem("Computer Use…", action: #selector(showComputerUse), to: menu)
        if computerUse.enabled {
            menu.addItem(.separator())
            let status = NSMenuItem(title: "Computer use: \(computerUse.statusTitle)", action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
            if computerUse.status.working { addItem("Stop", action: #selector(stopComputerUse), to: menu) }
            addItem(computerUse.status.paused ? "Resume" : "Pause Computer Use", action: #selector(pauseComputerUse), to: menu)
            for grant in computerUse.status.missing {
                let item = NSMenuItem(title: "Allow \(grant)…", action: #selector(allowComputerUse(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = grant
                menu.addItem(item)
            }
        }
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
        AppUpdateController.shared.addMenuItems(to: menu)
        menu.addItem(.separator())
        addItem("Quit term-llm", action: #selector(quitTermLLM), to: menu)
    }

    private func updateComputerUseIcon() {
        statusItem?.button?.image = NSImage(systemSymbolName: computerUse.icon, accessibilityDescription: "term-llm")
        statusItem?.button?.toolTip = computerUse.enabled ? "term-llm · Computer use: \(computerUse.statusTitle)" : "term-llm"
        if computerUse.menuOpen, let menu = statusItem?.menu { menuNeedsUpdate(menu) }
    }

    @objc private func showComputerUse() { computerUse.showWindow() }
    @objc private func stopComputerUse() { computerUse.stop() }
    @objc private func pauseComputerUse() { computerUse.togglePause() }
    @objc private func allowComputerUse(_ sender: NSMenuItem) {
        if let grant = sender.representedObject as? String { computerUse.send("allow", grant: grant) }
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
