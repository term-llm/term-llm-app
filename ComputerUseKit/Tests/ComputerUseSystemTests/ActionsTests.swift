import AppKit
import ComputerUseCore
import XCTest
import os

@testable import ComputerUseSystem

/// Logic tests of actions.py. Every AX read, window, clock, event sink and
/// activation is fake: constructing a CGEvent does not post it.
final class ActionsTests: ContextTestCase {
    var actions: Actions!, app: AppSession!, window: ContextElement!, root: ContextElement!,
        field: ContextElement!
    var posted: [(pid_t, CGEvent, Double)] = [], overlay: [OverlayCommand] = [],
        activation: [CGEvent] = []
    var front: pid_t = 88, held: UInt64 = 0, kind = AppKind(), blocked = false
    override func setUp() {
        super.setUp()
        posted = []
        overlay = []
        activation = []
        front = 88
        held = 0
        kind = AppKind()
        blocked = false
        window = ContextElement(
            rect: CGRect(x: 0, y: 0, width: 500, height: 400),
            attrs: ["AXTitle": "Test", "AXMain": true])
        root = ax.el(ax.app(pid: 77))
        root.attrs["AXWindows"] = [window.ref]
        field = ContextElement(
            "AXButton", id: 0, rect: CGRect(x: 20, y: 20, width: 60, height: 30),
            attrs: ["AXWindow": window.ref, "AXParent": window.ref])
        ax.hit = field.ref
        var apps = Apps.System()
        apps.info = { _ in [:] }
        apps.panelServices = { [:] }
        apps.processBundleID = { _ in "dev.other" }
        var focus = Focus.System()
        focus.frontPID = { self.front }
        focus.noAttention = { _ in }
        focus.personWent = { _, _ in false }
        focus.freeze = {}
        focus.thaw = {}
        focus.now = { self.clock.time }
        focus.sleep = { self.clock.sleep($0) }
        focus.background = { _ in }
        focus.post = { _, event in
            self.activation.append(event)
            self.root.attrs["AXFrontmost"] = true
        }
        var system = Actions.System()
        system.apps = Apps(system: apps)
        system.windows = Windows(system: windowSystem())
        system.windows.system.rows = { _, _ in
            [.init(id: self.window.id, pid: 77, frame: self.window.rect!)]
        }
        system.focus = Focus(system: focus)
        system.presence = Presence(
            enabled: { true }, now: { self.clock.time }, send: { self.overlay.append($0) },
            schedule: { $0() }, ask: { _ in }, withdraw: { _ in })
        system.post = { self.posted.append(($0, $1, $2)) }
        system.heldFlags = { self.held }
        system.now = { self.clock.time }
        system.sleep = { self.clock.sleep($0) }
        system.background = { $0() }
        system.checkRecipient = { _ in if self.blocked { throw Errors.make("forbidden") } }
        system.focusElement = { _ in true }
        system.presses = { $0.unicodeScalars.map { Keys.KeyPress(0, 0, String($0)) } }
        actions = Actions(system: system)
        app = AppSession(agent: AgentSession(key: "test"), target: target)
    }
    func line(_ role: String = "AXButton", actions: [(label: String, action: String)] = []) -> Line
    {
        field.attrs["AXRole"] = role
        return Line(
            depth: 0, text: "button", element: field.ref, role: role, name: "OK", actions: actions,
            id: 1)
    }
    var types: [UInt32] { posted.map { $0.1.type.rawValue } }
    func testAXFirstAndRefusalFallsBackButTimeoutNeverRepeats() throws {
        ax.offered = ["AXPress"]
        try actions.click(app, .line(line()))
        XCTAssertEqual(ax.performed.map { $0.1 }, ["AXPress"])
        XCTAssertTrue(posted.isEmpty)
        ax.onPerform = { _, _ in throw Errors.make("not_settable") }
        try actions.click(app, .line(line()))
        XCTAssertEqual(types, [1, 2])
        posted = []
        ax.onPerform = { _, _ in throw AX.failure(AX.cannotComplete) }
        XCTAssertThrowsError(try actions.click(app, .line(line())))
        XCTAssertTrue(posted.isEmpty)
    }
    func testPickPreferredAndPressNeedsNoWindow() throws {
        ax.offered = ["AXPress", "AXPick"]
        field.attrs["AXWindow"] = nil
        field.attrs["AXParent"] = nil
        try actions.click(app, .line(line()))
        XCTAssertEqual(ax.performed.map { $0.1 }, ["AXPick"])
        XCTAssertTrue(posted.isEmpty)
    }
    func testWebOnlyTogglesUseAXAction() throws {
        ax.offered = ["AXPress"]
        let web = ContextElement("AXWebArea", attrs: ["AXParent": window.ref])
        field.attrs["AXParent"] = web.ref
        for role in [
            "AXButton", "AXLink", "AXTextField", "AXSlider", "AXCheckBox", "AXRadioButton",
        ] {
            posted = []
            ax.performed = []
            try actions.click(app, .line(line(role)))
            XCTAssertEqual(ax.performed.isEmpty, !Actions.webActionRoles.contains(role), role)
        }
    }
    func testNonPlainClicksAndEnvironmentForceEvents() throws {
        ax.offered = ["AXPress"]
        try actions.click(app, .line(line()), button: 1)
        try actions.click(app, .line(line()), count: 2)
        try actions.click(app, .line(line()), key: "shift")
        try actions.click(app, .line(line()), hold: 0)
        app.agent.env[Actions.alwaysSimulateClick] = "1"
        try actions.click(app, .line(line()))
        XCTAssertTrue(ax.performed.isEmpty)
        XCTAssertFalse(posted.isEmpty)
    }
    func testCommandClickInBackgroundPlainClickInFrontAndSelectionActivates() throws {
        try actions.click(app, .line(line("AXTextField")))
        XCTAssertEqual(posted[0].1.flags.rawValue, UInt64(Keys.command))
        XCTAssertTrue(activation.isEmpty)
        posted = []
        front = 77
        try actions.click(app, .line(line()))
        XCTAssertEqual(posted[0].1.flags.rawValue, 0)
        front = 88
        posted = []
        try actions.click(app, .line(line("AXRow")))
        XCTAssertFalse(activation.isEmpty)
        XCTAssertEqual(posted[0].1.flags.rawValue, 0)
    }
    func testPointRightClickHasLeadAndAppScopedHitTest() throws {
        try actions.click(app, .point(CGPoint(x: 30, y: 30)), button: 1)
        XCTAssertEqual(types, [5, 3, 4])
        XCTAssertEqual(posted.first?.2, Actions.moveLead)
        XCTAssertTrue(posted.allSatisfy { $0.0 == 77 })
        XCTAssertEqual(posted[1].1.location, CGPoint(x: 30, y: 30))
    }
    func testInvalidCountAndMinimizedOrMissingWindowIDPostNothing() {
        XCTAssertThrowsError(try actions.click(app, .line(line()), count: 0))
        window.attrs["AXMinimized"] = true
        XCTAssertThrowsError(try actions.click(app, .point(.init(x: 30, y: 30))))
        window.attrs["AXMinimized"] = false
        window.id = 0
        XCTAssertThrowsError(try actions.click(app, .point(.init(x: 30, y: 30))))
        XCTAssertTrue(posted.isEmpty)
    }
    func testHeldClickReleasesOnCancellationAndRestoresModifiers() throws {
        var cancelled = false
        app.cancel = { cancelled }
        held = UInt64(Keys.control)
        actions.system.post = { pid, event, delay in
            self.posted.append((pid, event, delay))
            if event.type == .leftMouseDown { cancelled = true }
        }
        XCTAssertThrowsError(try actions.click(app, .line(line()), key: "shift", hold: 20))
        XCTAssertEqual(types, [12, 1, 2, 12])
        XCTAssertEqual(posted.last?.1.flags.rawValue, held)
        XCTAssertLessThan(clock.time, 1001)
    }
    func testDoubleClickCountsAndGap() throws {
        front = 77
        try actions.click(app, .line(line()), count: 2)
        XCTAssertEqual(types, [1, 2, 1, 2])
        XCTAssertEqual(
            posted.map { $0.1.getIntegerValueField(.mouseEventClickState) }, [1, 1, 2, 2])
        XCTAssertEqual(
            clock.sleeps.reduce(0, +), 2 * Events.clickHold + Actions.clickGap, accuracy: 0.0001)
    }
    func testVisiblePartAndEveryScrollAncestorCut() throws {
        let outer = ContextElement(
            "AXScrollArea", rect: CGRect(x: 0, y: 0, width: 100, height: 100),
            attrs: ["AXParent": window.ref])
        let inner = ContextElement(
            "AXScrollArea", rect: CGRect(x: 50, y: 0, width: 100, height: 100),
            attrs: ["AXParent": outer.ref])
        field.attrs["AXParent"] = inner.ref
        field.rect = CGRect(x: 80, y: 20, width: 100, height: 20)
        XCTAssertEqual(
            try actions.visiblePart(field.ref, actions.system.windows.keyWindow(target)),
            CGRect(x: 80, y: 20, width: 20, height: 20))
        XCTAssertFalse(try actions.position(field.ref, actions.system.windows.keyWindow(target)))
        XCTAssertEqual(
            try actions.clickablePoint(field.ref, actions.system.windows.keyWindow(target)),
            CGPoint(x: 90, y: 30))
        field.rect = CGRect(x: 600, y: 0, width: 10, height: 10)
        XCTAssertThrowsError(
            try actions.clickablePoint(field.ref, actions.system.windows.keyWindow(target)))
    }
    func testScrollToVisibleAndScrollAreaHintsBeforeClick() throws {
        let area = ContextElement(
            "AXScrollArea", rect: CGRect(x: 0, y: 0, width: 500, height: 400),
            attrs: ["AXParent": window.ref])
        field.attrs["AXParent"] = area.ref
        field.rect = CGRect(x: 600, y: 0, width: 10, height: 10)
        ax.offered = ["AXScrollToVisible"]
        let names = OSAllocatedUnfairLock(initialState: [String]())
        ax.onParam = { [field = field!] _, name, _ in
            names.withLock { $0.append(name) }
            field.rect = CGRect(x: 30, y: 30, width: 10, height: 10)
            return nil
        }
        XCTAssertTrue(try actions.position(field.ref, actions.system.windows.keyWindow(target)))
        XCTAssertEqual(ax.performed.map { $0.1 }, ["AXScrollToVisible"])
        XCTAssertEqual(names.withLock { $0 }, ["AXScrollToShowDescendant"])
    }
    func testMenuTitleReadNeverPressedAndItemPicksAndEscapeCancels() throws {
        let menu = ContextElement(
            "AXMenu", attrs: ["AXChildren": [ContextElement("AXMenuItem").ref]])
        field.attrs["AXChildren"] = [menu.ref]
        try actions.click(app, .line(line("AXMenuBarItem")))
        XCTAssertTrue(ax.performed.isEmpty && posted.isEmpty)
        ax.offered = ["AXPress", "AXPick"]
        try actions.click(app, .line(line("AXMenuItem")))
        XCTAssertEqual(ax.performed.last?.1, "AXPick")
        actions.system.windows.keepMenu(target, title: field.ref)
        try actions.pressKey(app, "Escape")
        XCTAssertEqual(ax.performed.last?.1, "AXCancel")
        XCTAssertNil(try actions.system.windows.shownMenu(target))
    }
    func testMenuFillAndEmptyFailureAndNonPlainRefusal() throws {
        let menu = ContextElement("AXMenu")
        field.attrs["AXChildren"] = [menu.ref]
        ax.onPerform = { _, action in
            if action == "AXPress" { menu.attrs["AXChildren"] = [ContextElement("AXMenuItem").ref] }
        }
        try actions.click(app, .line(line("AXMenuBarItem")))
        XCTAssertEqual(ax.performed.map { $0.1 }, ["AXPress", "AXCancel"])
        ax.onPerform = nil
        menu.attrs["AXChildren"] = []
        actions.system.windows.closeMenu(target)
        XCTAssertThrowsError(try actions.click(app, .line(line("AXMenuBarItem")))) {
            XCTAssertTrue(String(describing: $0).contains("filled only"))
        }
        XCTAssertThrowsError(try actions.click(app, .line(line("AXMenuItem")), button: 1))
        XCTAssertTrue(posted.isEmpty)
    }
    func testUnreportedPopupMenuClosesAndIsNeverRetried() {
        let menu = ContextElement("AXMenu")
        field.attrs["AXChildren"] = [menu.ref]
        ax.offered = ["AXPress"]
        // waitForMenu normally sees a popup's children; AXMenuBarItem selected=false
        // exercises the unreported menu branch via an explicit secondary press.
        let l = line("AXMenuBarItem", actions: [("Open", "AXPress")])
        XCTAssertThrowsError(try actions.secondary(app, l, "Open"))
        XCTAssertEqual(ax.performed.map { $0.1 }, ["AXPress", "AXCancel"])
        XCTAssertTrue(posted.isEmpty)
    }
    func testWheelPagesAndPointUsesWindowExtent() throws {
        for (n, extent, expected) in [(0.005, 100.0, 1), (1.25, 200.0, 250), (1, 20.0, 100)] {
            XCTAssertEqual(Actions.pages(n, extent: extent), expected)
        }
        try actions.scroll(app, .point(CGPoint(x: 30, y: 30)), direction: "down", pages: 0.5)
        XCTAssertEqual(types, [5, 22])
        XCTAssertEqual(posted[1].1.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -200)
        XCTAssertEqual(posted.map { $0.2 }, [Actions.scrollLead, Actions.scrollRest])
        XCTAssertTrue(activation.isEmpty)
    }
    func testDragStepsCappedAndReleasesOnInterruption() throws {
        front = 77
        try actions.drag(app, start: .init(x: 30, y: 30), end: .init(x: 200, y: 30))
        XCTAssertEqual(types.first, 5)
        XCTAssertEqual(types[1], 1)
        XCTAssertEqual(types.last, 2)
        XCTAssertEqual(types.filter { $0 == 6 }.count, 10)
        posted = []
        try actions.drag(app, start: .init(x: 30, y: 30), end: .init(x: 20_000, y: 30))
        XCTAssertEqual(types.filter { $0 == 6 }.count, 61)
        posted = []
        var cancelled = false
        app.cancel = { cancelled }
        actions.system.post = { pid, event, delay in
            self.posted.append((pid, event, delay))
            if event.type == .leftMouseDragged { cancelled = true }
        }
        XCTAssertThrowsError(
            try actions.drag(app, start: .init(x: 30, y: 30), end: .init(x: 200, y: 30)))
        XCTAssertEqual(types.last, 2)
    }
    func testKeysModifierTransitionsAndLastHold() throws {
        front = 77
        try actions.pressKey(app, "super+a Return", hold: 0.25)
        XCTAssertEqual(types, [12, 10, 11, 12, 10, 11])
        XCTAssertEqual(clock.sleeps.reduce(0, +), 0.25, accuracy: 0.0001)
        posted = []
        held = UInt64(Keys.command)
        try actions.pressKey(app, "super+a")
        XCTAssertEqual(types, [10, 11])
    }
    func testTypingAppendsAndSlowerPhoneAndCancellationStopsAtCurrentKey() throws {
        front = 77
        field.attrs["AXValue"] = "before"
        root.attrs["AXFocusedUIElement"] = field.ref
        try actions.typeText(app, "ab")
        XCTAssertEqual(types, [10, 11, 10, 11])
        XCTAssertTrue(ax.sets.isEmpty)
        XCTAssertEqual(posted.map { $0.2 }, Array(repeating: Limits.typeDelay, count: 4))
        app.target.bundleID = "com.apple.ScreenContinuity"
        posted = []
        try actions.typeText(app, "x")
        XCTAssertEqual(posted.map { $0.2 }, [0.005, 0.005])
        posted = []
        var cancelled = false
        app.cancel = { cancelled }
        actions.system.post = { pid, event, delay in
            self.posted.append((pid, event, delay))
            cancelled = true
        }
        XCTAssertThrowsError(try actions.typeText(app, "abc"))
        XCTAssertEqual(types, [10, 11])
    }
    func testFocusedForeignRecipientIsPolicyCheckedForKeysAndAX() throws {
        front = 77
        field.pid = 99
        root.attrs["AXFocusedUIElement"] = field.ref
        blocked = true
        XCTAssertThrowsError(try actions.pressKey(app, "Return"))
        ax.offered = ["AXPress"]
        XCTAssertThrowsError(try actions.click(app, .line(line())))
        XCTAssertThrowsError(try actions.setValue(app, line(), "secret"))
        XCTAssertTrue(posted.isEmpty && ax.performed.isEmpty && ax.sets.isEmpty)
    }
    func testFilePanelKeysGoToService() throws {
        front = 77
        window.attrs["AXIdentifier"] = "save-panel"
        root.attrs["AXFocusedWindow"] = window.ref
        root.attrs["AXFocusedUIElement"] = field.ref
        actions.system.apps.system.panelServices = { [99: 77] }
        try actions.pressKey(app, "Return")
        XCTAssertTrue(posted.allSatisfy { $0.0 == 99 })
    }
    func testSaveNameRefusesPathsForTypingAndSetting() throws {
        root.attrs["AXFocusedUIElement"] = field.ref
        field.attrs["AXIdentifier"] = Actions.nameField
        XCTAssertThrowsError(try actions.typeText(app, "/tmp/name"))
        XCTAssertThrowsError(try actions.setValue(app, line("AXTextField"), "/tmp/name"))
        XCTAssertTrue(posted.isEmpty && ax.sets.isEmpty)
        XCTAssertThrowsError(try actions.typeText(app, ""))
    }
    func testValueFollowsCurrentTypeAndOnlyBrowserAddressSubmits() throws {
        XCTAssertEqual(Actions.like(2, "3") as? Int, 3)
        XCTAssertEqual(Actions.like(2, "3.5") as? Double, 3.5)
        XCTAssertEqual(Actions.like("2", "3") as? String, "3")
        XCTAssertEqual(Actions.like(2, "bad") as? String, "bad")
        front = 77
        field.attrs["AXValue"] = "before"
        field.attrs["AXFocused"] = true
        try actions.setValue(app, line("AXSearchField"), "new")
        XCTAssertTrue(posted.isEmpty)
        field.attrs["AXIdentifier"] = Actions.browserField
        try actions.setValue(app, line("AXTextField"), "url")
        XCTAssertEqual(types, [10, 11])
    }
    func testDocumentAlwaysClicksAndUnfocusedFieldFallsBackToClick() throws {
        front = 77
        field.attrs["AXFocused"] = true
        try actions.setValue(app, line("AXTextArea"), "new")
        XCTAssertEqual(types, [1, 2])
        posted = []
        field.attrs["AXFocused"] = false
        actions.system.focusElement = { _ in false }
        try actions.setValue(app, line("AXTextField"), "new")
        XCTAssertEqual(types, [1, 2])
        ax.unsettable.insert("AXValue")
        XCTAssertThrowsError(try actions.setValue(app, line(), "new"))
    }
    func testSelectionRangesPrefixSuffixAndCursorModes() throws {
        field.attrs["AXValue"] = "one two one"
        field.attrs["AXFocused"] = true
        for (mode, range) in [
            ("text", NSRange(location: 8, length: 3)),
            ("cursor_before", NSRange(location: 8, length: 0)),
            ("cursor_after", NSRange(location: 11, length: 0)),
        ] {
            try actions.selectText(app, line("AXTextArea"), "one", prefix: "two ", mode: mode)
            XCTAssertEqual(ax.sets.last?.2 as? NSRange, range)
        }
        XCTAssertThrowsError(try actions.selectText(app, line(), "missing"))
        XCTAssertThrowsError(try actions.selectText(app, line(), "one", mode: "bogus"))
    }
    func testSelectionMarkersAndBoundsScrollToMiddle() throws {
        let bar = ContextElement("AXScrollBar", attrs: ["AXValue": 0.5])
        let area = ContextElement(
            "AXScrollArea", rect: CGRect(x: 0, y: 0, width: 100, height: 100),
            attrs: ["AXVerticalScrollBar": bar.ref])
        field.attrs["AXValue"] = "hello"
        field.attrs["AXParent"] = area.ref
        field.rect = CGRect(x: 0, y: 0, width: 100, height: 500)
        ax.unsettable = ["AXSelectedTextRange"]
        ax.onParam = { _, name, value in
            switch name {
            case "AXBoundsForRange": return CGRect(x: 0, y: 300, width: 20, height: 20)
            case "AXTextMarkerForIndex": return value
            case "AXTextMarkerRangeForUnorderedTextMarkers": return "markers"
            default: return nil
            }
        }
        try actions.selectText(app, line("AXTextArea"), "hello")
        XCTAssertEqual(bar.attrs["AXValue"] as? Double, 1)
        XCTAssertEqual(ax.sets.last?.1, "AXSelectedTextMarkerRange")
        XCTAssertEqual(ax.sets.last?.2 as? String, "markers")
    }
    func testSecondaryExactNamesDisclosurePageButtonsAndRaise() throws {
        let l = line(actions: [
            ("Raise", "AXRaise"), ("Expand", "AXPress"), ("Collapse", "AXPress"),
            ("Scroll Down", "AXScrollDownByPage"),
        ])
        XCTAssertThrowsError(try actions.secondary(app, l, "raise"))
        try actions.secondary(app, l, "Raise")
        XCTAssertEqual(ax.performed.last?.1, "AXRaise")
        try actions.secondary(app, l, "Expand")
        XCTAssertEqual(ax.sets.last?.1, "AXDisclosing")
        XCTAssertEqual(ax.sets.last?.2 as? Bool, true)
        try actions.secondary(app, l, "Collapse")
        XCTAssertEqual(ax.sets.last?.2 as? Bool, false)
        let page = ContextElement("AXButton", attrs: ["AXSubrole": "AXIncrementPage"])
        let bar = ContextElement("AXScrollBar")
        bar.attrs["AXChildren"] = [page.ref]
        field.attrs["AXVerticalScrollBar"] = bar.ref
        try actions.secondary(app, l, "Scroll Down")
        XCTAssertTrue(AX.same(ax.performed.last?.0, page.ref))
        XCTAssertEqual(ax.performed.last?.1, "AXPress")
        XCTAssertTrue(posted.isEmpty)
        XCTAssertFalse(app.needsSettle)
    }
    func testPasteUsesPIDCommandVAndWatchesFocusedFieldAndRestores() throws {
        front = 77
        root.attrs["AXFocusedUIElement"] = field.ref
        field.attrs["AXValue"] = "before"
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "paste-action-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        var restore = false
        var waits = 0
        let backend = ComputerUseSystem.Pasteboard.Backend(
            snapshot: { [["old": Data("old".utf8)]] }, write: { _ in 42 },
            restore: { _, count in
                restore = count == 42
                return true
            })
        actions.system.pasteboard = ComputerUseSystem.Pasteboard(
            board: { backend }, stateDirectory: { home },
            wait: { predicate, _, _ in
                waits += 1
                if waits == 1 { return true }
                self.field.attrs["AXValue"] = "after"
                return predicate()
            })
        try actions.paste(app, "hello", format: "text")
        XCTAssertEqual(types, [12, 10, 11, 12])
        XCTAssertTrue(posted.allSatisfy { $0.0 == 77 })
        XCTAssertTrue(restore)
        XCTAssertEqual(waits, 2)
        XCTAssertEqual(posted[1].1.flags.rawValue, UInt64(Keys.command))
    }
    func testOnlySinglePlainEscapeCancelsAndSecondaryCancelAlwaysCloses() throws {
        front = 77
        for spec in ["shift+Escape", "Escape Return", "Return Escape"] {
            actions.system.windows.keepMenu(target, title: field.ref)
            ax.performed = []
            posted = []
            try actions.pressKey(app, spec)
            XCTAssertTrue(ax.performed.isEmpty)
            XCTAssertNotNil(try actions.system.windows.shownMenu(target))
            XCTAssertFalse(posted.isEmpty)
        }
        let l = line(actions: [("Cancel", "AXCancel")])
        ax.onPerform = { _, _ in throw Errors.make("not_settable") }
        XCTAssertThrowsError(try actions.secondary(app, l, "Cancel"))
        XCTAssertNil(try actions.system.windows.shownMenu(target))
    }
    func testForeignWindowReceivesMouseAndIsPolicyChecked() throws {
        let foreign = ContextElement(
            "AXButton", pid: 99, id: 9, rect: CGRect(x: 20, y: 20, width: 60, height: 30),
            attrs: ["AXWindow": window.ref])
        ax.hit = foreign.ref
        actions.system.windows.system.rows = { _, _ in
            [.init(id: 9, pid: 99, frame: self.window.rect!)]
        }
        try actions.click(app, .point(CGPoint(x: 30, y: 30)))
        XCTAssertTrue(posted.allSatisfy { $0.0 == 99 })
        posted = []
        blocked = true
        XCTAssertThrowsError(try actions.click(app, .point(CGPoint(x: 30, y: 30))))
        XCTAssertTrue(posted.isEmpty)
    }
    func testChromiumAndCatalystMenuButtonActivateInsteadOfCommandClick() throws {
        for catalyst in [false, true] {
            var system = actions.system.apps.system
            system.info = { _ in catalyst ? [:] : ["NSPrincipalClass": Apps.chromiumClass] }
            actions.system.apps = Apps(system: system)
            root.attrs[Apps.catalyst] = catalyst
            root.attrs["AXFrontmost"] = false
            actions.system.focus = Focus(system: actions.system.focus.system)
            posted = []
            activation = []
            try actions.click(app, .line(line(catalyst ? "AXMenuButton" : "AXButton")))
            XCTAssertFalse(activation.isEmpty)
            XCTAssertEqual(posted[0].1.flags.rawValue, 0)
        }
    }
    func testMissingElementRefusesSafelyAndLargeWheelDoesNotTrap() throws {
        let missing = Line(depth: 0, text: "button", element: nil, role: "AXButton", id: 1)
        XCTAssertThrowsError(try actions.click(app, .line(missing)))
        XCTAssertThrowsError(try actions.scroll(app, .line(missing), direction: "down", pages: 1))
        XCTAssertThrowsError(
            try actions.scroll(app, .point(CGPoint(x: 30, y: 30)), direction: "down", pages: 1e100))
        XCTAssertTrue(posted.isEmpty)
    }

    func testRichSelectionSearchesPrintedMarkdownAndMapsToPlainSource() throws {
        let runs: [RichText.Run] = [
            ("Plain ", [:]), ("bold part", ["bold": true]), (" and ", [:]),
            ("a link", ["link": "x.org"]),
            (".", [:]),
        ]
        actions.system.printedText = { _ in try RichText.markdown(runs) }
        for (text, prefix, expected) in [
            ("bold part", "", NSRange(location: 6, length: 9)),
            ("a link", "", NSRange(location: 20, length: 6)),
            ("part** and", "bold ", NSRange(location: 11, length: 8)),
        ] {
            try actions.selectText(app, line("AXTextArea"), text, prefix: prefix)
            XCTAssertEqual(ax.sets.last?.2 as? NSRange, expected)
        }
    }

}
