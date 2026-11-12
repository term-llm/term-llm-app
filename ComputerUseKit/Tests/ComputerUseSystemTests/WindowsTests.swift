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
        windows.system.rows = { _, _ in [.init(id: 7, pid: 77, title: "Server", frame: .zero)] }
        XCTAssertEqual(try windows.windowRef(a.ref).title, "Server")
        a.rect = CGRect(x: -500.5, y: -99, width: 42, height: 23)
        XCTAssertEqual(try windows.windowRef(a.ref).frame, a.rect)
        XCTAssertTrue(ax.sets.isEmpty && ax.performed.isEmpty)
    }
    func testMatchingBoundsThenTitle() throws {
        a.id = 0
        windows.system.rows = { _, _ in [.init(id: 11, pid: 77, title: "Other", frame: self.a.rect!), .init(id: 12, pid: 77, title: "First", frame: self.a.rect!)] }
        XCTAssertEqual(try windows.windowRef(a.ref).windowID, 12)
        a.attrs["AXTitle"] = "Unknown"; XCTAssertEqual(try windows.windowRef(a.ref).windowID, 11)
    }
    func testServerOptionsAndMinimisedFallback() {
        var calls: [(UInt32, UInt32)] = []
        windows.system.rows = { option, id in calls.append((option, id)); return option == 0 ? [.init(id: 7, pid: 77, frame: .zero)] : [] }
        XCTAssertNotNil(windows.serverWindow(7)); XCTAssertEqual(calls.map { $0.0 }, [8, 0]); XCTAssertEqual(calls.map { $0.1 }, [7, 0])
        _ = windows.serverWindows(pid: 77); XCTAssertEqual(calls.last?.0, 17)
    }
    func testServerFilterAndExtrasBackToFront() {
        let rows = [Windows.Row(id: 9, pid: 77, frame: .zero), .init(id: 8, pid: 77, frame: .zero), .init(id: 7, pid: 77, frame: .zero), .init(id: 6, pid: 88, frame: .zero)]
        windows.system.rows = { _, _ in rows }; windows.system.associated = { id in id == 8 || id == 9 ? [7] : [] }
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
        windows.system.rows = { _, _ in [.init(id: 7, pid: 77, frame: .zero)] }
        let field = ContextElement("AXTextField", attrs: ["AXWindow": a.ref])
        let found = try windows.ref(field.ref)
        XCTAssertEqual(found.frame, a.rect); XCTAssertTrue(AX.same(found.element, a.ref))
        XCTAssertFalse(ax.gets.contains { $0.1 == "AXParent" })
    }
    func testForeignProcessClimbsToHostOrOwnWindow() throws {
        windows.system.rows = { _, _ in [.init(id: 7, pid: 77, frame: .zero), .init(id: 9, pid: 99, frame: .zero)] }
        let foreign = ContextElement("AXWebArea", pid: 99, attrs: ["AXWindow": a.ref, "AXParent": a.ref])
        XCTAssertEqual(try windows.ref(foreign.ref).pid, 77)
        foreign.id = 9; XCTAssertEqual(try windows.ref(foreign.ref).pid, 99)
        root.attrs["AXWindows"] = [a.ref]; ax.hit = foreign.ref
        XCTAssertEqual(try windows.at(target, point: .init(x: 0, y: 80)).pid, 99)
    }
    func testClimbAtMost300Parents() throws {
        windows.system.rows = { _, _ in [.init(id: 7, pid: 77, frame: .zero)] }
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
        let attention = OSAllocatedUnfairLock(initialState: [pid_t]()); windows.system.noAttention = { pid in attention.withLock { $0.append(pid) } }
        try windows.watch(target); try windows.watch(target); XCTAssertEqual(ax.observations.count, 1)
        for name in Windows.newWindows { ax.observations[0].fire(name, a.ref) }
        XCTAssertEqual(attention.withLock { $0 }, [77, 77]); windows.unwatch(target); XCTAssertFalse(ax.observations[0].stopped)
        windows.unwatch(target); XCTAssertTrue(ax.observations[0].stopped); windows.unwatch(target)
        ax.failObserve = true; XCTAssertThrowsError(try windows.watch(target)); ax.failObserve = false
        try windows.watch(target); XCTAssertEqual(ax.observations.count, 2)
    }
}
