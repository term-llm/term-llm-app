import XCTest
@testable import TermLLM

@MainActor
final class MusicToolsTests: XCTestCase {
    private var library: MusicLibrary!
    private var catalog: FakeCatalog!
    private var engine: FakeEngine!

    override func setUp() async throws {
        catalog = FakeCatalog(tracks: [track("100", "Teardrop", artist: "Massive Attack"),
                                       track("200", "Glory Box", artist: "Portishead"),
                                       track("300", "Roads", artist: "Portishead")])
        engine = FakeEngine()
        library = MusicLibrary(catalog: catalog, engine: engine,
                               store: PlaylistStore(fileURL: temporaryPlaylistFile()), defaults: isolatedDefaults(),
                               startCheck: MusicPlayer.StartCheck(polls: 5, interval: .milliseconds(1)))
    }

    /// Calls a tool the way the WebMCP bridge does and decodes its JSON.
    @discardableResult
    private func call(_ name: String, _ arguments: [String: JSONValue] = [:]) async throws -> JSONValue {
        let tool = try XCTUnwrap(library.tools.first { $0.name == name }, "no tool \(name)")
        let result = try await tool.call(arguments)
        XCTAssertFalse(result.isError)
        return try JSONValue.decode(Data(result.text.utf8))
    }

    private func callFailing(_ name: String, _ arguments: [String: JSONValue]) async -> String {
        do {
            try await call(name, arguments)
            XCTFail("\(name) should fail")
            return ""
        } catch {
            return error.localizedDescription
        }
    }

    private func entryIDs(_ playlist: JSONValue?) -> [JSONValue] {
        guard case .array(let entries)? = playlist?["entries"] else { return [] }
        return entries.compactMap { $0["entry_id"] }
    }

    func testToolCatalogue() {
        let tools = library.tools
        XCTAssertEqual(tools.map(\.name), [
            "music_search", "playlist_list", "playlist_get", "playlist_create", "playlist_add_songs",
            "playlist_remove_songs", "playlist_reorder", "playlist_rename", "playlist_delete",
            "music_play", "music_now_playing", "music_control",
        ])
        XCTAssertEqual(tools.filter(\.readOnly).map(\.name),
                       ["music_search", "playlist_list", "playlist_get", "music_now_playing"])
        XCTAssertEqual(tools.filter(\.consequential).map(\.name), ["playlist_delete"])
        XCTAssertTrue(tools.allSatisfy { $0.inputSchema["type"] == "object" })
        XCTAssertEqual(tools.first?.inputSchema["required"], ["query"])
        // Unique names so the registry accepts them alongside the built-ins.
        _ = DeviceToolRegistry(tools: BuiltInDeviceTools.standard + tools)
    }

    func testSearch() async throws {
        catalog.searchResults = [track("100", "Teardrop", artist: "Massive Attack")]
        let result = try await call("music_search", ["query": "teardrop", "limit": 3])
        XCTAssertEqual(result, ["songs": [["id": "100", "title": "Teardrop", "artist": "Massive Attack", "album": "Album"]]])
        XCTAssertEqual(catalog.searches, ["teardrop"])
        let missing = await callFailing("music_search", [:])
        XCTAssertEqual(missing, "query is required: the song, artist, or album to look for.")
    }

    func testCreatingAndEditingPlaylistsByName() async throws {
        let created = try await call("playlist_create", ["name": "Trip-Hop", "song_ids": ["100", "200"]])
        XCTAssertEqual(created["name"], "Trip-Hop")
        XCTAssertEqual(created["songs"], 2)
        XCTAssertEqual(library.store.playlists.first?.tracks.map(\.title), ["Teardrop", "Glory Box"],
                       "metadata comes from the catalog")

        let added = try await call("playlist_add_songs", ["playlist": "trip-hop", "song_ids": ["300"], "position": 0])
        XCTAssertEqual(library.store.playlists.first?.tracks.map(\.id), ["300", "100", "200"])

        let ids = entryIDs(added)
        try await call("playlist_reorder", ["playlist": "Trip-Hop", "entry_ids": .array([ids[2], ids[1], ids[0]])])
        XCTAssertEqual(library.store.playlists.first?.tracks.map(\.id), ["200", "100", "300"])

        let removed = try await call("playlist_remove_songs", ["playlist": "Trip-Hop", "entry_ids": .array([ids[0]])])
        XCTAssertEqual(removed["songs"], 2)

        let fetched = try await call("playlist_get", ["playlist": "TRIP-HOP"])
        XCTAssertEqual(entryIDs(fetched).count, 2)

        let renamed = try await call("playlist_rename", ["playlist": "Trip-Hop", "name": "Bristol"])
        XCTAssertEqual(renamed["name"], "Bristol")

        let listed = try await call("playlist_list")
        guard case .array(let playlists)? = listed["playlists"] else { return XCTFail("no playlists") }
        XCTAssertEqual(playlists.map { $0["name"] }, ["Bristol"])

        let deleted = try await call("playlist_delete", ["playlist": "bristol"])
        XCTAssertEqual(deleted, ["deleted": "Bristol"])
        XCTAssertTrue(library.store.playlists.isEmpty)
    }

    func testModelReadableErrors() async throws {
        let unknownSong = await callFailing("playlist_create", ["name": "X", "song_ids": ["100", "999"]])
        XCTAssertEqual(unknownSong, #"Unknown Apple Music song ids: "999". Use music_search to find song ids."#)
        XCTAssertTrue(library.store.playlists.isEmpty, "nothing is created when a song is unknown")

        let noPlaylists = await callFailing("playlist_get", ["playlist": "Nope"])
        XCTAssertEqual(noPlaylists, #"No playlist named or identified by "Nope". There are no playlists yet; create one with playlist_create."#)

        try await call("playlist_create", ["name": "Mix", "song_ids": ["100", "200"]])
        try await call("playlist_create", ["name": "Chill"])
        let unknownPlaylist = await callFailing("music_play", ["playlist": "Nope"])
        XCTAssertEqual(unknownPlaylist, #"No playlist named or identified by "Nope". Playlists: "Chill", "Mix"."#,
                       "lists what exists so the agent can pick")

        let missing = await callFailing("playlist_get", [:])
        XCTAssertEqual(missing, "playlist is required: a playlist id or name (see playlist_list).")
        let blank = await callFailing("playlist_add_songs", ["playlist": "Mix", "song_ids": []])
        XCTAssertEqual(blank, "song_ids is required: song ids from music_search.")

        let badEntries = await callFailing("playlist_remove_songs", ["playlist": "Mix", "entry_ids": ["nope", "also-no"]])
        XCTAssertEqual(badEntries, #""nope", "also-no" in entry_ids aren't ids. Use entry ids from playlist_get."#)
        let stranger = UUID().uuidString
        let unknownEntry = await callFailing("playlist_remove_songs", ["playlist": "Mix", "entry_ids": .array([.string(stranger)])])
        XCTAssertEqual(unknownEntry, #""\#(stranger)" isn't an entry of "Mix". Use playlist_get for its entry ids."#)

        let partialOrder = await callFailing("playlist_reorder", ["playlist": "Mix", "entry_ids": .array([.string(stranger)])])
        XCTAssertEqual(partialOrder, #"entry_ids must list each of the 2 entries in "Mix" exactly once. Use playlist_get for the current entry ids."#)

        let wrongType = await callFailing("music_search", ["query": "x", "limit": "lots"])
        XCTAssertEqual(wrongType, "limit must be a whole number.")
        let wrongList = await callFailing("playlist_add_songs", ["playlist": "Mix", "song_ids": [["id": "100"]]])
        XCTAssertEqual(wrongList, "song_ids must be a list of strings.")
    }

    func testAcceptsObviousIntent() async throws {
        catalog.searchResults = [track("100")]
        // Numbers and booleans as strings, one id instead of a list, blank optionals.
        try await call("music_search", ["query": "x", "limit": "3", "unused": ""])
        let created = try await call("playlist_create", ["name": "Loose", "song_ids": "100, 200"])
        XCTAssertEqual(created["songs"], 2)
        try await call("playlist_add_songs", ["playlist": "Loose", "song_ids": "300", "position": ""])
        XCTAssertEqual(library.store.playlists.first?.tracks.map(\.id), ["100", "200", "300"])
        let playing = try await call("music_play", ["playlist": "Loose", "song_ids": "", "shuffle": "false", "start_entry_id": .null])
        XCTAssertEqual(playing["status"], "playing")
    }

    func testPlayingAndControlling() async throws {
        try await call("playlist_create", ["name": "Evening", "song_ids": ["100", "200", "300"]])
        let playing = try await call("music_play", ["playlist": "evening", "shuffle": true])
        XCTAssertEqual(playing["status"], "playing")
        XCTAssertEqual(playing["playlist"], "Evening")
        XCTAssertEqual(playing["queued"], 3)
        XCTAssertEqual(playing["shuffle"], true)
        XCTAssertEqual(playing["song"]?["title"], "Teardrop")
        XCTAssertEqual(engine.loads.last?.shuffle, true)

        let paused = try await call("music_control", ["action": "pause"])
        XCTAssertEqual(paused["status"], "paused")
        let next = try await call("music_control", ["action": "next"])
        XCTAssertEqual(next["song"]?["id"], "200")
        let now = try await call("music_now_playing")
        XCTAssertEqual(now["song"]?["id"], "200")

        let songs = try await call("music_play", ["song_ids": ["300"]])
        XCTAssertEqual(songs["song"]?["id"], "300")
        XCTAssertNil(songs["playlist"], "ad-hoc songs aren't attributed to a playlist")

        let unknownAction = await callFailing("music_control", ["action": "louder"])
        XCTAssertEqual(unknownAction, #"Unknown action "louder". Use one of pause, resume, next, previous, shuffle_on, shuffle_off."#)
        let aliased = try await call("music_control", ["action": "Skip"])
        XCTAssertEqual(aliased["song"]?["id"], "300")
    }

    func testPlayingFromAnEntry() async throws {
        let created = try await call("playlist_create", ["name": "Start Here", "song_ids": ["100", "200"]])
        let second = entryIDs(created)[1]
        let playing = try await call("music_play", ["playlist": "Start Here", "start_entry_id": second])
        XCTAssertEqual(playing["song"]?["id"], "200")
        let stranger = UUID().uuidString
        let badStart = await callFailing("music_play", ["playlist": "Start Here", "start_entry_id": .string(stranger)])
        XCTAssertEqual(badStart, #""\#(stranger)" isn't an entry of "Start Here". Use playlist_get for its entry ids."#)
    }

    func testBlankStartEntryPlaysFromTheFirstSong() async throws {
        try await call("playlist_create", ["name": "Top", "song_ids": ["100", "200"]])
        for blank: JSONValue in ["", "   ", .null] {
            let playing = try await call("music_play", ["playlist": "Top", "start_entry_id": blank])
            XCTAssertEqual(playing["status"], "playing")
            XCTAssertEqual(playing["song"]?["id"], "100")
            XCTAssertEqual(engine.loads.last?.index, 0)
        }
    }

    func testPlayReportsPlayingOnlyOnceTheSystemPlayerIs() async throws {
        try await call("playlist_create", ["name": "Slow Start", "song_ids": ["100"]])
        engine.startLag = 3 // the system player reports "playing" a moment late
        let playing = try await call("music_play", ["playlist": "Slow Start"])
        XCTAssertEqual(playing["status"], "playing")
        XCTAssertEqual(engine.playCount, 1)
    }

    func testPlayThatNeverStartsRetriesThenSaysWhatToDo() async throws {
        try await call("playlist_create", ["name": "Stuck", "song_ids": ["100"]])
        engine.neverStarts = true
        let failure = await callFailing("music_play", ["playlist": "Stuck"])
        XCTAssertEqual(failure, MusicError.didNotStart.localizedDescription)
        XCTAssertEqual(engine.playCount, 2, "play() is retried once")

        engine.neverStarts = false
        let resumed = try await call("music_control", ["action": "resume"])
        XCTAssertEqual(resumed["status"], "playing")
    }

    func testPlayingNeedsExactlyOneSource() async throws {
        try await call("playlist_create", ["name": "Mix", "song_ids": ["100"]])
        try await call("playlist_create", ["name": "Empty"])
        let both = await callFailing("music_play", ["playlist": "Mix", "song_ids": ["200"]])
        XCTAssertEqual(both, "Give either playlist or song_ids to music_play, not both.")
        let neither = await callFailing("music_play", ["playlist": "", "song_ids": []])
        XCTAssertEqual(neither, "music_play needs a playlist (id or name, see playlist_list) or song_ids (from music_search).")
        let empty = await callFailing("music_play", ["playlist": "Empty"])
        XCTAssertEqual(empty, #""Empty" has no songs yet. Add some with playlist_add_songs first."#)
        let resume = await callFailing("music_control", ["action": "resume"])
        XCTAssertEqual(resume, "Nothing to resume: nothing has been played yet. Start something with music_play.")
    }

    func testAgentEditsAreVisibleToTheMusicScreen() async throws {
        // The screen and the tools share one store.
        try await call("playlist_create", ["name": "Shared"])
        XCTAssertEqual(library.store.playlists.map(\.name), ["Shared"])
    }
}
