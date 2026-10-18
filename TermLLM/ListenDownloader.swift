import Foundation
import Observation

/// Keeps Listen items on the phone so they play offline and seek instantly.
/// Files live in Application Support (not backed up). Media from the
/// connected server is fetched with the web view's sign-in cookie; other
/// hosts never get cookies.
@MainActor
@Observable
final class ListenDownloader {
    typealias Fetch = @Sendable (URLRequest, ListenTransfer) async throws -> (URL, URLResponse)

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

    @ObservationIgnored private let store: ListenStore
    @ObservationIgnored private let cookies: ListenCookieJar
    @ObservationIgnored private let server: () -> ListenServer?
    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored let directory: URL
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var waiting: [UUID] = []
    /// Downloads started only to cache what's streaming.
    @ObservationIgnored private var forPlayback: Set<UUID> = []

    init(store: ListenStore, cookies: ListenCookieJar, server: @escaping () -> ListenServer?,
         directory: URL = ListenDownloader.defaultDirectory,
         fetch: @escaping Fetch = ListenTransfer.fetch) {
        self.store = store
        self.cookies = cookies
        self.server = server
        self.directory = directory
        self.fetch = fetch
    }

    nonisolated static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Listen/Downloads", directoryHint: .isDirectory)
    }

    /// Server media is small and behind sign-in, so it's downloaded by
    /// default; podcast episodes elsewhere stream unless asked.
    func shouldDownloadAutomatically(_ item: ListenItem) -> Bool {
        server()?.isSameOrigin(item.url) ?? false
    }

    var activeCount: Int { tasks.count }

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
    /// otherwise the URL (with cookies only for the connected server).
    func source(for item: ListenItem) async -> ListenSource {
        if let local = localURL(for: item) { return ListenSource(url: local, spoken: item.kind != .music) }
        if item.download == .downloaded {
            // The file vanished; forget it.
            store.update(item.id) { $0.download = .none; $0.localFile = nil; $0.downloadedBytes = nil }
        }
        let sameServer = server()?.isSameOrigin(item.url) ?? false
        return ListenSource(url: item.url, cookies: sameServer ? await cookies.cookies(for: item.url) : [],
                            spoken: item.kind != .music)
    }

    /// Downloads `id`. `forPlayback` caches something that's streaming:
    /// it runs at low priority and the file goes once the item is played.
    func download(_ id: UUID, forPlayback: Bool = false) {
        guard let item = store.item(id) else { return }
        if !forPlayback {
            // Asked for explicitly: keep it, even if it started as a cache.
            self.forPlayback.remove(id)
            if item.cachedForPlayback == true { store.update(id) { $0.cachedForPlayback = nil } }
        }
        guard item.download != .downloaded || localURL(for: item) == nil,
              tasks[id] == nil, !waiting.contains(id) else { return }
        if forPlayback { self.forPlayback.insert(id) }
        store.update(id) { $0.download = .queued; $0.downloadError = nil }
        waiting.append(id)
        startWaiting()
    }

    func isCachingForPlayback(_ id: UUID) -> Bool { forPlayback.contains(id) }

    /// Deletes files that were only cached for streaming.
    func releasePlaybackCache(_ ids: [UUID]) {
        for id in ids {
            if forPlayback.contains(id) { cancel(id); continue }
            if store.item(id)?.cachedForPlayback == true { deleteFile(id) }
        }
    }

    func cancel(_ id: UUID) {
        waiting.removeAll { $0 == id }
        forPlayback.remove(id)
        progress[id] = nil
        tasks.removeValue(forKey: id)?.cancel()
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
        store.update(id) {
            $0.download = .none; $0.localFile = nil; $0.downloadedBytes = nil; $0.downloadError = nil; $0.cachedForPlayback = nil
        }
    }

    /// Deletes files for items that are no longer in the library.
    func removeFiles(for items: [ListenItem]) {
        for item in items {
            waiting.removeAll { $0 == item.id }
            forPlayback.remove(item.id)
            progress[item.id] = nil
            tasks.removeValue(forKey: item.id)?.cancel()
            if let name = item.localFile { try? FileManager.default.removeItem(at: directory.appending(path: name)) }
        }
        startWaiting()
    }

    // MARK: - Private

    private func startWaiting() {
        while tasks.count < Self.maxConcurrent, !waiting.isEmpty {
            let id = waiting.removeFirst()
            guard store.item(id) != nil else { continue }
            tasks[id] = Task { [weak self] in
                await self?.run(id)
            }
        }
    }

    private func run(_ id: UUID) async {
        let transfer = ListenTransfer(lowPriority: forPlayback.contains(id))
        progress[id] = Progress()
        let watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.progressInterval)
                guard !Task.isCancelled, let self, self.progress[id] != nil else { return }
                let now = transfer.snapshot
                let next = Progress(received: now.received, expected: now.expected)
                if self.progress[id] != next { self.progress[id] = next }
            }
        }
        defer {
            watcher.cancel()
            progress[id] = nil
            tasks.removeValue(forKey: id)
            startWaiting()
        }
        guard let item = store.item(id) else { return }
        store.update(id) { $0.download = .downloading }
        do {
            let file = try await fetchFile(for: item, transfer: transfer)
            try Task.checkCancellation()
            guard store.item(id) != nil else {
                try? FileManager.default.removeItem(at: directory.appending(path: file.name))
                return
            }
            let cached = forPlayback.remove(id) != nil
            store.update(id) {
                $0.download = .downloaded
                $0.localFile = file.name
                $0.downloadedBytes = file.bytes
                $0.downloadError = nil
                $0.cachedForPlayback = cached ? true : nil
            }
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
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

    private func fetchFile(for item: ListenItem, transfer: ListenTransfer) async throws -> (name: String, bytes: Int64) {
        let sameServer = server()?.isSameOrigin(item.url) ?? false
        var url = item.url
        // App Transport Security blocks plain http downloads; most hosts also
        // serve https. (Streaming plain http still works for media.)
        if !sameServer, url.scheme?.lowercased() == "http", var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.scheme = "https"
            url = components.url ?? url
        }
        var request = URLRequest(url: url, timeoutInterval: 60)
        if sameServer {
            HTTPCookie.requestHeaderFields(with: await cookies.cookies(for: url)).forEach {
                request.setValue($1, forHTTPHeaderField: $0)
            }
        }
        let (temporary, response) = try await fetch(request, transfer)
        defer { try? FileManager.default.removeItem(at: temporary) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ListenError.downloadFailed("the server answered \(http.statusCode)")
        }
        let mime = response.mimeType?.lowercased() ?? ""
        if mime.hasPrefix("text/html") || mime.hasPrefix("application/json") {
            throw ListenError.downloadFailed("\(item.url.absoluteString) is a web page, not an audio or video file")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var folder = directory
        try? folder.setResourceValues(values)

        let name = "\(item.id.uuidString).\(Self.fileExtension(url: item.url, mime: mime))"
        let destination = directory.appending(path: name)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: destination.path(percentEncoded: false))[.size] as? Int64) ?? nil
        return (name, bytes ?? 0)
    }

    /// AVFoundation picks a decoder from the extension, so keep a real one.
    static func fileExtension(url: URL, mime: String) -> String {
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

/// Lets the downloader read progress from a download in flight.
final class ListenTransfer: @unchecked Sendable {
    let lowPriority: Bool
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var reported: (received: Int64, expected: Int64?) = (0, nil)

    init(lowPriority: Bool = false) {
        self.lowPriority = lowPriority
    }

    var snapshot: (received: Int64, expected: Int64?) {
        lock.withLock {
            guard let task else { return reported }
            let expected = task.countOfBytesExpectedToReceive
            return (task.countOfBytesReceived, expected > 0 ? expected : nil)
        }
    }

    func attach(_ task: URLSessionTask) {
        if lowPriority { task.priority = URLSessionTask.lowPriority }
        lock.withLock { self.task = task }
    }

    /// For fetches that aren't a URLSession task (tests).
    func report(received: Int64, expected: Int64?) {
        lock.withLock { reported = (received, expected) }
    }

    @Sendable static func fetch(_ request: URLRequest, _ transfer: ListenTransfer) async throws -> (URL, URLResponse) {
        try await URLSession.shared.download(for: request, delegate: Watcher(transfer: transfer))
    }

    private final class Watcher: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let transfer: ListenTransfer
        init(transfer: ListenTransfer) { self.transfer = transfer }
        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) { transfer.attach(task) }
    }
}
