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
    }

    private func browser(_ state: State, phase: ScenePhase = .active,
                         signingIn: Bool = false, reload: Int = 0, back: Int = 0,
                         authenticated: Int = 0, url: URL? = nil) -> BrowserView {
        BrowserView(url: url ?? server,
                    loading: Binding(get: { state.loading }, set: { state.loading = $0 }),
                    canGoBack: Binding(get: { state.canGoBack }, set: { state.canGoBack = $0 }),
                    loadError: Binding(get: { state.error }, set: { state.error = $0 }),
                    loginRequired: Binding(get: { state.loginRequired }, set: { state.loginRequired = $0 }),
                    reloadCount: reload, backCount: back, authenticatedCount: authenticated,
                    scenePhase: phase, isSigningIn: signingIn,
                    onLoginRequired: {}, onRevealControls: {})
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
}
