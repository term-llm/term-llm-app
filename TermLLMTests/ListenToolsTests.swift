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

    func testSourceRegistryRetainsProviderAfterFactoryReturns() async throws {
        let listen = makeListen()
        let settings = DeviceToolsSettings(defaults: isolatedDefaults(),
                                           registry: DeviceToolRegistry(tools: []), listen: listen)
        let source = HubConnection(id: UUID(), name: "Owner", kind: .hub,
                                   url: URL(string: "https://owner.example/phone/")!)
        let other = HubConnection(id: UUID(), name: "Other", kind: .directNode,
                                  url: URL(string: "https://other.example/node/")!)
        let registry = settings.registry(for: source)
        _ = settings.registry(for: other)
        XCTAssertTrue(registry === settings.registry(for: source), "uses the cached provider/registry pair")
        await settle()

        // Invoke the actual factory-returned closures after its local provider
        // has gone out of scope, not a separately retained ListenTools instance.
        let list = try XCTUnwrap(registry.tool(named: "media_list"))
        let empty = try await list.call([:])
        XCTAssertEqual(try JSONValue.decode(Data(empty.text.utf8))["total"], 0)
        let add = try XCTUnwrap(registry.tool(named: "media_add"))
        _ = try await add.call(["url": "/phone/media/owned.mp3", "download": "never"])
        let item = try XCTUnwrap(listen.store.items.first)
        XCTAssertEqual(item.url, URL(string: "https://owner.example/phone/media/owned.mp3"))
        XCTAssertEqual(item.sourceID, source.id, "must not inherit the latest registry or selected server")
        let populated = try await list.call([:])
        XCTAssertEqual(try JSONValue.decode(Data(populated.text.utf8))["total"], 1)
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

    func testPlatformCopyIncludesNestedSchemasWithoutChangingToolContract() throws {
        let listen = makeListen()
        let phone = ListenTools(listen: listen, platform: .iPhone)
        let mac = ListenTools(listen: listen, platform: .mac)
        func structure(_ value: JSONValue) -> JSONValue {
            switch value {
            case .object(let object):
                // Keep the item field named "description"; omit only schema prose.
                return .object(object.filter { $0.key != "description" || $0.value.stringValue == nil }.mapValues(structure))
            case .array(let values): return .array(values.map(structure))
            default: return value
            }
        }
        XCTAssertEqual(mac.tools.map(\.name), phone.tools.map(\.name))
        for (macTool, phoneTool) in zip(mac.tools, phone.tools) {
            XCTAssertEqual(macTool.title, phoneTool.title, macTool.name)
            XCTAssertEqual(structure(macTool.inputSchema), structure(phoneTool.inputSchema), macTool.name)
            XCTAssertEqual(macTool.readOnly, phoneTool.readOnly, macTool.name)
            XCTAssertEqual(macTool.consequential, phoneTool.consequential, macTool.name)
            let text = (macTool.description + String(decoding: macTool.inputSchema.encoded(), as: UTF8.self)).lowercased()
            for forbidden in ["iphone", "phone", "lock screen", "carplay"] {
                XCTAssertFalse(text.contains(forbidden), "\(macTool.name): \(text)")
            }
            XCTAssertTrue(macTool.description.contains("Mac"), macTool.name)
        }
        let phoneTools = Dictionary(uniqueKeysWithValues: phone.tools.map { ($0.name, $0) })
        XCTAssertEqual(phoneTools["media_add"]?.description,
                       "Add audio or video to the Listen queue on the iPhone (podcast episodes, audio term-llm generated, songs, "
                       + "sound effects, videos played for their sound). Each url must point at the media file itself (mp3, m4a, "
                       + "wav, mp4, …), not a web page: any http(s) URL, or a /media/… path on this term-llm server. Give a good "
                       + "title and artist (show, voice, or author): they appear on the lock screen. position: now starts playing "
                       + "it, next plays after the current item, end (default) adds to the bottom of Up Next. A URL already in the "
                       + "library is moved instead of duplicated.")
        XCTAssertEqual(phoneTools["media_list"]?.description,
                       "List the Listen library on the iPhone: Up Next in play order (default), history (played or archived), "
                       + "or all, with item ids, progress, and download state.")
        XCTAssertEqual(phoneTools["media_play"]?.description,
                       "Play an item from the Listen library on the iPhone, resuming where it was left. Without item, resumes "
                       + "the current item or starts Up Next.")
        XCTAssertEqual(phoneTools["media_control"]?.description,
                       "Control Listen playback on the iPhone: pause, resume, stop, seek (to seconds), skip (by seconds, "
                       + "negative goes back), next, previous, rate (speed 0.5–3), sleep (pause after minutes; 0 cancels), "
                       + "sleep_at_end (pause when this item ends), cancel_sleep, hide_player/show_player (the mini player bar).")
        XCTAssertEqual(phoneTools["media_now_playing"]?.description,
                       "What Listen is playing on the iPhone: the item, position, duration, time left, speed, state, sleep "
                       + "timer, and the next item. Use it to know what the user has heard.")
        XCTAssertEqual(phoneTools["media_manage"]?.description,
                       "Manage Listen items on the iPhone: remove, mark_played, mark_unplayed (back to Up Next), archive, "
                       + "move (to Up Next position to_index, 0 = top), clear_history (remove all played/archived), "
                       + "download (keep on the phone for offline play), cancel_download, delete_download.")
        let phoneSchema = try XCTUnwrap(phoneTools["media_add"]?.inputSchema)
        let macSchema = try XCTUnwrap(mac.tools.first { $0.name == "media_add" }?.inputSchema)
        for properties in [phoneSchema["properties"], phoneSchema["properties"]?["items"]?["items"]?["properties"]] {
            XCTAssertEqual(properties?["title"]?["description"], "Title for the lock screen and queue.")
            XCTAssertEqual(properties?["artwork_url"]?["description"], "Image URL for the lock screen.")
        }
        for properties in [macSchema["properties"], macSchema["properties"]?["items"]?["items"]?["properties"]] {
            XCTAssertEqual(properties?["title"]?["description"], "Title for Now Playing and queue.")
            XCTAssertEqual(properties?["artwork_url"]?["description"], "Image URL for Now Playing.")
        }
        let current = DeviceToolPlatform.current == .mac ? mac : phone
        XCTAssertEqual(listen.tools.map(\.description), current.tools.map(\.description))
        XCTAssertEqual(listen.tools.map(\.inputSchema), current.tools.map(\.inputSchema))
    }

    func testMacSourceRegistryHasOneMediaProviderAndRejectsNavigation() async throws {
        let listen = makeListen()
        let media = ListenTools(listen: listen, platform: .mac)
        let tools = DeviceToolsSettings.standardTools(platform: .mac, music: { [] },
            navigation: { XCTFail("Mac must not initialize navigation"); return [] }, media: { media.tools })
        let settings = DeviceToolsSettings(defaults: isolatedDefaults(), registry: DeviceToolRegistry(tools: tools), listen: listen)
        let source = HubConnection(id: UUID(), name: "Fixture", kind: .hub, url: testServer.base)
        let registry = settings.registry(for: source)
        XCTAssertEqual(registry.tools.map(\.name), ["ping", "device_info", "media_add", "media_list", "media_play",
                                                   "media_control", "media_now_playing", "media_manage"])
        XCTAssertTrue(registry === settings.registry(for: source))
        let origin = "https://hub.example"
        let rejected = await WebMCPBridge.handle(body: ["name": "location_current"], frameOrigin: origin,
            isMainFrame: true, expectedOrigin: origin, registry: registry)
        XCTAssertEqual(rejected, .failure(.init(message: "Unknown device tool: location_current")))
        let accepted = await WebMCPBridge.handle(body: ["name": "media_list"], frameOrigin: origin,
            isMainFrame: true, expectedOrigin: origin, registry: registry)
        let result = try accepted.get()
        XCTAssertEqual(try JSONValue.decode(Data(result.utf8))["total"], 0)
    }

    func testAbsurdToolTimesAndSleepMinutesReturnErrorsWithoutMutation() async throws {
        let listen = makeListen()
        for value in [1e100, -1, 0] as [Double] {
            let error = await failure(listen, "media_add", ["url": "https://example.com/audio.mp3", "duration_seconds": .double(value)])
            XCTAssertTrue(error?.contains("duration_seconds") == true)
            XCTAssertTrue(listen.store.items.isEmpty)
        }
        _ = try await call(listen, "media_add", ["url": "http://example.com/a.mp3", "position": "now", "download": "never"])
        for (name, args) in [
            ("media_play", ["start_at": JSONValue.double(1e100)]),
            ("media_control", ["action": "seek", "seconds": .double(1e100)]),
            ("media_control", ["action": "skip", "seconds": .double(-1e100)]),
            ("media_control", ["action": "sleep", "minutes": .int(Int.max)]),
            ("media_control", ["action": "sleep", "minutes": .double(1e100)]),
            ("media_control", ["action": "sleep", "minutes": -1]),
        ] {
            let error = await failure(listen, name, args)
            XCTAssertNotNil(error, "\(name) \(args)")
        }
        XCTAssertNil(listen.player.sleepAt)
        _ = try await call(listen, "media_control", ["action": "sleep", "minutes": 1440])
        XCTAssertNotNil(listen.player.sleepAt)
        _ = try await call(listen, "media_control", ["action": "sleep", "minutes": 0])
        XCTAssertNil(listen.player.sleepAt)
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
        let host = DeviceToolPlatform.current == .mac ? "in this app" : "on the iPhone"
        XCTAssertEqual(reference, "url: term-llm-media:// references can't be resolved \(host) yet. Pass the published media URL "
                       + "(a /media/… path on this server) or any direct http(s) audio/video URL.")
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
