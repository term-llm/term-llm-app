import AVFoundation
import MediaPlayer
import UIKit
import XCTest
@testable import TermLLM

@MainActor
final class ListenPlayerTests: XCTestCase {
    func testPlaysAndResumesWhereItWasLeft() async throws {
        let engine = FakeListenEngine()
        let listen = makeListen(engine: engine)
        var starts = 0
        listen.player.willStartPlayback = { starts += 1 }
        let items = try await listen.add([draft("a"), draft("b")], placement: .end, download: .never)
        engine.durations[items[0].url] = 600

        try await listen.player.play(items[0].id)
        XCTAssertEqual(listen.player.status, .playing)
        XCTAssertEqual(listen.player.duration, 600)
        XCTAssertEqual(listen.store.item(items[0].id)?.status, .inProgress)
        XCTAssertEqual(starts, 1)
        XCTAssertTrue(listen.player.showsBar)

        engine.currentTime = 120
        listen.player.pause()
        XCTAssertEqual(listen.player.status, .paused)
        XCTAssertEqual(listen.store.item(items[0].id)?.position, 120, "pausing saves the position")

        try await listen.player.play(items[1].id)
        try await listen.player.play(items[0].id)
        XCTAssertEqual(engine.loads.last?.startAt, 120)
    }

    func testFinishingMarksPlayedAndContinuesUpNext() async throws {
        let engine = FakeListenEngine()
        let listen = makeListen(engine: engine)
        let items = try await listen.add([draft("a"), draft("b")], placement: .now, download: .never)
        XCTAssertEqual(listen.player.currentID, items[0].id, ".now starts the first item")

        engine.send(.ended)
        await settle()
        XCTAssertEqual(listen.store.item(items[0].id)?.status, .played)
        XCTAssertEqual(listen.player.currentID, items[1].id)
        XCTAssertEqual(listen.player.status, .playing)

        engine.send(.ended)
        await settle()
        XCTAssertNil(listen.player.currentID, "the end of Up Next stops and hides the bar")
        XCTAssertFalse(listen.player.showsBar)
        XCTAssertEqual(listen.player.status, .idle)
    }

    func testSleepAtEndStopsAfterTheItem() async throws {
        let engine = FakeListenEngine()
        let listen = makeListen(engine: engine)
        _ = try await listen.add([draft("a"), draft("b")], placement: .now, download: .never)
        listen.player.sleepAtEndOfItem()
        engine.send(.ended)
        await settle()
        XCTAssertEqual(listen.player.status, .idle)
        XCTAssertEqual(listen.store.upNext.map(\.title), ["b"])
    }

    func testSleepTimerPauses() async throws {
        let engine = FakeListenEngine()
        var clock = Date(timeIntervalSince1970: 1_000)
        let directory = temporaryDirectory()
        let listen = Listen(store: ListenStore(fileURL: directory.appending(path: "l.json")), engine: engine,
                            cookies: FakeCookieJar(), server: { testServer }, downloadDirectory: directory,
                            defaults: isolatedDefaults(), now: { clock })
        _ = try await listen.add([draft("a")], placement: .now, download: .never)
        listen.player.sleep(minutes: 10)
        engine.send(.tick)
        XCTAssertEqual(listen.player.status, .playing)
        clock = clock.addingTimeInterval(601)
        engine.send(.tick)
        XCTAssertEqual(listen.player.status, .paused)
        XCTAssertNil(listen.player.sleepAt)
    }

    func testInterruptionsAndLostOutput() async throws {
        let engine = FakeListenEngine()
        let listen = makeListen(engine: engine)
        _ = try await listen.add([draft("a")], placement: .now, download: .never)
        engine.send(.interrupted)
        XCTAssertEqual(listen.player.status, .paused)
        engine.send(.interruptionEnded(shouldResume: true))
        await settle()
        XCTAssertEqual(listen.player.status, .playing)
        engine.send(.outputLost)
        XCTAssertEqual(listen.player.status, .paused)
        engine.send(.interruptionEnded(shouldResume: true))
        await settle()
        XCTAssertEqual(listen.player.status, .paused, "only resumes what an interruption paused")
    }

    func testPreviousRestartsThenGoesBack() async throws {
        let engine = FakeListenEngine()
        let listen = makeListen(engine: engine)
        let items = try await listen.add([draft("a"), draft("b")], placement: .end, download: .never)
        try await listen.player.play(items[1].id)
        engine.currentTime = 30
        try await listen.player.previous()
        XCTAssertEqual(engine.currentTime, 0)
        XCTAssertEqual(listen.player.currentID, items[1].id)
        try await listen.player.previous()
        XCTAssertEqual(listen.player.currentID, items[0].id)
    }

    func testLoadFailureIsReported() async throws {
        let engine = FakeListenEngine()
        engine.loadError = ListenError.playbackFailed("bad file")
        let listen = makeListen(engine: engine)
        let items = try await listen.add([draft("a")], placement: .end, download: .never)
        do {
            try await listen.player.play(items[0].id)
            XCTFail("expected an error")
        } catch {}
        XCTAssertEqual(listen.player.status, .failed("Can't play this: bad file"))
        XCTAssertNotNil(listen.player.notice)
    }

    func testHidingTheBarKeepsPlaying() async throws {
        let engine = FakeListenEngine()
        let listen = makeListen(engine: engine)
        let items = try await listen.add([draft("a"), draft("b")], placement: .now, download: .never)
        listen.player.hideBar()
        XCTAssertFalse(listen.player.showsBar)
        XCTAssertTrue(engine.playing)
        try await listen.player.play(items[1].id)
        XCTAssertTrue(listen.player.showsBar, "starting something new shows the bar again")
    }

    func testRemovingTheCurrentItemStops() async throws {
        let engine = FakeListenEngine()
        let listen = makeListen(engine: engine)
        let items = try await listen.add([draft("a")], placement: .now, download: .never)
        try listen.remove([items[0].id])
        XCTAssertNil(listen.player.currentID)
        XCTAssertFalse(listen.player.showsBar)
        XCTAssertEqual(engine.stops, 1)
        XCTAssertTrue(listen.store.items.isEmpty)
    }

    /// The root view and the shelf read these. Saving the position must not
    /// invalidate them: the iOS 26 tab accessory rebuilds the shelf on every
    /// root update, which refetched the artwork every few seconds.
    func testSavingThePositionLeavesTheShelfAlone() async throws {
        let engine = FakeListenEngine()
        let listen = makeListen(engine: engine)
        let items = try await listen.add([draft("a")], placement: .now, download: .never)
        await settle()
        let invalidated = UncheckedBox(Flag())
        withObservationTracking {
            _ = (listen.player.currentID, listen.player.showsBar, listen.player.isPlaying)
        } onChange: {
            invalidated.value.raised = true
        }
        for second in 1...ListenPlayer.saveInterval {
            engine.currentTime = TimeInterval(60 + second)
            engine.send(.tick)
        }
        XCTAssertEqual(listen.store.item(items[0].id)?.position, TimeInterval(60 + ListenPlayer.saveInterval),
                       "the position was saved")
        XCTAssertFalse(invalidated.value.raised)
        XCTAssertTrue(listen.player.showsBar)
    }

    func testPlaybackSavesThePositionWithoutRewritingTheLibrary() async throws {
        let directory = temporaryDirectory()
        let library = directory.appending(path: "library.json")
        let engine = FakeListenEngine()
        let listen = makeListen(engine: engine, directory: directory)
        let items = try await listen.add([draft("a")], placement: .now, download: .never)
        await settle()
        let saved = try Data(contentsOf: library)
        let played = ListenPlayer.saveInterval * 3
        for second in 1...played {
            engine.currentTime = TimeInterval(second)
            engine.send(.tick)
        }
        XCTAssertEqual(try Data(contentsOf: library), saved)
        XCTAssertEqual(ListenStore(fileURL: library).item(items[0].id)?.position, TimeInterval(played))

        engine.currentTime = TimeInterval(played + 4)
        listen.player.savePlayingPosition()
        XCTAssertEqual(ListenStore(fileURL: library).item(items[0].id)?.position, TimeInterval(played + 4),
                       "leaving the foreground saves it at once")
        engine.currentTime = TimeInterval(played + 9)
        listen.player.pause()
        XCTAssertEqual(ListenStore(fileURL: library).item(items[0].id)?.position, TimeInterval(played + 9))
        XCTAssertEqual(try Data(contentsOf: library), saved)
    }

    func testServerMediaStreamsWithCookiesAndOthersWithout() async throws {
        let engine = FakeListenEngine()
        let cookies = FakeCookieJar()
        cookies.cookies = [HTTPCookie(properties: [.domain: "hub.example", .path: "/", .name: "s", .value: "1"])!]
        let hub = URL(string: "https://hub.example/media/a.mp3")!
        let server = FakeMediaServer()
        server.serve(hub, .init(body: mediaBody(40)))
        server.serve(draft("b").url, .init(body: mediaBody(40)))
        let listen = makeListen(engine: engine, cookies: cookies, server: server)
        let items = try await listen.add([ListenDraft(url: hub), draft("b"),
                                          ListenDraft(url: URL(string: "https://hub.example/media/clip.mp4")!)],
                                         placement: .end, download: .never)
        try await listen.player.play(items[0].id)
        try await listen.player.play(items[1].id)
        try await waitFor { server.requests.count == 2 }
        XCTAssertEqual(server.requests.first { $0.url == hub }?.value(forHTTPHeaderField: "Cookie"), "s=1")
        XCTAssertNil(server.requests.first { $0.url == draft("b").url }?.value(forHTTPHeaderField: "Cookie"))
        // Video streams straight from its URL, with the cookie for this server.
        try await listen.player.play(items[2].id)
        XCTAssertNil(engine.loads.last?.source.transfer)
        XCTAssertEqual(engine.loads.last?.source.cookies.count, 1)
    }

    func testRestoresTheCurrentItemPausedAfterRelaunch() async throws {
        let directory = temporaryDirectory()
        let defaults = isolatedDefaults()
        let store = ListenStore(fileURL: directory.appending(path: "l.json"))
        let engine = FakeListenEngine()
        let first = Listen(store: store, engine: engine, cookies: FakeCookieJar(), server: { testServer },
                           downloadDirectory: directory, defaults: defaults)
        let items = try await first.add([draft("a")], placement: .now, download: .never)
        engine.currentTime = 50
        first.player.pause()

        let relaunched = Listen(store: ListenStore(fileURL: directory.appending(path: "l.json")), engine: FakeListenEngine(),
                                cookies: FakeCookieJar(), server: { testServer }, downloadDirectory: directory, defaults: defaults)
        XCTAssertEqual(relaunched.player.currentID, items[0].id)
        XCTAssertEqual(relaunched.player.status, .paused)
        XCTAssertEqual(relaunched.player.position, 50)
    }

    func testDownloadsServerMediaAutomatically() async throws {
        let directory = temporaryDirectory()
        let server = FakeMediaServer()
        server.serve(URL(string: "https://hub.example/media/abc")!, .init(body: Data("ID3fake".utf8)))
        let listen = makeListen(directory: directory, server: server)
        let items = try await listen.add([ListenDraft(url: URL(string: "https://hub.example/media/abc")!), draft("ext")],
                                         placement: .end)
        for _ in 0..<50 where listen.store.item(items[0].id)?.download != .downloaded {
            try await Task.sleep(for: .milliseconds(20))
        }
        let item = try XCTUnwrap(listen.store.item(items[0].id))
        XCTAssertEqual(item.download, .downloaded)
        XCTAssertEqual(item.localFile?.hasSuffix(".mp3"), true)
        XCTAssertEqual(listen.store.item(items[1].id)?.download, ListenItem.Download.none, "other hosts stream by default")
        let played = await listen.downloader.source(for: item)
        XCTAssertTrue(played.isLocal)

        try listen.remove([item.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "Downloads/\(item.localFile!)").path(percentEncoded: false)))
    }

    func testDownloadRejectsWebPages() async throws {
        let server = FakeMediaServer()
        server.serve(draft("page").url, .init(body: Data("<html>".utf8), mime: "text/html"))
        let listen = makeListen(server: server)
        let items = try await listen.add([draft("page")], placement: .end, download: .now)
        for _ in 0..<50 where listen.store.item(items[0].id)?.download != .failed {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(listen.store.item(items[0].id)?.download, .failed)
        XCTAssertEqual(listen.store.item(items[0].id)?.downloadError?.contains("web page"), true)
    }

    // MARK: - Streaming

    /// Serves draft("ep") as a 40-byte file; `held` holds back all but the first 10 bytes.
    private func episodeServer(held: Bool = false) -> FakeMediaServer {
        let server = FakeMediaServer()
        server.serve(draft("ep").url, .init(body: mediaBody(40)))
        if held { server.hold(10..<40) }
        return server
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
    }

    func testPlayingTheLoadedItemAgainKeepsItsBuffer() async throws {
        let engine = FakeListenEngine()
        let listen = makeListen(engine: engine)
        let items = try await listen.add([draft("a")], placement: .now, download: .never)
        engine.currentTime = 42
        listen.player.pause()
        try await listen.player.play(items[0].id)
        XCTAssertEqual(engine.loads.count, 1, "resumes instead of fetching the stream again")
        XCTAssertEqual(listen.player.status, .playing)
    }

    func testStreamingCachesTheItemThenSeeksFromTheFile() async throws {
        let engine = FakeListenEngine()
        let server = episodeServer(held: true)
        let listen = makeListen(engine: engine, server: server)
        let items = try await listen.add([draft("ep")], placement: .now, download: .never)
        XCTAssertTrue(listen.player.streaming)
        let stream = try XCTUnwrap(engine.loads.last).source
        XCTAssertFalse(stream.isLocal)
        XCTAssertNotNil(stream.transfer, "playback reads through the download")

        try await waitFor { listen.downloader.progress[items[0].id]?.fraction != nil }
        XCTAssertEqual(listen.downloader.progress[items[0].id]?.fraction, 0.25, "progress is visible while saving")
        XCTAssertTrue(listen.downloader.isCachingForPlayback(items[0].id))

        engine.bufferedUntil = 90
        engine.send(.buffer)
        XCTAssertEqual(listen.player.bufferedUntil, 90)

        server.release()
        try await waitFor { listen.store.item(items[0].id)?.download == .downloaded }
        XCTAssertEqual(listen.store.item(items[0].id)?.cachedForPlayback, true)
        XCTAssertEqual(server.requests.count, 1, "one download feeds playback and the saved file")
        XCTAssertEqual(server.bytesSent, 40)

        await listen.player.seek(to: 300)
        XCTAssertEqual(engine.loads.count, 2)
        XCTAssertTrue(try XCTUnwrap(engine.loads.last).source.isLocal, "once saved, seeks use the file")
        XCTAssertEqual(engine.loads.last?.startAt, 300)
        XCTAssertFalse(listen.player.streaming)
        XCTAssertNil(listen.player.bufferedUntil)
        XCTAssertEqual(listen.player.status, .playing)

        engine.send(.ended)
        await settle()
        XCTAssertEqual(listen.store.item(items[0].id)?.download, ListenItem.Download.none,
                       "a file saved only for streaming goes once played")
    }

    func testPlayingWhileDownloadingFetchesOnce() async throws {
        let engine = FakeListenEngine()
        let server = episodeServer(held: true)
        let listen = makeListen(engine: engine, server: server)
        let items = try await listen.add([draft("ep")], placement: .end, download: .now)
        XCTAssertEqual(listen.store.item(items[0].id)?.download, .downloading)
        try await listen.player.play(items[0].id)
        XCTAssertNotNil(engine.loads.last?.source.transfer, "playback joins the download in flight")
        server.release()
        try await waitFor { listen.store.item(items[0].id)?.download == .downloaded }
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertEqual(server.bytesSent, 40)
        XCTAssertNil(listen.store.item(items[0].id)?.cachedForPlayback, "an explicit download is kept")
    }

    func testStoppingTheSaveKeepsPlaybackStreaming() async throws {
        let engine = FakeListenEngine()
        let server = episodeServer(held: true)
        let listen = makeListen(engine: engine, server: server)
        let items = try await listen.add([draft("ep")], placement: .now, download: .never)
        let id = items[0].id
        let transfer = try XCTUnwrap(engine.loads.last?.source.transfer)
        try await waitFor { transfer.progress.received == 10 }
        listen.downloader.cancel(id)
        XCTAssertEqual(listen.store.item(id)?.download, ListenItem.Download.none)
        let read = FakeRead(0, length: 10)
        transfer.read(read)
        try await waitFor { read.finished }
        XCTAssertEqual(read.data, mediaBody(40).prefix(10), "playback carries on")

        listen.downloader.download(id)
        server.release()
        try await waitFor { listen.store.item(id)?.download == .downloaded }
        XCTAssertEqual(server.ranges(for: draft("ep").url), ["bytes=0-", "bytes=10-"],
                       "saving again carries on where it stopped")
        XCTAssertEqual(server.bytesSent, 40)
        XCTAssertNil(listen.store.item(id)?.cachedForPlayback)
    }

    func testExplicitDownloadsSurvivePlaying() async throws {
        let engine = FakeListenEngine()
        let listen = makeListen(engine: engine, server: episodeServer())
        let items = try await listen.add([draft("ep")], placement: .end, download: .now)
        try await waitFor { listen.store.item(items[0].id)?.download == .downloaded }
        try await listen.player.play(items[0].id)
        XCTAssertFalse(listen.player.streaming)
        engine.send(.ended)
        await settle()
        XCTAssertEqual(listen.store.item(items[0].id)?.download, .downloaded)
    }

    func testDroppedStreamCarriesOnFromTheSavedFile() async throws {
        let engine = FakeListenEngine()
        let listen = makeListen(engine: engine, server: episodeServer())
        let items = try await listen.add([draft("ep")], placement: .now, download: .never)
        try await waitFor { listen.store.item(items[0].id)?.download == .downloaded }
        engine.currentTime = 120
        engine.send(.failed("The network connection was lost."))
        try await waitFor { engine.loads.count == 2 }
        XCTAssertTrue(try XCTUnwrap(engine.loads.last).source.isLocal)
        XCTAssertEqual(engine.loads.last?.startAt, 120)
        try await waitFor { listen.player.status == .playing }
        XCTAssertNil(listen.player.notice)
    }

    func testFailedLoadStopsPreviousPlayback() async throws {
        let engine = FakeListenEngine()
        let listen = makeListen(engine: engine)
        let items = try await listen.add([draft("a"), draft("b")], placement: .now, download: .never)
        engine.loadError = ListenError.playbackFailed("could not load")
        do {
            try await listen.player.play(items[1].id)
            XCTFail("expected a load failure")
        } catch {}
        XCTAssertFalse(engine.playing)
        XCTAssertEqual(engine.stops, 1)
        XCTAssertEqual(listen.player.status, .failed(ListenError.playbackFailed("could not load").localizedDescription))
    }

    func testPlaybackFailureUnloadsEngine() async throws {
        let engine = FakeListenEngine()
        let listen = makeListen(engine: engine)
        _ = try await listen.add([draft("a")], placement: .now, download: .never)
        engine.currentTime = 42
        engine.send(.failed("stream failed"))
        XCTAssertFalse(engine.playing)
        XCTAssertEqual(engine.stops, 1)
        XCTAssertEqual(listen.player.position, 42)
        XCTAssertEqual(listen.player.status, .failed("stream failed"))
        XCTAssertFalse(listen.player.streaming)
    }

    func testStopWinsAgainstQueuedDownloadRecovery() async throws {
        let engine = FakeListenEngine()
        let listen = makeListen(engine: engine, server: episodeServer())
        let items = try await listen.add([draft("ep")], placement: .now, download: .never)
        try await waitFor { listen.store.item(items[0].id)?.download == .downloaded }
        engine.send(.failed("stream failed"))
        listen.player.stop()
        await settle()
        XCTAssertEqual(engine.loads.count, 1, "a queued recovery must not restart stopped playback")
        XCTAssertFalse(engine.playing)
        XCTAssertEqual(listen.player.status, .idle)
    }

    func testOldEndEventDoesNotFinishNewPlayback() async throws {
        let engine = FakeListenEngine()
        let listen = makeListen(engine: engine)
        let items = try await listen.add([draft("a"), draft("b")], placement: .now, download: .never)
        engine.send(.ended)
        listen.player.stop()
        try await listen.player.play(items[1].id)
        await settle()
        XCTAssertEqual(listen.player.currentID, items[1].id)
        XCTAssertEqual(listen.player.status, .playing)
        XCTAssertEqual(listen.store.item(items[1].id)?.status, .inProgress)
    }

    func testPauseAndStopWinAgainstQueuedInterruptionResume() async throws {
        for stop in [false, true] {
            let engine = FakeListenEngine()
            let listen = makeListen(engine: engine)
            _ = try await listen.add([draft("a")], placement: .now, download: .never)
            engine.send(.interrupted)
            engine.send(.interruptionEnded(shouldResume: true))
            if stop { listen.player.stop() } else { listen.player.pause() }
            await settle()
            XCTAssertEqual(engine.rates.count, 1, "interruption recovery must not restart playback")
            XCTAssertEqual(listen.player.status, stop ? .idle : .paused)
        }
    }

    func testClosingStopsAndKeepsTheItemQueued() async throws {
        let engine = FakeListenEngine()
        let listen = makeListen(engine: engine)
        let items = try await listen.add([draft("a")], placement: .now, download: .never)
        engine.currentTime = 75
        listen.player.stop()
        XCTAssertFalse(listen.player.showsBar)
        XCTAssertFalse(engine.playing)
        XCTAssertEqual(listen.store.item(items[0].id)?.position, 75)
        XCTAssertEqual(listen.store.upNext.map(\.id), [items[0].id])
    }
}

private final class UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

private final class Flag {
    var raised = false
}

@MainActor
final class ListenAudioSessionTests: XCTestCase {
    func testNormalPlaybackDoesNotMix() async throws {
        let session = FakeListenAudioSession()
        let engine = AVListenEngine(audioSession: session)
        try await engine.play(rate: 1)
        XCTAssertEqual(session.categoryOptions, [[]])
        XCTAssertEqual(session.activationCount, 1)
    }

    func testSessionCallsStayOffTheMainThreadAndInOrder() async throws {
        let session = FakeListenAudioSession()
        let engine = AVListenEngine(audioSession: session)
        try await engine.play(rate: 1)
        engine.stop()
        // Queued behind the deactivation, so this also waits for it.
        try await engine.play(rate: 1)
        XCTAssertEqual(session.activeCalls, [true, false, true])
        XCTAssertFalse(session.calledOnMainThread)
    }

    func testBackgroundInterruptionDenialRetriesWithMixing() async throws {
        let session = FakeListenAudioSession()
        session.activationErrors = [NSError(domain: NSOSStatusErrorDomain,
                                            code: AVAudioSession.ErrorCode.cannotInterruptOthers.rawValue)]
        let engine = AVListenEngine(audioSession: session)
        try await engine.play(rate: 1)
        XCTAssertEqual(session.categoryOptions, [[], [.mixWithOthers]])
        XCTAssertEqual(session.activationCount, 2)

        // The fallback is not sticky: the next request tries exclusive playback.
        try await engine.play(rate: 1)
        XCTAssertEqual(session.categoryOptions.last, [])
    }

    func testUnrelatedActivationErrorsAreNotRetried() async {
        let session = FakeListenAudioSession()
        session.activationErrors = [NSError(domain: NSOSStatusErrorDomain, code: -50)]
        let engine = AVListenEngine(audioSession: session)
        do {
            try await engine.play(rate: 1)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual((error as NSError).code, -50)
        }
        XCTAssertEqual(session.activationCount, 1)
        XCTAssertEqual(session.categoryOptions, [[]])
    }

    func testFailedFallbackIsReported() async {
        let session = FakeListenAudioSession()
        session.activationErrors = [
            NSError(domain: NSOSStatusErrorDomain, code: AVAudioSession.ErrorCode.cannotInterruptOthers.rawValue),
            NSError(domain: NSOSStatusErrorDomain, code: -50),
        ]
        let engine = AVListenEngine(audioSession: session)
        do {
            try await engine.play(rate: 1)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual((error as NSError).code, -50)
        }
        XCTAssertEqual(session.activationCount, 2)
    }
}

/// Called on the engine's session queue; tests read it only after awaiting
/// the engine, which orders those reads after the calls.
private final class FakeListenAudioSession: ListenAudioSession, @unchecked Sendable {
    var categoryOptions: [AVAudioSession.CategoryOptions] = []
    var activationErrors: [NSError] = []
    var activationCount = 0
    var activeCalls: [Bool] = []
    var calledOnMainThread = false

    func setCategory(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode,
                     policy: AVAudioSession.RouteSharingPolicy, options: AVAudioSession.CategoryOptions) throws {
        if Thread.isMainThread { calledOnMainThread = true }
        XCTAssertEqual(category, .playback)
        XCTAssertEqual(mode, .spokenAudio)
        XCTAssertEqual(policy, .longFormAudio)
        categoryOptions.append(options)
    }

    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
        if Thread.isMainThread { calledOnMainThread = true }
        activeCalls.append(active)
        guard active else { return }
        activationCount += 1
        if !activationErrors.isEmpty { throw activationErrors.removeFirst() }
    }
}

/// Exercises the real Foundation transport, not just the downloader's Fetch seam.
@MainActor
final class ListenMediaTransportTests: XCTestCase {
    func testMediaSessionHasNoAmbientCredentialStores() {
        let session = ListenMediaSession.makeSession()
        defer { session.invalidateAndCancel() }
        XCTAssertFalse(session.configuration.httpShouldSetCookies)
        XCTAssertNil(session.configuration.httpCookieStorage)
        XCTAssertNil(session.configuration.urlCredentialStorage)
    }

    func testArtworkTransportIgnoresAmbientCookiesAndPreservesExplicitHeaders() async throws {
        let fixture = MediaTransportFixture()
        defer { fixture.cleanUp() }
        for explicit in [false, true] {
            var request = URLRequest(url: fixture.url)
            request.httpShouldHandleCookies = false
            if explicit { request.setValue("scoped=owner", forHTTPHeaderField: "Cookie") }
            let (data, response) = try await fixture.session.data(for: request)
            XCTAssertEqual(data, Data("media".utf8), "public media still loads without credentials")
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            let received = try XCTUnwrap(MediaTransportProtocol.requests(for: fixture.url).last)
            XCTAssertEqual(received.value(forHTTPHeaderField: "Cookie"), explicit ? "scoped=owner" : nil)
            XCTAssertNil(received.value(forHTTPHeaderField: "Authorization"))
        }
        XCTAssertEqual(HTTPCookieStorage.shared.cookies(for: fixture.url)?.map(\.value), ["ambient"],
                       "Set-Cookie from media must not modify the ambient store")
    }

    func testDownloaderUsesIsolatedTransportWithEmptyAndExplicitScopedCookies() async throws {
        let fixture = MediaTransportFixture()
        defer { fixture.cleanUp() }
        for explicit in [false, true] {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let jar = FakeCookieJar()
            if explicit {
                jar.cookies = [HTTPCookie(properties: [.name: "scoped", .value: "owner",
                                                       .domain: fixture.url.host!, .path: "/"])!]
            }
            // The production transport, with only the URLProtocol registration changed.
            let listen = makeListen(cookies: jar, directory: directory,
                                    fetching: ListenSessionFetching(session: fixture.session))
            let items = try await listen.add([ListenDraft(url: fixture.url, sourceID: UUID())],
                                             placement: .end, download: .now)
            for _ in 0..<100 where listen.downloader.activeCount > 0 {
                try await Task.sleep(for: .milliseconds(20))
            }
            let item = try XCTUnwrap(listen.store.item(items[0].id))
            XCTAssertEqual(item.download, .downloaded, item.downloadError ?? "download must finish")
            let received = try XCTUnwrap(MediaTransportProtocol.requests(for: fixture.url).last)
            XCTAssertFalse(received.httpShouldHandleCookies)
            XCTAssertEqual(received.value(forHTTPHeaderField: "Cookie"), explicit ? "scoped=owner" : nil)
            XCTAssertNil(received.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(jar.requested, [fixture.url])
        }
    }

    func testNowPlayingArtworkUsesScopedCookiesOnly() async throws {
        let fixture = MediaTransportFixture()
        defer { fixture.cleanUp() }
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let jar = FakeCookieJar()
        let artwork = ListenArtworkStore(directory: directory.appending(path: "Artwork"), cookies: jar,
                                         server: { nil }, session: fixture.session)
        let nowPlaying = SystemNowPlaying(artwork: artwork)
        defer { nowPlaying.clear() }
        for explicit in [false, true] {
            jar.cookies = explicit ? [HTTPCookie(properties: [.name: "scoped", .value: "owner",
                                                             .domain: fixture.url.host!, .path: "/"])!] : []
            let item = ListenStore(fileURL: directory.appending(path: "library.json"))
                .add([ListenDraft(url: fixture.url, artworkURL: fixture.url, sourceID: UUID())], placement: .end)[0]
            let previous = MediaTransportProtocol.requests(for: fixture.url).count
            nowPlaying.show(item, position: 0, duration: nil, rate: 1, playing: false)
            for _ in 0..<100 where MediaTransportProtocol.requests(for: fixture.url).count == previous {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(MediaTransportProtocol.requests(for: fixture.url).count, previous + 1)
            let received = try XCTUnwrap(MediaTransportProtocol.requests(for: fixture.url).last)
            XCTAssertFalse(received.httpShouldHandleCookies)
            XCTAssertEqual(received.value(forHTTPHeaderField: "Cookie"), explicit ? "scoped=owner" : nil)
            XCTAssertNil(received.value(forHTTPHeaderField: "Authorization"))
        }
    }

    func testMediaRedirectDropsScopedCredentialsEvenWithinSameHost() throws {
        let session = ListenMediaSession.makeSession()
        defer { session.invalidateAndCancel() }
        let original = URL(string: "https://hub.example/owner/media.mp3")!
        for target in ["https://hub.example/other/file.mp3", "https://cdn.example/file.mp3"] {
            var request = URLRequest(url: URL(string: target)!)
            request.setValue("scoped=owner", forHTTPHeaderField: "Cookie")
            request.setValue("Bearer owner", forHTTPHeaderField: "Authorization")
            let response = HTTPURLResponse(url: original, statusCode: 302, httpVersion: nil, headerFields: nil)!
            let task = session.dataTask(with: original)
            let targetURL = request.url
            ListenMediaSession.Delegate().urlSession(session, task: task,
                                                     willPerformHTTPRedirection: response, newRequest: request) { redirected in
                XCTAssertEqual(redirected?.url, targetURL, "public redirects still follow")
                XCTAssertEqual(redirected?.httpShouldHandleCookies, false)
                XCTAssertNil(redirected?.value(forHTTPHeaderField: "Cookie"))
                XCTAssertNil(redirected?.value(forHTTPHeaderField: "Authorization"))
            }
            task.cancel()
        }
    }
}

private final class MediaTransportFixture: @unchecked Sendable {
    let url = URL(string: "https://\(UUID().uuidString.lowercased()).media.example/media.mp3")!
    let session = ListenMediaSession.makeSession(protocolClasses: [MediaTransportProtocol.self])
    private let credential = URLCredential(user: "ambient", password: "secret", persistence: .forSession)
    private let space: URLProtectionSpace
    private let cookie: HTTPCookie

    init() {
        cookie = HTTPCookie(properties: [.name: "session", .value: "ambient", .domain: url.host!, .path: "/"])!
        space = URLProtectionSpace(host: url.host!, port: 443, protocol: "https", realm: nil,
                                   authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        HTTPCookieStorage.shared.setCookie(cookie)
        URLCredentialStorage.shared.setDefaultCredential(credential, for: space)
    }

    func cleanUp() {
        session.invalidateAndCancel()
        HTTPCookieStorage.shared.deleteCookie(cookie)
        URLCredentialStorage.shared.remove(credential, for: space)
        MediaTransportProtocol.removeRequests(for: url)
    }
}

private final class MediaTransportProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    // Guarded by `lock`.
    nonisolated(unsafe) private static var recorded: [URL: [URLRequest]] = [:]

    static func requests(for url: URL) -> [URLRequest] { lock.withLock { recorded[url] ?? [] } }
    static func removeRequests(for url: URL) { lock.withLock { recorded[url] = nil } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".media.example") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.withLock { Self.recorded[url, default: []].append(request) }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "audio/mpeg", "Set-Cookie": "session=response; Path=/"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("media".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class ListenArtworkTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = temporaryDirectory()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store(_ session: URLSession) -> ListenArtworkStore {
        ListenArtworkStore(directory: directory, cookies: FakeCookieJar(), server: { nil }, session: session)
    }

    private func item(_ name: String = "cover.jpg", sourceID: UUID? = nil) -> ListenItem {
        let artwork = URL(string: "https://\(UUID().uuidString.lowercased()).artwork.example/\(name)")!
        return ListenStore(fileURL: directory.appending(path: "library.json"))
            .add([ListenDraft(url: URL(string: "https://pod.example/\(UUID()).mp3")!, artworkURL: artwork,
                              sourceID: sourceID)], placement: .end)[0]
    }

    func testArtworkIsFetchedOnceAndReadFromItsFileAfterThat() async throws {
        let session = ListenMediaSession.makeSession(protocolClasses: [ArtworkProtocol.self])
        defer { session.invalidateAndCancel() }
        let artwork = store(session)
        let episode = item()
        let url = try XCTUnwrap(episode.artworkURL)
        let row = ListenArtworkStore.pixels(for: 44, scale: 3)
        XCTAssertEqual(row, ListenArtworkStore.pixels(for: 42, scale: 3), "the mini player and list rows share one size")
        XCTAssertNil(artwork.cachedImage(for: episode, pixels: row))

        async let first = artwork.image(for: episode, pixels: row)
        async let second = artwork.image(for: episode, pixels: row)
        let images = await [first, second]
        XCTAssertEqual(images[0]?.cgImage?.width, 160, "decoded at display size")
        XCTAssertNotNil(images[1])
        XCTAssertEqual(ArtworkProtocol.requests(for: url), 1, "views showing the same artwork share one download")
        XCTAssertNotNil(artwork.cachedImage(for: episode, pixels: row), "a rebuilt view reads it without waiting")

        let file = try XCTUnwrap(artwork.savedFile(for: episode))
        XCTAssertEqual(file.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
        XCTAssertEqual(ListenArtworkStore.decode(file, maxPixels: 4096)?.cgImage?.width, 1024,
                       "saved at lock-screen size, not the served 1200 px")
        let large = await artwork.image(for: episode, pixels: ListenArtworkStore.pixels(for: 240, scale: 3))
        XCTAssertEqual(large?.cgImage?.width, 800)

        // Another launch reads the same file.
        let relaunched = store(session)
        let again = await relaunched.image(for: episode, pixels: row)
        XCTAssertNotNil(again)
        XCTAssertEqual(ArtworkProtocol.requests(for: url), 1, "never downloaded again")
    }

    func testMissingArtworkIsNotRefetchedOnEveryRebuild() async throws {
        let session = ListenMediaSession.makeSession(protocolClasses: [ArtworkProtocol.self])
        defer { session.invalidateAndCancel() }
        let artwork = store(session)
        let episode = item("missing.jpg")
        let first = await artwork.image(for: episode, pixels: 160)
        let second = await artwork.image(for: episode, pixels: 160)
        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(ArtworkProtocol.requests(for: try XCTUnwrap(episode.artworkURL)), 1)
        var plain = episode
        plain.artworkURL = nil
        let none = await artwork.image(for: plain, pixels: 160)
        XCTAssertNil(none)
    }

    func testEachOwnersArtworkIsKeptApartAndUnusedFilesGo() async throws {
        let session = ListenMediaSession.makeSession(protocolClasses: [ArtworkProtocol.self])
        defer { session.invalidateAndCancel() }
        let artwork = store(session)
        let public1 = item()
        var owned = public1
        owned.sourceID = UUID()
        XCTAssertNotEqual(artwork.fileName(for: public1), artwork.fileName(for: owned),
                          "an image fetched with one connection's sign-in never shows for another")
        let other = item()
        _ = await artwork.image(for: public1, pixels: 160)
        _ = await artwork.image(for: other, pixels: 160)
        XCTAssertNotNil(artwork.savedFile(for: other))
        artwork.prune(keeping: [public1])
        XCTAssertNotNil(artwork.savedFile(for: public1))
        XCTAssertNil(artwork.savedFile(for: other))
    }

    /// MediaPlayer renders artwork on its own queue. The closure used to be
    /// main-actor isolated, so playing anything with artwork trapped there.
    func testLockScreenArtworkRendersOffTheMainThread() async throws {
        let file = try XCTUnwrap(ListenArtworkStore.save(ArtworkProtocol.jpeg(side: 3000),
                                                         to: directory.appending(path: "big.img"), in: directory))
        let image = try XCTUnwrap(ListenArtworkStore.decode(file, maxPixels: ListenArtworkStore.savedPixels))
        XCTAssertEqual(image.cgImage?.width, 1024)
        let artwork = UncheckedBox(SystemNowPlaying.artwork(image))
        let rendered = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: artwork.value.image(at: CGSize(width: 300, height: 300)) != nil)
            }
        }
        XCTAssertTrue(rendered)
    }
}

final class ArtworkProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    // Guarded by `lock`.
    nonisolated(unsafe) private static var counts: [URL: Int] = [:]
    private static let body = jpeg(side: 1200)

    static func requests(for url: URL) -> Int { lock.withLock { counts[url] ?? 0 } }

    static func jpeg(side: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: side, height: side)
        return UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.8) { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".artwork.example") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.withLock { Self.counts[url, default: 0] += 1 }
        let missing = url.lastPathComponent.hasPrefix("missing")
        let response = HTTPURLResponse(url: url, statusCode: missing ? 404 : 200, httpVersion: nil,
                                       headerFields: ["Content-Type": missing ? "text/html" : "image/jpeg"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: missing ? Data("<html>".utf8) : Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
