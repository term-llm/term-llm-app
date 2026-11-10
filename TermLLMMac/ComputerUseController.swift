import AppKit
import Combine
@preconcurrency import ComputerUseCore
import Darwin
import Foundation

/// File-only setup logic. Tests inject both homes; no defaults or TCC calls.
struct ComputerUseInstallation: Sendable {
    let home: URL
    let state: URL
    let binary: URL
    private var manager: FileManager { .default }
    var enabledURL: URL { state.appendingPathComponent("enabled") }
    var link: URL { home.appendingPathComponent(".local/bin/term-llm-computer") }
    var skill: URL { home.appendingPathComponent(".config/term-llm/skills/\(ComputerUseSkill.name)/SKILL.md") }
    /// Earlier builds named the skill after the command. Agents would see both.
    var legacySkill: URL { home.appendingPathComponent(".config/term-llm/skills/term-llm-computer/SKILL.md") }
    private var ownershipURL: URL { state.appendingPathComponent("command-link.json") }
    var enabled: Bool { manager.fileExists(atPath: enabledURL.path) }

    func setEnabled(_ value: Bool) throws {
        try UnixSocket.makeOwnFolder(state.path)
        if value {
            try Data().write(to: enabledURL, options: .atomic)
            chmod(enabledURL.path, 0o600)
        } else if enabled {
            try manager.removeItem(at: enabledURL)
        }
    }
    private func ownedTargets() -> Set<String> {
        guard let data = try? Data(contentsOf: ownershipURL),
            let paths = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(paths)
    }
    var linkDestination: String? { try? manager.destinationOfSymbolicLink(atPath: link.path) }
    var linkIsCurrent: Bool { linkDestination == binary.path }
    /// The skill's `skill:computer-use` module for spawn_script cells.
    var skillModule: URL { skill.deletingLastPathComponent().appendingPathComponent(ComputerUseSkill.modulePath) }
    var skillInstalled: Bool {
        (try? String(contentsOf: skill, encoding: .utf8)) == ComputerUseSkill.text
            && (try? String(contentsOf: skillModule, encoding: .utf8)) == ComputerUseSkill.module
    }
    /// Only the app's own old copy: a real file in a real folder, with the old name.
    var legacySkillInstalled: Bool {
        Self.kind(legacySkill.deletingLastPathComponent()) == S_IFDIR && Self.kind(legacySkill) == S_IFREG
            && (try? String(contentsOf: legacySkill, encoding: .utf8))?.hasPrefix("---\nname: term-llm-computer\n") == true
    }
    /// An older app's skill is still there after an update: agents follow its text.
    var skillState: ComputerUseSkillState {
        if skillInstalled && !legacySkillInstalled { return .installed }
        return manager.fileExists(atPath: skill.path) || legacySkillInstalled ? .outdated : .missing
    }
    private static func kind(_ url: URL) -> mode_t? {
        var info = stat()
        return lstat(url.path, &info) == 0 ? info.st_mode & S_IFMT : nil
    }

    /// Repair only a link to this binary or a previously recorded target. In
    /// particular, dangling foreign links and ordinary files are never replaced.
    func installCommand(onlyIfOwned: Bool = false) throws {
        var info = stat()
        let exists = lstat(link.path, &info) == 0
        if !exists && errno != ENOENT { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let destination = linkDestination
        let ours = destination.map { $0 == binary.path || ownedTargets().contains($0) } ?? false
        if exists && (!ours || info.st_mode & S_IFMT != S_IFLNK) {
            if onlyIfOwned { return }
            throw NSError(
                domain: "ComputerUseInstallation", code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "\(link.path) already belongs to another installation. Nothing was changed."
                ])
        }
        if onlyIfOwned && !ours { return }
        if linkIsCurrent { return }
        try UnixSocket.makeOwnFolder(state.path)
        try manager.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        var targets = ownedTargets()
        targets.insert(binary.path)
        // Record ownership before promotion so a moved app can always repair it.
        try JSONEncoder().encode(targets.sorted()).write(to: ownershipURL, options: .atomic)
        chmod(ownershipURL.path, 0o600)
        let staged = link.deletingLastPathComponent().appendingPathComponent(".term-llm-computer-\(UUID().uuidString)")
        try manager.createSymbolicLink(at: staged, withDestinationURL: binary)
        defer { try? manager.removeItem(at: staged) }
        // Do not clobber an occupant created since the initial inspection.
        if !exists {
            guard renameatx_np(AT_FDCWD, staged.path, AT_FDCWD, link.path, UInt32(RENAME_EXCL)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } else {
            var now = stat()
            guard lstat(link.path, &now) == 0, now.st_ino == info.st_ino, now.st_dev == info.st_dev,
                linkDestination == destination
            else { throw CocoaError(.fileWriteFileExists) }
            guard rename(staged.path, link.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
    }
    func installSkill() throws {
        // Never follow a link into someone else's configuration.
        let folder = skill.deletingLastPathComponent()
        for path in [folder, skill, skillModule.deletingLastPathComponent(), skillModule] {
            var info = stat()
            if lstat(path.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK {
                throw CocoaError(.fileWriteNoPermission)
            }
        }
        try manager.createDirectory(at: skillModule.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The module first: term-llm refuses a SKILL.md whose declared module is missing.
        try ComputerUseSkill.module.write(to: skillModule, atomically: true, encoding: .utf8)
        try ComputerUseSkill.text.write(to: skill, atomically: true, encoding: .utf8)
        try removeLegacySkill()
    }
    /// Removes only the files the app wrote there, SKILL.md first so term-llm
    /// stops listing it, then the folders if nothing else is in them.
    private func removeLegacySkill() throws {
        guard legacySkillInstalled else { return }
        let folder = legacySkill.deletingLastPathComponent()
        let module = folder.appendingPathComponent(ComputerUseSkill.modulePath)
        try manager.removeItem(at: legacySkill)
        if Self.kind(module.deletingLastPathComponent()) == S_IFDIR && Self.kind(module) == S_IFREG {
            try manager.removeItem(at: module)
        }
        rmdir(module.deletingLastPathComponent().path)
        rmdir(folder.path)
    }
}

/// An app the person chose "Always allow" for in the helper's approval panel.
struct ComputerUseApprovedApp: Sendable, Equatable {
    let bundleID: String
    let name: String
}

struct ComputerUseStatus: Sendable, Equatable {
    var running = 0
    var working = false
    var paused = false
    var grants: [String: Bool] = [:]
    var missing: [String] { grants.filter { !$0.value }.map(\.key).sorted() }
    var title: String {
        if paused { return "Paused" }
        if let grant = missing.first { return "Needs \(grant)" }
        return working ? "Working" : "Ready"
    }
    var symbol: String {
        if paused { return "pause.circle" }
        if !missing.isEmpty { return "exclamationmark.triangle" }
        return working ? "cursorarrow.rays" : "terminal"
    }
}

enum ComputerUseSkillState: Sendable, Equatable { case installed, outdated, missing }

/// The command link and skill files as last checked.
struct ComputerUseSetup: Sendable, Equatable {
    var commandInstalled: Bool
    var skill: ComputerUseSkillState
}

/// What stops agents using Computer Use fully, called out at the top of the menu
/// and the Computer Use window, each with the button that fixes it.
enum ComputerUseIssue: Sendable, Equatable {
    case grant(String)
    case command
    case skillMissing
    case skillOutdated

    /// Nothing while Computer Use is off. Grants come first: without the two
    /// required ones nothing works. Files are skipped until they were checked.
    static func list(enabled: Bool, status: ComputerUseStatus, setup: ComputerUseSetup?) -> [ComputerUseIssue] {
        guard enabled else { return [] }
        var issues = status.missing.map(ComputerUseIssue.grant)
        if setup?.commandInstalled == false { issues.append(.command) }
        if setup?.skill == .missing { issues.append(.skillMissing) }
        if setup?.skill == .outdated { issues.append(.skillOutdated) }
        return issues
    }
    /// For the status line and the menu.
    var title: String {
        switch self {
        case .grant(let name): return "Needs \(name)"
        case .command: return "Command not installed"
        case .skillMissing: return "Skill not installed"
        case .skillOutdated: return "Skill out of date"
        }
    }
    var detail: String {
        switch self {
        case .grant(let name):
            let effect = [
                "Accessibility": "Computer Use can't work without it.",
                "Screen Recording": "Computer Use can't work without it.",
                "Input Monitoring": "Computer Use can't tell when you use an app yourself, so it won't step back.",
                "Event Posting": "Agents can't send clicks and keys to apps.",
            ][name]
            return ["\(name) isn't allowed.", effect].compactMap { $0 }.joined(separator: " ")
        case .command: return "The term-llm-computer command isn't installed. Agents run it to use apps."
        case .skillMissing: return "The computer-use skill isn't installed. Agents won't know how to use apps on this Mac."
        case .skillOutdated: return "The computer-use skill is out of date. Agents follow older instructions until you update it."
        }
    }
    var action: String {
        switch self {
        case .grant: return "Allow…"
        case .command: return "Install Command"
        case .skillMissing: return "Install Skill"
        case .skillOutdated: return "Update Skill"
        }
    }
}

/// Synchronous socket work is ONLY called from background work below.
private enum ComputerUseTransport {
    static func send(_ method: String, params: [String: String] = [:]) throws -> ComputerUseStatus {
        let path = Paths.socketPath()
        try UnixSocket.ownFolder((path as NSString).deletingLastPathComponent)
        let fd = try UnixSocket.connect(path, timeout: 0.25)
        defer { close(fd) }
        guard UnixSocket.peerUID(fd) == getuid() else { throw CocoaError(.fileReadNoPermission) }
        let reply = try Wire.call(Wire.control(method, params: params), on: fd, deadline: Date().addingTimeInterval(1))
        guard let result = reply["result"] as? [String: Any], reply["error"] == nil, result["exit"] == nil else {
            throw NSError(
                domain: "ComputerUseTransport", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The helper could not complete \(method)."])
        }
        return ComputerUseStatus(
            running: result["running"] as? Int ?? 0, working: result["working"] as? Bool ?? false,
            paused: result["paused"] as? Bool ?? false, grants: result["grants"] as? [String: Bool] ?? [:])
    }
}

@MainActor
final class ComputerUseController: NSObject, ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var status = ComputerUseStatus()
    @Published private(set) var connected = false
    @Published private(set) var error: String?
    /// Nil until the files were first checked, so launch never flashes a warning.
    @Published private(set) var setup: ComputerUseSetup?
    @Published private(set) var alwaysAllowed: [ComputerUseApprovedApp] = []
    var onChange: (() -> Void)?
    private let installation: ComputerUseInstallation
    private let suppressed: Bool
    private var polling: Task<Void, Never>?
    private var window: NSWindow?
    private var observer: NSObjectProtocol?
    private var launching = false
    private var quitting = false
    private var nextLaunch = Date.distantPast
    private var backoff: TimeInterval = 1
    private var connectedSince: Date?
    private var generation = 0
    var menuOpen = false
    var issues: [ComputerUseIssue] { ComputerUseIssue.list(enabled: enabled, status: status, setup: setup) }
    var statusTitle: String {
        guard connected else { return "Starting…" }
        return status.paused ? status.title : issues.first?.title ?? status.title
    }
    var icon: String {
        guard enabled else { return "terminal" }
        return status.paused || issues.isEmpty ? status.symbol : "exclamationmark.triangle"
    }

    init(
        home: URL = Paths.homeDirectory(), state: URL = Paths.stateDirectory(),
        binary: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/term-llm-computer"),
        suppressRuntime: Bool? = nil
    ) {
        installation = ComputerUseInstallation(home: home, state: state, binary: binary)
        suppressed =
            suppressRuntime
            ?? (MacLocalServiceBridge.isHostedTestRun || HubFixture.isEnabled || PhoneHubFixture.isEnabled)
        super.init()
        enabled = installation.enabled
    }
    func start() {
        guard !suppressed, !quitting else { return }
        if observer == nil {
            observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil, queue: .main
            ) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                    app.bundleIdentifier == "com.termllm.app.computeruse"
                else { return }
                MainActor.assumeIsolated {
                    guard let self, self.enabled, !self.quitting else { return }
                    self.connected = false
                    self.launching = false
                    self.nextLaunch = Date().addingTimeInterval(self.backoff)
                    self.backoff = min(60, self.backoff * 2)
                }
            }
        }
        refreshInstallations(repair: true)
        if enabled { startPolling() }
    }
    func setEnabled(_ value: Bool) {
        guard !suppressed, !quitting else { return }
        do { try installation.setEnabled(value) } catch {
            self.error = error.localizedDescription
            return
        }
        enabled = value
        generation += 1
        error = nil
        if value {
            nextLaunch = .distantPast
            backoff = 1
            startPolling()
        } else {
            polling?.cancel()
            polling = nil
            connected = false
            status = ComputerUseStatus()
            send("shutdown")
        }
        onChange?()
    }
    private func startPolling() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.enabled, !self.quitting else { return }
                await self.poll()
                try? await Task.sleep(for: .milliseconds(self.menuOpen ? 400 : 2000))
            }
        }
    }
    func refreshStatus() {
        guard enabled, !suppressed else { return }
        Task { await poll() }
    }
    private func poll() async {
        let epoch = generation
        let value = await Task.detached(priority: .utility) { try? ComputerUseTransport.send("status") }.value
        guard enabled, !quitting, epoch == generation else { return }
        if let value {
            status = value
            connected = true
            error = nil
            // "Always allow" in the helper's panel changes the list while it shows.
            if window?.isVisible == true { refreshApprovals() }
            // Do not reset the crash backoff on a single successful heartbeat, but
            // a helper that stayed up a minute was not crashing: its next exit
            // (for example to read a new permission grant) relaunches at once.
            if connectedSince == nil { connectedSince = Date() }
            if let since = connectedSince, Date().timeIntervalSince(since) > 60 { backoff = 1 }
        } else {
            connectedSince = nil
            connected = false
            launchIfNeeded()
        }
        onChange?()
    }
    private func launchIfNeeded() {
        guard !suppressed, enabled, !quitting, !launching, Date() >= nextLaunch else { return }
        launching = true
        nextLaunch = Date().addingTimeInterval(backoff)
        backoff = min(60, backoff * 2)
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/term-llm Computer Use.app")
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = false
        config.activates = false
        config.addsToRecentItems = false
        config.environment = [
            "TERM_LLM_COMPUTER_HOST_PID": String(getpid()),
            "TERM_LLM_COMPUTER_HOME": installation.state.path,
            "TERM_LLM_COMPUTER_SOCKET": Paths.socketPath(),
        ]
        NSWorkspace.shared.openApplication(at: helper, configuration: config) { [weak self] _, error in
            let message = error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.launching = false
                if !self.enabled || self.quitting {
                    self.send("shutdown")
                    return
                }
                if let message { self.error = message }
            }
        }
    }
    func send(_ method: String, grant: String? = nil) {
        guard !suppressed else { return }
        let epoch = generation
        Task {
            guard epoch == generation else { return }
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    _ = try ComputerUseTransport.send(method, params: grant.map { ["grant": $0] } ?? [:])
                    return nil
                } catch { return error.localizedDescription }
            }.value
            guard epoch == generation else { return }
            if let failure, method != "shutdown" { error = failure }
            if enabled { await poll() }
        }
    }
    func togglePause() { send(status.paused ? "resume" : "pause") }
    func stop() { send("stop") }

    /// Termination is the sole bounded wait on the main thread: ensure shutdown
    /// reaches the helper before this process exits. Its host monitor is fallback.
    func shutdownForApplicationQuit() {
        quitting = true
        generation += 1
        polling?.cancel()
        polling = nil
        guard !suppressed, enabled else { return }
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? ComputerUseTransport.send("shutdown")
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1.5)
    }
    func refreshInstallations(repair: Bool = false) {
        let files = installation
        Task {
            let value = await Task.detached(priority: .utility) { () -> ComputerUseSetup in
                if repair { try? files.installCommand(onlyIfOwned: true) }
                return ComputerUseSetup(commandInstalled: files.linkIsCurrent, skill: files.skillState)
            }.value
            guard value != setup else { return }
            setup = value
            onChange?()
        }
    }
    func fix(_ issue: ComputerUseIssue) {
        switch issue {
        case .grant(let name): send("allow", grant: name)
        case .command: installCommand()
        case .skillMissing, .skillOutdated: installSkill()
        }
    }
    /// approvals.json is the helper's file; it reads it on every check, so a
    /// removal here takes effect at the agent's next first use of that app.
    func refreshApprovals() {
        let store = ApprovalStore(directory: installation.state)
        Task {
            alwaysAllowed = await Task.detached(priority: .utility) { () -> [ComputerUseApprovedApp] in
                store.always().keys.map { bundleID in
                    var name = bundleID
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                        name = FileManager.default.displayName(atPath: url.path)
                        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
                    }
                    return ComputerUseApprovedApp(bundleID: bundleID, name: name)
                }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }.value
        }
    }
    func forgetApproval(_ bundleID: String) {
        guard !suppressed else { return }
        let store = ApprovalStore(directory: installation.state)
        Task {
            error = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    try store.remove(bundleID: bundleID)
                    return nil
                } catch { return error.localizedDescription }
            }.value
            refreshApprovals()
        }
    }
    func installCommand() { install(skill: false) }
    func installSkill() { install(skill: true) }
    private func install(skill: Bool) {
        guard !suppressed else { return }
        let setup = installation
        Task {
            error = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    if skill { try setup.installSkill() } else { try setup.installCommand() }
                    return nil
                } catch { return error.localizedDescription }
            }.value
            refreshInstallations()
        }
    }
    func showWindow() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Computer Use"
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            let viewController = ComputerUseViewController(controller: self)
            window.contentViewController = viewController
            viewController.fitWindowToContent()
            window.center()
            self.window = window
        }
        refreshInstallations()
        refreshApprovals()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
