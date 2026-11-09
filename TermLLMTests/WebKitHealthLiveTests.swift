import Network
import SwiftUI
#if os(iOS)
import UIKit
#endif
import WebKit
import XCTest
@testable import TermLLM

/// The real injected probe and the real close path, inside WebKit. Pages are
/// loaded with an https base URL, so no network is involved.
#if os(iOS)
@MainActor
final class WebKitHealthLiveTests: XCTestCase {
    private static let server = URL(string: "https://example.com/ui/")!
    private static let chat = URL(string: "https://example.com/ui/chat/7")!

    /// Draws every frame, runs a composited and a repainting animation, and
    /// changes its DOM ten times a second.
    private static let busyPage = """
    <!doctype html><html><head><meta name="viewport" content="width=device-width"><style>
    @keyframes spin { from { transform: rotate(0deg) } to { transform: rotate(360deg) } }
    @keyframes paint { from { background-position: 0 0 } to { background-position: 100px 0 } }
    .spinner { width: 40px; height: 40px; background: red; animation: spin 1s linear infinite }
    .painter { width: 100px; height: 40px; background: linear-gradient(90deg, red, blue); animation: paint 1s linear infinite }
    </style></head><body><div class="spinner"></div><div class="painter"></div><p id="ticker"></p><script>
    function loop() { requestAnimationFrame(loop); } requestAnimationFrame(loop);
    let n = 0; setInterval(() => { document.getElementById('ticker').textContent = String(n++); }, 100);
    </script></body></html>
    """

    private final class Collected { var samples: [WebPageHealthSample] = [] }

    private final class Messages: NSObject, WKScriptMessageHandler {
        var values: [String] = []
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if let value = message.body as? String { values.append(value) }
        }
    }

    private func host() throws -> UIViewController {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in window.isHidden = true }
        return controller
    }

    private func probedWebView(in controller: UIViewController, collected: Collected,
                               reportMilliseconds: Int = 1_000, hiddenMilliseconds: Int = 2_000) -> WKWebView {
        let bridge = WebKitHealthBridge(serverURL: Self.server, reportMilliseconds: reportMilliseconds,
                                        hiddenMilliseconds: hiddenMilliseconds)
        bridge.onSample = { sample, _ in collected.samples.append(sample) }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        bridge.install(into: configuration.userContentController)
        let web = WKWebView(frame: controller.view.bounds, configuration: configuration)
        controller.view.addSubview(web)
        addTeardownBlock { @MainActor in
            web.stopLoading()
            web.removeFromSuperview()
            bridge.uninstall()
        }
        return web
    }

    private func until(_ what: String, timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func testProbeMeasuresDrawingAnimationsAndDOMChangesThenQuietsWhenHidden() async throws {
        let controller = try host()
        let collected = Collected()
        let web = probedWebView(in: controller, collected: collected)
        web.loadHTMLString(Self.busyPage, baseURL: Self.chat)

        // Reports after the first include a full second of DOM counting.
        try await until("three visible reports") { collected.samples.filter(\.isVisible).count >= 3 }
        let visible = try XCTUnwrap(collected.samples.last(where: \.isVisible))
        XCTAssertGreaterThan(visible.framesPerSecond, 20, "the page's requestAnimationFrame loop")
        XCTAssertEqual(visible.runningAnimations, 2)
        let spin = try XCTUnwrap(visible.animations.first { $0.name == "spin" })
        XCTAssertEqual(spin.properties, ["transform"])
        XCTAssertTrue(spin.composited)
        XCTAssertTrue(spin.infinite)
        XCTAssertEqual(spin.target, "div.spinner")
        let paint = try XCTUnwrap(visible.animations.first { $0.name == "paint" })
        XCTAssertFalse(paint.properties.isEmpty)
        XCTAssertTrue(paint.properties.allSatisfy { $0.hasPrefix("background-position") }, "\(paint.properties)")
        XCTAssertFalse(paint.composited, "a background-position animation repaints every frame")
        XCTAssertGreaterThan(visible.mutationSeconds, 0.5)
        XCTAssertEqual(visible.mutationsPerSecond, 10, accuracy: 6)
        XCTAssertEqual(visible.busyFraction, 0, accuracy: 0.2)

        // What watching costs the page, measured inside it once warmed up (the
        // first reports carry one-off setup and compilation). Reports here come
        // every second, five times the app's rate. WebKit's clock has 1 ms
        // steps, so this is an average over several seconds.
        try await until("eight visible reports") { collected.samples.filter(\.isVisible).count >= 8 }
        let steady = collected.samples.filter(\.isVisible).dropFirst(3)
        let cost = steady.map(\.probeMilliseconds).reduce(0, +) / 1000 / steady.map(\.spanSeconds).reduce(0, +)
        print("WebKit health: page probe \(WebKitHealthReport.costText(cost)) of a core, reporting every second while the page draws every frame")
        XCTAssertLessThan(cost, 0.005, "a regression guard: no per-frame or per-change work in the probe")

        // Leaving the window hides the page: it stops drawing and the probe
        // drops to its hidden cadence without scanning animations or the DOM.
        let before = collected.samples.count
        web.removeFromSuperview()
        try await until("a hidden report") { collected.samples.dropFirst(before).contains { !$0.isVisible } }
        let transition = collected.samples.count
        try await until("a full hidden report") { collected.samples.count > transition }
        let hidden = try XCTUnwrap(collected.samples.last)
        XCTAssertEqual(hidden.visibility, "hidden")
        XCTAssertEqual(hidden.frames, 0)
        XCTAssertEqual(hidden.runningAnimations, 0)
        XCTAssertEqual(hidden.mutationSeconds, 0)
        XCTAssertGreaterThan(hidden.spanSeconds, 1.5, "hidden reports come at the slower cadence")
        XCTAssertEqual(hidden.hiddenSeconds, hidden.spanSeconds, accuracy: 0.2)
    }

    func testProbeStaysOutOfOtherOrigins() async throws {
        let controller = try host()
        let collected = Collected()
        let web = probedWebView(in: controller, collected: collected)
        web.loadHTMLString(Self.busyPage, baseURL: URL(string: "https://other.example/ui/")!)
        try await until("the page") { !web.isLoading && web.url != nil }
        try await Task.sleep(for: .milliseconds(2_500))
        XCTAssertTrue(collected.samples.isEmpty)
        let installed = try await web.evaluateJavaScript("window.__termLLMHealthProbe === true") as? Bool
        XCTAssertEqual(installed, false)
    }

    private final class Closes { var calls: [(WebKitTeardownReason, URL?)] = [] }

    private func chatCoordinator(_ closes: Closes) -> BrowserView.Coordinator {
        var parent = BrowserView(url: Self.server, loading: .constant(false), canGoBack: .constant(false),
                                 loadError: .constant(nil), loginRequired: .constant(false),
                                 reloadCount: 0, backCount: 0, authenticatedCount: 0,
                                 onLoginRequired: {}, onRevealControls: {})
        parent.onHealthTeardown = { reason, _, restore in closes.calls.append((reason, restore)) }
        let coordinator = parent.makeCoordinator()
        coordinator.loadedURL = parent.url
        return coordinator
    }

    /// The frontend saves an unsent draft on beforeunload, not per keystroke,
    /// and WKWebView never fires beforeunload by itself: closing must run the
    /// page's handlers and unload it rather than just dropping the view.
    func testClosingUnloadsThePageFirstSoItCanSaveItsDraft() async throws {
        let controller = try host()
        let closes = Closes()
        let coordinator = chatCoordinator(closes)
        let messages = Messages()
        let store = WKWebsiteDataStore.nonPersistent()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        configuration.userContentController.add(messages, name: "lifecycle")
        let web = WKWebView(frame: controller.view.bounds, configuration: configuration)
        controller.view.addSubview(web)
        coordinator.webView = web
        web.navigationDelegate = coordinator
        addTeardownBlock { @MainActor in
            web.navigationDelegate = nil
            web.removeFromSuperview()
            configuration.userContentController.removeScriptMessageHandler(forName: "lifecycle")
        }
        web.loadHTMLString("""
        <!doctype html><body><textarea>unsent draft</textarea><script>
        addEventListener('beforeunload', () => {
          localStorage.setItem('draft', document.querySelector('textarea').value);
          webkit.messageHandlers.lifecycle.postMessage('beforeunload');
        });
        addEventListener('pagehide', () => webkit.messageHandlers.lifecycle.postMessage('pagehide'));
        </script></body>
        """, baseURL: Self.chat)
        try await until("the chat page") { web.url == Self.chat && !web.isLoading }

        coordinator.closePage(reason: .hiddenActivity, detail: "test")
        XCTAssertTrue(coordinator.closingPage)
        XCTAssertTrue(closes.calls.isEmpty, "waits for the page to unload")
        try await until("the close request") { !closes.calls.isEmpty }
        XCTAssertEqual(closes.calls.count, 1)
        XCTAssertEqual(closes.calls.first?.0, .hiddenActivity)
        XCTAssertEqual(closes.calls.first?.1, Self.chat, "reopens where the page was")
        XCTAssertEqual(web.url, BrowserView.Coordinator.blankPage)
        try await until("the page's unload handlers") {
            messages.values.contains("beforeunload") && messages.values.contains("pagehide")
        }
        // The reopened page finds the draft its handler saved.
        let reader = WKWebViewConfiguration()
        reader.websiteDataStore = store
        let reopened = WKWebView(frame: controller.view.bounds, configuration: reader)
        controller.view.addSubview(reopened)
        reopened.loadHTMLString("<p>reopened</p>", baseURL: Self.chat)
        try await until("the reopened page") { reopened.url == Self.chat && !reopened.isLoading }
        let draft = try await reopened.evaluateJavaScript("localStorage.getItem('draft')") as? String
        XCTAssertEqual(draft, "unsent draft")
        reopened.removeFromSuperview()

        // Nothing else may load into the closing view.
        web.loadHTMLString("<p>late</p>", baseURL: Self.chat)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(web.url, BrowserView.Coordinator.blankPage)
        coordinator.closePage(reason: .manual, detail: "again")
        XCTAssertEqual(closes.calls.count, 1)
    }

    private final class Shown: ObservableObject { @Published var browser = true }

    private struct Shell: View {
        let url: URL
        @ObservedObject var shown: Shown
        let monitor: WebKitHealthMonitor
        var body: some View {
            if shown.browser {
                BrowserView(url: url, loading: .constant(false), canGoBack: .constant(false),
                            loadError: .constant(nil), loginRequired: .constant(false),
                            reloadCount: 0, backCount: 0, authenticatedCount: 0,
                            onLoginRequired: {}, onRevealControls: {}, health: monitor,
                            onHealthTeardown: { _, _, _ in shown.browser = false })
            } else {
                Text("parked")
            }
        }
    }

    private func webViews(in view: UIView) -> [WKWebView] {
        (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webViews(in:))
    }

    /// Closing exists to end the page's web process, which WebKit can only do
    /// once nothing holds the web view any more.
    func testClosedPageReleasesItsWebView() async throws {
        let server = try PageServer()
        addTeardownBlock { server.stop() }
        let page = try await server.start()
        let controller = try host()
        let monitor = WebKitHealthMonitor(defaults: UserDefaults(suiteName: "WebKitHealthLive-\(UUID().uuidString)")!,
                                          journal: nil)
        let shown = Shown()
        let hosting = UIHostingController(rootView: Shell(url: page, shown: shown, monitor: monitor))
        controller.addChild(hosting)
        hosting.view.frame = controller.view.bounds
        controller.view.addSubview(hosting.view)
        hosting.didMove(toParent: controller)
        addTeardownBlock { @MainActor in hosting.view.removeFromSuperview() }

        weak var web: WKWebView?
        try await until("the page") {
            web = webViews(in: hosting.view).first
            return web?.isLoading == false && web?.url == page
        }
        XCTAssertEqual(monitor.sessions.count, 1)
        monitor.tick(now: 1)
        XCTAssertEqual(monitor.status.webViewsAlive, 1)
        monitor.pausePage()
        try await until("the page to close") { !shown.browser }
        try await until("the web view to be released", timeout: .seconds(5)) { web == nil }
        XCTAssertTrue(monitor.sessions.isEmpty)
        monitor.tick(now: 10)
        XCTAssertEqual(monitor.status.webViewsAlive, 0)
    }

    /// A hung page cannot run unload handlers: close it at once.
    func testHungPageClosesAtOnce() async throws {
        let controller = try host()
        let closes = Closes()
        let coordinator = chatCoordinator(closes)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: controller.view.bounds, configuration: configuration)
        controller.view.addSubview(web)
        coordinator.webView = web
        web.navigationDelegate = coordinator
        addTeardownBlock { @MainActor in
            web.navigationDelegate = nil
            web.removeFromSuperview()
        }
        web.loadHTMLString("<p>chat</p>", baseURL: Self.chat)
        try await until("the chat page") { web.url == Self.chat && !web.isLoading }
        coordinator.closePage(reason: .unresponsive, detail: "test")
        XCTAssertEqual(closes.calls.count, 1)
        XCTAssertEqual(closes.calls.first?.1, Self.chat)
        XCTAssertFalse(coordinator.closingPage)
        XCTAssertEqual(web.url, Self.chat, "no unload navigation into a hung page")
    }
}
#endif

/// Loopback HTTP server answering every request with one small page, so a
/// real `BrowserView` can load without the network.
private final class PageServer: @unchecked Sendable {
    static let page = Data("<!doctype html><html><body><p>chat</p></body></html>".utf8)
    private let listener: NWListener
    private let queue = DispatchQueue(label: "WebKitHealthLiveTests.PageServer")

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let resumed = HubTestBox(false)
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    guard !resumed.value else { return }
                    resumed.set(true)
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    guard !resumed.value else { return }
                    resumed.set(true)
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [queue] connection in
                connection.start(queue: queue)
                Self.receive(connection, accumulated: Data())
            }
            listener.start(queue: queue)
        }
        return URL(string: "http://localhost:\(port)/ui/")!
    }

    func stop() { listener.cancel() }

    private static func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, complete, error in
            var bytes = accumulated
            if let data { bytes.append(data) }
            guard bytes.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if error == nil, !complete { receive(connection, accumulated: bytes) } else { connection.cancel() }
                return
            }
            let head = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(page.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + page, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
