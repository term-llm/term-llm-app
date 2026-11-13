import AppKit
import ComputerUseCore
import XCTest
import os
@testable import ComputerUseSystem

final class WindowsTests: ContextTestCase {
    var windows: Windows!; var a: ContextElement!; var b: ContextElement!; var root: ContextElement!
    override func setUp() {
        super.setUp(); windows = Windows(system: windowSystem()); a = ContextElement(attrs: ["AXTitle": "First"]); b = ContextElement(id: 8, attrs: ["AXTitle": "Last"])
        root = ax.el(ax.app(pid: 77)); root.attrs["AXWindows"] = [a.ref, b.ref]
    }
    private func configureWindows(_ configure: (inout Windows.System) -> Void) {
        var system = windows.system; configure(&system); windows = Windows(system: system)
    }
    func testKeyChoiceFocusedMainLast() throws {
        XCTAssertEqual(try windows.keyWindow(target).windowID, 8)
        root.attrs["AXMainWindow"] = a.ref; XCTAssertEqual(try windows.keyWindow(target).windowID, 7)
        root.attrs["AXFocusedWindow"] = b.ref; XCTAssertEqual(try windows.keyWindow(target).windowID, 8)
        XCTAssertEqual(Windows.keyWindowAttributes, ["AXFocusedWindow", "AXMainWindow", "AXWindows"])
    }
    func testDesktopOnlyWhenNoRealWindow() throws {
        a.attrs["AXSubrole"] = Windows.desktop; root.attrs["AXFocusedWindow"] = a.ref
        XCTAssertEqual(try windows.keyWindow(target).windowID, 8)
        root.attrs["AXWindows"] = [a.ref]; XCTAssertEqual(try windows.keyWindow(target).windowID, 7)
    }
    func testMissingWindowAndNotRunning() {
        root.attrs = [:]; assertHarnessError(Errors.make("no_windows").message) { _ = try self.windows.keyWindow(self.target) }
        var off = target; off.pid = nil
        assertHarnessError(name: "app_not_running") { _ = try self.windows.keyWindow(off) }
    }
    func testTitleFromServerAndLiveFrame() throws {
        configureWindows { $0.rows = { _, _ in [.init(id: 7, pid: 77, title: "Server", frame: .zero)] } }
        XCTAssertEqual(try windows.windowRef(a.ref).title, "Server")
        a.rect = CGRect(x: -500.5, y: -99, width: 42, height: 23)
        XCTAssertEqual(try windows.windowRef(a.ref).frame, a.rect)
        XCTAssertTrue(ax.sets.isEmpty && ax.performed.isEmpty)
    }
    func testMatchingBoundsThenTitle() throws {
        a.id = 0
        let a = a!
        configureWindows { $0.rows = { _, _ in [.init(id: 11, pid: 77, title: "Other", frame: a.rect!), .init(id: 12, pid: 77, title: "First", frame: a.rect!)] } }
        XCTAssertEqual(try windows.windowRef(a.ref).windowID, 12)
        a.attrs["AXTitle"] = "Unknown"; XCTAssertEqual(try windows.windowRef(a.ref).windowID, 11)
    }
    func testServerOptionsAndMinimisedFallback() {
        let calls = ContextBox([(UInt32, UInt32)]())
        configureWindows { $0.rows = { option, id in calls.withValue { $0.append((option, id)) }; return option == 0 ? [.init(id: 7, pid: 77, frame: .zero)] : [] } }
        XCTAssertNotNil(windows.serverWindow(7)); XCTAssertEqual(calls.value.map { $0.0 }, [8, 0]); XCTAssertEqual(calls.value.map { $0.1 }, [7, 0])
        _ = windows.serverWindows(pid: 77); XCTAssertEqual(calls.value.last?.0, 17)
    }
    func testServerFilterAndExtrasBackToFront() {
        let rows = [Windows.Row(id: 9, pid: 77, frame: .zero), .init(id: 8, pid: 77, frame: .zero), .init(id: 7, pid: 77, frame: .zero), .init(id: 6, pid: 88, frame: .zero)]
        configureWindows { $0.rows = { _, _ in rows } }; configureWindows { $0.associated = { id in id == 8 || id == 9 ? [7] : [] } }
        XCTAssertEqual(windows.serverWindows(pid: 77).map(\.id), [9, 8, 7])
        XCTAssertEqual(windows.extraWindows(target: target, windowID: 7).map(\.id), [8, 9])
        XCTAssertTrue(windows.extraWindows(target: target, windowID: 9).isEmpty)
        XCTAssertTrue(windows.extraWindows(target: target, windowID: 999).isEmpty)
    }
    func testOrderedAndPointFirstWinsSignedHalfOpen() throws {
        XCTAssertEqual(try windows.ordered(target).map(\.windowID), [7, 8])
        XCTAssertEqual(try windows.at(target, point: CGPoint(x: -99.5, y: 50)).windowID, 7)
        XCTAssertThrowsError(try windows.at(target, point: CGPoint(x: 100, y: 50)))
        root.attrs["AXWindows"] = []; XCTAssertThrowsError(try windows.at(target, point: .zero))
    }
    func testOwnWindowKeepsAXFrame() throws {
        configureWindows { $0.rows = { _, _ in [.init(id: 7, pid: 77, frame: .zero)] } }
        let field = ContextElement("AXTextField", attrs: ["AXWindow": a.ref])
        let found = try windows.ref(field.ref)
        XCTAssertEqual(found.frame, a.rect); XCTAssertTrue(AX.same(found.element, a.ref))
        XCTAssertFalse(ax.gets.contains { $0.1 == "AXParent" })
    }
    func testForeignProcessClimbsToHostOrOwnWindow() throws {
        configureWindows { $0.rows = { _, _ in [.init(id: 7, pid: 77, frame: .zero), .init(id: 9, pid: 99, frame: .zero)] } }
        let foreign = ContextElement("AXWebArea", pid: 99, attrs: ["AXWindow": a.ref, "AXParent": a.ref])
        XCTAssertEqual(try windows.ref(foreign.ref).pid, 77)
        foreign.id = 9; XCTAssertEqual(try windows.ref(foreign.ref).pid, 99)
        root.attrs["AXWindows"] = [a.ref]; ax.hit = foreign.ref
        XCTAssertEqual(try windows.at(target, point: .init(x: 0, y: 80)).pid, 99)
    }
    func testClimbAtMost300Parents() throws {
        configureWindows { $0.rows = { _, _ in [.init(id: 7, pid: 77, frame: .zero)] } }
        for depth in [300, 301] {
            var node = a!
            for _ in 0..<depth { node = ContextElement("AXGroup", id: 0, attrs: ["AXParent": node.ref]) }
            if depth == 300 { XCTAssertEqual(try windows.ref(node.ref).windowID, 7) }
            else { XCTAssertThrowsError(try windows.ref(node.ref)) }
        }
    }
    func testObserverMenuOpenCloseAndSubmenu() throws {
        try windows.watch(target)
        let title = ContextElement("AXMenuBarItem"), menu = ContextElement("AXMenu")
        menu.attrs["AXParent"] = title.ref
        let o = ax.observations[0]; o.fire(Windows.menuOpened, menu.ref)
        XCTAssertTrue(AX.same(try windows.openMenu(target), title.ref))
        let item = ContextElement("AXMenuItem"), sub = ContextElement("AXMenu", attrs: ["AXParent": item.ref])
        o.fire(Windows.menuOpened, sub.ref); XCTAssertTrue(AX.same(try windows.shownMenu(target), title.ref))
        o.fire(Windows.menuClosed, sub.ref); XCTAssertNotNil(try windows.shownMenu(target))
        o.fire(Windows.menuClosed, menu.ref); XCTAssertNil(try windows.shownMenu(target))
    }
    func testPopupShownAttributeOrChildrenStaysInsideWindow() throws {
        for role in Windows.menuButtons {
            let opener = ContextElement(role), menu = ContextElement("AXMenu", attrs: ["AXParent": opener.ref])
            opener.attrs["AXChildren"] = [menu.ref]
            XCTAssertTrue(AX.same(try windows.waitForMenu(target, opener: opener.ref), menu.ref))
            XCTAssertNil(try windows.openMenu(target)); windows.closeMenu(target)
            opener.attrs["AXChildren"] = nil; opener.attrs["AXShownMenuUIElement"] = menu.ref
            XCTAssertNotNil(try windows.waitForMenu(target, opener: opener.ref)); windows.closeMenu(target)
        }
    }
    func testMenuBarSelectedAndTimeout() throws {
        let title = ContextElement("AXMenuBarItem", attrs: ["AXChildren": [ContextElement("AXMenu").ref]])
        XCTAssertNil(try windows.waitForMenu(target, opener: title.ref)); XCTAssertEqual(clock.time, 1000.25, accuracy: 0.02)
        title.attrs["AXSelected"] = true; XCTAssertTrue(AX.same(try windows.waitForMenu(target, opener: title.ref), title.ref))
    }
    func testKeptMenuIgnoresFillingButAnotherMenuTakesOver() throws {
        try windows.watch(target)
        let title = ContextElement("AXMenuBarItem"), menu = ContextElement("AXMenu", attrs: ["AXParent": title.ref])
        windows.keepMenu(target, title: title.ref)
        ax.observations[0].fire(Windows.menuClosed, menu.ref); ax.observations[0].fire(Windows.menuOpened, menu.ref)
        XCTAssertTrue(AX.same(try windows.openMenu(target), title.ref))
        let other = ContextElement("AXMenuBarItem"), otherMenu = ContextElement("AXMenu", attrs: ["AXParent": other.ref])
        ax.observations[0].fire(Windows.menuOpened, otherMenu.ref); XCTAssertTrue(AX.same(try windows.openMenu(target), other.ref))
    }
    func testDeadAndLateMenuForgottenAndSeparateApps() throws {
        try windows.watch(target)
        let title = ContextElement("AXMenuBarItem"), menu = ContextElement("AXMenu", attrs: ["AXParent": title.ref])
        ax.observations[0].fire(Windows.menuOpened, menu.ref); windows.closeMenu(target); XCTAssertNil(try windows.openMenu(target))
        windows.keepMenu(target, title: title.ref); title.alive = false; XCTAssertNil(try windows.openMenu(target))
        title.alive = true; windows.keepMenu(target, title: title.ref)
        var other = target; other.pid = 99; XCTAssertNil(try windows.openMenu(other))
    }
    func testWatchCountNewWindowAttentionAndUnwind() throws {
        let attention = OSAllocatedUnfairLock(initialState: [pid_t]()), heard = DispatchSemaphore(value: 0)
        configureWindows { $0.noAttention = { pid in attention.withLock { $0.append(pid) }; heard.signal() } }
        try windows.watch(target); try windows.watch(target); XCTAssertEqual(ax.observations.count, 1)
        for name in Windows.newWindows { ax.observations[0].fire(name, a.ref) }
        XCTAssertEqual(heard.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(heard.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(attention.withLock { $0 }, [77, 77]); windows.unwatch(target); XCTAssertFalse(ax.observations[0].stopped)
        windows.unwatch(target); XCTAssertTrue(ax.observations[0].stopped); windows.unwatch(target)
        ax.failObserve = true; XCTAssertThrowsError(try windows.watch(target)); ax.failObserve = false
        try windows.watch(target); XCTAssertEqual(ax.observations.count, 2)
    }
}

/// Pure watch/menu ownership regressions. Every system dependency is fail-fast
/// unless explicitly replaced. Observer hooks are synchronized fake callbacks.
final class WindowsOwnershipTests: XCTestCase {
    private let target = AppTarget(path: "/Fixture/Test.app", bundleID: "test", name: "Test", pid: 77)

    func testConcurrentWatchReferenceCountingAndLateClaimedDelivery() throws {
        let backend = ContextAX(), windows = Windows(system: isolatedWindowsSystem()), target = target
        DispatchQueue.concurrentPerform(iterations: 50) { _ in
            do { try AX.withBackend(backend) { try windows.watch(target) } } catch { XCTFail("Unexpected watch failure: \(error)") }
        }
        XCTAssertEqual(backend.observations.count, 1)
        let old = backend.observations[0]
        DispatchQueue.concurrentPerform(iterations: 50) { _ in windows.unwatch(target) }
        XCTAssertTrue(old.stopped)
        try AX.withBackend(backend) { try windows.watch(target) }
        let title = ContextElement("AXMenuBarItem"), menu = ContextElement("AXMenu", attrs: [:])
        menu.set("AXParent", title.ref)
        old.fireClaimed(Windows.menuOpened, menu.ref)
        try AX.withBackend(backend) { XCTAssertNil(try windows.shownMenu(target)) }
        backend.observations[1].fire(Windows.menuOpened, menu.ref)
        try AX.withBackend(backend) { XCTAssertTrue(AX.same(try windows.shownMenu(target), title.ref)) }
        windows.unwatch(target)
    }

    func testObserveCanReenterTeardownAndRewatchWithoutPublishingOldObserver() throws {
        let backend = ContextAX(), windows = Windows(system: isolatedWindowsSystem()), target = target
        let first = ContextBox(true)
        backend.onObserve = { _ in
            if first.withValue({ first in let result = first; first = false; return result }) {
                windows.unwatch(target)
                try windows.watch(target)
            }
        }
        try AX.withBackend(backend) { try windows.watch(target) }
        XCTAssertEqual(backend.observations.count, 2)
        XCTAssertTrue(backend.observations[0].stopped)
        XCTAssertFalse(backend.observations[1].stopped)
        windows.unwatch(target)
        XCTAssertTrue(backend.observations[1].stopped)
        backend.onObserve = nil
    }

    func testStopCanReenterWatchWithoutRegistryOrExecutionLock() throws {
        let backend = ContextAX(), windows = Windows(system: isolatedWindowsSystem()), target = target
        try AX.withBackend(backend) { try windows.watch(target) }
        backend.observations[0].onStop = {
            do { try AX.withBackend(backend) { try windows.watch(target) } } catch { XCTFail("Unexpected watch failure: \(error)") }
        }
        windows.unwatch(target)
        XCTAssertEqual(backend.observations.count, 2)
        XCTAssertFalse(backend.observations[1].stopped)
        windows.unwatch(target)
        XCTAssertTrue(backend.observations[1].stopped)
        backend.observations[0].onStop = nil
    }

    func testPendingObserveDoesNotBlockMainTeardownOrNewGeneration() throws {
        let backend = ContextAX(), windows = Windows(system: isolatedWindowsSystem()), target = target
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        let first = ContextBox(true)
        backend.onObserve = { _ in
            if first.withValue({ first in let result = first; first = false; return result }) {
                entered.signal()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            }
        }
        DispatchQueue.global().async {
            do { try AX.withBackend(backend) { try windows.watch(target) } } catch { XCTFail("Unexpected watch failure: \(error)") }
            finished.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        try AX.withBackend(backend) { try windows.watch(target) } // Joins without blocking callback/main delivery.
        windows.unwatch(target); windows.unwatch(target)
        try AX.withBackend(backend) { try windows.watch(target) }
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(backend.observations.count, 2)
        XCTAssertTrue(backend.observations[0].stopped)
        XCTAssertFalse(backend.observations[1].stopped)
        backend.observations[0].fireClaimed(Windows.menuOpened, ContextElement("AXMenu").ref)
        try AX.withBackend(backend) { XCTAssertNil(try windows.shownMenu(target)) }
        windows.unwatch(target)
    }

    func testFailedRegistrationRetiresRecorderAndRetryWorks() throws {
        let backend = ContextAX(), windows = Windows(system: isolatedWindowsSystem()), target = target
        backend.onObserve = { _ in throw Errors.make("no_windows") }
        XCTAssertThrowsError(try AX.withBackend(backend) { try windows.watch(target) })
        backend.onObserve = nil
        try AX.withBackend(backend) { try windows.watch(target) }
        backend.observations[0].fireClaimed(Windows.menuOpened, ContextElement("AXMenu").ref)
        try AX.withBackend(backend) { XCTAssertNil(try windows.shownMenu(target)) }
        windows.unwatch(target)
        XCTAssertTrue(backend.observations[1].stopped)
    }

    func testMenuAXReadDoesNotBlockCallbacksOrAnotherPID() throws {
        let backend = ContextAX(), windows = Windows(system: isolatedWindowsSystem()), target = target
        try AX.withBackend(backend) { try windows.watch(target) }
        let title = ContextElement("AXMenuBarItem"), menu = ContextElement("AXMenu", attrs: ["AXParent": title.ref])
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        backend.onGet = { element, name in
            if AX.same(element, menu.ref), name == "AXParent" {
                entered.signal(); XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            }
            return (element.object as! ContextElement).attrs[name]
        }
        backend.observations[0].fire(Windows.menuOpened, menu.ref)
        DispatchQueue.global().async {
            do { _ = try AX.withBackend(backend) { try windows.shownMenu(target) } } catch { XCTFail("Unexpected menu failure: \(error)") }
            finished.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        // These calls execute before releasing the blocked target AX read.
        backend.observations[0].fire(Windows.menuClosed, menu.ref)
        var other = target; other.pid = 99
        windows.keepMenu(other, title: title.ref)
        try AX.withBackend(backend) { XCTAssertTrue(AX.same(try windows.shownMenu(other), title.ref)) }
        XCTAssertEqual(finished.wait(timeout: .now() + 0.05), .timedOut)
        release.signal(); XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        try AX.withBackend(backend) { XCTAssertNil(try windows.shownMenu(target)) }
        windows.unwatch(target)
    }

    func testReentrantCloseInvalidatesInFlightMenuSample() throws {
        let backend = ContextAX(), windows = Windows(system: isolatedWindowsSystem()), target = target
        try AX.withBackend(backend) { try windows.watch(target) }
        let title = ContextElement("AXMenuBarItem"), menu = ContextElement("AXMenu", attrs: ["AXParent": title.ref])
        backend.onGet = { element, name in
            if AX.same(element, menu.ref), name == "AXParent" { windows.closeMenu(target) }
            return (element.object as! ContextElement).attrs[name]
        }
        backend.observations[0].fire(Windows.menuOpened, menu.ref)
        try AX.withBackend(backend) { XCTAssertNil(try windows.shownMenu(target)) }
        backend.onGet = nil
        try AX.withBackend(backend) { XCTAssertNil(try windows.shownMenu(target)) }
        windows.unwatch(target)
    }

    func testNotificationOnlyRecordsAndWorkerAttentionCallbackCanReenter() throws {
        let backend = ContextAX(), owner = ContextBox<Windows?>(nil), calls = ContextBox([pid_t]()), target = target
        var system = isolatedWindowsSystem()
        let heard = DispatchSemaphore(value: 0)
        system.noAttention = { pid in
            XCTAssertFalse(Thread.isMainThread, "Observer delivery must not execute the attention dependency")
            XCTAssertTrue(AX.backend === backend, "Attention work must retain the watch caller's backend across GCD")
            calls.withValue { $0.append(pid) }; owner.value?.closeMenu(target); heard.signal()
        }
        let windows = Windows(system: system); owner.value = windows
        // Create menu state in a different scope before watch: capture belongs to
        // the registration, not whichever operation first allocated the state.
        windows.keepMenu(target, title: ContextElement("AXMenuBarItem").ref)
        try AX.withBackend(backend) { try windows.watch(target) }
        backend.observations[0].fire(Windows.newWindows[0], ContextElement().ref)
        XCTAssertEqual(heard.wait(timeout: .now() + 2), .success)
        try AX.withBackend(backend) { XCTAssertNil(try windows.shownMenu(target)) }
        XCTAssertEqual(calls.value, [77])
        windows.unwatch(target); owner.value = nil
    }
}

extension WindowsOwnershipTests {
    func testFailedPendingRegistrationPreservesSuccessfulJoinerReferenceCount() throws {
        let backend = ContextAX(), windows = Windows(system: isolatedWindowsSystem()), target = target
        let first = ContextBox(true)
        backend.onObserve = { _ in
            if first.withValue({ value in let result = value; value = false; return result }) {
                try windows.watch(target) // A successful, nonblocking join.
                throw Errors.make("no_windows")
            }
        }
        XCTAssertThrowsError(try AX.withBackend(backend) { try windows.watch(target) })
        try AX.withBackend(backend) { try windows.watch(target) }
        XCTAssertEqual(backend.observations.count, 2)
        backend.observations[0].fireClaimed(Windows.menuOpened, ContextElement("AXMenu").ref)
        try AX.withBackend(backend) { XCTAssertNil(try windows.shownMenu(target)) }
        windows.unwatch(target) // Original successful join is still counted.
        XCTAssertFalse(backend.observations[1].stopped)
        windows.unwatch(target)
        XCTAssertTrue(backend.observations[1].stopped)
        backend.onObserve = nil
    }

    func testRegistrationAndMenuReadsStayOnTheirCallingWorker() {
        let backend = ContextAX(), windows = Windows(system: isolatedWindowsSystem()), target = target
        let title = ContextElement("AXMenuBarItem"), menu = ContextElement("AXMenu", attrs: ["AXParent": title.ref])
        let finished = DispatchSemaphore(value: 0)
        backend.onObserve = { _ in XCTAssertFalse(Thread.isMainThread) }
        backend.onGet = { element, name in
            XCTAssertFalse(Thread.isMainThread)
            return (element.object as! ContextElement).attrs[name]
        }
        DispatchQueue.global().async {
            do {
                try AX.withBackend(backend) {
                    try windows.watch(target)
                    backend.observations[0].fire(Windows.menuOpened, menu.ref)
                    XCTAssertTrue(AX.same(try windows.shownMenu(target), title.ref))
                    windows.unwatch(target)
                }
            } catch { XCTFail("Unexpected watch/menu failure: \(error)") }
            finished.signal()
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
    }
}

extension WindowsOwnershipTests {
    func testAdapterDeinitStopsObserverAndRetiresClaimedNotifications() throws {
        let backend = ContextAX()
        let observation: ContextObservation
        do {
            let windows = Windows(system: isolatedWindowsSystem())
            try AX.withBackend(backend) { try windows.watch(target) }
            observation = backend.observations[0]
        }
        XCTAssertTrue(observation.stopped)
        // Would trigger the fail-fast attention fake if the recorder were live.
        observation.fireClaimed(Windows.newWindows[0], ContextElement().ref)
        XCTAssertEqual(backend.observations.count, 1)
    }
}

extension WindowsOwnershipTests {
    func testMenuReadFailureCannotConsumePendingAttentionWork() throws {
        let backend = ContextAX(), calls = ContextBox(0)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        var system = isolatedWindowsSystem()
        system.noAttention = { _ in
            XCTAssertFalse(Thread.isMainThread)
            let call = calls.withValue { $0 += 1; return $0 }
            if call == 1 {
                entered.signal(); XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            }
            finished.signal()
        }
        let windows = Windows(system: system)
        try AX.withBackend(backend) { try windows.watch(target) }
        let observation = backend.observations[0], menu = ContextElement("AXMenu")
        observation.fire(Windows.newWindows[0], menu.ref)
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        observation.fire(Windows.menuOpened, menu.ref)
        observation.fire(Windows.newWindows[1], menu.ref)
        backend.failGet = ["AXParent"]
        XCTAssertThrowsError(try AX.withBackend(backend) { try windows.shownMenu(target) })
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(calls.value, 2)
        windows.unwatch(target)
    }
}

extension WindowsOwnershipTests {
    private func assertQueuedAttentionSurvivesTeardown(deinitialize: Bool) throws {
        let backend = ContextAX(), calls = ContextBox(0)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        var system = isolatedWindowsSystem()
        system.noAttention = { _ in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertTrue(AX.backend === backend, "Teardown flush must retain the watch's captured backend")
            let call = calls.withValue { $0 += 1; return $0 }
            if call == 1 {
                entered.signal(); XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            }
            finished.signal()
        }
        var windows: Windows? = Windows(system: system)
        try AX.withBackend(backend) { try windows!.watch(target) }
        let observation = backend.observations[0], element = ContextElement().ref
        observation.fire(Windows.newWindows[0], element)
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        observation.fire(Windows.newWindows[1], element) // Pending behind the blocked source handler.
        if deinitialize { windows = nil } else { windows!.unwatch(target) }
        XCTAssertTrue(observation.stopped)
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success, "Retirement cannot discard a delivered attention notification")
        XCTAssertEqual(calls.value, 2)
    }

    func testUnwatchFlushesQueuedAttentionWhileFirstHandlerIsBlocked() throws {
        try assertQueuedAttentionSurvivesTeardown(deinitialize: false)
    }

    func testDeinitFlushesQueuedAttentionWhileFirstHandlerIsBlocked() throws {
        try assertQueuedAttentionSurvivesTeardown(deinitialize: true)
    }

    func testAttentionDeliveredDuringObserverStopSurvivesMenuRetirement() throws {
        let backend = ContextAX(), called = DispatchSemaphore(value: 0), calls = ContextBox(0)
        var system = isolatedWindowsSystem()
        system.noAttention = { _ in
            XCTAssertFalse(Thread.isMainThread); XCTAssertTrue(AX.backend === backend)
            calls.withValue { $0 += 1 }; called.signal()
        }
        let windows = Windows(system: system)
        try AX.withBackend(backend) { try windows.watch(target) }
        let observation = backend.observations[0], element = ContextElement().ref
        observation.onStop = { observation.fireClaimed(Windows.newWindows[0], element) }
        windows.unwatch(target)
        XCTAssertEqual(called.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(calls.value, 1)
        observation.onStop = nil
    }

    func testAttentionDeliveredDuringRetiredPendingObserveIsFlushed() throws {
        let backend = ContextAX(), called = DispatchSemaphore(value: 0), calls = ContextBox(0), target = target
        var system = isolatedWindowsSystem()
        system.noAttention = { _ in
            XCTAssertFalse(Thread.isMainThread); XCTAssertTrue(AX.backend === backend)
            calls.withValue { $0 += 1 }; called.signal()
        }
        let windows = Windows(system: system)
        backend.onObserve = { observation in
            windows.unwatch(target) // Retired, but the observer has not returned for stop yet.
            observation.fireClaimed(Windows.newWindows[0], ContextElement().ref)
        }
        try AX.withBackend(backend) { try windows.watch(target) }
        XCTAssertTrue(backend.observations[0].stopped)
        XCTAssertEqual(called.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(calls.value, 1)
        backend.onObserve = nil
    }

    func testMenuWaitFollowsReentrantUnwatchRewatchGeneration() throws {
        let backend = ContextAX(), clock = ContextClock(), target = target, first = ContextBox(true)
        var system = isolatedWindowsSystem(); system.now = clock.now; system.sleep = { clock.sleep($0) }
        let windows = Windows(system: system)
        let opener = ContextElement("AXPopUpButton"), menu = ContextElement("AXMenu", attrs: ["AXParent": opener.ref])
        try AX.withBackend(backend) { try windows.watch(target) }
        backend.onGet = { element, name in
            if AX.same(element, opener.ref), name == "AXShownMenuUIElement",
               first.withValue({ value in let result = value; value = false; return result }) {
                windows.unwatch(target)
                try windows.watch(target)
                opener.set("AXShownMenuUIElement", menu.ref)
            }
            return (element.object as! ContextElement).attrs[name]
        }
        try AX.withBackend(backend) { XCTAssertTrue(AX.same(try windows.waitForMenu(target, opener: opener.ref), menu.ref)) }
        XCTAssertEqual(backend.observations.count, 2)
        XCTAssertTrue(backend.observations[0].stopped)
        XCTAssertFalse(backend.observations[1].stopped)
        XCTAssertEqual(clock.sleeps, [Windows.menuPoll])
        backend.onGet = nil; windows.unwatch(target)
    }
}

extension WindowsOwnershipTests {
    func testRetiredFailingObserveStillFlushesDeliveredAttention() {
        let backend = ContextAX(), called = DispatchSemaphore(value: 0), calls = ContextBox(0), target = target
        var system = isolatedWindowsSystem()
        system.noAttention = { _ in
            XCTAssertFalse(Thread.isMainThread); XCTAssertTrue(AX.backend === backend)
            calls.withValue { $0 += 1 }; called.signal()
        }
        let windows = Windows(system: system)
        backend.onObserve = { observation in
            windows.unwatch(target)
            observation.fireClaimed(Windows.newWindows[0], ContextElement().ref)
            throw Errors.make("no_windows")
        }
        XCTAssertThrowsError(try AX.withBackend(backend) { try windows.watch(target) })
        XCTAssertEqual(called.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(calls.value, 1)
        backend.observations[0].fireClaimed(Windows.newWindows[1], ContextElement().ref)
        XCTAssertEqual(called.wait(timeout: .now() + 0.05), .timedOut, "Failed creation must also close its attention acceptance")
        backend.onObserve = nil
    }
}
