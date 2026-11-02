import XCTest
import WebKit
import UIKit
@testable import TermLLM

final class ServerAddressTests: XCTestCase {
    func testNormalization() {
        XCTAssertEqual(ServerAddress.parse("  example.com  ")?.absoluteString, "https://example.com/")
        XCTAssertEqual(ServerAddress.parse("https://example.com/hub/")?.absoluteString, "https://example.com/hub/")
    }

    @MainActor
    func testPublicDemoAddress() {
        XCTAssertEqual(ServerAddress.parse(ServerAddress.demo)?.absoluteString, ServerAddress.demo)
        XCTAssertEqual(ServerAddress.parse("demo.term-llm.com")?.absoluteString, ServerAddress.demo)
        let settings = DeviceToolsSettings(defaults: isolatedDefaults())
        XCTAssertFalse(settings.isEnabled, "device tools are off by default")
    }

    func testPKCEChallengeMatchesRFC7636() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(NativeLogin.challenge(for: verifier), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testNativeOriginNormalizesDefaultHTTPSPort() {
        XCTAssertEqual(NativeLogin.origin(for: URL(string: "https://chat.example.com:443/ui/")!), "https://chat.example.com")
        XCTAssertEqual(NativeLogin.origin(for: URL(string: "https://chat.example.com:8443/ui/")!), "https://chat.example.com:8443")
    }

    func testLocalSimulatorServer() {
        #if targetEnvironment(simulator)
        XCTAssertEqual(ServerAddress.parse("http://localhost:8080/ui/")?.absoluteString, "http://localhost:8080/ui/")
        XCTAssertEqual(NativeLogin.origin(for: URL(string: "http://localhost:8080/ui/")!), "http://localhost:8080")
        XCTAssertEqual(NativeLogin.origin(for: URL(string: "http://localhost:80/ui/")!), "http://localhost")
        #else
        XCTAssertNil(ServerAddress.parse("http://localhost:8080/ui/"))
        #endif
    }

    @MainActor
    func testLinkedDeviceBrowserUsesOnlyItsSavedLoopbackOrigin() throws {
        let url = try XCTUnwrap(URL(string: "http://localhost:43210/chat/"))
        let source = HubConnection(id: UUID(), name: "Desk", kind: .directNode, url: url,
                                   linkedDevicesHostKey: LinkedDevicesBase64URL.encode(Data(repeating: 1, count: 32)))
        // This is the address handed to the Chat shell, not user-entered HTTP.
        XCTAssertEqual(ServerAddress.browserURL(url.absoluteString, selectedConnection: source), url)
        let chat = try XCTUnwrap(HubNavigation.chatDestination("/chat/?new=1", server: url,
                                                              nodeID: "direct-node", direct: true))
        XCTAssertNotNil(ChatTabContext.resolve(connection: source, browserIdentity: UUID(), url: chat, agents: []))
        #if !targetEnvironment(simulator)
        XCTAssertNil(ServerAddress.parse(url.absoluteString), "Ordinary HTTP input must stay rejected on device")
        XCTAssertNil(ServerAddress.browserURL(url.absoluteString, selectedConnection: nil))
        #endif
        for other in ["http://localhost:43211/chat/", "http://localhost:43210/other/",
                      "http://127.0.0.1:43210/chat/", "http://localhost.evil.com:43210/chat/",
                      "http://localhost:43210/chat/?new=1", "http://localhost:43210/chat/#fragment",
                      "http://user:password@localhost:43210/chat/", "https://example.com/"] {
            XCTAssertNil(ServerAddress.browserURL(other, selectedConnection: source), other)
        }
    }

    @MainActor
    func testLinkedDeviceBrowserRejectsUnvalidatedSourceMetadata() throws {
        let url = try XCTUnwrap(URL(string: "http://localhost:43210/chat/"))
        let key = LinkedDevicesBase64URL.encode(Data(repeating: 1, count: 32))
        let sources = [
            HubConnection(id: UUID(), name: "Desk", kind: .hub, url: url, linkedDevicesHostKey: key),
            HubConnection(id: UUID(), name: "Desk", kind: .directNode, url: url, needsKindReview: true, linkedDevicesHostKey: key),
            HubConnection(id: UUID(), name: "Desk", kind: .directNode, url: url, linkedDevicesHostKey: "invalid"),
            HubConnection(id: UUID(), name: "Desk", kind: .directNode,
                          url: URL(string: "http://localhost:80/chat/")!, linkedDevicesHostKey: key)
        ]
        for source in sources {
            XCTAssertNil(ServerAddress.browserURL(source.url.absoluteString, selectedConnection: source))
        }
    }

    @MainActor
    func testBrowserURLKeepsOrdinaryServerPolicy() {
        let url = URL(string: "https://example.com/hub/")!
        let source = HubConnection(id: UUID(), name: "Work", kind: .hub, url: url)
        XCTAssertEqual(ServerAddress.browserURL(url.absoluteString, selectedConnection: source), url)
        XCTAssertEqual(ServerAddress.browserURL(url.absoluteString, selectedConnection: nil), url)
        XCTAssertNil(ServerAddress.browserURL("http://example.com/", selectedConnection: source))
    }

    func testBackgroundAudioEnabledForLiveVoice() {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        XCTAssertTrue(modes?.contains("audio") == true)
    }

    func testLocalServerConnectionsHaveAPrivacyPurposeString() {
        let purpose = Bundle.main.object(forInfoDictionaryKey: "NSLocalNetworkUsageDescription") as? String
        XCTAssertFalse(purpose?.isEmpty ?? true)
    }

    func testHTTPRecoveryDistinguishesLoginFromServerFailures() {
        let url = URL(string: "https://example.com/ui/")!
        func response(_ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
            HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
        }
        XCTAssertNil(BrowserView.recovery(for: response(200)))
        XCTAssertNil(BrowserView.recovery(for: response(302)))
        XCTAssertEqual(BrowserView.recovery(for: response(401, headers: ["X-Term-Llm-Login-Url": "/ui/auth/login"])), .signIn)
        XCTAssertEqual(BrowserView.recovery(for: response(401)), .httpError(401))
        XCTAssertEqual(BrowserView.recovery(for: response(404)), .httpError(404))
        XCTAssertEqual(BrowserView.recovery(for: response(503)), .httpError(503))
    }

    @MainActor
    func testHTTPSMagicDNSAndTailnetMountsAreAcceptedWithoutWeakeningHTTPPolicy() {
        for address in ["desk.tail123.ts.net", "https://desk.tail123.ts.net:8443/hub/", "https://desk/hub/"] {
            XCTAssertNotNil(ServerAddress.parse(address), address)
            XCTAssertNotNil(HubConnectionStore.canonicalURL(address), address)
        }
        for address in ["http://desk.tail123.ts.net/", "http://100.64.0.1/", "http://desk/"] {
            XCTAssertNil(ServerAddress.parse(address), address)
        }
    }

    @MainActor
    func testMacChatUsesResponsiveContentAndIsolatedTextScaleWithoutChangingMobile() {
        let macConfiguration = WKWebViewConfiguration()
        BrowserView.configureMacBrowsing(macConfiguration, isMac: true)
        XCTAssertEqual(macConfiguration.defaultWebpagePreferences.preferredContentMode, .mobile)
        let mobileConfiguration = WKWebViewConfiguration()
        let originalMode = mobileConfiguration.defaultWebpagePreferences.preferredContentMode
        BrowserView.configureMacBrowsing(mobileConfiguration, isMac: false)
        XCTAssertEqual(mobileConfiguration.defaultWebpagePreferences.preferredContentMode, originalMode)

        let authentication = WKUserScript(source: "window.fixtureAuthentication = 'local dummy';",
                                          injectionTime: .atDocumentStart, forMainFrameOnly: true)
        macConfiguration.userContentController.addUserScript(authentication)
        let view = WKWebView(frame: .zero, configuration: macConfiguration)
        view.pageZoom = 1.75 // Recover a retained view previously using geometric zoom.
        BrowserView.applyMacTextScale(1.25, to: view, isMac: true)
        XCTAssertEqual(view.pageZoom, 1, accuracy: 0.001)
        var scripts = view.configuration.userContentController.userScripts
        XCTAssertEqual(scripts.count, 2)
        XCTAssertTrue(scripts.contains { $0 === authentication }, "Keep unrelated authentication scripts")
        let presentation = scripts.filter { $0 !== authentication }
        XCTAssertEqual(presentation.count, 1)
        XCTAssertEqual(presentation.first?.injectionTime, .atDocumentEnd)
        XCTAssertEqual(presentation.first?.isForMainFrameOnly, true)
        // WKUserScript does not expose contentWorld in this SDK. The real
        // fixture below verifies isolation with a page-world style API trap.
        BrowserView.applyMacTextScale(1.5, to: view, isMac: true)
        scripts = view.configuration.userContentController.userScripts
        XCTAssertEqual(scripts.count, 2, "Replace only the sizing script instead of accumulating injections")
        XCTAssertTrue(scripts.contains { $0 === authentication })
        BrowserView.applyMacTextScale(1.75, to: view, isMac: false)
        let unchanged = view.configuration.userContentController.userScripts
        XCTAssertEqual(unchanged.count, scripts.count)
        XCTAssertTrue(zip(unchanged, scripts).allSatisfy { $0.0 === $0.1 })
        XCTAssertEqual(view.pageZoom, 1, accuracy: 0.001)
        XCTAssertNil(view.url, "Changing text scale must not navigate")
        XCTAssertEqual(BrowserView.normalizedMacTextScale(.nan), 1.25)
        XCTAssertEqual(BrowserView.normalizedMacTextScale(.infinity), 1.25)
        XCTAssertEqual(BrowserView.normalizedMacTextScale(0), 0.75)
        XCTAssertEqual(BrowserView.normalizedMacTextScale(10), 2)
    }

    @MainActor
    func testMacChatResponsiveViewportFitsAcrossTextScaleAndResizeWithoutReload() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        BrowserView.configureMacBrowsing(configuration, isMac: true)
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 420, height: 700), configuration: configuration)
        view.scrollView.contentInsetAdjustmentBehavior = .never
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        window.frame = view.frame
        window.makeKeyAndVisible()
        host.view.addSubview(view)
        defer {
            view.stopLoading()
            view.removeFromSuperview()
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        BrowserView.applyMacTextScale(1.25, to: view, isMac: true)
        view.loadHTMLString(Self.responsiveChatHTML, baseURL: nil)
        let initial = try await settledChatMetrics(view)
        XCTAssertEqual((initial["fontSize"] as? NSNumber)?.doubleValue ?? 0, 20, accuracy: 0.1,
                       "Document-end script must size newly loaded documents before any dynamic update")
        // Neither the edited value nor this per-load random marker can survive a reload.
        let markerValue = try await view.evaluateJavaScript("window.documentMarker")
        let marker = try XCTUnwrap(markerValue as? String)
        _ = try await view.evaluateJavaScript("document.getElementById('draft').value = 'Edited draft stays here'")

        for width in [420.0, 756.0, 1100.0] {
            window.frame.size.width = width
            host.view.layoutIfNeeded()
            view.frame = CGRect(x: 0, y: 0, width: width, height: 700)
            view.layoutIfNeeded()
            var baseGlyphWidth = 0.0
            var baseGlyphHeight = 0.0
            for scale in [1.0, 1.25, 1.75] {
                BrowserView.applyMacTextScale(scale, to: view, isMac: true)
                let metrics = try await settledChatMetrics(view)
                let context = "native width=\(width), textScale=\(scale), metrics=\(metrics)"
                func number(_ key: String) throws -> Double {
                    try XCTUnwrap(metrics[key] as? NSNumber, "Missing \(key): \(context)").doubleValue
                }
                XCTAssertNotNil(view.window, context)
                XCTAssertEqual(view.bounds.width, width, accuracy: 0.5, context)
                XCTAssertEqual(view.scrollView.bounds.width, width, accuracy: 0.5, context)
                XCTAssertEqual(view.pageZoom, 1, accuracy: 0.001, context)
                let visualWidth = try number("visualWidth")
                let visualLeft = try number("visualLeft")
                let documentWidth = try number("documentWidth")
                // Compare CSS geometry in one coordinate system, then map the visible
                // viewport to native points using WebKit's reported visual scale.
                XCTAssertEqual(visualWidth * (try number("visualScale")), width, accuracy: 2, context)
                XCTAssertEqual(documentWidth, visualWidth, accuracy: 2, context)
                XCTAssertLessThanOrEqual(try number("scrollWidth"), documentWidth + 1, context)
                XCTAssertEqual(try number("scrollX"), 0, accuracy: 1, context)
                for element in ["app", "header", "composer"] {
                    XCTAssertGreaterThanOrEqual(try number(element + "Left"), visualLeft - 1, context)
                    XCTAssertLessThanOrEqual(try number(element + "Right"), visualLeft + visualWidth + 1, context)
                }
                XCTAssertEqual(try number("fontSize"), 16 * scale, accuracy: 0.1, context)
                XCTAssertEqual(try number("pageStyleCalls"), 0, context)
                let glyphWidth = try number("glyphWidth")
                let glyphHeight = try number("glyphHeight")
                if scale == 1 {
                    baseGlyphWidth = glyphWidth
                    baseGlyphHeight = glyphHeight
                    XCTAssertGreaterThan(glyphWidth, 0, context)
                    XCTAssertGreaterThan(glyphHeight, 0, context)
                } else {
                    // Real glyph/line boxes must grow, not only a CSS preference.
                    // System font optical sizing/kerning is not a geometric
                    // transform: require substantial growth, not linear width.
                    XCTAssertGreaterThan(glyphWidth, baseGlyphWidth * (1 + (scale - 1) * 0.8), context)
                    XCTAssertGreaterThan(glyphHeight, baseGlyphHeight, context)
                }
                XCTAssertEqual(metrics["sidebarVisible"] as? Bool, documentWidth >= 800, context)
                XCTAssertEqual(metrics["marker"] as? String, marker, context)
                XCTAssertEqual(metrics["draft"] as? String, "Edited draft stays here", context)
                XCTAssertLessThanOrEqual(view.scrollView.contentSize.width,
                                         view.scrollView.bounds.width + 2, context)
                XCTAssertEqual(view.scrollView.contentOffset.x, 0, accuracy: 1, context)
            }
        }
    }

    @MainActor
    func testPhoneBrowsingLeavesExplicitContentModesZoomAndScriptsUnchanged() {
        // Check all initial modes, not just .recommended, so a mobile override
        // accidentally applied outside the Mac path cannot pass unnoticed.
        for mode in [WKWebpagePreferences.ContentMode.recommended, .mobile, .desktop] {
            let configuration = WKWebViewConfiguration()
            configuration.defaultWebpagePreferences.preferredContentMode = mode
            BrowserView.configureMacBrowsing(configuration, isMac: false)
            XCTAssertEqual(configuration.defaultWebpagePreferences.preferredContentMode, mode)
            let authentication = WKUserScript(source: "window.phoneFixture = true;",
                                              injectionTime: .atDocumentStart, forMainFrameOnly: true)
            configuration.userContentController.addUserScript(authentication)
            let view = WKWebView(frame: .zero, configuration: configuration)
            view.pageZoom = 1.1
            BrowserView.applyMacTextScale(1.75, to: view, isMac: false)
            XCTAssertEqual(view.pageZoom, 1.1, accuracy: 0.001)
            let scripts = view.configuration.userContentController.userScripts
            XCTAssertEqual(scripts.count, 1)
            XCTAssertTrue(scripts.first === authentication)
            XCTAssertNil(view.url)
        }
    }

    @MainActor
    private func settledChatMetrics(_ view: WKWebView) async throws -> [String: Any] {
        let deadline = ContinuousClock.now + .seconds(2)
        let token = UUID().uuidString
        var armed = false
        var previous: NSDictionary?
        var stableReads = 0
        var latest: [String: Any] = [:]
        while ContinuousClock.now < deadline {
            if !armed, (try? await view.evaluateJavaScript("typeof window.chatMetrics === 'function'")) as? Bool == true {
                // Two actual WebKit animation frames, followed by stable geometry
                // reads, allow resize/text layout and native scroll commits to settle.
                _ = try await view.evaluateJavaScript("""
                    window.committedLayout = null;
                    requestAnimationFrame(() => requestAnimationFrame(() => window.committedLayout = '\(token)'));
                    """)
                armed = true
            }
            if armed, var metrics = try await view.evaluateJavaScript("window.chatMetrics()") as? [String: Any] {
                metrics["nativeContentWidth"] = view.scrollView.contentSize.width
                metrics["nativeOffsetX"] = view.scrollView.contentOffset.x
                latest = metrics
                let current = metrics as NSDictionary
                if metrics["committed"] as? String == token, previous?.isEqual(current) == true {
                    stableReads += 1
                    if stableReads >= 2 { return metrics }
                } else {
                    stableReads = 0
                }
                previous = current
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Local WebKit fixture did not commit stable layout within two seconds: \(latest)")
        throw NSError(domain: "ServerAddressTests.ResponsiveChat", code: 1)
    }

    private static let responsiveChatHTML = """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        * { box-sizing: border-box; }
        html, body { margin: 0; width: 100%; font: 16px -apple-system; -webkit-text-size-adjust: 100%; }
        #app { position: fixed; inset: 0; width: 100%; display: grid; grid-template-columns: minmax(0, 1fr); }
        aside { display: none; }
        main { min-width: 0; display: grid; grid-template-rows: auto minmax(0, 1fr) auto; }
        header, #composer { min-width: 0; width: 100%; padding: 12px; }
        article { min-width: 0; overflow-y: auto; padding: 12px; }
        textarea { display: block; width: 100%; min-width: 0; font: inherit; }
        pre, .table-scroll { max-width: 100%; overflow-x: auto; }
        #glyph { white-space: nowrap; }
        @media (min-width: 800px) { #app { grid-template-columns: 180px minmax(0, 1fr); } aside { display: block; } }
        </style></head><body>
        <div id="app"><aside>Conversations</aside><main>
        <header id="header">Conversation header</header>
        <article><p id="message"><span id="glyph">Readable</span> conversation text wraps naturally inside the available space.</p>
        <pre>short code sample</pre><div class="table-scroll"><table><tr><td>Short</td><td>table</td></tr></table></div></article>
        <form id="composer"><textarea id="draft">An unsent draft</textarea><button type="button">Send</button></form>
        </main></div>
        <script>
        window.documentMarker = Math.random().toString(36);
        // An injected .page-world sizing script would hit this trap and fail
        // to resize text; isolated-world DOM presentation updates must not.
        window.pageStyleCalls = 0;
        CSSStyleDeclaration.prototype.setProperty = function() { window.pageStyleCalls++; };
        window.chatMetrics = () => {
            const root = document.documentElement, viewport = window.visualViewport;
            const glyph = document.getElementById('glyph').getBoundingClientRect();
            const result = {
                committed: window.committedLayout, marker: window.documentMarker,
                pageStyleCalls: window.pageStyleCalls,
                draft: document.getElementById('draft').value,
                documentWidth: root.clientWidth, scrollWidth: root.scrollWidth, scrollX,
                visualWidth: viewport.width, visualLeft: viewport.offsetLeft, visualScale: viewport.scale,
                fontSize: parseFloat(getComputedStyle(document.getElementById('message')).fontSize),
                glyphWidth: glyph.width, glyphHeight: glyph.height,
                sidebarVisible: getComputedStyle(document.querySelector('aside')).display !== 'none'
            };
            for (const id of ['app', 'header', 'composer']) {
                const rect = document.getElementById(id).getBoundingClientRect();
                result[id + 'Left'] = rect.left; result[id + 'Right'] = rect.right;
            }
            return result;
        };
        </script></body></html>
        """

    func testInvalidAddresses() {
        for value in ["", "file:///tmp/test", "http://example.com", "http://localhost.evil.com/ui/", "http://127.0.0.1:8080/ui/", "https://", "https://user:pass@example.com", "https://example.com/?token=secret"] {
            XCTAssertNil(ServerAddress.parse(value), value)
        }
    }
}
