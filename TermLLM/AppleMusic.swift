import Combine
import Foundation
@preconcurrency import MusicKit
import os

/// Music diagnostics: `log stream --predicate 'subsystem == "com.termllm.app"'`
/// or Console.app with the device selected.
let musicLog = Logger(subsystem: "com.termllm.app", category: "music")

// The boundary between the app and MusicKit. Everything above these two
// protocols (store, player, tools, views) is testable without Apple Music.

enum MusicAccess: Equatable, Sendable {
    case authorized, notDetermined, denied, restricted
}

protocol MusicCatalog: Sendable {
    func access() -> MusicAccess
    func requestAccess() async -> MusicAccess
    /// Catalog songs matching `term`.
    func search(_ term: String, limit: Int) async throws -> [MusicTrack]
    /// Song metadata for `ids`, in order; unknown ids are omitted.
    func tracks(ids: [String]) async throws -> [MusicTrack]
}

struct PlaybackSnapshot: Equatable, Sendable {
    enum State: Equatable, Sendable { case playing, paused, stopped }
    var state: State = .stopped
    /// The system player's current song, which may not be one this app queued.
    var current: MusicTrack?
    var shuffle = false
}

@MainActor
protocol MusicPlaybackEngine: AnyObject {
    /// Called whenever the snapshot may have changed.
    var onChange: (@MainActor () -> Void)? { get set }
    var snapshot: PlaybackSnapshot { get }
    /// Queues `tracks` from `index` and returns the ones Apple Music could resolve.
    func load(_ tracks: [MusicTrack], startingAt index: Int, shuffle: Bool) async throws -> [MusicTrack]
    func play() async throws
    func pause()
    func skipToNext() async throws
    func skipToPrevious() async throws
    func setShuffle(_ enabled: Bool)
}

// MARK: - MusicKit

struct AppleMusicCatalog: MusicCatalog {
    private static let lookupBatch = 25

    func access() -> MusicAccess { Self.access(MusicAuthorization.currentStatus) }

    func requestAccess() async -> MusicAccess {
        Self.access(await MusicAuthorization.request())
    }

    func search(_ term: String, limit: Int) async throws -> [MusicTrack] {
        try await ensureAccess()
        let limit = max(1, min(25, limit))
        var request = MusicCatalogSearchRequest(term: term, types: [Song.self])
        request.limit = limit
        do {
            return try await request.response().songs.map(MusicTrack.init(song:))
        } catch where Self.isDecodingFailure(error) {
            // One result MusicKit can't decode fails the whole page. Ask the
            // Apple Music API directly and keep every song that parses.
            musicLog.error("MusicKit search decode failed, using lenient parsing: \(CatalogParsing.describe(error), privacy: .public) — \(String(reflecting: error), privacy: .public)")
            return try await CatalogParsing.searchSongs(apiData(path: "search", query: [
                "term": term, "types": "songs", "limit": String(limit),
            ]))
        } catch {
            musicLog.error("MusicKit search failed: \(String(reflecting: error), privacy: .public)")
            throw error
        }
    }

    func tracks(ids: [String]) async throws -> [MusicTrack] {
        try await ensureAccess()
        var tracks: [String: MusicTrack] = [:]
        for batch in Self.batches(of: ids) {
            do {
                let response = try await MusicCatalogResourceRequest<Song>(matching: \.id, memberOf: batch.map { MusicItemID($0) }).response()
                for song in response.items { tracks[song.id.rawValue] = MusicTrack(song: song) }
            } catch where Self.isDecodingFailure(error) {
                musicLog.error("MusicKit lookup decode failed, using lenient parsing: \(CatalogParsing.describe(error), privacy: .public)")
                let data = try await apiData(path: "songs", query: ["ids": batch.joined(separator: ",")])
                for track in CatalogParsing.resourceSongs(data) { tracks[track.id] = track }
            }
        }
        return ids.compactMap { tracks[$0] }
    }

    /// Batched lookups (one request per 25 ids) so long playlists start fast;
    /// ids Apple Music doesn't know, or MusicKit can't decode, are dropped
    /// instead of failing the whole queue.
    func songs(ids: [String]) async throws -> [Song] {
        try await ensureAccess()
        var found: [String: Song] = [:]
        for batch in Self.batches(of: ids) {
            do {
                for song in try await lookUp(batch) { found[song.id.rawValue] = song }
            } catch where Self.isDecodingFailure(error) && batch.count > 1 {
                // Isolate the song MusicKit can't decode; keep the rest.
                musicLog.error("MusicKit batch decode failed, retrying songs one by one: \(CatalogParsing.describe(error), privacy: .public)")
                for id in batch {
                    if let song = try? await lookUp([id]).first { found[song.id.rawValue] = song }
                }
            }
        }
        return ids.compactMap { found[$0] }
    }

    private func lookUp(_ ids: [String]) async throws -> MusicItemCollection<Song> {
        try await MusicCatalogResourceRequest<Song>(matching: \.id, memberOf: ids.map { MusicItemID($0) }).response().items
    }

    /// A raw Apple Music API request in the user's storefront (MusicKit signs it).
    private func apiData(path: String, query: [String: String]) async throws -> Data {
        let storefront = try await MusicDataRequest.currentCountryCode
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.music.apple.com"
        components.path = "/v1/catalog/\(storefront)/\(path)"
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw URLError(.badURL) }
        return try await MusicDataRequest(urlRequest: URLRequest(url: url)).response().data
    }

    private static func batches(of ids: [String]) -> [[String]] {
        var seen = Set<String>()
        let unique = ids.filter { seen.insert($0).inserted }
        return stride(from: 0, to: unique.count, by: lookupBatch).map {
            Array(unique[$0..<min($0 + lookupBatch, unique.count)])
        }
    }

    /// "The data couldn't be read because it isn't in the correct format."
    static func isDecodingFailure(_ error: Error) -> Bool {
        if error is DecodingError { return true }
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && (4864...4865).contains(nsError.code)
    }

    private func ensureAccess() async throws {
        var status = access()
        if status == .notDetermined { status = await requestAccess() }
        guard status == .authorized else { throw MusicError.notAuthorized }
    }

    private static func access(_ status: MusicAuthorization.Status) -> MusicAccess {
        switch status {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        default: return .denied
        }
    }
}

extension MusicTrack {
    init(song: Song) {
        self.init(id: song.id.rawValue, title: song.title, artist: song.artistName,
                  album: song.albumTitle, artworkURL: song.artwork?.url(width: 300, height: 300))
    }
}

/// Plays through the system Music player, so lock screen, Control Center and
/// CarPlay controls work and playback continues when this app is suspended.
/// (`ApplicationMusicPlayer` failed to prepare on device in jarvis.)
@MainActor
final class AppleMusicEngine: MusicPlaybackEngine {
    var onChange: (@MainActor () -> Void)?
    private let player = SystemMusicPlayer.shared
    private let catalog: AppleMusicCatalog
    private var observers: Set<AnyCancellable> = []

    init(catalog: AppleMusicCatalog = AppleMusicCatalog()) {
        self.catalog = catalog
        // objectWillChange fires before the change lands; read on the next turn.
        let notify: () -> Void = { [weak self] in
            DispatchQueue.main.async { self?.onChange?() }
        }
        player.state.objectWillChange.sink { _ in notify() }.store(in: &observers)
        player.queue.objectWillChange.sink { _ in notify() }.store(in: &observers)
    }

    var snapshot: PlaybackSnapshot {
        let state: PlaybackSnapshot.State
        switch player.state.playbackStatus {
        case .playing, .seekingForward, .seekingBackward: state = .playing
        case .paused, .interrupted: state = .paused
        default: state = .stopped
        }
        return PlaybackSnapshot(state: state, current: currentTrack,
                                shuffle: (player.state.shuffleMode ?? .off) != .off)
    }

    private var currentTrack: MusicTrack? {
        guard let entry = player.queue.currentEntry else { return nil }
        var id = entry.id
        if case .song(let song)? = entry.item { id = song.id.rawValue }
        return MusicTrack(id: id, title: entry.title, artist: entry.subtitle, album: nil,
                          artworkURL: entry.artwork?.url(width: 300, height: 300))
    }

    func load(_ tracks: [MusicTrack], startingAt index: Int, shuffle: Bool) async throws -> [MusicTrack] {
        let songs = try await catalog.songs(ids: tracks.map(\.id))
        guard !songs.isEmpty else { throw MusicError.noPlayableSongs }
        let wanted = tracks.indices.contains(index) ? tracks[index].id : nil
        let start = songs.first { $0.id.rawValue == wanted } ?? songs[0]
        player.queue = MusicKit.MusicPlayer.Queue(for: songs, startingAt: start)
        player.state.shuffleMode = shuffle ? .songs : .off
        return songs.map(MusicTrack.init(song:))
    }

    func play() async throws {
        guard try await MusicSubscription.current.canPlayCatalogContent else {
            musicLog.error("Apple Music subscription can't play catalog content")
            throw MusicError.cannotPlayCatalog
        }
        // The system player sometimes refuses the first play() after a queue
        // swap ("Failed to prepare to play"); prepare and retry briefly.
        var lastError: Error?
        for attempt in 1...3 {
            try? await player.prepareToPlay()
            do {
                try await player.play()
                return
            } catch {
                lastError = error
                musicLog.error("Apple Music play attempt \(attempt) failed: \(String(reflecting: error), privacy: .public)")
                try? await Task.sleep(for: .milliseconds(attempt == 1 ? 200 : 500))
            }
        }
        throw MusicError.playbackFailed(lastError?.localizedDescription ?? "unknown error")
    }

    func pause() { player.pause() }
    func skipToNext() async throws { try await player.skipToNextEntry() }
    func skipToPrevious() async throws { try await player.skipToPreviousEntry() }
    func setShuffle(_ enabled: Bool) { player.state.shuffleMode = enabled ? .songs : .off }
}
