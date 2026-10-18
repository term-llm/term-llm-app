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
        XCTAssertEqual(engine.stops, 1)
        XCTAssertTrue(listen.store.items.isEmpty)
    }

    func testServerMediaStreamsWithCookiesAndOthersWithout() async throws {
        let engine = FakeListenEngine()
        let cookies = FakeCookieJar()
        cookies.cookies = [HTTPCookie(properties: [.domain: "hub.example", .path: "/", .name: "s", .value: "1"])!]
        let listen = makeListen(engine: engine, cookies: cookies)
        let items = try await listen.add([ListenDraft(url: URL(string: "https://hub.example/media/a.mp3")!),
                                          draft("b")], placement: .end, download: .never)
        try await listen.player.play(items[0].id)
        XCTAssertEqual(engine.loads.last?.source.cookies.count, 1)
        try await listen.player.play(items[1].id)
        XCTAssertEqual(engine.loads.last?.source.cookies.count, 0)
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
        let source = directory.appending(path: "payload.tmp")
        try Data("ID3fake".utf8).write(to: source)
        let cookies = FakeCookieJar()
        let listen = makeListen(cookies: cookies, directory: directory, fetch: { request in
            XCTAssertEqual(request.url?.host(), "hub.example")
            let copy = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.copyItem(at: source, to: copy)
            return (copy, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                          headerFields: ["Content-Type": "audio/mpeg"])!)
        })
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
        let listen = makeListen(fetch: { request in
            let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try Data("<html>".utf8).write(to: file)
            return (file, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                          headerFields: ["Content-Type": "text/html; charset=utf-8"])!)
        })
        let items = try await listen.add([draft("page")], placement: .end, download: .now)
        for _ in 0..<50 where listen.store.item(items[0].id)?.download != .failed {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(listen.store.item(items[0].id)?.download, .failed)
        XCTAssertEqual(listen.store.item(items[0].id)?.downloadError?.contains("web page"), true)
    }
}
