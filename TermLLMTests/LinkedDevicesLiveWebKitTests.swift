import Foundation
import Network
import WebKit
import XCTest
@testable import TermLLM


/// Platform capability proof only: no broker, provider, microphone permission
/// request, getUserMedia invocation, AudioContext creation or audio recording.
@MainActor
final class LinkedDevicesLiveWebKitTests: XCTestCase {
    func testRealLocalhostBridgeExposesSecureLiveAPIsWithoutCapture() async throws {
        let page = """
        <!doctype html><html><head><title>Linked Live capability probe</title></head>
        <body><p id="linked-live-probe">Real bridge document</p></body></html>
        """
        let forwarder = LinkedDevicesForwarder(chunks: [Data(page.utf8)], contentType: "text/html; charset=utf-8")
        let authorization = PeerAuthorizationState(PeerAuthorization(
            peerID: "test-host", sessionID: "live-capability-probe", expiresAt: .distantFuture, scopePrefix: "/ui/"))
        let bridge = PeerLoopbackBridge(forwarder: forwarder, authorization: authorization,
                                        listener: PeerNWLoopbackListener(), headTimeout: 5)
        defer { bridge.revoke() }
        let endpoint = try await startBridgeWithinDeadline(bridge)
        let url = try XCTUnwrap(endpoint.url(forPath: "/ui/"))
        XCTAssertNotEqual(endpoint.port, 0)
        XCTAssertEqual(url.host, "localhost")
        XCTAssertEqual(url.scheme, "http")

        let dataStore = WKWebsiteDataStore.nonPersistent()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: configuration)
        let navigation = LinkedLiveNavigationWaiter()
        webView.navigationDelegate = navigation
        addTeardownBlock { @MainActor in
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            navigation.cancel()
            bridge.revoke()
            await endpoint.removeCapability(from: dataStore.httpCookieStore)
            await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        }

        // Follow production ordering: reserve the actual localhost origin,
        // install its HttpOnly capability in this isolated store, then accept.
        await endpoint.installCapability(in: dataStore.httpCookieStore)
        try bridge.activate()
        webView.load(URLRequest(url: url))
        try await navigation.wait()
        XCTAssertEqual(webView.url, url)
        XCTAssertTrue(forwarder.paths.contains("/ui/"), "HTML must traverse the authenticated real bridge")

        let probe = try await webView.callAsyncJavaScript("""
        return {
            documentLoaded: document.getElementById('linked-live-probe')?.textContent === 'Real bridge document',
            origin: window.location.origin,
            secureContext: window.isSecureContext === true,
            getUserMedia: typeof navigator.mediaDevices?.getUserMedia,
            audioContext: typeof window.AudioContext,
            audioWorkletNode: typeof window.AudioWorkletNode
        };
        """, contentWorld: .page)
        let result = try XCTUnwrap(probe as? [String: Any])
        XCTAssertEqual(result["documentLoaded"] as? Bool, true, "A bridge error page is not a capability proof")
        XCTAssertEqual(result["origin"] as? String, endpoint.origin)
        XCTAssertEqual(result["secureContext"] as? Bool, true,
                       "Platform blocker: real HTTP localhost is not a secure context; do not bypass WebKit security")
        XCTAssertEqual(result["getUserMedia"] as? String, "function")
        XCTAssertEqual(result["audioContext"] as? String, "function")
        XCTAssertEqual(result["audioWorkletNode"] as? String, "function")
    }

    private func startBridgeWithinDeadline(_ bridge: PeerLoopbackBridge) async throws -> PeerLoopbackEndpoint {
        try await withThrowingTaskGroup(of: PeerLoopbackEndpoint.self) { group in
            group.addTask { try await bridge.startPaused() }
            group.addTask {
                try await Task.sleep(nanoseconds: 15_000_000_000)
                throw RealLoopbackTestError.timedOut
            }
            defer { group.cancelAll() }
            guard let endpoint = try await group.next() else { throw RealLoopbackTestError.unexpectedEOF }
            return endpoint
        }
    }
}

/// Stores early completion like the LiveHangUp waiter, with an independent
/// deadline so a failed WebKit navigation cannot leave a physical-device run hung.
@MainActor
private final class LinkedLiveNavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?
    private var deadline: Task<Void, Never>?

    func wait() async throws {
        if let result { return try result.get() }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            deadline = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
                self?.finish(.failure(RealLoopbackTestError.timedOut))
            }
        }
    }

    func cancel() { finish(.failure(CancellationError())) }

    private func finish(_ result: Result<Void, Error>) {
        guard self.result == nil else { return }
        self.result = result
        deadline?.cancel()
        deadline = nil
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(.success(())) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }
}
