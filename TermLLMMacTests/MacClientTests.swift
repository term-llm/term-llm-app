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
               file: StaticString = #filePath, line: UInt = #line,
               _ condition: () -> Bool) async throws {
    try await pollUntil(description(), timeout: .seconds(timeout), interval: .milliseconds(50),
                        file: file, line: line, condition)
}

/// The native Mac client's platform behavior. Mac Catalyst's WebKit has no
/// media capture at all; this target exists so Chat can use the microphone.
@MainActor
final class MacClientTests: XCTestCase {
    func testDestinationToolbarUsesAContentSizedNativePicker() async throws {
        func segmentedControl(in view: NSView) -> NSSegmentedControl? {
            if let control = view as? NSSegmentedControl { return control }
            return view.subviews.lazy.compactMap(segmentedControl).first
        }
        let host = NSHostingController(rootView: Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar { MacWorkspaceToolbar(selection: .agents, onSelect: { _ in }) })
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 120),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.toolbarStyle = .unifiedCompact
        window.contentViewController = host
        window.setContentSize(NSSize(width: 820, height: 120))
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentViewController = nil }
        try await waitUntil("the native destination toolbar") {
            host.view.layoutSubtreeIfNeeded()
            return window.contentView?.superview.flatMap(segmentedControl) != nil
        }
        let chrome = try XCTUnwrap(window.contentView?.superview)
        let control = try XCTUnwrap(segmentedControl(in: chrome))
        XCTAssertEqual(control.segmentCount, 4)
        XCTAssertLessThan(control.frame.width, 360, "Do not stretch the picker to an arbitrary toolbar width")
        XCTAssertEqual(control.frame.width, control.intrinsicContentSize.width, accuracy: 1)
    }

    func testConversationListAndSearchShareTheSameColumn() async throws {
        for width: CGFloat in [820, 1180, 1440] {
            let measurements = ConversationLayoutMeasurements()
            let host = NSHostingController(rootView: NavigationStack {
                ConversationListLayoutFixture(measurements: measurements)
            }.frame(maxWidth: .infinity, maxHeight: .infinity))
            host.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 500),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = host
            window.setContentSize(NSSize(width: width, height: 500))
            window.orderFront(nil)
            defer { window.orderOut(nil); window.contentViewController = nil }
            try await waitUntil("search and list row geometry at \(width): \(measurements.frames)") {
                host.view.layoutSubtreeIfNeeded()
                return (measurements.frames["search"]?.width ?? 0) > 0 && (measurements.frames["row"]?.width ?? 0) > 0
            }
            let search = try XCTUnwrap(measurements.frames["search"])
            let row = try XCTUnwrap(measurements.frames["row"])
            XCTAssertEqual(search.minX, row.minX, accuracy: 1,
                           "Search and the session row must share a column edge")
            XCTAssertEqual(row.minX, max(20, (width - 900) / 2), accuracy: 1)
            XCTAssertEqual(row.width, min(900, width - 40), accuracy: 1)
            if width == 1180 {
                let image = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
                host.view.cacheDisplay(in: host.view.bounds, to: image)
                let attachment = XCTAttachment(data: try XCTUnwrap(image.representation(using: .png, properties: [:])),
                                               uniformTypeIdentifier: "public.png")
                attachment.name = "chat-style-native-sessions"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    func testAgentsPanelPickerStaysCenteredWithAndWithoutSearch() async throws {
        func segmentedControl(in view: NSView) -> NSSegmentedControl? {
            if let control = view as? NSSegmentedControl { return control }
            return view.subviews.lazy.compactMap(segmentedControl).first
        }

        for width: CGFloat in [820, 1180, 1440] {
            for panel in PhoneHubView.Panel.allCases {
                let host = NSHostingView(rootView: PhoneHubPanelControls(
                    selection: panel, attention: "3", usesWorkspaceChrome: true, onSelect: { _ in }) {
                        TextField("Search sessions", text: .constant(""))
                            .frame(maxWidth: .infinity)
                    })
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 200),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                defer { window.orderOut(nil); window.contentView = nil }
                try await waitUntil("native panel picker at \(width) / \(panel)") {
                    host.layoutSubtreeIfNeeded()
                    return segmentedControl(in: host) != nil
                }
                let control = try XCTUnwrap(segmentedControl(in: host))
                let frame = host.convert(control.bounds, from: control)
                XCTAssertEqual(frame.midX, width / 2, accuracy: 1,
                               "Adding Sessions search must not move the picker off centre")
                XCTAssertEqual(control.segmentCount, 3)
                XCTAssertTrue(control.label(forSegment: 1)?.contains("3") == true,
                              "The native Attention segment must keep its count")
            }
        }
    }

    func testWindowCallbacksPublishAfterTheCurrentUpdateReturns() async throws {
        let suite = "TermLLMMacTests.deferredWindow.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = MacClientWindow(defaults: defaults)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        client.attach(window)
        defer { window.orderOut(nil) }
        // Drain attachment/activation before testing the close callback.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
        var publications = 0
        let observation = client.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }

        window.performClose(nil)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(client.isForegroundActive, "Attendance must use live AppKit state, even before UI publication")
        XCTAssertEqual(publications, 0,
                       "AppKit callbacks may run during SwiftUI layout; observable state must not publish synchronously")
        try await waitUntil("deferred hidden-window publication") { !client.isVisible && client.phase == .background }
        XCTAssertGreaterThan(publications, 0)
    }

    func testSettingsPresentationFitsTheParentInsteadOfItsHistory() {
        XCTAssertEqual(MacSettingsLayout.size(available: CGSize(width: 1180, height: 800)),
                       CGSize(width: 680, height: 600))
        XCTAssertEqual(MacSettingsLayout.size(available: CGSize(width: 820, height: 560)),
                       CGSize(width: 680, height: 512))
        XCTAssertEqual(MacSettingsLayout.size(available: CGSize(width: 640, height: 400)),
                       CGSize(width: 592, height: 352))
        for available in [CGSize.zero, CGSize(width: 32, height: 32), CGSize(width: 420, height: 280)] {
            let size = MacSettingsLayout.size(available: available)
            XCTAssertGreaterThanOrEqual(size.width, 0)
            XCTAssertGreaterThanOrEqual(size.height, 0)
            XCTAssertLessThanOrEqual(size.width, available.width)
            XCTAssertLessThanOrEqual(size.height, available.height)
        }
    }

    func testSettingsLongFormKeepsAFinitePresentation() {
        let available = CGSize(width: 820, height: 560)
        let expected = MacSettingsLayout.size(available: available)
        let host = NSHostingView(rootView: MacSettingsPresentation(onClose: {}, availableSize: available) {
            NavigationStack {
                Form {
                    Section("History") {
                        ForEach(0..<120) { index in
                            Text("Event \(index): a long diagnostic entry that must scroll inside the sheet.")
                        }
                    }
                }
                .settingsPageTitle("Diagnostics")
            }
        })
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: expected),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.width, expected.width, accuracy: 1)
        XCTAssertEqual(host.fittingSize.height, expected.height, accuracy: 1)
    }

    func testSettingsOwnsCommandWWithoutClosingTheClient() async throws {
        var dismissed = false
        let host = NSHostingView(rootView: MacSettingsPresentation(onClose: { dismissed = true }) {
            Text("Nested settings page")
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 600),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                                                  modifierFlags: .command, timestamp: 0,
                                                  windowNumber: window.windowNumber, context: nil,
                                                  characters: "w", charactersIgnoringModifiers: "w",
                                                  isARepeat: false, keyCode: 13))
        XCTAssertTrue(window.performKeyEquivalent(with: event))
        try await waitUntil("Settings to consume Command-W", timeout: 1) { dismissed }
        XCTAssertTrue(window.isVisible, "The sheet shortcut must not close the underlying client")
    }

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

    func testClientWindowHidesOnCloseAndKeepsItsSceneIdentity() async throws {
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
        XCTAssertFalse(client.isForegroundActive, "Attendance follows live visibility without waiting for UI state")
        try await waitUntil("hidden client UI snapshot") { !client.isVisible && client.phase == .background }
        XCTAssertFalse(client.isVisible)
        XCTAssertEqual(client.phase, .background, "A hidden window must not count as attended")
        XCTAssertFalse(client.isForegroundActive)
        XCTAssertTrue(window.contentView === content, "Close must not replace the document")

        client.show()
        XCTAssertTrue(window.isVisible)
        try await waitUntil("reopened client UI snapshot") { client.isVisible && client.phase != .background }
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
private final class ConversationLayoutMeasurements {
    var frames: [String: CGRect] = [:]
}

private struct ConversationLayoutMarker: NSViewRepresentable {
    let name: String
    let measurements: ConversationLayoutMeasurements

    func makeNSView(context: Context) -> Marker {
        Marker(name: name, measurements: measurements)
    }

    func updateNSView(_ view: Marker, context: Context) {
        view.needsLayout = true
        DispatchQueue.main.async { [weak view] in view?.captureFrame() }
    }

    final class Marker: NSView {
        let name: String
        let measurements: ConversationLayoutMeasurements

        init(name: String, measurements: ConversationLayoutMeasurements) {
            self.name = name
            self.measurements = measurements
            super.init(frame: .zero)
        }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() {
            super.layout()
            captureFrame()
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            captureFrame()
        }
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            captureFrame()
        }
        func captureFrame() {
            guard window != nil else { return }
            measurements.frames[name] = convert(bounds, to: nil)
        }
    }
}

private struct ConversationListLayoutFixture: View {
    let measurements: ConversationLayoutMeasurements

    var body: some View {
        WorkspaceSessionList(wide: true) {
            Section {
                ForEach(0..<4) { index in
                    Button {} label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(["Mac UI Audit Findings", "Redesign Agent Selection Menu",
                                  "Eliminate Flaky Slow Tests", "Mac App Sidebar Cleanup"][index])
                                .font(.system(size: 15))
                            Text("This Mac · 5 minutes ago")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        .modifier(WorkspaceConversationLabel())
                    }
                    .buttonStyle(.plain)
                    .modifier(WorkspaceConversationRow(isSelected: index == 0))
                    .background(ConversationLayoutMarker(name: index == 0 ? "row" : "row-\(index)", measurements: measurements))
                }
            }
            .listSectionSeparator(.hidden)
        }
        .contentMargins(.top, 8, for: .scrollContent)
        .workspaceTopBar {
            PhoneHubPanelControls(selection: .sessions, attention: nil, usesWorkspaceChrome: true, onSelect: { _ in }) {
                HStack(spacing: 8) {
                    PhoneHubSessionSearchField(text: .constant(""), onSubmit: {})
                        .background(ConversationLayoutMarker(name: "search", measurements: measurements))
                    Image(systemName: "arrow.up.arrow.down").frame(width: 32, height: 32)
                }
            }
        }
        .background(Color.platformBackground)
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
