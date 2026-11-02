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

    nonisolated static func recovery(for response: HTTPURLResponse) -> Recovery? {
        guard response.statusCode >= 400 else { return nil }
        if response.statusCode == 401,
           response.value(forHTTPHeaderField: "X-Term-Llm-Login-Url") != nil {
            return .signIn
        }
        return .httpError(response.statusCode)
    }

    nonisolated static func shouldRevokeAuthorization(for response: HTTPURLResponse,
                                                      isLinkedDevices: Bool) -> Bool {
        guard isLinkedDevices else { return response.statusCode == 401 || response.statusCode == 403 }
        return response.statusCode == 401 &&
            response.value(forHTTPHeaderField: PeerAuthorizationLoss.headerName) == PeerAuthorizationLoss.headerValue
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
    /// Mac-only text scale. WebKit page zoom stays at 100% so viewport-sized
    /// headers and composers continue to fit. Phone/iPad sizing is untouched.
    var textScale: Double = 1.25
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
    var websiteDataStore: WKWebsiteDataStore? = nil
    var authenticationScript: String? = nil
    /// Isolated source pages may never commit an ancestor/sibling same-origin
    /// document: direct frontend token storage is origin-wide, not path-wide.
    var connectionMount: URL? = nil
    /// Explicit capture master switch. Linked sources additionally require the
    /// validated bridge's main-frame microphone-only policy below.
    var allowsMediaCapture = true
    /// Uses authenticated bridge metadata to distinguish remote 401 from local
    /// capability/scope failures. Ordinary HTTP sources keep legacy behavior.
    var isLinkedDevices = false
    var onAuthorizationRevoked: () -> Void = {}
    /// Committed main document only; provisional destinations are not retained context.
    var onDocumentCommitted: (URL) -> Void = { _ in }
    /// The page started or stopped capturing the microphone or camera (a Live
    /// call). Reported as stopped when the view goes away mid-capture.
    var onMediaCaptureChange: (Bool) -> Void = { _ in }
    /// Watches this page's web content; nil disables monitoring (tests, legacy fixture).
    var health: WebKitHealthMonitor? = nil
    /// The monitor asks to close this web view (runaway, hung or paused page),
    /// with the page's current same-mount URL to reopen later.
    var onHealthTeardown: (WebKitTeardownReason, String, URL?) -> Void = { _, _, _ in }

    /// Pure WebKit permission policy; granting here does not bypass iOS's
    /// app-level microphone authorization. No capture API is called natively.
    func mediaCaptureDecision(originScheme: String, originHost: String, originPort: Int,
                              frameURL: URL?, isMainFrame: Bool,
                              type: WKMediaCaptureType) -> WKPermissionDecision {
        guard allowsMediaCapture else { return .deny }
        let matchesOrigin = isHubOrigin(scheme: originScheme, host: originHost, port: originPort)
        if isLinkedDevices {
            guard type == .microphone, isMainFrame, matchesOrigin,
                  let mount = connectionMount, HubConnectionStore.isLinkedDevicesBridgeURL(mount),
                  HubNavigation.isWithinMount(url, server: mount),
                  let frameURL, HubNavigation.isWithinMount(frameURL, server: mount) else { return .deny }
            // Pairing is not microphone consent. Keep WebKit's per-origin
            // permission prompt as well as iOS's app-level authorization.
            return .prompt
        }
        // Preserve the ordinary HTTP/HTTPS policy, including WebKit prompts
        // for cameras, other origins and combined capture requests.
        return type == .microphone && matchesOrigin ? .grant : .prompt
    }

    private func isHubOrigin(scheme originScheme: String, host originHost: String, port originPort: Int) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return false }
        let defaultPort = scheme == "https" ? 443 : scheme == "http" ? 80 : 0
        return originScheme.lowercased() == scheme && originHost.lowercased() == host &&
            (originPort == 0 ? defaultPort : originPort) == (url.port ?? defaultPort)
    }

    nonisolated static func normalizedMacTextScale(_ value: Double) -> Double {
        DesktopChatAppearance.clamped(value)
    }

    static func configureMacBrowsing(_ configuration: WKWebViewConfiguration, isMac: Bool) {
        guard isMac else { return }
        // This is a UIKit WebView even on Mac. Its desktop content mode can
        // impose a wide effective viewport, then shrink/clip that layout inside
        // a narrow app window. Honor the page's width=device-width viewport;
        // responsive CSS still selects the desktop layout when there is room.
        // Readability is controlled independently by text scaling, not by
        // fitting an oversized desktop canvas into the native bounds.
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
    }

    private static let macTextSizingMarker = "// term-llm Mac text sizing\n"

    nonisolated static func macTextSizingScript(_ value: Double) -> String {
        let percent = normalizedMacTextScale(value) * 100
        return """
        // term-llm Mac text sizing
        (() => {
            const size = '\(percent)%';
            for (const element of [document.documentElement, document.body]) {
                if (!element) continue;
                for (const property of ['-webkit-text-size-adjust', 'text-size-adjust']) {
                    if (element.style.getPropertyValue(property) !== size ||
                        element.style.getPropertyPriority(property) !== 'important') {
                        element.style.setProperty(property, size, 'important');
                    }
                }
            }
        })();
        """
    }

    /// UIKit pageZoom changes the visual viewport without consistently resizing
    /// fixed 100%-wide layouts. Use WebKit's text-only adjustment instead: text
    /// reflows at the real width, and no navigation, draft or DOM replacement is
    /// needed. The presentation script has no native handlers or credentials.
    static func applyMacTextScale(_ value: Double, to view: WKWebView, isMac: Bool,
                                  documentFinished: Bool = false) {
        guard isMac else { return }
        if abs(view.pageZoom - 1) > 0.001 { view.pageZoom = 1 }
        let source = macTextSizingScript(value)
        let controller = view.configuration.userContentController
        let previous = controller.userScripts.first { $0.source.hasPrefix(macTextSizingMarker) }
        let changed = previous?.source != source
        if changed {
            if let previous { controller.removeUserScript(previous) }
            controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd,
                                                  forMainFrameOnly: true, in: .defaultClient))
        }
        // Reapply on commit completion if a preference changed during a load.
        // Normal SwiftUI/polling updates with an unchanged size do no page work.
        if (changed || documentFinished), view.url != nil {
            view.evaluateJavaScript(source, in: nil, in: .defaultClient) { _ in }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        Self.configureMacBrowsing(configuration, isMac: ProcessInfo.processInfo.isiOSAppOnMac)
        configuration.websiteDataStore = websiteDataStore ?? (HubFixture.isEnabled ? HubFixture.websiteDataStore : .default())
        if let authenticationScript {
            configuration.userContentController.addUserScript(WKUserScript(source: authenticationScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        configuration.allowsInlineMediaPlayback = true
        configuration.userContentController.addUserScript(WKUserScript(source: LiveHangUp.userScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        context.coordinator.syncPushBridge(url: url, center: push, controller: configuration.userContentController)
        context.coordinator.syncDeviceTools(url: url, registry: deviceTools, controller: configuration.userContentController)
        let view = WKWebView(frame: .zero, configuration: configuration)
        Self.applyMacTextScale(textScale, to: view, isMac: ProcessInfo.processInfo.isiOSAppOnMac)
        context.coordinator.webView = view
        context.coordinator.syncHealth(view)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.appWillStartPlayback),
                                               name: .appWillStartPlayback, object: nil)
#if DEBUG
        view.isInspectable = true
#endif
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        context.coordinator.backObservation = view.observe(\.canGoBack, options: [.new]) { [weak coordinator = context.coordinator] webView, _ in
            MainActor.assumeIsolated { coordinator?.parent.canGoBack = webView.canGoBack }
        }
        context.coordinator.urlObservation = view.observe(\.url, options: [.initial, .new]) { [weak coordinator = context.coordinator] webView, _ in
            MainActor.assumeIsolated { coordinator?.parent.push?.visibleURL = webView.url }
        }
        context.coordinator.captureObservations = [
            view.observe(\.microphoneCaptureState, options: [.new]) { [weak coordinator = context.coordinator] webView, _ in
                MainActor.assumeIsolated { coordinator?.setMediaCapturing(webView.isCapturingMedia) }
            },
            view.observe(\.cameraCaptureState, options: [.new]) { [weak coordinator = context.coordinator] webView, _ in
                MainActor.assumeIsolated { coordinator?.setMediaCapturing(webView.isCapturingMedia) }
            },
        ]
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
        Self.applyMacTextScale(textScale, to: view, isMac: ProcessInfo.processInfo.isiOSAppOnMac)
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
        var captureObservations: [NSKeyValueObservation] = []
        /// What `onMediaCaptureChange` last reported.
        private(set) var capturingMedia = false
        var pushChangeCount = 0
        private var handledPushNavigation: UUID?
        private(set) var bridge: WebMCPBridge?
        private(set) var pushBridge: NativePushBridge?
        private var registeredPushWindowID: String?
        private weak var registeredPushScene: UIWindowScene?
        private var recoveryPending = false
        private var lastAutomaticRecovery: TimeInterval?
        private var voiceTask: Task<Void, Never>?
        private var voiceID: UUID?
        private var voiceNavigated = false
        private var voiceClicked = false
        weak var webView: WKWebView?
        /// Only invocations that actually started playback may delay handover.
        private var playbackCallIDs: Set<UUID> = []
        private var hangUpGeneration = UUID()
        private(set) var hangUpTask: Task<Void, Never>?
        /// Injectable so lifecycle tests can release grace without wall-clock sleeps.
        var waitForPlaybackHandoverGrace: @Sendable () async throws -> Void = {
            try await Task.sleep(for: LiveHangUp.toolResultGrace)
        }
        private var healthBridge: WebKitHealthBridge?
        private(set) var healthSession: WebKitPageSession?
        /// The page is unloading before the monitor's requested close.
        private(set) var closingPage = false
        private var closingNavigation: WKNavigation?
        private var closingFinish: (() -> Void)?
        private var closingTimeout: Task<Void, Never>?
        static let blankPage = URL(string: "about:blank")!

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
            NotificationCenter.default.removeObserver(self, name: .appWillStartPlayback, object: nil)
            invalidatePlaybackHandover(cancelPageRequest: true)
            MainActor.assumeIsolated { bridge?.onCallReplied = nil }
            backObservation?.invalidate()
            backObservation = nil
            urlObservation?.invalidate()
            urlObservation = nil
            captureObservations.forEach { $0.invalidate() }
            captureObservations = []
            setMediaCapturing(false)
            bridge?.uninstall()
            bridge = nil
            pushBridge?.uninstall()
            pushBridge = nil
            healthBridge?.uninstall()
            healthBridge = nil
            if let healthSession { MainActor.assumeIsolated { parent.health?.detach(healthSession) } }
            healthSession = nil
            closingTimeout?.cancel()
            closingTimeout = nil
            closingFinish = nil
            closingNavigation = nil
            closingPage = false
            recoveryPending = false
        }

        /// Creates this view's health session and keeps the probe matching the
        /// configured origin and setting. Script changes apply to the next document.
        func syncHealth(_ view: WKWebView) {
            MainActor.assumeIsolated {
                guard let monitor = parent.health else {
                    healthBridge?.uninstall()
                    healthBridge = nil
                    return
                }
                if healthSession == nil {
                    let session = monitor.makeSession(for: view)
                    session.contextProvider = { [weak self, weak view] in
                        guard let self, let view else { return WebKitPageContext() }
                        return self.healthContext(view)
                    }
                    session.onTeardown = { [weak self] reason, detail in
                        self?.closePage(reason: reason, detail: detail)
                    }
                    healthSession = session
                }
                let controller = view.configuration.userContentController
                if monitor.probeEnabled {
                    if healthBridge?.serverURL != parent.url || healthBridge?.isInstalled != true {
                        healthBridge?.uninstall()
                        let bridge = WebKitHealthBridge(serverURL: parent.url)
                        bridge.onSample = { [weak self] sample, _ in
                            MainActor.assumeIsolated {
                                guard let self, let session = self.healthSession else { return }
                                self.parent.health?.record(sample, from: session)
                            }
                        }
                        bridge.install(into: controller)
                        healthBridge = bridge
                    }
                } else if let healthBridge {
                    healthBridge.uninstall()
                    self.healthBridge = nil
                }
            }
        }

        @MainActor
        private func healthContext(_ view: WKWebView) -> WebKitPageContext {
            let background = UIApplication.shared.applicationState == .background
            return WebKitPageContext(
                userCanSee: Self.healthPageIsOnScreen(parent, inWindow: view.window != nil, appBackground: background),
                appBackground: background,
                inWindow: view.window != nil,
                viewHidden: view.isHidden,
                capturing: capturingMedia,
                voiceLaunching: voiceTask != nil,
                toolCalls: bridge?.activeCalls ?? 0,
                signingIn: parent.isSigningIn,
                loading: parent.loading || view.isLoading)
        }

        /// Hands the web view to the parent to close. A page that still runs
        /// first unloads, so its own handlers save the unsent draft (the
        /// frontend persists it on beforeunload, not per keystroke). A hung
        /// page cannot run any handler and closes at once.
        @MainActor
        func closePage(reason: WebKitTeardownReason, detail: String, grace: Duration = .seconds(2)) {
            guard !closingPage else { return }
            let restore = restorableURL()
            let finish = { [weak self] in
                guard let self else { return }
                self.closingTimeout?.cancel()
                self.closingTimeout = nil
                self.parent.onHealthTeardown(reason, detail, restore)
            }
            guard reason != .unresponsive, let view = webView, view.url != nil, view.url != Self.blankPage else {
                finish()
                return
            }
            closingPage = true
            closingFinish = finish
            view.evaluateJavaScript(Self.unloadScript) { [weak self, weak view] _, error in
                MainActor.assumeIsolated {
                    // Could not run in the page: unload it from here (pagehide only).
                    guard error != nil, let self, self.closingFinish != nil, let view else { return }
                    self.closingNavigation = view.load(URLRequest(url: Self.blankPage))
                }
            }
            closingTimeout = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: grace) } catch { return }
                self?.finishClosing()
            }
        }

        /// WKWebView never dispatches beforeunload here (measured: neither for
        /// loads the app starts nor for the page's own navigations), so the
        /// page's beforeunload listeners are run explicitly, as a browser would
        /// before leaving. Leaving then runs pagehide and unload. Only DOM
        /// lifecycle events; no frontend state is touched.
        static let unloadScript = """
        try { window.dispatchEvent(new Event('beforeunload', { cancelable: true })); } catch {}
        location.replace('about:blank'); void 0;
        """

        /// The old document has unloaded (or could not): let the parent close the view.
        private func finishClosing() {
            guard let finish = closingFinish else { return }
            closingFinish = nil
            finish()
        }

        /// The page's current route if it is still this connection's page;
        /// otherwise the configured root. Never a login route or another mount.
        func restorableURL() -> URL? {
            guard let current = webView?.url, sameOrigin(current, parent.url), !isLoginRoute(current),
                  parent.connectionMount.map({ HubNavigation.isWithinMount(current, server: $0) }) ?? true else { return parent.url }
            return current
        }

        private func refreshHealth() {
            guard let healthSession else { return }
            MainActor.assumeIsolated { parent.health?.refresh(healthSession) }
        }

        func setMediaCapturing(_ capturing: Bool) {
            guard capturing != capturingMedia else { return }
            capturingMedia = capturing
            parent.onMediaCaptureChange(capturing)
            refreshHealth()
        }

        private var nativeDestinationID: UUID?

        func update(_ view: WKWebView, parent: BrowserView) {
            if self.parent.isContentVisible && !parent.isContentVisible {
                // Keep the document alive when returning to the native Hub, but
                // do not let its hidden focused input cover the native screens.
                // This is a native responder handoff, not JS or a navigation.
                view.endEditing(true)
            }
            // Mirror native visibility. This alone does not throttle the page:
            // WebKit runs a web view as visible while it is in a window,
            // whatever `isHidden` says (measured: timers, animation frames and
            // visibilityState are unchanged). Leaving the window hides it; the
            // tab view detaches a hidden tab's view, and the health monitor
            // reports a page that keeps running as visible off screen.
            let hidden = !parent.isContentVisible
            if view.isHidden != hidden { view.isHidden = hidden }
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
            syncHealth(view)

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
               navigation.id != handledPushNavigation,
               HubNavigation.isWithinMount(navigation.url, server: parent.connectionMount ?? parent.url) {
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
            refreshHealth()
        }

        func registerPushScene(_ scene: UIWindowScene) {
            // Runs on every SwiftUI update of the browser. Registration persists
            // a scene-session map in UserDefaults, so only redo it when the scene
            // (or its identifier) actually changes, not on every render pass.
            guard registeredPushWindowID == nil || registeredPushScene !== scene else { return }
            let id = MainActor.assumeIsolated { PushCenter.windowID(for: scene) }
            MainActor.assumeIsolated { parent.push?.registerWindow(id, scene: scene) }
            registeredPushScene = scene
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

        /// On screen for the health monitor. Unlike notification presence, an
        /// inactive scene counts: a Mac window without focus, iPad multitasking
        /// or Control Center still shows the page, and WebKit runs it as visible.
        /// Treating that as hidden flagged a false mismatch and could stop a
        /// page the user can see.
        @MainActor
        static func healthPageIsOnScreen(_ parent: BrowserView, inWindow: Bool, appBackground: Bool) -> Bool {
            parent.isContentVisible && parent.scenePhase != .background && !appBackground && inWindow
                && !parent.isSigningIn && !parent.loginRequired && parent.loadError == nil
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
            invalidatePlaybackHandover(cancelPageRequest: false)
            if let healthSession { MainActor.assumeIsolated { parent.health?.contentProcessTerminated(healthSession) } }
            if closingPage {
                // Nothing left to unload; the view is closing anyway.
                finishClosing()
                return
            }
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

        /// This app is about to play music or a podcast: end this page's live
        /// call, which would otherwise keep listening over the audio.
        @objc func appWillStartPlayback() {
            guard !closingPage, let view = webView, let current = view.url, sameOrigin(current, parent.url),
                  !MainActor.assumeIsolated({ WebMCPBridge.hasStalePlaybackInvocation }) else { return }
            if let callID = MainActor.assumeIsolated({ bridge?.currentPlaybackCallID }) {
                // Repeated starts from this invocation coalesce. A newer playback
                // tool supersedes an already-armed grace request without letting
                // that older request discard the newer tool's result.
                if hangUpTask != nil { cancelPlaybackGrace(cancelPageRequest: true) }
                playbackCallIDs.insert(callID)
            } else if playbackCallIDs.isEmpty {
                cancelPlaybackGrace(cancelPageRequest: true)
                Self.runHangUpScript(LiveHangUp.requestScript(afterToolResult: false), in: view)
            }
        }

        private func deviceToolCallReplied(_ callID: UUID) {
            guard playbackCallIDs.remove(callID) != nil, playbackCallIDs.isEmpty else { return }
            guard !closingPage, let view = webView, let current = view.url, sameOrigin(current, parent.url) else { return }
            Self.runHangUpScript(LiveHangUp.requestScript(afterToolResult: true), in: view)
            let generation = hangUpGeneration
            let waitForGrace = waitForPlaybackHandoverGrace
            hangUpTask = Task { @MainActor [weak self, weak view] in
                do { try await waitForGrace() } catch { return }
                guard !Task.isCancelled, let self, self.hangUpGeneration == generation else { return }
                self.hangUpTask = nil
                guard let view, self.webView === view, !self.closingPage,
                      let current = view.url, self.sameOrigin(current, self.parent.url) else { return }
                Self.runHangUpScript(LiveHangUp.flushScript, in: view)
            }
        }

        private func cancelPlaybackGrace(cancelPageRequest: Bool) {
            if hangUpTask != nil, cancelPageRequest, let view = webView {
                Self.runHangUpScript(LiveHangUp.cancelScript, in: view)
            }
            hangUpGeneration = UUID()
            hangUpTask?.cancel()
            hangUpTask = nil
        }

        private func invalidatePlaybackHandover(cancelPageRequest: Bool) {
            cancelPlaybackGrace(cancelPageRequest: cancelPageRequest)
            playbackCallIDs.removeAll()
            MainActor.assumeIsolated { bridge?.invalidatePlaybackInvocations() }
        }

        /// Fire-and-forget; the scripts evaluate to undefined.
        private static func runHangUpScript(_ script: String, in view: WKWebView) {
            view.evaluateJavaScript(script, completionHandler: nil)
        }

        /// Installs, replaces, or removes the WebMCP bridge. Returns true when
        /// the injected script changed, so the current page must reload.
        @discardableResult
        func syncDeviceTools(url: URL, registry: DeviceToolRegistry?, controller: WKUserContentController) -> Bool {
            if let bridge, let registry, bridge.serverURL == url, bridge.registry === registry { return false }
            if bridge == nil && registry == nil { return false }
            invalidatePlaybackHandover(cancelPageRequest: true)
            MainActor.assumeIsolated { bridge?.onCallReplied = nil }
            bridge?.uninstall()
            bridge = nil
            if let registry {
                let bridge = WebMCPBridge(serverURL: url, registry: registry, device: UIDevice.current.model)
                MainActor.assumeIsolated {
                    bridge.onCallReplied = { [weak self, weak bridge] callID in
                        guard let self, let bridge, self.bridge === bridge else { return }
                        self.deviceToolCallReplied(callID)
                    }
                }
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
            // The unload before a requested close is not a page load.
            guard !closingPage else { return }
            // A provisional load may fail, be cancelled or become a download.
            // The still-live document keeps its binding until actual commit.
            rejectedHTTPResponse = false
            parent.loading = true
            parent.loadError = nil
            parent.loginRequired = false
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            // Provisional navigation does not retire the still-live document.
            // At actual commit, never send an old request/flush to the new page.
            invalidatePlaybackHandover(cancelPageRequest: false)
            if closingPage {
                // The chat document has unloaded and saved its draft.
                MainActor.assumeIsolated { pushBridge?.documentCommitted() }
                if webView.url == Self.blankPage { finishClosing() }
                return
            }
            if let url = webView.url { parent.onDocumentCommitted(url) }
            MainActor.assumeIsolated {
                if let healthSession { parent.health?.documentWillChange(healthSession) }
                let owner: String?
                if let scene = webView.window?.windowScene { owner = PushCenter.windowID(for: scene) }
                else { owner = nil }
                pushBridge?.documentCommitted(windowID: owner)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !closingPage else { return }
            BrowserView.applyMacTextScale(parent.textScale, to: webView,
                                          isMac: ProcessInfo.processInfo.isiOSAppOnMac, documentFinished: true)
            if let scene = webView.window?.windowScene {
                registerPushScene(scene)
            }
            rejectedHTTPResponse = false
            parent.loading = false
            parent.loadError = nil
            parent.loginRequired = false
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
            if closingPage {
                decisionHandler(navigationResponse.response.url == Self.blankPage ? .allow : .cancel)
                return
            }
            if let mount = parent.connectionMount,
               let destination = navigationResponse.response.url,
               !HubNavigation.isWithinMount(destination, server: mount) {
                decisionHandler(.cancel)
                return
            }
            guard navigationResponse.isForMainFrame,
                  let response = navigationResponse.response as? HTTPURLResponse,
                  let recovery = BrowserView.recovery(for: response) else {
                decisionHandler(.allow)
                return
            }
            rejectedHTTPResponse = true
            parent.loading = false
            if BrowserView.shouldRevokeAuthorization(for: response,
                                                      isLinkedDevices: parent.isLinkedDevices) {
                parent.onAuthorizationRevoked()
            }
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
            if closingPage {
                // The unload page itself failed: close anyway. A cancelled
                // earlier load is not the unload.
                if navigation === closingNavigation { finishClosing() }
                return
            }
            fail(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if closingPage {
                if navigation === closingNavigation { finishClosing() }
                return
            }
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
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            guard let destination = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if closingPage {
                // Only the unload page; nothing may start while the view closes.
                decisionHandler(destination == Self.blankPage && navigationAction.targetFrame?.isMainFrame != false ? .allow : .cancel)
                return
            }
            if let mount = parent.connectionMount, !HubNavigation.isWithinMount(destination, server: mount) {
                // Never load a sibling/ancestor into this credential's origin
                // storage. An explicit external link may leave in Safari.
                if navigationAction.navigationType == .linkActivated, navigationAction.targetFrame?.isMainFrame != false {
                    UIApplication.shared.open(destination)
                }
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
                if let mount = parent.connectionMount, !HubNavigation.isWithinMount(url, server: mount) {
                    UIApplication.shared.open(url)
                } else if isLoginRoute(url) {
                    parent.onLoginRequired()
                } else if url.scheme == parent.url.scheme, url.host == parent.url.host, url.port == parent.url.port {
                    webView.load(navigationAction.request)
                } else {
                    UIApplication.shared.open(url)
                }
            }
            return nil
        }

        // Ordinary configured microphone origins keep their existing grant;
        // linked sources retain a per-origin prompt. iOS owns app authorization.
        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                     decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
            decisionHandler(parent.mediaCaptureDecision(
                originScheme: origin.protocol, originHost: origin.host, originPort: origin.port,
                frameURL: frame.request.url, isMainFrame: frame.isMainFrame, type: type))
        }

        // iOS owns the one-time location authorization; skip WebKit's per-page prompt for the hub.
        @available(iOS 27.0, *)
        func webView(_ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo,
                     decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
            if parent.isLinkedDevices {
                decisionHandler(.deny)
            } else {
                decisionHandler(isHubOrigin(origin) ? .grant : .prompt)
            }
        }

        private func isHubOrigin(_ origin: WKSecurityOrigin) -> Bool {
            parent.isHubOrigin(scheme: origin.protocol, host: origin.host, port: origin.port)
        }

        private func isLoginRoute(_ destination: URL) -> Bool {
            let prefix = parent.url.path.hasSuffix("/") ? String(parent.url.path.dropLast()) : parent.url.path
            return destination.scheme == parent.url.scheme && destination.host == parent.url.host &&
                destination.port == parent.url.port &&
                ["/auth/login", "/auth/setup", "/auth/recover"].contains { destination.path == prefix + $0 }
        }
    }
}

private extension WKWebView {
    var isCapturingMedia: Bool { microphoneCaptureState != .none || cameraCaptureState != .none }
}
