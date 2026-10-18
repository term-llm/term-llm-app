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
        return Listen(store: ListenStore(), engine: AVListenEngine(), cookies: cookies, server: server,
                      nowPlaying: SystemNowPlaying(cookies: cookies, server: server))
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
    @ObservationIgnored let server: () -> ListenServer?
    @ObservationIgnored private var toolbox: ListenTools?

    init(store: ListenStore, engine: ListenEngine, cookies: ListenCookieJar, server: @escaping () -> ListenServer?,
         nowPlaying: ListenNowPlaying? = nil, downloadDirectory: URL = ListenDownloader.defaultDirectory,
         fetch: ListenDownloader.Fetch? = nil, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.server = server
        let downloader = fetch.map {
            ListenDownloader(store: store, cookies: cookies, server: server, directory: downloadDirectory, fetch: $0)
        } ?? ListenDownloader(store: store, cookies: cookies, server: server, directory: downloadDirectory)
        self.downloader = downloader
        self.player = ListenPlayer(store: store, engine: engine, sources: { await downloader.source(for: $0) },
                                   nowPlaying: nowPlaying, defaults: defaults, now: now)
        // Save what's streaming as it plays, so seeks become instant and a
        // dropped connection doesn't stop it; the file goes once played.
        player.didStartStreaming = { [weak downloader] id in
            guard let downloader, let item = store.item(id), Self.cachesWhileStreaming(item) else { return }
            downloader.download(id, forPlayback: true)
        }
        player.didFinish = { [weak downloader] ids in downloader?.releasePlaybackCache(ids) }
    }

    /// Video files can be huge; everything else is cached while it streams.
    static func cachesWhileStreaming(_ item: ListenItem) -> Bool {
        item.kind != .video && item.download != .downloaded && item.download != .downloading && item.download != .queued
    }

    var tools: [DeviceTool] {
        if toolbox == nil { toolbox = ListenTools(listen: self) }
        return toolbox?.tools ?? []
    }

    /// Adds items; `.now` starts the first one.
    @discardableResult
    func add(_ drafts: [ListenDraft], placement: ListenStore.Placement, download: DownloadPolicy = .auto) async throws -> [ListenItem] {
        let added = store.add(drafts, placement: placement, after: player.currentID)
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
    }

    /// One Listen and Apple Music at a time: each pauses the other.
    static func connectToMusic(_ music: MusicPlayer, listen: Listen) {
        music.willStartPlayback = { [weak listen] in listen?.player.pause() }
        listen.player.willStartPlayback = { [weak music] in
            if music?.isPlaying == true { music?.pause() }
        }
    }
}
