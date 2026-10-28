import SwiftUI
import XCTest
@testable import TermLLM

/// Renders the Music screens with sample data in a real window. Guards against
/// screens that fail to lay out, and attaches screenshots to the test result
/// for review (`xcrun xcresulttool export attachments`).
@MainActor
final class MusicViewRenderingTests: XCTestCase {
    private func sampleLibrary() async throws -> MusicLibrary {
        let songs = [
            track("1", "Teardrop", artist: "Massive Attack"),
            track("2", "Glory Box", artist: "Portishead"),
            track("3", "Roads", artist: "Portishead"),
            track("4", "Unfinished Sympathy", artist: "Massive Attack"),
        ]
        let library = MusicLibrary(catalog: FakeCatalog(tracks: songs), engine: FakeEngine(),
                                   store: PlaylistStore(fileURL: temporaryPlaylistFile()), defaults: isolatedDefaults())
        try library.store.create(name: "Road Trip", tracks: [songs[3]])
        let bristol = try library.store.create(name: "Bristol Trip-Hop", tracks: Array(songs.prefix(3)))
        try await library.player.play(bristol, startingAt: bristol.entries[1].id)
        return library
    }

    private func render<Content: View>(_ view: Content, named name: String) async throws {
        // Windows only draw when attached to a scene; borrow the test host's.
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(800))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(Self.hasContent(image), "\(name) rendered a blank screen")
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        window.isHidden = true
    }

    /// True unless every pixel is the same colour.
    private static func hasContent(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage,
              let data = cgImage.dataProvider?.data as Data?, data.count >= 4 else { return false }
        let first = data.prefix(4)
        return stride(from: 0, to: data.count - 4, by: 4 * 97).contains { data[$0..<$0 + 4] != first }
    }

    func testMusicScreen() async throws {
        let library = try await sampleLibrary()
        try await render(MusicView(library: library), named: "music")
    }

    func testPlaylistScreen() async throws {
        let library = try await sampleLibrary()
        let playlist = try XCTUnwrap(library.store.playlists.first { $0.name == "Bristol Trip-Hop" })
        try await render(NavigationStack { PlaylistDetailView(library: library, playlistID: playlist.id) },
                         named: "playlist")
    }

    func testEmptyStates() async throws {
        let library = MusicLibrary(catalog: FakeCatalog(access: .notDetermined), engine: FakeEngine(),
                                   store: PlaylistStore(fileURL: temporaryPlaylistFile()), defaults: isolatedDefaults())
        try await render(MusicView(library: library), named: "music-empty")
        let playlist = try library.store.create(name: "New Playlist")
        try await render(NavigationStack { PlaylistDetailView(library: library, playlistID: playlist.id) },
                         named: "playlist-empty")
        try await render(MusicSearchView(library: library, playlistID: playlist.id), named: "add-songs")
    }

    /// Core Animation moves the bars at a capped rate; nothing in the app
    /// redraws them each frame, and they come to rest when playback stops.
    func testPlayingBarsAnimateInCoreAnimationOnlyWhilePlaying() throws {
        let view = PlayingBarsView()
        XCTAssertTrue(view.bars.allSatisfy { $0.animationKeys() == nil })
        view.animating = true
        let animations = view.bars.compactMap { $0.animation(forKey: PlayingBarsView.animationKey) }
        XCTAssertEqual(animations.count, 3)
        XCTAssertTrue(animations.allSatisfy { $0.preferredFrameRateRange.maximum <= 20 && !$0.isRemovedOnCompletion })
        view.animating = false
        XCTAssertTrue(view.bars.allSatisfy { $0.animationKeys() == nil })
    }
}
