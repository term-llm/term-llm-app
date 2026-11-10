import Foundation
import os

public struct CLIUpdateState: Codable, Equatable, Sendable {
    public var lastCheckedAt: Date?
    public var lastError: String?
    public var skippedVersions: [String] = []
    public var lastInstalledVersion: String?
    public var pendingRestart: [String] = []
    /// Services asked to reload whose new version could not be observed: no
    /// bearer token (passkey web, hub), or still finishing active work.
    public var unconfirmedReloads: [String] = []
    public init() {}
    private enum CodingKeys: String, CodingKey { case lastCheckedAt, lastError, skippedVersions, lastInstalledVersion, pendingRestart, unconfirmedReloads }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        lastCheckedAt = try values.decodeIfPresent(Date.self, forKey: .lastCheckedAt)
        lastError = try values.decodeIfPresent(String.self, forKey: .lastError)
        skippedVersions = try values.decodeIfPresent([String].self, forKey: .skippedVersions) ?? []
        lastInstalledVersion = try values.decodeIfPresent(String.self, forKey: .lastInstalledVersion)
        pendingRestart = try values.decodeIfPresent([String].self, forKey: .pendingRestart) ?? []
        unconfirmedReloads = try values.decodeIfPresent([String].self, forKey: .unconfirmedReloads) ?? []
    }
}

public protocol ServiceVersionChecking {
    func matches(status: ServiceStatus, token: String, version: String) -> Bool
}
public struct HTTPServiceVersionChecker: ServiceVersionChecking {
    private let configuration: URLSessionConfiguration
    public init(configuration: URLSessionConfiguration = .ephemeral) { self.configuration = configuration }
    public func matches(status: ServiceStatus, token: String, version: String) -> Bool {
        guard case .success(let endpoint) = ManagedLoopbackEndpoint.make(from: status) else { return false }
        let matches = OSAllocatedUnfairLock(initialState: false); let done = DispatchSemaphore(value: 0)
        let config = configuration.copy() as! URLSessionConfiguration
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCache = nil
        let session = URLSession(configuration: config, delegate: HealthRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: endpoint.baseURL.appendingPathComponent("healthz"))
        request.timeoutInterval = 6; request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        session.dataTask(with: request) { [request] data, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200, http.url == request.url,
               let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let same = json["version"] as? String == version
                matches.withLock { $0 = same }
            }
            done.signal()
        }.resume()
        guard done.wait(timeout: .now() + 8) == .success else { return false }
        return matches.withLock { $0 }
    }
}
private final class HealthRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// All operations are synchronous background work. The model runs this through
/// its detached work seam, so waiting for a graceful reload cannot block UI.
public struct CLIUpdater {
    public let provisioner: CLIProvisioner
    public let installer: ReleaseInstaller
    public var versionChecker: ServiceVersionChecking = HTTPServiceVersionChecker()
    /// How long to wait for a bearer service to report the new version. Expiry
    /// is not a failure: a busy service re-execs after its active work.
    public var reloadTimeout: TimeInterval = 120
    /// How long a service without a bearer token must stay healthy after the
    /// reload request before it is reported as reloaded (version unconfirmed).
    public var unconfirmedSettle: TimeInterval = 20
    /// The successor briefly has no listener, so only a failure lasting this
    /// long counts as a broken release.
    public var failureGrace: TimeInterval = 30
    public var pollInterval: TimeInterval = 2
    public init(provisioner: CLIProvisioner, installer: ReleaseInstaller? = nil) {
        self.provisioner = provisioner; self.installer = installer ?? ReleaseInstaller(provisioner: provisioner)
    }
    public var stateURL: URL { provisioner.supportDirectory.appendingPathComponent("update-state.json") }
    public func loadState() throws -> CLIUpdateState {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return CLIUpdateState() }
        return try JSONDecoder().decode(CLIUpdateState.self, from: Data(contentsOf: stateURL))
    }
    private func save(_ state: CLIUpdateState) throws {
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
    }
    private func controller(_ kind: String) -> ServiceController {
        ServiceController(executable: provisioner.managedBinary, kind: kind, runner: provisioner.runner)
    }
    @discardableResult
    public func setUp() throws -> CLIUpdateState {
        try performCheck(force: true, allowInitialInstall: true)
    }
    @discardableResult
    public func check(force: Bool = false) throws -> CLIUpdateState {
        try performCheck(force: force, allowInitialInstall: false)
    }
    private func performCheck(force: Bool, allowInitialInstall: Bool) throws -> CLIUpdateState {
        try provisioner.requireManagementEnabled()
        if !force, let journal = try MigrationManager(provisioner: provisioner).loadJournal(), !journal.complete && !journal.rolledBack {
            throw CLIProvisionerError.installFailed("Finish or undo the switch to the app's copy before checking for updates. Repair still works if the app's copy is damaged.")
        }
        let current: CLISelection?
        if allowInitialInstall { current = try? provisioner.loadSelection().get() }
        else {
            current = try provisioner.loadSelection().get()
            guard let current, current.source != .external, current.binaryPath == provisioner.managedBinary.path else {
                throw CLIProvisionerError.notInstalled
            }
        }
        try FileManager.default.createDirectory(at: provisioner.supportDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var state = try loadState()
        state.lastCheckedAt = Date(); state.lastError = nil
        try save(state)
        do {
            // Snapshot BEFORE replacement. No foreign service may be reloaded or restarted.
            // A schema-1 or damaged install must never be executed to query status.
            // Repair/install the signed candidate first, then use that verified CLI.
            let currentVerified = (try? installer.verifyManaged()) != nil
            if !currentVerified && current?.source == .release && !force {
                throw CLIProvisionerError.installFailed("The managed installation failed integrity verification. Use Repair to explicitly reinstall a signed release.")
            }
            var running = currentVerified ? try runningOwnedServices() : []
            guard let installed = try installer.install(skippedVersions: state.skippedVersions, force: force || !currentVerified) else { return state }
            state.lastInstalledVersion = installed.version
            state.pendingRestart = []
            state.unconfirmedReloads = []
            try save(state)
            if !currentVerified { running = try runningOwnedServices() }
            var signalled: [String] = []
            do {
                for service in running {
                    let cli = controller(service.kind)
                    // Re-read at time of mutation: another owner could have rebound it.
                    let latest = try cli.currentStatus()
                    guard latest.binary == provisioner.managedBinary.path, latest.running else { continue }
                    guard cli.supports("reload") else { state.pendingRestart.append(service.kind); continue }
                    signalled.append(service.kind)
                    try cli.reload()
                    let token = service.kind == "web" && service.auth == "bearer" ? try? cli.token() : nil
                    if try awaitReload(cli, token: token, version: installed.version) == .unconfirmed {
                        state.unconfirmedReloads.append(service.kind)
                    }
                }
            } catch {
                if !state.skippedVersions.contains(installed.version) { state.skippedVersions.append(installed.version) }
                state.lastError = "The new CLI failed service verification; recovery is required."
                try save(state)
                _ = try provisioner.rollbackToPrevious()
                state.lastInstalledVersion = current?.version
                state.pendingRestart = []
                state.unconfirmedReloads = []
                state.lastError = "The new CLI failed service verification; the previous version was restored."
                // Persist the bad-version decision even if recovery itself fails.
                try save(state)
                // Do not execute a legacy/unsigned backup even during recovery.
                try installer.verifySignature(at: provisioner.managedBinary)
                for kind in signalled {
                    let cli = controller(kind)
                    if try cli.currentStatus().binary == provisioner.managedBinary.path {
                        try cli.requireSuccess(cli.restart())
                    }
                }
                throw error
            }
            try save(state)
            return state
        } catch {
            if state.lastError == nil { state.lastError = "Couldn't check for updates: \(error.localizedDescription)" }
            try save(state)
            throw error
        }
    }
    enum ReloadOutcome { case confirmed, unconfirmed }

    /// `service reload` only requests a graceful re-exec: the previous process
    /// keeps serving until its active work finishes, then the successor has no
    /// listener until it starts. An authenticated health response proves the new
    /// version; without a bearer token a healthy service is only "unconfirmed".
    /// Only a failure that persists past the start-up gap means a broken release.
    func awaitReload(_ cli: ServiceController, token: String?, version: String) throws -> ReloadOutcome {
        let began = Date()
        var failingSince: Date?
        while true {
            // A status query that fails counts like an unhealthy state: only a
            // persistent failure means the new release is broken.
            let status = try? cli.currentStatus()
            if let status, status.binary != provisioner.managedBinary.path {
                throw CLIProvisionerError.installFailed("The \(cli.kind) service was switched to another binary during the update.")
            }
            let now = Date()
            if let status, status.state == .ready {
                failingSince = nil
                if let token {
                    if versionChecker.matches(status: status, token: token, version: version) { return .confirmed }
                } else if now.timeIntervalSince(began) >= unconfirmedSettle {
                    return .unconfirmed
                }
                if now.timeIntervalSince(began) >= reloadTimeout { return .unconfirmed }
            } else {
                let since = failingSince ?? now
                failingSince = since
                if now.timeIntervalSince(since) >= failureGrace {
                    throw CLIProvisionerError.installFailed("The \(cli.kind) service did not stay healthy after reloading the new CLI.")
                }
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
    }

    private func runningOwnedServices() throws -> [ServiceStatus] {
        try ["web", "hub"].map { try controller($0).currentStatus() }
            .filter { $0.binary == provisioner.managedBinary.path && $0.running }
    }
    public func finishRestart(kind: String) throws {
        try installer.verifyManaged()
        var state = try loadState()
        guard state.pendingRestart.contains(kind) else { return }
        let cli = controller(kind)
        guard try cli.currentStatus().binary == provisioner.managedBinary.path else { return }
        try cli.requireSuccess(cli.restart())
        guard try cli.currentStatus().state == .ready else { throw CLIProvisionerError.installFailed("The service is not ready after restart.") }
        state.pendingRestart.removeAll { $0 == kind }; try save(state)
    }
    public func remove() throws {
        try installer.verifyManaged()
        for kind in ["web", "hub"] {
            let cli = controller(kind)
            if try cli.currentStatus().binary == provisioner.managedBinary.path { try cli.requireSuccess(cli.uninstall()) }
        }
        _ = try provisioner.removeManagedInstall()
    }
}
