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
    private var requests = 0
    var requestCount: Int { lock.withLock { requests } }
    var beforeRequest: (@Sendable () async -> Void)?
    /// Can differ from the current permission to exercise a stale request result.
    var requestResult: MusicAccess?
    var searchResults: [MusicTrack] = []
    private(set) var searches: [String] = []

    init(tracks: [MusicTrack] = [], access: MusicAccess = .authorized) {
        known = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        accessValue = access
    }

    func access() -> MusicAccess { lock.withLock { accessValue } }
    func setAccess(_ access: MusicAccess) { lock.withLock { accessValue = access } }
    func requestAccess() async -> MusicAccess {
        lock.withLock { requests += 1 }
        await beforeRequest?()
        return lock.withLock {
            if accessValue == .notDetermined { accessValue = .authorized }
            return requestResult ?? accessValue
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
    /// Suspension points for exercising superseded requests before side effects.
    var beforeLoad: (() async throws -> Void)?
    var beforePlay: (() async throws -> Void)?
    var onSnapshot: (() -> Void)?
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
            onSnapshot?()
            if pendingReads > 0 {
                pendingReads -= 1
                if pendingReads == 0 { stored.state = .playing }
            }
            return stored
        }
        set { stored = newValue }
    }
    var onLoad: (() -> Void)?
    private(set) var activations = 0
    private(set) var loads: [(tracks: [MusicTrack], index: Int, shuffle: Bool)] = []
    private(set) var loaded: [MusicTrack] = []
    private(set) var playCount = 0
    private(set) var pauseCount = 0
    private(set) var skips: [String] = []

    func activate() { activations += 1 }

    func load(_ tracks: [MusicTrack], startingAt index: Int, shuffle: Bool) async throws -> [MusicTrack] {
        loads.append((tracks, index, shuffle))
        onLoad?()
        try await beforeLoad?()
        loaded = tracks.filter { !unavailable.contains($0.id) }
        guard !loaded.isEmpty else { throw MusicError.noPlayableSongs }
        let start = tracks.indices.contains(index) && !unavailable.contains(tracks[index].id) ? tracks[index] : loaded[0]
        snapshot = PlaybackSnapshot(state: .paused, current: start, shuffle: shuffle)
        return loaded
    }

    func play() async throws {
        if let playError { throw playError }
        playCount += 1
        try await beforePlay?()
        if neverStarts { return }
        if startLag > 0 {
            pendingReads = startLag
        } else {
            stored.state = .playing
        }
    }

    func pause() {
        pauseCount += 1
        pendingReads = 0
        stored.state = .paused
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

/// A single-use suspension point; completion can succeed or fail after pause.
@MainActor
final class MusicTestGate {
    var onWait: (() -> Void)?
    private var result: Result<Void, Error>?
    private var continuation: CheckedContinuation<Void, Error>?

    func wait() async throws {
        if let result { return try result.get() }
        try await withCheckedThrowingContinuation {
            continuation = $0
            onWait?()
        }
    }

    func finish(_ result: Result<Void, Error> = .success(())) {
        self.result = result
        continuation?.resume(with: result)
        continuation = nil
    }
}

/// Mirrors the real location, including the space in "Application Support",
/// which once broke loading (`URL.path()` percent-encodes it).
func temporaryPlaylistFile() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "PlaylistStoreTests-\(UUID().uuidString)")
        .appending(path: "Application Support/Music")
        .appending(path: "playlists.json")
}

func isolatedDefaults() -> UserDefaults {
    UserDefaults(suiteName: "MusicTests-\(UUID().uuidString)")!
}
