import XCTest
@testable import TermLLM

@MainActor
final class ListenStoreTests: XCTestCase {
    func testPlacementsOrderUpNext() {
        let store = ListenStore(fileURL: temporaryDirectory().appending(path: "library.json"))
        let a = store.add([draft("a"), draft("b")], placement: .end)
        let c = store.add([draft("c")], placement: .now)
        store.add([draft("d")], placement: .next, after: a[0].id)
        store.add([draft("e")], placement: .end)
        XCTAssertEqual(store.upNext.map(\.title), ["c", "a", "d", "b", "e"])
        XCTAssertEqual(c[0].kind, .audio)
    }

    func testReAddingAURLMovesItInsteadOfDuplicating() throws {
        let store = ListenStore(fileURL: temporaryDirectory().appending(path: "library.json"))
        let first = store.add([draft("a"), draft("b")], placement: .end)
        try store.setStatus([first[0].id], .played)
        let again = store.add([draft("a", title: "Better title")], placement: .now)
        XCTAssertEqual(again[0].id, first[0].id)
        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(store.upNext.map(\.title), ["Better title", "b"])
        XCTAssertEqual(store.upNext.first?.status, .unplayed, "re-adding a played item brings it back")
    }

    func testStatusChangesAndHistory() throws {
        let store = ListenStore(fileURL: temporaryDirectory().appending(path: "library.json"))
        let items = store.add([draft("a"), draft("b"), draft("c")], placement: .end)
        try store.setStatus([items[1].id], .played)
        XCTAssertEqual(store.upNext.map(\.title), ["a", "c"])
        XCTAssertEqual(store.history.map(\.title), ["b"])
        try store.setStatus([items[1].id], .unplayed)
        XCTAssertEqual(store.upNext.map(\.title), ["a", "c", "b"], "returning items go to the end")
        XCTAssertEqual(store.clearHistory().count, 0)
        try store.setStatus([items[0].id], .archived)
        XCTAssertEqual(store.clearHistory().map(\.title), ["a"])
        XCTAssertEqual(store.items.count, 2)
    }

    func testMoveAndNeighbours() throws {
        let store = ListenStore(fileURL: temporaryDirectory().appending(path: "library.json"))
        let items = store.add([draft("a"), draft("b"), draft("c")], placement: .end)
        try store.move(items[2].id, toUpNextIndex: 0)
        XCTAssertEqual(store.upNext.map(\.title), ["c", "a", "b"])
        XCTAssertEqual(store.upNext(after: items[2].id)?.title, "a")
        XCTAssertEqual(store.upNext(before: items[0].id)?.title, "c")
        XCTAssertNil(store.upNext(after: items[1].id))
        XCTAssertEqual(store.upNext(after: nil)?.title, "c")
    }

    func testResolvesByIDOrTitle() throws {
        let store = ListenStore(fileURL: temporaryDirectory().appending(path: "library.json"))
        let items = store.add([draft("a", title: "Morning Briefing")], placement: .end)
        XCTAssertEqual(try store.resolve(items[0].id.uuidString).id, items[0].id)
        XCTAssertEqual(try store.resolve("morning briefing").id, items[0].id)
        XCTAssertThrowsError(try store.resolve("nope"))
    }

    /// Playback records its position regularly. That must not rewrite the
    /// library, which history and show notes make hundreds of KB.
    func testPositionsAreSavedApartFromTheLibrary() async throws {
        let library = temporaryDirectory().appending(path: "library.json")
        let positions = ListenStore.positionsURL(for: library)
        let store = ListenStore(fileURL: library)
        let items = store.add([draft("a"), draft("b")], placement: .end)
        await store.flushForTesting()
        let saved = try Data(contentsOf: library)

        store.setPosition(120, for: items[0].id)
        store.setPosition(150, for: items[0].id)
        await store.flushForTesting()
        XCTAssertEqual(try Data(contentsOf: library), saved, "the library isn't rewritten")
        XCTAssertEqual(store.item(items[0].id)?.position, 150)
        XCTAssertLessThan(try Data(contentsOf: positions).count, 200)
        XCTAssertEqual(ListenStore(fileURL: library).item(items[0].id)?.position, 150, "a relaunch restores it")

        // The next library save takes the position in and drops the small file.
        try store.setStatus([items[1].id], .archived)
        await store.flushForTesting()
        XCTAssertFalse(FileManager.default.fileExists(atPath: positions.path(percentEncoded: false)))
        XCTAssertEqual(ListenStore(fileURL: library).item(items[0].id)?.position, 150)
    }

    func testAnUnreadablePositionsFileFallsBackToTheLibrary() async throws {
        let library = temporaryDirectory().appending(path: "library.json")
        let store = ListenStore(fileURL: library)
        let items = store.add([draft("a")], placement: .end)
        store.setPosition(30, for: items[0].id)
        try store.setStatus([items[0].id], .inProgress)
        await store.flushForTesting()
        try Data("{".utf8).write(to: ListenStore.positionsURL(for: library))
        let reopened = ListenStore(fileURL: library)
        XCTAssertEqual(reopened.item(items[0].id)?.position, 30)
        XCTAssertNil(reopened.notice)
    }

    func testPersistsAndRecoversFromAnUnreadableFile() async throws {
        let directory = temporaryDirectory()
        let file = directory.appending(path: "library.json")
        let store = ListenStore(fileURL: file)
        let items = store.add([draft("a"), draft("b")], placement: .end)
        store.update(items[0].id) { $0.position = 42; $0.status = .inProgress }
        await store.flushForTesting()

        let reopened = ListenStore(fileURL: file)
        XCTAssertEqual(reopened.upNext.map(\.title), ["a", "b"])
        XCTAssertEqual(reopened.item(items[0].id)?.position, 42)

        try Data("not json".utf8).write(to: file)
        let recovered = ListenStore(fileURL: file)
        XCTAssertTrue(recovered.items.isEmpty)
        XCTAssertNotNil(recovered.notice)
        await recovered.flushForTesting()
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        XCTAssertTrue(names.contains { $0.hasPrefix("library-unreadable-") })
    }

    func testResumePositionRestartsNearlyFinishedItems() {
        var item = ListenItem(url: URL(string: "https://x.example/a.mp3")!, title: "a", duration: 100,
                              status: .inProgress, position: 40)
        XCTAssertEqual(item.resumePosition(), 40)
        item.position = 97
        XCTAssertEqual(item.resumePosition(), 0)
        item.status = .unplayed
        item.position = 40
        XCTAssertEqual(item.resumePosition(), 0)
    }

    func testSameMediaURLRetainsDistinctPersistentSourceOwners() async throws {
        let directory = temporaryDirectory()
        let file = directory.appendingPathComponent("owned-media.json")
        let store = ListenStore(fileURL: file)
        let url = URL(string: "https://example.com/nested/media.mp3")!
        let a = UUID(), b = UUID()
        let items = store.add([ListenDraft(url: url, sourceID: a), ListenDraft(url: url, sourceID: b)], placement: .end)
        XCTAssertEqual(items.count, 2)
        XCTAssertNotEqual(items[0].id, items[1].id)
        await store.flushForTesting()
        XCTAssertEqual(ListenStore(fileURL: file).items.map(\.sourceID), [a, b])
    }

    func testPersistedAbsurdTimesAreSanitizedBeforeUse() async throws {
        let file = temporaryDirectory().appending(path: "library.json")
        let store = ListenStore(fileURL: file)
        let items = store.add([draft("invalid"), draft("valid")], placement: .end)
        await store.flushForTesting()
        var body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var rows = try XCTUnwrap(body["items"] as? [[String: Any]])
        rows[0]["duration"] = 1e100
        rows[0]["position"] = -1e100
        rows[1]["duration"] = 120
        rows[1]["position"] = 20
        body["items"] = rows
        try JSONSerialization.data(withJSONObject: body).write(to: file)
        try JSONSerialization.data(withJSONObject: ["version": 1, "positions": [items[0].id.uuidString: 1e100]])
            .write(to: ListenStore.positionsURL(for: file))
        let reopened = ListenStore(fileURL: file)
        XCTAssertNil(reopened.items[0].duration)
        XCTAssertEqual(reopened.items[0].position, 0)
        XCTAssertEqual(reopened.items[1].duration, 120)
        XCTAssertEqual(reopened.items[1].position, 20)
    }

    func testPositionLibraryAndLaterPositionWritesKeepFIFOOrder() async throws {
        let file = temporaryDirectory().appending(path: "library.json")
        let queue = DispatchQueue(label: "ListenStoreTests.blockedPersistence")
        let release = DispatchSemaphore(value: 0)
        let entered = expectation(description: "persistence queue blocked")
        queue.async { entered.fulfill(); _ = release.wait(timeout: .now() + 5) }
        await fulfillment(of: [entered], timeout: 1)
        defer { release.signal() }
        let store = ListenStore(fileURL: file, persistenceQueue: queue)
        let item = store.add([draft("a")], placement: .end)[0]
        store.setPosition(10, for: item.id)
        try store.setStatus([item.id], .inProgress)
        store.setPosition(20, for: item.id)
        XCTAssertEqual(store.item(item.id)?.position, 20, "memory updates while disk is blocked")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        release.signal()
        await store.flushForTesting()
        XCTAssertEqual(ListenStore(fileURL: file).item(item.id)?.position, 20)
        try store.setStatus([item.id], .played)
        await store.flushForTesting()
        XCTAssertEqual(ListenStore(fileURL: file).item(item.id)?.position, 0, "an older delta cannot resurrect a played position")
    }

    func testLinkedMountScopesServerPathsWithoutChangingDirectOwnerResolution() throws {
        let id = UUID()
        let mount = URL(string: "http://localhost:43301/chat/")!
        let linked = ListenServer(base: mount, sourceID: id, scopedToMount: true)
        func resolved(_ path: String, _ server: ListenServer = linked) throws -> String {
            try ListenServer.resolve(path, server: server).absoluteString
        }
        XCTAssertEqual(try resolved("/media/a.mp3"), "http://localhost:43301/chat/media/a.mp3")
        XCTAssertEqual(try resolved("/media/a.mp3?sig=1"), "http://localhost:43301/chat/media/a.mp3?sig=1")
        XCTAssertEqual(try resolved("/hub/node/n1/media/a.mp3"), "http://localhost:43301/chat/hub/node/n1/media/a.mp3")
        // Already-prefixed paths are not prefixed twice; a longer sibling name is not a prefix match.
        XCTAssertEqual(try resolved("/chat/media/a.mp3"), "http://localhost:43301/chat/media/a.mp3")
        XCTAssertEqual(try resolved("/chat"), "http://localhost:43301/chat")
        XCTAssertEqual(try resolved("/chatty/a.mp3"), "http://localhost:43301/chat/chatty/a.mp3")
        for escape in ["/media/../../x", "/chat/../x", "/%2e%2e/x", "/media/a%2fb", "/media\\a", "//evil.example/a.mp3"] {
            XCTAssertThrowsError(try resolved(escape), escape)
        }
        XCTAssertEqual(try resolved("/media/a.mp3", ListenServer(base: URL(string: "http://localhost:43302/")!,
                                                                  sourceID: id, scopedToMount: true)),
                       "http://localhost:43302/media/a.mp3", "a root mount is unchanged")
        XCTAssertEqual(try resolved("http://feeds.example/ep.mp3"), "http://feeds.example/ep.mp3",
                       "direct URLs never gain a mount or a source")
        // The direct owner (and the saved-server fallback) keep origin-relative resolution.
        let direct = ListenServer(base: mount, sourceID: id)
        XCTAssertEqual(try resolved("/media/a.mp3", direct), "http://localhost:43301/media/a.mp3")
        XCTAssertEqual(try resolved("/chat/media/a.mp3", direct), "http://localhost:43301/chat/media/a.mp3")
        XCTAssertEqual(try resolved("/media/a.mp3", testServer), "https://hub.example/media/a.mp3")
    }

    func testURLPolicy() throws {
        XCTAssertEqual(try ListenServer.resolve("/media/abc.mp3", server: testServer).absoluteString,
                       "https://hub.example/media/abc.mp3")
        XCTAssertEqual(try ListenServer.resolve("/hub/node/n1/media/abc.mp3", server: testServer).absoluteString,
                       "https://hub.example/hub/node/n1/media/abc.mp3")
        XCTAssertEqual(try ListenServer.resolve("http://feeds.example/ep.mp3", server: testServer).scheme, "http")
        XCTAssertThrowsError(try ListenServer.resolve("term-llm-media://0123", server: testServer))
        XCTAssertThrowsError(try ListenServer.resolve("file:///etc/passwd", server: testServer))
        XCTAssertThrowsError(try ListenServer.resolve("https://user:pw@x.example/a.mp3", server: testServer))
        XCTAssertThrowsError(try ListenServer.resolve("/media/a.mp3", server: nil))
        XCTAssertTrue(testServer.isSameOrigin(URL(string: "https://hub.example:443/media/a.mp3")!))
        XCTAssertFalse(testServer.isSameOrigin(URL(string: "http://hub.example/media/a.mp3")!))
        XCTAssertFalse(testServer.isSameOrigin(URL(string: "https://evil.hub.example/a.mp3")!))
    }

    func testCookieMatching() throws {
        func cookie(_ domain: String, path: String = "/") -> HTTPCookie {
            HTTPCookie(properties: [.domain: domain, .path: path, .name: "session-\(domain)\(path)", .value: "v",
                                    .secure: "TRUE"])!
        }
        let all = [cookie("hub.example"), cookie(".example"), cookie("other.example"),
                   cookie("hub.example", path: "/admin")]
        let matched = WebKitCookieJar.matching(all, url: URL(string: "https://hub.example/ui/media/a.mp3")!)
        XCTAssertEqual(Set(matched.map(\.name)), ["session-hub.example/", "session-.example/"])
        let insecure = WebKitCookieJar.matching(all, url: URL(string: "http://hub.example/a.mp3")!)
        XCTAssertTrue(insecure.isEmpty, "secure cookies never go over http")
    }
}

/// Kept separate from the store suite so these deterministic scheduling tests
/// need neither AVPlayer nor a running audio session.
@MainActor
final class ListenBufferCallbackCoalescerTests: XCTestCase {
    func testConcurrentBurstSchedulesOnlyOneMainQueueCallback() {
        let scheduler = BufferCallbackTestScheduler()
        var deliveries = 0
        let callbacks = ListenBufferCallbackCoalescer(schedule: scheduler.schedule) { deliveries += 1 }

        DispatchQueue.concurrentPerform(iterations: 10_000) { _ in callbacks.request() }

        XCTAssertEqual(scheduler.scheduledDelays, [0.25])
        XCTAssertEqual(scheduler.pendingCount, 1)
        XCTAssertEqual(deliveries, 0, "KVO threads must not deliver inline")
        scheduler.runNext()
        XCTAssertEqual(deliveries, 1)
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testDeliveryReadsLatestStateAndEachWindowRemainsBounded() {
        let scheduler = BufferCallbackTestScheduler()
        let latest = BufferCallbackTestValue()
        var delivered: [Int] = []
        let callbacks = ListenBufferCallbackCoalescer(schedule: scheduler.schedule) { delivered.append(latest.value) }

        for value in 1...500 {
            latest.value = value
            callbacks.request()
        }
        // Changes after the last KVO notification are visible too: delivery
        // samples current engine state, never an old captured KVO snapshot.
        latest.value = 501
        scheduler.runNext()
        XCTAssertEqual(delivered, [501])

        for value in 502...1_000 {
            latest.value = value
            callbacks.request()
        }
        XCTAssertEqual(scheduler.pendingCount, 1)
        XCTAssertEqual(scheduler.scheduledDelays, [0.25, 0.25], "even a new burst must wait another update interval")
        scheduler.runNext()
        XCTAssertEqual(delivered, [501, 1_000])
    }

    func testStopCancelsPendingDeliveryAndRejectsLateObserverCallbacks() {
        let scheduler = BufferCallbackTestScheduler()
        var deliveries = 0
        let callbacks = ListenBufferCallbackCoalescer(schedule: scheduler.schedule) { deliveries += 1 }
        callbacks.request()
        callbacks.invalidate()
        callbacks.invalidate() // Teardown is idempotent.

        DispatchQueue.concurrentPerform(iterations: 1_000) { _ in callbacks.request() }
        XCTAssertEqual(scheduler.scheduledDelays.count, 1, "an invalidated observer cannot schedule again")
        scheduler.runNext() // Simulate a canceled callback still queued on main.
        XCTAssertEqual(deliveries, 0)
    }

    func testReplacementCannotDeliverOldItemOrSuppressNewItem() {
        let scheduler = BufferCallbackTestScheduler()
        var delivered: [String] = []
        let oldItem = ListenBufferCallbackCoalescer(schedule: scheduler.schedule) { delivered.append("old") }
        oldItem.request()
        oldItem.invalidate()

        let newItem = ListenBufferCallbackCoalescer(schedule: scheduler.schedule) { delivered.append("new") }
        newItem.request()
        oldItem.request() // A KVO observer already in flight during replacement.
        XCTAssertEqual(scheduler.scheduledDelays.count, 2)
        scheduler.runNext()
        XCTAssertTrue(delivered.isEmpty)
        scheduler.runNext()
        XCTAssertEqual(delivered, ["new"])

        newItem.request()
        scheduler.runNext()
        XCTAssertEqual(delivered, ["new", "new"], "the new lifetime remains usable")
    }
}

@MainActor
private final class BufferCallbackTestValue {
    var value = 0
}

private final class BufferCallbackTestScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var work: [DispatchWorkItem] = []
    private var delays: [TimeInterval] = []

    var scheduledDelays: [TimeInterval] { lock.withLock { delays } }
    var pendingCount: Int { lock.withLock { work.count } }

    func schedule(after delay: TimeInterval, work item: DispatchWorkItem) {
        lock.withLock {
            delays.append(delay)
            work.append(item)
        }
    }

    @MainActor
    func runNext() {
        let item = lock.withLock { work.removeFirst() }
        item.perform()
    }
}
