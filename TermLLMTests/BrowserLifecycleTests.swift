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
        var hangUpScripts: [String] = []
        override func evaluateJavaScript(_ javaScriptString: String,
                                         completionHandler: (@MainActor @Sendable (Any?, Error?) -> Void)? = nil) {
            if javaScriptString.contains("__termLLMLiveHangUp") {
                hangUpScripts.append(javaScriptString)
                completionHandler?(nil, nil)
            } else {
                super.evaluateJavaScript(javaScriptString, completionHandler: completionHandler)
            }
        }
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

    func testLinkedGeolocationPromptsOnlyForVerifiedTopLevelChat() {
        var parent = linkedMediaBrowser()
        let origin = "http://localhost:43212"
        func decision(_ frame: String?, main: Bool = true, scheme: String = "http",
                      host: String = "localhost", port: Int = 43212) -> WKPermissionDecision {
            parent.geolocationDecision(originScheme: scheme, originHost: host, originPort: port,
                                       frameURL: frame.flatMap(URL.init(string:)), isMainFrame: main)
        }
        let chat = origin + "/ui/chat/7"
        XCTAssertEqual(decision(origin + "/ui/?new=1"), .prompt)
        XCTAssertEqual(decision(chat), .prompt)
        XCTAssertEqual(decision(chat, main: false), .deny)
        XCTAssertEqual(decision(nil), .deny)
        XCTAssertEqual(decision(chat, scheme: "https"), .deny)
        XCTAssertEqual(decision(chat, host: "127.0.0.1"), .deny)
        XCTAssertEqual(decision(chat, port: 43213), .deny)
        XCTAssertEqual(decision("http://localhost:43213/ui/chat/7"), .deny)
        for path in ["/", "/other/chat/7", "/ui/api/location", "/ui/files/photo", "/ui/%2e%2e/chat/7"] {
            XCTAssertEqual(decision(origin + path), .deny, path)
        }
        parent.connectionMount = URL(string: origin + "/other/")!
        XCTAssertEqual(decision(origin + "/other/chat/7"), .deny)
        parent.connectionMount = URL(string: origin + "/ui/?scope=1")!
        XCTAssertEqual(decision(chat), .deny)
        parent.connectionMount = nil
        XCTAssertEqual(decision(chat), .deny)
    }

    func testOrdinaryGeolocationPolicyRemainsUnchanged() {
        let parent = browser(State())
        XCTAssertEqual(parent.geolocationDecision(originScheme: "https", originHost: "example.com", originPort: 0,
                                                  frameURL: nil, isMainFrame: false), .grant)
        XCTAssertEqual(parent.geolocationDecision(originScheme: "https", originHost: "other.example", originPort: 0,
                                                  frameURL: nil, isMainFrame: false), .prompt)
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

    #if os(iOS)
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

    #endif

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

    func testNativeNewConversationLoadsEvenWhenFileDocumentIsCurrent() {
        let state = State()
        let coordinator = coordinator(browser(state))
        let file = URL(string: "https://example.com/ui/files/review.md")!
        let view = webView(file)
        var parent = browser(state)
        let draft = URL(string: "https://example.com/ui/?new=1")!
        parent.nativeDestination = HubBrowserDestination(url: draft)
        coordinator.update(view, parent: parent)
        coordinator.update(view, parent: parent)
        XCTAssertEqual(view.requests.map(\.url), [draft], "Native navigation must not depend on the current document's JavaScript")
        parent.nativeDestination = HubBrowserDestination(url: draft)
        coordinator.update(view, parent: parent)
        XCTAssertEqual(view.requests.map(\.url), [draft, draft], "Repeated new-conversation requests must still navigate")
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
        BrowserView.dismantleWebView(view, coordinator: coordinator)
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
        BrowserView.dismantleWebView(webView(server), coordinator: coordinator)
        coordinator.tearDown()
        XCTAssertEqual(reports, [true, false, true, false])
    }

    // This regression deliberately uses only the pre-fix public entry points,
    // so it can also run with the original bridge/coordinator for red evidence.
    func testManualPlaybackDoesNotWaitForAnUnrelatedTool() async throws {
        let started = PlaybackTestGate()
        let finish = PlaybackTestGate()
        let registry = DeviceToolRegistry(tools: [
            DeviceTool(name: "slow", description: "Unrelated slow work") { _ in
                await started.open()
                await finish.wait()
                return DeviceToolResult(text: "slow result")
            },
        ])
        let coordinator = coordinator(browser(State()))
        let view = webView(server)
        coordinator.webView = view
        coordinator.syncDeviceTools(url: server, registry: registry,
                                    controller: view.configuration.userContentController)
        defer { coordinator.tearDown() }
        let waiter = VoiceNavigationWaiter()
        view.navigationDelegate = waiter
        view.loadHTMLString("<!doctype html><body>Playback regression</body>", baseURL: server)
        try await waiter.wait()
        let call = Task { @MainActor in
            try await view.callAsyncJavaScript("return await document.modelContext.executeTool('slow', {})", contentWorld: .page) as? String
        }
        await started.wait()
        coordinator.appWillStartPlayback()
        XCTAssertEqual(view.hangUpScripts, [LiveHangUp.requestScript(afterToolResult: false)],
                       "Manual playback must not wait for an unrelated active tool")
        finish.open()
        let reply = try await call.value
        XCTAssertEqual(reply, "slow result")
    }

    func testPlaybackWaitsForExactlyTheInitiatingReplyNotOtherCalls() async throws {
        let coordinator = coordinator(browser(State()))
        let view = webView(server)
        let started = PlaybackTestGate()
        let finishPlay = PlaybackTestGate()
        let finishSlow = PlaybackTestGate()
        let grace = PlaybackTestGate()
        coordinator.waitForPlaybackHandoverGrace = { await grace.wait() }
        let registry = DeviceToolRegistry(tools: [
            DeviceTool(name: "play", description: "Starts playback") { _ in
                await MainActor.run {
                    coordinator.appWillStartPlayback()
                    coordinator.appWillStartPlayback() // Repeated starts from one invocation coalesce.
                }
                await started.open()
                await finishPlay.wait()
                return DeviceToolResult(text: "play result")
            },
            DeviceTool(name: "slow", description: "Unrelated") { _ in
                await finishSlow.wait()
                return DeviceToolResult(text: "slow result")
            },
            DeviceTool(name: "other", description: "Another unrelated reply") { _ in
                DeviceToolResult(text: "other result")
            },
        ])
        coordinator.webView = view
        coordinator.syncDeviceTools(url: server, registry: registry,
                                    controller: view.configuration.userContentController)
        let bridge = try XCTUnwrap(coordinator.bridge)
        defer { grace.open(); coordinator.tearDown() }
        let slow = bridge.startCall(body: ["name": "slow"], frameOrigin: bridge.expectedOrigin, isMainFrame: true) { _, _ in }
        var playReplied = false
        let play = bridge.startCall(body: ["name": "play"], frameOrigin: bridge.expectedOrigin, isMainFrame: true) { result, error in
            XCTAssertEqual(result as? String, "play result")
            XCTAssertNil(error)
            XCTAssertTrue(view.hangUpScripts.isEmpty, "Never hang up before handing off the initiating result")
            playReplied = true
        }
        await started.wait()
        let other = bridge.startCall(body: ["name": "other"], frameOrigin: bridge.expectedOrigin, isMainFrame: true) { _, _ in }
        await other.value
        XCTAssertTrue(view.hangUpScripts.isEmpty, "Another call's reply cannot settle the initiating call")
        finishPlay.open()
        await play.value
        XCTAssertTrue(playReplied)
        XCTAssertEqual(bridge.activeCalls, 1)
        XCTAssertEqual(view.hangUpScripts, [LiveHangUp.requestScript(afterToolResult: true)])
        finishSlow.open()
        await slow.value
        XCTAssertEqual(view.hangUpScripts, [LiveHangUp.requestScript(afterToolResult: true)],
                       "An unrelated reply must not issue another handover")
        let graceTask = try XCTUnwrap(coordinator.hangUpTask)
        coordinator.webView(view, didStartProvisionalNavigation: nil)
        coordinator.webView(view, didFailProvisionalNavigation: nil,
                            withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
        grace.open()
        await graceTask.value
        XCTAssertEqual(view.hangUpScripts.last, LiveHangUp.flushScript,
                       "A failed provisional navigation must preserve the current document's grace")
    }

    func testPlaybackFromAnotherBridgeDoesNotDeferThisPage() async {
        let coordinator = coordinator(browser(State()))
        let view = webView(server)
        coordinator.webView = view
        let foreign = WebMCPBridge(serverURL: server, registry: DeviceToolRegistry(tools: [
            DeviceTool(name: "play", description: "Other page's tool") { _ in
                await MainActor.run { coordinator.appWillStartPlayback() }
                return DeviceToolResult(text: "done")
            },
        ]), device: "iPhone")
        let call = foreign.startCall(body: ["name": "play"], frameOrigin: foreign.expectedOrigin, isMainFrame: true) { _, _ in }
        await call.value
        XCTAssertEqual(view.hangUpScripts, [LiveHangUp.requestScript(afterToolResult: false)])
        coordinator.tearDown()
    }

    func testHandoverGraceCannotFlushAfterDocumentCommitTerminationTeardownOrBridgeReplacement() async throws {
        for invalidation in ["commit", "termination", "teardown", "replacement"] {
            let coordinator = coordinator(browser(State(), phase: .background))
            let view = webView(server)
            let graceStarted = PlaybackTestGate()
            let finishGrace = PlaybackTestGate()
            coordinator.waitForPlaybackHandoverGrace = {
                await graceStarted.open()
                // Deliberately ignore cancellation: the document/token check must
                // also defend against a grace operation that has already resumed.
                await finishGrace.wait()
            }
            let registry = DeviceToolRegistry(tools: [
                DeviceTool(name: "play", description: "Starts playback") { _ in
                    await MainActor.run { coordinator.appWillStartPlayback() }
                    return DeviceToolResult(text: "done")
                },
            ])
            coordinator.webView = view
            coordinator.syncDeviceTools(url: server, registry: registry,
                                        controller: view.configuration.userContentController)
            let bridge = try XCTUnwrap(coordinator.bridge)
            let call = bridge.startCall(body: ["name": "play"], frameOrigin: bridge.expectedOrigin, isMainFrame: true) { _, _ in }
            await call.value
            await graceStarted.wait()
            XCTAssertEqual(view.hangUpScripts, [LiveHangUp.requestScript(afterToolResult: true)])
            let graceTask = try XCTUnwrap(coordinator.hangUpTask)
            coordinator.webView(view, didStartProvisionalNavigation: nil)
            switch invalidation {
            case "commit": coordinator.webView(view, didCommit: nil)
            case "termination": coordinator.webViewWebContentProcessDidTerminate(view)
            case "teardown": coordinator.tearDown()
            default:
                coordinator.syncDeviceTools(url: server, registry: nil,
                                            controller: view.configuration.userContentController)
            }
            finishGrace.open()
            await graceTask.value
            XCTAssertFalse(view.hangUpScripts.contains(LiveHangUp.flushScript), invalidation)
            coordinator.tearDown()
        }
    }

    func testOldDocumentToolReplyCannotStartHandoverInNewDocument() async throws {
        let coordinator = coordinator(browser(State()))
        let view = webView(server)
        let started = PlaybackTestGate()
        let finish = PlaybackTestGate()
        let registry = DeviceToolRegistry(tools: [
            DeviceTool(name: "play", description: "Starts playback") { _ in
                await MainActor.run { coordinator.appWillStartPlayback() }
                await started.open()
                await finish.wait()
                // The task local is still inherited, but this invocation belongs
                // to the old document and must not defer the new page's playback.
                await MainActor.run { coordinator.appWillStartPlayback() }
                return DeviceToolResult(text: "done")
            },
        ])
        coordinator.webView = view
        coordinator.syncDeviceTools(url: server, registry: registry,
                                    controller: view.configuration.userContentController)
        let bridge = try XCTUnwrap(coordinator.bridge)
        let call = bridge.startCall(body: ["name": "play"], frameOrigin: bridge.expectedOrigin, isMainFrame: true) { _, _ in }
        await started.wait()
        coordinator.webView(view, didCommit: nil)
        finish.open()
        await call.value
        XCTAssertTrue(view.hangUpScripts.isEmpty,
                      "A retired document's still-running invocation must not stop the new page at all")
        coordinator.tearDown()
    }

    func testManualPlaybackSupersedesExistingGrace() async throws {
        let coordinator = coordinator(browser(State()))
        let view = webView(server)
        let graceStarted = PlaybackTestGate()
        let finishGrace = PlaybackTestGate()
        coordinator.waitForPlaybackHandoverGrace = {
            await graceStarted.open()
            await finishGrace.wait()
        }
        let registry = DeviceToolRegistry(tools: [
            DeviceTool(name: "play", description: "Starts playback") { _ in
                await MainActor.run { coordinator.appWillStartPlayback() }
                return DeviceToolResult(text: "done")
            },
        ])
        coordinator.webView = view
        coordinator.syncDeviceTools(url: server, registry: registry,
                                    controller: view.configuration.userContentController)
        let bridge = try XCTUnwrap(coordinator.bridge)
        let call = bridge.startCall(body: ["name": "play"], frameOrigin: bridge.expectedOrigin, isMainFrame: true) { _, _ in }
        await call.value
        await graceStarted.wait()
        let graceTask = try XCTUnwrap(coordinator.hangUpTask)
        coordinator.appWillStartPlayback()
        XCTAssertEqual(view.hangUpScripts, [LiveHangUp.requestScript(afterToolResult: true),
                                            LiveHangUp.cancelScript,
                                            LiveHangUp.requestScript(afterToolResult: false)])
        finishGrace.open()
        await graceTask.value
        XCTAssertFalse(view.hangUpScripts.contains(LiveHangUp.flushScript))
        coordinator.tearDown()
    }

    func testActualMediaPlayToolPreservesScopeAcrossListenMainActorHop() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let listen = Listen(store: ListenStore(fileURL: directory.appending(path: "library.json")),
                            engine: FakeListenEngine(), cookies: FakeCookieJar(), server: { nil },
                            downloadDirectory: directory, defaults: isolatedDefaults())
        let items = try await listen.add([ListenDraft(url: URL(string: "http://media.example/episode.mp3")!, title: "Episode")],
                                         placement: .end, download: .never)
        let coordinator = coordinator(browser(State()))
        let view = webView(server)
        let grace = PlaybackTestGate()
        coordinator.waitForPlaybackHandoverGrace = { await grace.wait() }
        coordinator.webView = view
        coordinator.syncDeviceTools(url: server, registry: DeviceToolRegistry(tools: listen.tools),
                                    controller: view.configuration.userContentController)
        let bridge = try XCTUnwrap(coordinator.bridge)
        NotificationCenter.default.addObserver(coordinator, selector: #selector(BrowserView.Coordinator.appWillStartPlayback),
                                               name: .appWillStartPlayback, object: nil)
        var playbackNotifications = 0
        listen.player.willStartPlayback = {
            playbackNotifications += 1
            XCTAssertNotNil(bridge.currentPlaybackCallID, "The real media tool's actor hop must preserve correlation")
            NotificationCenter.default.post(name: .appWillStartPlayback, object: nil)
        }
        let call = bridge.startCall(body: ["name": "media_play", "arguments": "{\"item\":\"\(items[0].id)\"}"],
                                    frameOrigin: bridge.expectedOrigin, isMainFrame: true) { result, error in
            XCTAssertNotNil(result)
            XCTAssertNil(error)
            XCTAssertTrue(view.hangUpScripts.isEmpty)
        }
        await call.value
        XCTAssertEqual(playbackNotifications, 1)
        XCTAssertEqual(listen.player.status, .playing)
        XCTAssertEqual(view.hangUpScripts, [LiveHangUp.requestScript(afterToolResult: true)])
        coordinator.tearDown()
        grace.open()
        listen.player.stop()
    }

    /// The health monitor's "off screen" must not include a page the user can
    /// still see: an unfocused Mac window or iPad multitasking is only inactive.
    func testHealthCountsAShownPageInAnInactiveSceneAsOnScreen() {
        let state = State()
        func onScreen(_ parent: BrowserView, inWindow: Bool = true, background: Bool = false) -> Bool {
            BrowserView.Coordinator.healthPageIsOnScreen(parent, inWindow: inWindow, appBackground: background)
        }
        XCTAssertTrue(onScreen(browser(state)))
        XCTAssertTrue(onScreen(browser(state, phase: .inactive)))
        XCTAssertFalse(onScreen(browser(state, phase: .background)))
        XCTAssertFalse(onScreen(browser(state, phase: .inactive), background: true))
        XCTAssertFalse(onScreen(browser(state), inWindow: false))
        XCTAssertFalse(onScreen(browser(state, signingIn: true)))
        var otherTab = browser(state)
        otherTab.isContentVisible = false
        XCTAssertFalse(onScreen(otherTab))
        state.loginRequired = true
        XCTAssertFalse(onScreen(browser(state)))
        state.loginRequired = false
        state.error = "The server could not be reached."
        XCTAssertFalse(onScreen(browser(state)))
    }
}

@MainActor
private final class PlaybackTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
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


@MainActor
extension BrowserLifecycleTests {
    func testWorkspacePlatformKeepsPhoneTabsRegardlessOfWidthOrSizeClass() {
        #if os(iOS)
        XCTAssertEqual(WorkspacePlatform(idiom: .phone), .phone)
        XCTAssertEqual(WorkspacePlatform(idiom: .pad), .pad)
        #else
        XCTAssertEqual(WorkspacePlatform.current, .mac)
        #endif
        for width: CGFloat in [320, 599, 768, 899, 900, 1440] {
            let policy = WorkspaceLayoutPolicy(platform: .phone, width: width, overlayPresented: true)
            XCTAssertFalse(policy.platform.usesWorkspaceChrome)
            XCTAssertFalse(policy.supportsPersistentSidebar)
            XCTAssertFalse(policy.showsSidebar)
            XCTAssertFalse(policy.showsSidebarToggle)
            XCTAssertEqual(policy.contentInset, 0)
        }
    }

    func testMacWorkspaceUsesFullWidthContentWithoutSidebarAtEveryWidth() {
        for width: CGFloat in [320, 599, 768, 820, 899, 900, 1194, 1440] {
            for hidden in [false, true] {
                let policy = WorkspaceLayoutPolicy(platform: .mac, width: width,
                                                   persistentSidebarHidden: hidden, overlayPresented: true)
                XCTAssertTrue(policy.platform.usesWorkspaceChrome)
                XCTAssertFalse(policy.supportsSidebar)
                XCTAssertEqual(policy.sidebarWidth, 0)
                XCTAssertFalse(policy.supportsPersistentSidebar)
                XCTAssertFalse(policy.showsPersistentSidebar)
                XCTAssertFalse(policy.showsOverlaySidebar)
                XCTAssertFalse(policy.showsSidebar)
                XCTAssertFalse(policy.showsSidebarToggle, "Mac Chat must not reserve a leading toggle rail")
                XCTAssertEqual(policy.contentInset, 0)
            }
        }
    }

    func testWorkspaceSidebarBreakpointDimensionsAndManualCollapse() {
        for platform: WorkspacePlatform in [.pad] {
            let sidebarWidth: CGFloat = 200
            for width: CGFloat in [320, 599, 768, 899] {
                var policy = WorkspaceLayoutPolicy(platform: platform, width: width)
                XCTAssertTrue(policy.platform.usesWorkspaceChrome, "Narrow workspaces must not become phone tabs")
                XCTAssertEqual(policy.sidebarWidth, sidebarWidth)
                XCTAssertFalse(policy.showsSidebar)
                XCTAssertTrue(policy.showsSidebarToggle)
                XCTAssertEqual(policy.contentInset, 0)
                policy.overlayPresented = true
                XCTAssertTrue(policy.showsOverlaySidebar)
                XCTAssertEqual(policy.contentInset, 0, "An overlay must not shrink or reparent content")
            }
            for width: CGFloat in [900, 1194, 1440] {
                var policy = WorkspaceLayoutPolicy(platform: platform, width: width, overlayPresented: true)
                XCTAssertTrue(policy.showsPersistentSidebar)
                XCTAssertFalse(policy.showsOverlaySidebar)
                XCTAssertFalse(policy.showsSidebarToggle)
                XCTAssertEqual(policy.contentInset, sidebarWidth)
                policy.persistentSidebarHidden = true
                XCTAssertFalse(policy.showsSidebar)
                XCTAssertTrue(policy.showsSidebarToggle)
                XCTAssertEqual(policy.contentInset, 0)
            }
        }
    }

    /// Exercise the production generic container, not just its policy. This
    /// mounts a real local WKWebView without network, credentials or bridges.
    /// A structurally conditional split/tab implementation would dismantle or
    /// recreate it when crossing 900 pt or leaving Chat.
    #if os(iOS)
    func testWorkspaceContainerRetainsActualWebViewAcrossSelectionAndWidthChanges() async throws {
        for platform: WorkspacePlatform in [.pad, .mac] {
            let mounted = expectation(description: "Mounted one \(platform) chat web view")
            let model = WorkspaceIdentityModel(onMount: { mounted.fulfill() })
            let host = UIHostingController(rootView: WorkspaceIdentityFixture(model: model, platform: platform))
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previousKeyWindow = scene.keyWindow
            let window = UIWindow(windowScene: scene)
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
                previousKeyWindow?.makeKey()
            }
            host.view.layoutIfNeeded()
            await fulfillment(of: [mounted], timeout: 3)
            let original = try XCTUnwrap(model.webViews.first)
            let identity = ObjectIdentifier(original)
            XCTAssertNotNil(original.window)
            let navigation = VoiceNavigationWaiter()
            original.navigationDelegate = navigation
            original.loadHTMLString("""
                <meta name="viewport" content="width=device-width, initial-scale=1">
                <style>html,body{margin:0}body{height:5000px}textarea{position:absolute;top:80px;width:200px;height:100px}</style>
                <textarea aria-label="Draft"></textarea><p>Local retained document</p>
                """, baseURL: nil)
            try await navigation.wait()
            // didFinish can precede WebKit's first native layout transaction. A JS
            // scroll here can be overwritten by that transaction's initial zero
            // offset, so first wait for the actual scrollable native viewport.
            for _ in 0..<200 where original.scrollView.contentSize.height < 5000 || original.bounds.height == 0 {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(original.scrollView.contentSize.height, 5000, accuracy: 1,
                           "The fixture document must finish native layout before scrolling")
            _ = try await original.callAsyncJavaScript("document.querySelector('textarea').value = 'unsent workspace draft';",
                                                       contentWorld: .page)
            // Seed the viewport as a native scroll would, then require both
            // processes to agree before exercising detachment. Merely seeing a
            // JS scrollTo return 640 does not establish the native checkpoint.
            original.scrollView.setContentOffset(CGPoint(x: 0, y: 640), animated: false)
            var initialScroll: Double?
            for _ in 0..<200 {
                initialScroll = try await original.callAsyncJavaScript("return window.scrollY;", contentWorld: .page) as? Double
                if let initialScroll, abs(initialScroll - 640) <= 1,
                   abs(original.scrollView.contentOffset.y - 640) <= 1 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(try XCTUnwrap(initialScroll), 640, accuracy: 1)
            XCTAssertEqual(original.scrollView.contentOffset.y, 640, accuracy: 1, "Initial native scroll must agree with the document before detachment")

            // Wide split -> overlay-capable portrait -> very narrow iPad/Mac ->
            // split again, while visiting every actual destination slot.
            let transitions: [(CGFloat, AppTab)] = [(1194, .agents), (768, .music), (500, .podcasts),
                                                   (899, .chat), (900, .agents), (1440, .chat)]
            for (width, tab) in transitions {
                model.width = width
                model.selection = tab
                host.view.setNeedsLayout()
                host.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(60))
                host.view.layoutIfNeeded()
                XCTAssertEqual(model.webViews.count, 1, "Chat was recreated at \(width) / \(tab)")
                XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(model.webViews.last)), identity)
                XCTAssertEqual(model.dismantles, 0, "Chat must stay mounted while hidden")
                if tab == .chat {
                    XCTAssertNotNil(original.window, "Visible Chat must reattach the retained web view")
                    let layout = WorkspaceLayoutPolicy(platform: platform, width: width)
                    let railWidth: CGFloat = layout.showsSidebarToggle ? 44 : 0
                    XCTAssertEqual(original.bounds.width, width - layout.contentInset - railWidth, accuracy: 1,
                                   "The test must exercise real container resizing, including the Chat rail")
                    let draft = try await original.callAsyncJavaScript("return document.querySelector('textarea').value;",
                                                                       contentWorld: .page) as? String
                    XCTAssertEqual(draft, "unsent workspace draft")
                    let scroll = try await original.callAsyncJavaScript("return window.scrollY;", contentWorld: .page) as? Double
                    XCTAssertEqual(try XCTUnwrap(scroll), 640, accuracy: 2,
                                   "Detachment must not reset document scroll: \(platform), width \(width), native offset \(original.scrollView.contentOffset)")
                } else {
                    XCTAssertNil(original.window, "Opacity alone does not hide a page from WebKit; Chat must leave its window")
                    XCTAssertEqual(model.updatedVisibilities.last, false, "The browser coordinator must receive hidden state before detachment")
                }
                XCTAssertTrue(model.updateIdentities.allSatisfy { $0 == identity })
            }
            XCTAssertGreaterThan(model.updateIdentities.count, 1, "The hosted fixture must actually receive state updates")
            model.selection = .agents
            try await Task.sleep(for: .milliseconds(60))
            // A replacement document in the same retained WKWebView must not
            // inherit the old page's native scroll checkpoint.
            let replacementNavigation = VoiceNavigationWaiter()
            original.navigationDelegate = replacementNavigation
            original.loadHTMLString("<body style='height:5000px'><textarea>new document</textarea></body>", baseURL: nil)
            try await replacementNavigation.wait()
            model.selection = .chat
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(60))
            XCTAssertNotNil(original.window)
            let replacementScroll = try await original.callAsyncJavaScript("return window.scrollY;", contentWorld: .page) as? Double
            XCTAssertEqual(try XCTUnwrap(replacementScroll), 0, accuracy: 1, "Navigation must invalidate the old document's scroll checkpoint")
            XCTAssertEqual(model.webViews.count, 1)
            model.selection = .agents
            try await Task.sleep(for: .milliseconds(60))
            model.chatAvailable = false
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(60))
            XCTAssertEqual(model.dismantles, 1, "Revocation must tear down a hidden protected document immediately")
            XCTAssertNil(original.window)
        }
    }

    private final class WorkspaceIdentityModel: ObservableObject {
        @Published var selection: AppTab = .chat
        @Published var width: CGFloat = 1200
        @Published var chatAvailable = true
        var webViews: [WKWebView] = []
        var updateIdentities: [ObjectIdentifier] = []
        var updatedVisibilities: [Bool] = []
        var dismantles = 0
        let onMount: () -> Void
        init(onMount: @escaping () -> Void) { self.onMount = onMount }
    }

    private struct WorkspaceIdentityFixture: View {
        @ObservedObject var model: WorkspaceIdentityModel
        let platform: WorkspacePlatform

        var body: some View {
            WorkspaceShell(platform: platform, selection: model.selection, visitedTabs: Set(AppTab.allCases),
                           chatAgentName: "Fixture Agent", onSelect: { model.selection = $0 }, onSettings: {}) { _ in
                Text("Agents")
            } chat: {
                if model.chatAvailable {
                    WorkspaceWebViewProbe(model: model, isVisible: model.selection == .chat)
                } else {
                    Text("Authorization revoked")
                }
            } music: { _ in
                Text("Music")
            } podcasts: { _ in
                Text("Podcasts")
            } shelf: {
                Text("Shared playback shelf")
            }
            .frame(width: model.width, height: 600)
        }
    }

    private struct WorkspaceWebViewProbe: UIViewRepresentable {
        let model: WorkspaceIdentityModel
        let isVisible: Bool
        func makeCoordinator() -> WorkspaceIdentityModel { model }
        func makeUIView(context: Context) -> WKWebView {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let view = WKWebView(frame: .zero, configuration: configuration)
            model.webViews.append(view)
            model.onMount()
            return view
        }
        func updateUIView(_ view: WKWebView, context: Context) {
            model.updateIdentities.append(ObjectIdentifier(view))
            model.updatedVisibilities.append(isVisible)
        }
        static func dismantleUIView(_ view: WKWebView, coordinator: WorkspaceIdentityModel) {
            coordinator.dismantles += 1
        }
    }
    #endif
}
