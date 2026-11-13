import Observation
import SwiftUI
import XCTest
@testable import TermLLM

/// Renders the Listen screens with sample data in a real window, like
/// `MusicViewRenderingTests`; screenshots are attached to the test result.
#if os(iOS)
@MainActor
final class ListenViewRenderingTests: XCTestCase {
    private func sampleListen() async throws -> Listen {
        let engine = FakeListenEngine()
        // Saving the streaming episode stays in flight at about a third.
        let server = FakeMediaServer()
        server.serve(URL(string: "https://hub.example/media/brief.mp3")!, .init(body: mediaBody(6_200_000)))
        server.hold(2_100_000..<6_200_000)
        let listen = makeListen(engine: engine, server: server)
        let items = try await listen.add([
            ListenDraft(url: URL(string: "https://hub.example/media/brief.mp3")!, title: "Morning briefing: Sunday 18 October",
                        artist: "term-llm · af_sky", kind: .generated, duration: 412),
            ListenDraft(url: URL(string: "https://feeds.example/ep212.mp3")!, title: "Episode 212: The long tail of caches",
                        artist: "Systems Weekly", kind: .episode, duration: 3_720),
            ListenDraft(url: URL(string: "https://feeds.example/ep88.mp3")!, title: "How sound effects are made",
                        artist: "Twenty Thousand Hertz", kind: .episode, duration: 1_980),
        ], placement: .now, download: .never)
        engine.duration = 412
        engine.currentTime = 95
        engine.bufferedUntil = 260
        engine.send(.tick)
        for _ in 0..<50 where listen.downloader.progress[items[0].id]?.fraction == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        listen.store.update(items[2].id) { $0.status = .inProgress; $0.position = 600 }
        let old = listen.store.add([ListenDraft(url: URL(string: "https://feeds.example/ep1.mp3")!, title: "Pilot",
                                                artist: "Systems Weekly", kind: .episode, duration: 1_500)], placement: .end)
        try listen.store.setStatus([old[0].id], .played)
        return listen
    }

    private func hostedWindow<Content: View>(_ view: Content, width: CGFloat? = nil) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: CGSize(width: width ?? scene.screen.bounds.width,
                                                        height: scene.screen.bounds.height))
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        return window
    }

    private func capture(_ window: UIWindow, named name: String) throws {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let cgImage = try XCTUnwrap(image.cgImage)
        let pixels = try XCTUnwrap(cgImage.dataProvider?.data as Data?)
        XCTAssertGreaterThan(pixels.count, 4)
        // A blank-screen guard, not evidence of control presence or usability.
        XCTAssertTrue(stride(from: 0, to: max(0, pixels.count - 4), by: 4 * 97).contains {
            pixels[$0..<$0 + 4] != pixels.prefix(4)
        }, "\(name) rendered a blank screen")
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func render<Content: View>(_ view: Content, named name: String) async throws {
        let previousKeyWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        let window = try hostedWindow(view)
        defer { window.isHidden = true; previousKeyWindow?.makeKey() }
        try await Task.sleep(for: .milliseconds(800))
        try capture(window, named: name)
    }

    private struct ShelfFixture {
        let listen: Listen
        let library: MusicLibrary
        let podcastEngine: FakeListenEngine
        let musicEngine: FakeEngine
    }

    private func shelfFixture(_ source: MediaPlaybackShelf.Source) async throws -> ShelfFixture {
        let podcastEngine = FakeListenEngine()
        let listen = makeListen(engine: podcastEngine)
        let musicEngine = FakeEngine()
        let songs = [track("shelf-1", "Unfinished Sympathy — a very long song title", artist: "Massive Attack")]
        let library = MusicLibrary(catalog: FakeCatalog(tracks: songs), engine: musicEngine,
                                   store: PlaylistStore(fileURL: temporaryPlaylistFile()), defaults: isolatedDefaults())
        switch source {
        case .podcasts:
            _ = try await listen.add([
                ListenDraft(url: URL(string: "https://feeds.example/ep212.mp3")!,
                            title: "Episode 212: The long tail of caches and distributed systems",
                            artist: "Systems Weekly", kind: .episode, duration: 3_720),
            ], placement: .now, download: .never)
            podcastEngine.duration = 3_720
            podcastEngine.currentTime = 95
            podcastEngine.bufferedUntil = 260
            podcastEngine.send(.tick)
        case .music:
            try await library.player.play(songs)
        }
        return ShelfFixture(listen: listen, library: library,
                            podcastEngine: podcastEngine, musicEngine: musicEngine)
    }

    private func renderShelves(scheme: ColorScheme, width: CGFloat? = nil,
                               dynamicType: DynamicTypeSize = .large, forceFallback: Bool = false) async throws {
        for source in [MediaPlaybackShelf.Source.music, .podcasts] {
            let fixture = try await shelfFixture(source)
            let previousKeyWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows).first(where: \.isKeyWindow)
            let window = try hostedWindow(
                MediaShelfRenderingHarness(listen: fixture.listen, music: fixture.library.player,
                                           forceFallback: forceFallback)
                    .environment(\.colorScheme, scheme)
                    .environment(\.dynamicTypeSize, dynamicType), width: width)
            defer { window.isHidden = true; previousKeyWindow?.makeKey() }
            window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
            try await Task.sleep(for: .milliseconds(800))
            let presentation: String
            if #available(iOS 26.1, *), !forceFallback { presentation = "native-accessory" }
            else { presentation = "safe-area" }
            let name = "shelf-\(source)-\(presentation)-\(scheme)-\(Int(window.bounds.width))pt-\(dynamicType)"
            try capture(window, named: name)
        }
    }

    /// Unlike the engine-only test, includes production Listen state, system
    /// now-playing integration, MusicKit observation, and the native tab shelf.
    /// Records comparative evidence rather than assuming a portable CPU limit.
    func testProductionPlaybackPathCPUAcrossShelfAndPauseStates() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = URL(string: "https://pod.example/production-cpu.mp3")!
        var frame = Data(count: 417)
        frame.replaceSubrange(0..<4, with: [0xFF, 0xFB, 0x90, 0xC4])
        let body = Data((0..<Int(120.0 * 44_100 / 1_152)).flatMap { _ in frame })
        let server = FakeMediaServer()
        server.serve(url, .init(body: body))
        let artwork = ListenArtworkStore(directory: directory.appending(path: "Artwork"), cookies: nil, server: { nil })
        let listen = Listen(store: ListenStore(fileURL: directory.appending(path: "library.json")),
                            engine: AVListenEngine(), cookies: FakeCookieJar(), server: { nil },
                            nowPlaying: SystemNowPlaying(artwork: artwork), artwork: artwork,
                            downloadDirectory: directory.appending(path: "Downloads"), fetching: server,
                            defaults: isolatedDefaults())
        let music = MusicLibrary.shared.player
        listen.player.willStartPlayback = { if music.isPlaying { music.pause() } }
        let items = try await listen.add([ListenDraft(url: url, title: "Production playback CPU fixture", kind: .episode)],
                                         placement: .end, download: .never)
        let previousKeyWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        let window = try hostedWindow(MediaShelfRenderingHarness(listen: listen, music: music))
        defer {
            listen.player.stop()
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }
        var evidence: [String] = []
        let sampleSeconds = ProcessInfo.processInfo.environment["TERMLLM_LISTEN_CPU_SAMPLE_SECONDS"]
            .flatMap(Int.init).map { min(30, max(2, $0)) } ?? 2
        func measure(_ state: String) async throws {
            try await Task.sleep(for: .milliseconds(500))
            let sampler = ProcessUsageSampler()
            _ = sampler.sample(appActive: true, appBackground: false)
            try await Task.sleep(for: .seconds(sampleSeconds))
            let sample = sampler.sample(appActive: true, appBackground: false)
            evidence.append("\(state): CPU cores=\(sample.appCPU.map(String.init(describing:)) ?? "unavailable"), "
                            + "wakeups/s=\(sample.wakeupsPerSecond.map(String.init(describing:)) ?? "unavailable")")
        }
        try await measure("idle native shelf")
        try await listen.player.play(items[0].id)
        XCTAssertEqual(listen.player.status, .playing)
        try await measure("playing native shelf 1x")
        XCTAssertGreaterThan(listen.player.position, 0.5, "The production player must actually advance")
        listen.player.setRate(1.5)
        try await measure("playing native shelf 1.5x")
        listen.player.pause()
        try await measure("paused native shelf")
        window.isHidden = true
        try await measure("paused window hidden")
        try await listen.player.resume()
        try await measure("playing window hidden")
        window.rootViewController = UIHostingController(rootView:
            MediaShelfRenderingHarness(listen: listen, music: music, forceFallback: true))
        window.makeKeyAndVisible()
        try await measure("playing fallback shelf")
        listen.player.stop()
        try await measure("stopped fallback shelf")
        let attachment = XCTAttachment(string: evidence.joined(separator: "\n"))
        attachment.name = "simulator-production-playback-path-cpu"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSharedMediaShelfLight() async throws {
        try await renderShelves(scheme: .light)
    }

    func testSharedMediaShelfDark() async throws {
        try await renderShelves(scheme: .dark)
    }

    func testSharedMediaShelfCompactAccessibilityText() async throws {
        // Capture both appearances at a real 320pt window width, not an image scaled down afterwards.
        for scheme in [ColorScheme.light, .dark] {
            try await renderShelves(scheme: scheme, width: 320, dynamicType: .accessibility3)
        }
    }

    func testSharedMediaShelfSafeAreaFallback() async throws {
        // Exercise the older-system presentation even when the test simulator supports the native accessory.
        try await renderShelves(scheme: .dark, width: 320, dynamicType: .accessibility3, forceFallback: true)
    }

    /// Public UIKit inspection only: SwiftUI does not expose its accessibility
    /// tree in every unit-test host. No private AX APIs or synthetic button actions.
    private func accessibilityElements(in window: UIWindow) -> [NSObject] {
        var pending: [NSObject] = [window]
        var visited = Set<ObjectIdentifier>()
        var result: [NSObject] = []
        while let element = pending.popLast(), visited.count < 2_048 {
            guard visited.insert(ObjectIdentifier(element)).inserted else { continue }
            result.append(element)
            if let view = element as? UIView { pending.append(contentsOf: view.subviews) }
            if let children = element.accessibilityElements {
                pending.append(contentsOf: children.prefix(128).compactMap { $0 as? NSObject })
            }
            let count = element.accessibilityElementCount()
            if count > 0 && count < 128 {
                for index in 0..<count {
                    if let child = element.accessibilityElement(at: index) as? NSObject { pending.append(child) }
                }
            }
        }
        return result
    }

    private func verifyShelfDismissal(_ source: MediaPlaybackShelf.Source) async throws {
        let fixture = try await shelfFixture(source)
        let previousKeyWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        let window = try hostedWindow(
            MediaShelfRenderingHarness(listen: fixture.listen, music: fixture.library.player)
                .environment(\.dynamicTypeSize, .accessibility3), width: 320)
        defer { window.isHidden = true; previousKeyWindow?.makeKey() }
        try await Task.sleep(for: .milliseconds(800))
        try capture(window, named: "shelf-\(source)-before-accessibility-hide")
        let elements = accessibilityElements(in: window)
        func identifier(_ element: NSObject) -> String? {
            (element as? UIAccessibilityIdentification)?.accessibilityIdentifier
        }
        guard elements.contains(where: { identifier($0) == "mediaShelfHarnessContent" }) else {
            throw XCTSkip("This unit-test host does not expose the SwiftUI accessibility tree; inspect screenshot attachments instead")
        }
        let closeID = source == .music ? "musicMiniPlayerClose" : "miniPlayerClose"
        let close = try XCTUnwrap(elements.first { identifier($0) == closeID }, "The shelf must expose its X control")
        let labels = source == .music
            ? ["Hide Music player", "Pause Music"]
            : ["Hide Podcast player", "Pause"]
        for label in labels {
            let control = try XCTUnwrap(elements.first { $0.accessibilityLabel == label }, "Missing control: \(label)")
            XCTAssertTrue(control.accessibilityTraits.contains(.button), label)
            let frame = control.accessibilityFrame
            XCTAssertGreaterThanOrEqual(frame.width, 44, label)
            XCTAssertGreaterThanOrEqual(frame.height, 44, label)
            XCTAssertTrue(window.convert(window.bounds, to: nil).insetBy(dx: -0.5, dy: -0.5).contains(frame),
                          "\(label) must not be clipped outside the 320pt window")
        }
        let podcastID = fixture.listen.player.currentID
        let musicID = fixture.library.player.nowPlaying?.id
        let pauseCount = fixture.musicEngine.pauseCount
        let stopCount = fixture.podcastEngine.stops
        guard close.accessibilityActivate() else {
            throw XCTSkip("The host exposes AX frames but does not support activating SwiftUI buttons in process")
        }
        try await Task.sleep(for: .milliseconds(800))
        let remainingElements = accessibilityElements(in: window)
        XCTAssertTrue(remainingElements.contains { identifier($0) == "mediaShelfHarnessContent" },
                      "The parent tab content should remain accessible after hiding the shelf")
        XCTAssertFalse(remainingElements.contains { identifier($0) == closeID },
                       "X should hide the panel, not merely leave an inactive control")
        XCTAssertEqual(fixture.listen.player.currentID, podcastID)
        XCTAssertEqual(fixture.library.player.nowPlaying?.id, musicID)
        XCTAssertEqual(fixture.musicEngine.pauseCount, pauseCount)
        XCTAssertEqual(fixture.podcastEngine.stops, stopCount)
        if source == .music {
            XCTAssertTrue(fixture.library.player.isPlaying)
            XCTAssertEqual(fixture.musicEngine.snapshot.state, .playing)
        } else {
            XCTAssertTrue(fixture.listen.player.isPlaying)
            XCTAssertTrue(fixture.podcastEngine.playing)
            XCTAssertFalse(fixture.listen.player.showsBar)
        }
        try capture(window, named: "shelf-\(source)-after-hide-keeps-playing")
    }

    func testSharedMusicShelfAccessibleControlsAndHideKeepsPlaying() async throws {
        try await verifyShelfDismissal(.music)
    }

    func testSharedPodcastShelfAccessibleControlsAndHideKeepsPlaying() async throws {
        try await verifyShelfDismissal(.podcasts)
    }

    func testMiniPlayerUnderPage() async throws {
        let listen = try await sampleListen()
        try await render(VStack(spacing: 0) {
            Color.cyan.opacity(0.15).overlay(Text("web page"))
            MiniPlayerBar(listen: listen) {}
        }, named: "listen-mini-player")
    }

    func testMiniPlayerShowsArtworkSavedOnThePhone() async throws {
        let session = ListenMediaSession.makeSession(protocolClasses: [ArtworkProtocol.self])
        defer { session.invalidateAndCancel() }
        let directory = temporaryDirectory()
        let artwork = ListenArtworkStore(directory: directory.appending(path: "Artwork"), cookies: FakeCookieJar(),
                                         server: { nil }, session: session)
        let listen = makeListen(directory: directory, artwork: artwork)
        let cover = URL(string: "https://\(UUID().uuidString.lowercased()).artwork.example/cover.jpg")!
        let items = try await listen.add([
            ListenDraft(url: URL(string: "https://feeds.example/ep212.mp3")!, title: "Episode 212: The long tail of caches",
                        artist: "Systems Weekly", artworkURL: cover, kind: .episode, duration: 3_720),
        ], placement: .now, download: .never)
        try await render(VStack(spacing: 0) {
            Color.cyan.opacity(0.15).overlay(Text("web page"))
            MiniPlayerBar(listen: listen) {}
        }, named: "listen-mini-player-artwork")
        XCTAssertNotNil(artwork.cachedImage(for: items[0], pixels: ListenArtworkStore.pixels(for: 42, scale: 3)),
                        "the mini player decoded its artwork from the saved file")
        XCTAssertNotNil(artwork.savedFile(for: items[0]))
        XCTAssertEqual(ArtworkProtocol.requests(for: cover), 1)
    }

    func testPlayerSheet() async throws {
        let listen = try await sampleListen()
        listen.player.sleepAtEndOfItem()
        try await render(ListenPlayerView(listen: listen), named: "listen-player")
    }

    func testPresentedPlayerCloseKeepsPlaybackAndMiniPlayer() async throws {
        let fixture = try await shelfFixture(.podcasts)
        let presentation = PlayerSheetPresentation()
        let previousKeyWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        let window = try hostedWindow(PlayerSheetFixture(listen: fixture.listen, presentation: presentation))
        defer { window.isHidden = true; previousKeyWindow?.makeKey() }
        try await Task.sleep(for: .milliseconds(300))
        presentation.isPresented = true
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertNotNil(window.rootViewController?.presentedViewController)
        try capture(window, named: "listen-presented-player")
        let currentID = fixture.listen.player.currentID
        let stops = fixture.podcastEngine.stops
        let rates = fixture.podcastEngine.rates
        let showsBar = fixture.listen.player.showsBar
        let close = accessibilityElements(in: window).first {
            ($0 as? UIAccessibilityIdentification)?.accessibilityIdentifier == "listenPlayerClose"
        }
        guard let close else {
            throw XCTSkip("This unit-test host does not expose the SwiftUI sheet accessibility tree; inspect the screenshot attachment")
        }
        XCTAssertTrue(close.accessibilityActivate())
        for _ in 0..<40 where presentation.isPresented || window.rootViewController?.presentedViewController != nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(presentation.isPresented)
        XCTAssertNil(window.rootViewController?.presentedViewController)
        XCTAssertEqual(fixture.listen.player.currentID, currentID)
        XCTAssertTrue(fixture.listen.player.isPlaying)
        XCTAssertTrue(fixture.podcastEngine.playing)
        XCTAssertEqual(fixture.podcastEngine.stops, stops)
        XCTAssertEqual(fixture.podcastEngine.rates, rates)
        XCTAssertEqual(fixture.listen.player.showsBar, showsBar)
        try capture(window, named: "listen-player-closed-keeps-playing")
    }

    func testLibraryContextMenusForUpNextAndHistory() async throws {
        // Query the public UIKit menu delegate at visible row locations. This
        // verifies registration, not a real mouse gesture or the menu's actions.
        for status in [ListenItem.Status.unplayed, .inProgress, .played, .archived] {
            let listen = makeListen()
            let item = try XCTUnwrap(listen.store.add([draft("menu", title: "Menu episode")], placement: .end).first)
            try listen.store.setStatus([item.id], status)
            let previousKeyWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows).first(where: \.isKeyWindow)
            let window = try hostedWindow(ListenView(listen: listen))
            defer { window.isHidden = true; previousKeyWindow?.makeKey() }
            try await Task.sleep(for: .milliseconds(800))

            func descendants(_ view: UIView) -> [UIView] {
                [view] + view.subviews.flatMap(descendants)
            }
            let views = descendants(window)
            let cells = views.compactMap { $0 as? UICollectionViewCell }
            let interactions = views.flatMap(\.interactions).compactMap { $0 as? UIContextMenuInteraction }
            let hasMenu = interactions.contains { interaction in
                guard let view = interaction.view else { return false }
                return cells.contains { cell in
                    let center = CGPoint(x: cell.bounds.midX, y: cell.bounds.midY)
                    let location = cell.convert(center, to: view)
                    guard view.bounds.contains(location) else { return false }
                    return interaction.delegate?.contextMenuInteraction(interaction, configurationForMenuAtLocation: location) != nil
                }
            }
            XCTAssertTrue(hasMenu, "\(status) rows must expose a context menu, not only swipe actions")
        }
    }

    func testWorkspaceHeaderIsOptIn() async throws {
        for usesWorkspaceChrome in [false, true] {
            let previousKeyWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows).first(where: \.isKeyWindow)
            let window = try hostedWindow(NavigationStack {
                ListenView(listen: makeListen(), embedded: true, usesWorkspaceChrome: usesWorkspaceChrome,
                           onToggleSidebar: {})
            }, width: 1_024)
            defer { window.isHidden = true; previousKeyWindow?.makeKey() }
            try await Task.sleep(for: .milliseconds(800))
            try capture(window, named: usesWorkspaceChrome ? "listen-workspace-root" : "listen-system-root")
            let identifiers = accessibilityElements(in: window).compactMap {
                ($0 as? UIAccessibilityIdentification)?.accessibilityIdentifier
            }
            guard identifiers.contains("podcastsScreen") else {
                throw XCTSkip("This host does not expose the SwiftUI accessibility tree; inspect screenshot attachments instead")
            }
            XCTAssertEqual(identifiers.contains("listenWorkspaceHeader"), usesWorkspaceChrome)
        }
    }

    func testLibrary() async throws {
        let listen = try await sampleListen()
        try await render(ListenView(listen: listen), named: "listen-library")
        try await render(ListenView(listen: makeListen()), named: "listen-empty")
    }
}

/// Mirrors the persistent tab host, rather than rendering a shelf in an isolated
/// VStack: the parent binding/observer must survive when the accessory disappears.
@MainActor
private struct MediaShelfRenderingHarness: View {
    let listen: Listen
    let music: MusicPlayer
    var forceFallback = false
    @State private var shelfState = MediaPlaybackShelf.State()

    private var playback: MediaPlaybackShelf.Playback {
        .init(podcastID: listen.player.currentID, podcastVisible: listen.player.showsBar,
              podcastPlaying: listen.player.isPlaying, musicID: music.nowPlaying?.id,
              musicPlaying: music.isPlaying)
    }

    var body: some View {
        Group {
            if #available(iOS 26.1, *), !forceFallback {
                nativeTabView
                    .tabViewBottomAccessory(isEnabled: shelfState.visibleSource(for: playback) != nil) {
                        shelf(usesSystemBackground: true)
                    }
            } else {
                nativeTabView
            }
        }
        .onChange(of: playback, initial: true) { _, value in shelfState.update(value) }
    }

    private var nativeTabView: some View {
        TabView {
            tabContent.tabItem { Label("Agents", systemImage: "square.grid.2x2") }
            tabContent.tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
            tabContent.tabItem { Label("Music", systemImage: "music.note") }
            tabContent.tabItem { Label("Podcasts", systemImage: "dot.radiowaves.left.and.right") }
        }
    }

    @ViewBuilder private var tabContent: some View {
        if #available(iOS 26.1, *), !forceFallback {
            page
        } else {
            page.safeAreaInset(edge: .bottom, spacing: 0) { shelf() }
        }
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your workspace")
                .font(.title.bold())
                .accessibilityIdentifier("mediaShelfHarnessContent")
            Text("Playback continues as you switch tabs.")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(.systemGroupedBackground))
    }

    private func shelf(usesSystemBackground: Bool = false) -> some View {
        MediaPlaybackShelf(listen: listen, music: music, state: $shelfState,
                           usesSystemBackground: usesSystemBackground,
                           onOpenPodcastPlayer: {}, onOpenMusic: {})
    }
}

@MainActor
private final class PlayerSheetPresentation: ObservableObject {
    @Published var isPresented = false
}

@MainActor
private struct PlayerSheetFixture: View {
    let listen: Listen
    @ObservedObject var presentation: PlayerSheetPresentation

    var body: some View {
        MiniPlayerBar(listen: listen) { presentation.isPresented = true }
            .sheet(isPresented: $presentation.isPresented) { ListenPlayerView(listen: listen) }
    }
}

#endif

/// Verify the actual view-body dependencies, not just the player model: a tick
/// should refresh the small labels/scrubber without rebuilding artwork/menus.
@MainActor
final class ListenViewObservationTests: XCTestCase {
    private func fixture() async throws -> (Listen, FakeListenEngine, ListenItem) {
        let engine = FakeListenEngine()
        let listen = makeListen(engine: engine)
        let added = try await listen.add([
            ListenDraft(url: URL(string: "http://pod.example/episode.mp3")!, title: "Episode", duration: 600)
        ], placement: .now, download: .never)
        engine.duration = 600
        engine.currentTime = 30
        engine.bufferedUntil = 120
        engine.send(.tick)
        return (listen, engine, try XCTUnwrap(listen.store.item(added[0].id)))
    }

    func testTickDoesNotInvalidateMiniPlayerOrFullPlayerBody() async throws {
        let (listen, engine, _) = try await fixture()
        let mini = ObservationFlag()
        let full = ObservationFlag()
        withObservationTracking {
            _ = MiniPlayerBar(listen: listen, onOpen: {}).body
        } onChange: { mini.raise() }
        withObservationTracking {
            _ = ListenPlayerView(listen: listen).body
        } onChange: { full.raise() }
        engine.currentTime = 31
        engine.bufferedUntil = 121
        engine.send(.tick)
        XCTAssertFalse(mini.raised, "mini-player artwork and transport must not observe the playhead")
        XCTAssertFalse(full.raised, "full-player artwork and menus must not observe the playhead")
    }

    func testTickStillInvalidatesSubtitleAndScrubber() async throws {
        let (listen, engine, item) = try await fixture()
        let subtitle = ObservationFlag()
        let scrubber = ObservationFlag()
        withObservationTracking {
            _ = ListenMiniPlayerSubtitle(player: listen.player, item: item).body
        } onChange: { subtitle.raise() }
        withObservationTracking {
            _ = ListenPlaybackScrubber(player: listen.player).body
        } onChange: { scrubber.raise() }
        engine.currentTime = 31
        engine.send(.tick)
        XCTAssertTrue(subtitle.raised)
        XCTAssertTrue(scrubber.raised)
    }

    private final class ObservationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var raised: Bool { lock.withLock { value } }
        func raise() { lock.withLock { value = true } }
    }
}
