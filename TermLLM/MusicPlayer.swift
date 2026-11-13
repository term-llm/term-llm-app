import Foundation
import Observation

/// A short message for the Music screen's toast.
struct MusicNotice: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let isError: Bool
}

/// What the Music screen and the agent's tools see of playback. The system
/// player is the source of truth; this adds which playlist was loaded.
@MainActor
@Observable
final class MusicPlayer {
    enum Status: Equatable {
        case idle, loading, playing, paused
        case failed(String)
    }

    private(set) var status: Status = .idle
    /// The system player's current song (possibly one started elsewhere).
    private(set) var nowPlaying: MusicTrack?
    /// Songs this app last queued, and the playlist they came from.
    private(set) var queue: [MusicTrack] = []
    private(set) var playlistID: UUID?
    private(set) var shuffle: Bool
    /// The row a tap is starting, for an immediate spinner.
    private(set) var startingEntryID: UUID?
    private(set) var notice: MusicNotice?

    /// Runs before this app starts audio (e.g. to end a live voice call).
    @ObservationIgnored var willStartPlayback: (() -> Void)?

    @ObservationIgnored private let engine: MusicPlaybackEngine
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let startCheck: StartCheck
    /// Invalidated by pause or a newer start/resume, independently of task lifetime.
    @ObservationIgnored private var playbackRequest = UUID()
    static let shuffleKey = "music.shuffle"

    /// How long to wait for the system player to report playing after play().
    struct StartCheck {
        var polls = 30
        var interval: Duration = .milliseconds(100)
    }

    init(engine: MusicPlaybackEngine, defaults: UserDefaults = .standard, startCheck: StartCheck = StartCheck()) {
        self.engine = engine
        self.defaults = defaults
        self.startCheck = startCheck
        shuffle = defaults.bool(forKey: Self.shuffleKey)
        engine.onChange = { [weak self] in self?.sync() }
        sync()
    }

    var isPlaying: Bool { status == .playing || status == .loading }

    /// True while `playlist` is what the system player is working through.
    func isActive(_ playlist: Playlist) -> Bool {
        guard playlistID == playlist.id, let current = nowPlaying else { return false }
        return playlist.entries.contains { $0.track.id == current.id }
    }

    // MARK: Starting playback

    @discardableResult
    func play(_ playlist: Playlist, startingAt entryID: UUID? = nil, shuffle: Bool? = nil) async throws -> [MusicTrack] {
        guard !playlist.entries.isEmpty else { throw MusicError.emptyPlaylist(playlist.name) }
        let index = entryID.flatMap { id in playlist.entries.firstIndex { $0.id == id } } ?? 0
        return try await start(playlist.tracks, at: index, playlistID: playlist.id, shuffle: shuffle,
                               entryID: entryID ?? playlist.entries[index].id)
    }

    @discardableResult
    func play(_ tracks: [MusicTrack], startingAt index: Int = 0, shuffle: Bool? = nil) async throws -> [MusicTrack] {
        guard !tracks.isEmpty else { throw MusicError.noPlayableSongs }
        return try await start(tracks, at: index, playlistID: nil, shuffle: shuffle)
    }

    private func start(_ tracks: [MusicTrack], at index: Int, playlistID: UUID?, shuffle: Bool?, entryID: UUID? = nil) async throws -> [MusicTrack] {
        // Reject the entire queue, including mixed playlists, before touching
        // audio, permissions, shuffle preferences, or willStartPlayback.
        guard !tracks.contains(where: \.isSample) else {
            let error = MusicError.sampleSongsNotPlayable
            post(error.localizedDescription, isError: true)
            throw error
        }
        let request = UUID()
        playbackRequest = request
        startingEntryID = entryID
        defer { if playbackRequest == request { startingEntryID = nil } }
        if let shuffle { rememberShuffle(shuffle) }
        willStartPlayback?()
        status = .loading
        do {
            try checkRequest(request)
            let loaded = try await engine.load(tracks, startingAt: index, shuffle: self.shuffle)
            try checkRequest(request)
            queue = loaded
            self.playlistID = playlistID
            try await startPlaying(request: request)
            try checkRequest(request)
            let skipped = tracks.count - loaded.count
            if skipped > 0 {
                post("\(skipped) song\(skipped == 1 ? " isn't" : "s aren't") available on Apple Music", isError: false)
            }
            return loaded
        } catch {
            guard playbackRequest == request else { throw CancellationError() }
            if error is CancellationError {
                status = .paused
                throw error
            }
            let message = error.localizedDescription
            status = .failed(message)
            post(message, isError: true)
            throw error
        }
    }

    // MARK: Transport

    func pause() {
        playbackRequest = UUID()
        startingEntryID = nil
        engine.pause()
        status = .paused
    }

    func resume() async throws {
        guard nowPlaying != nil || !queue.isEmpty else { throw MusicError.nothingToResume }
        let request = UUID()
        playbackRequest = request
        startingEntryID = nil
        willStartPlayback?()
        let previous = status
        status = .loading
        do {
            try await startPlaying(request: request)
        } catch {
            guard playbackRequest == request else { throw CancellationError() }
            status = previous == .loading ? .paused : previous
            sync()
            if !(error is CancellationError) { post(error.localizedDescription, isError: true) }
            throw error
        }
    }

    /// Plays and waits until the system player actually reports playing: it
    /// only does so a moment after play() returns, and occasionally not at
    /// all until asked again. Callers (and tool results) then see the truth.
    private func startPlaying(request: UUID) async throws {
        for attempt in 1...2 {
            try checkRequest(request)
            try await engine.play()
            try checkRequest(request)
            for _ in 0..<startCheck.polls {
                try checkRequest(request)
                if engine.snapshot.state == .playing {
                    status = .playing
                    sync()
                    return
                }
                try await Task.sleep(for: startCheck.interval)
            }
            try checkRequest(request)
            musicLog.error("Apple Music didn't report playing after play() attempt \(attempt)")
        }
        throw MusicError.didNotStart
    }

    private func checkRequest(_ request: UUID) throws {
        try Task.checkCancellation()
        guard playbackRequest == request else { throw CancellationError() }
    }

    func togglePlayPause() async {
        if isPlaying { pause() } else { try? await resume() }
    }

    /// Syncs as soon as the skip lands, so callers (e.g. tool results) never
    /// report the song that was just skipped.
    func next() async throws {
        try await engine.skipToNext()
        sync()
    }

    func previous() async throws {
        try await engine.skipToPrevious()
        sync()
    }

    func setShuffle(_ enabled: Bool) {
        rememberShuffle(enabled)
        engine.setShuffle(enabled)
    }

    func post(_ text: String, isError: Bool) {
        notice = MusicNotice(text: text, isError: isError)
    }

    func dismissNotice(_ id: UUID? = nil) {
        if id == nil || notice?.id == id { notice = nil }
    }

    // MARK: Sync

    /// Mirrors the system player, which also changes from the lock screen,
    /// Control Center, or the Music app.
    func sync() {
        let snapshot = engine.snapshot
        nowPlaying = snapshot.current.map { current in
            current.fillingMissingMetadata(from: queue.first { $0.id == current.id })
        }
        if !queue.isEmpty, snapshot.current != nil, snapshot.shuffle != shuffle { rememberShuffle(snapshot.shuffle) }
        guard status != .loading else { return }
        switch snapshot.state {
        case .playing: status = .playing
        case .paused: status = .paused
        case .stopped: if case .failed = status {} else { status = snapshot.current == nil ? .idle : .paused }
        }
    }

    private func rememberShuffle(_ enabled: Bool) {
        shuffle = enabled
        defaults.set(enabled, forKey: Self.shuffleKey)
    }
}
