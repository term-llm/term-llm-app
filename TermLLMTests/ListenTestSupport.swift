import Foundation
@testable import TermLLM

/// Test doubles at the AVFoundation/WebKit boundary.

@MainActor
final class FakeListenEngine: ListenEngine {
    var onEvent: (@MainActor (ListenEngineEvent) -> Void)?
    var currentTime: TimeInterval = 0
    var duration: TimeInterval?
    var bufferedUntil: TimeInterval?
    var isStalled = false
    var loadError: Error?
    /// Durations reported per URL once loaded.
    var durations: [URL: TimeInterval] = [:]
    private(set) var loads: [(source: ListenSource, startAt: TimeInterval)] = []
    private(set) var playing = false
    private(set) var rates: [Float] = []
    private(set) var stops = 0

    func load(_ source: ListenSource, startAt: TimeInterval) async throws {
        loads.append((source, startAt))
        if let loadError { throw loadError }
        currentTime = startAt
        duration = durations[source.url]
    }

    func play(rate: Float) async throws {
        playing = true
        rates.append(rate)
    }

    func pause() { playing = false }

    func seek(to seconds: TimeInterval) async { currentTime = seconds }

    func setRate(_ rate: Float) { rates.append(rate) }

    func stop() {
        playing = false
        stops += 1
    }

    func send(_ event: ListenEngineEvent) { onEvent?(event) }
}

@MainActor
final class FakeCookieJar: ListenCookieJar {
    var cookies: [HTTPCookie] = []
    private(set) var requested: [URL] = []

    func cookies(for url: URL) async -> [HTTPCookie] {
        requested.append(url)
        return cookies
    }
}

let testServer = ListenServer(base: URL(string: "https://hub.example/ui/")!)

func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "listen-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func draft(_ name: String, title: String? = nil, host: String = "pod.example") -> ListenDraft {
    ListenDraft(url: URL(string: "https://\(host)/\(name).mp3")!, title: title)
}

/// `server` stands in for the network; by default nothing is there (404).
@MainActor
func makeListen(engine: FakeListenEngine? = nil, cookies: FakeCookieJar? = nil,
                directory: URL = temporaryDirectory(),
                server: FakeMediaServer = FakeMediaServer(),
                fetching: ListenFetching? = nil, artwork: ListenArtworkStore? = nil) -> Listen {
    let engine = engine ?? FakeListenEngine()
    let cookies = cookies ?? FakeCookieJar()
    return Listen(store: ListenStore(fileURL: directory.appending(path: "library.json")), engine: engine, cookies: cookies,
           server: { testServer }, artwork: artwork, downloadDirectory: directory.appending(path: "Downloads"),
           fetching: fetching ?? server, retryDelays: [0.01, 0.01], defaults: isolatedDefaults())
}

/// Serves files by byte range in place of the network, like a web server
/// with `Range`/`If-Range` support, and counts the body bytes it sends.
/// Unknown URLs answer 404.
final class FakeMediaServer: ListenFetching, @unchecked Sendable {
    struct File {
        var body: Data
        var mime = "audio/mpeg"
        var etag: String? = "\"v1\""
        /// False: ignores Range and always sends the whole file.
        var ranges = true
        var status = 200
    }

    private let lock = NSLock()
    private var files: [URL: File] = [:]
    private var log: [URLRequest] = []
    private var sent = 0
    private var holding: Range<Int>?
    private var parked: [@Sendable () -> Void] = []
    private var drops: [Int] = []

    func serve(_ url: URL, _ file: File) { lock.withLock { files[url] = file } }
    func remove(_ url: URL) { lock.withLock { files[url] = nil } }

    var requests: [URLRequest] { lock.withLock { log } }
    /// Body bytes sent, as the network would carry them.
    var bytesSent: Int { lock.withLock { sent } }
    func ranges(for url: URL) -> [String] {
        requests.filter { $0.url == url }.map { $0.value(forHTTPHeaderField: "Range") ?? "-" }
    }

    /// File bytes in `range` wait until `release()`.
    func hold(_ range: Range<Int>?) { lock.withLock { holding = range } }

    func release() {
        let waiting = lock.withLock {
            holding = nil
            defer { parked = [] }
            return parked
        }
        waiting.forEach { $0() }
    }

    /// The next request's connection drops after sending `bytes`.
    func dropNext(after bytes: Int) { lock.withLock { drops.append(bytes) } }

    func start(_ request: URLRequest, queue: DispatchQueue,
               events: @escaping @Sendable (ListenFetchEvent) -> Void) -> @Sendable () -> Void {
        let cancelled = Cancelled()
        let (file, drop) = lock.withLock { () -> (File?, Int?) in
            log.append(request)
            return (request.url.flatMap { files[$0] }, drops.isEmpty ? nil : drops.removeFirst())
        }
        let url = request.url ?? URL(string: "https://unknown.example")!
        guard let file, file.status == 200 else {
            let status = file?.status ?? 404
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "text/plain", "Content-Length": "0"])!
            queue.async {
                events(.response(response))
                events(.finished(nil))
            }
            return { cancelled.set() }
        }
        let total = file.body.count
        var start = 0, end = total, status = 200
        var headers = ["Content-Type": file.mime]
        if let etag = file.etag { headers["ETag"] = etag }
        if file.ranges, let range = request.value(forHTTPHeaderField: "Range"), let asked = Self.parse(range),
           request.value(forHTTPHeaderField: "If-Range").map({ $0 == file.etag }) ?? true {
            guard asked.start < total else {
                let response = HTTPURLResponse(url: url, statusCode: 416, httpVersion: "HTTP/1.1",
                                               headerFields: ["Content-Range": "bytes */\(total)"])!
                queue.async {
                    events(.response(response))
                    events(.finished(nil))
                }
                return { cancelled.set() }
            }
            start = asked.start
            end = min(total, asked.end.map { $0 + 1 } ?? total)
            status = 206
            headers["Content-Range"] = "bytes \(start)-\(end - 1)/\(total)"
        }
        headers["Content-Length"] = String(end - start)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        let (from, to) = (start, end)
        queue.async {
            events(.response(response))
            self.send(file.body, from: from, to: to, dropAt: drop.map { from + $0 }, queue: queue,
                      events: events, cancelled: cancelled)
        }
        return { cancelled.set() }
    }

    private func send(_ body: Data, from offset: Int, to end: Int, dropAt: Int?, queue: DispatchQueue,
                      events: @escaping @Sendable (ListenFetchEvent) -> Void, cancelled: Cancelled) {
        var offset = offset
        while offset < end {
            if cancelled.isSet { return }
            if let dropAt, offset >= dropAt { return events(.finished(URLError(.networkConnectionLost))) }
            let held = lock.withLock { holding }
            if let held, held.contains(offset) {
                let resume = offset
                lock.withLock {
                    parked.append {
                        queue.async {
                            self.send(body, from: resume, to: end, dropAt: dropAt, queue: queue,
                                      events: events, cancelled: cancelled)
                        }
                    }
                }
                return
            }
            var chunkEnd = min(end, offset + (64 << 10))
            if let held, held.lowerBound > offset { chunkEnd = min(chunkEnd, held.lowerBound) }
            if let dropAt, dropAt > offset { chunkEnd = min(chunkEnd, dropAt) }
            lock.withLock { sent += chunkEnd - offset }
            events(.data(body.subdata(in: offset..<chunkEnd)))
            offset = chunkEnd
        }
        if !cancelled.isSet { events(.finished(nil)) }
    }

    private static func parse(_ header: String) -> (start: Int, end: Int?)? {
        guard header.hasPrefix("bytes=") else { return nil }
        let parts = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let start = Int(parts[0]) else { return nil }
        return (start, Int(parts[1]))
    }

    private final class Cancelled: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }
}

/// Reads from a transfer the way AVFoundation's loading requests do.
final class FakeRead: ListenTransferRead, @unchecked Sendable {
    private let lock = NSLock()
    private let start: Int64
    private let end: Int64?
    private let asksInfo: Bool
    private let dataless: Bool
    private var _info: (type: String, length: Int64)?
    private var _data = Data()
    private var _finished = false
    private var _error: Error?
    private var _cancelled = false

    init(_ start: Int64, length: Int64? = nil, info: Bool = false, dataless: Bool = false) {
        self.start = start
        end = length.map { start + $0 }
        asksInfo = info
        self.dataless = dataless
    }

    var info: (type: String, length: Int64)? { lock.withLock { _info } }
    var data: Data { lock.withLock { _data } }
    var finished: Bool { lock.withLock { _finished } }
    var error: Error? { lock.withLock { _error } }
    func cancel() { lock.withLock { _cancelled = true } }

    var isDone: Bool { lock.withLock { _cancelled || _finished || _error != nil } }
    var wantsInfo: Bool { lock.withLock { asksInfo && _info == nil } }
    func provide(type: String, length: Int64) { lock.withLock { _info = (type, length) } }
    var wanted: (offset: Int64, end: Int64?)? {
        lock.withLock { dataless ? nil : (start + Int64(_data.count), end) }
    }
    func respond(with data: Data) { lock.withLock { _data.append(data) } }
    func finish() { lock.withLock { _finished = true } }
    func fail(_ error: Error) { lock.withLock { _error = error } }
}

/// Polls until `condition` holds (or a few seconds pass).
@MainActor
func eventually(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

/// Distinct bytes, so misplaced ranges show up.
func mediaBody(_ count: Int) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: ($0 >> 8) &+ ($0 &* 7)) })
}

/// Waits for main-actor tasks spawned by the code under test.
@MainActor
func settle() async {
    for _ in 0..<20 { await Task.yield() }
}
