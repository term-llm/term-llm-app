import CryptoKit
import Darwin
import Foundation

/// On-disk selection of the `term-llm` executable the companion manages or
/// adopts. A bundled install is copied outside the app so a Terminal invocation
/// keeps working when the GUI is closed or moved. An external (Homebrew,
/// standalone) install is only referenced; the companion never updates it.
public struct CLISelection: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        case bundled
        case external
    }

    public static let schemaVersion = 1

    public var schemaVersion: Int
    public var source: Source
    /// Absolute path to the executable that should be run.
    public var binaryPath: String
    /// Managed install version. Empty when adopted from an external install.
    public var version: String
    /// SHA-256 of the managed binary at install time. Empty for external.
    public var sha256: String
    public var installedAt: Date
    /// Human-readable provenance, e.g. "Homebrew" for `/opt/homebrew/...`.
    public var provenance: String

    public init(schemaVersion: Int = CLISelection.schemaVersion,
                source: Source,
                binaryPath: String,
                version: String,
                sha256: String,
                installedAt: Date = Date(),
                provenance: String) {
        self.schemaVersion = schemaVersion
        self.source = source
        self.binaryPath = binaryPath
        self.version = version
        self.sha256 = sha256
        // Manifests store millisecond precision; normalise so a decoded
        // selection compares equal to the one that was written.
        self.installedAt = Date(timeIntervalSince1970: (installedAt.timeIntervalSince1970 * 1000).rounded() / 1000)
        self.provenance = provenance
    }

    public var binaryURL: URL { URL(fileURLWithPath: binaryPath) }
}

public struct ExternalCLI: Equatable, Sendable {
    public var path: String
    public var resolvedPath: String
    public var version: String
    public var provenance: String

    public init(path: String, resolvedPath: String, version: String, provenance: String) {
        self.path = path
        self.resolvedPath = resolvedPath
        self.version = version
        self.provenance = provenance
    }
}

public enum CLIProvisionerError: Error, LocalizedError, Equatable {
    case payloadMissing(String)
    case payloadInvalid(String)
    case checksumMismatch(expected: String, actual: String)
    case installFailed(String)
    case notInstalled
    case externalMissing(String)
    case notExecutable(String)
    case unsafeLocation(String)

    public var errorDescription: String? {
        switch self {
        case .payloadMissing(let path):
            return "The app does not contain a CLI payload (expected at \(path))."
        case .payloadInvalid(let reason):
            return "The bundled CLI payload is not usable: \(reason)"
        case .checksumMismatch:
            return "The copied CLI payload failed its checksum check; the previous installation was kept."
        case .installFailed(let reason):
            return "Could not install the CLI: \(reason)"
        case .notInstalled:
            return "No managed term-llm CLI is installed."
        case .externalMissing(let path):
            return "The selected external CLI no longer exists at \(path)."
        case .notExecutable(let path):
            return "Not an executable file: \(path)"
        case .unsafeLocation(let path):
            return "Refusing to manage an unexpected location: \(path)"
        }
    }
}

/// Result of exposing the managed binary on `~/.local/bin`. A foreign file is
/// never replaced; callers must show the collision and let the user resolve it.
public enum PATHLinkStatus: Equatable, Sendable {
    case linked(String)
    case alreadyLinked(String)
    case notLinked(String)
    case skippedExternal(String)
    case collision(String)
    case failed(String)
}

public enum CLIProblem: Equatable, Sendable {
    case missingBinary(String)
    case notExecutable(String)
    case checksumMismatch(String)
    case manifestUnreadable(String)

    public var description: String {
        switch self {
        case .missingBinary(let path): return "Selected CLI is missing at \(path)."
        case .notExecutable(let path): return "Selected CLI is not executable: \(path)"
        case .checksumMismatch(let path): return "Managed CLI checksum no longer matches its manifest: \(path)"
        case .manifestUnreadable(let reason): return "The CLI manifest could not be read: \(reason)"
        }
    }
}

/// Owns the stable per-user runtime outside the `.app`. Layout:
///
///     ~/Library/Application Support/TermLLM/
///       install.json          selection + integrity manifest
///       bin/term-llm          managed executable (bundled installs)
///       backups/<stamp>/...   previous managed executable during an update
///       logs/                 optional provisioning logs
public struct CLIProvisioner {
    public static let directoryName = "TermLLM"
    public static let executableName = "term-llm"

    public let home: URL
    public let fileManager: FileManager
    public let runner: CommandRunning

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                fileManager: FileManager = .default,
                runner: CommandRunning = ProcessCommandRunner()) {
        self.home = home
        self.fileManager = fileManager
        self.runner = runner
    }

    public var supportDirectory: URL {
        home.appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    public var binDirectory: URL { supportDirectory.appendingPathComponent("bin", isDirectory: true) }
    public var managedBinary: URL { binDirectory.appendingPathComponent(Self.executableName) }
    public var manifestURL: URL { supportDirectory.appendingPathComponent("install.json") }
    /// Sidecar consumed by `term-llm upgrade`: the core refuses self-upgrade
    /// when this marker sits next to the resolved executable.
    public var managedMarkerURL: URL {
        binDirectory.appendingPathComponent(Self.executableName + ".managed.json")
    }
    public var managedMarkerPresent: Bool {
        fileManager.fileExists(atPath: managedMarkerURL.path)
    }
    static let markerOwner = "term-llm macOS companion"
    public var backupDirectory: URL { supportDirectory.appendingPathComponent("backups", isDirectory: true) }
    public var pathLink: URL {
        home.appendingPathComponent(".local/bin", isDirectory: true)
            .appendingPathComponent(Self.executableName)
    }

    // MARK: - Selection

    public func loadSelection() -> Result<CLISelection?, CLIProvisionerError> {
        guard fileManager.fileExists(atPath: manifestURL.path) else { return .success(nil) }
        do {
            let data = try Data(contentsOf: manifestURL)
            let selection = try Self.decoder.decode(CLISelection.self, from: data)
            guard selection.schemaVersion == CLISelection.schemaVersion else {
                return .failure(.installFailed("Unsupported CLI manifest version \(selection.schemaVersion)."))
            }
            return .success(selection)
        } catch {
            return .failure(.installFailed("The CLI manifest is unreadable: \(error.localizedDescription)"))
        }
    }

    public func problems(in selection: CLISelection) -> [CLIProblem] {
        let url = selection.binaryURL
        guard fileManager.fileExists(atPath: url.path) else {
            return [.missingBinary(url.path)]
        }
        guard fileManager.isExecutableFile(atPath: url.path) else {
            return [.notExecutable(url.path)]
        }
        if selection.source == .bundled,
           !selection.sha256.isEmpty,
           let digest = try? Self.cachedSHA256(of: url),
           digest != selection.sha256 {
            return [.checksumMismatch(url.path)]
        }
        return []
    }

    /// Test-only transaction seam. Production never sets this.
    enum InstallFailurePoint {
        case beforeReplace
        case afterReplace
        case afterMarker
    }
    var failurePoint: InstallFailurePoint?

    /// Installs the app's bundled payload into the managed location.
    ///
    /// The previous executable is *copied* to a backup and the verified staging
    /// file is renamed over the live name, so `term-llm` never disappears
    /// between an old and new version. Marker and manifest are written after
    /// the replace; any failure restores the previous binary bytes and the
    /// previous marker/manifest (or removes them for a first install). This is
    /// what makes the operation transactional rather than best-effort.
    @discardableResult
    public func installBundled(payload: URL,
                               version: String,
                               expectedSHA256: String? = nil) throws -> CLISelection {
        // Serialise the whole promotion across app instances. The managed
        // directory is user-owned, so an advisory lock file is sufficient; it
        // is never used to infer ownership.
        try withInstallLock {
            try installBundledLocked(payload: payload, version: version, expectedSHA256: expectedSHA256)
        }
    }

    private func installBundledLocked(payload: URL,
                                      version: String,
                                      expectedSHA256: String?) throws -> CLISelection {
        guard fileManager.fileExists(atPath: payload.path) else {
            throw CLIProvisionerError.payloadMissing(payload.path)
        }
        let payloadDigest: String
        do {
            payloadDigest = try Self.sha256(of: payload)
        } catch {
            throw CLIProvisionerError.payloadInvalid(error.localizedDescription)
        }
        if let expectedSHA256, !expectedSHA256.isEmpty, expectedSHA256.lowercased() != payloadDigest {
            throw CLIProvisionerError.checksumMismatch(expected: expectedSHA256, actual: payloadDigest)
        }
        let attributes = (try? fileManager.attributesOfItem(atPath: payload.path)) ?? [:]
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else { throw CLIProvisionerError.payloadInvalid("the file is empty") }

        do {
            try fileManager.createDirectory(at: binDirectory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o755])
        } catch {
            throw CLIProvisionerError.installFailed(error.localizedDescription)
        }

        let staging = binDirectory.appendingPathComponent(".\(Self.executableName).staging-\(UUID().uuidString)")
        let backupBinary = backupDirectory
            .appendingPathComponent(Self.stamp())
            .appendingPathComponent(Self.executableName)
        let hadPrevious = fileManager.fileExists(atPath: managedBinary.path)
        let previousManifest = try? Data(contentsOf: manifestURL)
        let previousMarker = try? Data(contentsOf: managedMarkerURL)

        do {
            try fileManager.copyItem(at: payload, to: staging)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path)
            let stagedDigest = try Self.sha256(of: staging)
            guard stagedDigest == payloadDigest else {
                try? fileManager.removeItem(at: staging)
                throw CLIProvisionerError.checksumMismatch(expected: payloadDigest, actual: stagedDigest)
            }
            if hadPrevious {
                try fileManager.createDirectory(at: backupBinary.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
                // Copy, never move: the live name must stay resolvable.
                try fileManager.copyItem(at: managedBinary, to: backupBinary)
            }
        } catch let error as CLIProvisionerError {
            try? fileManager.removeItem(at: staging)
            try? fileManager.removeItem(at: backupBinary.deletingLastPathComponent())
            throw error
        } catch {
            try? fileManager.removeItem(at: staging)
            try? fileManager.removeItem(at: backupBinary.deletingLastPathComponent())
            throw CLIProvisionerError.installFailed(error.localizedDescription)
        }

        do {
            try failIfNeeded(.beforeReplace)
            try Self.replaceAtomically(staging, managedBinary)
        } catch {
            try? fileManager.removeItem(at: staging)
            if let typed = error as? CLIProvisionerError { throw typed }
            throw CLIProvisionerError.installFailed(error.localizedDescription)
        }

        let selection = CLISelection(source: .bundled,
                                     binaryPath: managedBinary.path,
                                     version: version,
                                     sha256: payloadDigest,
                                     provenance: "Bundled with the app")
        do {
            try failIfNeeded(.afterReplace)
            try writeManagedMarker()
            try failIfNeeded(.afterMarker)
            try writeManifest(selection)
        } catch {
            // The update is only complete when marker and manifest name it.
            // Restore every previous artifact, not just the executable.
            if hadPrevious, fileManager.fileExists(atPath: backupBinary.path) {
                try? Self.replaceAtomically(backupBinary, managedBinary)
            } else {
                try? fileManager.removeItem(at: managedBinary)
            }
            restore(previousMarker, at: managedMarkerURL)
            restore(previousManifest, at: manifestURL)
            throw CLIProvisionerError.installFailed("Could not finalise the CLI update: \(error.localizedDescription)")
        }
        pruneBackups(keeping: 3)
        return selection
    }

    private func failIfNeeded(_ point: InstallFailurePoint) throws {
        guard let failurePoint, failurePoint == point else { return }
        throw CLIProvisionerError.installFailed("injected failure at \(point)")
    }

    private func withInstallLock<T>(_ body: () throws -> T) throws -> T {
        do {
            try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o755])
        } catch {
            throw CLIProvisionerError.installFailed("could not create the managed directory: \(error.localizedDescription)")
        }
        let lockPath = supportDirectory.appendingPathComponent(".install.lock").path
        let descriptor = open(lockPath, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else {
            throw CLIProvisionerError.installFailed("could not open the install lock")
        }
        defer {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw CLIProvisionerError.installFailed("could not acquire the install lock")
        }
        return try body()
    }

    /// POSIX rename replaces the destination name atomically on the same
    /// volume. `FileManager.moveItem` refuses an existing destination and a
    /// move-then-copy sequence leaves a window with no executable.
    static func replaceAtomically(_ source: URL, _ destination: URL) throws {
        if rename(source.path, destination.path) != 0 {
            throw CLIProvisionerError.installFailed("atomic replace failed: \(String(cString: strerror(errno)))")
        }
    }

    private func restore(_ data: Data?, at url: URL) {
        if let data {
            try? data.write(to: url, options: .atomic)
            try? fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        } else {
            try? fileManager.removeItem(at: url)
        }
    }

    /// Records an existing external installation without copying or modifying it.
    public func adoptExternal(_ external: ExternalCLI) throws -> CLISelection {
        let url = URL(fileURLWithPath: external.path)
        guard fileManager.fileExists(atPath: url.path) else {
            throw CLIProvisionerError.externalMissing(external.path)
        }
        guard fileManager.isExecutableFile(atPath: url.path) else {
            throw CLIProvisionerError.notExecutable(external.path)
        }
        let selection = CLISelection(source: .external,
                                     binaryPath: external.path,
                                     version: external.version,
                                     sha256: "",
                                     provenance: external.provenance)
        try writeManifest(selection)
        return selection
    }

    public func forgetSelection() throws {
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw CLIProvisionerError.notInstalled
        }
        try fileManager.removeItem(at: manifestURL)
    }

    private func writeManifest(_ selection: CLISelection) throws {
        try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o755])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(CLIProvisioner.isoFormatter.string(from: date))
        }
        let data = try encoder.encode(selection)
        try data.write(to: manifestURL, options: [.atomic])
        try? fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: manifestURL.path)
    }

    /// Rewrites the ownership marker for an already-installed managed binary.
    /// This is self-healing for app updates and for users who deleted the
    /// sidecar; it never creates one for an external installation.
    @discardableResult
    public func ensureManagedMarker(for selection: CLISelection) -> Bool {
        guard selection.source == .bundled,
              selection.binaryPath == managedBinary.path,
              fileManager.isExecutableFile(atPath: managedBinary.path) else { return false }
        if managedMarkerPresent { return true }
        return (try? writeManagedMarker()) != nil
    }

    private func writeManagedMarker() throws {
        struct Marker: Encodable {
            let schemaVersion: Int
            let owner: String
            let updateHint: String

            enum CodingKeys: String, CodingKey {
                case schemaVersion = "schema_version"
                case owner
                case updateHint = "update_hint"
            }
        }
        let marker = Marker(schemaVersion: 1,
                            owner: Self.markerOwner,
                            updateHint: "Update it from the term-llm macOS app, which verifies the payload and can roll back.")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try fileManager.createDirectory(at: binDirectory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o755])
        try encoder.encode(marker).write(to: managedMarkerURL, options: [.atomic])
        try? fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: managedMarkerURL.path)
    }

    // MARK: - External detection

    /// Finds `term-llm` executables on the user's PATH and the common Homebrew
    /// prefixes. The managed binary is excluded. Nothing is executed unless the
    /// caller asked for versions (still bounded and non-interactive).
    public func detectExternal(includeVersions: Bool = true,
                               searchDirectories: [String]? = nil) -> [ExternalCLI] {
        var directories: [String] = []
        if let searchDirectories {
            directories.append(contentsOf: searchDirectories)
        } else {
            let env = ProcessInfo.processInfo.environment
            for key in ["PATH", "TERM_LLM_INSTALL_DIR"] {
                guard let value = env[key] else { continue }
                directories.append(contentsOf: value.split(separator: ":").map(String.init))
            }
            directories.append(contentsOf: [
                "\(home.path)/.local/bin",
                "/opt/homebrew/bin",
                "/usr/local/bin",
                "/usr/bin",
            ])
        }
        var seen = Set<String>()
        var results: [ExternalCLI] = []
        for directory in directories where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(Self.executableName)
            let standardised = candidate.standardizedFileURL
            guard seen.insert(standardised.path).inserted else { continue }
            // The standardised PATH entry is our own link; report it as managed,
            // not as an external installation.
            if standardised.path == pathLink.standardizedFileURL.path { continue }
            if standardised.path == managedBinary.standardizedFileURL.path { continue }
            guard fileManager.isExecutableFile(atPath: candidate.path) else { continue }
            let resolved = candidate.resolvingSymlinksInPath()
            if resolved.path == managedBinary.standardizedFileURL.path { continue }
            var version = ""
            if includeVersions,
               let probe = try? runner.run(executable: candidate, arguments: ["--version"],
                                           environment: nil, timeout: 4) {
                version = Self.firstLine(probe.stdout.isEmpty ? probe.stderr : probe.stdout)
            }
            results.append(ExternalCLI(path: candidate.path,
                                       resolvedPath: resolved.path,
                                       version: version,
                                       provenance: Self.provenance(for: resolved.path)))
        }
        return results
    }

    static func provenance(for resolvedPath: String) -> String {
        if resolvedPath.hasPrefix("/opt/homebrew/") || resolvedPath.hasPrefix("/usr/local/Cellar/") {
            return "Homebrew"
        }
        if resolvedPath.contains("/Cellar/") { return "Homebrew" }
        if resolvedPath.hasPrefix("/usr/local/bin/") { return "Local install" }
        return "Existing install"
    }

    // MARK: - PATH link

    /// Exposes a *managed* binary at `~/.local/bin/term-llm`. An external
    /// installation is left alone: its package manager owns that name.
    public func syncPATHLink(for selection: CLISelection) -> PATHLinkStatus {
        if selection.source == .external {
            return .skippedExternal("The external installation already provides its own command.")
        }
        let managed = managedBinary.standardizedFileURL
        let link = pathLink
        do {
            if fileManager.fileExists(atPath: link.path) || (try? link.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                let destination = (try? fileManager.destinationOfSymbolicLink(atPath: link.path))
                    .map { URL(fileURLWithPath: $0, relativeTo: link.deletingLastPathComponent()).standardizedFileURL }
                if let destination, destination.path == managed.path {
                    return .alreadyLinked(link.path)
                }
                return .collision(link.path)
            }
            try fileManager.createDirectory(at: link.deletingLastPathComponent(),
                                            withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o755])
            try fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: managed.path)
            return .linked(link.path)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Read-only PATH state for display. Unlike `syncPATHLink`, this never
    /// creates a link, so launching the app does not mutate the user's shell
    /// environment before they choose an install action.
    public func inspectPATHLink(for selection: CLISelection) -> PATHLinkStatus {
        if selection.source == .external {
            return .skippedExternal("The external installation already provides its own command.")
        }
        let managed = managedBinary.standardizedFileURL
        guard fileManager.fileExists(atPath: pathLink.path)
                || (try? pathLink.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true else {
            return .notLinked(pathLink.path)
        }
        let destination = (try? fileManager.destinationOfSymbolicLink(atPath: pathLink.path))
            .map { URL(fileURLWithPath: $0, relativeTo: pathLink.deletingLastPathComponent()).standardizedFileURL }
        if let destination, destination.path == managed.path {
            return .alreadyLinked(pathLink.path)
        }
        return .collision(pathLink.path)
    }

    public func removePATHLink() -> Bool {
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: pathLink.path) else {
            return false
        }
        let resolved = URL(fileURLWithPath: destination, relativeTo: pathLink.deletingLastPathComponent())
            .standardizedFileURL
        guard resolved.path == managedBinary.standardizedFileURL.path else { return false }
        return (try? fileManager.removeItem(at: pathLink)) != nil
    }

    // MARK: - Uninstall (GUI remains a separate decision)

    /// Removes only companion-managed CLI files. User data and the core
    /// service are untouched by design.
    @discardableResult
    public func removeManagedInstall() throws -> Bool {
        var removed = false
        if fileManager.fileExists(atPath: managedBinary.path) {
            try fileManager.removeItem(at: managedBinary)
            removed = true
        }
        if fileManager.fileExists(atPath: manifestURL.path) {
            try fileManager.removeItem(at: manifestURL)
            removed = true
        }
        if fileManager.fileExists(atPath: managedMarkerURL.path) {
            try fileManager.removeItem(at: managedMarkerURL)
            removed = true
        }
        if fileManager.fileExists(atPath: backupDirectory.path) {
            try fileManager.removeItem(at: backupDirectory)
            removed = true
        }
        _ = removePATHLink()
        return removed
    }

    // MARK: - Helpers

    private func pruneBackups(keeping count: Int) {
        guard let entries = try? fileManager.contentsOfDirectory(at: backupDirectory,
                                                                 includingPropertiesForKeys: [.contentModificationDateKey],
                                                                 options: [.skipsHiddenFiles]) else { return }
        let sorted = entries.sorted { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return l > r
        }
        for entry in sorted.dropFirst(count) {
            try? fileManager.removeItem(at: entry)
        }
    }

    /// Digest cache for status polling. Keyed by path, size and modification
    /// time; installs always hash the fresh payload directly. This keeps a
    /// 4-second UI refresh from re-reading a multi-megabyte binary forever.
    private final class ChecksumCache: @unchecked Sendable {
        struct Entry {
            let size: Int
            let modified: TimeInterval
            let digest: String
        }
        static let shared = ChecksumCache()
        private let lock = NSLock()
        private var entries: [String: Entry] = [:]

        func digest(for url: URL, compute: () throws -> String) rethrows -> String {
            let path = url.standardizedFileURL.path
            let attributes = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
            let size = (attributes[.size] as? NSNumber)?.intValue ?? -1
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            lock.lock()
            if let entry = entries[path], entry.size == size, entry.modified == modified {
                lock.unlock()
                return entry.digest
            }
            lock.unlock()
            let digest = try compute()
            lock.lock()
            entries[path] = Entry(size: size, modified: modified, digest: digest)
            lock.unlock()
            return digest
        }
    }

    static func cachedSHA256(of url: URL) throws -> String {
        try ChecksumCache.shared.digest(for: url) { try sha256(of: url) }
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return String(line.prefix(120))
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: Date()) + "-" + UUID().uuidString.prefix(8)
    }

    static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = isoFormatter.date(from: text) { return date }
            if let date = ISO8601DateFormatter().date(from: text) { return date }
            throw DecodingError.dataCorruptedError(in: container,
                                                   debugDescription: "Unreadable install timestamp")
        }
        return decoder
    }
}
