import SwiftUI
import WebKit
import XCTest
@testable import TermLLM

// Exercise the real coordinator with a recording web view: no network or
// private WebKit process-killing API is needed to simulate termination.
@MainActor
final class BrowserLifecycleTests: XCTestCase {
    private let server = URL(string: "https://example.com/ui/")!

    private final class State {
        var loading = false
        var canGoBack = false
        var error: String?
        var loginRequired = false
        var reveals = 0
    }

    private func browser(_ state: State, phase: ScenePhase = .active,
                         signingIn: Bool = false, reload: Int = 0, back: Int = 0,
                         authenticated: Int = 0, url: URL? = nil,
                         voiceLaunch: VoiceBrowserLaunch? = nil,
                         onVoiceFinished: @escaping (UUID, String?) -> Void = { _, _ in }) -> BrowserView {
        BrowserView(url: url ?? server,
                    loading: Binding(get: { state.loading }, set: { state.loading = $0 }),
                    canGoBack: Binding(get: { state.canGoBack }, set: { state.canGoBack = $0 }),
                    loadError: Binding(get: { state.error }, set: { state.error = $0 }),
                    loginRequired: Binding(get: { state.loginRequired }, set: { state.loginRequired = $0 }),
                    reloadCount: reload, backCount: back, authenticatedCount: authenticated,
                    scenePhase: phase, isSigningIn: signingIn,
                    onLoginRequired: {}, onRevealControls: { state.reveals += 1 },
                    voiceLaunch: voiceLaunch, onVoiceLaunchFinished: onVoiceFinished)
    }

    private func coordinator(_ parent: BrowserView) -> BrowserView.Coordinator {
        let coordinator = parent.makeCoordinator()
        coordinator.loadedURL = parent.url
        return coordinator
    }

    private final class RecordingWebView: WKWebView {
        var currentURL: URL?
        var hasBackItem = false
        var requests: [URLRequest] = []
        var reloads = 0
        var backs = 0
        override var url: URL? { currentURL }
        override var canGoBack: Bool { hasBackItem }
        override func load(_ request: URLRequest) -> WKNavigation? {
            requests.append(request)
            return nil
        }
        override func reload() -> WKNavigation? {
            reloads += 1
            return nil
        }
        override func goBack() -> WKNavigation? {
            backs += 1
            return nil
        }
    }

    private func webView(_ url: URL? = nil) -> RecordingWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = RecordingWebView(frame: .zero, configuration: config)
        view.currentURL = url
        return view
    }

    private func linkedMediaBrowser() -> BrowserView {
        var parent = browser(State(), url: URL(string: "http://localhost:43212/ui/")!)
        parent.connectionMount = parent.url
        parent.isLinkedDevices = true
        return parent
    }

    private func linkedCapture(_ parent: BrowserView, scheme: String = "http", host: String = "localhost",
                               port: Int = 43212, frame: String? = "http://localhost:43212/ui/chat/7",
                               mainFrame: Bool = true, type: WKMediaCaptureType = .microphone) -> WKPermissionDecision {
        parent.mediaCaptureDecision(originScheme: scheme, originHost: host, originPort: port,
                                    frameURL: frame.flatMap(URL.init(string:)), isMainFrame: mainFrame, type: type)
    }

    func testLinkedMicrophonePromptsOnlyForMainFrameWithinConfiguredMount() {
        let parent = linkedMediaBrowser()
        for path in ["/ui", "/ui/", "/ui/chat/7?new=1"] {
            XCTAssertEqual(linkedCapture(parent, frame: "http://localhost:43212" + path), .prompt)
        }
        XCTAssertEqual(linkedCapture(parent, mainFrame: false), .deny)
        XCTAssertEqual(linkedCapture(parent, frame: nil), .deny)
        for path in ["/", "/other/", "/ui-other/", "/ui/../other", "/ui/%2e%2e/other",
                     "/ui/chat%2f7", "/ui/%252e%252e/other"] {
            XCTAssertEqual(linkedCapture(parent, frame: "http://localhost:43212" + path), .deny, path)
        }
    }

    func testLinkedMicrophoneRequiresExactSecurityOriginAndFrameOrigin() {
        let parent = linkedMediaBrowser()
        XCTAssertEqual(linkedCapture(parent, scheme: "https"), .deny)
        XCTAssertEqual(linkedCapture(parent, host: "other.example"), .deny)
        XCTAssertEqual(linkedCapture(parent, host: "127.0.0.1"), .deny)
        XCTAssertEqual(linkedCapture(parent, port: 43213), .deny)
        XCTAssertEqual(linkedCapture(parent, port: 0), .deny)
        for frame in ["https://localhost:43212/ui/", "http://localhost:43213/ui/",
                      "http://localhost/ui/", "http://127.0.0.1:43212/ui/",
                      "http://other.example:43212/ui/", "http://user@localhost:43212/ui/"] {
            XCTAssertEqual(linkedCapture(parent, frame: frame), .deny, frame)
        }
    }

    func testLinkedCaptureDeniesCameraAndCombinedRequestsEvenForTrustedMainFrame() {
        let parent = linkedMediaBrowser()
        for type: WKMediaCaptureType in [.camera, .cameraAndMicrophone] {
            XCTAssertEqual(linkedCapture(parent, type: type), .deny)
            XCTAssertEqual(linkedCapture(parent, mainFrame: false, type: type), .deny)
        }
    }

    func testLinkedCaptureFailsClosedWithoutValidatedConfiguredBridgeMount() {
        var parent = linkedMediaBrowser()
        parent.connectionMount = nil
        XCTAssertEqual(linkedCapture(parent), .deny)
        for mount in ["https://localhost:43212/ui/", "http://127.0.0.1:43212/ui/",
                      "http://other.example:43212/ui/", "http://localhost/ui/",
                      "http://localhost:80/ui/", "http://localhost:43213/ui/",
                      "http://localhost:43212/other/", "http://localhost:43212/ui/?scope=1"] {
            parent.connectionMount = URL(string: mount)!
            XCTAssertEqual(linkedCapture(parent), .deny, mount)
        }
        // A valid mount alone cannot authorize a differently configured page.
        parent = browser(State(), url: URL(string: "http://localhost:43213/ui/")!)
        parent.isLinkedDevices = true
        parent.connectionMount = URL(string: "http://localhost:43212/ui/")!
        XCTAssertEqual(linkedCapture(parent, port: 43213, frame: "http://localhost:43213/ui/"), .deny)
    }

    func testMediaCaptureMasterSwitchDeniesBothLinkedAndOrdinarySources() {
        for var parent in [linkedMediaBrowser(), browser(State())] {
            parent.allowsMediaCapture = false
            for type: WKMediaCaptureType in [.microphone, .camera, .cameraAndMicrophone] {
                XCTAssertEqual(parent.mediaCaptureDecision(originScheme: parent.url.scheme!, originHost: parent.url.host!,
                                                          originPort: parent.url.port ?? 443, frameURL: parent.url,
                                                          isMainFrame: true, type: type), .deny)
            }
        }
    }

    func testOrdinaryMediaCapturePolicyRemainsUnchanged() {
        for address in ["https://example.com/ui/", "http://example.com/ui/"] {
            let parent = browser(State(), url: URL(string: address)!)
            let scheme = parent.url.scheme!
            // Existing ordinary-source behavior does not require a main frame,
            // request URL or configured mount, and accepts the default origin port.
            for mainFrame in [true, false] {
                for port in [0, scheme == "https" ? 443 : 80] {
                    XCTAssertEqual(parent.mediaCaptureDecision(originScheme: scheme, originHost: "example.com",
                                                              originPort: port, frameURL: nil, isMainFrame: mainFrame,
                                                              type: .microphone), .grant)
                }
            }
            for type: WKMediaCaptureType in [.camera, .cameraAndMicrophone] {
                XCTAssertEqual(parent.mediaCaptureDecision(originScheme: scheme, originHost: "example.com",
                                                          originPort: 0, frameURL: parent.url, isMainFrame: true,
                                                          type: type), .prompt)
            }
            for (originScheme, host, port) in [(scheme, "other.example", 0), (scheme, "example.com", 43212),
                                             (scheme == "https" ? "http" : "https", "example.com", 0)] {
                XCTAssertEqual(parent.mediaCaptureDecision(originScheme: originScheme, originHost: host,
                                                          originPort: port, frameURL: parent.url, isMainFrame: true,
                                                          type: .microphone), .prompt)
            }
        }
    }

    func testRetainedChatContextIsReportedOnlyForCommittedDocuments() {
        let state = State()
        var commits: [URL] = []
        var parent = browser(state)
        parent.onDocumentCommitted = { commits.append($0) }
        let coordinator = coordinator(parent)
        let view = webView(server.appendingPathComponent("chat/7"))
        coordinator.webView(view, didStartProvisionalNavigation: nil)
        coordinator.webView(view, didFailProvisionalNavigation: nil,
                            withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
        XCTAssertTrue(commits.isEmpty)
        coordinator.webView(view, didCommit: nil)
        XCTAssertEqual(commits, [view.url!])
        view.currentURL = server.appendingPathComponent("chat/8")
        coordinator.webView(view, didStartProvisionalNavigation: nil)
        XCTAssertEqual(commits.count, 1, "Attempted URLs must not replace the retained document context")
        coordinator.webView(view, didCommit: nil)
        XCTAssertEqual(commits.last, view.url)
    }

    func testProvisionalFailureCancelAndDownloadKeepNativeDocumentGenerationUntilCommit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "provisional-push-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let push = PushCenter(defaults: defaults, identities: PushIdentityStore(storage: InMemoryPushStorage()),
            relayTransport: { _ in XCTFail("No relay request expected"); throw PushError.relayUnavailable }, registerForRemote: {},
            deliveries: PushDeliveryStore(url: directory.appendingPathComponent("state.json")), inbox: FakePushInbox())
        let state = State()
        var parent = browser(state); parent.push = push
        let coordinator = coordinator(parent)
        let view = webView(server)
        coordinator.syncPushBridge(url: server, center: push, controller: view.configuration.userContentController)
        let bridge = try XCTUnwrap(coordinator.pushBridge)
        for error in [NSURLErrorCancelled, NSURLErrorNotConnectedToInternet] {
            coordinator.webView(view, didStartProvisionalNavigation: nil)
            coordinator.webView(view, didFailProvisionalNavigation: nil, withError: NSError(domain: NSURLErrorDomain, code: error))
            XCTAssertEqual(bridge.documentGeneration, 0)
        }
        coordinator.webView(view, didStartProvisionalNavigation: nil) // response becomes download, no document commit
        XCTAssertEqual(bridge.documentGeneration, 0)
        coordinator.webView(view, didCommit: nil)
        XCTAssertEqual(bridge.documentGeneration, 1)
        coordinator.tearDown()
    }

    func testControlsPullUsesViewportAtTopScrolledAndBouncingOffsets() {
        for offset: CGFloat in [0, 420, -90] {
            var pull = BrowserControlsPullGesture()
            XCTAssertFalse(pull.update(state: .began, location: CGPoint(x: 20, y: offset + 60),
                                       translation: .zero, boundsMinY: offset))
            XCTAssertFalse(pull.update(state: .changed, location: CGPoint(x: 20, y: offset + 127),
                                       translation: CGPoint(x: 0, y: 67), boundsMinY: offset))
            // The outer scroll view may move too; eligibility must remain latched.
            let movedOffset = offset - 30
            XCTAssertTrue(pull.update(state: .changed, location: CGPoint(x: 20, y: movedOffset + 128),
                                      translation: CGPoint(x: 0, y: 68), boundsMinY: movedOffset))
        }
    }

    func testControlsPullRecoversStartBeforeBeganRecognitionSlop() {
        for offset: CGFloat in [0, 420, -90] {
            var pull = BrowserControlsPullGesture()
            // Started at 135, but is already outside the zone when UIKit recognizes it.
            XCTAssertFalse(pull.update(state: .began, location: CGPoint(x: 0, y: offset + 147),
                                       translation: CGPoint(x: 0, y: 12), boundsMinY: offset))
            XCTAssertTrue(pull.update(state: .changed, location: CGPoint(x: 0, y: offset + 205),
                                      translation: CGPoint(x: 0, y: 70), boundsMinY: offset))
        }
        var pull = BrowserControlsPullGesture()
        // A delayed first callback can already meet the deliberate pull threshold.
        XCTAssertTrue(pull.update(state: .began, location: CGPoint(x: 0, y: 200),
                                  translation: CGPoint(x: 0, y: 70), boundsMinY: 0))
        XCTAssertFalse(pull.update(state: .changed, location: CGPoint(x: 0, y: 210),
                                   translation: CGPoint(x: 0, y: 80), boundsMinY: 0))
    }

    func testControlsPullRejectsStartsOutsideTopZone() {
        for offset: CGFloat in [0, 420, -90] {
            for start: CGFloat in [-1, 140, 260] {
                var pull = BrowserControlsPullGesture()
                // Include upward recognition slop: a touch starting below the zone
                // must not become eligible just because it moves into the zone.
                XCTAssertFalse(pull.update(state: .began, location: CGPoint(x: 0, y: offset + start - 12),
                                           translation: CGPoint(x: 0, y: -12), boundsMinY: offset))
                XCTAssertFalse(pull.update(state: .changed, location: CGPoint(x: 0, y: offset + start + 100),
                                           translation: CGPoint(x: 0, y: 100), boundsMinY: offset))
            }
        }
    }

    func testControlsPullRequiresDeliberateDownwardVerticalMovement() {
        for translation in [CGPoint.zero, CGPoint(x: 0, y: 67), CGPoint(x: 0, y: -100),
                            CGPoint(x: 100, y: 10), CGPoint(x: -100, y: 70),
                            CGPoint(x: 35, y: 70), CGPoint(x: -35, y: 70)] {
            var pull = BrowserControlsPullGesture()
            XCTAssertFalse(pull.update(state: .began, location: CGPoint(x: 0, y: 60),
                                       translation: .zero, boundsMinY: 0))
            XCTAssertFalse(pull.update(state: .changed, location: CGPoint(x: translation.x, y: 60 + translation.y),
                                       translation: translation, boundsMinY: 0))
        }
        for x: CGFloat in [-30, 30] {
            var pull = BrowserControlsPullGesture()
            XCTAssertFalse(pull.update(state: .began, location: CGPoint(x: 0, y: 60),
                                       translation: .zero, boundsMinY: 0))
            XCTAssertTrue(pull.update(state: .changed, location: CGPoint(x: x, y: 130),
                                      translation: CGPoint(x: x, y: 70), boundsMinY: 0))
        }
    }

    func testControlsPullFiresOnceAndTerminalStatesResetEligibility() {
        for terminal: UIGestureRecognizer.State in [.ended, .cancelled, .failed] {
            for triggerBeforeReset in [false, true] {
                var pull = BrowserControlsPullGesture()
                XCTAssertFalse(pull.update(state: .began, location: CGPoint(x: 0, y: 60),
                                           translation: .zero, boundsMinY: 0))
                if triggerBeforeReset {
                    XCTAssertTrue(pull.update(state: .changed, location: CGPoint(x: 0, y: 130),
                                              translation: CGPoint(x: 0, y: 70), boundsMinY: 0))
                    XCTAssertFalse(pull.update(state: .changed, location: CGPoint(x: 0, y: 160),
                                               translation: CGPoint(x: 0, y: 100), boundsMinY: 0))
                }
                XCTAssertFalse(pull.update(state: terminal, location: CGPoint(x: 0, y: 160),
                                           translation: CGPoint(x: 0, y: 100), boundsMinY: 0))
                XCTAssertFalse(pull.update(state: .changed, location: CGPoint(x: 0, y: 160),
                                           translation: CGPoint(x: 0, y: 100), boundsMinY: 0))
                XCTAssertFalse(pull.update(state: .began, location: CGPoint(x: 0, y: 60),
                                           translation: .zero, boundsMinY: 0))
                XCTAssertTrue(pull.update(state: .changed, location: CGPoint(x: 0, y: 130),
                                          translation: CGPoint(x: 0, y: 70), boundsMinY: 0))
            }
        }
    }

    private final class RecordingPanGesture: UIPanGestureRecognizer {
        var recordedState: UIGestureRecognizer.State = .possible
        var recordedLocation = CGPoint.zero
        var recordedTranslation = CGPoint.zero
        override var state: UIGestureRecognizer.State {
            get { recordedState }
            set { recordedState = newValue }
        }
        override func location(in view: UIView?) -> CGPoint { recordedLocation }
        override func translation(in view: UIView?) -> CGPoint { recordedTranslation }
    }

    func testControlsPullCoordinatorRevealsOnceWhileScrolledAndResetsOnTeardown() {
        let state = State()
        let coordinator = coordinator(browser(state))
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        scrollView.contentSize = CGSize(width: 320, height: 1500)
        scrollView.contentOffset.y = 420
        let pan = RecordingPanGesture()
        scrollView.addGestureRecognizer(pan)
        pan.recordedState = .began
        pan.recordedLocation = CGPoint(x: 20, y: 420 + 147)
        pan.recordedTranslation = CGPoint(x: 0, y: 12)
        coordinator.handlePull(pan)
        XCTAssertEqual(state.reveals, 0)
        pan.recordedState = .changed
        pan.recordedLocation.y = 420 + 205
        pan.recordedTranslation.y = 70
        coordinator.handlePull(pan)
        coordinator.handlePull(pan)
        XCTAssertEqual(state.reveals, 1)
        XCTAssertTrue(coordinator.gestureRecognizer(pan,
                      shouldRecognizeSimultaneouslyWith: scrollView.panGestureRecognizer))
        coordinator.tearDown()
        coordinator.handlePull(pan)
        XCTAssertEqual(state.reveals, 1)
        pan.recordedState = .began
        pan.recordedLocation.y = 420 + 60
        pan.recordedTranslation = .zero
        coordinator.handlePull(pan)
        pan.recordedState = .cancelled
        coordinator.handlePull(pan)
        pan.recordedState = .changed
        pan.recordedTranslation.y = 70
        coordinator.handlePull(pan)
        XCTAssertEqual(state.reveals, 1)
        pan.recordedState = .began
        pan.recordedLocation.y = 420 + 60
        pan.recordedTranslation = .zero
        coordinator.handlePull(pan)
        pan.recordedState = .changed
        pan.recordedTranslation.y = 70
        coordinator.handlePull(pan)
        XCTAssertEqual(state.reveals, 2)
    }

    func testHealthyForegroundAndOrdinaryUpdatesDoNotReload() {
        let state = State()
        let coordinator = coordinator(browser(state))
        let view = webView(server)
        for phase: ScenePhase in [.inactive, .background, .active, .active] {
            coordinator.update(view, parent: browser(state, phase: phase))
        }
        XCTAssertTrue(view.requests.isEmpty)
        XCTAssertEqual(view.reloads, 0)
    }

    func testActiveTerminationRecoversCurrentRouteWithGETOnce() {
        let state = State()
        let coordinator = coordinator(browser(state))
        let route = URL(string: "https://example.com/ui/sessions/42")!
        let view = webView(route)
        coordinator.webViewWebContentProcessDidTerminate(view)
        coordinator.update(view, parent: browser(state))
        XCTAssertEqual(view.requests.map(\.url), [route])
        XCTAssertEqual(view.requests.first?.httpMethod, "GET")
        XCTAssertEqual(view.reloads, 0)
    }

    func testBackgroundTerminationWaitsForActiveScene() async {
        let state = State()
        let coordinator = coordinator(browser(state, phase: .background))
        let view = webView(server)
        coordinator.webViewWebContentProcessDidTerminate(view)
        coordinator.update(view, parent: browser(state, phase: .inactive))
        XCTAssertTrue(view.requests.isEmpty)
        coordinator.update(view, parent: browser(state))
        coordinator.update(view, parent: browser(state))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(view.requests.count, 1)
    }

    func testRepeatedCrashesStopUntilRetryEvenAfterDidFinish() {
        let state = State()
        let coordinator = coordinator(browser(state))
        let view = webView(server)
        coordinator.webViewWebContentProcessDidTerminate(view)
        coordinator.webView(view, didFinish: nil)
        coordinator.webViewWebContentProcessDidTerminate(view)
        XCTAssertEqual(view.requests.count, 1)
        XCTAssertNotNil(state.error)
        XCTAssertFalse(state.loading)
        coordinator.update(view, parent: browser(state, reload: 1))
        XCTAssertEqual(view.reloads, 1)
        // Navigation callbacks clear the recovery screen, as with ordinary Retry.
        coordinator.webView(view, didStartProvisionalNavigation: nil)
        XCTAssertNil(state.error)
        coordinator.webViewWebContentProcessDidTerminate(view)
        XCTAssertEqual(view.requests.count, 2)
    }

    func testLaterIndependentTerminationCanRecover() {
        let state = State()
        let coordinator = coordinator(browser(state, phase: .background))
        let view = webView(server)
        coordinator.webViewWebContentProcessDidTerminate(view)
        coordinator.parent = browser(state)
        coordinator.recoverIfNeeded(view, now: 100)
        coordinator.parent = browser(state, phase: .background)
        coordinator.webViewWebContentProcessDidTerminate(view)
        coordinator.parent = browser(state)
        coordinator.recoverIfNeeded(view, now: 131)
        XCTAssertEqual(view.requests.count, 2)
        XCTAssertNil(state.error)
    }

    func testRecoveryDoesNotOverrideHTTPOrSignInScreens() {
        for status in [401, 503] {
            let state = State()
            let coordinator = coordinator(browser(state))
            let view = webView(server)
            // WKNavigationResponse cannot be constructed outside WebKit.
            // Model the state set by its already-tested HTTP recovery mapping.
            coordinator.rejectedHTTPResponse = true
            state.loginRequired = status == 401
            state.error = status == 401 ? nil : "The server returned HTTP 503."
            let originalError = state.error
            coordinator.webViewWebContentProcessDidTerminate(view)
            coordinator.update(view, parent: browser(state))
            XCTAssertTrue(view.requests.isEmpty)
            XCTAssertEqual(state.error, originalError)
            XCTAssertEqual(state.loginRequired, status == 401)
        }
    }

    func testPasskeyFlowDefersRecoveryAndAuthenticationCoalescesReload() {
        let state = State()
        let coordinator = coordinator(browser(state, signingIn: true))
        let view = webView(server)
        coordinator.webViewWebContentProcessDidTerminate(view)
        XCTAssertTrue(view.requests.isEmpty)
        coordinator.update(view, parent: browser(state, reload: 1, authenticated: 1))
        coordinator.update(view, parent: browser(state, reload: 1, authenticated: 1))
        XCTAssertEqual(view.requests.map(\.url), [server])
        XCTAssertEqual(view.reloads, 0)
    }

    func testServerChangeDiscardsPendingOldRouteAndCoalescesCommands() {
        let state = State()
        let coordinator = coordinator(browser(state, phase: .background))
        let view = webView(URL(string: "https://example.com/ui/sessions/old")!)
        coordinator.webViewWebContentProcessDidTerminate(view)
        let other = URL(string: "https://other.example/ui/")!
        coordinator.update(view, parent: browser(state, reload: 1, back: 1, authenticated: 1, url: other))
        coordinator.update(view, parent: browser(state, reload: 1, back: 1, authenticated: 1, url: other))
        XCTAssertEqual(view.requests.map(\.url), [other])
        XCTAssertEqual(view.reloads, 0)
        XCTAssertEqual(view.backs, 0)
    }

    func testRecreatedCoordinatorDoesNotReplayOldCommands() {
        let state = State()
        let parent = browser(state, reload: 4, back: 2, authenticated: 3)
        let coordinator = coordinator(parent)
        let view = webView(server)
        view.hasBackItem = true
        coordinator.update(view, parent: parent)
        XCTAssertTrue(view.requests.isEmpty)
        XCTAssertEqual(view.reloads, 0)
        XCTAssertEqual(view.backs, 0)
    }

    func testRecoveryFallsBackForMissingForeignAndLoginURLs() {
        for url in [nil, URL(string: "https://other.example/ui/"),
                    URL(string: "https://example.com/ui/auth/login")] {
            let state = State()
            let coordinator = coordinator(browser(state))
            let view = webView(url)
            coordinator.webViewWebContentProcessDidTerminate(view)
            XCTAssertEqual(view.requests.map(\.url), [server])
        }
    }

    func testVoiceLaunchAllowsOnlyItsRootAndMaterializedChatRoutes() {
        let request = VoiceBrowserLaunch(id: UUID(), url: URL(string: "https://example.com/hub/node/jarvis/?new=1")!)
        let root = URL(string: "https://example.com/hub/node/jarvis/")!
        let chat = URL(string: "https://example.com/hub/node/jarvis/chat/42")!
        XCTAssertTrue(request.allowsPath(root, afterStart: false))
        XCTAssertFalse(request.allowsPath(chat, afterStart: false))
        XCTAssertTrue(request.allowsPath(chat, afterStart: true))
        for path in ["/hub/node/other/chat/42", "/hub/node/jarvis/auth/login",
                     "/hub/node/jarvis/chat/", "/hub/node/jarvis/chat/42/other"] {
            XCTAssertFalse(request.allowsPath(URL(string: "https://example.com" + path)!, afterStart: true))
        }
        let direct = VoiceBrowserLaunch(id: UUID(), url: URL(string: "https://example.com/ui/?new=1")!)
        XCTAssertTrue(direct.allowsPath(URL(string: "https://example.com/ui/chat/session-id")!, afterStart: true))
    }

    func testVoiceCommandPreservesExistingCallAndDoesNotReplay() async throws {
        let state = State()
        let view = webView(server)
        let waiter = VoiceNavigationWaiter()
        view.navigationDelegate = waiter
        view.loadHTMLString("<section aria-label='Live voice'><button>Stop</button></section><textarea>unsent text</textarea>", baseURL: server)
        try await waiter.wait()
        let request = VoiceBrowserLaunch(id: UUID(), url: URL(string: "https://example.com/ui/?new=1")!)
        let completed = expectation(description: "existing call preserved")
        let parent = browser(state, voiceLaunch: request) { id, error in
            XCTAssertEqual(id, request.id)
            XCTAssertNil(error)
            completed.fulfill()
        }
        let coordinator = coordinator(parent)
        coordinator.update(view, parent: parent)
        await fulfillment(of: [completed], timeout: 5)
        coordinator.update(view, parent: parent)
        XCTAssertTrue(view.requests.isEmpty)
        coordinator.tearDown()
    }

    func testVoiceDestinationSurvivesPasskeyCompletionAndCoalescesUpdates() async throws {
        let state = State()
        let view = webView(server)
        let waiter = VoiceNavigationWaiter()
        view.navigationDelegate = waiter
        view.loadHTMLString("<p>No call</p>", baseURL: server)
        try await waiter.wait()
        let request = VoiceBrowserLaunch(id: UUID(), url: URL(string: "https://example.com/ui/?new=1")!)
        let parent = browser(state, voiceLaunch: request)
        let coordinator = coordinator(parent)
        coordinator.update(view, parent: parent)
        for _ in 0..<100 where view.requests.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(view.requests.map(\.url), [request.url])
        coordinator.update(view, parent: browser(state, authenticated: 1, voiceLaunch: request))
        XCTAssertEqual(view.requests.map(\.url), [request.url, request.url])
        // Ordinary updates after authentication must not navigate again.
        coordinator.update(view, parent: browser(state, authenticated: 1, voiceLaunch: request))
        XCTAssertEqual(view.requests.count, 2)
        coordinator.tearDown()
    }

    func testVoiceCommandRejectsForeignDestination() async {
        let state = State()
        let request = VoiceBrowserLaunch(id: UUID(), url: URL(string: "https://foreign.example/?new=1")!)
        let completed = expectation(description: "foreign destination rejected")
        let parent = browser(state, voiceLaunch: request) { id, error in
            XCTAssertEqual(id, request.id)
            XCTAssertNotNil(error)
            completed.fulfill()
        }
        let coordinator = coordinator(parent)
        let view = webView(server)
        coordinator.update(view, parent: parent)
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertTrue(view.requests.isEmpty)
        coordinator.tearDown()
    }

    func testVoiceScriptStartsOnlyEnabledVisibleLiveButtonAndNeverStopsCall() async throws {
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let waiter = VoiceNavigationWaiter()
        view.navigationDelegate = waiter
        view.loadHTMLString("""
        <html><body>
        <button aria-label="Start live voice" disabled>Live</button>
        <script>
        window.clicks = 0;
        document.querySelector('button').onclick = function() {
            window.clicks++;
            this.setAttribute('aria-label', 'Stop live voice');
        };
        </script>
        </body></html>
        """, baseURL: server)
        try await waiter.wait()
        // The test web view is not presented by the test host. Model foreground.
        _ = try await view.callAsyncJavaScript("Object.defineProperty(document, 'visibilityState', {get: () => 'visible'});", contentWorld: .page)
        let disabled = try await view.callAsyncJavaScript(VoiceLaunchScript.start, contentWorld: .page) as? String
        XCTAssertEqual(disabled, "waiting")
        _ = try await view.callAsyncJavaScript("document.querySelector('button').disabled = false;", contentWorld: .page)
        let clicked = try await view.callAsyncJavaScript(VoiceLaunchScript.start, contentWorld: .page) as? String
        XCTAssertEqual(clicked, "clicked")
        let active = try await view.callAsyncJavaScript(VoiceLaunchScript.start, contentWorld: .page) as? String
        XCTAssertEqual(active, "active")
        let clicks = try await view.callAsyncJavaScript("return window.clicks;", contentWorld: .page) as? Int
        XCTAssertEqual(clicks, 1)
        _ = try await view.callAsyncJavaScript("document.querySelector('button').setAttribute('aria-label', 'Retry live voice');", contentWorld: .page)
        let failure = try await view.callAsyncJavaScript(VoiceLaunchScript.inspect, contentWorld: .page) as? String
        XCTAssertEqual(failure, "failed")
        let retry = try await view.callAsyncJavaScript(VoiceLaunchScript.start, contentWorld: .page) as? String
        XCTAssertEqual(retry, "failed", "Never automatically retry a failed voice session")
    }

    func testVoiceConfirmationWaitsForConnectionAndDetectsFailure() async throws {
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let waiter = VoiceNavigationWaiter()
        view.navigationDelegate = waiter
        view.loadHTMLString("<section aria-label='Live voice' class='live-status-connecting'><button>Stop</button></section>", baseURL: server)
        try await waiter.wait()
        let connecting = try await view.callAsyncJavaScript(VoiceLaunchScript.confirm, contentWorld: .page) as? String
        XCTAssertEqual(connecting, "waiting")
        for phase in ["requesting-permission", "listening", "speaking", "working", "failed"] {
            _ = try await view.callAsyncJavaScript("document.querySelector('section').className = 'live-status-' + phase;",
                                                  arguments: ["phase": phase], in: nil, contentWorld: .page)
            let result = try await view.callAsyncJavaScript(VoiceLaunchScript.confirm, contentWorld: .page) as? String
            XCTAssertEqual(result, phase == "failed" ? "failed" : phase == "requesting-permission" ? "waiting" : "active")
        }
    }

    func testVoiceScriptDoesNotClickHiddenButtonOrBackgroundPage() async throws {
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let waiter = VoiceNavigationWaiter()
        view.navigationDelegate = waiter
        view.loadHTMLString("<button aria-label='Start live voice' style='display:none'>Live</button>", baseURL: server)
        try await waiter.wait()
        _ = try await view.callAsyncJavaScript("Object.defineProperty(document, 'visibilityState', {configurable: true, get: () => 'visible'});", contentWorld: .page)
        let hidden = try await view.callAsyncJavaScript(VoiceLaunchScript.start, contentWorld: .page) as? String
        XCTAssertEqual(hidden, "waiting")
        _ = try await view.callAsyncJavaScript("document.querySelector('button').style.display = ''; Object.defineProperty(document, 'visibilityState', {get: () => 'hidden'});", contentWorld: .page)
        let background = try await view.callAsyncJavaScript(VoiceLaunchScript.start, contentWorld: .page) as? String
        XCTAssertEqual(background, "waiting")
    }

    func testTearDownDiscardsPendingRecovery() {
        let state = State()
        let coordinator = coordinator(browser(state, phase: .background))
        let view = webView(server)
        coordinator.webViewWebContentProcessDidTerminate(view)
        BrowserView.dismantleUIView(view, coordinator: coordinator)
        coordinator.parent = browser(state)
        coordinator.recoverIfNeeded(view)
        XCTAssertTrue(view.requests.isEmpty)
        XCTAssertNil(view.navigationDelegate)
        XCTAssertNil(view.uiDelegate)
    }

    /// A linked device stays connected in the background while its page
    /// captures (a Live call), so a capture must not outlive its view.
    func testMediaCaptureIsReportedOnChangeAndEndsWithTheView() {
        var reports: [Bool] = []
        var parent = browser(State())
        parent.onMediaCaptureChange = { reports.append($0) }
        let coordinator = coordinator(parent)
        coordinator.setMediaCapturing(true)
        coordinator.setMediaCapturing(true)
        coordinator.setMediaCapturing(false)
        coordinator.setMediaCapturing(true)
        BrowserView.dismantleUIView(webView(server), coordinator: coordinator)
        coordinator.tearDown()
        XCTAssertEqual(reports, [true, false, true, false])
    }
}

@MainActor
private final class VoiceNavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    func wait() async throws {
        if let result { return try result.get() }
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    private func finish(_ result: Result<Void, Error>) {
        if let continuation {
            self.continuation = nil
            continuation.resume(with: result)
        } else { self.result = result }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(.success(())) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }
}
