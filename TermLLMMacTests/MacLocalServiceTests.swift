import AppKit
import SwiftUI
import TermLLMMacKit
import XCTest
@testable import TermLLM

/// The local term-llm service integration, now compiled into the Mac app.
/// Temporary homes, synthetic CLIs and a loopback fixture only: no installed
/// service, real login item, Keychain credential or real home is touched.
@MainActor
final class MacLocalServiceTests: XCTestCase {
    private var home: URL!

    override func setUp() async throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("term-llm-mac-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: Handoff contract

    func testHandoffAcceptsOnlyAManagedLoopbackServiceAndACredential() {
        let valid = MacLocalServiceBridge.request(baseURL: "http://127.0.0.1:8737/", token: "opaque-token", open: true)
        XCTAssertEqual(valid?.baseURL.absoluteString, "http://127.0.0.1:8737/")
        XCTAssertEqual(valid?.token, "opaque-token")
        XCTAssertEqual(MacLocalServiceBridge.request(baseURL: "http://localhost:8737", token: "t", open: false)?
            .baseURL.absoluteString, "http://localhost:8737/")
        for address in ["https://example.com/", "http://192.168.1.2:8737/", "http://127.0.0.1/", "http://user@127.0.0.1:8737/",
                        "http://127.0.0.1:8737/?token=x", "ftp://127.0.0.1:8737/", "http://127.0.0.1:8737/a/../b/"] {
            XCTAssertNil(MacLocalServiceBridge.request(baseURL: address, token: "t", open: true), address)
        }
        for token in ["", "   ", "a\nb", "a\rb"] {
            XCTAssertNil(MacLocalServiceBridge.request(baseURL: "http://127.0.0.1:8737/", token: token, open: true))
        }
    }

    func testBackgroundInclusionNeverOverridesAPendingOpenChat() throws {
        let bridge = MacLocalServiceBridge()
        let base = try XCTUnwrap(URL(string: "http://127.0.0.1:8737/"))
        bridge.receive(baseURL: base, token: "first", open: true)
        bridge.receive(baseURL: base, token: "background", open: false)
        XCTAssertEqual(bridge.request?.token, "first", "A pending Open Chat already adds This Mac")
        XCTAssertNil(bridge.error)

        let other = MacLocalServiceBridge()
        other.receive(baseURL: try XCTUnwrap(URL(string: "https://example.com/")), token: "x", open: false)
        XCTAssertNil(other.request)
        XCTAssertNil(other.error, "Background inclusion stays silent")
        other.receive(baseURL: try XCTUnwrap(URL(string: "https://example.com/")), token: "x", open: true)
        XCTAssertNotNil(other.error, "An explicit Open Chat explains why nothing opened")
        let id = try XCTUnwrap(bridge.request?.id)
        XCTAssertEqual(bridge.takeRequest(id)?.token, "first")
        XCTAssertNil(bridge.request)
    }

    func testHiddenWindowUsesBackgroundPhase() {
        for phase in [ScenePhase.active, .inactive, .background] {
            XCTAssertEqual(MacLocalServiceBridge.effectiveScenePhase(phase, isMainWindowVisible: false), .background)
            XCTAssertEqual(MacLocalServiceBridge.effectiveScenePhase(phase, isMainWindowVisible: true), phase)
        }
    }

    // MARK: Window lifecycle and menu-bar item

    func testRetainedWindowHidesOnCloseAndForwardsOtherDelegateCalls() {
        final class OriginalDelegate: NSObject, NSWindowDelegate {
            var closeDecisions = 0
            var resizeCalls = 0
            func windowShouldClose(_ sender: NSWindow) -> Bool { closeDecisions += 1; return true }
            func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
                resizeCalls += 1
                return NSSize(width: frameSize.width + 10, height: frameSize.height)
            }
        }
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 420, height: 240),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let original = OriginalDelegate()
        window.delegate = original
        let content = NSTextView()
        content.string = "unsent fixture draft"
        window.contentView = content
        window.orderFront(nil)
        var visibility: [Bool] = []
        let retained = RetainedWindowDelegate(window: window) { visibility.append($0) }
        XCTAssertTrue(window.delegate === retained)
        XCTAssertEqual(visibility, [true])

        // The real AppKit close action (red button and Command-W) hides.
        window.performClose(nil)
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(original.closeDecisions, 0, "Hiding must not enter SwiftUI's scene-destruction path")
        XCTAssertTrue(window.contentView === content)
        XCTAssertEqual(content.string, "unsent fixture draft")
        XCTAssertEqual(visibility, [true, false])

        retained.show()
        XCTAssertTrue(window.isVisible && retained.isVisible)
        XCTAssertEqual(visibility, [true, false, true])

        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
                             styleMask: [.titled], backing: .buffered, defer: false)
        window.beginSheet(sheet)
        XCTAssertFalse(retained.windowShouldClose(window), "Never strand a sheet behind a hidden window")
        XCTAssertTrue(window.isVisible)
        window.endSheet(sheet)
        sheet.orderOut(nil)

        XCTAssertTrue(retained.responds(to: #selector(NSWindowDelegate.windowWillResize(_:to:))))
        let resized = window.delegate?.windowWillResize?(window, to: NSSize(width: 500, height: 300))
        XCTAssertEqual(resized?.width, 510)
        XCTAssertEqual(original.resizeCalls, 1)

        let other = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        XCTAssertTrue(retained.windowShouldClose(other), "Other windows keep normal close semantics")
        XCTAssertEqual(original.closeDecisions, 1)
        window.orderOut(nil)
    }

    /// Computer Use state inside the temporary home, never this Mac's own.
    private func isolatedComputerUse(enabled: Bool = false) throws -> ComputerUseController {
        let files = ComputerUseInstallation(
            home: home, state: home.appendingPathComponent("computer-use"),
            binary: home.appendingPathComponent("term-llm.app/Contents/Helpers/term-llm-computer"))
        if enabled { try files.setEnabled(true) }
        return ComputerUseController(home: home, state: files.state, binary: files.binary, suppressRuntime: true)
    }

    func testMenuBarItemWorksWithoutLocalServiceSetup() throws {
        let controller = MacLocalServiceController(home: home, computerUse: try isolatedComputerUse())
        let menu = NSMenu()
        controller.menuNeedsUpdate(menu)
        XCTAssertEqual(menu.items.map(\.title), ["Open term-llm", "Local Service…", "Computer Use…",
                                               "App Updates Unavailable", "", "Quit term-llm"],
                       "A remote-only app needs Open and Quit without local-service setup")
        XCTAssertFalse(menu.items.first { $0.title == "App Updates Unavailable" }?.isEnabled ?? true,
                       "The hosted test must expose a diagnostic, never a live updater")
        XCTAssertFalse(menu.items.contains { $0.title.contains("Start Service") || $0.title.contains("Stop Service") },
                       "Opening the menu must not opt into local services")
        XCTAssertEqual(menu.items.last?.action, #selector(MacLocalServiceController.quitTermLLM))
    }

    func testExistingLocalInstallShowsFullMenuWithoutOpeningSetupOrRestarting() throws {
        let provisioner = CLIProvisioner(home: home)
        for marker in [provisioner.manifestURL, DeveloperModeStore(provisioner: provisioner).url] {
            try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: marker)
            let controller = MacLocalServiceController(home: home, computerUse: try isolatedComputerUse())
            let menu = NSMenu()
            controller.menuNeedsUpdate(menu)
            XCTAssertEqual(menu.items.map(\.title), [
                "Open term-llm", "Local Service…", "Computer Use…", "", "Local service: Not set up",
                "Open Local Chat", "Start Service", "Restart Service", "App Updates Unavailable", "", "Quit term-llm"
            ], "An existing \(marker.lastPathComponent) must expose controls before any setup or service action")
            XCTAssertFalse(try XCTUnwrap(menu.items.first { $0.title == "Restart Service" }).isEnabled,
                           "Showing controls must not enable restarting an unverified service")
            try FileManager.default.removeItem(at: marker)
        }
    }

    func testComputerUseProblemsAreCalledOutAtTheTopOfTheMenu() async throws {
        let computerUse = try isolatedComputerUse(enabled: true)
        let controller = MacLocalServiceController(home: home, computerUse: computerUse)
        let menu = NSMenu()
        controller.menuNeedsUpdate(menu)
        XCTAssertEqual(menu.items.first?.title, "Open term-llm", "Nothing is called out before the files are checked")
        computerUse.refreshInstallations()
        try await waitUntil("files checked") { computerUse.setup != nil }
        controller.menuNeedsUpdate(menu)
        XCTAssertEqual(menu.items.map(\.title), [
            "Computer Use Needs Attention…", "", "Open term-llm", "Local Service…", "Computer Use…", "",
            "Computer use: Starting…", "Pause Computer Use", "App Updates Unavailable", "", "Quit term-llm",
        ])
        let callout = try XCTUnwrap(menu.items.first)
        XCTAssertTrue(callout.isEnabled)
        XCTAssertEqual(callout.action, NSSelectorFromString("showComputerUse"), "It opens the Computer Use window")
        if #available(macOS 14.4, *) { XCTAssertEqual(callout.subtitle, "Command not installed · Skill not installed") }
    }

    func testComputerUseSetupRefreshIsFrozenDuringTerminationPreparation() async throws {
        let computerUse = try isolatedComputerUse(enabled: true)
        computerUse.beginTerminationPreparation()
        computerUse.refreshInstallations(repair: true)
        await Task.yield()
        XCTAssertNil(computerUse.setup, "Termination preparation must not admit file repair or setup refresh work")
        computerUse.cancelTerminationPreparation()
        computerUse.refreshInstallations()
        try await waitUntil("files checked after cancellation") { computerUse.setup != nil }
        XCTAssertEqual(computerUse.setup, ComputerUseSetup(commandInstalled: false, skill: .missing))
        XCTAssertEqual(computerUse.issues, [.command, .skillMissing],
                       "Cancelling preparation must restore main's setup diagnostics")
    }

    // MARK: Local Service window

    func testLocalServiceWindowStartsSimpleWithAdvancedCollapsed() async throws {
        let model = CompanionModel(home: home, loginService: nil)
        let controller = LocalServiceViewController(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 320),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        controller.fitWindowToContent()
        controller.view.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func button(_ title: String) throws -> NSButton {
            try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.title == title },
                          "Missing control: \(title)")
        }
        func shown(_ view: NSView) -> Bool { !view.isHiddenOrHasHiddenAncestor }
        func texts() -> [String] {
            descendants(controller.view).compactMap { $0 as? NSTextField }.filter(shown).map(\.stringValue)
        }

        XCTAssertTrue(texts().contains("term-llm isn't set up on this Mac"))
        let setUp = try button("Set Up term-llm")
        XCTAssertTrue(shown(setUp) && setUp.isEnabled && setUp.keyEquivalent == "\r", "Set Up is the default action")
        XCTAssertFalse(shown(try button("Start the local service when you log in")))
        for title in ["Developer Mode…", "Copy Diagnostics"] {
            XCTAssertFalse(shown(try button(title)), "Advanced control visible before expanding: \(title)")
        }
        let collapsedHeight = window.frame.height
        try button("Advanced").performClick(nil)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(shown(try button("Developer Mode…")))
        XCTAssertTrue(texts().contains("Not installed"))
        for title in ["Check for Updates", "Stop Managing…", "Remove…", "Switch to the App's Copy…", "Restart", "Reinstall Service"] {
            XCTAssertFalse(shown(try button(title)), "Inapplicable control shown: \(title)")
        }
        XCTAssertGreaterThan(window.frame.height, collapsedHeight)
        try button("Advanced").performClick(nil)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertFalse(shown(try button("Developer Mode…")))

        // Open at Login is opt-in and, with no system service injected, only
        // ever writes inside the temporary home.
        let login = try button("Open term-llm when you log in")
        XCTAssertEqual(login.state, .off)
        let loginItem = AppLoginItem(home: home)
        login.performClick(nil)
        try await waitUntil { model.loginItemEnabled && !model.busy && login.state == .on }
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: loginItem.plistURL), format: nil)
            as? [String: Any]
        XCTAssertEqual(plist?["ProgramArguments"] as? [String], [try XCTUnwrap(Bundle.main.executableURL).path],
                       "Open at Login launches this app")
        login.performClick(nil)
        try await waitUntil { !model.loginItemEnabled && !model.busy && login.state == .off }
        XCTAssertFalse(FileManager.default.fileExists(atPath: loginItem.plistURL.path))
    }

    // MARK: Authenticated handoff

    func testServiceIsHandedToTheClientOnlyAfterAnAuthenticatedProbe() async throws {
        let token = "synthetic-fixture-credential-only"
        let mode = home.appendingPathComponent("response-mode")
        try "authenticated".write(to: mode, atomically: true, encoding: .utf8)
        let server = try LoopbackHTTPServer { _, path, headers in
            let accepted = path == "/ui/v1/capabilities" && headers["authorization"] == "Bearer \(token)"
                && (try? String(contentsOf: mode, encoding: .utf8)) == "authenticated"
            return .init(status: accepted ? 200 : 401, contentType: "application/json",
                         body: Data((accepted ? #"{"projects":{"enabled":true},"shell":{"version":1}}"# : "{}").utf8))
        }
        let port = try await server.start()
        defer { server.stop() }
        let status = home.appendingPathComponent("status.json")
        try Self.statusJSON(port: port, host: "127.0.0.1", auth: "bearer").write(to: status, atomically: true, encoding: .utf8)
        let cli = home.appendingPathComponent("fixture-cli")
        try """
        #!/bin/sh
        case "$*" in
          'service status --json'|'service status web --json') cat '\(status.path)' ;;
          'service token web') printf '%s\\n' '\(token)' ;;
          *) exit 91 ;;
        esac
        """.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        try DeveloperModeStore(provisioner: CLIProvisioner(home: home)).enable(binary: cli)
        let model = CompanionModel(home: home, loginService: nil)

        var inclusions = 0
        model.connectLocalServiceHandler = { endpoint, offered in
            XCTAssertTrue(model.isChatAvailable, "Offered a credential before the authenticated probe")
            XCTAssertNil(endpoint.baseURL.query)
            XCTAssertEqual(offered, token)
            inclusions += 1
        }
        await model.refresh()
        XCTAssertEqual(inclusions, 1, "A verified local service is offered to the client")
        await model.refresh()
        XCTAssertEqual(inclusions, 1, "An unchanged service is not offered again")

        var handoffs = 0
        model.openLocalChatHandler = { endpoint, offered in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertNil(endpoint.baseURL.query, "No credential in the URL")
            XCTAssertEqual(offered, token)
            handoffs += 1
        }
        model.openChat()
        try await waitUntil("the first handoff") { handoffs == 1 }
        XCTAssertFalse(model.diagnosticsText().contains(token), "Diagnostics leaked the credential")

        // A cached authenticated result must not authorize a later handoff.
        try "unauthorized".write(to: mode, atomically: true, encoding: .utf8)
        model.openChat()
        try await waitUntil("a fresh 401 probe") { model.sessionOutcome == .unauthorized(401) }
        XCTAssertEqual(handoffs, 1, "A rejected credential reached the client")

        // A non-loopback endpoint never receives the credential.
        try Self.statusJSON(port: port, host: "example.invalid", auth: "bearer").write(to: status, atomically: true, encoding: .utf8)
        await model.refresh()
        XCTAssertFalse(model.isChatAvailable)
        model.openChat()
        try await waitUntil("the non-loopback refusal (\(model.actionError ?? "nil"))") { model.actionError?.contains("non-loopback") == true }
        XCTAssertEqual(handoffs, 1)

        // A fresh status read refuses to replace a service using passkey
        // authentication, even when a caller bypasses the disabled control.
        // (Still non-loopback, so the refresh that follows the refusal does not
        // probe and replace this error with the probe's.)
        try Self.statusJSON(port: port, host: "example.invalid", auth: "passkey").write(to: status, atomically: true, encoding: .utf8)
        model.installService()
        try await waitUntil("the passkey refusal (\(model.actionError ?? "nil"))") { !model.busy && model.actionError?.contains("will not replace or downgrade") == true }

        // No client means no fallback Chat.
        try Self.statusJSON(port: port, host: "127.0.0.1", auth: "bearer").write(to: status, atomically: true, encoding: .utf8)
        try "authenticated".write(to: mode, atomically: true, encoding: .utf8)
        model.openLocalChatHandler = nil
        model.openChat()
        try await waitUntil("the missing-client refusal (\(model.actionError ?? "nil"))") { model.actionError?.contains("Chat workspace is unavailable") == true }
        XCTAssertEqual(handoffs, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/LaunchAgents").path),
                       "A handoff must not create a login agent")
    }

    private static func statusJSON(port: UInt16, host: String, auth: String) -> String {
        """
        {"schema_version": 1, "services": [{"kind": "web", "installed": true, "managed": true,
          "registered": true, "state": "ready", "running": true, "autostart": false,
          "url": "http://\(host):\(port)/ui/", "port": \(port), "base_path": "/ui/", "auth": "\(auth)",
          "enrollment": "not_required", "healthy": true}]}
        """
    }
}
