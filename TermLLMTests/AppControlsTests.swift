import SwiftUI
import WebKit
import XCTest
@testable import TermLLM

@MainActor
final class AppControlsTests: XCTestCase {
    func testThemeAccentAdaptsAndKeepsWhiteButtonLabelsLegible() throws {
        let accent = try XCTUnwrap(UIColor(named: "AccentColor", in: .main, compatibleWith: nil))
        func luminance(_ color: UIColor) -> Double {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            XCTAssertTrue(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
            XCTAssertEqual(alpha, 1)
            func linear(_ value: CGFloat) -> Double {
                let value = Double(value)
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }
        let light = luminance(accent.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)))
        let dark = luminance(accent.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)))
        XCTAssertGreaterThan(dark, light, "Dark mode needs a lighter accent, not a forced appearance")
        for value in [light, dark] {
            XCTAssertGreaterThanOrEqual(1.05 / (value + 0.05), 4.5, "White prominent-button labels must stay readable")
        }
    }

    func testFridayBatOnlyAnimatesWhileVisibleActiveAndMotionAllowed() {
        for visible in [false, true] {
            for active in [false, true] {
                for reduceMotion in [false, true] {
                    let mode = FridayBatFlight.mode(visible: visible, active: active, reduceMotion: reduceMotion)
                    XCTAssertEqual(mode == .flight, visible && active && !reduceMotion)
                    XCTAssertEqual(mode == .parked, visible && active && reduceMotion)
                    XCTAssertEqual(mode == .hidden, !visible || !active)
                }
            }
        }
    }

    func testFridayBatCrossesOnceWithinSkyBandAndBanksGently() {
        for width: CGFloat in [280, 360, 900] {
            var previousX = -CGFloat.infinity
            for frame in 0...330 {
                let time = Double(frame) / 60
                let point = FridayBatFlight.position(at: time, width: width)
                XCTAssertGreaterThanOrEqual(point.x, previousX)
                XCTAssertTrue((10...23).contains(point.y))
                XCTAssertLessThanOrEqual(abs(FridayBatFlight.bank(at: time, width: width)), 14 * .pi / 180)
                previousX = point.x
            }
            XCTAssertLessThan(FridayBatFlight.position(at: 0, width: width).x, -19)
            XCTAssertGreaterThan(FridayBatFlight.position(at: FridayBatFlight.duration, width: width).x, width + 19)
            XCTAssertEqual(FridayBatFlight.position(at: 100, width: width),
                           FridayBatFlight.position(at: FridayBatFlight.duration, width: width))
        }
        XCTAssertEqual(FridayBatFlight.samples.first, 0)
        XCTAssertEqual(FridayBatFlight.samples.last, FridayBatFlight.duration)
    }

    func testFridayBatHasFiveHertzFlutterAndStillGlides() {
        for start in [0.0, 1.4, 2.9, 4.5] {
            XCTAssertEqual(FridayBatFlight.fold(at: start), 0, accuracy: 0.001)
            XCTAssertEqual(FridayBatFlight.fold(at: start + 0.1), 1, accuracy: 0.001)
            XCTAssertEqual(FridayBatFlight.fold(at: start + 0.2), 0, accuracy: 0.001)
        }
        for time in [0.85, 1.1, 1.35, 2.45, 2.7, 2.85, 3.95, 4.2, 4.45] {
            XCTAssertEqual(FridayBatFlight.fold(at: time), 0)
        }
    }

    func testFridayBatWingPosesShareTopologyAndNeverFlattenIntoADash() {
        func elements(_ path: CGPath) -> [CGPathElementType] {
            var result: [CGPathElementType] = []
            path.applyWithBlock { result.append($0.pointee.type) }
            return result
        }
        let extended = FridayBatFlight.wingPath(fold: 0)
        for fold: CGFloat in [0, 0.5, 1] {
            let path = FridayBatFlight.wingPath(fold: fold)
            XCTAssertEqual(elements(path), elements(extended))
            XCTAssertGreaterThan(path.boundingBoxOfPath.height, 14)
            XCTAssertGreaterThan(path.boundingBoxOfPath.width, 18)
            for x: CGFloat in [-2.5, 2.5] {
                for y: CGFloat in [0, 1, 2] {
                    XCTAssertTrue(path.contains(CGPoint(x: x, y: y)), "Wing roots must join the body, not cancel its fill")
                }
            }
        }
        XCTAssertLessThan(FridayBatFlight.wingPath(fold: 1).boundingBoxOfPath.width,
                          extended.boundingBoxOfPath.width * 0.7)
    }

    func testFridayBatLayerSchedulesOneFinitePassAndCancelsEvenDuringDelay() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 360, height: 100))
        let view = FridayBatView(frame: CGRect(x: 0, y: 0, width: 360, height: 32))
        window.addSubview(view)
        view.layoutIfNeeded()
        view.mode = .parked
        XCTAssertNil(view.bat.animationKeys(), "Reduce Motion must not schedule even a delayed animation")
        XCTAssertEqual(view.bat.opacity, 1)
        view.mode = .flight
        let flight = try XCTUnwrap(view.bat.animation(forKey: "flight") as? CAAnimationGroup)
        XCTAssertEqual(flight.duration, 5.5)
        XCTAssertEqual(flight.repeatCount, 0)
        XCTAssertTrue(flight.isRemovedOnCompletion)
        XCTAssertEqual(flight.preferredFrameRateRange.preferred, 30)
        XCTAssertGreaterThan(flight.beginTime, CACurrentMediaTime())
        XCTAssertEqual(view.bat.opacity, 0, "Hidden model layer is restored after the one pass")
        view.bat.removeAllAnimations() // Simulate completion, then an ordinary SwiftUI/layout update.
        view.mode = .flight
        view.setNeedsLayout()
        view.layoutIfNeeded()
        XCTAssertNil(view.bat.animationKeys(), "Layout must not restart a completed flight")
        view.mode = .hidden
        view.mode = .flight
        XCTAssertNotNil(view.bat.animationKeys(), "A new active appearance rearms the pass")
        view.mode = .parked
        XCTAssertNil(view.bat.animationKeys(), "Reduce Motion cancels an in-flight or delayed pass")
        view.mode = .flight
        view.removeFromSuperview()
        XCTAssertNil(view.bat.animationKeys(), "Detached onboarding cannot keep pending work")
        view.mode = .hidden
        XCTAssertEqual(view.bat.opacity, 0)
    }

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
}
