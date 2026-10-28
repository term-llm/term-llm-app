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
                          retryDelays: [TimeInterval] = [0.01, 0.01]) -> (ListenTransfer, Outcome) {
        let outcome = Outcome()
        let transfer = ListenTransfer(id: id, remote: url, directory: directory, fetching: server,
                                      retryDelays: retryDelays,
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
