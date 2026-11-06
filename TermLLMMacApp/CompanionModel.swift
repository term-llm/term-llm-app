import AppKit
import Combine
import SwiftUI
import TermLLMMacKit

enum CompanionTab: String, CaseIterable, Identifiable {
    case chat = "Chat"
    case setup = "Setup"
    case diagnostics = "Diagnostics"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right"
        case .setup: return "sparkles"
        case .diagnostics: return "stethoscope"
        }
    }
}

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
    @Published private(set) var busy = false
    @Published private(set) var actionError: String?
    @Published private(set) var lastAction: String?
    @Published private(set) var diagnostics = DiagnosticsReport(checks: [])
    @Published var tab: CompanionTab = .setup
    @Published private(set) var externalCandidates: [ExternalCLI] = []
    @Published private(set) var payloadPresent = false
    @Published private(set) var payloadVersion = ""
    @Published private(set) var payloadSHA256 = ""
    @Published private(set) var servicePort: Int = 8765
    @Published private(set) var serviceAuth: String = "bearer"
    @Published private(set) var lastRefresh = Date.distantPast

    let home: URL
    let appVersion: String
    private let provisioner: CLIProvisioner
    private let loginItem: AppLoginItem
    private let runner: CommandRunning
    private var pollTask: Task<Void, Never>?
    private var tokenRetryAfter = Date.distantPast

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
        let runner = ProcessCommandRunner()
        self.runner = runner
        self.provisioner = CLIProvisioner(home: home, runner: runner)
        self.loginItem = AppLoginItem(home: home)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        self.appVersion = version
        loadBundledPayloadMetadata()
        reloadSelection()
        loginItemEnabled = loginItem.isEnabled
        rebuildDiagnostics()
    }

    // MARK: - Derived state

    var controller: ServiceController? {
        guard let selection, cliProblems.isEmpty else { return nil }
        return ServiceController(executable: selection.binaryURL, runner: runner)
    }

    var readiness: ChatReadiness {
        guard selection != nil, cliProblems.isEmpty else { return .needsServiceInstall }
        guard let status else { return .needsServiceInstall }
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

    var statusColor: Color {
        switch status?.state {
        case .ready: return .green
        case .stopped, .notInstalled, .notRegistered: return .secondary
        case .unhealthy, .unmanaged, .error: return .orange
        case .none: return .secondary
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
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/TermLLMMac")
    }

    var bundledPayloadURL: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let payload = resources.appendingPathComponent("cli/term-llm")
        return FileManager.default.isExecutableFile(atPath: payload.path) ? payload : nil
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
        reloadSelection()
        guard let controller else {
            status = nil
            statusReport = nil
            statusError = selectionError ?? "Select a working term-llm CLI first."
            endpoint = nil
            lastRefresh = Date()
            rebuildDiagnostics()
            return
        }
        do {
            let report = try await perform { try controller.status() }
            statusReport = report
            status = report.service("web")
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
        loginItemEnabled = loginItem.isEnabled
        if let status, status.state == .ready, let endpoint,
           (token == nil || sessionOutcome == nil),
           Date() >= tokenRetryAfter {
            await loadToken(endpoint: endpoint, probe: true)
        }
        lastRefresh = Date()
        rebuildDiagnostics()
    }

    // MARK: - CLI

    private func reloadSelection() {
        switch provisioner.loadSelection() {
        case .success(let value):
            selection = value
            selectionError = nil
            cliProblems = value.map { provisioner.problems(in: $0) } ?? []
            if let value {
                provisioner.ensureManagedMarker(for: value)
                pathLink = provisioner.inspectPATHLink(for: value)
            } else {
                pathLink = nil
            }
        case .failure(let error):
            selection = nil
            selectionError = error.localizedDescription
            cliProblems = []
        }
    }

    private func loadBundledPayloadMetadata() {
        guard let resources = Bundle.main.resourceURL else { return }
        let payload = resources.appendingPathComponent("cli/term-llm")
        payloadPresent = FileManager.default.isExecutableFile(atPath: payload.path)
        let versionFile = resources.appendingPathComponent("cli/VERSION")
        payloadVersion = (try? String(contentsOf: versionFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let shaFile = resources.appendingPathComponent("cli/sha256")
        payloadSHA256 = (try? String(contentsOf: shaFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func installBundledCLI() {
        guard let payload = bundledPayloadURL else {
            actionError = "This build has no bundled term-llm payload. Build one with scripts/macos/build-cli-payload.sh or select an existing installation."
            return
        }
        let version = payloadVersion.isEmpty ? "bundled" : payloadVersion
        let provisioner = self.provisioner
        let expectedSHA256 = payloadSHA256.isEmpty ? nil : payloadSHA256
        run("Installing the bundled CLI…", work: {
            try provisioner.installBundled(payload: payload,
                                           version: version,
                                           expectedSHA256: expectedSHA256)
        }, done: { selection in
            self.pathLink = provisioner.syncPATHLink(for: selection)
            self.lastAction = "Installed term-llm \(version) outside the app bundle."
        })
    }

    func detectExternalCLIs() {
        let provisioner = self.provisioner
        run("Looking for existing installations…", work: {
            provisioner.detectExternal()
        }, done: { candidates in
            self.externalCandidates = candidates
            if candidates.isEmpty {
                self.actionError = "No existing term-llm installation was found on PATH or in the common Homebrew locations."
            }
        })
    }

    func adopt(_ external: ExternalCLI) {
        let provisioner = self.provisioner
        run("Using the existing installation…", work: {
            try provisioner.adoptExternal(external)
        }, done: { selection in
            self.pathLink = provisioner.syncPATHLink(for: selection)
            self.externalCandidates = []
            self.lastAction = "Using the existing term-llm installation at \(selection.binaryPath)."
        })
    }

    func verifyCLI() {
        reloadSelection()
        rebuildDiagnostics()
    }

    // MARK: - Service

    func installService(port: Int? = nil) {
        guard let controller else {
            actionError = "Select a working term-llm CLI first."
            return
        }
        run("Creating the local service…", work: {
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
        guard let controller else { return }
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
        guard let controller else { return }
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
        guard let controller else { return }
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
        guard let controller else { return }
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
            self.loginItemEnabled = loginItem.isEnabled
            self.lastAction = enabled
                ? "The menu-bar app will open when you log in."
                : "The menu-bar app will not open automatically at login."
        })
    }

    func refreshLoginItemPathIfNeeded() {
        loginItem.refreshIfNeeded(appExecutable: appExecutableURL)
        loginItemEnabled = loginItem.isEnabled
    }

    // MARK: - Authentication / chat

    func openChat() {
        Task {
            tokenRetryAfter = .distantPast
            await refresh()
            guard let endpoint else {
                actionError = endpointError ?? "The local service endpoint is unavailable."
                return
            }
            if token == nil || sessionOutcome?.isAuthenticated != true {
                await loadToken(endpoint: endpoint, probe: true)
            }
            if token != nil, sessionOutcome?.isAuthenticated == true {
                tab = .chat
            } else {
                actionError = sessionOutcome?.description ?? "The local service is not ready for chat yet."
            }
        }
    }

    func loadToken(endpoint: ManagedLoopbackEndpoint, probe: Bool) async {
        guard let controller else { return }
        do {
            let value = try await perform { try controller.token() }
            token = value
            tokenRetryAfter = .distantPast
            actionError = nil
            if probe {
                let outcome = await LocalSessionProbe.probe(endpoint: endpoint, token: value)
                sessionOutcome = outcome
                if !outcome.isAuthenticated { actionError = outcome.description }
            }
        } catch {
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
            sessionOutcome = await LocalSessionProbe.probe(endpoint: endpoint, token: token)
            rebuildDiagnostics()
        }
    }

    // MARK: - Diagnostics

    func rebuildDiagnostics() {
        diagnostics = CompanionDiagnostics.build(appVersion: appVersion,
                                                 payloadPresent: payloadPresent,
                                                 selection: selection,
                                                 selectionError: selectionError,
                                                 problems: cliProblems,
                                                 pathLink: pathLink,
                                                 status: status,
                                                 endpoint: endpoint,
                                                 tokenAvailable: token != nil,
                                                 loginItemEnabled: loginItemEnabled,
                                                 managedMarkerPresent: provisioner.managedMarkerPresent,
                                                 payloadChecksumPresent: !payloadSHA256.isEmpty)
    }

    func diagnosticsText() -> String {
        diagnostics.redactedText(appVersion: appVersion, home: home)
    }

    // MARK: - Quit

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
        guard let controller else {
            NSApplication.shared.terminate(nil)
            return
        }
        busy = true
        Task {
            _ = try? await perform { try controller.stop() }
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: - Plumbing

    /// Runs filesystem/CLI work off the main actor and applies results back on
    /// the main actor. The work closure must not mutate published state.
    private func run<T>(_ message: String,
                        work: @escaping () throws -> T,
                        done: @escaping (T) -> Void) {
        guard !busy else { return }
        busy = true
        actionError = nil
        lastAction = message
        Task {
            do {
                let value = try await perform(work)
                done(value)
            } catch {
                actionError = error.localizedDescription
                lastAction = nil
            }
            busy = false
            reloadSelection()
            loginItemEnabled = loginItem.isEnabled
            await refresh()
        }
    }

    private func perform<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try work() }.value
    }
}
