import SwiftUI
import WebKit
import XCTest
@testable import TermLLM

@MainActor
final class AppControlsTests: XCTestCase {
    private final class State {
        var expanded = false
        var actions: [AppControlAction] = []
        let defaults: UserDefaults

        init(defaults: UserDefaults = isolatedDefaults()) { self.defaults = defaults }
    }

    private func bar(_ state: State, canGoBack: Bool = false) -> AppControlsBar {
        AppControlsBar(
            isExpanded: Binding(get: { state.expanded }, set: { state.expanded = $0 }),
            hintAcknowledged: Binding(
                get: { state.defaults.bool(forKey: AppControlsBar.hintAcknowledgedKey) },
                set: { state.defaults.set($0, forKey: AppControlsBar.hintAcknowledgedKey) }),
            canGoBack: canGoBack, onAction: { state.actions.append($0) })
    }

    func testPlaybackShelfDoesNotInventOrStartAPlayer() {
        XCTAssertNil(MediaPlaybackShelf.visibleSource(podcastVisible: false, podcastPlaying: false,
                                                     musicAvailable: false, musicPlaying: false))
        XCTAssertEqual(MediaPlaybackShelf.visibleSource(podcastVisible: true, podcastPlaying: false,
                                                       musicAvailable: true, musicPlaying: true), .music)
        XCTAssertEqual(MediaPlaybackShelf.visibleSource(podcastVisible: true, podcastPlaying: true,
                                                       musicAvailable: true, musicPlaying: false), .podcasts)
        XCTAssertEqual(MediaPlaybackShelf.visibleSource(podcastVisible: true, podcastPlaying: false,
                                                       musicAvailable: true, musicPlaying: false, preferred: .music), .music,
                       "Pausing Music must not switch the shelf to an older paused podcast")
        XCTAssertEqual(MediaPlaybackShelf.visibleSource(podcastVisible: false, podcastPlaying: true,
                                                       musicAvailable: true, musicPlaying: false), .music,
                       "Hiding the podcast bar must not bring it back during tab changes")
    }

    private func playback(podcastID: UUID? = nil, podcastVisible: Bool = false,
                          podcastPlaying: Bool = false, musicID: String? = nil,
                          musicPlaying: Bool = false) -> MediaPlaybackShelf.Playback {
        .init(podcastID: podcastID, podcastVisible: podcastVisible,
              podcastPlaying: podcastPlaying, musicID: musicID, musicPlaying: musicPlaying)
    }

    func testMusicShelfDismissalDoesNotFallBackToPausedPodcast() {
        var state = MediaPlaybackShelf.State()
        let playing = playback(podcastID: UUID(), podcastVisible: true,
                               musicID: "song-a", musicPlaying: true)
        state.update(playing)
        XCTAssertEqual(state.visibleSource(for: playing), .music)
        state.dismiss(.music, playback: playing)
        XCTAssertNil(state.visibleSource(for: playing), "Dismissal hides controls even while audio is playing")
        XCTAssertEqual(state.dismissedMusicID, "song-a")

        var paused = playing
        paused.musicPlaying = false
        state.update(paused)
        XCTAssertNil(state.visibleSource(for: paused), "Pausing hidden Music must not reveal the old podcast")
    }

    func testPodcastShelfDismissalDoesNotFallBackToPausedMusic() {
        var state = MediaPlaybackShelf.State()
        let playing = playback(podcastID: UUID(), podcastVisible: true, podcastPlaying: true,
                               musicID: "older-song")
        state.update(playing)
        XCTAssertEqual(state.visibleSource(for: playing), .podcasts)
        state.dismiss(.podcasts, playback: playing)
        var hidden = playing
        hidden.podcastVisible = false // ListenPlayer.hideBar(), not stop().
        state.update(hidden)
        XCTAssertTrue(hidden.podcastPlaying)
        XCTAssertNil(state.visibleSource(for: hidden))

        hidden.podcastPlaying = false
        state.update(hidden)
        XCTAssertNil(state.visibleSource(for: hidden))
    }

    func testShelfHostRemountsPreserveDismissalAndPreferredSource() {
        var state = MediaPlaybackShelf.State()
        var current = playback(podcastID: UUID(), podcastVisible: true,
                               musicID: "song-a", musicPlaying: true)
        state.update(current)
        state.dismiss(.music, playback: current)
        for _ in 0..<4 {
            // Each fallback tab's onChange(initial: true) sees the same inputs.
            state.update(current)
            XCTAssertNil(state.visibleSource(for: current))
            XCTAssertEqual(state.preferredSource, .music)
        }
        current.musicPlaying = false
        state.update(current)
        state.update(current)
        XCTAssertNil(state.visibleSource(for: current))

        state.dismiss(.podcasts, playback: current)
        current.podcastVisible = false
        state.update(current)
        state.update(current)
        XCTAssertNil(state.visibleSource(for: current))
        XCTAssertEqual(state.preferredSource, .podcasts)
    }

    func testNewMusicIdentityRestoresShelfWithoutAPlayingTransition() {
        var state = MediaPlaybackShelf.State()
        var current = playback(musicID: "song-a", musicPlaying: true)
        state.update(current)
        state.dismiss(.music, playback: current)
        current.musicID = "song-b"
        state.update(current)
        XCTAssertEqual(state.visibleSource(for: current), .music)
        XCTAssertNil(state.dismissedMusicID)

        current.musicPlaying = false
        state.update(current)
        state.dismiss(.music, playback: current)
        current.musicID = "song-c"
        state.update(current)
        XCTAssertEqual(state.visibleSource(for: current), .music, "A genuinely new paused selection can restore controls")
    }

    func testResumingDismissedMusicRestoresShelf() {
        var state = MediaPlaybackShelf.State()
        var current = playback(musicID: "song-a")
        state.update(current)
        state.dismiss(.music, playback: current)
        XCTAssertNil(state.visibleSource(for: current))
        current.musicPlaying = true
        state.update(current)
        XCTAssertEqual(state.visibleSource(for: current), .music)
    }

    func testNewPodcastOrExplicitShowRestoresShelf() {
        var state = MediaPlaybackShelf.State()
        var current = playback(podcastID: UUID(), podcastVisible: true, podcastPlaying: true,
                               musicID: "older-song")
        state.update(current)
        state.dismiss(.podcasts, playback: current)
        current.podcastVisible = false
        state.update(current)
        current.podcastID = UUID()
        current.podcastVisible = true // ListenPlayer.play() shows the bar for a new item.
        state.update(current)
        XCTAssertEqual(state.visibleSource(for: current), .podcasts)

        state.dismiss(.podcasts, playback: current)
        current.podcastVisible = false
        current.podcastPlaying = false
        state.update(current)
        current.podcastVisible = true // Explicit showBar() should also be respected.
        state.update(current)
        XCTAssertEqual(state.visibleSource(for: current), .podcasts)
    }

    func testStartingAnotherSourceRestoresDismissedShelf() {
        var state = MediaPlaybackShelf.State()
        var current = playback(podcastID: UUID(), podcastVisible: true,
                               musicID: "song-a", musicPlaying: true)
        state.update(current)
        state.dismiss(.music, playback: current)
        current.musicPlaying = false
        current.podcastPlaying = true
        state.update(current)
        XCTAssertEqual(state.visibleSource(for: current), .podcasts)

        state.dismiss(.podcasts, playback: current)
        current.podcastVisible = false
        current.podcastPlaying = false
        state.update(current)
        current.musicPlaying = true
        state.update(current)
        XCTAssertEqual(state.visibleSource(for: current), .music)
    }

    func testPersistentTabsReplaceDuplicateFloatingMediaNavigation() {
        let state = State()
        var controls = bar(state)
        controls.showsSettings = false
        controls.showsMediaActions = false
        XCTAssertEqual(controls.actions, [.back, .reload])
    }

    func testPhoneHubOwnsSettingsInsteadOfDuplicatingItInChatControls() {
        let state = State()
        var controls = bar(state)
        controls.showsSettings = false
        XCTAssertFalse(controls.actions.contains(.settings))
        XCTAssertEqual(controls.actions, [.back, .reload, .music, .listen])
    }

    func testOpeningControlsAcknowledgesHintAndDoesNotNavigate() {
        let state = State()
        XCTAssertFalse(state.defaults.bool(forKey: AppControlsBar.hintAcknowledgedKey))
        XCTAssertTrue(bar(state).isVisible, "Only the first-use coachmark is initially visible")
        bar(state).reveal()
        XCTAssertTrue(state.expanded)
        XCTAssertTrue(state.defaults.bool(forKey: AppControlsBar.hintAcknowledgedKey))
        XCTAssertTrue(state.actions.isEmpty)
        // Learning the menu survives view recreation / another server.
        let reopened = State(defaults: state.defaults)
        XCTAssertTrue(reopened.defaults.bool(forKey: AppControlsBar.hintAcknowledgedKey))
        XCTAssertFalse(reopened.expanded)
    }

    func testDismissingHintDoesNotOpenControlsOrSettings() {
        let state = State()
        bar(state).dismissHint()
        XCTAssertTrue(state.defaults.bool(forKey: AppControlsBar.hintAcknowledgedKey))
        XCTAssertFalse(state.expanded)
        XCTAssertTrue(state.actions.isEmpty)
        XCTAssertFalse(bar(state).isVisible, "Dismissing the teacher leaves no permanent chrome")
        bar(state).reveal()
        XCTAssertTrue(state.expanded, "The pull/accessibility reveal remains usable after dismissing the hint")
    }

    func testEachControlClosesTheFloatingBarAndLeavesNoChrome() {
        for action in AppControlAction.allCases {
            let state = State()
            bar(state).reveal()
            bar(state, canGoBack: true).activate(action)
            XCTAssertEqual(state.actions, [action])
            XCTAssertFalse(state.expanded)
            XCTAssertFalse(bar(state).isVisible)
            XCTAssertTrue(state.defaults.bool(forKey: AppControlsBar.hintAcknowledgedKey))
        }
    }

    func testOpeningDoesNotResetAnAlreadyAcknowledgedHint() {
        let state = State()
        bar(state).dismissHint()
        bar(state).reveal()
        state.expanded = false
        bar(state).reveal()
        XCTAssertTrue(state.expanded)
        XCTAssertTrue(state.defaults.bool(forKey: AppControlsBar.hintAcknowledgedKey))
    }

    func testHiddenMacWindowUsesBackgroundPhaseWithoutDiscardingTheScene() {
        for phase in [ScenePhase.active, .inactive, .background] {
            XCTAssertEqual(MacLocalServiceBridge.effectiveScenePhase(phase, isMainWindowVisible: false), .background,
                           "A retained hidden scene must not poll or count as foreground attendance")
            XCTAssertEqual(MacLocalServiceBridge.effectiveScenePhase(phase, isMainWindowVisible: true), phase,
                           "A visible window still follows the real app activation state")
        }
    }

    func testNativePlatformSelectsItsWorkspace() {
        #if os(iOS)
        XCTAssertEqual(WorkspacePlatform(idiom: .pad), .pad)
        XCTAssertEqual(WorkspacePlatform(idiom: .phone), .phone)
        #else
        XCTAssertEqual(WorkspacePlatform.current, .mac)
        XCTAssertTrue(WorkspacePlatform.current.usesWorkspaceChrome)
        #endif
        XCTAssertEqual(WorkspaceLayoutPolicy(platform: .mac, width: 640).sidebarWidth, 220)
    }

    func testUserVisibleAppNameIsExactlyTheProductName() {
        // The Mac app menu, About panel, Dock, Finder and Login Items show the
        // bundle name and file name; the Home screen shows the display name.
        let info = Bundle.main.infoDictionary ?? [:]
        XCTAssertEqual(info["CFBundleName"] as? String, "term-llm")
        XCTAssertEqual(info["CFBundleDisplayName"] as? String, "term-llm")
        XCTAssertEqual(Bundle.main.bundleURL.lastPathComponent, "term-llm.app")
    }

    func testLocalServiceHandoffRejectsInvalidEndpointsAndTokens() {
        let valid = MacLocalServiceBridge.request(baseURL: "http://127.0.0.1:8737/", token: "opaque-token", open: true)
        XCTAssertEqual(valid?.baseURL.absoluteString, "http://127.0.0.1:8737/")
        XCTAssertEqual(valid?.token, "opaque-token")
        let localhost = MacLocalServiceBridge.request(baseURL: "http://localhost:8737", token: "opaque-token", open: true)
        XCTAssertEqual(localhost?.baseURL.absoluteString, "http://localhost:8737/")
        for token in ["", "   ", "line\rbreak", "line\nbreak"] {
            XCTAssertNil(MacLocalServiceBridge.request(baseURL: "http://127.0.0.1:8737/", token: token, open: true))
        }
        for baseURL in ["", "https://127.0.0.1:8737/", "http://example.com:8737/", "http://127.0.0.1/",
                        "http://u:p@127.0.0.1:8737/", "http://127.0.0.1:8737/?token=secret",
                        "http://127.0.0.1:8737/#fragment", "http://127.0.0.1:8737/a/../b"] {
            XCTAssertNil(MacLocalServiceBridge.request(baseURL: baseURL, token: "opaque-token", open: true), baseURL)
        }
    }

    func testLocalServiceHandoffOpenFlagDistinguishesBackgroundInclusion() {
        for open in [true, false] {
            XCTAssertEqual(MacLocalServiceBridge.request(baseURL: "http://127.0.0.1:8737/",
                                                       token: "opaque-token", open: open)?.open, open)
        }
    }

    func testHostedUnitTestsDoNotStartTheRealMacIntegration() {
        // The Mac test host shares the app's defaults and keychain; starting the
        // integration here would add This Mac to the developer's real setup.
        XCTAssertTrue(MacLocalServiceBridge.isHostedTestRun)
    }

    #if os(iOS)
    func testControlsAndTeacherLayouts() async throws {
        let state = State()
        try await render(bar(state), named: "app-controls-first-use")
        bar(state).dismissHint()
        try await render(bar(state), named: "app-controls-collapsed")
        bar(state).reveal()
        try await render(bar(state, canGoBack: true), named: "app-controls-expanded")
        try await render(bar(state).frame(width: 320), named: "app-controls-narrow-expanded")
        let fresh = State()
        try await render(bar(fresh).frame(width: 320).dynamicTypeSize(.accessibility2),
                         named: "app-controls-large-text-hint")
    }

    /// Opt-in against the public demo or a locally served build. The native
    /// overlay must never reserve page space, reload WebKit, or keep chrome
    /// visible once the first-use hint has been acknowledged.
    func testLiveBrowserViewportIsUnchangedByHintAndControls() async throws {
        guard let raw = ProcessInfo.processInfo.environment["TERMLLM_DEMO_E2E_URL"],
              let server = ServerAddress.parse(raw) else {
            throw XCTSkip("Set TERMLLM_DEMO_E2E_URL to exercise the real browser overlay")
        }
        let defaults = UserDefaults.standard
        let oldServer = defaults.object(forKey: "serverURL")
        let oldHint = defaults.object(forKey: AppControlsBar.hintAcknowledgedKey)
        defaults.set(server.absoluteString, forKey: "serverURL")
        defaults.set(true, forKey: AppControlsBar.hintAcknowledgedKey)
        defer {
            defaults.set(oldServer, forKey: "serverURL")
            defaults.set(oldHint, forKey: AppControlsBar.hintAcknowledgedKey)
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = UIHostingController(rootView: ContentView())
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        func findWebView(_ view: UIView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.compactMap(findWebView).first
        }
        try await Task.sleep(for: .milliseconds(300))
        let web = try XCTUnwrap(findWebView(window))
        var ready = false
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("!!document.querySelector('#promptInput')")) as? Bool == true {
                ready = true
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(ready, "The demo composer should load")
        let viewport = web.convert(web.bounds, to: window)
        _ = try await web.evaluateJavaScript("window.__appControlsViewportTest = 'unchanged'")
        func capture(_ name: String) {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        capture("live-demo-controls-hidden")
        defaults.set(false, forKey: AppControlsBar.hintAcknowledgedKey)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(web.convert(web.bounds, to: window), viewport, "The coachmark must overlay, not resize the page")
        capture("live-demo-floating-coachmark")
        let coordinator = try XCTUnwrap(web.navigationDelegate as? BrowserView.Coordinator)
        coordinator.parent.onRevealControls()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(web.convert(web.bounds, to: window), viewport, "Revealing controls must not move the page")
        XCTAssertTrue(defaults.bool(forKey: AppControlsBar.hintAcknowledgedKey))
        let sentinel = try await web.evaluateJavaScript("window.__appControlsViewportTest") as? String
        XCTAssertEqual(sentinel, "unchanged", "Revealing controls must not reload the page")
        capture("live-demo-floating-controls")
    }

    private func render<Content: View>(_ controls: Content, named name: String) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = UIHostingController(rootView:
            Color.gray.opacity(0.08)
                .overlay(Text("Conversation").foregroundStyle(.secondary))
                .overlay(alignment: .top) {
                    controls.padding(.horizontal, 12).padding(.top, 10)
                }
                .tint(.cyan))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(300))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let cgImage = try XCTUnwrap(image.cgImage)
        let pixels = try XCTUnwrap(cgImage.dataProvider?.data as Data?)
        let first = pixels.prefix(4)
        XCTAssertTrue(stride(from: 0, to: pixels.count - 4, by: 4 * 97).contains {
            pixels[$0..<$0 + 4] != first
        }, "\(name) should not render a blank screen")
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    #endif
}
