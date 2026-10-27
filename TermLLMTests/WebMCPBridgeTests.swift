import WebKit
import XCTest
@testable import TermLLM

@MainActor
final class WebMCPBridgeTests: XCTestCase {
    private let server = URL(string: "https://jarvis.example/ui/")!

    private func registry() -> DeviceToolRegistry {
        DeviceToolRegistry(tools: [
            BuiltInDeviceTools.ping(now: { Date(timeIntervalSince1970: 0) }),
            DeviceTool(name: "boom", description: "Always fails \"loudly\" `here` </script>") { _ in
                throw DeviceToolError(message: "kaboom")
            },
            DeviceTool(name: "soft_fail", description: "Returns an error result") { _ in .error("nope") },
        ])
    }

    private func bridge(_ server: URL? = nil) -> WebMCPBridge {
        WebMCPBridge(serverURL: server ?? self.server, registry: registry(), device: "iPhone")
    }

    // MARK: Native side

    func testOriginSerializationMatchesLocationOrigin() {
        XCTAssertEqual(WebMCPBridge.originString(scheme: "https", host: "Jarvis.Example", port: 443), "https://jarvis.example")
        XCTAssertEqual(WebMCPBridge.originString(scheme: "https", host: "jarvis.example", port: 0), "https://jarvis.example")
        XCTAssertEqual(WebMCPBridge.originString(scheme: "http", host: "localhost", port: 8080), "http://localhost:8080")
        XCTAssertEqual(bridge().expectedOrigin, "https://jarvis.example")
    }

    func testHandlerRejectsOtherOriginsAndSubframes() async {
        let origin = "https://jarvis.example"
        let body: [String: Any] = ["name": "ping", "arguments": "{}"]
        let wrongOrigin = await WebMCPBridge.handle(body: body, frameOrigin: "https://evil.example", isMainFrame: true,
                                                    expectedOrigin: origin, registry: registry())
        XCTAssertEqual(wrongOrigin, .failure(.init(message: "Device tools are not available to this page")))
        let subframe = await WebMCPBridge.handle(body: body, frameOrigin: origin, isMainFrame: false,
                                                 expectedOrigin: origin, registry: registry())
        XCTAssertEqual(subframe, .failure(.init(message: "Device tools are not available to this page")))
    }

    func testHandlerRunsToolsAndMapsErrors() async {
        let origin = "https://jarvis.example"
        func call(_ body: Any) async -> Result<String, WebMCPBridge.BridgeError> {
            await WebMCPBridge.handle(body: body, frameOrigin: origin, isMainFrame: true, expectedOrigin: origin, registry: registry())
        }
        let ok = await call(["name": "ping", "arguments": #"{"message":"hi"}"#])
        XCTAssertEqual(ok, .success("pong from term-llm iPhone app at 1970-01-01T00:00:00Z\necho: hi"))
        let noArguments = await call(["name": "ping"])
        XCTAssertEqual(noArguments, .success("pong from term-llm iPhone app at 1970-01-01T00:00:00Z"))
        let thrown = await call(["name": "boom", "arguments": "{}"])
        XCTAssertEqual(thrown, .failure(.init(message: "kaboom")))
        let soft = await call(["name": "soft_fail", "arguments": "{}"])
        XCTAssertEqual(soft, .failure(.init(message: "nope")))
        let unknown = await call(["name": "nope"])
        XCTAssertEqual(unknown, .failure(.init(message: "Unknown device tool: nope")))
        let badArguments = await call(["name": "ping", "arguments": "[1]"])
        XCTAssertEqual(badArguments, .failure(.init(message: "Tool arguments must be an object")))
        let malformed = await call("ping")
        XCTAssertEqual(malformed, .failure(.init(message: "Malformed device tool call")))
    }

    func testToolSpecsCarryWebMCPAnnotations() {
        guard case .array(let specs) = WebMCPBridge.toolSpecs(registry().tools) else { return XCTFail() }
        XCTAssertEqual(specs.first?["name"], "ping")
        XCTAssertEqual(specs.first?["annotations"]?["readOnlyHint"], true)
        XCTAssertEqual(specs.first?["inputSchema"]?["type"], "object")
        XCTAssertEqual(specs[1]["annotations"]?["readOnlyHint"], false)
    }

    // MARK: Injected script in a real WKWebView

    private func makeWebView(bridge: WebMCPBridge?) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        bridge?.install(into: configuration.userContentController)
        return WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: configuration)
    }

    private func load(_ webView: WKWebView, baseURL: URL) async throws {
        let waiter = NavigationWaiter()
        webView.navigationDelegate = waiter
        webView.loadHTMLString("<!doctype html><html><body>term-llm</body></html>", baseURL: baseURL)
        try await waiter.wait()
    }

    private func js(_ webView: WKWebView, _ body: String) async throws -> Any? {
        try await webView.callAsyncJavaScript(body, contentWorld: .page)
    }

    func testInjectedToolsAreDiscoverableAndExecutable() async throws {
        let webView = makeWebView(bridge: bridge())
        try await load(webView, baseURL: server)

        let names = try await js(webView, "return (await document.modelContext.getTools()).map(t => t.name)") as? [String]
        XCTAssertEqual(names, ["boom", "ping", "soft_fail"])

        let tools = try await js(webView, "return JSON.stringify(await document.modelContext.getTools())") as? String
        let parsed = try JSONValue.decode(Data((tools ?? "").utf8))
        guard case .array(let list) = parsed, let ping = list.first(where: { $0["name"] == "ping" }) else { return XCTFail() }
        XCTAssertEqual(ping["annotations"]?["readOnlyHint"], true)
        XCTAssertEqual(ping["origin"], "https://jarvis.example")
        XCTAssertEqual(list.first(where: { $0["name"] == "boom" })?["description"], "Always fails \"loudly\" `here` </script>")

        let marker = try await js(webView, "return window.__termLLMDeviceTools.tools.length") as? Int
        XCTAssertEqual(marker, 3)
        let device = try await js(webView, "return window.__termLLMDeviceTools.device") as? String
        XCTAssertEqual(device, "iPhone", "the web UI labels page tools with this")

        let result = try await js(webView, """
            const [tool] = (await document.modelContext.getTools()).filter(t => t.name === 'ping');
            return await document.modelContext.executeTool(tool, { message: 'from the page' });
            """) as? String
        XCTAssertEqual(result, "pong from term-llm iPhone app at 1970-01-01T00:00:00Z\necho: from the page")

        let byName = try await js(webView, "return await document.modelContext.executeTool('ping', {})") as? String
        XCTAssertEqual(byName, "pong from term-llm iPhone app at 1970-01-01T00:00:00Z")
    }

    func testTracksRunningCallsAndReportsWhenTheyHaveReplied() async throws {
        let bridge = WebMCPBridge(serverURL: server, registry: DeviceToolRegistry(tools: [
            DeviceTool(name: "slow", description: "Takes a moment") { _ in
                try await Task.sleep(for: .milliseconds(300))
                return DeviceToolResult(text: "done")
            },
        ]), device: "iPhone")
        var settled = 0
        bridge.onCallsSettled = { settled += 1 }
        let webView = makeWebView(bridge: bridge)
        try await load(webView, baseURL: server)
        webView.evaluateJavaScript("document.modelContext.executeTool('slow', {}).then(r => window.slow = r); void 0;", completionHandler: nil)
        for _ in 0..<50 where bridge.activeCalls == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(bridge.activeCalls, 1)
        XCTAssertEqual(settled, 0)
        for _ in 0..<100 where settled == 0 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(settled, 1)
        XCTAssertEqual(bridge.activeCalls, 0)
        let reply = try await js(webView, "return window.slow") as? String
        XCTAssertEqual(reply, "done")
    }

    func testToolFailuresRejectInThePage() async throws {
        let webView = makeWebView(bridge: bridge())
        try await load(webView, baseURL: server)
        let message = try await js(webView, """
            try { await document.modelContext.executeTool('boom', {}); return 'resolved'; }
            catch (error) { return String(error && error.message || error); }
            """) as? String
        XCTAssertEqual(message, "kaboom")
        let soft = try await js(webView, """
            try { await document.modelContext.executeTool('soft_fail', {}); return 'resolved'; }
            catch (error) { return String(error && error.message || error); }
            """) as? String
        XCTAssertEqual(soft, "nope")
    }

    func testNotInjectedIntoOtherOrigins() async throws {
        let webView = makeWebView(bridge: bridge())
        try await load(webView, baseURL: URL(string: "https://devbox.example/")!)
        let present = try await js(webView, "return typeof document.modelContext") as? String
        XCTAssertEqual(present, "undefined")
    }

    func testNothingInjectedWhenDisabled() async throws {
        let webView = makeWebView(bridge: nil)
        try await load(webView, baseURL: server)
        let present = try await js(webView, "return typeof document.modelContext") as? String
        XCTAssertEqual(present, "undefined")
    }

    func testUninstallRemovesInjectionOnReload() async throws {
        let installed = bridge()
        let webView = makeWebView(bridge: installed)
        try await load(webView, baseURL: server)
        let before = try await js(webView, "return typeof document.modelContext") as? String
        XCTAssertEqual(before, "object")
        installed.uninstall()
        try await load(webView, baseURL: server)
        let after = try await js(webView, "return typeof document.modelContext") as? String
        XCTAssertEqual(after, "undefined")
    }

    func testShimSupportsPageToolsUnregistrationAndToolChange() async throws {
        let webView = makeWebView(bridge: bridge())
        try await load(webView, baseURL: server)
        let result = try await js(webView, """
            let changes = 0;
            document.modelContext.addEventListener('toolchange', () => changes++);
            const controller = new AbortController();
            await document.modelContext.registerTool({
              name: 'page_tool', description: 'from the page', inputSchema: { type: 'object', properties: {} },
              execute: async () => 'page result',
            }, { signal: controller.signal });
            let duplicate = 'none';
            try {
              await document.modelContext.registerTool({ name: 'page_tool', description: '', execute: async () => '' });
            } catch (error) { duplicate = error.name; }
            const ran = await document.modelContext.executeTool('page_tool', {});
            controller.abort();
            const names = (await document.modelContext.getTools()).map(t => t.name);
            return JSON.stringify({ changes, duplicate, ran, names });
            """) as? String
        let json = try JSONValue.decode(Data((result ?? "").utf8))
        XCTAssertEqual(json["changes"], 2, "register + unregister")
        XCTAssertEqual(json["duplicate"], "InvalidStateError")
        XCTAssertEqual(json["ran"], "page result")
        XCTAssertEqual(json["names"], ["boom", "ping", "soft_fail"])
    }

    func testPageCannotBypassShimFromWrongOrigin() async throws {
        // Even if a foreign page reached the handler, native rejects it.
        let foreign = bridge(URL(string: "https://other.example/")!)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // Register the handler without the origin-gated script.
        configuration.userContentController.addScriptMessageHandler(foreign, contentWorld: .page, name: WebMCPBridge.handlerName)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        try await load(webView, baseURL: server)
        let message = try await js(webView, """
            try { await window.webkit.messageHandlers.termllmDeviceTools.postMessage({ name: 'ping', arguments: '{}' }); return 'resolved'; }
            catch (error) { return String(error && error.message || error); }
            """) as? String
        XCTAssertEqual(message, "Device tools are not available to this page")
    }
}

private final class NavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    func wait() async throws {
        if let result { return try result.get() }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        if let continuation {
            self.continuation = nil
            continuation.resume(with: result)
        } else {
            self.result = result
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(.success(())) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }
}
