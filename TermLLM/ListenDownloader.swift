import Foundation
import Observation

/// Keeps Listen items on the phone so they play offline and seek instantly.
/// Each item has at most one `ListenTransfer`, fetched by byte range, and
/// playback reads through it while it runs: streaming an episode and saving
/// it fetch each byte once. Files live in Application Support (not backed
/// up). Media from the connected server is fetched with the web view's
/// sign-in cookie; other hosts never get cookies.
@MainActor
@Observable
final class ListenDownloader {
    /// Bytes fetched so far for a download in flight.
    struct Progress: Equatable, Sendable {
        var received: Int64 = 0
        /// Nil until the server says (or if it never does).
        var expected: Int64?

        var fraction: Double? {
            guard let expected, expected > 0 else { return nil }
            return min(1, Double(received) / Double(expected))
        }
    }

    static let maxConcurrent = 3
    /// How often progress is read while downloading.
    static let progressInterval: Duration = .milliseconds(500)

    /// Downloads in flight, by item.
    private(set) var progress: [UUID: Progress] = [:]

    /// Whether playback is reading this item through its transfer now.
    @ObservationIgnored var isStreaming: (UUID) -> Bool = { _ in false }

    @ObservationIgnored private let store: ListenStore
    @ObservationIgnored private let cookies: ListenCookieJar
    @ObservationIgnored private let server: () -> ListenServer?
    @ObservationIgnored private let fetching: ListenFetching
    @ObservationIgnored private let retryDelays: [TimeInterval]
    @ObservationIgnored let directory: URL
    /// Downloads in flight, including one playback reads.
    @ObservationIgnored private var transfers: [UUID: ListenTransfer] = [:]
    /// Transfers that only serve playback now (saving was stopped). The
    /// player holds them; they let a new download carry on instead.
    @ObservationIgnored private var streams: [UUID: WeakTransfer] = [:]
    @ObservationIgnored private var watchers: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var waiting: [UUID] = []
    /// Downloads started only to cache what's streaming.
    @ObservationIgnored private var forPlayback: Set<UUID> = []

    init(store: ListenStore, cookies: ListenCookieJar, server: @escaping () -> ListenServer?,
         directory: URL = ListenDownloader.defaultDirectory,
         fetching: ListenFetching = ListenSessionFetching(),
         retryDelays: [TimeInterval] = ListenTransfer.retryDelays) {
        self.store = store
        self.cookies = cookies
        self.server = server
        self.directory = directory
        self.fetching = fetching
        self.retryDelays = retryDelays
        removeStrayPartials()
    }

    nonisolated static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Listen/Downloads", directoryHint: .isDirectory)
    }

    /// Server media is small and behind sign-in, so it's downloaded by
    /// default; podcast episodes elsewhere stream unless asked.
    func shouldDownloadAutomatically(_ item: ListenItem) -> Bool {
        server()?.isSameOrigin(item.url) ?? false
    }

    var activeCount: Int { transfers.count }

    /// Bytes used by downloaded items.
    var totalBytes: Int64 {
        store.items.compactMap { $0.download == .downloaded ? $0.downloadedBytes : nil }.reduce(0, +)
    }

    func localURL(for item: ListenItem) -> URL? {
        guard item.download == .downloaded, let name = item.localFile else { return nil }
        let url = directory.appending(path: name)
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    /// What the engine should play for `item`: its file if downloaded,
    /// otherwise its transfer, which saves it while it plays. Video and plain
    /// http stream straight from the URL (cookies only for the connected server).
    func source(for item: ListenItem) async -> ListenSource {
        retirePlaybackCaches(except: item.id)
        if let local = localURL(for: item) { return ListenSource(url: local, spoken: item.kind != .music) }
        if item.download == .downloaded {
            // The file vanished; forget it.
            store.update(item.id) { $0.download = .none; $0.localFile = nil; $0.downloadedBytes = nil }
        }
        if Self.playsThroughTransfer(item) {
            return ListenSource(url: item.url, spoken: item.kind != .music, transfer: transferForPlayback(item))
        }
        let cookies = isSameServer(item) ? await cookies.cookies(for: item.url, sourceID: item.sourceID) : []
        return ListenSource(url: item.url, cookies: cookies, spoken: item.kind != .music)
    }

    /// Videos can be huge and AirPlay needs their real URL; App Transport
    /// Security keeps plain http to AVFoundation.
    nonisolated static func playsThroughTransfer(_ item: ListenItem) -> Bool {
        item.kind != .video && item.url.scheme?.lowercased() == "https"
    }

    /// Downloads `id`. `forPlayback` caches only a bounded window ahead of
    /// playback; the file goes once the item is played.
    func download(_ id: UUID, forPlayback: Bool = false) {
        guard let item = store.item(id) else { return }
        if !forPlayback {
            // Asked for explicitly: keep it, even if it started as a cache.
            self.forPlayback.remove(id)
            if item.cachedForPlayback == true { store.update(id) { $0.cachedForPlayback = nil } }
        }
        guard item.download != .downloaded || localURL(for: item) == nil else { return }
        if let transfer = transfers[id] {
            if !forPlayback { transfer.setSaving(true) }
            return
        }
        if waiting.contains(id) { return }
        if forPlayback { self.forPlayback.insert(id) }
        if let stream = streams.removeValue(forKey: id)?.transfer {
            // Saving stopped while it played: carry on with the same transfer.
            stream.setSaving(true, playbackOnly: forPlayback)
            track(stream, for: id)
            return
        }
        store.update(id) { $0.download = .queued; $0.downloadError = nil }
        waiting.append(id)
        startWaiting()
    }

    func isCachingForPlayback(_ id: UUID) -> Bool { forPlayback.contains(id) }

    /// Deletes files that were only cached for streaming.
    func releasePlaybackCache(_ ids: [UUID]) {
        for id in ids {
            if forPlayback.contains(id) {
                cancel(id)
            } else if store.item(id)?.cachedForPlayback == true {
                deleteFile(id)
            }
            // What was streamed of it without finishing goes too.
            removePartial(id)
        }
    }

    /// Stops downloading. If it's playing, it carries on streaming without
    /// saving the rest.
    func cancel(_ id: UUID) {
        waiting.removeAll { $0 == id }
        forPlayback.remove(id)
        stopWatching(id)
        if let transfer = transfers.removeValue(forKey: id) {
            if isStreaming(id) {
                transfer.setSaving(false)
                streams[id] = WeakTransfer(transfer)
            } else {
                transfer.cancel(keepingPartial: false)
            }
        }
        if let item = store.item(id), item.download == .queued || item.download == .downloading {
            store.update(id) { $0.download = .none }
        }
        startWaiting()
    }

    /// Deletes the file; the item streams again.
    func deleteFile(_ id: UUID) {
        cancel(id)
        guard let item = store.item(id) else { return }
        if let name = item.localFile { try? FileManager.default.removeItem(at: directory.appending(path: name)) }
        removePartial(id)
        store.update(id) {
            $0.download = .none; $0.localFile = nil; $0.downloadedBytes = nil; $0.downloadError = nil; $0.cachedForPlayback = nil
        }
    }

    /// Deletes files for items that are no longer in the library.
    func removeFiles(for items: [ListenItem]) {
        for item in items {
            waiting.removeAll { $0 == item.id }
            forPlayback.remove(item.id)
            stopWatching(item.id)
            transfers.removeValue(forKey: item.id)?.cancel(keepingPartial: false)
            streams.removeValue(forKey: item.id)?.transfer?.cancel(keepingPartial: false)
            if let name = item.localFile { try? FileManager.default.removeItem(at: directory.appending(path: name)) }
            removePartial(item.id)
        }
        startWaiting()
    }

    /// The request a transfer sends for `url`, with only its owner's cookies,
    /// read when it's sent so a revoked sign-in stops at the next request.
    func request(for url: URL, sameServer: Bool, sourceID: UUID?) async -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpShouldHandleCookies = false
        if sameServer {
            HTTPCookie.requestHeaderFields(with: await cookies.cookies(for: url, sourceID: sourceID)).forEach {
                request.setValue($1, forHTTPHeaderField: $0)
            }
        }
        return request
    }

    /// The request `item`'s transfer would send now.
    func request(for item: ListenItem) async -> URLRequest {
        await request(for: transferURL(for: item), sameServer: isSameServer(item), sourceID: item.sourceID)
    }

    // MARK: - Private

    private struct WeakTransfer {
        weak var transfer: ListenTransfer?
        init(_ transfer: ListenTransfer) { self.transfer = transfer }
    }

    private func isSameServer(_ item: ListenItem) -> Bool {
        item.sourceID != nil || (server()?.isSameOrigin(item.url) ?? false)
    }

    private func transferURL(for item: ListenItem) -> URL {
        // App Transport Security blocks plain http downloads; most hosts also
        // serve https. (Streaming plain http still works for media.)
        guard !isSameServer(item), item.url.scheme?.lowercased() == "http",
              var components = URLComponents(url: item.url, resolvingAgainstBaseURL: false) else { return item.url }
        components.scheme = "https"
        return components.url ?? item.url
    }

    /// Playback caches only need an active writer/watcher while current. Keep
    /// sparse bytes for a later resume, without retaining every visited episode
    /// or letting old completion callbacks update a replacement transfer.
    private func retirePlaybackCaches(except current: UUID) {
        for id in forPlayback where id != current {
            waiting.removeAll { $0 == id }
            stopWatching(id)
            if let transfer = transfers.removeValue(forKey: id) {
                transfer.cancel(keepingPartial: true)
                // Seal the partial before another source selection can reopen
                // it on a different transfer queue. No remote work is awaited.
                _ = transfer.progress
            }
            if let item = store.item(id), item.download == .queued || item.download == .downloading {
                store.update(id) { $0.download = .none; $0.downloadError = nil }
            }
        }
        forPlayback = forPlayback.intersection([current])
        startWaiting()
    }

    /// The transfer playback reads: the download in flight, or a new one
    /// that caches the item while it plays. It starts at once, ahead of the queue.
    private func transferForPlayback(_ item: ListenItem) -> ListenTransfer {
        if let transfer = transfers[item.id] { return transfer }
        if let stream = streams[item.id]?.transfer { return stream }
        let queued = waiting.contains(item.id)
        waiting.removeAll { $0 == item.id }
        if !queued { forPlayback.insert(item.id) }
        return begin(item)
    }

    private func startWaiting() {
        // The current playback cache may stay idle/partial indefinitely.
        // It must not occupy a whole-file download queue slot.
        while transfers.keys.filter({ !forPlayback.contains($0) }).count < Self.maxConcurrent, !waiting.isEmpty {
            let id = waiting.removeFirst()
            guard let item = store.item(id) else { continue }
            begin(item)
        }
    }

    @discardableResult
    private func begin(_ item: ListenItem) -> ListenTransfer {
        let sameServer = isSameServer(item)
        let sourceID = item.sourceID
        let transfer = ListenTransfer(
            id: item.id, remote: transferURL(for: item), directory: directory, fetching: fetching,
            retryDelays: retryDelays, playbackOnly: forPlayback.contains(item.id),
            makeRequest: { [weak self] url in
                await self?.request(for: url, sameServer: sameServer, sourceID: sourceID) ?? URLRequest(url: url)
            },
            finished: { [weak self] transfer, result in
                Task { @MainActor in self?.finished(transfer, result) }
            })
        track(transfer, for: item.id)
        transfer.start()
        return transfer
    }

    private func track(_ transfer: ListenTransfer, for id: UUID) {
        transfers[id] = transfer
        store.update(id) { $0.download = .downloading; $0.downloadError = nil }
        watchers[id]?.cancel()
        progress[id] = Progress()
        watchers[id] = Task { [weak self, weak transfer] in
            while !Task.isCancelled {
                guard let self, let transfer, self.transfers[id] === transfer else { return }
                let now = transfer.progress
                let next = Progress(received: now.received, expected: now.expected)
                if self.progress[id] != next { self.progress[id] = next }
                try? await Task.sleep(for: Self.progressInterval)
            }
        }
    }

    private func stopWatching(_ id: UUID) {
        watchers.removeValue(forKey: id)?.cancel()
        progress[id] = nil
    }

    private func finished(_ transfer: ListenTransfer, _ result: Result<ListenTransfer.Saved, Error>) {
        let id = transfer.id
        if streams[id]?.transfer === transfer { streams[id] = nil }
        guard transfers[id] === transfer else {
            // Saving was stopped or its playback cache was retired. A newer
            // transfer may already own the same destination: never delete its
            // file when an old completion finally reaches the main actor.
            if case .success(let saved) = result, transfers[id] == nil,
               store.item(id)?.localFile != saved.file.lastPathComponent {
                try? FileManager.default.removeItem(at: saved.file)
            }
            return
        }
        transfers[id] = nil
        stopWatching(id)
        defer { startWaiting() }
        switch result {
        case .success(let saved):
            let cached = forPlayback.remove(id) != nil
            guard store.item(id) != nil else {
                try? FileManager.default.removeItem(at: saved.file)
                return
            }
            store.update(id) {
                $0.download = .downloaded
                $0.localFile = saved.file.lastPathComponent
                $0.downloadedBytes = saved.bytes
                $0.downloadError = nil
                $0.cachedForPlayback = cached ? true : nil
            }
        case .failure(let error):
            if forPlayback.remove(id) != nil {
                // A cache that didn't work out; the item still streams.
                listenLog.info("Listen couldn't save a stream: \(error.localizedDescription, privacy: .public)")
                store.update(id) { $0.download = .none; $0.downloadError = nil }
                return
            }
            listenLog.error("Listen download failed: \(error.localizedDescription, privacy: .public)")
            store.update(id) { $0.download = .failed; $0.downloadError = error.localizedDescription }
        }
    }

    /// An unfinished download's file, unless a live transfer still owns it.
    private func removePartial(_ id: UUID) {
        guard transfers[id] == nil, streams[id]?.transfer == nil else { return }
        ListenTransfer.partialFiles(for: id, in: directory).forEach { try? FileManager.default.removeItem(at: $0) }
    }

    /// Unfinished downloads of items still in Up Next resume later; the rest go.
    private func removeStrayPartials() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        for name in names where name.contains(".partial") {
            if let id = UUID(uuidString: String(name.prefix(36))), let item = store.item(id), item.isQueued,
               item.download != .downloaded {
                continue
            }
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }

    /// AVFoundation picks a decoder from the extension, so keep a real one.
    nonisolated static func fileExtension(url: URL, mime: String) -> String {
        let known = ["mp3", "m4a", "aac", "wav", "flac", "ogg", "opus", "mp4", "m4v", "mov", "webm", "caf", "aiff"]
        let ext = url.pathExtension.lowercased()
        if known.contains(ext) { return ext }
        switch mime {
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/mp4", "audio/x-m4a", "audio/aac": return "m4a"
        case "audio/wav", "audio/x-wav", "audio/wave": return "wav"
        case "audio/flac": return "flac"
        case "audio/ogg", "audio/opus": return "ogg"
        case "video/mp4": return "mp4"
        case "video/quicktime": return "mov"
        case "video/webm", "audio/webm": return "webm"
        default: return "mp3"
        }
    }
}

/// HTTP media carries only the scoped headers supplied by Listen, never the
/// process-wide cookie jar or saved URL credentials. Shared by downloads and artwork.
enum ListenMediaSession {
    static let shared = makeSession()

    static func makeSession(protocolClasses: [AnyClass]? = nil) -> URLSession {
        let configuration = IsolatedURLSession.configuration {
            if let protocolClasses { $0.protocolClasses = protocolClasses }
        }
        return URLSession(configuration: configuration, delegate: Delegate(), delegateQueue: nil)
    }

    // Stateless, but non-final so the data-task Forwarder can inherit the media
    // redirect policy. Subclasses must separately uphold Sendable invariants.
    class Delegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            // A redirect can leave the credential owner's mount even on the same
            // host. Follow public redirects, but don't forward scoped credentials.
            var redirected = request
            redirected.httpShouldHandleCookies = false
            redirected.setValue(nil, forHTTPHeaderField: "Cookie")
            redirected.setValue(nil, forHTTPHeaderField: "Authorization")
            completionHandler(redirected)
        }
    }
}
