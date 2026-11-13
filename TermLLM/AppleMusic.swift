import Combine
import Foundation
@preconcurrency import MusicKit
import os

/// Music diagnostics: see docs/MAC-SUPPORT.md for scoped music/device-tools
/// log capture, or filter those categories in Console.app.
let musicLog = Logger(subsystem: "com.termllm.app", category: "music")

// The boundary between the app and MusicKit. Everything above these two
// protocols (store, player, tools, views) is testable without Apple Music.

enum MusicAccess: String, Equatable, Sendable {
    case authorized, notDetermined, denied, restricted

    /// Small inline guidance shared by the library and song search.
    var guidance: String? {
        switch self {
        case .authorized: return nil
        case .notDetermined:
            return "Connect Apple Music, then choose Allow in the permission prompt to search and play songs. Playlists work without access."
        case .denied:
            #if os(macOS)
            return "Apple Music access is off. In System Settings → Privacy & Security → Media & Apple Music, allow term-llm access. Playlists still work."
            #else
            return "Apple Music access is off. In Settings, allow Media & Apple Music for term-llm. Playlists still work."
            #endif
        case .restricted:
            return "Apple Music access is restricted by this device's settings or management policy. Check with the device's parent or administrator. Playlists still work."
        }
    }

    var actionTitle: String? {
        switch self {
        case .notDetermined: return "Connect Apple Music"
        case .denied: return "Open Settings"
        case .authorized, .restricted: return nil
        }
    }
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
        let diagnostic = DeviceToolDiagnostics(operation: "catalog.authorization.request")
        musicLog.info("\(diagnostic.event("start"), privacy: .public) authorization=\(access().rawValue, privacy: .public)")
        let result = Self.access(await MusicAuthorization.request())
        musicLog.info("\(diagnostic.event("result"), privacy: .public) authorization=\(result.rawValue, privacy: .public)")
        return result
    }

    func search(_ term: String, limit: Int) async throws -> [MusicTrack] {
        let diagnostic = DeviceToolDiagnostics(operation: "catalog.search")
        musicLog.info("\(diagnostic.event("start"), privacy: .public) limit=\(limit)")
        do {
            try await ensureAccess()
            let limit = max(1, min(25, limit))
            var request = MusicCatalogSearchRequest(term: term, types: [Song.self])
            request.limit = limit
            let result: [MusicTrack]
            do {
                result = try await request.response().songs.map(MusicTrack.init(song:))
            } catch where Self.isDecodingFailure(error) {
                // One result MusicKit can't decode fails the whole page. Ask the
                // Apple Music API directly and keep every song that parses.
                musicLog.error("\(diagnostic.event("decode_fallback.start"), privacy: .public) \(DeviceToolDiagnostics.errorMetadata(error), privacy: .public)")
                do {
                    result = try await CatalogParsing.searchSongs(apiData(path: "search", query: [
                        "term": term, "types": "songs", "limit": String(limit),
                    ]))
                    musicLog.info("\(diagnostic.event("decode_fallback.success"), privacy: .public) count=\(result.count)")
                } catch {
                    musicLog.error("\(diagnostic.event("decode_fallback.failure"), privacy: .public) \(DeviceToolDiagnostics.errorMetadata(error), privacy: .public)")
                    throw error
                }
            }
            musicLog.info("\(diagnostic.event("success"), privacy: .public) count=\(result.count)")
            return result
        } catch {
            musicLog.error("\(diagnostic.event("failure"), privacy: .public) \(DeviceToolDiagnostics.errorMetadata(error), privacy: .public)")
            throw error
        }
    }

    func tracks(ids: [String]) async throws -> [MusicTrack] {
        let diagnostic = DeviceToolDiagnostics(operation: "catalog.tracks")
        musicLog.info("\(diagnostic.event("start"), privacy: .public) count=\(ids.count)")
        do {
            try await ensureAccess()
            var tracks: [String: MusicTrack] = [:]
            for batch in Self.batches(of: ids) {
                musicLog.info("\(diagnostic.event("batch.start"), privacy: .public) count=\(batch.count)")
                do {
                    let response = try await MusicCatalogResourceRequest<Song>(matching: \.id, memberOf: batch.map { MusicItemID($0) }).response()
                    for song in response.items { tracks[song.id.rawValue] = MusicTrack(song: song) }
                    musicLog.info("\(diagnostic.event("batch.success"), privacy: .public) count=\(response.items.count)")
                } catch where Self.isDecodingFailure(error) {
                    musicLog.error("\(diagnostic.event("decode_fallback.start"), privacy: .public) \(DeviceToolDiagnostics.errorMetadata(error), privacy: .public)")
                    do {
                        let data = try await apiData(path: "songs", query: ["ids": batch.joined(separator: ",")])
                        let parsed = CatalogParsing.resourceSongs(data)
                        for track in parsed { tracks[track.id] = track }
                        musicLog.info("\(diagnostic.event("decode_fallback.success"), privacy: .public) count=\(parsed.count)")
                    } catch {
                        musicLog.error("\(diagnostic.event("decode_fallback.failure"), privacy: .public) \(DeviceToolDiagnostics.errorMetadata(error), privacy: .public)")
                        throw error
                    }
                }
            }
            let result = ids.compactMap { tracks[$0] }
            musicLog.info("\(diagnostic.event("success"), privacy: .public) count=\(result.count)")
            return result
        } catch {
            musicLog.error("\(diagnostic.event("failure"), privacy: .public) \(DeviceToolDiagnostics.errorMetadata(error), privacy: .public)")
            throw error
        }
    }

    /// Batched lookups (one request per 25 ids) so long playlists start fast;
    /// ids Apple Music doesn't know, or MusicKit can't decode, are dropped
    /// instead of failing the whole queue.
    func songs(ids: [String]) async throws -> [Song] {
        let diagnostic = DeviceToolDiagnostics(operation: "catalog.songs")
        musicLog.info("\(diagnostic.event("start"), privacy: .public) count=\(ids.count)")
        do {
            try await ensureAccess()
            var found: [String: Song] = [:]
            for batch in Self.batches(of: ids) {
                do {
                    for song in try await lookUp(batch) { found[song.id.rawValue] = song }
                } catch where Self.isDecodingFailure(error) && batch.count > 1 {
                    // Isolate the song MusicKit can't decode; keep the rest.
                    musicLog.error("\(diagnostic.event("decode_fallback.start"), privacy: .public) count=\(batch.count) \(DeviceToolDiagnostics.errorMetadata(error), privacy: .public)")
                    let before = found.count
                    for id in batch {
                        // lookUp logs each ignored failure, without changing this fallback's tolerance.
                        if let song = try? await lookUp([id]).first { found[song.id.rawValue] = song }
                    }
                    musicLog.info("\(diagnostic.event("decode_fallback.complete"), privacy: .public) resolved_count=\(found.count - before) requested_count=\(batch.count)")
                }
            }
            let result = ids.compactMap { found[$0] }
            musicLog.info("\(diagnostic.event("success"), privacy: .public) count=\(result.count)")
            return result
        } catch {
            musicLog.error("\(diagnostic.event("failure"), privacy: .public) \(DeviceToolDiagnostics.errorMetadata(error), privacy: .public)")
            throw error
        }
    }

    private func lookUp(_ ids: [String]) async throws -> MusicItemCollection<Song> {
        let diagnostic = DeviceToolDiagnostics(operation: "catalog.lookup")
        musicLog.info("\(diagnostic.event("start"), privacy: .public) count=\(ids.count)")
        do {
            let result = try await MusicCatalogResourceRequest<Song>(matching: \.id, memberOf: ids.map { MusicItemID($0) }).response().items
            musicLog.info("\(diagnostic.event("success"), privacy: .public) count=\(result.count)")
            return result
        } catch {
            musicLog.error("\(diagnostic.event("failure"), privacy: .public) \(DeviceToolDiagnostics.errorMetadata(error), privacy: .public)")
            throw error
        }
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
        let diagnostic = DeviceToolDiagnostics(operation: "catalog.authorization.ensure")
        var status = access()
        musicLog.info("\(diagnostic.event("start"), privacy: .public) authorization=\(status.rawValue, privacy: .public)")
        if status == .notDetermined { status = await requestAccess() }
        guard status == .authorized else {
            musicLog.error("\(diagnostic.event("denied"), privacy: .public) authorization=\(status.rawValue, privacy: .public) \(DeviceToolDiagnostics.errorMetadata(MusicError.notAuthorized), privacy: .public)")
            throw MusicError.notAuthorized
        }
        musicLog.info("\(diagnostic.event("success"), privacy: .public) authorization=\(status.rawValue, privacy: .public)")
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

/// Plays through the system Music player on iPhone/iPad, so lock screen,
/// Control Center and CarPlay controls work and playback continues when this
/// app is suspended. (`ApplicationMusicPlayer` failed to prepare on device in
/// jarvis.) macOS has no system player for apps; the Mac app plays in-app.
@MainActor
final class AppleMusicEngine: MusicPlaybackEngine {
    var onChange: (@MainActor () -> Void)?
    #if os(macOS)
    private let player = ApplicationMusicPlayer.shared
    private let diagnosticEngine = "application"
    #else
    private let player = SystemMusicPlayer.shared
    private let diagnosticEngine = "system"
    #endif
    private let catalog: AppleMusicCatalog
    private var observers: Set<AnyCancellable> = []
    /// A newer load/play or explicit pause supersedes work suspended in MusicKit.
    private var playbackRequest = UUID()

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
        let song: MusicTrack?
        if case .song(let item)? = entry.item { song = MusicTrack(song: item) } else { song = nil }
        return MusicTrack(id: song?.id ?? entry.id, title: entry.title, artist: entry.subtitle, album: nil,
                          artworkURL: entry.artwork?.url(width: 300, height: 300))
            .fillingMissingMetadata(from: song)
    }

    func load(_ tracks: [MusicTrack], startingAt index: Int, shuffle: Bool) async throws -> [MusicTrack] {
        let diagnostic = DeviceToolDiagnostics(operation: "player.load")
        musicLog.info("\(diagnostic.event("start"), privacy: .public) engine=\(self.diagnosticEngine, privacy: .public) count=\(tracks.count)")
        let request = UUID()
        playbackRequest = request
        do {
            try checkRequest(request)
            let songs = try await catalog.songs(ids: tracks.map(\.id))
            try checkRequest(request)
            guard !songs.isEmpty else { throw MusicError.noPlayableSongs }
            let wanted = tracks.indices.contains(index) ? tracks[index].id : nil
            let start = songs.first { $0.id.rawValue == wanted } ?? songs[0]
            musicLog.info("\(diagnostic.event("queue.assign"), privacy: .public) count=\(songs.count)")
            player.queue = .init(for: songs, startingAt: start)
            player.state.shuffleMode = shuffle ? .songs : .off
            musicLog.info("\(diagnostic.event("success"), privacy: .public) count=\(songs.count)")
            return songs.map(MusicTrack.init(song:))
        } catch {
            musicLog.error("\(diagnostic.event("failure"), privacy: .public) \(DeviceToolDiagnostics.errorMetadata(error), privacy: .public)")
            throw error
        }
    }

    func play() async throws {
        let diagnostic = DeviceToolDiagnostics(operation: "player.play")
        musicLog.info("\(diagnostic.event("start"), privacy: .public) engine=\(self.diagnosticEngine, privacy: .public)")
        let request = UUID()
        playbackRequest = request
        do {
            try checkRequest(request)
            musicLog.info("\(diagnostic.event("subscription.start"), privacy: .public)")
            let canPlay: Bool
            do {
                canPlay = try await MusicSubscription.current.canPlayCatalogContent
                musicLog.info("\(diagnostic.event("subscription.result"), privacy: .public) can_play=\(canPlay)")
            } catch {
                musicLog.error("\(diagnostic.event("subscription.failure"), privacy: .public) \(DeviceToolDiagnostics.errorMetadata(error), privacy: .public)")
                throw error
            }
            try checkRequest(request)
            guard canPlay else {
                musicLog.error("\(diagnostic.event("subscription.denied"), privacy: .public)")
                throw MusicError.cannotPlayCatalog
            }
            // The system player sometimes refuses the first play() after a queue
            // swap ("Failed to prepare to play"); prepare and retry briefly.
            var lastError: Error?
            for attempt in 1...3 {
                try checkRequest(request)
                musicLog.info("\(diagnostic.event("prepare.start"), privacy: .public) attempt=\(attempt)")
                do {
                    try await player.prepareToPlay()
                    musicLog.info("\(diagnostic.event("prepare.success"), privacy: .public) attempt=\(attempt)")
                } catch {
                    // Deliberately ignored, exactly as the previous try? path.
                    musicLog.error("\(diagnostic.event("prepare.failure_ignored"), privacy: .public) attempt=\(attempt) \(DeviceToolDiagnostics.errorMetadata(error), privacy: .public)")
                }
                try checkRequest(request)
                do {
                    musicLog.info("\(diagnostic.event("play.start"), privacy: .public) attempt=\(attempt)")
                    try await player.play()
                    // MusicKit cannot reliably revoke an already-submitted play().
                    // Do not compensate with pause here: it could stop a newer play
                    // (or intentional playback from Music/Control Center).
                    try checkRequest(request)
                    musicLog.info("\(diagnostic.event("success"), privacy: .public) attempt=\(attempt)")
                    return
                } catch {
                    try checkRequest(request)
                    if error is CancellationError { throw error }
                    lastError = error
                    musicLog.error("\(diagnostic.event("play.failure_retry"), privacy: .public) attempt=\(attempt) \(DeviceToolDiagnostics.errorMetadata(error), privacy: .public)")
                    try await Task.sleep(for: .milliseconds(attempt == 1 ? 200 : 500))
                    try checkRequest(request)
                }
            }
            if let lastError {
                musicLog.error("\(diagnostic.event("retries_exhausted"), privacy: .public) \(DeviceToolDiagnostics.errorMetadata(lastError), privacy: .public)")
            }
            throw MusicError.playbackFailed(lastError?.localizedDescription ?? "unknown error")
        } catch {
            musicLog.error("\(diagnostic.event("failure"), privacy: .public) \(DeviceToolDiagnostics.errorMetadata(error), privacy: .public)")
            throw error
        }
    }

    private func checkRequest(_ request: UUID) throws {
        try Task.checkCancellation()
        guard playbackRequest == request else { throw CancellationError() }
    }

    func pause() {
        playbackRequest = UUID()
        player.pause()
    }
    func skipToNext() async throws { try await player.skipToNextEntry() }
    func skipToPrevious() async throws { try await player.skipToPreviousEntry() }
    func setShuffle(_ enabled: Bool) { player.state.shuffleMode = enabled ? .songs : .off }
}
