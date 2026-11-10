import AppKit
import Network
import SwiftUI
import WebKit
import XCTest
@testable import TermLLM

/// A tiny loopback HTTP/1.1 server: one response per connection, no TLS.
/// `localhost` pages are secure contexts, like the managed local service.
final class LoopbackHTTPServer: @unchecked Sendable {
    struct Response: Sendable {
        var status = 200
        var contentType = "text/html; charset=utf-8"
        var body = Data()
    }
    typealias Handler = @Sendable (_ method: String, _ path: String, _ headers: [String: String]) -> Response

    private let listener: NWListener
    private let queue = DispatchQueue(label: "TermLLMMacTests.LoopbackHTTPServer")
    private let handler: Handler

    init(handler: @escaping Handler) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        self.handler = handler
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [handler, queue] connection in
            connection.start(queue: queue)
            Self.receive(connection, buffer: Data(), handler: handler)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let resumed = LockedFlag()
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    if resumed.set() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if resumed.set() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    private static func receive(_ connection: NWConnection, buffer: Data, handler: @escaping Handler) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if complete || error != nil { connection.cancel() } else { receive(connection, buffer: buffer, handler: handler) }
                return
            }
            let lines = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let request = lines.first?.split(separator: " ").map(String.init) ?? []
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let response = handler(request.first ?? "", request.count > 1 ? request[1] : "", headers)
            let head = "HTTP/1.1 \(response.status) \(response.status == 200 ? "OK" : "Unauthorized")\r\n"
                + "Content-Type: \(response.contentType)\r\nContent-Length: \(response.body.count)\r\n"
                + "Connection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    /// True only for the first caller.
    func set() -> Bool { lock.withLock { defer { value = true }; return !value } }
}

@MainActor
func waitUntil(_ description: @autoclosure () -> String = "condition", timeout: TimeInterval = 10,
               _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else {
            throw NSError(domain: "TermLLMMacTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for \(description())"])
        }
        try await Task.sleep(for: .milliseconds(50))
    }
}

/// The native Mac client's platform behavior. Mac Catalyst's WebKit has no
/// media capture at all; this target exists so Chat can use the microphone.
@MainActor
final class MacClientTests: XCTestCase {
    func testChatWebViewExposesMicrophoneCaptureAPIs() async throws {
        let server = try LoopbackHTTPServer { _, _, _ in
            .init(body: Data("<!doctype html><title>Chat</title><p>ready</p>".utf8))
        }
        let port = try await server.start()
        defer { server.stop() }
        let url = try XCTUnwrap(URL(string: "http://localhost:\(port)/ui/"))
        let browser = BrowserView(url: url, loading: .constant(false), canGoBack: .constant(false),
                                  loadError: .constant(nil), loginRequired: .constant(false),
                                  reloadCount: 0, backCount: 0, authenticatedCount: 0,
                                  onLoginRequired: {}, onRevealControls: {},
                                  websiteDataStore: .nonPersistent(), connectionMount: url)
        let coordinator = browser.makeCoordinator()
        let webView = browser.makeWebView(coordinator: coordinator)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        defer {
            BrowserView.dismantleWebView(webView, coordinator: coordinator)
            window.contentView = nil
        }
        try await waitUntil { webView.url != nil && !webView.isLoading }
        // Capability checks only: nothing here asks for microphone access.
        let probe = try await webView.evaluateJavaScript("""
            JSON.stringify({
              secure: window.isSecureContext === true,
              getUserMedia: typeof navigator.mediaDevices?.getUserMedia,
              mediaRecorder: typeof window.MediaRecorder,
              peerConnection: typeof window.RTCPeerConnection,
              audioWorklet: typeof window.AudioWorkletNode
            })
            """) as? String
        let result = try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(probe).utf8)) as? [String: Any]
        XCTAssertEqual(result?["secure"] as? Bool, true)
        XCTAssertEqual(result?["getUserMedia"] as? String, "function",
                       "AppKit WebKit must expose getUserMedia (Mac Catalyst's does not)")
        XCTAssertEqual(result?["mediaRecorder"] as? String, "function")
        XCTAssertEqual(result?["peerConnection"] as? String, "function")
        XCTAssertEqual(result?["audioWorklet"] as? String, "function")
        // The configured server's own microphone requests keep their grant.
        XCTAssertEqual(browser.mediaCaptureDecision(originScheme: "http", originHost: "localhost", originPort: Int(port),
                                                    frameURL: url, isMainFrame: true, type: .microphone), .grant)
    }

    /// macOS 27 floats "Write with Siri" beside a focused text area whenever the
    /// web view allows it. A plain web view proves the page reaches that state.
    func testChatDeclinesTheWriteWithSiriButtonForItsComposer() async throws {
        let server = try LoopbackHTTPServer { _, _, _ in
            .init(body: Data("<!doctype html><title>Chat</title><textarea placeholder=\"Steer conversation...\"></textarea>".utf8))
        }
        let port = try await server.start()
        defer { server.stop() }
        let url = try XCTUnwrap(URL(string: "http://localhost:\(port)/ui/"))
        let browser = BrowserView(url: url, loading: .constant(false), canGoBack: .constant(false),
                                  loadError: .constant(nil), loginRequired: .constant(false),
                                  reloadCount: 0, backCount: 0, authenticatedCount: 0,
                                  onLoginRequired: {}, onRevealControls: {},
                                  websiteDataStore: .nonPersistent(), connectionMount: url)
        let coordinator = browser.makeCoordinator()
        let chat = browser.makeWebView(coordinator: coordinator)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let plain = WKWebView(frame: .zero, configuration: configuration)
        plain.load(URLRequest(url: url))
        var windows: [NSWindow] = []
        defer {
            BrowserView.dismantleWebView(chat, coordinator: coordinator)
            windows.forEach { $0.contentView = nil; $0.orderOut(nil) }
        }
        for view in [chat, plain] {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
            windows.append(window)
            try await waitUntil { view.url != nil && !view.isLoading }
            let focused = try await view.evaluateJavaScript(
                "document.querySelector('textarea').focus(); document.activeElement.tagName") as? String
            XCTAssertEqual(focused, "TEXTAREA")
        }

        let key = "allowsWritingToolsAffordance"
        if plain.responds(to: NSSelectorFromString(key)) {
            try await waitUntil("WebKit to allow the button for a focused text area") {
                plain.value(forKey: key) as? Bool == true
            }
        }
        XCTAssertTrue(chat is ChatWebView)
        XCTAssertEqual(chat.value(forKey: key) as? Bool, false)
    }

    func testChatZoomIsWholePageZoomWithinItsRange() {
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        BrowserView.applyChatZoom(1.5, to: view)
        XCTAssertEqual(view.pageZoom, 1.5, accuracy: 0.001)
        BrowserView.applyChatZoom(5, to: view)
        XCTAssertEqual(view.pageZoom, 2, accuracy: 0.001)
        BrowserView.applyChatZoom(0.1, to: view)
        XCTAssertEqual(view.pageZoom, 0.75, accuracy: 0.001)
        BrowserView.applyChatZoom(.nan, to: view)
        XCTAssertEqual(view.pageZoom, DesktopChatAppearance.defaultZoom, accuracy: 0.001)
        XCTAssertTrue(view.configuration.userContentController.userScripts.isEmpty,
                      "Zoom must not inject page scripts")
    }

    func testPlatformIdentityIsTheMacWorkspace() {
        XCTAssertTrue(AppPlatform.isMac)
        XCTAssertEqual(WorkspacePlatform.current, .mac)
        XCTAssertTrue(WorkspacePlatform.current.usesWorkspaceChrome)
        XCTAssertEqual(DeviceToolPlatform.current, .mac)
        XCTAssertEqual(NativeDevice.model, "Mac")
        XCTAssertEqual(NativeDevice.platformName, "macOS")
        XCTAssertTrue(NativeDevice.modelIdentifier.contains(","), "Expected a Mac model identifier, got \(NativeDevice.modelIdentifier)")
        XCTAssertTrue(["charging", "full", "unplugged", "unknown"].contains(NativeDevice.battery().state))
        XCTAssertFalse(NativeApp.supportsMultipleScenes, "Multiple client windows stay disabled")
    }

    func testClientWindowHidesOnCloseAndKeepsItsSceneIdentity() throws {
        let suite = "TermLLMMacTests.clientWindow.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = MacClientWindow(defaults: defaults)
        XCTAssertEqual(MacClientWindow(defaults: defaults).sceneIdentifier, client.sceneIdentifier,
                       "Push routing needs a stable window identity across launches")
        XCTAssertNil(client.scene(for: nil))

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSTextView()
        content.string = "unsent draft"
        window.contentView = content
        window.orderFront(nil)
        client.attach(window)
        XCTAssertTrue(client.scene(for: window) === client)
        XCTAssertNil(client.scene(for: NSWindow()), "Only the client window is the client scene")
        XCTAssertTrue(client.isAttachedToApp)
        XCTAssertTrue(client.isVisible)

        window.performClose(nil)
        XCTAssertFalse(window.isVisible, "Close hides the client window")
        XCTAssertFalse(client.isVisible)
        XCTAssertEqual(client.phase, .background, "A hidden window must not count as attended")
        XCTAssertFalse(client.isForegroundActive)
        XCTAssertTrue(window.contentView === content, "Close must not replace the document")

        client.show()
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(client.isVisible)
        XCTAssertNotEqual(client.phase, .background)
        XCTAssertEqual(content.string, "unsent draft")
        window.orderOut(nil)
    }

    /// SwiftUI adds the scene reader to the window while it renders. Attaching
    /// publishes the window's visibility and phase, so doing it there logs
    /// "Publishing changes from within view updates is not allowed".
    func testSceneReaderAttachesTheWindowAfterSwiftUIRendersIt() throws {
        let suite = "TermLLMMacTests.sceneReader.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = MacClientWindow(defaults: defaults)
        var ready: [NativeWindowScene] = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        let host = NSHostingView(rootView: Color.clear.background(NativeSceneReader(client: client) { ready.append($0) }))
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        func reader(in view: NSView) -> NativeSceneReader.Reader? {
            (view as? NativeSceneReader.Reader) ?? view.subviews.lazy.compactMap(reader).first
        }
        XCTAssertTrue(reader(in: host)?.window === window, "SwiftUI has rendered the reader into the window")
        XCTAssertFalse(client.isAttachedToApp, "Attaching must wait until SwiftUI finishes rendering")
        XCTAssertTrue(ready.isEmpty)

        let nextTurn = expectation(description: "next main-queue turn")
        DispatchQueue.main.async { nextTurn.fulfill() }
        wait(for: [nextTurn], timeout: 1)
        XCTAssertTrue(client.scene(for: window) === client)
        XCTAssertEqual(ready.count, 1)
        XCTAssertTrue(ready.first === client)
    }

    /// Mount the production shell and its retained destination controllers, not
    /// just the layout policy. This page has no server, credentials or bridges.
    func testWorkspaceShellRetainsFullWidthChatAcrossTabsAndWidthsWithoutSidebarToggles() async throws {
        let model = MacWorkspaceIdentityModel()
        let host = NSHostingController(rootView: MacWorkspaceIdentityFixture(model: model))
        host.sizingOptions = []
        // This AppKit test window has no SwiftUI Scene to own a toolbar.
        // Exercise the shell content without bridging window chrome.
        host.sceneBridgingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: model.width, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
        }
        host.view.layoutSubtreeIfNeeded()
        try await waitUntil("the shell to mount Chat") { model.webViews.count == 1 }
        let original = try XCTUnwrap(model.webViews.first)
        let identity = ObjectIdentifier(original)
        original.loadHTMLString("""
            <!doctype html><title>Workspace fixture</title>
            <style>html,body{margin:0}textarea{width:80%;height:100px}</style>
            <textarea aria-label="Draft"></textarea>
            """, baseURL: nil)
        try await waitUntil("the local Chat document to load") {
            original.title == "Workspace fixture" && !original.isLoading
        }
        _ = try await original.evaluateJavaScript(
            "document.querySelector('textarea').value = 'unsent Mac workspace draft'")

        // Cross the old overlay/persistent breakpoint in both directions and
        // return from every native destination at each width. In particular,
        // narrow Chat must not lose 44 pt to a rail, or wide Chat 220 pt to a sidebar.
        for width: CGFloat in [1200, 899, 900, 500, 1440] {
            model.width = width
            window.setContentSize(NSSize(width: width, height: 600))
            for tab: AppTab in [.chat, .agents, .chat, .music, .chat, .podcasts, .chat] {
                model.selection = tab
                host.view.needsLayout = true
                host.view.layoutSubtreeIfNeeded()
                try await waitUntil("Chat visibility/layout at \(width) / \(tab)") {
                    host.view.layoutSubtreeIfNeeded()
                    guard model.updatedWidth == width,
                          model.updatedVisibility == (tab == .chat) else { return false }
                    if tab == .chat {
                        return original.window === window && !original.isHiddenOrHasHiddenAncestor
                            && abs(original.bounds.width - width) <= 1
                    }
                    return original.window == nil
                }
                XCTAssertEqual(model.webViews.count, 1, "Chat was recreated at \(width) / \(tab)")
                XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(model.webViews.last)), identity)
                XCTAssertEqual(model.dismantles, 0, "Leaving Chat must not discard its document")
                if tab == .chat {
                    let frame = original.convert(original.bounds, to: host.view)
                    XCTAssertEqual(frame.minX, 0, accuracy: 1, "No leading rail or sidebar inset")
                    XCTAssertEqual(frame.maxX, width, accuracy: 1, "Chat must fill the shell width")
                    XCTAssertEqual(original.visibleRect.width, width, accuracy: 1,
                                   "The full-width Chat must actually be visible, not clipped")
                    let draft = try await original.evaluateJavaScript(
                        "document.querySelector('textarea').value") as? String
                    XCTAssertEqual(draft, "unsent Mac workspace draft")
                }
            }
            try await waitUntil("all native destinations to receive their sidebar toggle at \(width)") {
                [.agents, .music, .podcasts].allSatisfy { tab in
                    model.nativeToggleSamples.contains { $0.tab == tab && $0.width == width }
                }
            }
        }
        XCTAssertTrue(model.updateIdentities.allSatisfy { $0 == identity })
        XCTAssertTrue(model.nativeToggleSamples.allSatisfy { !$0.hasToggle },
                      "Mac native destinations must receive nil: navigation belongs to the shell toolbar")
        for tab: AppTab in [.agents, .music, .podcasts] {
            XCTAssertEqual(model.nativeMounts[tab], 1, "Native destination stacks must stay mounted")
        }
    }

    func testMenuCommandsNeedTheClientWindowToOwnTheKeyboard() {
        let center = DesktopCommandCenter()
        var received: [DesktopCommand] = []
        let policy = DesktopCommandPolicy(tab: .chat, enabled: true, hasSources: true, chatAvailable: true,
                                          chatParked: false, canGoBack: true, canZoom: true)
        center.install(policy: policy) { received.append($0) }
        XCTAssertEqual(center.title(for: .refresh), "Reload Chat")
        XCTAssertEqual(center.title(for: .resetZoom), "Actual Size")
        // The unit-test host shows no client window, so nothing may run.
        XCTAssertFalse(MacClientWindow.shared.ownsKeyboard)
        for command in DesktopCommand.allCases {
            XCTAssertFalse(center.allows(command))
            center.perform(command)
        }
        XCTAssertTrue(received.isEmpty, "Commands must not reach a window that is not key")
    }

    func testKeyboardShortcutsMatchTheDocumentedKeys() {
        XCTAssertEqual(DesktopCommand.tabs.map(\.keyEquivalent.character), ["1", "2", "3", "4"])
        XCTAssertEqual(DesktopCommand.settings.keyEquivalent.character, ",")
        XCTAssertEqual(DesktopCommand.back.keyEquivalent.character, "[")
        XCTAssertEqual(DesktopCommand.zoom.map(\.keyEquivalent.character), ["+", "-", "0"])
    }

    func testHostedTestRunShowsNoClientWindow() {
        XCTAssertTrue(MacLocalServiceBridge.isHostedTestRun)
        XCTAssertNil(MacClientWindow.shared.window, "The test host must not open the developer's connections")
    }
}

/// Test-local roots deliberately avoid the app's stores, players and Keychain.
@MainActor
private final class MacWorkspaceIdentityModel: ObservableObject {
    @Published var selection: AppTab = .chat
    @Published var width: CGFloat = 820
    var webViews: [WKWebView] = []
    var updateIdentities: [ObjectIdentifier] = []
    var updatedWidth: CGFloat?
    var updatedVisibility: Bool?
    var dismantles = 0
    var nativeToggleSamples: [(tab: AppTab, width: CGFloat, hasToggle: Bool)] = []
    var nativeMounts: [AppTab: Int] = [:]
}

@MainActor
private struct MacWorkspaceIdentityFixture: View {
    @ObservedObject var model: MacWorkspaceIdentityModel

    var body: some View {
        WorkspaceShell(platform: .mac, selection: model.selection, visitedTabs: Set(AppTab.allCases),
                       chatAgentName: "Fixture Agent", onSelect: { model.selection = $0 }, onSettings: {}) { toggle in
            nativeDestination(.agents, toggle: toggle)
        } chat: {
            MacWorkspaceWebViewProbe(model: model, width: model.width, isVisible: model.selection == .chat)
        } music: { toggle in
            nativeDestination(.music, toggle: toggle)
        } podcasts: { toggle in
            nativeDestination(.podcasts, toggle: toggle)
        } shelf: {
            EmptyView()
        }
        .frame(width: model.width, height: 600)
    }

    private func nativeDestination(_ tab: AppTab, toggle: (() -> Void)?) -> some View {
        MacWorkspaceNativeProbe(model: model, tab: tab, width: model.width, hasToggle: toggle != nil)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
private struct MacWorkspaceWebViewProbe: NSViewRepresentable {
    let model: MacWorkspaceIdentityModel
    let width: CGFloat
    let isVisible: Bool

    func makeCoordinator() -> MacWorkspaceIdentityModel { model }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        model.webViews.append(view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        model.updateIdentities.append(ObjectIdentifier(view))
        model.updatedWidth = width
        model.updatedVisibility = isVisible
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: MacWorkspaceIdentityModel) {
        coordinator.dismantles += 1
    }
}

@MainActor
private struct MacWorkspaceNativeProbe: NSViewRepresentable {
    let model: MacWorkspaceIdentityModel
    let tab: AppTab
    let width: CGFloat
    let hasToggle: Bool

    func makeNSView(context: Context) -> NSView {
        model.nativeMounts[tab, default: 0] += 1
        return NSView()
    }

    func updateNSView(_ view: NSView, context: Context) {
        model.nativeToggleSamples.append((tab: tab, width: width, hasToggle: hasToggle))
    }
}
