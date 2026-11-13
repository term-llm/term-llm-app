import ComputerUseCore
import Foundation
import XCTest
import os

@testable import ComputerUseSystem

/// Pure ownership tests. Every platform seam is fail-fast or a synchronized fake.
/// These tests never construct CGEvents, access the pasteboard, query a real app,
/// start an observer, or use UI, permissions, input monitoring or power assertions.
final class PureActionsOwnershipTests: XCTestCase {
    private func target(_ pid: pid_t = 77) -> AppTarget {
        AppTarget(path: "/Fixture/\(pid).app", bundleID: "fixture.\(pid)", name: "Fixture", pid: pid)
    }

    private func line(_ element: ContextElement, role: String = "AXButton", action: String = "AXRaise") -> Line {
        Line(depth: 0, text: "fixture", element: element.ref, role: role,
             actions: [(label: "Do", action: action)], id: 1)
    }

    private func system(clock: ContextClock = ContextClock(), worker: ContextAX = ContextAX()) -> Actions.System {
        var windows = isolatedWindowsSystem()
        windows.now = { clock.time }
        windows.sleep = { clock.sleep($0) }
        var focus = isolatedFocusSystem()
        focus.frontPID = { 77 } // Menu-fill fixture is already focused; no activation events.
        focus.now = { clock.time }
        var s = Actions.System()
        s.apps = Apps(system: isolatedAppsSystem())
        s.windows = Windows(system: windows)
        s.focus = Focus(system: focus)
        s.presence = Presence(
            enabled: { false }, now: { XCTFail("Unexpected presence clock"); return 0 },
            send: { _ in XCTFail("Unexpected overlay") },
            schedule: { _ in XCTFail("Unexpected UI scheduling") },
            ask: { _ in XCTFail("Unexpected panel") }, withdraw: { _ in XCTFail("Unexpected panel") })
        s.pasteboard = Pasteboard(board: {
            XCTFail("Unexpected pasteboard")
            return .init(snapshot: { [] }, write: { _ in nil }, restore: { _, _ in false })
        }, stateDirectory: { XCTFail("Unexpected pasteboard persistence"); return URL(fileURLWithPath: "/unused") },
        wait: { _, _, _ in XCTFail("Unexpected paste wait"); return false })
        s.checkRecipient = { _ in XCTFail("All operations must remain in the fixture target") }
        s.post = { _, _, _ in XCTFail("Unexpected event") }
        s.heldFlags = { XCTFail("Unexpected HID query"); return 0 }
        s.presses = { _ in XCTFail("Unexpected key mapping"); return [] }
        s.printedText = { _ in XCTFail("Unexpected printed text read"); return ("", nil) }
        s.focusElement = { _ in XCTFail("Unexpected focus change"); return false }
        s.now = { clock.time }
        s.sleep = { clock.sleep($0) }
        s.background = { work in
            DispatchQueue.global().async {
                // Arbitrary GCD must not accidentally fall back to the real AX
                // registry, even in a negative control without backend capture.
                AX.withBackend(worker) { work() }
            }
        }
        return s
    }

    func testActionsAndBuilderAreSendableImmutableSnapshots() throws {
        func requireSendable<T: Sendable>(_ value: T) {}
        let log = ContextBox<[String]>([])
        var builder = system()
        builder.checkRecipient = { value in log.withValue { $0.append("first:\(value)") } }
        builder.now = { 123 }
        let first = Actions(system: builder)
        builder.checkRecipient = { value in log.withValue { $0.append("second:\(value)") } }
        builder.now = { 456 }
        builder.windows = Windows(system: isolatedWindowsSystem())
        let second = Actions(system: builder)
        requireSendable(first)
        requireSendable(builder)
        try first.system.checkRecipient("a")
        try second.system.checkRecipient("b")
        XCTAssertEqual(log.value, ["first:a", "second:b"])
        XCTAssertEqual(first.system.now(), 123)
        XCTAssertEqual(second.system.now(), 456)
        XCTAssertFalse(first.system.windows === second.system.windows)
        // Rebuilding from a copy preserves all other configured adapter identities.
        XCTAssertTrue(first.system.apps === second.system.apps)
        XCTAssertTrue(first.system.focus === second.system.focus)
        XCTAssertTrue(first.system.presence === second.system.presence)
        XCTAssertTrue(first.system.pasteboard === second.system.pasteboard)
    }

    func testSharedActionsAllowsIndependentSynchronousAppWorkers() {
        let actions = Actions(system: system())
        let first = ContextAX(), second = ContextAX()
        let firstElement = ContextElement("AXButton", pid: 77, id: 0, rect: nil)
        let secondElement = ContextElement("AXButton", pid: 88, id: 0, rect: nil)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let otherFinished = DispatchSemaphore(value: 0), all = DispatchGroup()
        let failures = ContextBox<[String]>([])
        let firstTarget = target(), secondTarget = target(88)
        first.onPerform = { element, action in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertTrue(AX.backend === first)
            XCTAssertTrue(AX.same(element, firstElement.ref))
            XCTAssertEqual(action, "AXRaise")
            entered.signal()
            XCTAssertEqual(release.wait(timeout: .now() + 10), .success)
        }
        second.onPerform = { element, _ in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertTrue(AX.backend === second)
            XCTAssertTrue(AX.same(element, secondElement.ref))
        }
        defer { first.onPerform = nil; second.onPerform = nil }
        all.enter()
        DispatchQueue.global().async {
            defer { all.leave() }
            // AppSession and Line are worker-local mutable graphs, not Sendable
            // payloads. Only the target and synchronized node cross this hop.
            let app = AppSession(agent: AgentSession(key: "first"), target: firstTarget)
            let request = Line(depth: 0, text: "first", element: firstElement.ref, role: "AXButton",
                               actions: [(label: "Do", action: "AXRaise")], id: 1)
            do { try AX.withBackend(first) { try actions.secondary(app, request, "Do") } }
            catch { failures.withValue { $0.append(String(describing: error)) } }
        }
        let started = entered.wait(timeout: .now() + 5)
        XCTAssertEqual(started, .success)
        all.enter()
        DispatchQueue.global().async {
            defer { all.leave(); otherFinished.signal() }
            let app = AppSession(agent: AgentSession(key: "second"), target: secondTarget)
            let request = Line(depth: 0, text: "second", element: secondElement.ref, role: "AXButton",
                               actions: [(label: "Do", action: "AXRaise")], id: 1)
            do { try AX.withBackend(second) { try actions.secondary(app, request, "Do") } }
            catch { failures.withValue { $0.append(String(describing: error)) } }
        }
        // The first target's blocked AX call must not serialize another app.
        XCTAssertEqual(otherFinished.wait(timeout: .now() + 5), .success)
        release.signal()
        XCTAssertEqual(all.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(failures.value.isEmpty, "\(failures.value)")
        XCTAssertEqual(first.performed.map { $0.1 }, ["AXRaise"])
        XCTAssertEqual(second.performed.map { $0.1 }, ["AXRaise"])
    }

    func testTimedOutPressCanFinishLateWithoutRetryOrBlockingAnotherCaller() throws {
        let caller = ContextAX(), next = ContextAX(), fallback = ContextAX()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()
        let opener = ContextElement("AXPopUpButton", id: 0, rect: nil)
        let nextOpener = ContextElement("AXPopUpButton", pid: 88, id: 0, rect: nil)
        caller.onPerform = { _, _ in
            XCTAssertFalse(Thread.isMainThread)
            entered.signal()
            XCTAssertEqual(release.wait(timeout: .now() + 10), .success)
            throw Errors.make("not_settable") // Late error stays with its own pending result.
        }
        var builder = system(worker: fallback)
        let dispatches = OSAllocatedUnfairLock(initialState: 0)
        builder.background = { work in
            let dispatch = dispatches.withLock { $0 += 1; return $0 }
            let completed = DispatchSemaphore(value: 0)
            finished.enter()
            DispatchQueue.global().async {
                defer { finished.leave() }
                AX.withBackend(fallback) { work() }
                completed.signal()
            }
            // Only the first worker models a late press. Join subsequent work
            // before returning so success does not depend on the real pressJoin.
            if dispatch > 1 { XCTAssertEqual(completed.wait(timeout: .now() + 5), .success) }
        }
        let actions = Actions(system: builder)
        let app = AppSession(agent: AgentSession(key: "timeout"), target: target())
        let nextApp = AppSession(agent: AgentSession(key: "next"), target: target(88))
        let request = line(opener, role: "AXPopUpButton", action: "AXPress")
        let nextRequest = line(nextOpener, role: "AXPopUpButton", action: "AXPress")
        defer { release.signal(); XCTAssertEqual(finished.wait(timeout: .now() + 5), .success) }
        XCTAssertThrowsError(try AX.withBackend(caller) { try actions.secondary(app, request, "Do") }) {
            XCTAssertEqual(($0 as? HarnessError)?.message, Errors.make("menu_click_failed").message)
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(finished.wait(timeout: .now()), .timedOut, "Caller returned before AXPress finished")
        try AX.withBackend(next) { try actions.secondary(nextApp, nextRequest, "Do") }
        XCTAssertEqual(dispatches.withLock { $0 }, 2)
        XCTAssertEqual(finished.wait(timeout: .now()), .timedOut, "The first worker must remain blocked")
        XCTAssertEqual(caller.performed.map { $0.1 }, ["AXPress"], "A timeout must not retry")
        XCTAssertEqual(next.performed.map { $0.1 }, ["AXPress"])
        XCTAssertTrue(fallback.performed.isEmpty, "Both workers must use their own captured caller backend")
    }

    func testVisibleMenuReturnsWhilePressIsStillInFlight() throws {
        let caller = ContextAX(), fallback = ContextAX()
        let release = DispatchSemaphore(value: 0), entered = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()
        let opener = ContextElement("AXPopUpButton", id: 0, rect: nil)
        let menu = ContextElement("AXMenu", id: 0, rect: nil)
        caller.onPerform = { _, _ in
            opener.set("AXShownMenuUIElement", menu.ref)
            entered.signal()
            XCTAssertEqual(release.wait(timeout: .now() + 10), .success)
        }
        var builder = system(worker: fallback)
        builder.background = { work in
            finished.enter()
            DispatchQueue.global().async {
                defer { finished.leave() }
                AX.withBackend(fallback) { work() }
            }
            XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        }
        let actions = Actions(system: builder)
        let app = AppSession(agent: AgentSession(key: "visible"), target: target())
        let request = line(opener, role: "AXPopUpButton", action: "AXPress")
        defer { release.signal(); XCTAssertEqual(finished.wait(timeout: .now() + 5), .success) }
        try AX.withBackend(caller) { try actions.secondary(app, request, "Do") }
        XCTAssertEqual(finished.wait(timeout: .now()), .timedOut)
        XCTAssertEqual(caller.performed.map { $0.1 }, ["AXPress"])
        XCTAssertTrue(fallback.performed.isEmpty)
    }

    func testCompletedFailurePropagatesAndWorkerCallbackCanReenterActions() throws {
        let caller = ContextAX(), fallback = ContextAX()
        var builder = system(worker: fallback)
        builder.background = { work in
            let completed = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                AX.withBackend(fallback) { work() }
                completed.signal()
            }
            // Inner AXRaise performs directly, so joining the outer worker is
            // safe and publishes its error before the completion assertion.
            XCTAssertEqual(completed.wait(timeout: .now() + 5), .success)
        }
        let actions = Actions(system: builder)
        let app = AppSession(agent: AgentSession(key: "reentrant"), target: target())
        let opener = ContextElement("AXPopUpButton", id: 0, rect: nil)
        let inner = ContextElement("AXButton", id: 0, rect: nil)
        let target = target()
        caller.onPerform = { _, action in
            if action == "AXPress" {
                // Scope the caller explicitly: Actions captures the backend for
                // perform, not the TaskLocal environment of arbitrary GCD work.
                let innerApp = AppSession(agent: AgentSession(key: "inner"), target: target)
                let innerRequest = Line(depth: 0, text: "inner", element: inner.ref, role: "AXButton",
                                        actions: [(label: "Do", action: "AXRaise")], id: 1)
                try AX.withBackend(caller) { try actions.secondary(innerApp, innerRequest, "Do") }
                throw Errors.make("not_settable")
            }
        }
        let request = line(opener, role: "AXPopUpButton", action: "AXPress")
        defer { caller.onPerform = nil }
        XCTAssertThrowsError(try AX.withBackend(caller) { try actions.secondary(app, request, "Do") }) {
            XCTAssertEqual(($0 as? HarnessError)?.message, Errors.make("not_settable").message)
        }
        XCTAssertEqual(caller.performed.map { $0.1 }, ["AXPress", "AXRaise"])
        XCTAssertTrue(fallback.performed.isEmpty)
    }

    func testMenuFillWorkerOwnsItsStateAfterCallerReturns() {
        let caller = ContextAX(), fallback = ContextAX()
        let release = DispatchSemaphore(value: 0), entered = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()
        let menu = ContextElement("AXMenu", id: 0, rect: nil)
        let item = ContextElement("AXMenuItem", id: 0, rect: nil)
        let title = ContextElement("AXMenuBarItem", id: 0, rect: nil, attrs: ["AXChildren": [menu.ref]])
        caller.onPerform = { _, action in
            guard action == "AXPress" else { return }
            entered.signal()
            XCTAssertEqual(release.wait(timeout: .now() + 10), .success)
            menu.set("AXChildren", [item.ref])
        }
        var builder = system(worker: fallback)
        builder.background = { work in
            finished.enter()
            DispatchQueue.global().async {
                defer { finished.leave() }
                AX.withBackend(fallback) { work() }
            }
            XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        }
        let actions = Actions(system: builder)
        let app = AppSession(agent: AgentSession(key: "fill-timeout"), target: target())
        let request = line(title, role: "AXMenuBarItem", action: "AXPress")
        XCTAssertThrowsError(try AX.withBackend(caller) { try actions.click(app, .line(request)) }) {
            XCTAssertEqual(($0 as? HarnessError)?.message, Errors.make("menu_fills_on_open", ["title": ""]).message)
        }
        XCTAssertEqual(finished.wait(timeout: .now()), .timedOut)
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(caller.performed.map { $0.1 }, ["AXPress", "AXCancel"])
        XCTAssertTrue(fallback.performed.isEmpty)
    }
}
