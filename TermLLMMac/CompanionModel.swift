import AppKit
import Combine
import Foundation
// TermLLMMacKit is a Swift 5 language-mode package; its value types are
// used across this model's background tasks.
@preconcurrency import TermLLMMacKit

/// Main-actor UI state. All observable mutation happens here; filesystem and
/// CLI work is performed on a background task and returned as a value.
@MainActor
final class CompanionModel: ObservableObject {
    @Published private(set) var selection: CLISelection?
    @Published private(set) var selectionError: String?
    @Published private(set) var cliProblems: [CLIProblem] = []
    @Published private(set) var pathLink: PATHLinkStatus?
    @Published private(set) var status: ServiceStatus?
    @Published private(set) var statusReport: ServiceStatusReport?
    @Published private(set) var statusError: String?
    @Published private(set) var endpoint: ManagedLoopbackEndpoint?
    @Published private(set) var endpointError: String?
    @Published private(set) var token: String?
    @Published private(set) var sessionOutcome: LocalSessionProbe.Outcome?
    @Published private(set) var loginItemEnabled = false
    /// Registered for Open at Login, but waiting for approval in System Settings.
    @Published private(set) var loginItemNeedsApproval = false
    @Published private(set) var busy = false
    @Published private(set) var preparingForTermination = false
    private var activeRefreshes = 0

    @Published private(set) var actionError: String?
    @Published private(set) var lastAction: String?
    @Published private(set) var diagnostics = DiagnosticsReport(checks: [])
    @Published private(set) var developerModeEnabled = false
    @Published private(set) var developerBinary: URL?
    @Published private(set) var conflicts: [OwnershipConflict] = []
    @Published private(set) var migrationJournal: MigrationJournal?
    @Published private(set) var migrationBlocker: MigrationBlocker? = .notSetUp
    @Published private(set) var updateState = CLIUpdateState()
    @Published private(set) var signatureVerifiedVersion: String?
    @Published private(set) var handedOver = false
    @Published private(set) var servicePort: Int = 8765
    @Published private(set) var serviceAuth: String = "bearer"
    @Published private(set) var lastRefresh = Date.distantPast

    /// In-process handoff into the full client's retained Chat workspace.
    /// Never persist or URL-encode the credential.
    var openLocalChatHandler: ((ManagedLoopbackEndpoint, String) -> Void)?
    /// Same handoff without opening Chat: keeps the verified local service in
    /// the app's connections as This Mac. Offered once per address and token.
    var connectLocalServiceHandler: ((ManagedLoopbackEndpoint, String) -> Void)?
    private var offeredEndpoint: ManagedLoopbackEndpoint?
    private var offeredToken: String?
    private var connectTask: Task<Void, Never>?

    let home: URL
    let appVersion: String
    private let provisioner: CLIProvisioner
    private let loginItem: AppLoginItem
    private let runner: CommandRunning
    private var updateTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var tokenRetryAfter = Date.distantPast

    /// Tests pass `loginService: nil`: the hosted test runner is this app, and
    /// must never register the developer's real Open at Login item.
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         loginService: MainAppLoginService? = AppLoginItem.systemService) {
        self.home = home
        let runner = ProcessCommandRunner()
        self.runner = runner
        self.provisioner = CLIProvisioner(home: home, runner: runner)
        self.loginItem = AppLoginItem(home: home, mainApp: loginService)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        self.appVersion = version
        selection = try? provisioner.loadSelection().get()
        developerModeEnabled = FileManager.default.fileExists(atPath: DeveloperModeStore(provisioner: provisioner).url.path)
        developerBinary = try? DeveloperModeStore(provisioner: provisioner).load()
        handedOver = selection == nil && FileManager.default.fileExists(atPath: provisioner.managedBinary.path)
        syncLoginItem()
        rebuildDiagnostics()
    }

    // MARK: - Derived state

    var controller: ServiceController? {
        if let developerBinary { return ServiceController(executable: developerBinary, runner: runner) }
        guard let selection, selection.source == .release, cliProblems.isEmpty,
              signatureVerifiedVersion != nil else { return nil }
        return ServiceController(executable: provisioner.managedBinary, runner: runner)
    }

    var readiness: ChatReadiness {
        guard controller != nil, cliProblems.isEmpty else { return .needsServiceInstall }
        guard let status else { return .needsServiceInstall }
        // A service on another copy still serves Chat; only control is withheld.
        switch status.state {
        case .notInstalled, .notRegistered: return .needsServiceInstall
        case .unmanaged: return .unmanagedService
        case .stopped: return .needsStart
        case .unhealthy: return .unhealthy(status.healthError ?? "The health check failed.")
        case .error: return .unsupported(status.error ?? "The service manager reported an error.")
        case .ready:
            if status.auth == "passkey", status.enrollment == .pending {
                return .passkeyEnrollmentRequired
            }
            if token == nil { return .needsAuthentication }
            return .ready
        }
    }

    var isChatAvailable: Bool {
        if case .ready = readiness, endpoint != nil, token != nil, sessionOutcome?.isAuthenticated == true {
            return true
        }
        return false
    }

    var statusTitle: String {
        guard let status else { return cliProblems.isEmpty ? "Not set up" : "CLI problem" }
        switch status.state {
        case .ready: return "Running"
        case .stopped: return "Stopped"
        case .unhealthy: return "Unhealthy"
        case .notInstalled: return "Not installed"
        case .notRegistered: return "Needs repair"
        case .unmanaged: return "Unmanaged"
        case .error: return "Error"
        }
    }

    var menuBarSymbol: String {
        switch status?.state {
        case .ready: return "terminal.fill"
        case .stopped, .notInstalled, .notRegistered: return "terminal"
        case .unhealthy, .unmanaged, .error: return "exclamationmark.triangle"
        case .none: return "terminal"
        }
    }

    var appExecutableURL: URL {
        Bundle.main.executableURL
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/term-llm")
    }

    var isManaged: Bool { selection?.source == .release && !developerModeEnabled }
    var managedBinaryPath: String { provisioner.managedBinary.path }
    var migrationUnavailableReason: String? { migrationBlocker?.reason }

    /// The simple view's headline, next step and notice.
    var summary: LocalServiceSummary {
        var facts = LocalServiceFacts(home: home.path, managedBinary: provisioner.managedBinary.path)
        facts.busyMessage = busy ? (lastAction ?? "Working…") : nil
        facts.developerModeEnabled = developerModeEnabled
        facts.developerBinary = developerBinary?.path
        facts.selection = selection
        facts.verifiedVersion = signatureVerifiedVersion
        facts.ownershipError = selectionError
        facts.handedOver = handedOver
        facts.service = status
        facts.serviceError = controller == nil ? nil : statusError
        facts.conflicts = conflicts
        facts.migrationBlocker = migrationBlocker
        facts.migration = migrationJournal
        facts.updates = updateState
        return LocalServiceSummary.make(facts)
    }

    /// Start, stop, restart and start-at-login act on any service the core
    /// manages, whichever copy of term-llm it runs. The core refuses services it
    /// doesn't own; replacing the service's binary is the separate switch.
    var canControlService: Bool {
        guard controller != nil, let status else { return false }
        return status.installed && status.managed
    }
    var ownershipStatus: String {
        if let developerBinary { return "Developer mode · \(developerBinary.path) — no installation, update, migration or PATH management" }
        if developerModeEnabled { return "Developer mode — selected executable unavailable. Leave Developer Mode to manage term-llm." }
        if let selection {
            if selection.source == .external { return "Legacy selection — migration pending · \(selection.binaryPath)" }
            if selection.source == .bundled { return "Managed legacy install — update required · \(provisioner.managedBinary.path)" }
            let checked = updateState.lastCheckedAt.map { $0.formatted() } ?? "Never"
            return "Managed · \(selection.version) · \(provisioner.managedBinary.path)\nLast update check: \(checked)"
        }
        return handedOver ? "Handed over — this copy updates itself with `term-llm upgrade`" : "Not set up"
    }

    // MARK: - Lifecycle

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        guard !preparingForTermination else { return }
        activeRefreshes += 1
        defer { activeRefreshes -= 1 }
        await reloadOwnership()
        guard let controller else {
            status = nil
            statusReport = nil
            statusError = selectionError ?? "Set up the official signed term-llm release or choose Developer Mode first."
            endpoint = nil; token = nil; sessionOutcome = nil
            lastRefresh = Date()
            rebuildDiagnostics()
            return
        }
        do {
            // One CLI process per poll reports both Web and Hub.
            let report = try await perform { try controller.statusAll() }
            statusReport = report
            status = report.service("web")
            if developerBinary == nil {
                let provisioner = self.provisioner
                let states = report.services
                let scanned = await performValue { ConflictScanner(provisioner: provisioner).scan(services: states) }
                conflicts = scanned
                migrationBlocker = await performValue { MigrationManager(provisioner: provisioner).blocker(conflicts: scanned) }
            }
            statusError = nil
            if let status {
                servicePort = status.port ?? servicePort
                serviceAuth = status.auth ?? serviceAuth
                switch ManagedLoopbackEndpoint.make(from: status) {
                case .success(let value):
                    endpoint = value
                    endpointError = nil
                case .failure(let error):
                    endpoint = nil
                    endpointError = error.localizedDescription
                }
            } else {
                endpoint = nil
                endpointError = "The service report did not contain a web service."
            }
        } catch {
            statusReport = nil
            status = nil
            endpoint = nil
            statusError = error.localizedDescription
        }
        if endpoint == nil { token = nil; sessionOutcome = nil }
        syncLoginItem()
        if let status, status.state == .ready, let endpoint,
           (token == nil || sessionOutcome == nil),
           Date() >= tokenRetryAfter {
            await loadToken(endpoint: endpoint, probe: true)
        }
        offerConnectionIfNeeded()
        lastRefresh = Date()
        rebuildDiagnostics()
    }

    /// Hands a newly verified address or token to the app; never a credential
    /// that failed the authenticated probe.
    private func offerConnectionIfNeeded() {
        guard isChatAvailable, let endpoint, let token, let connectLocalServiceHandler,
              endpoint != offeredEndpoint || token != offeredToken else { return }
        offeredEndpoint = endpoint
        offeredToken = token
        connectLocalServiceHandler(endpoint, token)
    }

    /// Keeps This Mac current while no Local Service window or menu is polling:
    /// one status check a minute until the service is connected, then every five.
    func startBackgroundConnect() {
        guard connectTask == nil else { return }
        connectTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.pollTask == nil && !self.busy { await self.refresh() }
                let minutes: UInt64 = self.offeredEndpoint == nil ? 1 : 5
                try? await Task.sleep(nanoseconds: minutes * 60_000_000_000)
            }
        }
    }

    // MARK: - CLI

    private struct OwnershipSnapshot {
        var selection: CLISelection?
        var developer: URL?
        var developerEnabled = false
        var error: String?
        var problems: [CLIProblem] = []
        var pathLink: PATHLinkStatus?
        var signatureVersion: String?
        var conflicts: [OwnershipConflict] = []
        var journal: MigrationJournal?
        var updates = CLIUpdateState()
        var handedOver = false
    }
    private func reloadOwnership() async {
        let provisioner = self.provisioner
        // Reuse the last service report so service conflicts don't blink out
        // between this scan and the fresh one after the status call.
        let knownServices = statusReport?.services ?? []
        let snapshot = await performValue { () -> OwnershipSnapshot in
            var value = OwnershipSnapshot()
            do {
                value.developerEnabled = FileManager.default.fileExists(atPath: DeveloperModeStore(provisioner: provisioner).url.path)
                value.developer = try DeveloperModeStore(provisioner: provisioner).load()
                value.selection = try provisioner.loadSelection().get()
                if value.developer == nil {
                    value.updates = try CLIUpdater(provisioner: provisioner).loadState()
                    value.journal = try MigrationManager(provisioner: provisioner).loadJournal()
                    value.conflicts = ConflictScanner(provisioner: provisioner).scan(services: knownServices)
                    if let selection = value.selection {
                        if selection.source == .release {
                            value.problems = provisioner.problems(in: selection)
                            try ReleaseInstaller(provisioner: provisioner).verifyManaged()
                            value.signatureVersion = selection.version
                            try? provisioner.refreshManagedMarkerWording()
                        }
                        value.pathLink = provisioner.inspectPATHLink(for: selection)
                    }
                    value.handedOver = value.selection == nil && FileManager.default.fileExists(atPath: provisioner.managedBinary.path)
                }
            } catch { value.error = "Ownership verification failed: " + error.localizedDescription }
            return value
        }
        selection = snapshot.selection; developerBinary = snapshot.developer
        developerModeEnabled = snapshot.developerEnabled
        selectionError = snapshot.error; cliProblems = snapshot.problems; pathLink = snapshot.pathLink
        signatureVerifiedVersion = snapshot.signatureVersion; conflicts = snapshot.conflicts
        migrationJournal = snapshot.journal; updateState = snapshot.updates; handedOver = snapshot.handedOver
        if snapshot.error != nil { signatureVerifiedVersion = nil }
        // The real blocker is computed after the status call; only override it
        // when that call can't happen, so the switch button doesn't flicker.
        if developerModeEnabled { migrationBlocker = .developerMode }
        else if signatureVerifiedVersion == nil { migrationBlocker = .notSetUp }
    }

    func startUpdateSchedule() {
        guard updateTask == nil else { return }
        updateTask = Task { [weak self] in
            var firstCheck = true
            while !Task.isCancelled {
                guard let self else { return }
                let provisioner = self.provisioner
                let checkAtLaunch = firstCheck
                let due = await self.performValue {
                    guard !FileManager.default.fileExists(atPath: DeveloperModeStore(provisioner: provisioner).url.path),
                          let selected = try? provisioner.loadSelection().get(), selected.source != .external else { return false }
                    do {
                        if let journal = try MigrationManager(provisioner: provisioner).loadJournal(), !journal.complete && !journal.rolledBack { return false }
                    } catch { return false }
                    let state = try? CLIUpdater(provisioner: provisioner).loadState()
                    return checkAtLaunch || Date().timeIntervalSince(state?.lastCheckedAt ?? .distantPast) >= 24 * 60 * 60
                }
                if due && !self.busy { firstCheck = false; self.checkForUpdates(scheduled: true) }
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }
    func setUpCLI() {
        let provisioner = self.provisioner
        run("Downloading and verifying term-llm…", work: {
            _ = try CLIUpdater(provisioner: provisioner).setUp()
            if let installed = try provisioner.loadSelection().get() { _ = provisioner.syncPATHLink(for: installed) }
        }, done: { self.lastAction = "Installed the official signed term-llm release. Foreign copies were left untouched."; self.startUpdateSchedule() })
    }
    /// A scheduled check reports failure only in the saved update state (shown
    /// under Advanced); it doesn't put an error in front of the user.
    func checkForUpdates(repair: Bool = false, scheduled: Bool = false) {
        if repair && selection == nil { setUpCLI(); return }
        let provisioner = self.provisioner
        run(repair ? "Reinstalling term-llm…" : "Checking for updates…", quiet: scheduled, work: {
            try CLIUpdater(provisioner: provisioner).check(force: repair)
        }, done: { state in
            self.updateState = state
            self.lastAction = self.updateNotice ?? "CLI update check completed."
        })
    }
    /// Update follow-ups the user should know about; nil when there are none.
    var updateNotice: String? {
        var notes: [String] = []
        if !updateState.unconfirmedReloads.isEmpty {
            notes.append("Reload requested for \(updateState.unconfirmedReloads.joined(separator: " and ")); the running version isn't confirmed (no bearer token, or active work is still finishing).")
        }
        if !updateState.pendingRestart.isEmpty {
            notes.append("Restart \(updateState.pendingRestart.joined(separator: " and ")) to finish updating.")
        }
        return notes.isEmpty ? nil : notes.joined(separator: "\n")
    }
    func enableDeveloperMode(binary: URL) {
        let provisioner = self.provisioner
        run("Enabling Developer Mode…", work: { try DeveloperModeStore(provisioner: provisioner).enable(binary: binary) }, done: {
            self.token = nil; self.sessionOutcome = nil
        })
    }
    func leaveDeveloperMode() {
        let provisioner = self.provisioner
        run("Leaving Developer Mode…", work: { try DeveloperModeStore(provisioner: provisioner).disable() }, done: {
            self.token = nil; self.sessionOutcome = nil; self.startUpdateSchedule()
        })
    }
    func migrate(rollback: Bool = false) {
        let provisioner = self.provisioner
        run(rollback ? "Undoing the switch…" : "Switching to the app's copy…", work: {
            let manager = MigrationManager(provisioner: provisioner)
            if rollback { try manager.rollback() } else { try manager.migrate() }
        }, done: { self.lastAction = rollback ? "Migration rolled back." : "Migration complete. Other checkouts were left untouched." })
    }
    func removeHomebrewCopy() {
        let provisioner = self.provisioner
        run("Removing Homebrew's term-llm…", work: {
            let manager = MigrationManager(provisioner: provisioner)
            // Removal needs a finished switch, so anything still on Homebrew's
            // copy moves first; a failed switch leaves Homebrew installed.
            if try manager.loadJournal()?.complete != true { try manager.migrate() }
            try manager.removeHomebrewCopy()
        }, done: { self.lastAction = "Homebrew copy removed; conflicts re-scanned." })
    }
    func removeCLI() {
        let provisioner = self.provisioner
        run("Removing term-llm…", work: { try CLIUpdater(provisioner: provisioner).remove() }, done: { self.lastAction = "Removed managed CLI and its services; core data and credentials were preserved." })
    }
    func handOverCLI() {
        let provisioner = self.provisioner
        run("Handing term-llm over…", work: { try provisioner.handOver() }, done: { self.lastAction = "Handed over — this copy updates itself with `term-llm upgrade`" })
    }
    func finishUpdate() {
        let provisioner = self.provisioner
        run("Restarting to finish the update…", work: {
            let updater = CLIUpdater(provisioner: provisioner)
            for kind in try updater.loadState().pendingRestart { try updater.finishRestart(kind: kind) }
        }, done: { self.lastAction = "Finished the service update." })
    }
    func verifyCLI() { Task { await refresh() } }

    // MARK: - Service

    func installService(port: Int? = nil) {
        guard let controller else {
            actionError = "Select a working term-llm CLI first."
            return
        }
        let allowedBinary = developerBinary?.path ?? provisioner.managedBinary.path
        run("Starting the local service…", work: {
            // Re-read immediately before mutation; a stale UI snapshot must not
            // replace an unmanaged service or downgrade existing passkey auth.
            let current = try controller.currentStatus()
            guard (current.state == .notInstalled && !current.installed) ||
                    (current.installed && current.managed && current.auth == "bearer" && current.state != .unmanaged && current.binary == allowedBinary) else {
                throw NSError(domain: "TermLLMLocalService", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "An existing service must be app-managed and use bearer authentication before it can be reinstalled. The app will not replace or downgrade it."])
            }
            let result = try controller.installFresh(authMode: "bearer", port: port)
            guard result.succeeded else {
                throw ServiceContractError.commandFailed(status: result.status,
                                                          message: ServiceController.message(from: result))
            }
        }, done: {
            self.lastAction = "Created a bearer-auth loopback service managed by term-llm."
        })
    }

    func startService() {
        guard let controller, canControlService else { return }
        run("Starting the local service…", work: {
            let result = try controller.start()
            guard result.succeeded else {
                throw ServiceContractError.commandFailed(status: result.status,
                                                          message: ServiceController.message(from: result))
            }
        }, done: {
            self.lastAction = "Started the local service."
        })
    }

    func stopService() {
        guard let controller, canControlService else { return }
        run("Stopping the local service…", work: {
            let result = try controller.stop()
            guard result.succeeded else {
                throw ServiceContractError.commandFailed(status: result.status,
                                                          message: ServiceController.message(from: result))
            }
        }, done: {
            self.token = nil
            self.sessionOutcome = nil
            self.lastAction = "Stopped the local service; the start-at-login preference was preserved."
        })
    }

    func restartService() {
        guard let controller, canControlService else { return }
        run("Restarting the local service…", work: {
            let result = try controller.restart()
            guard result.succeeded else {
                throw ServiceContractError.commandFailed(status: result.status,
                                                          message: ServiceController.message(from: result))
            }
        }, done: {
            self.token = nil
            self.sessionOutcome = nil
            self.lastAction = "Restarted the local service."
        })
    }

    func setServiceAutostart(_ enabled: Bool) {
        guard let controller, canControlService else { return }
        run(enabled ? "Enabling start at login…" : "Disabling start at login…", work: {
            let result = try controller.setAutostart(enabled)
            guard result.succeeded else {
                throw ServiceContractError.commandFailed(status: result.status,
                                                          message: ServiceController.message(from: result))
            }
        }, done: {
            self.lastAction = enabled
                ? "The local service will start when you log in."
                : "The local service will not start automatically at login."
        })
    }

    // MARK: - Login item

    func setLoginItem(_ enabled: Bool) {
        let loginItem = self.loginItem
        let executable = appExecutableURL
        run(enabled ? "Adding the app to login items…" : "Removing the app from login items…", work: {
            if enabled {
                try loginItem.enable(appExecutable: executable)
            } else {
                try loginItem.disable()
            }
        }, done: {
            self.syncLoginItem()
            self.lastAction = enabled
                ? "term-llm will open when you log in."
                : "term-llm will not open automatically at login."
        })
    }

    private func syncLoginItem() {
        loginItemEnabled = loginItem.isEnabled
        loginItemNeedsApproval = loginItem.needsApproval
    }

    func refreshLoginItemPathIfNeeded() {
        guard !preparingForTermination else { return }
        loginItem.refreshIfNeeded(appExecutable: appExecutableURL)
        syncLoginItem()
    }

    // MARK: - Authentication / chat

    /// `onFailure` lets callers without the Local Service window, such as the
    /// menu-bar item, show why Chat didn't open instead of failing silently.
    func openChat(onFailure: ((String) -> Void)? = nil) {
        Task {
            tokenRetryAfter = .distantPast
            await refresh()
            guard status?.state == .ready, let endpoint else {
                actionError = endpointError ?? "The local service is not ready for chat yet."
                onFailure?(actionError ?? "")
                return
            }
            // A handoff must prove the current credential, not reuse a cached
            // success from a previous service run or endpoint.
            await loadToken(endpoint: endpoint, probe: true)
            guard self.endpoint == endpoint, isChatAvailable, let token else {
                actionError = actionError ?? sessionOutcome?.description ?? "The local service is not ready for chat yet."
                onFailure?(actionError ?? "")
                return
            }
            deliverLocalChat(endpoint: endpoint, token: token)
        }
    }

    /// Kept separate from the async work so the final readiness gate is also
    /// enforced at the point where a credential leaves this model.
    func deliverLocalChat(endpoint: ManagedLoopbackEndpoint, token: String) {
        guard isChatAvailable, self.endpoint == endpoint, self.token == token else { return }
        if let openLocalChatHandler {
            openLocalChatHandler(endpoint, token)
        } else {
            actionError = "The app's Chat workspace is unavailable. Close and reopen Local Service, then try again."
        }
    }

    func loadToken(endpoint: ManagedLoopbackEndpoint, probe: Bool) async {
        guard let controller else { return }
        do {
            let value = try await perform { try controller.token() }
            guard self.endpoint == endpoint else { return }
            token = value
            sessionOutcome = nil
            tokenRetryAfter = .distantPast
            actionError = nil
            if probe {
                let outcome = await LocalSessionProbe.probe(endpoint: endpoint, token: value)
                // Polling and explicit opens may overlap. Never attach one
                // probe's success to another endpoint or rotated credential.
                guard self.endpoint == endpoint, token == value else { return }
                sessionOutcome = outcome
                if !outcome.isAuthenticated { actionError = outcome.description }
            }
        } catch {
            guard self.endpoint == endpoint else { return }
            token = nil
            sessionOutcome = .unreachable(error.localizedDescription)
            actionError = error.localizedDescription
            // A failed Keychain read (for example a non-GUI session) must not
            // spawn a promptable CLI every four seconds.
            tokenRetryAfter = Date().addingTimeInterval(30)
        }
        rebuildDiagnostics()
    }

    func verifySession() {
        guard let endpoint, let token else { return }
        Task {
            let outcome = await LocalSessionProbe.probe(endpoint: endpoint, token: token)
            guard self.endpoint == endpoint, self.token == token else { return }
            sessionOutcome = outcome
            rebuildDiagnostics()
        }
    }

    // MARK: - Diagnostics

    func rebuildDiagnostics() {
        diagnostics = CompanionDiagnostics.build(appVersion: appVersion,
                                                 selection: selection,
                                                 selectionError: selectionError,
                                                 problems: cliProblems,
                                                 pathLink: pathLink,
                                                 status: status,
                                                 endpoint: endpoint,
                                                 tokenAvailable: token != nil,
                                                 loginItemEnabled: loginItemEnabled,
                                                 managedMarkerPresent: provisioner.managedMarkerPresent,
                                                 ownership: ownershipStatus,
                                                 signatureVerifiedVersion: signatureVerifiedVersion,
                                                 updateState: updateState, conflicts: conflicts, journal: migrationJournal)
    }

    func diagnosticsText() -> String {
        diagnostics.redactedText(appVersion: appVersion, home: home)
    }

    // MARK: - Quit

    /// Freeze before awaiting: scheduled/user mutations must not enter while
    /// existing detached work is being drained for bundle replacement.
    func prepareForTermination() async throws {
        preparingForTermination = true
        try await AppUpdateDrain.waitUntil(timeout: .seconds(300)) {
            !self.busy && self.activeRefreshes == 0
        }
    }

    func cancelTerminationPreparation() { preparingForTermination = false }

    func quitMenuBarApp() {
        NSApplication.shared.terminate(nil)
    }

    func confirmStopAndQuit() {
        let alert = NSAlert()
        alert.messageText = "Stop the local service and quit?"
        alert.informativeText = "Conversations stay on this Mac. The service will stop for every client; your start-at-login preference is preserved."
        alert.addButton(withTitle: "Stop Service and Quit")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            stopServiceAndQuit()
        }
    }

    func stopServiceAndQuit() {
        guard !busy, !preparingForTermination else { return }
        guard let controller else {
            NSApplication.shared.terminate(nil)
            return
        }
        busy = true
        Task {
            _ = try? await perform { try controller.stop() }
            busy = false
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: - Plumbing

    /// Runs filesystem/CLI work off the main actor and applies results back on
    /// the main actor. The work closure must not mutate published state.
    private func run<T: Sendable>(_ message: String,
                                  quiet: Bool = false,
                                  work: @escaping @Sendable () throws -> T,
                                  done: @escaping (T) -> Void) {
        guard !busy, !preparingForTermination else { return }
        busy = true
        if !quiet { actionError = nil }
        lastAction = message
        Task {
            do {
                let value = try await perform(work)
                done(value)
            } catch {
                if !quiet { actionError = error.localizedDescription }
                lastAction = nil
            }
            busy = false
            syncLoginItem()
            await refresh()
        }
    }

    private func performValue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .utility) { work() }.value
    }

    private func perform<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try work() }.value
    }
}
