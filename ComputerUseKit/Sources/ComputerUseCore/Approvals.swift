import Darwin
import Foundation

/// Persistence shared with the main app's Computer Use window.
/// approvals.json is UTF-8 JSON: {"always": {"com.example.App": "2026-11-10T08:00:00Z"},
/// "modified": "2026-11-10T08:00:00Z"}. Keys are bundle IDs, values UTC ISO-8601
/// dates. Removing a key removes that persistent grant. Read on every check so
/// edits take effect immediately. Atomic replacement, directory 0700/file 0600.
public final class ApprovalStore {
    public let file: URL
    public init(directory: URL = Paths.stateDirectory()) {
        file = directory.appendingPathComponent("approvals.json")
    }
    public func always() -> [String: String] {
        guard let data = try? Data(contentsOf: file),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let always = object["always"] as? [String: String]
        else { return [:] }
        return always
    }
    public func save(bundleID: String, now: Date = Date()) throws {
        // A pid comes back as another program: such a yes is never written down.
        guard !bundleID.hasPrefix("#pid:") else { return }
        let date = ISO8601DateFormatter().string(from: now)
        var entries = always()
        entries[bundleID] = date
        try Self.write(["always": entries, "modified": date], to: file)
    }
    /// Take back an "Always allow" (the main app's Computer Use window). The app is
    /// asked about again at its next first use in a session.
    public func remove(bundleID: String, now: Date = Date()) throws {
        var entries = always()
        guard entries.removeValue(forKey: bundleID) != nil else { return }
        try Self.write(["always": entries, "modified": ISO8601DateFormatter().string(from: now)], to: file)
    }
    public var sessionsFile: URL {
        file.deletingLastPathComponent().appendingPathComponent("sessions.json")
    }
    /// Session grants are pairs [agentKey, bundleID]. Numeric process keys must
    /// be checked against the pid's start time by the helper, never just its pid.
    public func sessions(alive: (String) -> Bool) -> Set<SessionGrant> {
        guard let data = try? Data(contentsOf: sessionsFile),
            let rows = try? JSONSerialization.jsonObject(with: data) as? [[String]]
        else { return [] }
        return Set(
            rows.compactMap { row in
                row.count == 2 && alive(row[0])
                    ? SessionGrant(agent: row[0], bundleID: row[1]) : nil
            })
    }
    public struct SessionGrant: Hashable {
        public let agent: String, bundleID: String
        public init(agent: String, bundleID: String) {
            self.agent = agent
            self.bundleID = bundleID
        }
    }
    public func saveSession(agent: String, bundleID: String, alive: (String) -> Bool) throws {
        var grants = sessions(alive: alive)
        grants.insert(SessionGrant(agent: agent, bundleID: bundleID))
        let rows = grants.map { [$0.agent, $0.bundleID] }.sorted {
            $0.lexicographicallyPrecedes($1)
        }
        try Self.write(rows, to: sessionsFile)
    }
    public static func write(_ object: Any, to file: URL) throws {
        let folder = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Unique scratch files avoid collisions and never follow an existing .tmp symlink.
        let scratch = folder.appendingPathComponent(
            ".\(file.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(scratch.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer {
            close(fd)
            try? FileManager.default.removeItem(at: scratch)
        }
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += n
            }
        }
        guard fsync(fd) == 0, rename(scratch.path, file.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
