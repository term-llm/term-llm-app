import Foundation

/// Machine-readable service status emitted by
/// `term-llm service status [web|hub] --json` (schema version 1).
public struct ServiceStatusReport: Decodable, Equatable, Sendable {
    public static let supportedSchemaVersion = 1

    public var schemaVersion: Int
    public var generatedAt: String?
    public var uid: Int?
    public var platform: String?
    public var services: [ServiceStatus]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case generatedAt = "generated_at"
        case uid
        case platform
        case services
    }

    public init(schemaVersion: Int, generatedAt: String? = nil, uid: Int? = nil,
                platform: String? = nil, services: [ServiceStatus]) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.uid = uid
        self.platform = platform
        self.services = services
    }

    public func service(_ kind: String) -> ServiceStatus? {
        services.first { $0.kind == kind }
    }
}

public struct ServiceStatus: Decodable, Equatable, Sendable {
    public enum State: String, Decodable, Sendable {
        case notInstalled = "not_installed"
        case unmanaged
        case notRegistered = "not_registered"
        case stopped
        case ready
        case unhealthy
        case error
    }

    public enum Enrollment: String, Decodable, Sendable {
        case notRequired = "not_required"
        case pending
        case enrolled
        case unknown
    }

    public var kind: String
    public var installed: Bool
    public var managed: Bool
    public var registered: Bool
    public var state: State
    public var running: Bool
    public var pid: Int?
    public var autostart: Bool
    public var binary: String?
    public var version: String?
    public var url: String?
    public var host: String?
    public var port: Int?
    public var basePath: String?
    public var auth: String?
    public var enrollment: Enrollment
    public var healthy: Bool
    public var healthError: String?
    public var specPath: String?
    public var nativePath: String?
    public var lastExitCode: Int?
    public var error: String?

    enum CodingKeys: String, CodingKey {
        case kind, installed, managed, registered, state, running, pid, autostart,
             binary, version, url, host, port, auth, enrollment, healthy, error
        case basePath = "base_path"
        case healthError = "health_error"
        case specPath = "spec_path"
        case nativePath = "native_path"
        case lastExitCode = "last_exit_code"
    }

    public init(kind: String, installed: Bool, managed: Bool, registered: Bool,
                state: State, running: Bool, pid: Int? = nil, autostart: Bool,
                binary: String? = nil, version: String? = nil, url: String? = nil,
                host: String? = nil, port: Int? = nil, basePath: String? = nil,
                auth: String? = nil, enrollment: Enrollment = .unknown,
                healthy: Bool = false, healthError: String? = nil,
                specPath: String? = nil, nativePath: String? = nil,
                lastExitCode: Int? = nil, error: String? = nil) {
        self.kind = kind
        self.installed = installed
        self.managed = managed
        self.registered = registered
        self.state = state
        self.running = running
        self.pid = pid
        self.autostart = autostart
        self.binary = binary
        self.version = version
        self.url = url
        self.host = host
        self.port = port
        self.basePath = basePath
        self.auth = auth
        self.enrollment = enrollment
        self.healthy = healthy
        self.healthError = healthError
        self.specPath = specPath
        self.nativePath = nativePath
        self.lastExitCode = lastExitCode
        self.error = error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(String.self, forKey: .kind)
        installed = try container.decodeIfPresent(Bool.self, forKey: .installed) ?? false
        managed = try container.decodeIfPresent(Bool.self, forKey: .managed) ?? false
        registered = try container.decodeIfPresent(Bool.self, forKey: .registered) ?? false
        state = (try? container.decodeIfPresent(State.self, forKey: .state)) ?? .error
        running = try container.decodeIfPresent(Bool.self, forKey: .running) ?? false
        let rawPID = try container.decodeIfPresent(Int.self, forKey: .pid)
        pid = (rawPID ?? 0) > 0 ? rawPID : nil
        autostart = try container.decodeIfPresent(Bool.self, forKey: .autostart) ?? false
        binary = try container.decodeIfPresent(String.self, forKey: .binary)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        host = try container.decodeIfPresent(String.self, forKey: .host)
        port = try container.decodeIfPresent(Int.self, forKey: .port)
        basePath = try container.decodeIfPresent(String.self, forKey: .basePath)
        auth = try container.decodeIfPresent(String.self, forKey: .auth)
        enrollment = (try? container.decodeIfPresent(Enrollment.self, forKey: .enrollment)) ?? .unknown
        healthy = try container.decodeIfPresent(Bool.self, forKey: .healthy) ?? false
        healthError = try container.decodeIfPresent(String.self, forKey: .healthError)
        specPath = try container.decodeIfPresent(String.self, forKey: .specPath)
        nativePath = try container.decodeIfPresent(String.self, forKey: .nativePath)
        lastExitCode = try container.decodeIfPresent(Int.self, forKey: .lastExitCode)
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }
}

public enum ServiceContractError: Error, LocalizedError, Equatable {
    case commandFailed(status: Int32, message: String)
    case invalidJSON(String)
    case unsupportedSchema(Int)
    case missingService(String)
    case tokenUnavailable(String)
    case executableUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(_, let message): return message
        case .invalidJSON(let reason): return "The service returned unreadable status: \(reason)"
        case .unsupportedSchema(let version):
            return "This app needs service status schema 1; the CLI reported schema \(version). Update the app or CLI."
        case .missingService(let kind): return "Service status did not include \(kind)."
        case .tokenUnavailable(let reason): return "Could not read the local service token: \(reason)"
        case .executableUnavailable(let path): return "The term-llm executable is unavailable at \(path)."
        }
    }
}

/// Non-interactive wrapper around `term-llm service ...`. The CLI remains the
/// service owner; the app only invokes documented commands and never edits
/// launchd plists or builds its own service manager.
public struct ServiceController: Sendable {
    public let executable: URL
    public let kind: String
    private let runner: CommandRunning

    public init(executable: URL, kind: String = "web", runner: CommandRunning) {
        self.executable = executable
        self.kind = kind
        self.runner = runner
    }

    public init(executable: URL, kind: String = "web") {
        self.init(executable: executable, kind: kind, runner: ProcessCommandRunner())
    }

    public func status() throws -> ServiceStatusReport {
        try report(["service", "status", kind, "--json"])
    }

    /// Web and Hub from one invocation, so polling spawns a single CLI process.
    public func statusAll() throws -> ServiceStatusReport {
        try report(["service", "status", "--json"])
    }

    private func report(_ arguments: [String]) throws -> ServiceStatusReport {
        let result = try invoke(arguments, timeout: 15)
        guard result.succeeded else {
            throw ServiceContractError.commandFailed(status: result.status,
                                                      message: Self.message(from: result))
        }
        let report: ServiceStatusReport
        do {
            report = try JSONDecoder().decode(ServiceStatusReport.self, from: Data(result.stdout.utf8))
        } catch {
            throw ServiceContractError.invalidJSON(String(describing: error))
        }
        guard report.schemaVersion == ServiceStatusReport.supportedSchemaVersion else {
            throw ServiceContractError.unsupportedSchema(report.schemaVersion)
        }
        return report
    }

    public func currentStatus() throws -> ServiceStatus {
        let report = try status()
        guard let service = report.service(kind) else {
            throw ServiceContractError.missingService(kind)
        }
        return service
    }

    /// Fresh install of an owned loopback service. Bearer auth is explicitly
    /// requested; this app does not rely on core defaults, so a future default
    /// change cannot silently downgrade the connection mode.
    public func installFresh(authMode: String = "bearer", port: Int? = nil) throws -> CommandResult {
        var args = ["service", "install", kind, "--yes", "--binary", executable.path, "--"]
        args.append("--auth")
        args.append(authMode)
        if let port { args.append(contentsOf: ["--port", String(port)]) }
        return try invoke(args, timeout: 90)
    }

    /// Starts without rewriting the login preference (the app exposes that as
    /// its own control).
    public func start() throws -> CommandResult {
        try invoke(["service", "start", kind, "--no-enable"], timeout: 90)
    }

    /// Stops the process while preserving the user's start-at-login choice.
    public func stop() throws -> CommandResult {
        try invoke(["service", "stop", kind, "--keep-enabled"], timeout: 60)
    }

    /// Restarts without changing the login preference or requiring it to be on.
    public func restart() throws -> CommandResult {
        try invoke(["service", "restart", kind, "--no-enable"], timeout: 90)
    }

    public func setAutostart(_ enabled: Bool) throws -> CommandResult {
        try invoke(["service", "autostart", kind, enabled ? "on" : "off"], timeout: 60)
    }

    private struct CapabilityKey: Hashable, Sendable {
        let file: FileIdentity
        let operation: String
    }
    private static let capabilities = FileCheckCache<CapabilityKey, Bool>()

    /// True only when this CLI implements `service <operation>`. CLIs without
    /// the subcommand (0.9.94 included) answer `service <operation> --help`,
    /// and even `service reload web`, with the parent `service` help and exit
    /// 0, so success alone proves nothing. The probe requires the subcommand's
    /// own usage line. Answers are cached until the executable is replaced.
    public func supports(_ operation: String) -> Bool {
        let key = FileIdentity(executable).map { CapabilityKey(file: $0, operation: operation) }
        if let key, let cached = Self.capabilities.value(for: key) { return cached }
        guard let result = try? invoke(["service", operation, "--help"], timeout: 10) else { return false }
        let supported = result.succeeded && Self.usageNamesSubcommand(result.stdout, operation: operation)
        if let key { Self.capabilities.set(supported, for: key) }
        return supported
    }

    /// Matches cobra's `Usage:` section, e.g. `  term-llm service rebind [web|hub] [flags]`.
    static func usageNamesSubcommand(_ help: String, operation: String) -> Bool {
        let lines = help.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let usage = lines.firstIndex(of: "Usage:"), usage + 1 < lines.count else { return false }
        let words = lines[usage + 1].split(separator: " ")
        return words.count >= 3 && words[1] == "service" && words[2] == Substring(operation)
    }

    /// Core restarts a running service and may restore the previous binary, each
    /// step bounded by launchd's exit timeout and a readiness wait. Killing the
    /// CLI mid-rollback would leave the service half-switched, so allow ample time.
    public func rebind(binary: String) throws {
        try requireSuccess(invoke(["service", "rebind", kind, "--binary", binary], timeout: 300))
    }

    public func reload() throws {
        try requireSuccess(invoke(["service", "reload", kind], timeout: 20))
    }

    public func requireSuccess(_ result: CommandResult) throws {
        guard result.succeeded else {
            // Child output is not trusted to be credential-free.
            throw ServiceContractError.commandFailed(status: result.status, message: "The service command failed (exit \(result.status)).")
        }
    }

    public func uninstall() throws -> CommandResult {
        try invoke(["service", "uninstall", kind], timeout: 60)
    }

    /// Reads the managed bearer token. Callers keep it in memory and never log,
    /// persist, or place it in a URL.
    public func token() throws -> String {
        let result = try invoke(["service", "token", kind], timeout: 20)
        guard result.succeeded else {
            // This is the one command whose stdout is the secret. Never fall
            // back to stdout in an error path, even if a future CLI printed the
            // token before failing.
            throw ServiceContractError.tokenUnavailable(Self.tokenFailureMessage(from: result))
        }
        let token = Self.extractToken(result.stdout)
        guard token.count >= 16, !token.contains("\n"), !token.contains("\r") else {
            throw ServiceContractError.tokenUnavailable("the CLI returned no usable token")
        }
        return token
    }

    public func logsFollowCommand() -> String {
        "term-llm service logs \(kind)"
    }

    private func invoke(_ arguments: [String], timeout: TimeInterval) throws -> CommandResult {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ServiceContractError.executableUnavailable(executable.path)
        }
        return try runner.run(executable: executable, arguments: arguments,
                              environment: ["TERM_LLM_NO_PROMPT": "1", "TERM_LLM_SKIP_UPDATE_CHECK": "1"], timeout: timeout)
    }

    public static func message(from result: CommandResult) -> String {
        let raw = result.stderr.isEmpty ? result.stdout : result.stderr
        let line = raw.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .last ?? "term-llm exited with status \(result.status)."
        return String(line.prefix(400))
    }

    /// Error text for `service token` that provably ignores stdout.
    static func tokenFailureMessage(from result: CommandResult) -> String {
        let line = result.stderr.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .last
        if let line, !line.isEmpty {
            return String(line.prefix(400))
        }
        return "term-llm service token exited with status \(result.status)."
    }

    /// Accepts `token: VALUE`, `service token web: VALUE`, or a bare token line.
    /// Only the last non-empty line is considered; nothing is logged.
    static func extractToken(_ output: String) -> String {
        let lines = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let last = lines.last else { return "" }
        if let range = last.range(of: "token:", options: [.caseInsensitive]) {
            return last[range.upperBound...].trimmingCharacters(in: .whitespaces)
        }
        if last.contains(":") {
            return String(last.split(separator: ":", maxSplits: 1).last ?? "").trimmingCharacters(in: .whitespaces)
        }
        return last
    }
}
