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

    #if os(iOS)
    private func render<Content: View>(_ view: Content, named name: String, width: CGFloat? = nil) async throws {
        // Windows only draw when attached to a scene; borrow the test host's.
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: CGSize(width: width ?? scene.screen.bounds.width,
                                                        height: scene.screen.bounds.height))
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

    func testMusicWorkspaceRoot() async throws {
        let library = try await sampleLibrary()
        try await render(MusicView(library: library, embedded: true, usesWorkspaceChrome: true,
                                   onToggleSidebar: {}), named: "music-workspace-root", width: 1_024)
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

    func testPermissionHintsRenderWithoutPrompting() async throws {
        for status: MusicAccess in [.notDetermined, .denied, .restricted] {
            let catalog = FakeCatalog(access: status)
            let library = MusicLibrary(catalog: catalog, engine: FakeEngine(),
                                       store: PlaylistStore(fileURL: temporaryPlaylistFile()), defaults: isolatedDefaults())
            try await render(MusicView(library: library), named: "music-access-\(status.rawValue)")
            let playlist = try library.store.create(name: "Test")
            try await render(MusicSearchView(library: library, playlistID: playlist.id),
                             named: "music-search-access-\(status.rawValue)")
            XCTAssertEqual(catalog.requestCount, 0, "showing guidance must not prompt")
        }
    }

    func testRetainedMusicRefreshesPermissionOnActivationAndVisibleForeground() async throws {
        let catalog = FakeCatalog(access: .notDetermined)
        let library = MusicLibrary(catalog: catalog, engine: FakeEngine(),
                                   store: PlaylistStore(fileURL: temporaryPlaylistFile()), defaults: isolatedDefaults())
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        let host = UIHostingController(rootView: MusicView(library: library, embedded: true, isActive: false)
            .environment(\.scenePhase, .active))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(300))

        catalog.setAccess(.authorized)
        host.rootView = MusicView(library: library, embedded: true, isActive: true)
            .environment(\.scenePhase, .active)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(library.access, .authorized, "activating the retained tab refreshes permission")

        host.rootView = MusicView(library: library, embedded: true, isActive: true)
            .environment(\.scenePhase, .background)
        try await Task.sleep(for: .milliseconds(300))
        catalog.setAccess(.denied)
        host.rootView = MusicView(library: library, embedded: true, isActive: true)
            .environment(\.scenePhase, .active)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(library.access, .denied, "returning from Settings refreshes the visible Music tab")

        host.rootView = MusicView(library: library, embedded: true, isActive: false)
            .environment(\.scenePhase, .background)
        try await Task.sleep(for: .milliseconds(300))
        catalog.setAccess(.restricted)
        host.rootView = MusicView(library: library, embedded: true, isActive: false)
            .environment(\.scenePhase, .active)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(library.access, .denied, "inactive destinations do not refresh in the foreground")
        XCTAssertEqual(catalog.requestCount, 0, "lifecycle refreshes never request permission")
    }

    /// The tab accessory recreates the Music mini player whenever the root view
    /// updates. Its artwork must come back in the first frame from the copy on
    /// the phone, not flash a placeholder while it's fetched and decoded again.
    func testRebuiltArtworkShowsTheSavedImageInItsFirstFrame() async throws {
        let session = ListenMediaSession.makeSession(protocolClasses: [ArtworkProtocol.self])
        defer { session.invalidateAndCancel() }
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ListenArtworkStore(directory: directory, cookies: nil, server: { nil }, session: session)
        let cover = try XCTUnwrap(URL(string: "https://\(UUID().uuidString.lowercased()).artwork.example/cover.jpg"))
        try await render(ArtworkView(url: cover, size: 42, store: store), named: "music-artwork")
        XCTAssertNotNil(store.savedFile(url: cover))

        // Drawn before yielding, so no load can have finished: this is the
        // rebuilt view's first frame.
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 42, height: 42)
        let host = UIHostingController(rootView: ArtworkView(url: cover, size: 42, store: store).ignoresSafeArea())
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.preferredRange = .standard
        let frame = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { context in
            host.view.layer.render(in: context.cgContext)
        }
        let (red, green, blue) = try XCTUnwrap(Self.centre(frame))
        XCTAssertTrue(green > red + 40 && blue > red + 40, "the first frame shows the teal artwork: \(red) \(green) \(blue)")
        XCTAssertEqual(ArtworkProtocol.requests(for: cover), 1, "fetched once")
    }

    private static func centre(_ image: UIImage) -> (Int, Int, Int)? {
        guard let cgImage = image.cgImage, let data = cgImage.dataProvider?.data as Data?,
              cgImage.bitsPerPixel == 32 else { return nil }
        let offset = (cgImage.height / 2) * cgImage.bytesPerRow + (cgImage.width / 2) * 4
        guard data.count >= offset + 4 else { return nil }
        // BGRA or RGBA: the red and blue channels may swap, green stays put.
        let first = Int(data[offset]), second = Int(data[offset + 1]), third = Int(data[offset + 2])
        let bgra = cgImage.bitmapInfo.contains(.byteOrder32Little)
        return bgra ? (third, second, first) : (first, second, third)
    }

    #endif

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
