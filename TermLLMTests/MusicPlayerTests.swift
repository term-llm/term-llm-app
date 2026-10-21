import XCTest
@testable import TermLLM

@MainActor
final class MusicPlayerTests: XCTestCase {
    private func playlist(_ ids: [String], name: String = "Mix") -> Playlist {
        Playlist(id: UUID(), name: name,
                 entries: ids.map { PlaylistEntry(id: UUID(), track: track($0), addedAt: Date()) },
                 createdAt: Date(), updatedAt: Date())
    }

    func testPlaysAPlaylistFromAnEntry() async throws {
        let engine = FakeEngine()
        let player = MusicPlayer(engine: engine, defaults: isolatedDefaults())
        var starts = 0
        player.willStartPlayback = { starts += 1 }
        let mix = playlist(["1", "2", "3"])
        var spinnerRow: UUID?
        engine.onLoad = { spinnerRow = player.startingEntryID }

        let loaded = try await player.play(mix, startingAt: mix.entries[1].id)

        XCTAssertEqual(loaded.map(\.id), ["1", "2", "3"])
        XCTAssertEqual(engine.loads.first?.index, 1)
        XCTAssertEqual(spinnerRow, mix.entries[1].id, "the tapped row spins while loading")
        XCTAssertNil(player.startingEntryID)
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(player.status, .playing)
        XCTAssertEqual(player.nowPlaying?.id, "2")
        XCTAssertTrue(player.isActive(mix))
        XCTAssertFalse(player.isActive(playlist(["1"], name: "Other")))
    }

    func testSkipsUnavailableSongsWithANotice() async throws {
        let engine = FakeEngine()
        engine.unavailable = ["2"]
        let player = MusicPlayer(engine: engine, defaults: isolatedDefaults())
        let loaded = try await player.play([track("1"), track("2"), track("3")])
        XCTAssertEqual(loaded.map(\.id), ["1", "3"])
        XCTAssertEqual(player.notice?.text, "1 song isn't available on Apple Music")
        XCTAssertEqual(player.notice?.isError, false)
    }

    func testReportsPlaybackFailures() async {
        let engine = FakeEngine()
        engine.playError = MusicError.cannotPlayCatalog
        let player = MusicPlayer(engine: engine, defaults: isolatedDefaults())
        do {
            try await player.play([track("1")])
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? MusicError, .cannotPlayCatalog)
        }
        XCTAssertEqual(player.status, .failed(MusicError.cannotPlayCatalog.localizedDescription))
        XCTAssertEqual(player.notice?.isError, true)
    }

    func testSampleDetectionUsesReservedIDsNotDisplayMetadata() {
        XCTAssertTrue(track("term-llm:sample:future").isSample)
        XCTAssertFalse(track("123", "Fictional Sample Song").isSample)
        XCTAssertFalse(track("sample").isSample)
    }

    func testSampleAndMixedQueuesNeverReachEngineOrPlaybackCallback() async {
        let engine = FakeEngine()
        let defaults = isolatedDefaults()
        let player = MusicPlayer(engine: engine, defaults: defaults)
        var starts = 0
        player.willStartPlayback = { starts += 1 }
        for tracks in [MusicTrack.demoTracks, [track("1"), track("term-llm:sample:future")]] {
            do {
                try await player.play(tracks, shuffle: true)
                XCTFail("sample tracks must not play")
            } catch {
                XCTAssertEqual(error as? MusicError, .sampleSongsNotPlayable)
            }
        }
        XCTAssertEqual(starts, 0)
        XCTAssertTrue(engine.loads.isEmpty)
        XCTAssertEqual(engine.playCount, 0)
        XCTAssertFalse(player.shuffle, "a rejected play must not change shuffle preferences")
        XCTAssertFalse(defaults.bool(forKey: MusicPlayer.shuffleKey))
        XCTAssertTrue(player.queue.isEmpty)
        XCTAssertEqual(player.status, .idle)
        XCTAssertEqual(player.notice?.text, MusicTrack.sampleExplanation)
        XCTAssertEqual(player.notice?.isError, true)
    }

    func testMixedPlaylistCannotPlayEvenStartingFromARealSong() async {
        let engine = FakeEngine()
        let player = MusicPlayer(engine: engine, defaults: isolatedDefaults())
        var starts = 0
        player.willStartPlayback = { starts += 1 }
        let mixed = playlist(["1", "term-llm:sample:paper-moon"])
        do {
            try await player.play(mixed, startingAt: mixed.entries[0].id)
            XCTFail("the queue still includes a nonplayable sample")
        } catch {
            XCTAssertEqual(error as? MusicError, .sampleSongsNotPlayable)
        }
        XCTAssertEqual(starts, 0)
        XCTAssertTrue(engine.loads.isEmpty)
        XCTAssertEqual(engine.playCount, 0)
        XCTAssertNil(player.startingEntryID)
        XCTAssertNil(player.playlistID)
        XCTAssertEqual(player.notice?.text, MusicTrack.sampleExplanation)
    }

    func testRejectedSampleQueueDoesNotInterruptExistingPlayback() async throws {
        let engine = FakeEngine()
        let player = MusicPlayer(engine: engine, defaults: isolatedDefaults())
        try await player.play([track("1")])
        var starts = 0
        player.willStartPlayback = { starts += 1 }
        do {
            try await player.play(MusicTrack.demoTracks)
            XCTFail("sample tracks must not play")
        } catch {
            XCTAssertEqual(error as? MusicError, .sampleSongsNotPlayable)
        }
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(engine.loads.count, 1)
        XCTAssertEqual(engine.playCount, 1)
        XCTAssertEqual(engine.pauseCount, 0)
        XCTAssertEqual(player.queue.map(\.id), ["1"])
        XCTAssertEqual(player.nowPlaying?.id, "1")
        XCTAssertEqual(player.status, .playing)
    }

    func testRefusesEmptyPlaylists() async {
        let player = MusicPlayer(engine: FakeEngine(), defaults: isolatedDefaults())
        do {
            try await player.play(playlist([]))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? MusicError, .emptyPlaylist("Mix"))
        }
    }

    func testFollowsTheSystemPlayer() async throws {
        let engine = FakeEngine()
        let player = MusicPlayer(engine: engine, defaults: isolatedDefaults())
        let mix = playlist(["1", "2"])
        try await player.play(mix)

        engine.emit { $0.state = .paused }
        XCTAssertEqual(player.status, .paused)
        XCTAssertFalse(player.isPlaying)

        try await player.next()
        engine.emit { _ in }
        XCTAssertEqual(player.nowPlaying?.id, "2")

        // Something else started in the Music app.
        engine.emit { $0.current = track("elsewhere"); $0.state = .playing }
        XCTAssertEqual(player.nowPlaying?.id, "elsewhere")
        XCTAssertFalse(player.isActive(mix))

        engine.emit { $0.current = nil; $0.state = .stopped }
        XCTAssertEqual(player.status, .idle)
    }

    func testTransport() async throws {
        let engine = FakeEngine()
        let player = MusicPlayer(engine: engine, defaults: isolatedDefaults())
        try await player.play([track("1"), track("2")])
        await player.togglePlayPause()
        XCTAssertEqual(engine.pauseCount, 1)
        XCTAssertEqual(player.status, .paused)
        await player.togglePlayPause()
        XCTAssertEqual(engine.playCount, 2)
        XCTAssertEqual(player.status, .playing)
        try await player.previous()
        XCTAssertEqual(engine.skips, ["previous"])
    }

    func testShuffleIsRememberedAndApplied() async throws {
        let defaults = isolatedDefaults()
        let engine = FakeEngine()
        let player = MusicPlayer(engine: engine, defaults: defaults)
        XCTAssertFalse(player.shuffle)
        try await player.play([track("1"), track("2")], shuffle: true)
        XCTAssertEqual(engine.loads.last?.shuffle, true)
        XCTAssertTrue(MusicPlayer(engine: FakeEngine(), defaults: defaults).shuffle)

        player.setShuffle(false)
        XCTAssertFalse(engine.snapshot.shuffle)
        // Changed from Control Center while our queue plays.
        engine.emit { $0.shuffle = true }
        XCTAssertTrue(player.shuffle)
        XCTAssertTrue(defaults.bool(forKey: MusicPlayer.shuffleKey))
    }

    func testResumeNeedsSomethingToPlay() async {
        let player = MusicPlayer(engine: FakeEngine(), defaults: isolatedDefaults())
        do {
            try await player.resume()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? MusicError, .nothingToResume)
        }
    }

    func testWaitsForTheSystemPlayerToReportPlaying() async throws {
        let engine = FakeEngine()
        engine.startLag = 4
        let player = MusicPlayer(engine: engine, defaults: isolatedDefaults(),
                                 startCheck: .init(polls: 10, interval: .milliseconds(1)))
        try await player.play([track("1")])
        XCTAssertEqual(player.status, .playing, "never reports the stale paused state")
        XCTAssertEqual(engine.playCount, 1)
    }

    func testReportsPlaybackThatNeverStarts() async throws {
        let engine = FakeEngine()
        engine.neverStarts = true
        let player = MusicPlayer(engine: engine, defaults: isolatedDefaults(),
                                 startCheck: .init(polls: 3, interval: .milliseconds(1)))
        do {
            try await player.play([track("1")])
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? MusicError, .didNotStart)
        }
        XCTAssertEqual(engine.playCount, 2, "retried once")
        XCTAssertEqual(player.status, .failed(MusicError.didNotStart.localizedDescription))
        XCTAssertEqual(player.notice?.isError, true)
    }
}
