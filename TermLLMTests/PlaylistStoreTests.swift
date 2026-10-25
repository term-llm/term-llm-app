import XCTest
@testable import TermLLM

@MainActor
final class PlaylistStoreTests: XCTestCase {
    private var file: URL!
    private var clock = Date(timeIntervalSince1970: 1_000)

    override func setUp() async throws {
        file = temporaryPlaylistFile()
        clock = Date(timeIntervalSince1970: 1_000)
    }

    private func makeStore() -> PlaylistStore {
        PlaylistStore(fileURL: file) { [unowned self] in
            clock = clock.addingTimeInterval(1)
            return clock
        }
    }

    func testCreatesAndPersists() throws {
        let store = makeStore()
        let playlist = try store.create(name: "  Road Trip ", tracks: [track("1"), track("2")])
        XCTAssertEqual(playlist.name, "Road Trip")
        XCTAssertEqual(playlist.tracks.map(\.id), ["1", "2"])
        XCTAssertNotEqual(playlist.entries[0].id, playlist.entries[1].id)

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.playlists, [playlist])
        XCTAssertNil(reloaded.readOnlyReason)
        XCTAssertNil(reloaded.notice)
    }

    func testExplicitIdentityPersistsAndDuplicateIDsCannotOverwrite() throws {
        let store = makeStore()
        let id = UUID()
        let original = try store.create(name: "Explicit ID", tracks: [track("1")], id: id)
        XCTAssertEqual(original.id, id)
        XCTAssertEqual(makeStore().playlist(id: id), original)
        let saved = try Data(contentsOf: file)
        XCTAssertThrowsError(try store.create(name: "Different name", tracks: [track("2")], id: id)) {
            XCTAssertEqual($0 as? MusicError, .playlistIDTaken(id.uuidString))
        }
        XCTAssertEqual(store.playlists, [original])
        XCTAssertEqual(try Data(contentsOf: file), saved)
    }

    func testOrdinaryCreationNeverInfersIdentityFromSampleContents() throws {
        let store = makeStore()
        let first = try store.create(name: "First", tracks: MusicTrack.demoTracks)
        let second = try store.create(name: "Second", tracks: MusicTrack.demoTracks)
        XCTAssertNotEqual(first.id, Playlist.demoID)
        XCTAssertNotEqual(second.id, Playlist.demoID)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(makeStore().playlists.count, 2)
        let id = UUID()
        let model = Playlist(id: id, name: "Model", entries: first.entries,
                             createdAt: first.createdAt, updatedAt: first.updatedAt)
        XCTAssertEqual(model.id, id)
    }

    func testNamesAreRequiredAndUnique() throws {
        let store = makeStore()
        XCTAssertThrowsError(try store.create(name: "   ")) { XCTAssertEqual($0 as? MusicError, .nameRequired) }
        let first = try store.create(name: "Focus")
        XCTAssertThrowsError(try store.create(name: "focus")) { XCTAssertEqual($0 as? MusicError, .nameTaken("focus")) }
        let second = try store.create(name: "Chill")
        XCTAssertThrowsError(try store.rename(second.id, to: "FOCUS"))
        try store.rename(first.id, to: "Focus") // renaming to its own name is fine
        try store.rename(first.id, to: "Deep Focus")
        XCTAssertEqual(store.playlist(id: first.id)?.name, "Deep Focus")
    }

    func testResolvesByIdOrName() throws {
        let store = makeStore()
        let playlist = try store.create(name: "Morning Run")
        XCTAssertEqual(try store.resolve(playlist.id.uuidString).id, playlist.id)
        XCTAssertEqual(try store.resolve(" morning run ").id, playlist.id)
        XCTAssertThrowsError(try store.resolve("Evening")) {
            XCTAssertEqual($0 as? MusicError, .playlistNotFound("Evening", available: ["Morning Run"]))
            XCTAssertEqual($0.localizedDescription,
                           #"No playlist named or identified by "Evening". Playlists: "Morning Run"."#)
        }
        XCTAssertEqual(MusicError.playlistNotFound("X", available: []).localizedDescription,
                       #"No playlist named or identified by "X". There are no playlists yet; create one with playlist_create."#)
    }

    func testEditsEntries() throws {
        let store = makeStore()
        let playlist = try store.create(name: "Mix", tracks: [track("a"), track("b")])
        let added = try store.add([track("x"), track("y")], to: playlist.id, at: 1)
        XCTAssertEqual(store.playlist(id: playlist.id)?.tracks.map(\.id), ["a", "x", "y", "b"])

        try store.remove(entries: [added[0].id], from: playlist.id)
        XCTAssertEqual(store.playlist(id: playlist.id)?.tracks.map(\.id), ["a", "y", "b"])
        let stranger = UUID()
        XCTAssertThrowsError(try store.remove(entries: [stranger, added[1].id], from: playlist.id)) {
            XCTAssertEqual($0 as? MusicError, .unknownEntries([stranger.uuidString], playlist: "Mix"))
        }
        XCTAssertEqual(store.playlist(id: playlist.id)?.entries.count, 3, "nothing removed when any id is unknown")

        try store.move(in: playlist.id, from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(store.playlist(id: playlist.id)?.tracks.map(\.id), ["b", "a", "y"])

        let entries = try XCTUnwrap(store.playlist(id: playlist.id)).entries
        try store.reorder(playlist.id, entryIDs: entries.reversed().map(\.id))
        XCTAssertEqual(store.playlist(id: playlist.id)?.tracks.map(\.id), ["y", "a", "b"])
        for invalid in [[entries[0].id], entries.map(\.id) + [entries[0].id], [entries[0].id, entries[1].id, UUID()]] {
            XCTAssertThrowsError(try store.reorder(playlist.id, entryIDs: invalid)) {
                XCTAssertEqual($0 as? MusicError, .invalidOrder(playlist: "Mix", expected: 3))
            }
        }
        XCTAssertEqual(makeStore().playlist(id: playlist.id)?.tracks.map(\.id), ["y", "a", "b"], "edits persist")
    }

    func testAllowsDuplicateSongsAsSeparateEntries() throws {
        let store = makeStore()
        let playlist = try store.create(name: "Repeat", tracks: [track("1")])
        try store.add([track("1")], to: playlist.id)
        let entries = try XCTUnwrap(store.playlist(id: playlist.id)).entries
        XCTAssertEqual(entries.map(\.track.id), ["1", "1"])
        try store.remove(entries: [entries[1].id], from: playlist.id)
        XCTAssertEqual(store.playlist(id: playlist.id)?.entries, [entries[0]])
    }

    func testMostRecentlyChangedFirst() throws {
        let store = makeStore()
        let older = try store.create(name: "Older")
        let newer = try store.create(name: "Newer")
        XCTAssertEqual(store.playlists.map(\.id), [newer.id, older.id])
        try store.add([track("1")], to: older.id)
        XCTAssertEqual(store.playlists.map(\.id), [older.id, newer.id])
        XCTAssertGreaterThan(store.playlists[0].updatedAt, store.playlists[0].createdAt)
    }

    func testDeletes() throws {
        let store = makeStore()
        let playlist = try store.create(name: "Gone")
        try store.delete(playlist.id)
        XCTAssertTrue(store.playlists.isEmpty)
        XCTAssertTrue(makeStore().playlists.isEmpty)
        XCTAssertThrowsError(try store.delete(playlist.id))
    }

}
