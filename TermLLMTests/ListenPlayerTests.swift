import AVFoundation
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
        let listen = makeListen(cookies: cookies, directory: directory, fetch: { request, _ in
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
        let listen = makeListen(fetch: { request, _ in
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

    // MARK: - Streaming

    /// A fetch that serves a small MP3 after `gate` opens, reporting progress.
    private func audioFetch(gate: AsyncStream<Void>? = nil) -> ListenDownloader.Fetch {
        let box = UncheckedBox(gate)
        return { request, transfer in
            transfer.report(received: 10, expected: 40)
            if let gate = box.value { for await _ in gate { break } }
            let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try Data("ID3fake".utf8).write(to: file)
            return (file, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                          headerFields: ["Content-Type": "audio/mpeg"])!)
        }
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
        let (gate, open) = AsyncStream<Void>.makeStream()
        let listen = makeListen(engine: engine, fetch: audioFetch(gate: gate))
        let items = try await listen.add([draft("ep")], placement: .now, download: .never)
        XCTAssertTrue(listen.player.streaming)
        XCTAssertFalse(try XCTUnwrap(engine.loads.last).source.isLocal)

        try await waitFor { listen.downloader.progress[items[0].id]?.fraction != nil }
        XCTAssertEqual(listen.downloader.progress[items[0].id]?.fraction, 0.25, "progress is visible while saving")
        XCTAssertTrue(listen.downloader.isCachingForPlayback(items[0].id))

        engine.bufferedUntil = 90
        engine.send(.buffer)
        XCTAssertEqual(listen.player.bufferedUntil, 90)

        open.yield()
        try await waitFor { listen.store.item(items[0].id)?.download == .downloaded }
        XCTAssertEqual(listen.store.item(items[0].id)?.cachedForPlayback, true)

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

    func testExplicitDownloadsSurvivePlaying() async throws {
        let engine = FakeListenEngine()
        let listen = makeListen(engine: engine, fetch: audioFetch())
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
        let listen = makeListen(engine: engine, fetch: audioFetch())
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

@MainActor
final class ListenAudioSessionTests: XCTestCase {
    func testNormalPlaybackDoesNotMix() throws {
        let session = FakeListenAudioSession()
        let engine = AVListenEngine(audioSession: session)
        try engine.play(rate: 1)
        XCTAssertEqual(session.categoryOptions, [[]])
        XCTAssertEqual(session.activationCount, 1)
    }

    func testBackgroundInterruptionDenialRetriesWithMixing() throws {
        let session = FakeListenAudioSession()
        session.activationErrors = [NSError(domain: NSOSStatusErrorDomain,
                                            code: AVAudioSession.ErrorCode.cannotInterruptOthers.rawValue)]
        let engine = AVListenEngine(audioSession: session)
        try engine.play(rate: 1)
        XCTAssertEqual(session.categoryOptions, [[], [.mixWithOthers]])
        XCTAssertEqual(session.activationCount, 2)

        // The fallback is not sticky: the next request tries exclusive playback.
        try engine.play(rate: 1)
        XCTAssertEqual(session.categoryOptions.last, [])
    }

    func testUnrelatedActivationErrorsAreNotRetried() {
        let session = FakeListenAudioSession()
        session.activationErrors = [NSError(domain: NSOSStatusErrorDomain, code: -50)]
        let engine = AVListenEngine(audioSession: session)
        XCTAssertThrowsError(try engine.play(rate: 1)) { error in
            XCTAssertEqual((error as NSError).code, -50)
        }
        XCTAssertEqual(session.activationCount, 1)
        XCTAssertEqual(session.categoryOptions, [[]])
    }

    func testFailedFallbackIsReported() {
        let session = FakeListenAudioSession()
        session.activationErrors = [
            NSError(domain: NSOSStatusErrorDomain, code: AVAudioSession.ErrorCode.cannotInterruptOthers.rawValue),
            NSError(domain: NSOSStatusErrorDomain, code: -50),
        ]
        let engine = AVListenEngine(audioSession: session)
        XCTAssertThrowsError(try engine.play(rate: 1)) { error in
            XCTAssertEqual((error as NSError).code, -50)
        }
        XCTAssertEqual(session.activationCount, 2)
    }
}

@MainActor
private final class FakeListenAudioSession: ListenAudioSession {
    var categoryOptions: [AVAudioSession.CategoryOptions] = []
    var activationErrors: [NSError] = []
    var activationCount = 0

    func setCategory(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode,
                     policy: AVAudioSession.RouteSharingPolicy, options: AVAudioSession.CategoryOptions) throws {
        XCTAssertEqual(category, .playback)
        XCTAssertEqual(mode, .spokenAudio)
        XCTAssertEqual(policy, .longFormAudio)
        categoryOptions.append(options)
    }

    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
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
            let listen = makeListen(cookies: jar, directory: directory, fetch: { request, _ in
                // Keep the real consumer's request and execute its production
                // download transport with only the URLProtocol registration changed.
                try await ListenTransfer.fetch(request, ListenTransfer(session: fixture.session))
            })
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
        let nowPlaying = SystemNowPlaying(cookies: jar, server: { nil }, session: fixture.session)
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
    private static var recorded: [URL: [URLRequest]] = [:]

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
