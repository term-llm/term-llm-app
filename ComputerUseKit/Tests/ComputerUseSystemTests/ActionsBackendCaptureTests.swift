import ComputerUseCore
import XCTest

@testable import ComputerUseSystem

/// Audited fake-only worker regressions, separate from the event-oriented suite.
/// ContextAX/ContextElement contain synchronized fixture data only. No AX SDK
/// calls, CGEvents, app resolution, pasteboard, overlays, input or activity occur.
final class ActionsBackendCaptureTests: XCTestCase {
    private let target = AppTarget(path: "/A/Test.app", bundleID: "dev.test", name: "Test", pid: 77)

    func testMenuPressCapturesCallerBackendOutsideWorkerScope() throws {
        let caller = ContextAX(), worker = ContextAX(), clock = ContextClock()
        let opener = ContextElement("AXPopUpButton", id: 0, rect: nil)
        let menu = ContextElement("AXMenu", id: 0, rect: nil)
        caller.onPerform = { element, action in
            XCTAssertTrue(AX.same(element, opener.ref))
            if action == "AXPress" { opener.set("AXShownMenuUIElement", menu.ref) }
        }
        let actions = makeActions(caller: caller, worker: worker, clock: clock)
        let app = AppSession(agent: AgentSession(key: "backend-press"), target: target)
        let line = Line(depth: 0, text: "popup", element: opener.ref, role: "AXPopUpButton",
                        actions: [(label: "Open", action: "AXPress")], id: 1)
        try AX.withBackend(caller) { try actions.secondary(app, line, "Open") }
        XCTAssertEqual(caller.performed.map { $0.1 }, ["AXPress"])
        XCTAssertTrue(AX.same(caller.performed.first?.0, opener.ref))
        XCTAssertTrue(worker.performed.isEmpty, "The worker's fallback backend must never perform the action")
    }

    func testMenuFillCapturesCallerBackendOutsideWorkerScope() throws {
        let caller = ContextAX(), worker = ContextAX(), clock = ContextClock()
        let menu = ContextElement("AXMenu", id: 0, rect: nil)
        let item = ContextElement("AXMenuItem", id: 0, rect: nil)
        let title = ContextElement("AXMenuBarItem", id: 0, rect: nil, attrs: ["AXChildren": [menu.ref]])
        caller.onPerform = { _, action in
            if action == "AXPress" { menu.set("AXChildren", [item.ref]) }
        }
        let actions = makeActions(caller: caller, worker: worker, clock: clock)
        let app = AppSession(agent: AgentSession(key: "backend-fill"), target: target)
        let line = Line(depth: 0, text: "menu", element: title.ref, role: "AXMenuBarItem", id: 1)
        try AX.withBackend(caller) { try actions.click(app, .line(line)) }
        XCTAssertEqual(caller.performed.map { $0.1 }, ["AXPress", "AXCancel"])
        XCTAssertTrue(AX.same(caller.performed.first?.0, title.ref))
        XCTAssertTrue(worker.performed.isEmpty, "The worker's fallback backend must never perform the action")
    }

    private func makeActions(caller: ContextAX, worker: ContextAX, clock: ContextClock) -> Actions {
        var windows = isolatedWindowsSystem()
        windows.rows = { _, _ in XCTFail("No window-server reads expected"); return [] }
        windows.associated = { _ in XCTFail("No associated-window reads expected"); return [] }
        windows.noAttention = { _ in XCTFail("No attention changes expected") }
        windows.now = { clock.time }
        windows.sleep = { clock.sleep($0) }
        var focus = isolatedFocusSystem()
        focus.frontPID = { 77 } // Already focused: never construct activation events.
        focus.now = { clock.time }
        focus.sleep = { _ in XCTFail("No focus wait expected") }
        focus.post = { _, _ in XCTFail("No focus events expected") }
        focus.noAttention = { _ in XCTFail("No attention changes expected") }
        focus.freeze = { XCTFail("No screen freeze expected") }
        focus.thaw = { XCTFail("No screen thaw expected") }
        focus.background = { _ in XCTFail("No focus watcher expected") }
        focus.personWent = { _, _ in XCTFail("No input monitor expected"); return false }
        var system = Actions.System()
        system.apps = Apps(system: isolatedAppsSystem())
        system.windows = Windows(system: windows)
        system.focus = Focus(system: focus)
        system.presence = Presence(enabled: { false }, send: { _ in XCTFail("No overlay expected") },
                                   schedule: { _ in XCTFail("No overlay scheduling expected") })
        system.pasteboard = Pasteboard(board: {
            XCTFail("No pasteboard access expected")
            return Pasteboard.Backend(snapshot: { [] }, write: { _ in nil }, restore: { _, _ in false })
        })
        system.post = { _, _, _ in XCTFail("No events expected") }
        system.heldFlags = { XCTFail("No HID query expected"); return 0 }
        system.presses = { _ in XCTFail("No key mapping expected"); return [] }
        system.printedText = { _ in XCTFail("No printed text expected"); return ("", nil) }
        system.focusElement = { _ in XCTFail("No focus change expected"); return false }
        system.checkRecipient = { _ in XCTFail("All fixtures belong to the target") }
        system.now = { clock.time }
        system.sleep = { clock.sleep($0) }
        system.background = { work in
            XCTAssertTrue(AX.backend === caller)
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                // GCD does not inherit the caller's TaskLocal. Do not call that
                // global backend: install a second fake scope before running work,
                // so even the pre-fix regression cannot touch a real AX backend.
                XCTAssertFalse(AX.backend === caller)
                AX.withBackend(worker) { work() }
                done.signal()
            }
            XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        }
        return Actions(system: system)
    }
}
