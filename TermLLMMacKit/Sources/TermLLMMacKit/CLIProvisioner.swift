import CryptoKit
import Darwin
import Foundation
import os

/// Release manifest. Legacy sources are decoded for migration only.
public struct CLISelection: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        case release
        case bundled // schema 1 only
        case external
    }

    public static let schemaVersion = 2

    public var schemaVersion: Int
    public var source: Source
    /// Managed path for releases; display-only legacy path for schema 1.
    public var binaryPath: String
    /// Release version. Legacy bundled versions are not trusted.
    public var version: String
    /// SHA-256 of the managed binary at install time. Empty for external.
    public var sha256: String
    public var installedAt: Date
    /// Official release URL (legacy manifests may carry a human-readable label).
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

public enum CLIProvisionerError: Error, LocalizedError, Equatable {
    case candidateMissing(String)
    case candidateInvalid(String)
    case checksumMismatch(expected: String, actual: String)
    case installFailed(String)
    case notInstalled
    case notExecutable(String)
    case unsafeLocation(String)

    public var errorDescription: String? {
        switch self {
        case .candidateMissing(let path):
            return "The verified candidate is missing (expected at \(path))."
        case .candidateInvalid(let reason):
            return "The CLI candidate is not usable: \(reason)"
        case .checksumMismatch:
            return "The copied CLI candidate failed its checksum check; the previous installation was kept."
        case .installFailed(let reason):
            return "Could not install the CLI: \(reason)"
        case .notInstalled:
            return "No managed term-llm CLI is installed."
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

/// Owns the stable per-user runtime outside the `.app`, next to term-llm's
/// own settings so it is in the same place on every OS. Layout:
///
///     ~/.config/term-llm/app/
///       install.json          selection + integrity manifest
///       bin/term-llm          managed executable (signed releases)
///       backups/<stamp>/...   previous managed executable during an update
///       logs/                 optional provisioning logs
public struct CLIProvisioner: Sendable {
    public static let executableName = "term-llm"

    public let home: URL
    /// Foundation documents the shared manager as thread-safe. Resolve it at the
    /// operation boundary rather than storing an arbitrary manager whose delegate
    /// or subclass may have unsynchronized state.
    public var fileManager: FileManager { .default }
    public let runner: CommandRunning

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                runner: CommandRunning = ProcessCommandRunner()) {
        self.home = home
        self.runner = runner
    }

    /// Fixed under `home`, not `$XDG_CONFIG_HOME`: GUI apps don't see shell
    /// variables, and tests must never resolve to the developer's real folder.
    public var supportDirectory: URL {
        home.appendingPathComponent(".config/term-llm/app", isDirectory: true)
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
    static let markerOwner = "the term-llm app"
    static let markerBundleID = "com.termllm.app"
    var markerUpdateHint: String {
        "Update it from the term-llm app. If that app is no longer installed, delete \(managedMarkerURL.path) so `term-llm upgrade` can manage this copy."
    }

    /// `term-llm upgrade` shows the marker's owner and hint when it refuses to
    /// update this copy. Rewords an existing marker of ours left by an older
    /// app; never creates one or changes ownership. Skips while an install runs.
    public func refreshManagedMarkerWording() throws {
        try requireManagementEnabled()
        func outdated() -> Bool {
            guard let data = try? Data(contentsOf: managedMarkerURL),
                  let marker = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  marker["app_bundle_id"] as? String == Self.markerBundleID else { return false }
            return marker["owner"] as? String != Self.markerOwner || marker["update_hint"] as? String != markerUpdateHint
        }
        guard outdated() else { return }
        try withInstallLock(waiting: false) {
            if outdated() { try writeManagedMarker() }
        }
    }
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
            var selection = try Self.decoder.decode(CLISelection.self, from: data)
            guard [1, CLISelection.schemaVersion].contains(selection.schemaVersion) else {
                return .failure(.installFailed("Unsupported CLI manifest version \(selection.schemaVersion)."))
            }
            guard (selection.schemaVersion == 1 && selection.source != .release) ||
                    (selection.schemaVersion == 2 && selection.source == .release) else {
                return .failure(.installFailed("CLI manifest source does not match its schema."))
            }
            if selection.schemaVersion == 1 && selection.source == .bundled { selection.version = "" }
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
        if selection.source != .external,
           !selection.sha256.isEmpty,
           let digest = try? Self.cachedSHA256(of: url),
           digest != selection.sha256 {
            return [.checksumMismatch(url.path)]
        }
        return []
    }

    /// Test-only transaction seam. Production never sets this.
    enum InstallFailurePoint: Sendable {
        case beforeReplace
        case afterReplace
        case afterMarker
    }
    var failurePoint: InstallFailurePoint?

    /// Promotes an already signature-verified release candidate into the managed location.
    ///
    /// The previous executable is *copied* to a backup and the verified staging
    /// file is renamed over the live name, so `term-llm` never disappears
    /// between an old and new version. Marker and manifest are written after
    /// the replace; any failure restores the previous binary bytes and the
    /// previous marker/manifest (or removes them for a first install). This is
    /// what makes the operation transactional rather than best-effort.
    @discardableResult
    public func installVerified(binary candidate: URL,
                                version: String,
                                sha256 expectedSHA256: String,
                                provenance: String) throws -> CLISelection {
        // Serialise the whole promotion across app instances. The managed
        // directory is user-owned, so an advisory lock file is sufficient; it
        // is never used to infer ownership.
        try requireManagementEnabled()
        return try withInstallLock {
            try installVerifiedLocked(candidate: candidate, version: version, expectedSHA256: expectedSHA256, provenance: provenance)
        }
    }

    private func installVerifiedLocked(candidate: URL,
                                      version: String,
                                      expectedSHA256: String, provenance: String,
                                      restoring: CLISelection? = nil, marker: Data? = nil) throws -> CLISelection {
        guard fileManager.fileExists(atPath: candidate.path) else {
            throw CLIProvisionerError.candidateMissing(candidate.path)
        }
        let candidateDigest: String
        do {
            candidateDigest = try Self.sha256(of: candidate)
        } catch {
            throw CLIProvisionerError.candidateInvalid(error.localizedDescription)
        }
        if expectedSHA256.lowercased() != candidateDigest {
            throw CLIProvisionerError.checksumMismatch(expected: expectedSHA256, actual: candidateDigest)
        }
        var info = stat()
        guard lstat(candidate.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw CLIProvisionerError.candidateInvalid("not a regular file") }
        let attributes = (try? fileManager.attributesOfItem(atPath: candidate.path)) ?? [:]
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else { throw CLIProvisionerError.candidateInvalid("the file is empty") }

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
            try fileManager.copyItem(at: candidate, to: staging)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path)
            let stagedDigest = try Self.sha256(of: staging)
            guard stagedDigest == candidateDigest else {
                try? fileManager.removeItem(at: staging)
                throw CLIProvisionerError.checksumMismatch(expected: candidateDigest, actual: stagedDigest)
            }
            if hadPrevious {
                try fileManager.createDirectory(at: backupBinary.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
                // Copy, never move: the live name must stay resolvable.
                try fileManager.copyItem(at: managedBinary, to: backupBinary)
                if let previousManifest { try previousManifest.write(to: backupBinary.deletingLastPathComponent().appendingPathComponent("install.json")) }
                if let previousMarker { try previousMarker.write(to: backupBinary.deletingLastPathComponent().appendingPathComponent("marker.json")) }
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
            if let previousManifest,
               let previous = try? Self.decoder.decode(CLISelection.self, from: previousManifest), previous.source == .external {
                try previousManifest.write(to: supportDirectory.appendingPathComponent("legacy-selection.json"), options: .atomic)
            }
            try failIfNeeded(.beforeReplace)
            try Self.replaceAtomically(staging, managedBinary)
        } catch {
            try? fileManager.removeItem(at: staging)
            try? fileManager.removeItem(at: backupBinary.deletingLastPathComponent())
            if let typed = error as? CLIProvisionerError { throw typed }
            throw CLIProvisionerError.installFailed(error.localizedDescription)
        }

        let selection = restoring ?? CLISelection(source: .release,
                                     binaryPath: managedBinary.path,
                                     version: version,
                                     sha256: candidateDigest,
                                     provenance: provenance)
        do {
            try failIfNeeded(.afterReplace)
            if let marker { try marker.write(to: managedMarkerURL, options: .atomic) }
            else { try writeManagedMarker() }
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
            if !fileManager.fileExists(atPath: backupBinary.path) {
                try? fileManager.removeItem(at: backupBinary.deletingLastPathComponent())
            }
            throw CLIProvisionerError.installFailed("Could not finalise the CLI update: \(error.localizedDescription)")
        }
        pruneBackups(keeping: 3)
        return selection
    }

    private func failIfNeeded(_ point: InstallFailurePoint) throws {
        guard let failurePoint, failurePoint == point else { return }
        throw CLIProvisionerError.installFailed("injected failure at \(point)")
    }

    private func withInstallLock<T>(waiting: Bool = true, _ body: () throws -> T) throws -> T {
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
        guard flock(descriptor, waiting ? LOCK_EX : LOCK_EX | LOCK_NB) == 0 else {
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

    private func writeManagedMarker() throws {
        struct Marker: Encodable {
            let schemaVersion: Int
            let owner: String
            let appBundleID: String
            let updateHint: String

            enum CodingKeys: String, CodingKey {
                case schemaVersion = "schema_version"
                case owner
                case appBundleID = "app_bundle_id"
                case updateHint = "update_hint"
            }
        }
        let marker = Marker(schemaVersion: 1,
                            owner: Self.markerOwner,
                            appBundleID: Self.markerBundleID,
                            updateHint: markerUpdateHint)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try fileManager.createDirectory(at: binDirectory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o755])
        try encoder.encode(marker).write(to: managedMarkerURL, options: [.atomic])
        try? fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: managedMarkerURL.path)
    }

    // MARK: - PATH link

    /// Exposes a *managed* binary at `~/.local/bin/term-llm`. An external
    /// installation is left alone: its package manager owns that name.
    public func syncPATHLink(for selection: CLISelection) -> PATHLinkStatus {
        if selection.source != .release || (try? requireManagementEnabled()) == nil {
            return .notLinked(pathLink.path)
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
        if selection.source != .release || (try? requireManagementEnabled()) == nil {
            return .notLinked(pathLink.path)
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
        guard (try? requireManagementEnabled()) != nil else { return false }
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
        try requireManagementEnabled()
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
        for name in ["staging", "update-state.json"] {
            let url = supportDirectory.appendingPathComponent(name)
            if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
        }
        _ = removePATHLink()
        return removed
    }

    public func requireManagementEnabled() throws {
        // Existence, not successful decode: a corrupt developer setting fails closed.
        guard !fileManager.fileExists(atPath: supportDirectory.appendingPathComponent("developer-mode.json").path) else {
            throw CLIProvisionerError.installFailed("Leave Developer Mode before managing term-llm.")
        }
    }

    public func handOver() throws {
        try requireManagementEnabled()
        try withInstallLock {
            for url in [managedMarkerURL, manifestURL, supportDirectory.appendingPathComponent("update-state.json")] {
                if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
            }
        }
    }

    @discardableResult
    public func rollbackToPrevious() throws -> CLISelection {
        try requireManagementEnabled()
        return try withInstallLock {
            let entries = try fileManager.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: [.creationDateKey])
                .sorted {
                    let l = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                    let r = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                    return l == r ? $0.lastPathComponent > $1.lastPathComponent : l > r
                }
            guard let backup = entries.first(where: {
                fileManager.fileExists(atPath: $0.appendingPathComponent("install.json").path) &&
                fileManager.fileExists(atPath: $0.appendingPathComponent(Self.executableName).path) &&
                fileManager.fileExists(atPath: $0.appendingPathComponent("marker.json").path)
            }) else {
                throw CLIProvisionerError.notInstalled
            }
            let binary = backup.appendingPathComponent(Self.executableName)
            let manifest = try Data(contentsOf: backup.appendingPathComponent("install.json"))
            let selection = try Self.decoder.decode(CLISelection.self, from: manifest)
            guard try Self.sha256(of: binary) == selection.sha256 else {
                throw CLIProvisionerError.installFailed("The backup checksum does not match its manifest.")
            }
            // Promotion has the same rollback semantics as installation. Restore
            // the matching historical metadata only after the binary transaction.
            let marker = try Data(contentsOf: backup.appendingPathComponent("marker.json"))
            let restored = try installVerifiedLocked(candidate: binary, version: selection.version,
                                                     expectedSHA256: selection.sha256, provenance: selection.provenance,
                                                     restoring: selection, marker: marker)
            // Consume the restored backup; a later rollback must not select it again.
            try? fileManager.removeItem(at: backup)
            return restored
        }
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
    /// time; installs always hash the fresh candidate directly. This keeps a
    /// 4-second UI refresh from re-reading a multi-megabyte binary forever.
    private final class ChecksumCache: Sendable {
        struct Entry: Sendable {
            let size: Int
            let modified: TimeInterval
            let digest: String
        }
        static let shared = ChecksumCache()
        private let entries = OSAllocatedUnfairLock<[String: Entry]>(initialState: [:])

        func digest(for url: URL, compute: () throws -> String) rethrows -> String {
            let path = url.standardizedFileURL.path
            let attributes = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
            let size = (attributes[.size] as? NSNumber)?.intValue ?? -1
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            if let entry = entries.withLock({ $0[path] }), entry.size == size, entry.modified == modified {
                return entry.digest
            }
            let digest = try compute()
            entries.withLock { $0[path] = Entry(size: size, modified: modified, digest: digest) }
            return digest
        }
    }

    static func cachedSHA256(of url: URL) throws -> String {
        try ChecksumCache.shared.digest(for: url) { try sha256(of: url) }
    }

    public static func sha256(of url: URL) throws -> String {
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

    /// A new formatter per use: ISO8601DateFormatter is not Sendable, and the
    /// manifest is only encoded or decoded on install and status reads.
    static var isoFormatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

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
