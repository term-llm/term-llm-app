import Foundation
@testable import TermLLM

/// Test doubles at the MusicKit boundary.

func track(_ id: String, _ title: String? = nil, artist: String = "Artist") -> MusicTrack {
    MusicTrack(id: id, title: title ?? "Song \(id)", artist: artist, album: "Album", artworkURL: nil)
}

final class FakeCatalog: MusicCatalog, @unchecked Sendable {
    private let lock = NSLock()
    private var known: [String: MusicTrack]
    private var accessValue: MusicAccess
    var searchResults: [MusicTrack] = []
    private(set) var searches: [String] = []

    init(tracks: [MusicTrack] = [], access: MusicAccess = .authorized) {
        known = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        accessValue = access
    }

    func access() -> MusicAccess { lock.withLock { accessValue } }
    func requestAccess() async -> MusicAccess {
        lock.withLock {
            if accessValue == .notDetermined { accessValue = .authorized }
            return accessValue
        }
    }

    func search(_ term: String, limit: Int) async throws -> [MusicTrack] {
        try lock.withLock {
            guard accessValue == .authorized else { throw MusicError.notAuthorized }
            searches.append(term)
            return Array(searchResults.prefix(limit))
        }
    }

    func tracks(ids: [String]) async throws -> [MusicTrack] {
        lock.withLock { ids.compactMap { known[$0] } }
    }
}

@MainActor
final class FakeEngine: MusicPlaybackEngine {
    var onChange: (@MainActor () -> Void)?
    /// Song ids Apple Music "can't find".
    var unavailable: Set<String> = []
    var playError: Error?
    /// Like the system player: reports `playing` only after this many reads.
    var startLag = 0
    /// Accepts play() but never starts.
    var neverStarts = false
    private var stored = PlaybackSnapshot()
    private var pendingReads = 0

    var snapshot: PlaybackSnapshot {
        get {
            if pendingReads > 0 {
                pendingReads -= 1
                if pendingReads == 0 { stored.state = .playing }
            }
            return stored
        }
        set { stored = newValue }
    }
    var onLoad: (() -> Void)?
    private(set) var loads: [(tracks: [MusicTrack], index: Int, shuffle: Bool)] = []
    private(set) var loaded: [MusicTrack] = []
    private(set) var playCount = 0
    private(set) var pauseCount = 0
    private(set) var skips: [String] = []

    func load(_ tracks: [MusicTrack], startingAt index: Int, shuffle: Bool) async throws -> [MusicTrack] {
        loads.append((tracks, index, shuffle))
        onLoad?()
        loaded = tracks.filter { !unavailable.contains($0.id) }
        guard !loaded.isEmpty else { throw MusicError.noPlayableSongs }
        let start = tracks.indices.contains(index) && !unavailable.contains(tracks[index].id) ? tracks[index] : loaded[0]
        snapshot = PlaybackSnapshot(state: .paused, current: start, shuffle: shuffle)
        return loaded
    }

    func play() async throws {
        if let playError { throw playError }
        playCount += 1
        if neverStarts { return }
        if startLag > 0 {
            pendingReads = startLag
        } else {
            stored.state = .playing
        }
    }

    func pause() {
        pauseCount += 1
        snapshot.state = .paused
    }

    func skipToNext() async throws {
        skips.append("next")
        move(by: 1)
    }

    func skipToPrevious() async throws {
        skips.append("previous")
        move(by: -1)
    }

    func setShuffle(_ enabled: Bool) { snapshot.shuffle = enabled }

    /// Simulates a change from outside the app (lock screen, Music app).
    func emit(_ change: (inout PlaybackSnapshot) -> Void) {
        change(&snapshot)
        onChange?()
    }

    private func move(by offset: Int) {
        guard let current = snapshot.current, let index = loaded.firstIndex(of: current) else { return }
        let next = index + offset
        if loaded.indices.contains(next) { snapshot.current = loaded[next] }
    }
}

func temporaryPlaylistFile() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "PlaylistStoreTests-\(UUID().uuidString)")
        .appending(path: "playlists.json")
}

func isolatedDefaults() -> UserDefaults {
    UserDefaults(suiteName: "MusicTests-\(UUID().uuidString)")!
}
