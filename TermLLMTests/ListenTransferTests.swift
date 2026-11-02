import AVFoundation
import XCTest
@testable import TermLLM

final class ListenByteRangesTests: XCTestCase {
    func testMergesTouchingAndOverlappingRanges() {
        var held = ListenByteRanges()
        held.insert(10..<20)
        held.insert(30..<40)
        held.insert(20..<25)
        XCTAssertEqual(held.ranges, [10..<25, 30..<40])
        held.insert(24..<31)
        XCTAssertEqual(held.ranges, [10..<40])
        held.insert(0..<5)
        XCTAssertEqual(held.ranges, [0..<5, 10..<40])
        XCTAssertEqual(held.total, 35)
    }

    func testFindsWhatIsMissing() {
        let held = ListenByteRanges([0..<5, 10..<40])
        XCTAssertEqual(held.firstMissing(from: 0, below: 50), 5)
        XCTAssertEqual(held.firstMissing(from: 12, below: 50), 40)
        XCTAssertNil(held.firstMissing(from: 12, below: 40))
        XCTAssertEqual(held.nextStart(after: 5), 10)
        XCTAssertNil(held.nextStart(after: 10))
        XCTAssertEqual(held.runEnd(at: 3), 5)
        XCTAssertNil(held.runEnd(at: 5))
        XCTAssertFalse(held.covers(40))
        XCTAssertTrue(ListenByteRanges([0..<40]).covers(40))
    }

    func testClampsToTheFileSize() {
        var held = ListenByteRanges([0..<5, 10..<40])
        held.clamp(below: 20)
        XCTAssertEqual(held.ranges, [0..<5, 10..<20])
    }
}

@MainActor
final class ListenTransferTests: XCTestCase {
    private let url = URL(string: "https://media.example/show/episode.mp3")!
    private var directory: URL!

    override func setUp() async throws {
        directory = temporaryDirectory()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var _result: Result<ListenTransfer.Saved, Error>?
        var result: Result<ListenTransfer.Saved, Error>? { lock.withLock { _result } }
        func set(_ result: Result<ListenTransfer.Saved, Error>) { lock.withLock { _result = result } }
        var saved: ListenTransfer.Saved? { if case .success(let saved) = result { saved } else { nil } }
        var error: Error? { if case .failure(let error) = result { error } else { nil } }
    }

    private func transfer(_ server: FakeMediaServer, id: UUID = UUID(),
                          retryDelays: [TimeInterval] = [0.01, 0.01],
                          playbackOnly: Bool = false) -> (ListenTransfer, Outcome) {
        let outcome = Outcome()
        let transfer = ListenTransfer(id: id, remote: url, directory: directory, fetching: server,
                                      retryDelays: retryDelays, playbackOnly: playbackOnly,
                                      makeRequest: { URLRequest(url: $0) },
                                      finished: { _, result in outcome.set(result) })
        return (transfer, outcome)
    }

    private func contents(_ saved: ListenTransfer.Saved?) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(saved).file)
    }

    func testDownloadsTheWholeFileOnce() async throws {
        let body = mediaBody(3 << 20)
        let server = FakeMediaServer()
        server.serve(url, .init(body: body))
        let (transfer, outcome) = transfer(server)
        transfer.start()
        await eventually { outcome.result != nil }
        XCTAssertEqual(try contents(outcome.saved), body)
        XCTAssertEqual(outcome.saved?.file.pathExtension, "mp3")
        XCTAssertEqual(server.ranges(for: url), ["bytes=0-"])
        XCTAssertEqual(server.bytesSent, body.count)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "\(transfer.id.uuidString).partial").path))
    }

    func testPlaybackReadsWhileItDownloads() async throws {
        let body = mediaBody(2 << 20)
        let server = FakeMediaServer()
        server.serve(url, .init(body: body))
        server.hold(512 << 10 ..< body.count)
        let (transfer, outcome) = transfer(server)
        transfer.start()
        // What AVFoundation asks first: the type and size, and two bytes.
        let probe = FakeRead(0, length: 2, info: true)
        let stream = FakeRead(0)
        transfer.read(probe)
        transfer.read(stream)
        await eventually { probe.finished && stream.data.count == 512 << 10 }
        XCTAssertEqual(probe.info?.type, "public.mp3")
        XCTAssertEqual(probe.info?.length, Int64(body.count))
        XCTAssertEqual(probe.data, body.prefix(2))
        XCTAssertEqual(stream.data.count, 512 << 10, "reads get what's here while the rest is on its way")
        XCTAssertFalse(stream.finished)
        server.release()
        await eventually { stream.finished && outcome.result != nil }
        XCTAssertEqual(stream.data, body)
        XCTAssertEqual(try contents(outcome.saved), body)
        XCTAssertEqual(server.bytesSent, body.count, "playing and saving fetch each byte once")
    }

    func testSeekingAheadFetchesThereFirstThenFillsTheGap() async throws {
        let body = mediaBody(4 << 20)
        let server = FakeMediaServer()
        server.serve(url, .init(body: body))
        server.hold(256 << 10 ..< 3 << 20)
        let (transfer, outcome) = transfer(server)
        transfer.start()
        await eventually { transfer.progress.received == 256 << 10 }
        let seek = FakeRead(3 << 20, length: 1 << 20)
        transfer.read(seek)
        await eventually { seek.finished }
        XCTAssertEqual(seek.data, body.subdata(in: 3 << 20 ..< 4 << 20))
        XCTAssertEqual(server.ranges(for: url).prefix(2), ["bytes=0-", "bytes=3145728-"])
        server.release()
        await eventually { outcome.result != nil }
        XCTAssertEqual(server.ranges(for: url), ["bytes=0-", "bytes=3145728-", "bytes=262144-3145727"],
                       "the gap is filled afterwards, stopping where the seek began")
        XCTAssertEqual(try contents(outcome.saved), body)
        XCTAssertEqual(server.bytesSent, body.count, "no byte is fetched twice")
    }

    func testReadsWithinReachWaitForTheRequestInFlight() async throws {
        let body = mediaBody(2 << 20)
        let server = FakeMediaServer()
        server.serve(url, .init(body: body))
        server.hold(128 << 10 ..< 129 << 10)
        let (transfer, outcome) = transfer(server)
        transfer.start()
        await eventually { transfer.progress.received == 128 << 10 }
        let near = FakeRead(512 << 10, length: 4096)
        transfer.read(near)
        server.release()
        await eventually { near.finished && outcome.result != nil }
        XCTAssertEqual(server.ranges(for: url), ["bytes=0-"], "a read just ahead doesn't restart the download")
        XCTAssertEqual(server.bytesSent, body.count)
    }

    func testResumesAPartialFileAfterRelaunch() async throws {
        let body = mediaBody(3 << 20)
        let server = FakeMediaServer()
        server.serve(url, .init(body: body))
        server.hold(1 << 20 ..< body.count)
        let id = UUID()
        do {
            let (first, _) = transfer(server, id: id)
            first.start()
            await eventually { first.progress.received == 1 << 20 }
            first.cancel(keepingPartial: true)
            _ = first.progress // the cancellation has landed
        }
        server.release()

        let (second, outcome) = transfer(server, id: id)
        XCTAssertEqual(second.progress.received, 1 << 20, "the partial file is picked up")
        second.start()
        await eventually { outcome.result != nil }
        XCTAssertEqual(try contents(outcome.saved), body)
        let resumed = try XCTUnwrap(server.requests.last)
        XCTAssertEqual(resumed.value(forHTTPHeaderField: "Range"), "bytes=1048576-")
        XCTAssertEqual(resumed.value(forHTTPHeaderField: "If-Range"), "\"v1\"")
        XCTAssertEqual(server.bytesSent, body.count)
    }

    func testAFileThatChangedStartsOver() async throws {
        let body = mediaBody(2 << 20)
        let server = FakeMediaServer()
        server.serve(url, .init(body: body))
        server.hold(1 << 20 ..< body.count)
        let id = UUID()
        do {
            let (first, _) = transfer(server, id: id)
            first.start()
            await eventually { first.progress.received == 1 << 20 }
            first.cancel(keepingPartial: true)
            _ = first.progress
        }
        let changed = Data(body.reversed())
        server.serve(url, .init(body: changed, etag: "\"v2\""))
        server.release()

        let (second, outcome) = transfer(server, id: id)
        second.start()
        await eventually { outcome.result != nil }
        XCTAssertEqual(try contents(outcome.saved), changed, "If-Range brought the whole new file")
    }

    func testServerWithoutRangesStillWorks() async throws {
        let body = mediaBody(3 << 20)
        let server = FakeMediaServer()
        server.serve(url, .init(body: body, ranges: false))
        server.hold(64 << 10 ..< 65 << 10)
        let (transfer, outcome) = transfer(server)
        transfer.start()
        await eventually { transfer.progress.received == 64 << 10 }
        let ahead = FakeRead(2 << 20, length: 4096)
        transfer.read(ahead)
        server.release()
        await eventually { ahead.finished && outcome.result != nil }
        XCTAssertEqual(ahead.data, body.subdata(in: 2 << 20 ..< (2 << 20) + 4096))
        XCTAssertEqual(server.requests.count, 1, "without ranges, a read ahead waits instead of starting over")
        XCTAssertEqual(try contents(outcome.saved), body)
    }

    func testDroppedConnectionCarriesOnWhereItStopped() async throws {
        let body = mediaBody(2 << 20)
        let server = FakeMediaServer()
        server.serve(url, .init(body: body))
        server.dropNext(after: 700 << 10)
        let (transfer, outcome) = transfer(server)
        transfer.start()
        await eventually { outcome.result != nil }
        XCTAssertEqual(try contents(outcome.saved), body)
        XCTAssertEqual(server.ranges(for: url), ["bytes=0-", "bytes=716800-"])
        XCTAssertEqual(server.bytesSent, body.count)
    }

    func testWebPagesAndErrorsFail() async throws {
        let server = FakeMediaServer()
        server.serve(url, .init(body: Data("<html>".utf8), mime: "text/html"))
        let (page, pageOutcome) = transfer(server)
        page.start()
        await eventually { pageOutcome.result != nil }
        XCTAssertEqual(pageOutcome.error?.localizedDescription.contains("web page"), true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "\(page.id.uuidString).partial").path))

        server.serve(url, .init(body: Data(), status: 404))
        let (missing, missingOutcome) = transfer(server)
        let read = FakeRead(0, info: true)
        missing.read(read)
        await eventually { missingOutcome.result != nil && read.error != nil }
        XCTAssertEqual(missingOutcome.error?.localizedDescription.contains("404"), true)
        XCTAssertNotNil(read.error, "playback hears about it too")
    }

    func testPlaybackCacheStopsAtLookaheadAndResumesWhenACachedReadAdvances() async throws {
        let body = mediaBody(12 << 20)
        let server = FakeMediaServer()
        server.serve(url, .init(body: body))
        let (transfer, outcome) = transfer(server, playbackOnly: true)
        transfer.start()
        await eventually { transfer.progress.received == ListenTransfer.playbackLookahead }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(transfer.progress.received, ListenTransfer.playbackLookahead)
        XCTAssertEqual(server.ranges(for: url), ["bytes=0-3145727"])
        XCTAssertNil(outcome.result, "an idle playback cache must not save the entire episode")

        let info = FakeRead(0, info: true, dataless: true)
        transfer.read(info)
        await eventually { info.finished }
        XCTAssertEqual(info.info?.length, Int64(body.count))
        XCTAssertEqual(server.requests.count, 1, "metadata alone does not move the lookahead")

        let read = FakeRead(1 << 20, length: 4096)
        transfer.read(read)
        await eventually { read.finished && transfer.progress.received == 4 << 20 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(read.data, body.subdata(in: 1 << 20 ..< (1 << 20) + 4096))
        XCTAssertEqual(transfer.progress.received, 4 << 20)
        XCTAssertEqual(server.ranges(for: url), ["bytes=0-3145727", "bytes=3145728-4194303"])
        XCTAssertEqual(server.bytesSent, 4 << 20, "reads from cache still advance the window, without repeats")
        XCTAssertNil(outcome.result)
        transfer.cancel(keepingPartial: false)
        _ = transfer.progress
    }

    func testPlaybackSeekAndTailProbeDoNotBackfillTheGapAndPromotionDoes() async throws {
        let body = mediaBody(16 << 20)
        let server = FakeMediaServer()
        server.serve(url, .init(body: body))
        let (transfer, outcome) = transfer(server, playbackOnly: true)
        transfer.start()
        await eventually { transfer.progress.received == 3 << 20 }
        let seek = FakeRead(10 << 20, length: 4096)
        transfer.read(seek)
        await eventually { seek.finished && transfer.progress.received == 6 << 20 }
        XCTAssertEqual(seek.data, body.subdata(in: 10 << 20 ..< (10 << 20) + 4096))

        let tail = FakeRead(Int64(body.count - 2), length: 2, info: true)
        transfer.read(tail)
        await eventually { tail.finished }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(tail.data, body.suffix(2))
        XCTAssertEqual(transfer.progress.received, (6 << 20) + 2)
        XCTAssertEqual(server.ranges(for: url), ["bytes=0-3145727", "bytes=10485760-13631487",
                                               "bytes=16777214-16777215"])
        XCTAssertNil(outcome.result, "tail metadata must not trigger filling skipped parts")

        let back = FakeRead(2 << 20, length: 4096)
        transfer.read(back)
        await eventually { back.finished && transfer.progress.received == (8 << 20) + 2 }
        XCTAssertEqual(back.data, body.subdata(in: 2 << 20 ..< (2 << 20) + 4096))
        XCTAssertEqual(server.ranges(for: url).last, "bytes=3145728-5242879")

        transfer.setSaving(true)
        await eventually { outcome.result != nil }
        XCTAssertEqual(try contents(outcome.saved), body, "promotion backfills every remaining hole")
        XCTAssertEqual(server.bytesSent, body.count, "seeks, backfill and promotion share the same cache")
    }

    func testPlaybackSeekInterruptsOldPrefetchWithoutFetchingTheWholeGap() async throws {
        let body = mediaBody(12 << 20)
        let server = FakeMediaServer()
        server.serve(url, .init(body: body))
        server.hold(256 << 10 ..< 8 << 20)
        let (transfer, outcome) = transfer(server, playbackOnly: true)
        transfer.start()
        await eventually { transfer.progress.received == 256 << 10 }
        let seek = FakeRead(8 << 20, length: 4096)
        transfer.read(seek)
        await eventually { seek.finished && transfer.progress.received == (3 << 20) + (256 << 10) }
        server.release()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(seek.data, body.subdata(in: 8 << 20 ..< (8 << 20) + 4096))
        XCTAssertEqual(server.ranges(for: url), ["bytes=0-3145727", "bytes=8388608-11534335"])
        XCTAssertEqual(transfer.progress.received, (3 << 20) + (256 << 10))
        XCTAssertNil(outcome.result)
        transfer.cancel(keepingPartial: false)
        _ = transfer.progress
    }

    func testPlaybackRetryAndRelaunchKeepTheBoundAndReusePartialBytes() async throws {
        let body = mediaBody(12 << 20)
        let server = FakeMediaServer()
        server.serve(url, .init(body: body))
        server.dropNext(after: 512 << 10)
        let id = UUID()
        do {
            let (first, outcome) = transfer(server, id: id, playbackOnly: true)
            first.start()
            await eventually { first.progress.received == 3 << 20 }
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(server.ranges(for: url), ["bytes=0-3145727", "bytes=524288-3145727"])
            XCTAssertEqual(server.requests.last?.value(forHTTPHeaderField: "If-Range"), "\"v1\"")
            XCTAssertNil(outcome.result)
            first.cancel(keepingPartial: true)
            _ = first.progress
        }
        let (resumed, outcome) = transfer(server, id: id, playbackOnly: true)
        resumed.start()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(resumed.progress.received, 3 << 20)
        XCTAssertEqual(server.requests.count, 2, "relaunch does not continue beyond the idle window")
        let seek = FakeRead(8 << 20, length: 4096)
        resumed.read(seek)
        await eventually { seek.finished && resumed.progress.received == 6 << 20 }
        XCTAssertEqual(seek.data, body.subdata(in: 8 << 20 ..< (8 << 20) + 4096))
        XCTAssertEqual(server.requests.last?.value(forHTTPHeaderField: "If-Range"), "\"v1\"")
        XCTAssertNil(outcome.result)
        resumed.setSaving(true)
        await eventually { outcome.result != nil }
        XCTAssertEqual(try contents(outcome.saved), body)
        XCTAssertEqual(server.bytesSent, body.count, "retry/resume/promotion never repeat a held byte")
    }

    func testStoppingPlaybackSavingFetchesOnlyDemandAndCanResumeExplicitly() async throws {
        let body = mediaBody(10 << 20)
        let server = FakeMediaServer()
        server.serve(url, .init(body: body))
        let (transfer, outcome) = transfer(server, playbackOnly: true)
        transfer.start()
        await eventually { transfer.progress.received == 3 << 20 }
        transfer.setSaving(false)
        let read = FakeRead(6 << 20, length: 64 << 10)
        transfer.read(read)
        await eventually { read.finished }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(read.data, body.subdata(in: 6 << 20 ..< (6 << 20) + (64 << 10)))
        XCTAssertEqual(transfer.progress.received, (3 << 20) + (64 << 10), "Stop disables lookahead too")
        XCTAssertNil(outcome.result)
        transfer.setSaving(true)
        await eventually { outcome.result != nil }
        XCTAssertEqual(try contents(outcome.saved), body)
        XCTAssertEqual(server.bytesSent, body.count)
    }

    func testPlaybackAllToEndDemandIsNotStarvedByTheSpeculativeBound() async throws {
        let body = mediaBody(8 << 20)
        let server = FakeMediaServer()
        server.serve(url, .init(body: body))
        let (transfer, outcome) = transfer(server, playbackOnly: true)
        // AVFoundation can ask for the whole remaining resource. Such demand
        // is not speculative prefetch and must not stall at the lookahead.
        let read = FakeRead(0, info: true)
        transfer.read(read)
        await eventually { read.finished && outcome.result != nil }
        XCTAssertEqual(read.data, body)
        XCTAssertEqual(read.info?.length, Int64(body.count))
        XCTAssertEqual(try contents(outcome.saved), body)
        XCTAssertEqual(server.ranges(for: url), ["bytes=0-3145727", "bytes=3145728-6291455", "bytes=6291456-8388607"])
        XCTAssertEqual(server.bytesSent, body.count)
    }

    func testPlaybackCacheKeepsOneFullResponseWhenServerIgnoresRange() async throws {
        let body = mediaBody(10 << 20)
        let server = FakeMediaServer()
        server.serve(url, .init(body: body, ranges: false))
        server.hold(3 << 20 ..< 4 << 20)
        let (transfer, outcome) = transfer(server, playbackOnly: true)
        transfer.start()
        await eventually { transfer.progress.received == 3 << 20 }
        let first = FakeRead(0, length: 3 << 20)
        transfer.read(first)
        await eventually { first.finished }
        let next = FakeRead(3 << 20, length: 1 << 20)
        transfer.read(next)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(outcome.result)
        XCTAssertEqual(server.ranges(for: url), ["bytes=0-3145727"], "do not cancel the 200 at the speculative bound")
        server.release()
        await eventually { next.finished && outcome.result != nil }
        XCTAssertEqual(first.data, body.prefix(3 << 20))
        XCTAssertEqual(next.data, body.subdata(in: 3 << 20 ..< 4 << 20))
        XCTAssertEqual(try contents(outcome.saved), body)
        XCTAssertEqual(server.requests.count, 1, "sequential playback must not re-download prefixes")
        XCTAssertEqual(server.bytesSent, body.count, "non-range servers intentionally fall back to a whole-file save")
    }

    func testPlaybackCacheDiscoversEOFWhenRangeResponseOmitsTotal() async throws {
        let body = mediaBody(4 << 20)
        let server = FakeMediaServer()
        server.serve(url, .init(body: body))
        let outcome = Outcome()
        let transfer = ListenTransfer(id: UUID(), remote: url, directory: directory,
                                      fetching: UnknownTotalFetching(server: server), playbackOnly: true,
                                      makeRequest: { URLRequest(url: $0) },
                                      finished: { _, result in outcome.set(result) })
        let probe = FakeRead(0, length: 2, info: true)
        transfer.read(probe)
        await eventually { probe.finished && outcome.result != nil }
        XCTAssertEqual(probe.info?.length, Int64(body.count), "the first finite range must not be mistaken for EOF")
        XCTAssertEqual(try contents(outcome.saved), body)
        XCTAssertEqual(server.ranges(for: url), ["bytes=0-3145727", "bytes=3145728-"])
        XCTAssertEqual(server.bytesSent, body.count, "unknown totals fall back to discovering EOF, without repeating bytes")
    }

    private struct UnknownTotalFetching: ListenFetching {
        let server: FakeMediaServer

        func start(_ request: URLRequest, queue: DispatchQueue,
                   events: @escaping @Sendable (ListenFetchEvent) -> Void) -> @Sendable () -> Void {
            server.start(request, queue: queue) { event in
                if case .response(let response) = event,
                   let range = response.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").first,
                   let url = response.url,
                   let unknown = HTTPURLResponse(url: url, statusCode: response.statusCode, httpVersion: "HTTP/1.1",
                                                 headerFields: ["Content-Type": "audio/mpeg", "Content-Range": "\(range)/*",
                                                                "ETag": "\"v1\""]) {
                    events(.response(unknown))
                } else {
                    events(event)
                }
            }
        }
    }

    func testWithoutSavingOnlyWhatPlaybackReadsIsFetched() async throws {
        let body = mediaBody(4 << 20)
        let server = FakeMediaServer()
        server.serve(url, .init(body: body))
        let id = UUID()
        do {
            let (transfer, outcome) = transfer(server, id: id)
            transfer.setSaving(false)
            transfer.start()
            let read = FakeRead(0, length: 100 << 10)
            transfer.read(read)
            await eventually { read.finished }
            _ = transfer.progress
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertLessThan(transfer.progress.received, Int64(body.count))
            XCTAssertLessThan(server.bytesSent, 1 << 20, "stops once the read has its bytes")
            XCTAssertNil(outcome.result)
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "\(id.uuidString).partial").path),
                       "nothing is left behind once playback lets go")
    }
}

/// The real AVPlayer reading through a transfer, with real audio data.
@MainActor
final class ListenEngineTransferTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = temporaryDirectory()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private final class QuietAudioSession: ListenAudioSession, @unchecked Sendable {
        func setCategory(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode,
                         policy: AVAudioSession.RouteSharingPolicy, options: AVAudioSession.CategoryOptions) throws {}
        func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {}
    }

    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var _done = false
        var done: Bool { lock.withLock { _done } }
        func finish() { lock.withLock { _done = true } }
    }

    private func transfer(_ server: FakeMediaServer, _ url: URL) -> (ListenTransfer, Outcome) {
        let outcome = Outcome()
        let transfer = ListenTransfer(id: UUID(), remote: url, directory: directory, fetching: server,
                                      makeRequest: { URLRequest(url: $0) }, finished: { _, _ in outcome.finish() })
        return (transfer, outcome)
    }

    /// MPEG-1 Layer III frames of silence (mono, 128 kbit/s, 44.1 kHz): a
    /// frame header and zeroed side information decode to silence.
    private static func silentMP3(seconds: Double) -> Data {
        var frame = Data(count: 417)
        frame.replaceSubrange(0..<4, with: [0xFF, 0xFB, 0x90, 0xC4])
        let frames = Int(seconds * 44_100 / 1_152)
        return Data((0..<frames).flatMap { _ in frame })
    }

    /// AAC in an MPEG-4 file as Core Audio writes it.
    private func silentM4A(seconds: Int) throws -> Data {
        let url = directory.appending(path: "silence.m4a")
        do {
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
            ])
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 44_100))
            buffer.frameLength = 44_100
            for _ in 0..<seconds { try file.write(from: buffer) }
        }
        return try Data(contentsOf: url)
    }

    func testPlaysMP3WhileDownloadingAndSeeksAheadFetchingEachByteOnce() async throws {
        let url = URL(string: "https://media.example/show/silence.mp3")!
        let body = Self.silentMP3(seconds: 60)
        let server = FakeMediaServer()
        server.serve(url, .init(body: body))
        // The download stalls early on, so the seek lands past what's here.
        server.hold(160_000 ..< 400_000)
        let (transfer, outcome) = transfer(server, url)
        transfer.start()
        let engine = AVListenEngine(audioSession: QuietAudioSession())
        defer { engine.stop() }

        try await engine.load(ListenSource(url: url, transfer: transfer), startAt: 0)
        XCTAssertEqual(engine.duration ?? 0, 60, accuracy: 2)
        try await engine.play(rate: 1)
        await eventually(10) { engine.currentTime > 0.5 }
        XCTAssertGreaterThan(engine.currentTime, 0.5, "plays from what's downloaded so far")

        await engine.seek(to: 45)
        XCTAssertEqual(engine.currentTime, 45, accuracy: 1.5)
        await eventually(10) { engine.currentTime > 46 }
        XCTAssertGreaterThan(engine.currentTime, 46, "plays on after seeking past the download: \(server.ranges(for: url)), \(transfer.progress)")

        server.release()
        await eventually(10) { outcome.done }
        XCTAssertTrue(outcome.done)
        XCTAssertEqual(server.bytesSent, body.count, "streaming and saving fetched each byte once: \(server.ranges(for: url))")
    }

    /// Exercises repeated streamed playback lifetimes with the real player.
    /// CPU is diagnostic evidence, not a portable pass/fail threshold: the
    /// simulator shares the Mac's audio/rendering services and is not a phone.
    func testRepeatedStreamPlaybackKeepsBufferCallbacksBounded() async throws {
        let url = URL(string: "https://media.example/show/silence.mp3")!
        let server = FakeMediaServer()
        server.serve(url, .init(body: Self.silentMP3(seconds: 120)))
        let realSession = ProcessInfo.processInfo.environment["TERMLLM_LISTEN_REAL_AUDIO_SESSION"] == "1"
        let engine = realSession ? AVListenEngine() : AVListenEngine(audioSession: QuietAudioSession())
        defer { engine.stop() }
        var bufferEvents = 0
        engine.onEvent = { event in
            if event == .buffer { bufferEvents += 1 }
        }
        var diagnostics: [String] = []
        // Opt in to a longer local reproduction without slowing normal CI.
        let sampleSeconds = ProcessInfo.processInfo.environment["TERMLLM_LISTEN_CPU_SAMPLE_SECONDS"]
            .flatMap(Int.init).map { min(60, max(2, $0)) } ?? 2
        func measure(_ state: String, cycle: Int) async throws {
            let sampler = ProcessUsageSampler()
            _ = sampler.sample(appActive: true, appBackground: false)
            let before = bufferEvents
            try await Task.sleep(for: .seconds(sampleSeconds))
            let sample = sampler.sample(appActive: true, appBackground: false)
            let interval = sample.cpuInterval ?? Double(sampleSeconds)
            XCTAssertLessThanOrEqual(bufferEvents - before,
                                     Int(ceil(interval / ListenBufferCallbackCoalescer.updateInterval)) + 1,
                                     "streaming must not flood the main thread with buffering updates")
            diagnostics.append("cycle \(cycle), \(state), real session \(realSession): app CPU cores=\(sample.appCPU.map(String.init(describing:)) ?? "unavailable"), "
                               + "wakeups/s=\(sample.wakeupsPerSecond.map(String.init(describing:)) ?? "unavailable"), "
                               + "buffer deliveries=\(bufferEvents - before) over \(interval)s")
        }
        for cycle in 0..<3 {
            let (transfer, _) = transfer(server, url)
            transfer.start()
            defer { transfer.cancel(keepingPartial: false) }
            try await engine.load(ListenSource(url: url, transfer: transfer), startAt: 10)
            try await engine.play(rate: 1)
            await eventually(10) { engine.currentTime > 10.5 }
            XCTAssertGreaterThan(engine.currentTime, 10.5)
            engine.pause()
            await engine.seek(to: 30)
            try await engine.play(rate: 1)
            await eventually(10) { engine.currentTime > 30.5 }
            XCTAssertGreaterThan(engine.currentTime, 30.5)

            try await measure("playing", cycle: cycle)
            if realSession {
                engine.pause()
                try await measure("paused", cycle: cycle)
            }
            engine.stop()
            if realSession { try await measure("stopped", cycle: cycle) }
            let stopped = bufferEvents
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(bufferEvents, stopped, "replaced/stopped items must not keep delivering buffer events")
        }
        let attachment = XCTAttachment(string: diagnostics.joined(separator: "\n"))
        attachment.name = "simulator-stream-playback-cpu-diagnostics"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testPlaysAACFromAServerThatDoesNotNameTheType() async throws {
        let url = URL(string: "https://media.example/episodes/42")!
        let body = try silentM4A(seconds: 30)
        let server = FakeMediaServer()
        server.serve(url, .init(body: body, mime: "application/octet-stream"))
        let (transfer, outcome) = transfer(server, url)
        transfer.start()
        let engine = AVListenEngine(audioSession: QuietAudioSession())
        defer { engine.stop() }

        try await engine.load(ListenSource(url: url, transfer: transfer), startAt: 20)
        XCTAssertEqual(engine.duration ?? 0, 30, accuracy: 1)
        try await engine.play(rate: 1)
        await eventually(10) { engine.currentTime > 20.5 }
        XCTAssertGreaterThan(engine.currentTime, 20.5)
        await eventually(10) { outcome.done }
        XCTAssertEqual(server.bytesSent, body.count, "\(server.ranges(for: url))")
    }
}

final class ListenNetworkUsageTests: XCTestCase {
    private var directory: URL!
    private var file: URL { directory.appending(path: "usage.json") }
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }
    private func date(_ year: Int = 2026, _ month: Int = 3, _ day: Int = 9,
                      _ hour: Int = 12, _ minute: Int = 0, _ second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day,
                                          hour: hour, minute: minute, second: second))!
    }
    private func usage(at now: Date, interval: TimeInterval = 3_600) -> ListenNetworkUsage {
        ListenNetworkUsage(fileURL: file, now: { now }, calendar: calendar, flushInterval: interval)
    }
    override func setUp() { directory = temporaryDirectory() }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    func testPersistsStartAndRepeatedBytesButBatchesChunksUntilFlush() throws {
        let start = date()
        let ledger = usage(at: start)
        let emptyFile = try Data(contentsOf: file)
        // The same downloaded range arriving twice is charged twice.
        ledger.record(bytes: 512)
        ledger.record(bytes: 512)
        ledger.record(bytes: 0)
        ledger.record(bytes: -1)
        let snapshot = ledger.snapshot(now: start, calendar: calendar)
        XCTAssertEqual(snapshot.todayBytes, 1_024)
        XCTAssertEqual(snapshot.weekBytes, 1_024)
        XCTAssertEqual(snapshot.monthBytes, 1_024)
        XCTAssertEqual(snapshot.totalBytes, 1_024)
        XCTAssertEqual(snapshot.recentBytes, 1_024)
        XCTAssertEqual(try Data(contentsOf: file), emptyFile, "chunks do not write to disk")
        ledger.flush()
        let relaunched = usage(at: start.addingTimeInterval(20))
        let saved = relaunched.snapshot(now: start.addingTimeInterval(20), calendar: calendar)
        XCTAssertEqual(saved.totalBytes, 1_024)
        XCTAssertEqual(saved.todayBytes, 1_024)
        XCTAssertEqual(saved.startedAt, start)
        XCTAssertEqual(saved.recentBytes, 0, "recent rate is deliberately in-memory only")
    }

    func testCalendarDayWeekMonthAndDaylightSavingBoundary() {
        // Monday starts a new calendar week; Sunday is the 23-hour DST day.
        let now = date(2026, 3, 9, 0)
        let ledger = usage(at: date(2026, 2, 28))
        ledger.record(bytes: 1, at: date(2026, 2, 28, 23, 59, 59))
        ledger.record(bytes: 2, at: date(2026, 3, 1, 0))
        ledger.record(bytes: 4, at: date(2026, 3, 8, 23, 59, 59))
        ledger.record(bytes: 8, at: now)
        let snapshot = ledger.snapshot(now: now, calendar: calendar)
        XCTAssertEqual(snapshot.todayBytes, 8)
        XCTAssertEqual(snapshot.weekBytes, 8, "calendar week, not the last seven days")
        XCTAssertEqual(snapshot.monthBytes, 14, "calendar month, not the last thirty days")
        XCTAssertEqual(snapshot.totalBytes, 15)
        XCTAssertEqual(snapshot.recentBytes, 12)
        let sunday = ledger.snapshot(now: date(2026, 3, 8, 23, 59, 59), calendar: calendar)
        XCTAssertEqual(sunday.todayBytes, 4, "next day's bucket is excluded at the interval end")
        XCTAssertEqual(sunday.weekBytes, 4)
    }

    func testRecentBytesExpireAtSixtySecondsAndDoNotIncludeFutureBuckets() {
        let start = date()
        let ledger = usage(at: start)
        ledger.record(bytes: 10, at: start)
        ledger.record(bytes: 20, at: start.addingTimeInterval(1))
        XCTAssertEqual(ledger.snapshot(now: start, calendar: calendar).recentBytes, 10)
        XCTAssertEqual(ledger.snapshot(now: start.addingTimeInterval(59), calendar: calendar).recentBytes, 30)
        XCTAssertEqual(ledger.snapshot(now: start.addingTimeInterval(60), calendar: calendar).recentBytes, 20)
        XCTAssertEqual(ledger.snapshot(now: start.addingTimeInterval(61), calendar: calendar).recentBytes, 0)
        XCTAssertEqual(ledger.snapshot(now: start.addingTimeInterval(61), calendar: calendar).totalBytes, 30)
    }

    func testPrunesDailyBucketsButKeepsLifetimeTotalAndStartDate() throws {
        let start = date(2025, 1, 1)
        let ledger = usage(at: start)
        for offset in 0..<120 {
            ledger.record(bytes: 10, at: calendar.date(byAdding: .day, value: offset, to: start)!)
        }
        ledger.flush()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual((json["days"] as? [[String: Any]])?.count, 90)
        let now = calendar.date(byAdding: .day, value: 120, to: start)!
        let snapshot = usage(at: now).snapshot(now: now, calendar: calendar)
        XCTAssertEqual(snapshot.totalBytes, 1_200)
        XCTAssertEqual(snapshot.startedAt, start)
        XCTAssertEqual(snapshot.todayBytes, 0)
        let muchLater = calendar.date(byAdding: .year, value: 1, to: now)!
        let later = usage(at: muchLater).snapshot(now: muchLater, calendar: calendar)
        XCTAssertEqual(later.totalBytes, 1_200)
        let pruned = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual((pruned["days"] as? [[String: Any]])?.count, 0)
    }

    func testConcurrentRecordingAndSnapshotsLoseNoBytes() {
        let now = date()
        let ledger = usage(at: now)
        let calendar = calendar
        DispatchQueue.concurrentPerform(iterations: 1_000) { index in
            ledger.record(bytes: 7)
            if index % 50 == 0 { _ = ledger.snapshot(now: now, calendar: calendar) }
        }
        ledger.flush()
        XCTAssertEqual(ledger.snapshot(now: now, calendar: calendar).totalBytes, 7_000)
        XCTAssertEqual(usage(at: now).snapshot(now: now, calendar: calendar).totalBytes, 7_000)
    }

    @MainActor
    func testPeriodicBatchWritesWithoutACompletion() async throws {
        let now = date()
        let ledger = usage(at: now, interval: 0.01)
        ledger.record(bytes: 123)
        await eventually {
            guard let data = try? Data(contentsOf: self.file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return json["totalBytes"] as? Int == 123
        }
        XCTAssertEqual(usage(at: now).snapshot(now: now, calendar: calendar).totalBytes, 123)
    }

    func testCorruptFileStartsFreshWithoutInventingHistoricalUsage() throws {
        try Data("not a ledger".utf8).write(to: file)
        let now = date()
        let snapshot = usage(at: now).snapshot(now: now, calendar: calendar)
        XCTAssertEqual(snapshot.startedAt, now)
        XCTAssertEqual(snapshot.totalBytes, 0)
        XCTAssertEqual(snapshot.todayBytes, 0)
    }
}

@MainActor
final class ListenSessionUsageTests: XCTestCase {
    private var directory: URL!
    override func setUp() async throws { directory = temporaryDirectory() }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }

    func testRealDelegateCountsRepeatedRangesAndFlushesSuccessfulAndFailedBodies() async throws {
        let file = directory.appending(path: "usage.json")
        let usage = ListenNetworkUsage(fileURL: file, flushInterval: 3_600)
        let session = ListenMediaSession.makeSession(protocolClasses: [ListenUsageProtocol.self])
        defer { session.invalidateAndCancel() }
        let fetching = ListenSessionFetching(session: session, usage: usage)
        let queue = DispatchQueue(label: "ListenUsageTests.events")
        for path in ["success", "success", "failure"] {
            let finished = expectation(description: path)
            let url = URL(string: "https://usage.media.example/\(path)")!
            var request = URLRequest(url: url)
            request.setValue("bytes=0-383", forHTTPHeaderField: "Range")
            _ = fetching.start(request, queue: queue) { event in
                if case .data(let data) = event, path == "failure" {
                    ListenUsageProtocol.failAfterBodyDelivery(bytes: data.count, for: url)
                }
                if case .finished(let error) = event {
                    XCTAssertEqual(error != nil, path == "failure")
                    finished.fulfill()
                }
            }
            await fulfillment(of: [finished], timeout: 5)
        }
        XCTAssertEqual(usage.snapshot().totalBytes, 1_152, "counts repeated bodies, not unique disk ranges")
        let persisted = ListenNetworkUsage(fileURL: file)
        XCTAssertEqual(persisted.snapshot().totalBytes, 1_152, "completion flushed success and failure")
    }

    func testActualDelegateCountsBeforeEventQueueFilteringAndRetainsCancelledBytes() async throws {
        let file = directory.appending(path: "usage.json")
        let usage = ListenNetworkUsage(fileURL: file, flushInterval: 3_600)
        let session = ListenMediaSession.makeSession(protocolClasses: [ListenUsageProtocol.self])
        defer { session.invalidateAndCancel() }
        let fetching = ListenSessionFetching(session: session, usage: usage)
        let queue = DispatchQueue(label: "ListenUsageTests.blockedEvents")
        let release = DispatchSemaphore(value: 0)
        queue.async { release.wait() }
        defer { release.signal() }
        let finished = expectation(description: "cancelled")
        let cancel = fetching.start(URLRequest(url: URL(string: "https://usage.media.example/hold")!), queue: queue) { event in
            // A stale/rejected transfer can ignore every data event. It must
            // still be charged for bytes URLSession already delivered.
            if case .finished(let error) = event {
                XCTAssertEqual((error as? URLError)?.code, .cancelled)
                finished.fulfill()
            }
        }
        await eventually { usage.snapshot().totalBytes == 384 }
        XCTAssertEqual(usage.snapshot().totalBytes, 384, "delegate accounted while transfer queue was blocked")
        cancel()
        release.signal()
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(ListenNetworkUsage(fileURL: file).snapshot().totalBytes, 384,
                       "cancelled requests flush bytes already received")
    }
}

private final class ListenUsageProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    // A failing fixture waits for real delegate delivery, not a timing delay:
    // Foundation may discard queued body callbacks if didFail follows didLoad
    // synchronously. All instance and dictionary state here is guarded by lock.
    nonisolated(unsafe) private static var pendingFailures: [URL: ListenUsageProtocol] = [:]
    private var deliveredBytes = 0

    static func failAfterBodyDelivery(bytes: Int, for url: URL) {
        let ready: ListenUsageProtocol? = lock.withLock {
            guard let fixture = pendingFailures[url] else { return nil }
            fixture.deliveredBytes += bytes
            guard fixture.deliveredBytes >= 384 else { return nil }
            pendingFailures[url] = nil
            return fixture
        }
        if let ready {
            ready.client?.urlProtocol(ready, didFailWithError: URLError(.networkConnectionLost))
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "usage.media.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        if url.lastPathComponent == "failure" {
            Self.lock.withLock { Self.pendingFailures[url] = self }
        }
        let response = HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": "audio/mpeg", "Content-Range": "bytes 0-383/1024",
            "X-Uncounted-Header": String(repeating: "h", count: 1_024),
        ])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 1, count: 128))
        client?.urlProtocol(self, didLoad: Data(repeating: 2, count: 256))
        switch url.lastPathComponent {
        case "hold", "failure": break
        default: client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {
        guard let url = request.url else { return }
        _ = Self.lock.withLock { Self.pendingFailures.removeValue(forKey: url) }
    }
}
