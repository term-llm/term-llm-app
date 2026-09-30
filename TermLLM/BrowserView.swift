import SwiftUI
import WebKit

struct BrowserView: UIViewRepresentable {
    enum Recovery: Equatable {
        case signIn
        case httpError(Int)
    }

    static func recovery(for response: HTTPURLResponse) -> Recovery? {
        guard response.statusCode >= 400 else { return nil }
        if response.statusCode == 401,
           response.value(forHTTPHeaderField: "X-Term-Llm-Login-Url") != nil {
            return .signIn
        }
        return .httpError(response.statusCode)
    }

    let url: URL
    @Binding var loading: Bool
    @Binding var canGoBack: Bool
    @Binding var loadError: String?
    @Binding var loginRequired: Bool
    let reloadCount: Int
    let backCount: Int
    let authenticatedCount: Int
    var scenePhase: ScenePhase = .active
    var isSigningIn = false
    /// Device tools to expose to this server's page via WebMCP, or nil when
    /// the user has not opted this server in.
    var deviceTools: DeviceToolRegistry? = nil
    let onLoginRequired: () -> Void
    let onRevealControls: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        context.coordinator.syncDeviceTools(url: url, registry: deviceTools, controller: configuration.userContentController)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        context.coordinator.backObservation = view.observe(\.canGoBack, options: [.new]) { [weak coordinator = context.coordinator] webView, _ in
            coordinator?.parent.canGoBack = webView.canGoBack
        }
        view.allowsBackForwardNavigationGestures = true
        view.scrollView.contentInsetAdjustmentBehavior = .never
        let pull = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePull(_:)))
        pull.delegate = context.coordinator
        pull.cancelsTouchesInView = false
        view.scrollView.addGestureRecognizer(pull)
        context.coordinator.loadedURL = url
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.update(view, parent: self)
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.tearDown()
        view.navigationDelegate = nil
        view.uiDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, UIGestureRecognizerDelegate {
        var parent: BrowserView
        var loadedURL: URL?
        var rejectedHTTPResponse = false
        private var pullEligible = false
        private var pullTriggered = false
        var reloadCount = 0
        var backCount = 0
        var authenticatedCount = 0
        var backObservation: NSKeyValueObservation?
        private var bridge: WebMCPBridge?
        private var recoveryPending = false
        private var lastAutomaticRecovery: TimeInterval?

        init(_ parent: BrowserView) {
            self.parent = parent
            // A recreated view already loads once in makeUIView. Do not replay
            // old native commands on its first SwiftUI update.
            reloadCount = parent.reloadCount
            backCount = parent.backCount
            authenticatedCount = parent.authenticatedCount
        }

        func tearDown() {
            backObservation?.invalidate()
            backObservation = nil
            bridge?.uninstall()
            bridge = nil
            recoveryPending = false
        }

        func update(_ view: WKWebView, parent: BrowserView) {
            self.parent = parent
            let serverChanged = loadedURL != parent.url
            let reloadRequested = reloadCount != parent.reloadCount
            let authenticated = authenticatedCount != parent.authenticatedCount
            let backRequested = backCount != parent.backCount
            loadedURL = parent.url
            reloadCount = parent.reloadCount
            authenticatedCount = parent.authenticatedCount
            backCount = parent.backCount
            let toolsChanged = syncDeviceTools(url: parent.url, registry: parent.deviceTools,
                                               controller: view.configuration.userContentController)

            // Coalesce native changes into one navigation. Server changes and
            // fresh auth always take precedence over reload/back commands.
            if serverChanged || authenticated {
                resetRecovery()
                rejectedHTTPResponse = false
                view.load(URLRequest(url: parent.url))
            } else if reloadRequested {
                resetRecovery()
                if view.url == nil || rejectedHTTPResponse {
                    view.load(URLRequest(url: parent.url))
                } else {
                    view.reload()
                }
            } else if backRequested, view.canGoBack {
                resetRecovery()
                view.goBack()
            } else if toolsChanged, view.url != nil, !rejectedHTTPResponse, !parent.isSigningIn,
                      !parent.loginRequired, parent.loadError == nil, !recoveryPending {
                view.reload() // user scripts only apply to new documents
            } else if recoveryPending {
                // A deferred termination can be handled by a scenePhase update.
                // Leave SwiftUI's update pass before changing recovery bindings.
                DispatchQueue.main.async { [weak self, weak view] in
                    guard let self, let view else { return }
                    self.recoverIfNeeded(view)
                }
            }
        }

        private func resetRecovery() {
            recoveryPending = false
            lastAutomaticRecovery = nil
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            recoveryPending = true
            parent.loading = false
            recoverIfNeeded(webView)
        }

        func recoverIfNeeded(_ view: WKWebView, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
            // Ordinary foregrounding is a no-op. Do not interrupt the system
            // passkey flow or replace an authoritative HTTP/network error.
            guard recoveryPending, parent.scenePhase == .active, !parent.isSigningIn,
                  !parent.loginRequired, !rejectedHTTPResponse, parent.loadError == nil else { return }
            recoveryPending = false
            // Bound automatic retries even when a crashing page briefly finishes
            // loading. An explicit Retry, server change, or sign-in resets this.
            if let lastAutomaticRecovery, now - lastAutomaticRecovery < 30 {
                parent.loadError = "The web page stopped unexpectedly. Tap Retry to reopen it."
                return
            }
            lastAutomaticRecovery = now
            // Use a fresh GET, not reload(), to avoid replaying a submitted form.
            // WKWebView.url includes the current SPA route after pushState.
            let target = view.url.flatMap { candidate in
                candidate.scheme == parent.url.scheme && candidate.host == parent.url.host &&
                    candidate.port == parent.url.port && !isLoginRoute(candidate) ? candidate : nil
            } ?? parent.url
            view.load(URLRequest(url: target))
        }

        /// Installs, replaces, or removes the WebMCP bridge. Returns true when
        /// the injected script changed, so the current page must reload.
        @discardableResult
        func syncDeviceTools(url: URL, registry: DeviceToolRegistry?, controller: WKUserContentController) -> Bool {
            if let bridge, let registry, bridge.serverURL == url, bridge.registry === registry { return false }
            if bridge == nil && registry == nil { return false }
            bridge?.uninstall()
            bridge = nil
            if let registry {
                let bridge = WebMCPBridge(serverURL: url, registry: registry, device: UIDevice.current.model)
                bridge.install(into: controller)
                self.bridge = bridge
            }
            return true
        }

        // Observe the pull without stealing WebKit's own scrolling or link gestures.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        @objc func handlePull(_ gesture: UIPanGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView else { return }
            switch gesture.state {
            case .began:
                pullEligible = gesture.location(in: scrollView).y < 140 &&
                    scrollView.contentOffset.y <= -scrollView.adjustedContentInset.top + 8
                pullTriggered = false
            case .changed:
                let translation = gesture.translation(in: scrollView)
                if pullEligible && !pullTriggered && translation.y > 95 &&
                    abs(translation.x) < translation.y / 2 {
                    pullTriggered = true
                    parent.onRevealControls()
                }
            case .ended, .cancelled, .failed:
                pullEligible = false
            default: break
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            rejectedHTTPResponse = false
            parent.loading = true
            parent.loadError = nil
            parent.loginRequired = false
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            rejectedHTTPResponse = false
            parent.loading = false
            parent.loadError = nil
            parent.loginRequired = false
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            guard navigationResponse.isForMainFrame,
                  let response = navigationResponse.response as? HTTPURLResponse,
                  let recovery = BrowserView.recovery(for: response) else {
                decisionHandler(.allow)
                return
            }
            rejectedHTTPResponse = true
            parent.loading = false
            switch recovery {
            case .signIn:
                parent.loginRequired = true
                parent.loadError = nil
            case .httpError(let status):
                parent.loginRequired = false
                parent.loadError = "The server returned HTTP \(status)."
            }
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            fail(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            fail(error)
        }

        private func fail(_ error: Error) {
            // WebKit may report cancellation after we intentionally reject an HTTP error page.
            if rejectedHTTPResponse { return }
            parent.loading = false
            if (error as NSError).code != NSURLErrorCancelled {
                parent.loadError = error.localizedDescription
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let destination = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if isLoginRoute(destination) {
                decisionHandler(.cancel)
                parent.onLoginRequired()
                return
            }
            if ["http", "https"].contains(destination.scheme?.lowercased() ?? ""),
               destination.host == parent.url.host,
               destination.port == parent.url.port,
               destination.scheme == parent.url.scheme {
                decisionHandler(.allow)
            } else {
                UIApplication.shared.open(destination)
                decisionHandler(.cancel)
            }
        }

        // Sites that open auth links with target=_blank still need a destination.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url {
                if isLoginRoute(url) {
                    parent.onLoginRequired()
                } else if url.scheme == parent.url.scheme, url.host == parent.url.host, url.port == parent.url.port {
                    webView.load(navigationAction.request)
                } else {
                    UIApplication.shared.open(url)
                }
            }
            return nil
        }

        // The configured hub already has app-level microphone permission; don't re-prompt on every live session.
        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            guard type == .microphone, isHubOrigin(origin) else {
                decisionHandler(.prompt)
                return
            }
            decisionHandler(.grant)
        }

        // iOS owns the one-time location authorization; skip WebKit's per-page prompt for the hub.
        @available(iOS 27.0, *)
        func webView(_ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(isHubOrigin(origin) ? .grant : .prompt)
        }

        private func isHubOrigin(_ origin: WKSecurityOrigin) -> Bool {
            guard let scheme = parent.url.scheme?.lowercased(), let host = parent.url.host?.lowercased() else {
                return false
            }
            let defaultPort = scheme == "https" ? 443 : scheme == "http" ? 80 : 0
            let expectedPort = parent.url.port ?? defaultPort
            let originPort = origin.port == 0 ? defaultPort : origin.port
            return origin.protocol.lowercased() == scheme && origin.host.lowercased() == host &&
                originPort == expectedPort
        }

        private func isLoginRoute(_ destination: URL) -> Bool {
            let prefix = parent.url.path.hasSuffix("/") ? String(parent.url.path.dropLast()) : parent.url.path
            return destination.scheme == parent.url.scheme && destination.host == parent.url.host &&
                destination.port == parent.url.port &&
                ["/auth/login", "/auth/setup", "/auth/recover"].contains { destination.path == prefix + $0 }
        }
    }
}
