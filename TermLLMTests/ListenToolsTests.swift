import XCTest
@testable import TermLLM

@MainActor
final class ListenToolsTests: XCTestCase {
    private func call(_ listen: Listen, _ name: String, _ arguments: [String: JSONValue] = [:]) async throws -> JSONValue {
        let tool = try XCTUnwrap(listen.tools.first { $0.name == name }, "missing tool \(name)")
        let result = try await tool.call(arguments)
        XCTAssertFalse(result.isError)
        return try JSONValue.decode(Data(result.text.utf8))
    }

    private func failure(_ listen: Listen, _ name: String, _ arguments: [String: JSONValue]) async -> String? {
        do {
            _ = try await listen.tools.first { $0.name == name }!.call(arguments)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func testToolNamesAndSchemas() {
        let listen = makeListen()
        XCTAssertEqual(listen.tools.map(\.name),
                       ["media_add", "media_list", "media_play", "media_control", "media_now_playing", "media_manage"])
        for tool in listen.tools {
            XCTAssertEqual(tool.inputSchema["type"], "object", tool.name)
            XCTAssertEqual(tool.inputSchema["additionalProperties"], false, tool.name)
        }
        XCTAssertNoThrow(DeviceToolRegistry(tools: BuiltInDeviceTools.standard + listen.tools))
    }

    func testAddWithMetadataAndPlayNow() async throws {
        let engine = FakeListenEngine()
        let listen = makeListen(engine: engine)
        let result = try await call(listen, "media_add", [
            "items": [
                ["url": "/media/0123abcd.mp3", "title": "Daily briefing", "artist": "term-llm · af_sky", "kind": "generated",
                 "duration_seconds": 312],
                ["url": "https://feeds.example/ep42.mp3", "title": "Episode 42", "artist": "Some Show",
                 "artwork_url": "https://feeds.example/art.jpg", "published_at": "2026-10-01"],
            ],
            "position": "now",
            "download": "never",
        ])
        XCTAssertEqual(result["added"].map { if case .array(let a) = $0 { return a.count } else { return 0 } }, 2)
        XCTAssertEqual(result["now_playing"]?["state"], "playing")
        XCTAssertEqual(result["now_playing"]?["item"]?["title"], "Daily briefing")
        XCTAssertEqual(result["now_playing"]?["next"]?["title"], "Episode 42")
        XCTAssertEqual(engine.loads.first?.source.url.absoluteString, "https://hub.example/media/0123abcd.mp3")
        let episode = try XCTUnwrap(listen.store.upNext.last)
        XCTAssertEqual(episode.artist, "Some Show")
        XCTAssertEqual(episode.kind, .audio)
        XCTAssertNotNil(episode.publishedAt)
        XCTAssertEqual(episode.artworkURL?.host(), "feeds.example")
    }

    func testAddAcceptsOneItemAtTheTopLevel() async throws {
        let listen = makeListen()
        let result = try await call(listen, "media_add", ["url": "https://x.example/clip.mp4", "download": "never"])
        XCTAssertEqual(result["now_playing"]?["state"], "idle", "end doesn't start playback")
        XCTAssertEqual(listen.store.upNext.first?.title, "clip")
        XCTAssertEqual(listen.store.upNext.first?.kind, .video)
    }

    func testAddRejectsBadURLs() async {
        let listen = makeListen()
        let missing = await failure(listen, "media_add", ["title": "x"])
        XCTAssertEqual(missing?.contains("url is required"), true)
        let reference = await failure(listen, "media_add", ["url": "term-llm-media://0123456789abcdef0123456789abcdef"])
        XCTAssertEqual(reference?.contains("/media/"), true)
        let scheme = await failure(listen, "media_add", ["items": [["url": "ftp://x.example/a.mp3"]]])
        XCTAssertNotNil(scheme)
        let kind = await failure(listen, "media_add", ["url": "https://x.example/a.mp3", "kind": "podcastz"])
        XCTAssertEqual(kind?.contains("kind must be one of"), true)
        XCTAssertTrue(listen.store.items.isEmpty)
    }

    func testListPlayControlAndNowPlaying() async throws {
        let engine = FakeListenEngine()
        let listen = makeListen(engine: engine)
        _ = try await call(listen, "media_add", ["items": [["url": "https://x.example/a.mp3", "title": "A"],
                                                          ["url": "https://x.example/b.mp3", "title": "B"]],
                                                "download": "never"])
        let list = try await call(listen, "media_list")
        XCTAssertEqual(list["total"], 2)

        let played = try await call(listen, "media_play", ["item": "b"])
        XCTAssertEqual(played["item"]?["title"], "B")

        engine.duration = 100
        engine.currentTime = 10
        engine.send(.tick)
        let skipped = try await call(listen, "media_control", ["action": "skip", "seconds": 30])
        XCTAssertEqual(skipped["position_s"], 40)
        XCTAssertEqual(skipped["remaining_s"], 60)

        let rate = try await call(listen, "media_control", ["action": "rate", "rate": "1.5"])
        XCTAssertEqual(rate["rate"], .double(1.5))

        let paused = try await call(listen, "media_control", ["action": "pause"])
        XCTAssertEqual(paused["state"], "paused")

        let sleep = try await call(listen, "media_control", ["action": "sleep_at_end"])
        XCTAssertEqual(sleep["sleep_at_end"], true)

        let hidden = try await call(listen, "media_control", ["action": "hide_player"])
        XCTAssertEqual(hidden["player_visible"], false)

        let unknown = await failure(listen, "media_control", ["action": "explode"])
        XCTAssertEqual(unknown?.contains("Unknown action"), true)
    }

    func testManage() async throws {
        let engine = FakeListenEngine()
        let listen = makeListen(engine: engine)
        _ = try await call(listen, "media_add", ["items": [["url": "https://x.example/a.mp3", "title": "A"],
                                                          ["url": "https://x.example/b.mp3", "title": "B"],
                                                          ["url": "https://x.example/c.mp3", "title": "C"]],
                                                "position": "now", "download": "never"])
        _ = try await call(listen, "media_manage", ["action": "move", "items": ["C"], "to_index": 0])
        XCTAssertEqual(listen.store.upNext.map(\.title), ["C", "A", "B"])

        _ = try await call(listen, "media_manage", ["action": "mark_played", "items": ["A"]])
        XCTAssertEqual(listen.player.current?.title, "C", "marking the playing item played moves on")
        XCTAssertEqual(listen.store.history.map(\.title), ["A"])

        _ = try await call(listen, "media_manage", ["action": "archive", "items": ["B"]])
        let cleared = try await call(listen, "media_manage", ["action": "clear_history"])
        XCTAssertEqual(cleared["removed"], 2)

        _ = try await call(listen, "media_manage", ["action": "remove", "items": ["C"]])
        XCTAssertTrue(listen.store.items.isEmpty)
        XCTAssertNil(listen.player.currentID)

        let missing = await failure(listen, "media_manage", ["action": "remove", "items": ["nope"]])
        XCTAssertEqual(missing?.contains("media_list"), true)
    }

    func testPlayWithNothingQueuedFails() async {
        let listen = makeListen()
        let message = await failure(listen, "media_play", [:])
        XCTAssertEqual(message, ListenError.nothingToPlay.localizedDescription)
    }
}
