import Foundation
import Observation

/// Playlists kept on this device, shared by the Music screen and the agent's
/// tools. Saved by `PlaylistFile` after every change; memory never runs ahead
/// of disk.
@MainActor
@Observable
final class PlaylistStore {
    /// Most recently changed first.
    private(set) var playlists: [Playlist] = []
    /// One-time explanation of anything set aside while loading.
    private(set) var notice: String?
    /// Set when the saved playlists must not be rewritten; changes are refused.
    private(set) var readOnlyReason: String?

    @ObservationIgnored private let file: PlaylistFile
    @ObservationIgnored private let now: () -> Date

    init(fileURL: URL = PlaylistStore.defaultFileURL, now: @escaping () -> Date = Date.init) {
        self.file = PlaylistFile(url: fileURL, now: now)
        self.now = now
        load()
    }

    /// Retries after the file couldn't be opened (e.g. before first unlock).
    func reloadIfReadOnly() {
        if readOnlyReason != nil { load() }
    }

    func dismissNotice() {
        notice = nil
    }

    nonisolated static var defaultFileURL: URL {
        URL.applicationSupportDirectory.appending(path: "Music/playlists.json")
    }

    func playlist(id: UUID) -> Playlist? {
        playlists.first { $0.id == id }
    }

    /// Finds a playlist by id or (case-insensitive) name; agents use both.
    func resolve(_ reference: String) throws -> Playlist {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: trimmed), let playlist = playlist(id: id) { return playlist }
        if let playlist = playlists.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return playlist
        }
        throw notFound(trimmed)
    }

    @discardableResult
    func create(name: String, tracks: [MusicTrack] = []) throws -> Playlist {
        let name = try validName(name, excluding: nil)
        let created = now()
        let playlist = Playlist(id: UUID(), name: name, entries: entries(for: tracks, at: created),
                                createdAt: created, updatedAt: created)
        try commit([playlist] + playlists)
        return playlist
    }

    func rename(_ id: UUID, to name: String) throws {
        let name = try validName(name, excluding: id)
        try update(id) { $0.name = name }
    }

    func delete(_ id: UUID) throws {
        guard playlist(id: id) != nil else { throw notFound(id.uuidString) }
        try commit(playlists.filter { $0.id != id })
    }

    /// Adds tracks at `position` (default: the end) and returns the new entries.
    @discardableResult
    func add(_ tracks: [MusicTrack], to id: UUID, at position: Int? = nil) throws -> [PlaylistEntry] {
        let added = entries(for: tracks, at: now())
        try update(id) { playlist in
            let index = max(0, min(position ?? playlist.entries.count, playlist.entries.count))
            playlist.entries.insert(contentsOf: added, at: index)
        }
        return added
    }

    func remove(entries entryIDs: Set<UUID>, from id: UUID) throws {
        try update(id) { playlist in
            let missing = entryIDs.subtracting(playlist.entries.map(\.id))
            guard missing.isEmpty else {
                throw MusicError.unknownEntries(missing.map(\.uuidString).sorted(), playlist: playlist.name)
            }
            playlist.entries.removeAll { entryIDs.contains($0.id) }
        }
    }

    /// Drag-to-reorder from a list.
    func move(in id: UUID, from source: IndexSet, to destination: Int) throws {
        try update(id) { $0.entries.move(fromOffsets: source, toOffset: destination) }
    }

    /// Replaces the order with `entryIDs`, which must list every entry once.
    func reorder(_ id: UUID, entryIDs: [UUID]) throws {
        try update(id) { playlist in
            let byID = Dictionary(uniqueKeysWithValues: playlist.entries.map { ($0.id, $0) })
            let invalid = MusicError.invalidOrder(playlist: playlist.name, expected: byID.count)
            guard entryIDs.count == byID.count, Set(entryIDs).count == entryIDs.count else { throw invalid }
            playlist.entries = try entryIDs.map { entryID in
                guard let entry = byID[entryID] else { throw invalid }
                return entry
            }
        }
    }

    // MARK: - Private

    private func update(_ id: UUID, _ change: (inout Playlist) throws -> Void) throws {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { throw notFound(id.uuidString) }
        var playlist = playlists[index]
        try change(&playlist)
        playlist.updatedAt = now()
        var next = playlists
        next.remove(at: index)
        try commit([playlist] + next)
    }

    /// Writes `next`, then publishes it: memory never runs ahead of disk.
    private func commit(_ next: [Playlist]) throws {
        if let readOnlyReason { throw MusicError.storageUnavailable(readOnlyReason) }
        try file.write(next)
        playlists = next
    }

    private func notFound(_ reference: String) -> MusicError {
        .playlistNotFound(reference, available: playlists.map(\.name))
    }

    private func validName(_ name: String, excluding id: UUID?) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MusicError.nameRequired }
        // Names stay unique so agents can refer to playlists by name.
        if playlists.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            throw MusicError.nameTaken(trimmed)
        }
        return trimmed
    }

    private func entries(for tracks: [MusicTrack], at date: Date) -> [PlaylistEntry] {
        tracks.map { PlaylistEntry(id: UUID(), track: $0, addedAt: date) }
    }

    private func load() {
        switch file.load() {
        case .empty:
            playlists = []
            readOnlyReason = nil
        case .writable(let loaded, let notice):
            playlists = loaded
            readOnlyReason = nil
            if let notice {
                self.notice = notice
                musicLog.error("Playlists recovered: \(notice, privacy: .public)")
            }
        case .readOnly(let loaded, let reason):
            playlists = loaded
            readOnlyReason = reason
            musicLog.error("Playlists read-only: \(reason, privacy: .public)")
        }
    }
}
