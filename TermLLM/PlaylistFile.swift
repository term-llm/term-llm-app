import Foundation

/// The playlists file: a versioned JSON document, written atomically.
///
/// Reading never loses data silently. Readable playlists and songs are kept.
/// Anything that can't be read is left out, but only after a copy of the
/// original file is saved beside it. A file this version can't safely rewrite
/// (from a newer app, or unreadable right now) is opened read-only.
struct PlaylistFile {
    static let formatVersion = 1

    enum Loaded: Equatable {
        /// No file yet.
        case empty
        /// Usable, possibly after recovery. `notice` explains anything set aside.
        case writable([Playlist], notice: String?)
        /// Shown but must not be rewritten.
        case readOnly([Playlist], reason: String)
    }

    let url: URL
    var now: () -> Date = Date.init

    func load() -> Loaded {
        let files = FileManager.default
        guard files.fileExists(atPath: url.path()) else { return .empty }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // Usually data protection before first unlock: the file may be
            // fine, so leave it alone and try again later.
            return .readOnly([], reason: "Saved playlists can't be opened right now (\(error.localizedDescription)). Reopen Music to try again.")
        }

        guard let body = try? Self.decoder.decode(Body.self, from: data), let stored = body.playlists else {
            guard let backup = try? setAside(moving: true) else {
                return .readOnly([], reason: "Saved playlists couldn't be read, and couldn't be set aside safely.")
            }
            return .writable([], notice: "Saved playlists couldn't be read. The file was kept as \(backup) and a new list started.")
        }

        var recovered = Recovery()
        let playlists = recovered.playlists(from: stored)
        if (body.version ?? 1) > Self.formatVersion {
            return .readOnly(playlists, reason: "These playlists were saved by a newer version of the app, so they can't be changed here.")
        }
        guard recovered.droppedPlaylists + recovered.droppedEntries > 0 else { return .writable(playlists, notice: nil) }
        guard let backup = try? setAside(moving: false) else {
            return .readOnly(playlists, reason: "Some saved playlists couldn't be read, and the original file couldn't be backed up.")
        }
        return .writable(playlists, notice: "\(recovered.summary) couldn't be read and \(recovered.droppedPlaylists + recovered.droppedEntries == 1 ? "was" : "were") left out. The original file was kept as \(backup).")
    }

    func write(_ playlists: [Playlist]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try Self.encoder.encode(Stored(version: Self.formatVersion, playlists: playlists))
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Moves or copies the file to `playlists-unreadable-<time>.json` beside it.
    private func setAside(moving: Bool) throws -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stem = "\(url.deletingPathExtension().lastPathComponent)-unreadable-\(formatter.string(from: now()))"
        var backup = url.deletingLastPathComponent().appending(path: "\(stem).json")
        var counter = 2
        while FileManager.default.fileExists(atPath: backup.path()) {
            backup = url.deletingLastPathComponent().appending(path: "\(stem)-\(counter).json")
            counter += 1
        }
        if moving {
            try FileManager.default.moveItem(at: url, to: backup)
        } else {
            try FileManager.default.copyItem(at: url, to: backup)
        }
        return backup.lastPathComponent
    }

    // MARK: - Format

    private struct Stored: Encodable {
        let version: Int
        let playlists: [Playlist]
    }

    /// Lenient read model: one bad playlist or song never hides the rest.
    private struct Body: Decodable {
        let version: Int?
        let playlists: [Lossy<StoredPlaylist>]?
    }

    fileprivate struct StoredPlaylist: Decodable {
        let id: UUID
        let name: String
        let entries: [Lossy<PlaylistEntry>]
        let createdAt: Date
        let updatedAt: Date
    }

    fileprivate struct Lossy<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }

    /// Turns what was readable into playlists that satisfy the store's rules.
    private struct Recovery {
        var droppedPlaylists = 0
        var droppedEntries = 0

        var summary: String {
            [droppedPlaylists > 0 ? "\(droppedPlaylists) playlist\(droppedPlaylists == 1 ? "" : "s")" : nil,
             droppedEntries > 0 ? "\(droppedEntries) song\(droppedEntries == 1 ? "" : "s")" : nil]
                .compactMap { $0 }.joined(separator: " and ")
        }

        mutating func playlists(from stored: [Lossy<StoredPlaylist>]) -> [Playlist] {
            var ids = Set<UUID>()
            var names = Set<String>()
            var result: [Playlist] = []
            for item in stored {
                guard let raw = item.value, ids.insert(raw.id).inserted else {
                    droppedPlaylists += 1
                    continue
                }
                var entryIDs = Set<UUID>()
                let entries: [PlaylistEntry] = raw.entries.compactMap { entry in
                    guard var entry = entry.value else {
                        droppedEntries += 1
                        return nil
                    }
                    // Entry ids must be unique for edits to target one song.
                    if !entryIDs.insert(entry.id).inserted {
                        entry = PlaylistEntry(id: UUID(), track: entry.track, addedAt: entry.addedAt)
                        entryIDs.insert(entry.id)
                    }
                    return entry
                }
                let name = uniqueName(raw.name, taken: &names)
                result.append(Playlist(id: raw.id, name: name, entries: entries,
                                       createdAt: raw.createdAt, updatedAt: raw.updatedAt))
            }
            return result.sorted { $0.updatedAt > $1.updatedAt }
        }

        /// Names must be unique (case-insensitive): agents refer to playlists by name.
        private func uniqueName(_ name: String, taken: inout Set<String>) -> String {
            let base = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : name
            var candidate = base
            var counter = 2
            while taken.contains(candidate.lowercased()) {
                candidate = "\(base) (\(counter))"
                counter += 1
            }
            taken.insert(candidate.lowercased())
            return candidate
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
