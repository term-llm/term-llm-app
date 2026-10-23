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

    func testPersistsAndRecoversFromAnUnreadableFile() throws {
        let directory = temporaryDirectory()
        let file = directory.appending(path: "library.json")
        let store = ListenStore(fileURL: file)
        let items = store.add([draft("a"), draft("b")], placement: .end)
        store.update(items[0].id) { $0.position = 42; $0.status = .inProgress }

        let reopened = ListenStore(fileURL: file)
        XCTAssertEqual(reopened.upNext.map(\.title), ["a", "b"])
        XCTAssertEqual(reopened.item(items[0].id)?.position, 42)

        try Data("not json".utf8).write(to: file)
        let recovered = ListenStore(fileURL: file)
        XCTAssertTrue(recovered.items.isEmpty)
        XCTAssertNotNil(recovered.notice)
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

    func testSameMediaURLRetainsDistinctPersistentSourceOwners() throws {
        let directory = temporaryDirectory()
        let file = directory.appendingPathComponent("owned-media.json")
        let store = ListenStore(fileURL: file)
        let url = URL(string: "https://example.com/nested/media.mp3")!
        let a = UUID(), b = UUID()
        let items = store.add([ListenDraft(url: url, sourceID: a), ListenDraft(url: url, sourceID: b)], placement: .end)
        XCTAssertEqual(items.count, 2)
        XCTAssertNotEqual(items[0].id, items[1].id)
        XCTAssertEqual(ListenStore(fileURL: file).items.map(\.sourceID), [a, b])
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
