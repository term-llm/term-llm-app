import SwiftUI
import XCTest
@testable import TermLLM

/// Renders the Listen screens with sample data in a real window, like
/// `MusicViewRenderingTests`; screenshots are attached to the test result.
@MainActor
final class ListenViewRenderingTests: XCTestCase {
    private func sampleListen() async throws -> Listen {
        let engine = FakeListenEngine()
        // Saving the streaming episode stays in flight at about a third.
        let listen = makeListen(engine: engine, fetch: { _, transfer in
            transfer.report(received: 21_000_000, expected: 62_000_000)
            try await Task.sleep(for: .seconds(60))
            throw CancellationError()
        })
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

    func testPlayerSheet() async throws {
        let listen = try await sampleListen()
        listen.player.sleepAtEndOfItem()
        try await render(ListenPlayerView(listen: listen), named: "listen-player")
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
