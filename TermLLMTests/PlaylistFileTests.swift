import XCTest
@testable import TermLLM

/// Loading the playlists file must never silently lose data.
@MainActor
final class PlaylistFileTests: XCTestCase {
    private var url: URL!
    private let fixedNow = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21 …

    override func setUp() async throws {
        url = temporaryPlaylistFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    private func writeRaw(_ text: String) throws {
        try Data(text.utf8).write(to: url)
    }

    private func store() -> PlaylistStore {
        PlaylistStore(fileURL: url) { [fixedNow] in fixedNow }
    }

    private func siblings() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path(percentEncoded: false)).sorted()
    }

    private func playlistJSON(id: String = UUID().uuidString, name: String, entries: [String] = [],
                              updated: String = "2026-09-20T10:00:00Z") -> String {
        #"{"id":"\#(id)","name":"\#(name)","createdAt":"2026-09-01T10:00:00Z","updatedAt":"\#(updated)","entries":[\#(entries.joined(separator: ","))]}"#
    }

    private func entryJSON(id: String = UUID().uuidString, song: String) -> String {
        #"{"id":"\#(id)","addedAt":"2026-09-01T10:00:00Z","track":{"id":"\#(song)","title":"Song \#(song)"}}"#
    }

    func testMissingFileIsAnEmptyLibrary() {
        let store = store()
        XCTAssertTrue(store.playlists.isEmpty)
        XCTAssertNil(store.notice)
        XCTAssertNil(store.readOnlyReason)
    }

    func testUnreadableFileIsSetAsideAndAFreshListStarts() throws {
        try writeRaw("{ definitely not json")
        let store = store()

        XCTAssertTrue(store.playlists.isEmpty)
        XCTAssertNil(store.readOnlyReason, "a fresh list can be used immediately")
        let backup = "playlists-unreadable-20260921-141320.json"
        XCTAssertEqual(store.notice, "Saved playlists couldn't be read. The file was kept as \(backup) and a new list started.")
        XCTAssertEqual(try siblings(), [backup])
        let kept = url.deletingLastPathComponent().appending(path: backup)
        XCTAssertEqual(try String(contentsOf: kept, encoding: .utf8), "{ definitely not json")

        try store.create(name: "Fresh")
        XCTAssertEqual(try siblings(), [backup, "playlists.json"])
        store.dismissNotice()
        XCTAssertNil(store.notice)
    }

    func testKeepsEverythingReadableAndBacksUpTheOriginal() throws {
        let original = #"""
        {"version": 1, "playlists": [
          \#(playlistJSON(name: "Good", entries: [entryJSON(song: "1"), #"{"id": "broken"}"#, entryJSON(song: "2")], updated: "2026-09-20T10:00:00Z")),
          {"name": "No id or dates"},
          \#(playlistJSON(name: "Also Good", updated: "2026-09-21T10:00:00Z"))
        ]}
        """#
        try writeRaw(original)
        let store = store()

        XCTAssertEqual(store.playlists.map(\.name), ["Also Good", "Good"], "newest first")
        XCTAssertEqual(store.playlist(id: store.playlists[1].id)?.tracks.map(\.id), ["1", "2"])
        XCTAssertNil(store.readOnlyReason)
        let backup = "playlists-unreadable-20260921-141320.json"
        XCTAssertEqual(store.notice, "1 playlist and 1 song couldn't be read and were left out. The original file was kept as \(backup).")
        XCTAssertEqual(try String(contentsOf: url.deletingLastPathComponent().appending(path: backup), encoding: .utf8), original)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original, "untouched until the next change")

        try store.rename(store.playlists[0].id, to: "Renamed")
        let reloaded = self.store()
        XCTAssertEqual(reloaded.playlists.map(\.name), ["Renamed", "Good"])
        XCTAssertNil(reloaded.notice, "the rewritten file is clean")
    }

    func testRepairsDuplicatesWithoutLosingSongs() throws {
        let sharedID = UUID().uuidString
        let entryID = UUID().uuidString
        try writeRaw(#"""
        {"version": 1, "playlists": [
          \#(playlistJSON(id: sharedID, name: "Mix", entries: [entryJSON(id: entryID, song: "1"), entryJSON(id: entryID, song: "2")], updated: "2026-09-21T10:00:00Z")),
          \#(playlistJSON(name: "mix", updated: "2026-09-20T10:00:00Z")),
          \#(playlistJSON(name: "   ", updated: "2026-09-19T10:00:00Z")),
          \#(playlistJSON(id: sharedID, name: "Duplicate id", updated: "2026-09-18T10:00:00Z"))
        ]}
        """#)
        let store = store()

        XCTAssertEqual(store.playlists.map(\.name), ["Mix", "mix (2)", "Untitled"])
        let mix = store.playlists[0]
        XCTAssertEqual(mix.tracks.map(\.id), ["1", "2"])
        XCTAssertEqual(Set(mix.entries.map(\.id)).count, 2, "entry ids are unique again")
        XCTAssertEqual(try store.resolve("MIX (2)").name, "mix (2)")
        XCTAssertEqual(store.notice?.hasPrefix("1 playlist couldn't be read and was left out."), true,
                       "the duplicate id is backed up before it's dropped")
    }

    func testNewerFormatIsReadOnlyAndNeverRewritten() throws {
        let original = #"{"version": 2, "playlists": [\#(playlistJSON(name: "Future"))], "smartFolders": []}"#
        try writeRaw(original)
        let store = store()

        XCTAssertEqual(store.playlists.map(\.name), ["Future"], "still visible")
        XCTAssertEqual(store.readOnlyReason, "These playlists were saved by a newer version of the app, so they can't be changed here.")
        XCTAssertThrowsError(try store.create(name: "New")) {
            guard case .storageUnavailable? = $0 as? MusicError else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try store.delete(store.playlists[0].id))
        XCTAssertEqual(store.playlists.map(\.name), ["Future"], "memory never runs ahead of disk")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original)
        XCTAssertEqual(try siblings(), ["playlists.json"], "nothing set aside")
    }

    func testFileThatCantBeOpenedIsLeftAloneAndRetried() throws {
        // A directory where the file should be stands in for an unreadable file.
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let store = store()
        XCTAssertTrue(store.readOnlyReason?.hasPrefix("Saved playlists can't be opened right now") == true)
        XCTAssertThrowsError(try store.create(name: "New"))
        XCTAssertEqual(try siblings(), ["playlists.json"], "nothing moved or backed up")

        try FileManager.default.removeItem(at: url)
        try Data(#"{"version": 1, "playlists": [\#(playlistJSON(name: "Back"))]}"#.utf8).write(to: url)
        store.reloadIfReadOnly()
        XCTAssertNil(store.readOnlyReason)
        XCTAssertEqual(store.playlists.map(\.name), ["Back"])
        try store.create(name: "Works")
    }

    func testMissingVersionIsTheCurrentFormat() throws {
        try writeRaw(#"{"playlists": [\#(playlistJSON(name: "Legacy"))]}"#)
        let store = store()
        XCTAssertEqual(store.playlists.map(\.name), ["Legacy"])
        XCTAssertNil(store.readOnlyReason)
        XCTAssertNil(store.notice)
    }

    func testBackupNamesNeverCollide() throws {
        try writeRaw("garbage one")
        _ = store()
        try writeRaw("garbage two")
        _ = store()
        XCTAssertEqual(try siblings(), ["playlists-unreadable-20260921-141320-2.json",
                                         "playlists-unreadable-20260921-141320.json"])
    }

    func testWritesTheVersionedFormat() throws {
        let store = store()
        try store.create(name: "Saved", tracks: [track("1")])
        let json = try JSONValue.decode(Data(contentsOf: url))
        XCTAssertEqual(json["version"], 1)
        guard case .array(let playlists)? = json["playlists"] else { return XCTFail("no playlists") }
        XCTAssertEqual(playlists.first?["name"], "Saved")
    }
}
