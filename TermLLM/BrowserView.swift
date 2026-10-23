import SwiftUI
import WebKit

struct VoiceBrowserLaunch: Equatable {
    let id: UUID
    let url: URL

    func allowsPath(_ candidate: URL, afterStart: Bool) -> Bool {
        let base = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let root = base.isEmpty ? "" : "/" + base
        let path = candidate.path.hasSuffix("/") ? String(candidate.path.dropLast()) : candidate.path
        if path == root { return true }
        // Starting Live materializes the draft and pushStates to /chat/<slug>.
        // Accept that SPA transition, but never another node or arbitrary page.
        guard afterStart, path.hasPrefix(root + "/chat/") else { return false }
        let slug = String(path.dropFirst((root + "/chat/").count))
        return !slug.isEmpty && slug != "." && slug != ".." && !slug.contains("/")
    }
}

struct VoiceLaunchFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Only inspect main-frame UI affordances; never reach into frontend stores.
/// The check is also used before navigating, to preserve an existing call.
enum VoiceLaunchScript {
    static let inspect = """
    const visible = b => b.getClientRects().length > 0;
    const buttons = [...document.querySelectorAll('button')].filter(visible);
    if (buttons.some(b => b.getAttribute('aria-label') === 'Stop live voice' ||
        (b.closest('section[aria-label="Live voice"]') && b.textContent.trim() === 'Stop'))) return 'active';
    if (buttons.some(b => b.getAttribute('aria-label') === 'Retry live voice')) return 'failed';
    return 'waiting';
    """

    static let confirm = """
    const status = document.querySelector('section[aria-label="Live voice"]');
    if (status?.classList.contains('live-status-failed')) return 'failed';
    if (['listening', 'speaking', 'working'].some(phase => status?.classList.contains('live-status-' + phase))) return 'active';
    if ([...document.querySelectorAll('button')].some(b => b.getAttribute('aria-label') === 'Retry live voice')) return 'failed';
    return 'waiting';
    """

    static let start = """
    const buttons = [...document.querySelectorAll('button')].filter(b => b.getClientRects().length > 0);
    if (buttons.some(b => b.getAttribute('aria-label') === 'Stop live voice' ||
        (b.closest('section[aria-label="Live voice"]') && b.textContent.trim() === 'Stop'))) return 'active';
    const button = buttons.find(b => b.getAttribute('aria-label') === 'Start live voice' && !b.disabled);
    if (buttons.some(b => b.getAttribute('aria-label') === 'Retry live voice')) return 'failed';
    if (!button || document.visibilityState !== 'visible') return 'waiting';
    button.click();
    return 'clicked';
    """
}

/// Observes a pull without depending on which (possibly nested) web scroller moves.
struct BrowserControlsPullGesture {
    private var eligible = false
    private var triggered = false

    mutating func reset() {
        eligible = false
        triggered = false
    }

    /// `location` is in scroll-view coordinates, whose origin moves with its bounds.
    /// Translation is a distance, so it needs no content-offset adjustment.
    mutating func update(state: UIGestureRecognizer.State, location: CGPoint,
                         translation: CGPoint, boundsMinY: CGFloat) -> Bool {
        switch state {
        case .began:
            reset()
            // A pan has already travelled through recognition slop at .began.
            let startY = location.y - boundsMinY - translation.y
            eligible = startY >= 0 && startY < 140
        case .changed:
            break
        case .ended, .cancelled, .failed:
            reset()
            return false
        default:
            return false
        }

        guard eligible, !triggered, translation.y >= 68,
              abs(translation.x) < translation.y / 2 else { return false }
        triggered = true
        return true
    }
}

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
    var voiceLaunch: VoiceBrowserLaunch? = nil
    var onVoiceLaunchFinished: (UUID, String?) -> Void = { _, _ in }
    /// Native push: the bridge is always offered to the configured server so
    /// its web UI can enroll; nil disables it (tests).
    var push: PushCenter? = nil
    /// A tapped notification's page on the configured server.
    var pushNavigation: PushNavigation? = nil
    var pushChangeCount = 0
    var onPushNavigationHandled: (UUID) -> Void = { _ in }
    var onPushWindowReady: (String) -> Void = { _ in }
    /// Explicit native navigation, independent of JS and WebKit UI responsiveness.
    var nativeDestination: HubBrowserDestination? = nil
    /// Native visibility overrides the page's own foreground/attendance claims.
    var isContentVisible = true
    /// Owned store for a paired peer bridge (non-persistent, holds only its
    /// HttpOnly capability cookie).  nil keeps the existing default/fixture store.
    var websiteDataStore: WKWebsiteDataStore? = nil
    /// A paired text-only transport does not grant camera/microphone access.
    /// Direct-server voice retains its existing permission behavior.
    var allowsMediaCapture = true

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = websiteDataStore ?? (HubFixture.isEnabled ? HubFixture.websiteDataStore : .default())
        configuration.allowsInlineMediaPlayback = true
        context.coordinator.syncPushBridge(url: url, center: push, controller: configuration.userContentController)
        context.coordinator.syncDeviceTools(url: url, registry: deviceTools, controller: configuration.userContentController)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        context.coordinator.backObservation = view.observe(\.canGoBack, options: [.new]) { [weak coordinator = context.coordinator] webView, _ in
            coordinator?.parent.canGoBack = webView.canGoBack
        }
        context.coordinator.urlObservation = view.observe(\.url, options: [.initial, .new]) { [weak coordinator = context.coordinator] webView, _ in
            MainActor.assumeIsolated { coordinator?.parent.push?.visibleURL = webView.url }
        }
        view.allowsBackForwardNavigationGestures = true
        view.scrollView.contentInsetAdjustmentBehavior = .never
        let pull = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePull(_:)))
        pull.delegate = context.coordinator
        pull.cancelsTouchesInView = false
        pull.delaysTouchesBegan = false
        pull.delaysTouchesEnded = false
        pull.minimumNumberOfTouches = 1
        pull.maximumNumberOfTouches = 1
        view.scrollView.addGestureRecognizer(pull)
        context.coordinator.loadedURL = url
        context.coordinator.pushChangeCount = pushChangeCount
        // Ownership is resolved from the attached UIWindowScene in updateUIView.
        // Do not let a newly created sibling consume the app-global tap here.
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
        private var controlsPull = BrowserControlsPullGesture()
        var reloadCount = 0
        var backCount = 0
        var authenticatedCount = 0
        var backObservation: NSKeyValueObservation?
        var urlObservation: NSKeyValueObservation?
        var pushChangeCount = 0
        private var handledPushNavigation: UUID?
        private var bridge: WebMCPBridge?
        private(set) var pushBridge: NativePushBridge?
        private var registeredPushWindowID: String?
        private var recoveryPending = false
        private var lastAutomaticRecovery: TimeInterval?
        private var voiceTask: Task<Void, Never>?
        private var voiceID: UUID?
        private var voiceNavigated = false
        private var voiceClicked = false

        init(_ parent: BrowserView) {
            self.parent = parent
            // A recreated view already loads once in makeUIView. Do not replay
            // old native commands on its first SwiftUI update.
            reloadCount = parent.reloadCount
            backCount = parent.backCount
            authenticatedCount = parent.authenticatedCount
        }

        func tearDown() {
            MainActor.assumeIsolated { pushBridge?.documentCommitted() }
            controlsPull.reset()
            voiceTask?.cancel()
            voiceTask = nil
            backObservation?.invalidate()
            backObservation = nil
            urlObservation?.invalidate()
            urlObservation = nil
            bridge?.uninstall()
            bridge = nil
            pushBridge?.uninstall()
            pushBridge = nil
            recoveryPending = false
        }

        private var nativeDestinationID: UUID?

        func update(_ view: WKWebView, parent: BrowserView) {
            self.parent = parent
            let destination = parent.nativeDestination
            let nativeNavigation = destination != nil && destination?.id != nativeDestinationID
            nativeDestinationID = destination?.id
            if let scene = view.window?.windowScene {
                registerPushScene(scene)
            }
            if parent.scenePhase != .active || parent.isSigningIn || parent.loginRequired || parent.loadError != nil {
                if let scene = view.window?.windowScene {
                    MainActor.assumeIsolated { parent.push?.windows.release(windowID: PushCenter.windowID(for: scene)) }
                }
            }
            let serverChanged = loadedURL != parent.url
            let reloadRequested = reloadCount != parent.reloadCount
            let authenticated = authenticatedCount != parent.authenticatedCount
            let backRequested = backCount != parent.backCount
            if serverChanged || backRequested || reloadRequested || parent.voiceLaunch == nil {
                cancelVoiceLaunch(error: serverChanged || backRequested || reloadRequested
                                  ? "Voice launch cancelled by navigation. Try the shortcut again." : nil)
            }
            loadedURL = parent.url
            reloadCount = parent.reloadCount
            authenticatedCount = parent.authenticatedCount
            backCount = parent.backCount
            let pushBridgeChanged = syncPushBridge(url: parent.url, center: parent.push,
                                                   controller: view.configuration.userContentController)
            let toolsChanged = syncDeviceTools(url: parent.url, registry: parent.deviceTools,
                                               controller: view.configuration.userContentController) || pushBridgeChanged

            // Coalesce native changes into one navigation. Server changes and
            // fresh auth always take precedence over reload/back commands.
            if serverChanged || authenticated {
                resetRecovery()
                rejectedHTTPResponse = false
                view.load(URLRequest(url: !serverChanged && authenticated && voiceNavigated && !voiceClicked
                                     ? (parent.voiceLaunch?.url ?? parent.url) : parent.url))
            } else if nativeNavigation, let destination,
                      sameOrigin(destination.url, parent.url) {
                resetRecovery()
                rejectedHTTPResponse = false
                view.load(URLRequest(url: destination.url))
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
            } else if toolsChanged, voiceTask == nil, view.url != nil, !rejectedHTTPResponse, !parent.isSigningIn,
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
            if !serverChanged && !backRequested && !reloadRequested {
                startVoiceLaunchIfNeeded(view)
            }
            if let navigation = parent.pushNavigation, let scene = view.window?.windowScene,
               navigation.windowID == MainActor.assumeIsolated({ PushCenter.windowID(for: scene) }),
               navigation.id != handledPushNavigation, sameOrigin(navigation.url, parent.url) {
                cancelVoiceLaunch(error: "Voice launch interrupted by notification tap.")
                resetRecovery()
                rejectedHTTPResponse = false
                view.load(URLRequest(url: navigation.url))
                handlePushNavigation(navigation)
            }
            if pushChangeCount != parent.pushChangeCount {
                pushChangeCount = parent.pushChangeCount
                if let current = view.url, sameOrigin(current, parent.url), !view.isLoading {
                    view.evaluateJavaScript(NativePushBridge.changeScript, completionHandler: nil)
                }
            }
        }

        func registerPushScene(_ scene: UIWindowScene) {
            let id = MainActor.assumeIsolated { PushCenter.windowID(for: scene) }
            MainActor.assumeIsolated { parent.push?.registerWindow(id, scene: scene) }
            guard registeredPushWindowID != id else { return }
            registeredPushWindowID = id
            let ready = parent.onPushWindowReady
            DispatchQueue.main.async { ready(id) }
        }

        /// Only the exact owner scene may mark a notification tap consumed.
        func handlePushNavigation(_ navigation: PushNavigation) {
            handledPushNavigation = navigation.id
            let done = parent.onPushNavigationHandled
            DispatchQueue.main.async { done(navigation.id) }
        }

        private var pushContentIsVisible: Bool {
            parent.isContentVisible && parent.scenePhase == .active && !parent.isSigningIn
                && !parent.loginRequired && parent.loadError == nil
        }

        /// Installs the push bridge for the configured server's origin.
        /// Returns true when the injected script changed.
        @discardableResult
        func syncPushBridge(url: URL, center: PushCenter?, controller: WKUserContentController) -> Bool {
            if let pushBridge, let center, pushBridge.serverURL == url, pushBridge.center === center {
                MainActor.assumeIsolated { pushBridge.setContentVisible(pushContentIsVisible) }
                return false
            }
            if pushBridge == nil && center == nil { return false }
            pushBridge?.uninstall()
            pushBridge = nil
            if let center {
                let bridge = MainActor.assumeIsolated {
                    let bridge = NativePushBridge(serverURL: url, center: center)
                    bridge.setContentVisible(pushContentIsVisible)
                    return bridge
                }
                bridge.install(into: controller)
                pushBridge = bridge
            }
            return true
        }

        private func finishVoiceLaunch(_ id: UUID, error: String? = nil) {
            guard voiceID == id else { return }
            voiceTask = nil
            // Keep the ID until ContentView consumes the result, preventing replay.
            let completion = parent.onVoiceLaunchFinished
            DispatchQueue.main.async { completion(id, error) }
        }

        private func cancelVoiceLaunch(error: String?) {
            voiceTask?.cancel()
            voiceTask = nil
            if let id = voiceID, let error { finishVoiceLaunch(id, error: error) }
            if parent.voiceLaunch == nil { voiceID = nil }
        }

        private func startVoiceLaunchIfNeeded(_ view: WKWebView) {
            guard let request = parent.voiceLaunch, voiceID != request.id,
                  parent.scenePhase == .active, !parent.isSigningIn else { return }
            voiceTask?.cancel()
            voiceID = request.id
            voiceNavigated = false
            voiceClicked = false
            voiceTask = Task { @MainActor [weak self, weak view] in
                // Leave the SwiftUI update pass before issuing browser commands.
                await Task.yield()
                guard let self, let view, !Task.isCancelled else { return }
                guard self.sameOrigin(request.url, self.parent.url) else {
                    self.finishVoiceLaunch(request.id, error: "The voice destination must belong to the configured server.")
                    return
                }
                // Do not navigate away from a call, even to a different agent.
                if let current = view.url, self.sameOrigin(current, self.parent.url),
                   let state = try? await self.voiceState(view, script: VoiceLaunchScript.inspect), state == "active" {
                    guard !Task.isCancelled else { return }
                    self.finishVoiceLaunch(request.id)
                    return
                }
                guard !Task.isCancelled, self.parent.voiceLaunch?.id == request.id else { return }
                self.voiceNavigated = true
                view.load(URLRequest(url: request.url))
                var readyTicks = 0
                // Pause the readiness budget for sign-in and backgrounding, but
                // never leave an invocation pending indefinitely.
                for _ in 0..<480 {
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                    guard !Task.isCancelled, self.parent.voiceLaunch?.id == request.id else { return }
                    guard self.parent.scenePhase == .active, !self.parent.isSigningIn,
                          !self.parent.loginRequired else { continue }
                    if self.parent.loadError != nil {
                        self.finishVoiceLaunch(request.id, error: "Couldn't load the voice destination. Retry the page, then run the shortcut again.")
                        return
                    }
                    guard !view.isLoading, !self.parent.loading else { continue }
                    guard let current = view.url, self.sameOrigin(current, request.url),
                          request.allowsPath(current, afterStart: self.voiceClicked) else {
                        self.finishVoiceLaunch(request.id, error: "The page navigated away from the voice destination. Try again after signing in.")
                        return
                    }
                    readyTicks += 1
                    let script = self.voiceClicked ? VoiceLaunchScript.confirm : VoiceLaunchScript.start
                    let state = try? await self.voiceState(view, script: script)
                    guard !Task.isCancelled else { return }
                    switch state {
                    case "active":
                        self.finishVoiceLaunch(request.id)
                        return
                    case "clicked":
                        self.voiceClicked = true
                    case "failed":
                        self.finishVoiceLaunch(request.id, error: "Live voice couldn't start. Check the page's voice error and tap Live to retry.")
                        return
                    default: break
                    }
                    if readyTicks >= 120 { break }
                }
                self.finishVoiceLaunch(request.id, error: "Live voice didn't become ready. Check microphone permission and tap Live on the page. The server must have Live enabled.")
            }
        }

        func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
            func port(_ url: URL) -> Int { url.port ?? (url.scheme == "https" ? 443 : 80) }
            return lhs.scheme?.lowercased() == rhs.scheme?.lowercased() &&
                lhs.host?.lowercased() == rhs.host?.lowercased() && port(lhs) == port(rhs)
        }

        private func voiceState(_ view: WKWebView, script: String) async throws -> String? {
            try await view.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page) as? String
        }

        private func resetRecovery() {
            recoveryPending = false
            lastAutomaticRecovery = nil
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            if voiceTask != nil {
                cancelVoiceLaunch(error: "The voice page stopped unexpectedly. Run the shortcut again after recovery.")
            }
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
            if controlsPull.update(state: gesture.state, location: gesture.location(in: scrollView),
                                   translation: gesture.translation(in: scrollView),
                                   boundsMinY: scrollView.bounds.minY) {
                parent.onRevealControls()
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            // A provisional load may fail, be cancelled or become a download.
            // The still-live document keeps its binding until actual commit.
            rejectedHTTPResponse = false
            parent.loading = true
            parent.loadError = nil
            parent.loginRequired = false
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            MainActor.assumeIsolated {
                let owner: String?
                if let scene = webView.window?.windowScene { owner = PushCenter.windowID(for: scene) }
                else { owner = nil }
                pushBridge?.documentCommitted(windowID: owner)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let scene = webView.window?.windowScene {
                registerPushScene(scene)
            }
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
            guard parent.allowsMediaCapture else {
                decisionHandler(.deny)
                return
            }
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
