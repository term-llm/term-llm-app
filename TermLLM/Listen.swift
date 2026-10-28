import Foundation
import Observation

/// Wires Listen together once: the library, downloads, the player, and the
/// agent's media tools all share the same state.
@MainActor
@Observable
final class Listen {
    static let shared: Listen = {
        let cookies = WebKitCookieJar()
        let server = { ListenServer.current() }
        let artwork = ListenArtworkStore(cookies: cookies, server: server)
        return Listen(store: ListenStore(), engine: AVListenEngine(), cookies: cookies, server: server,
                      nowPlaying: SystemNowPlaying(artwork: artwork), artwork: artwork)
    }()

    enum DownloadPolicy: String, CaseIterable, Sendable {
        /// Download media from the connected server; stream everything else.
        case auto
        case now
        case never
    }

    let store: ListenStore
    let downloader: ListenDownloader
    let player: ListenPlayer
    let artwork: ListenArtworkStore
    @ObservationIgnored let server: () -> ListenServer?
    @ObservationIgnored private var toolbox: ListenTools?

    /// `artwork` defaults to a store next to `downloadDirectory`.
    init(store: ListenStore, engine: ListenEngine, cookies: ListenCookieJar, server: @escaping () -> ListenServer?,
         nowPlaying: ListenNowPlaying? = nil, artwork: ListenArtworkStore? = nil,
         downloadDirectory: URL = ListenDownloader.defaultDirectory, fetching: ListenFetching = ListenSessionFetching(),
         retryDelays: [TimeInterval] = ListenTransfer.retryDelays,
         defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.server = server
        self.artwork = artwork ?? ListenArtworkStore(
            directory: downloadDirectory.deletingLastPathComponent().appending(path: "Artwork", directoryHint: .isDirectory),
            cookies: cookies, server: server)
        let downloader = ListenDownloader(store: store, cookies: cookies, server: server, directory: downloadDirectory,
                                          fetching: fetching, retryDelays: retryDelays)
        self.downloader = downloader
        let player = ListenPlayer(store: store, engine: engine, sources: { await downloader.source(for: $0) },
                                  nowPlaying: nowPlaying, defaults: defaults, now: now)
        self.player = player
        // Playing an item streams it through its download, which saves it
        // meanwhile; the file goes once played.
        downloader.isStreaming = { [weak player] id in player?.currentID == id && player?.streaming == true }
        player.didFinish = { [weak downloader] ids in downloader?.releasePlaybackCache(ids) }
    }

    var tools: [DeviceTool] {
        if toolbox == nil { toolbox = ListenTools(listen: self) }
        return toolbox?.tools ?? []
    }

    /// Adds items; `.now` starts the first one.
    @discardableResult
    func add(_ drafts: [ListenDraft], placement: ListenStore.Placement, download: DownloadPolicy = .auto, origin: ListenServer? = nil) async throws -> [ListenItem] {
        let owner = origin ?? server()
        let bound = drafts.map { draft -> ListenDraft in
            var draft = draft
            if draft.sourceID == nil, let owner, HubNavigation.isWithinMount(draft.url, server: owner.base) { draft.sourceID = owner.sourceID }
            return draft
        }
        let added = store.add(bound, placement: placement, after: player.currentID)
        for item in added where item.download != .downloaded {
            switch download {
            case .now: downloader.download(item.id)
            case .auto: if downloader.shouldDownloadAutomatically(item) { downloader.download(item.id) }
            case .never: break
            }
        }
        if placement == .now, let first = added.first {
            try await player.play(first.id)
        }
        return added.compactMap { store.item($0.id) }
    }

    func remove(_ ids: [UUID]) throws {
        let doomed = store.items.filter { ids.contains($0.id) }
        guard doomed.count == Set(ids).count else {
            let known = Set(doomed.map(\.id))
            throw ListenError.notFound(ids.first { !known.contains($0) }?.uuidString ?? "")
        }
        player.willRemove(Set(ids))
        try store.remove(ids)
        downloader.removeFiles(for: doomed)
        artwork.prune(keeping: store.items)
    }

    /// Marks played or archived, moving on if one of them is playing.
    func finish(_ ids: [UUID], as status: ListenItem.Status) async throws {
        try store.setStatus(ids, status)
        if let current = player.currentID, ids.contains(current) {
            await player.didFinishElsewhere(current)
        }
        if status == .played || status == .archived { downloader.releasePlaybackCache(ids) }
    }

    func clearHistory() {
        let removed = store.clearHistory()
        downloader.removeFiles(for: removed)
        artwork.prune(keeping: store.items)
    }

    /// One Listen and Apple Music at a time: each pauses the other. Either
    /// starting also ends a live voice call (see `LiveHangUp`).
    static func connectToMusic(_ music: MusicPlayer, listen: Listen,
                               notificationCenter: NotificationCenter = .default) {
        music.willStartPlayback = { [weak listen] in
            listen?.player.pause()
            notificationCenter.post(name: .appWillStartPlayback, object: nil)
        }
        listen.player.willStartPlayback = { [weak music] in
            if music?.isPlaying == true { music?.pause() }
            notificationCenter.post(name: .appWillStartPlayback, object: nil)
        }
    }
}
