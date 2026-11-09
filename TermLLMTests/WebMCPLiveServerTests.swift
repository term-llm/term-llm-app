import SwiftUI
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

    /// Serve the sibling repo's built demo locally and set
    /// TEST_RUNNER_TERMLLM_DEMO_E2E_URL=http://localhost:PORT/.
    /// Exercises the stock frontend's real per-conversation MCP switch, bridge,
    /// and persistent playlist store without Apple Music authorization.
    #if os(iOS)
    func testDemoCreatesNativeSamplePlaylistOnlyAfterMCPOptIn() async throws {
        guard let raw = ProcessInfo.processInfo.environment["TERMLLM_DEMO_E2E_URL"],
              let server = URL(string: raw) else {
            throw XCTSkip("Set TERMLLM_DEMO_E2E_URL to the built static demo to run")
        }
        let file = temporaryPlaylistFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let catalog = FakeCatalog(access: .denied)
        let engine = FakeEngine()
        let library = MusicLibrary(catalog: catalog, engine: engine,
                                   store: PlaylistStore(fileURL: file), defaults: isolatedDefaults())
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let bridge = WebMCPBridge(serverURL: server,
                                  registry: DeviceToolRegistry(tools: BuiltInDeviceTools.standard + library.tools),
                                  device: "iPhone")
        bridge.install(into: configuration.userContentController)
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        let controller = UIViewController()
        controller.view = webView
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; bridge.uninstall() }
        webView.load(URLRequest(url: server))

        func script(_ code: String) async throws -> Any? {
            try await webView.callAsyncJavaScript(code, contentWorld: .page)
        }
        func send(_ text: String) async throws {
            _ = try await webView.callAsyncJavaScript("""
                const input = document.querySelector('#promptInput');
                input.value = text;
                input.dispatchEvent(new Event('input', { bubbles: true }));
                await new Promise(resolve => setTimeout(resolve, 100));
                const button = document.querySelector('button[aria-label="Send message"]');
                if (!button || button.disabled) throw new Error('Send unavailable');
                button.click();
                """, arguments: ["text": text], contentWorld: .page)
        }
        func waitForReply() async throws {
            try await eventually("the scripted reply to finish", timeout: 20) {
                try await script("return !!document.querySelector('button[aria-label=\"Send message\"]') && !document.querySelector('#stopBtn')") as? Bool == true
            }
        }
        try await eventually("demo composer and welcome") {
            try await script("return !!document.querySelector('#promptInput') && document.body.innerText.includes('scripted')") as? Bool == true
        }
        XCTAssertTrue(library.store.playlists.isEmpty, "Merely opening the demo must not call a native tool")
        try await send("create playlist")
        try await waitForReply()
        XCTAssertTrue(library.store.playlists.isEmpty, "Native sharing alone must not enable conversation tools")
        let guide = try await script("return document.body.innerText") as? String
        XCTAssertTrue(guide?.contains("Share device tools") == true)

        _ = try await script("document.querySelector('#attachBtn').click()")
        try await eventually("the MCP menu item") {
            try await script("return [...document.querySelectorAll('[role=menuitem]')].some(b => b.textContent.trim() === 'MCP servers')") as? Bool == true
        }
        _ = try await script("[...document.querySelectorAll('[role=menuitem]')].find(b => b.textContent.trim() === 'MCP servers').click()")
        try await eventually("the disabled iPhone MCP switch") {
            try await script("return !!document.querySelector('input[aria-label=\"Enable iPhone\"]')") as? Bool == true
        }
        _ = try await script("document.querySelector('input[aria-label=\"Enable iPhone\"]').click()")
        _ = try await script("document.querySelector('.mcp-modal [data-overlay-close]').click()")
        try await send("create playlist")
        try await eventually("a real five-song native playlist", timeout: 20) {
            library.store.playlists.first?.entries.count == 5
        }
        try await waitForReply()
        let playlist = try XCTUnwrap(library.store.playlists.first)
        let reply = try await script("return document.body.innerText") as? String
        XCTAssertTrue(reply?.contains(playlist.name) == true)
        XCTAssertEqual(PlaylistStore(fileURL: file).playlists.first?.id, playlist.id, "Native playlist survives reload/relaunch")
        XCTAssertEqual(catalog.access(), .denied)
        XCTAssertTrue(engine.loads.isEmpty)
        try await send("create playlist")
        try await waitForReply()
        XCTAssertEqual(library.store.playlists.count, 1)
        XCTAssertEqual(library.store.playlists.first?.id, playlist.id)

        try await send("list playlists")
        try await waitForReply()
        let listing = try await script("return document.body.innerText") as? String
        XCTAssertTrue(listing?.contains("Playlists saved in term-llm on this device") == true)
        try await send("ping")
        try await waitForReply()
        let ping = try await script("return document.body.innerText") as? String
        XCTAssertTrue(ping?.contains("pong from term-llm iPhone app") == true)
        try await send("device info")
        try await waitForReply()
        let info = try await script("return document.body.innerText") as? String
        XCTAssertTrue(info?.contains("Read-only device tool information") == true)
        XCTAssertTrue(engine.loads.isEmpty)

        let nativeWindow = UIWindow(windowScene: scene)
        nativeWindow.frame = scene.screen.bounds
        nativeWindow.rootViewController = UIHostingController(rootView:
            NavigationStack { PlaylistDetailView(library: library, playlistID: playlist.id) })
        nativeWindow.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(500))
        let image = UIGraphicsImageRenderer(bounds: nativeWindow.bounds).image { _ in
            nativeWindow.drawHierarchy(in: nativeWindow.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "demo-real-native-five-song-playlist"
        attachment.lifetime = .keepAlways
        add(attachment)
        nativeWindow.isHidden = true
    }

    #endif

    private func eventually(_ what: String, timeout: TimeInterval = 10,
                            _ condition: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? await condition()) == true { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTFail("Timed out waiting for \(what)")
        throw NSError(domain: "WebMCPLiveServerTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for \(what)"])
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    func record(_ value: String) { lock.withLock { recorded.append(value) } }
    var values: [String] { lock.withLock { recorded } }
}
