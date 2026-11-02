import AVFoundation
import Foundation
import UniformTypeIdentifiers

// One download per Listen item, fetched by byte range. Playback reads through
// it, so streaming an episode and saving it fetch each byte once.

/// Byte ranges of a file that are on the phone, sorted and merged.
struct ListenByteRanges: Equatable, Sendable {
    private(set) var ranges: [Range<Int64>] = []

    init(_ ranges: [Range<Int64>] = []) {
        ranges.forEach { insert($0) }
    }

    var isEmpty: Bool { ranges.isEmpty }
    /// Bytes held.
    var total: Int64 { ranges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) } }

    mutating func insert(_ new: Range<Int64>) {
        guard !new.isEmpty else { return }
        var lower = new.lowerBound, upper = new.upperBound
        var merged: [Range<Int64>] = []
        var placed = false
        for range in ranges {
            if range.upperBound < lower {
                merged.append(range)
            } else if range.lowerBound > upper {
                if !placed { merged.append(lower..<upper); placed = true }
                merged.append(range)
            } else {
                lower = min(lower, range.lowerBound)
                upper = max(upper, range.upperBound)
            }
        }
        if !placed { merged.append(lower..<upper) }
        ranges = merged
    }

    /// Drops anything at or past `limit`.
    mutating func clamp(below limit: Int64) {
        ranges = ranges.compactMap { $0.lowerBound < limit ? $0.lowerBound..<min($0.upperBound, limit) : nil }
    }

    func contains(_ offset: Int64) -> Bool { runEnd(at: offset) != nil }

    /// The end of the held run that contains `offset`.
    func runEnd(at offset: Int64) -> Int64? {
        for range in ranges {
            if range.lowerBound > offset { return nil }
            if offset < range.upperBound { return range.upperBound }
        }
        return nil
    }

    /// The first byte at or after `offset`, below `limit`, that isn't held.
    func firstMissing(from offset: Int64, below limit: Int64) -> Int64? {
        var position = max(0, offset)
        for range in ranges where range.upperBound > position {
            if range.lowerBound > position { break }
            position = range.upperBound
        }
        return position < limit ? position : nil
    }

    /// Where the first held run after `offset` starts.
    func nextStart(after offset: Int64) -> Int64? {
        ranges.first { $0.lowerBound > offset }?.lowerBound
    }

    func covers(_ length: Int64) -> Bool {
        length <= 0 || ranges.first.map { $0.lowerBound <= 0 && $0.upperBound >= length } == true
    }
}

// MARK: - Fetching

/// What one range request reports, in order, on the transfer's queue.
enum ListenFetchEvent: Sendable {
    case response(HTTPURLResponse)
    case data(Data)
    case finished(Error?)
}

/// Sends a transfer's HTTP requests. Tests substitute a fake server.
protocol ListenFetching: Sendable {
    /// Starts `request`; `events` are called on `queue`. Returns a cancel action.
    func start(_ request: URLRequest, queue: DispatchQueue,
               events: @escaping @Sendable (ListenFetchEvent) -> Void) -> @Sendable () -> Void
}

/// Requests through `ListenMediaSession`: no ambient cookies or credentials,
/// and redirects drop the scoped ones.
struct ListenSessionFetching: ListenFetching {
    var session: URLSession = ListenMediaSession.shared
    var usage: ListenNetworkUsage = .shared

    func start(_ request: URLRequest, queue: DispatchQueue,
               events: @escaping @Sendable (ListenFetchEvent) -> Void) -> @Sendable () -> Void {
        var request = request
        request.httpShouldHandleCookies = false
        let task = session.dataTask(with: request)
        task.delegate = Forwarder(queue: queue, usage: usage, events: events)
        task.resume()
        return { task.cancel() }
    }

    /// A task delegate that keeps the session delegate's redirect rule.
    private final class Forwarder: ListenMediaSession.Delegate, URLSessionDataDelegate, @unchecked Sendable {
        let queue: DispatchQueue
        let usage: ListenNetworkUsage
        let events: @Sendable (ListenFetchEvent) -> Void

        init(queue: DispatchQueue, usage: ListenNetworkUsage,
             events: @escaping @Sendable (ListenFetchEvent) -> Void) {
            self.queue = queue
            self.usage = usage
            self.events = events
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            guard let http = response as? HTTPURLResponse else {
                completionHandler(.cancel)
                return
            }
            let events = events
            queue.async { events(.response(http)) }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            // Count actual received bodies, even if the transfer later rejects
            // the response, cancels this request or discards overlapping bytes.
            usage.record(bytes: Int64(data.count))
            let events = events
            queue.async { events(.data(data)) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            usage.flush()
            let events = events
            queue.async { events(.finished(error)) }
        }
    }
}

// MARK: - Reads

/// A read by playback: `AVAssetResourceLoadingRequest` in the app.
protocol ListenTransferRead: AnyObject {
    var isDone: Bool { get }
    /// Wants the content type and length.
    var wantsInfo: Bool { get }
    func provide(type: String, length: Int64)
    /// The next byte wanted and where the read ends (nil: the end of the
    /// file). Nil when it only wants information.
    var wanted: (offset: Int64, end: Int64?)? { get }
    func respond(with data: Data)
    func finish()
    func fail(_ error: Error)
}

private final class LoaderRead: ListenTransferRead {
    let request: AVAssetResourceLoadingRequest

    init(_ request: AVAssetResourceLoadingRequest) { self.request = request }

    var isDone: Bool { request.isCancelled || request.isFinished }
    var wantsInfo: Bool { request.contentInformationRequest.map { $0.contentType == nil } ?? false }

    func provide(type: String, length: Int64) {
        guard let info = request.contentInformationRequest else { return }
        info.contentType = type
        info.contentLength = length
        info.isByteRangeAccessSupported = true
    }

    var wanted: (offset: Int64, end: Int64?)? {
        guard let data = request.dataRequest else { return nil }
        let end = data.requestsAllDataToEndOfResource ? nil : data.requestedOffset + Int64(data.requestedLength)
        return (data.currentOffset, end)
    }

    func respond(with data: Data) { request.dataRequest?.respond(with: data) }
    func finish() { request.finishLoading() }
    func fail(_ error: Error) { request.finishLoading(with: error) }
}

// MARK: - Transfer

/// Downloads one Listen item into a file by byte ranges. Explicit downloads
/// fill every hole; playback-only caches stay near the newest playback read.
/// The bound is speculative only: outstanding reads are served in full, and
/// servers ignoring ranges/omitting totals fall back to whole-file fetching.
/// A partial file outlives the app and resumes with If-Range, so a file that
/// changed on the server starts over.
final class ListenTransfer: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    struct Saved: Sendable {
        let file: URL
        let bytes: Int64
        let mime: String?
    }

    static let scheme = "termllm-listen"
    static let retryDelays: [TimeInterval] = [1, 2, 4, 8, 15, 15]
    /// A read at most this far ahead of the request in flight may wait for it
    /// (if it's moving and gets there within `waitTime`) instead of starting
    /// another request there.
    static let waitWindow: Int64 = 1 << 20
    static let waitTime: TimeInterval = 2
    /// How often the partial file's record is saved while downloading: at
    /// most this much is fetched again if the app is killed.
    static let recordInterval: Int64 = 1 << 20
    /// Most bytes handed to one read at a time, so cancellation gets in.
    static let readSlice: Int64 = 1 << 20
    /// Automatic caching may fetch this far ahead of the newest submitted
    /// playback read, not ahead of its own background download cursor.
    static let playbackLookahead: Int64 = 3 << 20

    let id: UUID
    let queue = DispatchQueue(label: "TermLLM.ListenTransfer")
    /// What AVFoundation opens; only this delegate can load it.
    let assetURL: URL

    private let remote: URL
    private let directory: URL
    private let partialURL: URL
    private let recordURL: URL
    private let fetching: ListenFetching
    private let retryDelays: [TimeInterval]
    private let makeRequest: @Sendable (URL) async -> URLRequest
    private let finished: @Sendable (ListenTransfer, Result<Saved, Error>) -> Void

    // Everything below is confined to `queue` (or to init and deinit).
    private var file: FileHandle?
    private var held = ListenByteRanges()
    private var length: Int64?
    private var mime: String?
    private var validator: String?
    /// Save ahead of playback, or (by default) fetch the whole file.
    private var saving = true
    private var playbackOnly: Bool
    /// Changes only when playback submits a read, never as prefetch arrives.
    private var playbackOffset: Int64 = 0
    /// Leave an unfinished file for a later resume.
    private var keepsPartial = true
    /// The server answers byte ranges (it sent a 200 to one: it doesn't).
    private var rangesWork = true
    /// A server omitting the total length requires EOF discovery before we
    /// can provide AVFoundation's content information. Don't invent EOF at
    /// the end of our first bounded response.
    private var requiresEOF = false
    private var reads: [any ListenTransferRead] = []
    private var request: InFlight?
    private var generation = 0
    private var failures = 0
    private var restarts = 0
    private var retry: DispatchWorkItem?
    private var unrecorded: Int64 = 0
    /// Where filling continues: the end of the last request.
    private var fillFrom: Int64 = 0
    private var serveQueued = false
    private var recheckQueued = false
    private var phase = Phase.running

    private enum Phase {
        case running
        case saved(Saved)
        case failed(Error)
        case cancelled
    }

    private struct InFlight {
        let generation: Int
        let start: Int64
        var offset: Int64
        var end: Int64?
        var answered = false
        /// A bounded 206 with an unknown total must not be mistaken for EOF.
        var partialResponse = false
        var delivered: Int64 = 0
        var firstData: TimeInterval?
        var lastData: TimeInterval?
        var cancel: (@Sendable () -> Void)?

        /// Whether `offset` arrives through this request within `waitTime`.
        func arrives(_ offset: Int64, now: TimeInterval) -> Bool {
            let distance = offset - self.offset
            guard distance >= 0, distance <= ListenTransfer.waitWindow, end.map({ offset < $0 }) ?? true else { return false }
            // Asking again for the very next byte gains nothing.
            if distance == 0 { return true }
            guard let firstData, let lastData else { return true } // still starting
            // Stalled short of it: a request there may well be quicker.
            guard now - lastData < 1 else { return false }
            let rate = Double(delivered) / max(now - firstData, 0.05)
            return Double(distance) / max(rate, 1) <= ListenTransfer.waitTime
        }
    }

    private struct Record: Codable {
        var url: String
        var length: Int64?
        var mime: String?
        var validator: String?
        var ranges: [[Int64]]
    }

    init(id: UUID, remote: URL, directory: URL, fetching: ListenFetching,
         retryDelays: [TimeInterval] = ListenTransfer.retryDelays,
         playbackOnly: Bool = false,
         makeRequest: @escaping @Sendable (URL) async -> URLRequest,
         finished: @escaping @Sendable (ListenTransfer, Result<Saved, Error>) -> Void) {
        self.id = id
        self.remote = remote
        self.directory = directory
        self.fetching = fetching
        self.retryDelays = retryDelays
        self.playbackOnly = playbackOnly
        self.makeRequest = makeRequest
        self.finished = finished
        partialURL = directory.appending(path: "\(id.uuidString).partial")
        recordURL = directory.appending(path: "\(id.uuidString).partial.json")
        let ext = remote.pathExtension.isEmpty ? "" : "." + remote.pathExtension.lowercased()
        assetURL = URL(string: "\(Self.scheme)://item/\(id.uuidString)\(ext)") ?? URL(string: "\(Self.scheme)://item")!
        super.init()
        openPartial()
    }

    deinit {
        request?.cancel?()
        retry?.cancel()
        switch phase {
        case .saved: break
        case .running where keepsPartial: record()
        default:
            if !keepsPartial {
                try? FileManager.default.removeItem(at: partialURL)
                try? FileManager.default.removeItem(at: recordURL)
            }
        }
        try? file?.close()
    }

    /// Partial files of `id`, for clean-up.
    static func partialFiles(for id: UUID, in directory: URL) -> [URL] {
        ["partial", "partial.json"].map { directory.appending(path: "\(id.uuidString).\($0)") }
    }

    // MARK: Control

    /// Starts or continues downloading.
    func start() {
        queue.async {
            if case .failed(let error) = self.phase, self.file == nil {
                return self.finished(self, .failure(error)) // couldn't create its file
            }
            self.schedule()
        }
    }

    /// Saving can be a bounded playback cache or a whole-file download.
    /// The default promotes a playback cache without replacing its transfer.
    /// Stopping saving still serves only demanded bytes and discards the partial.
    func setSaving(_ saving: Bool, playbackOnly: Bool = false) {
        queue.async {
            self.saving = saving
            self.playbackOnly = playbackOnly
            self.keepsPartial = saving
            self.schedule()
        }
    }

    /// Stops for good. A kept partial file resumes next time.
    func cancel(keepingPartial: Bool) {
        queue.async {
            guard case .running = self.phase else { return }
            self.phase = .cancelled
            self.stopRequest()
            self.failReads(CancellationError())
            if keepingPartial {
                self.record()
                try? self.file?.close()
                self.file = nil
            } else {
                self.keepsPartial = false
                self.discardPartial()
            }
        }
    }

    /// Bytes on the phone and the file's size, once known.
    var progress: (received: Int64, expected: Int64?) {
        queue.sync { (held.total, length) }
    }

    /// Reads as playback would (tests).
    func read(_ read: any ListenTransferRead) {
        let pending = PendingRead(read: read)
        queue.async { self.add(pending.read) }
    }

    private struct PendingRead: @unchecked Sendable {
        let read: any ListenTransferRead
    }

    // MARK: AVAssetResourceLoaderDelegate (on `queue`)

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard loadingRequest.request.url?.scheme == Self.scheme else { return false }
        add(LoaderRead(loadingRequest))
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        reads.removeAll { ($0 as? LoaderRead)?.request === loadingRequest }
        schedule()
    }

    // MARK: Reads

    private func add(_ read: any ListenTransferRead) {
        switch phase {
        case .failed(let error): return read.fail(error)
        case .cancelled: return read.fail(CancellationError())
        case .running, .saved: break
        }
        if let wanted = read.wanted, !read.isDone {
            playbackOffset = max(0, wanted.offset)
        }
        reads.append(read)
        serve()
        schedule()
    }

    /// Answers reads from the file, as far as it's there.
    private func serve() {
        guard let file, let length else { return }
        var more = false
        reads.removeAll { read in
            if read.isDone { return true }
            if read.wantsInfo {
                guard let type = contentType() else { return false }
                read.provide(type: type, length: length)
            }
            guard let wanted = read.wanted else {
                read.finish()
                return true
            }
            let end = min(wanted.end ?? length, length)
            var offset = wanted.offset
            var budget = Self.readSlice
            while offset < end, budget > 0, let run = held.runEnd(at: offset) {
                let count = min(run, end, offset + budget) - offset
                guard let data = try? Self.read(file, at: offset, count: count), !data.isEmpty else { break }
                read.respond(with: data)
                offset += Int64(data.count)
                budget -= Int64(data.count)
            }
            if offset >= end {
                read.finish()
                return true
            }
            if budget <= 0 { more = true }
            return false
        }
        if more, !serveQueued {
            serveQueued = true
            queue.async {
                self.serveQueued = false
                self.serve()
            }
        }
    }

    private func failReads(_ error: Error) {
        for read in reads where !read.isDone { read.fail(error) }
        reads = []
    }

    /// The missing byte the newest waiting read needs. After a seek, the
    /// newest read is where playback went, while older ones may still be
    /// pending at the old position.
    private func urgentOffset() -> Int64? {
        for read in reads.reversed() where !read.isDone {
            let offset: Int64
            if let wanted = read.wanted {
                offset = wanted.offset
                if let end = wanted.end, offset >= end { continue }
            } else if read.wantsInfo, length == nil {
                offset = 0
            } else {
                continue
            }
            if let length, offset >= length { continue }
            if held.contains(offset) { continue }
            return offset
        }
        return nil
    }

    private func contentType() -> String? {
        if let type = mime.flatMap({ UTType(mimeType: $0) }), let playable = Self.playable(type) { return playable }
        if let type = UTType(filenameExtension: remote.pathExtension), let playable = Self.playable(type) { return playable }
        guard let file, held.runEnd(at: 0).map({ $0 >= 12 }) == true,
              let head = try? Self.read(file, at: 0, count: 12) else { return nil }
        return Self.sniff(head)
    }

    private static let playableTypes: [UTType] = AVURLAsset.audiovisualTypes().compactMap { UTType($0.rawValue) }

    /// The type itself if AVFoundation opens it, or one it opens that it is a kind of.
    private static func playable(_ type: UTType) -> String? {
        guard type.conforms(to: .audiovisualContent) else { return nil }
        if playableTypes.contains(type) { return type.identifier }
        return playableTypes.first { type.conforms(to: $0) }?.identifier
    }

    /// Recognises a file from its first bytes when the server and URL don't say.
    static func sniff(_ head: Data) -> String {
        let bytes = [UInt8](head.prefix(12))
        func text(_ range: Range<Int>) -> String {
            bytes.count >= range.upperBound ? String(decoding: bytes[range], as: UTF8.self) : ""
        }
        if text(4..<8) == "ftyp" { return AVFileType.mp4.rawValue }
        if text(0..<4) == "RIFF", text(8..<12) == "WAVE" { return AVFileType.wav.rawValue }
        if text(0..<4) == "fLaC" { return "org.xiph.flac" }
        if text(0..<4) == "caff" { return AVFileType.caf.rawValue }
        if text(0..<4) == "FORM" { return text(8..<12) == "AIFC" ? AVFileType.aifc.rawValue : AVFileType.aiff.rawValue }
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] & 0xF6 == 0xF0 { return "public.aac-audio" }
        return AVFileType.mp3.rawValue
    }

    // MARK: Scheduling

    private func schedule() {
        guard case .running = phase, file != nil else { return }
        if let length, held.covers(length) { return save() }
        let urgent = urgentOffset()
        if let request {
            if let urgent {
                // Without ranges a new request would start from the top: wait.
                guard rangesWork else { return }
                if request.arrives(urgent, now: ProcessInfo.processInfo.systemUptime) {
                    recheckSoon()
                    return
                }
                // A read wants bytes this request won't bring soon.
                stopRequest()
            } else if saving, playbackOnly, !requiresEOF {
                // A server ignoring Range keeps its single full response:
                // cancelling it would repeatedly download the same prefix.
                guard rangesWork else { return }
                // A cached read can move the playhead too. Don't continue an
                // old prefetch outside its new window.
                guard request.offset < playbackLimit, request.offset >= playbackOffset else {
                    stopRequest()
                    record()
                    return schedule()
                }
                return
            } else {
                // Not saving: stop once playback has what it asked for.
                if !saving, reads.isEmpty, rangesWork { stopRequest() }
                return
            }
        } else if retry != nil {
            return // backing off after a failed request
        }
        if let urgent {
            // Demand is always served, including a large/all-to-end read, but
            // each playback-cache request is finite. Demand does not move the
            // background window forward just because bytes arrived.
            begin(at: urgent, limit: playbackOnly && saving && !requiresEOF ? ahead(of: urgent) : nil)
        } else if saving, let next = nextToFill() {
            begin(at: next, limit: playbackOnly && !requiresEOF ? playbackLimit : nil)
        }
    }

    /// Looks again in a second, in case the request in flight stalls.
    private func recheckSoon() {
        guard !recheckQueued else { return }
        recheckQueued = true
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.recheckQueued = false
            self?.schedule()
        }
    }

    private func ahead(of offset: Int64) -> Int64 {
        min(offset, Int64.max - Self.playbackLookahead) + Self.playbackLookahead
    }

    private var playbackLimit: Int64 { min(length ?? .max, ahead(of: playbackOffset)) }

    private func nextToFill() -> Int64? {
        if playbackOnly, !requiresEOF {
            return held.firstMissing(from: playbackOffset, below: playbackLimit)
        }
        guard let length else { return held.firstMissing(from: 0, below: .max) }
        return held.firstMissing(from: fillFrom, below: length) ?? held.firstMissing(from: 0, below: length)
    }

    private func begin(at start: Int64, limit: Int64? = nil) {
        generation += 1
        let generation = generation
        // Stop where bytes already here begin, so nothing is fetched twice.
        var boundedEnd = held.nextStart(after: start)
        if let limit { boundedEnd = min(boundedEnd ?? .max, limit, length ?? .max) }
        let end = boundedEnd
        request = InFlight(generation: generation, start: start, offset: start, end: end)
        let resuming = !held.isEmpty
        let validator = validator
        let remote = remote
        let makeRequest = makeRequest
        Task {
            var http = await makeRequest(remote)
            http.setValue("bytes=\(start)-\(end.map { String($0 - 1) } ?? "")", forHTTPHeaderField: "Range")
            if resuming, let validator { http.setValue(validator, forHTTPHeaderField: "If-Range") }
            let request = http
            self.queue.async { self.launch(request, generation) }
        }
    }

    private func launch(_ http: URLRequest, _ generation: Int) {
        guard case .running = phase, request?.generation == generation else { return }
        request?.cancel = fetching.start(http, queue: queue) { [weak self] event in
            self?.handle(event, generation)
        }
    }

    private func stopRequest() {
        if let request {
            fillFrom = request.offset
            request.cancel?()
        }
        request = nil
        generation += 1
    }

    // MARK: Responses

    private func handle(_ event: ListenFetchEvent, _ generation: Int) {
        guard case .running = phase, request?.generation == generation else { return }
        switch event {
        case .response(let response): answered(response)
        case .data(let data): received(data)
        case .finished(let error): ended(error)
        }
    }

    private func answered(_ response: HTTPURLResponse) {
        guard var request else { return }
        let type = response.mimeType?.lowercased() ?? ""
        if type.hasPrefix("text/html") || type.hasPrefix("application/json") {
            return fail(ListenError.downloadFailed("\(remote.absoluteString) is a web page, not an audio or video file"),
                        discard: true)
        }
        let tag = Self.validator(of: response)
        switch response.statusCode {
        case 206:
            guard let range = Self.contentRange(of: response) else {
                return fail(ListenError.downloadFailed("the server sent an unreadable byte range"), discard: false)
            }
            if let total = range.total, let length, total != length { return startOver() }
            if let tag, let validator, tag != validator, !held.isEmpty { return startOver() }
            length = range.total ?? length
            request.partialResponse = range.total == nil && request.end != nil
            if length == nil, request.partialResponse, playbackOnly { requiresEOF = true }
            request.offset = range.start
        case 200:
            // The whole file from its first byte: the server ignores ranges, or
            // (If-Range) the file changed since the partial download.
            let size = response.expectedContentLength > 0 ? response.expectedContentLength : nil
            if !held.isEmpty, validator == nil || tag != validator || (size != nil && length != nil && size != length) {
                held = ListenByteRanges()
                try? file?.truncate(atOffset: 0)
            } else if request.start > 0
                        || response.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased().contains("bytes") != true {
                rangesWork = false
            }
            length = size ?? (held.isEmpty ? nil : length)
            // Playback's finite Range was ignored (or If-Range changed).
            // Keep this one full response rather than refetching prefixes.
            if saving, playbackOnly { rangesWork = false }
            request.offset = 0
            request.end = nil
        case 416:
            return startOver()
        default:
            return fail(ListenError.downloadFailed("the server answered \(response.statusCode)"), discard: false)
        }
        validator = tag ?? validator
        mime = response.mimeType ?? mime
        request.answered = true
        self.request = request
        serve()
    }

    private func received(_ data: Data) {
        guard var request, request.answered, let file else { return }
        do {
            try file.seek(toOffset: UInt64(request.offset))
            try file.write(contentsOf: data)
        } catch {
            return fail(error, discard: false)
        }
        let start = request.offset
        let now = ProcessInfo.processInfo.systemUptime
        request.offset += Int64(data.count)
        request.delivered += Int64(data.count)
        request.firstData = request.firstData ?? now
        request.lastData = now
        self.request = request
        held.insert(start..<request.offset)
        failures = 0
        unrecorded += Int64(data.count)
        if unrecorded >= Self.recordInterval { record() }
        serve()
        if let length, held.covers(length) { return save() }
        schedule()
    }

    private func ended(_ error: Error?) {
        guard let request else { return }
        self.request = nil
        fillFrom = request.offset
        if let error {
            guard Self.isTransient(error), failures < retryDelays.count else { return fail(error, discard: false) }
            let delay = retryDelays[failures]
            failures += 1
            record()
            let work = DispatchWorkItem { [weak self] in
                self?.retry = nil
                self?.schedule()
            }
            retry = work
            queue.asyncAfter(deadline: .now() + delay, execute: work)
            return
        }
        // Never ask again for what just came back empty.
        guard request.delivered > 0 || length == 0 else {
            return fail(ListenError.downloadFailed("the server sent no data"), discard: false)
        }
        // An unbounded response without a length ends at its last byte. A
        // bounded 206 may simply have reached our requested end, not EOF.
        if length == nil, request.answered, !request.partialResponse { length = request.offset }
        record()
        serve()
        schedule()
    }

    /// The file changed size or version on the server: drop what's here.
    private func startOver() {
        stopRequest()
        restarts += 1
        guard restarts <= 2 else {
            return fail(ListenError.downloadFailed("the file keeps changing on the server"), discard: true)
        }
        held = ListenByteRanges()
        length = nil
        validator = nil
        requiresEOF = false
        fillFrom = 0
        try? file?.truncate(atOffset: 0)
        try? FileManager.default.removeItem(at: recordURL)
        schedule()
    }

    private func fail(_ error: Error, discard: Bool) {
        guard case .running = phase else { return }
        phase = .failed(error)
        stopRequest()
        retry?.cancel()
        retry = nil
        failReads(error)
        if discard {
            keepsPartial = false
            discardPartial()
        } else {
            record()
        }
        finished(self, .failure(error))
    }

    /// Everything is here: becomes the item's file.
    private func save() {
        guard case .running = phase, let file, let length else { return }
        stopRequest()
        do {
            try file.synchronize()
            let name = "\(id.uuidString).\(ListenDownloader.fileExtension(url: remote, mime: mime?.lowercased() ?? ""))"
            let destination = directory.appending(path: name)
            try? FileManager.default.removeItem(at: destination)
            // The open handle keeps reading the moved file.
            try FileManager.default.moveItem(at: partialURL, to: destination)
            try? FileManager.default.removeItem(at: recordURL)
            let saved = Saved(file: destination, bytes: length, mime: mime)
            phase = .saved(saved)
            serve()
            finished(self, .success(saved))
        } catch {
            fail(error, discard: false)
        }
    }

    // MARK: Files

    private func openPartial() {
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var folder = directory
        try? folder.setResourceValues(values)
        let path = partialURL.path(percentEncoded: false)
        if manager.fileExists(atPath: path), let data = try? Data(contentsOf: recordURL),
           let saved = try? JSONDecoder().decode(Record.self, from: data), saved.url == remote.absoluteString {
            length = saved.length
            mime = saved.mime
            validator = saved.validator
            held = ListenByteRanges(saved.ranges.compactMap { $0.count == 2 && $0[0] < $0[1] ? $0[0]..<$0[1] : nil })
        } else {
            try? manager.removeItem(at: partialURL)
            try? manager.removeItem(at: recordURL)
        }
        if !manager.fileExists(atPath: path) { manager.createFile(atPath: path, contents: nil) }
        file = try? FileHandle(forUpdating: partialURL)
        // Never trust a record past what's in the file.
        if let size = try? file?.seekToEnd() { held.clamp(below: Int64(size)) }
        fillFrom = held.firstMissing(from: 0, below: .max) ?? 0
        if file == nil { phase = .failed(ListenError.storageUnavailable("Listen couldn't create a file for this item.")) }
    }

    private func record() {
        guard keepsPartial, let file, !held.isEmpty else { return }
        try? file.synchronize()
        let saved = Record(url: remote.absoluteString, length: length, mime: mime, validator: validator,
                           ranges: held.ranges.map { [$0.lowerBound, $0.upperBound] })
        try? JSONEncoder().encode(saved).write(to: recordURL, options: .atomic)
        unrecorded = 0
    }

    private func discardPartial() {
        try? file?.close()
        file = nil
        try? FileManager.default.removeItem(at: partialURL)
        try? FileManager.default.removeItem(at: recordURL)
    }

    private static func read(_ file: FileHandle, at offset: Int64, count: Int64) throws -> Data? {
        try file.seek(toOffset: UInt64(offset))
        return try file.read(upToCount: Int(count))
    }

    // MARK: HTTP

    /// A strong ETag, else Last-Modified: what If-Range accepts.
    static func validator(of response: HTTPURLResponse) -> String? {
        if let tag = response.value(forHTTPHeaderField: "ETag"), !tag.hasPrefix("W/") { return tag }
        return response.value(forHTTPHeaderField: "Last-Modified")
    }

    /// `Content-Range: bytes start-end/total` (total may be `*`).
    static func contentRange(of response: HTTPURLResponse) -> (start: Int64, total: Int64?)? {
        guard let header = response.value(forHTTPHeaderField: "Content-Range")?.trimmingCharacters(in: .whitespaces),
              header.lowercased().hasPrefix("bytes ") else { return nil }
        let spec = header.dropFirst(6)
        let parts = spec.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, let dash = parts[0].firstIndex(of: "-"),
              let start = Int64(parts[0][..<dash].trimmingCharacters(in: .whitespaces)) else { return nil }
        return (start, Int64(parts[1].trimmingCharacters(in: .whitespaces)))
    }

    static func isTransient(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
             .dnsLookupFailed, .internationalRoamingOff, .callIsActive, .dataNotAllowed, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }
}
