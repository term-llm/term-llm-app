import WebKit
import XCTest
@testable import TermLLM

/// Opt-in end-to-end check: the real injected WebMCP script, inside WebKit,
/// driving a live term-llm web UI whose debug model calls the device tool.
///
/// Start `term-llm serve web --no-auth` with `default_provider: debug`, then:
/// `TEST_RUNNER_TERMLLM_E2E_URL=http://127.0.0.1:PORT/ui/ xcodebuild test …`
@MainActor
final class WebMCPLiveServerTests: XCTestCase {
    func testDebugModelCallsDeviceToolThroughRealWebUI() async throws {
        guard let raw = ProcessInfo.processInfo.environment["TERMLLM_E2E_URL"], let server = URL(string: raw) else {
            throw XCTSkip("Set TERMLLM_E2E_URL to a debug-provider term-llm server to run")
        }
        let calls = CallCounter()
        let registry = DeviceToolRegistry(tools: [
            DeviceTool(name: "ping", description: "Check that the phone is reachable.") { arguments in
                calls.record(arguments["message"]?.stringValue ?? "")
                return DeviceToolResult(text: "pong from the iPhone")
            },
        ])
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        WebMCPBridge(serverURL: server, registry: registry, device: "iPhone")
            .install(into: configuration.userContentController)
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        webView.load(URLRequest(url: URL(string: "?new=1", relativeTo: server)!))

        try await eventually("the composer to load") {
            try await webView.callAsyncJavaScript("return !!document.querySelector('#promptInput')",
                                                  contentWorld: .page) as? Bool == true
        }
        let offered = try await webView.callAsyncJavaScript(
            "return (await document.modelContext.getTools()).map(t => t.name).join(',')", contentWorld: .page) as? String
        XCTAssertEqual(offered, "ping")

        _ = try await webView.callAsyncJavaScript("""
            const input = document.querySelector('#promptInput');
            Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value').set.call(input, 'call webmcp__ping message=hi');
            input.dispatchEvent(new Event('input', { bubbles: true }));
            await new Promise((resolve) => setTimeout(resolve, 100));
            document.querySelector('button[aria-label="Send message"]').click();
            """, contentWorld: .page)

        try await eventually("the continued response", timeout: 20) {
            let text = try await webView.callAsyncJavaScript("return document.body.innerText", contentWorld: .page) as? String
            return text?.contains("Debug: Tool execution completed successfully.") == true
        }
        XCTAssertEqual(calls.values, ["hi"])
    }

    private func eventually(_ what: String, timeout: TimeInterval = 10,
                            _ condition: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? await condition()) == true { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTFail("Timed out waiting for \(what)")
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    func record(_ value: String) { lock.withLock { recorded.append(value) } }
    var values: [String] { lock.withLock { recorded } }
}
