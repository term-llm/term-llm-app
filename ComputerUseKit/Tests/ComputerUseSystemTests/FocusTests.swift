import AppKit
import ComputerUseCore
import XCTest
import os
@testable import ComputerUseSystem

final class FocusTests: ContextTestCase {
    var focus: Focus!, window: ComputerUseCore.WindowRef!, element: ContextElement!
    private let frontState = OSAllocatedUnfairLock<pid_t>(initialState: 88)
    var front: pid_t {
        get { frontState.withLock { $0 } }
        set { frontState.withLock { $0 = newValue } }
    }
    var posted: [(pid_t, CGEvent)] = [], background: [() -> Void] = [], screen: [String] = []
    var react = true, personWent = false
    override func setUp() {
        super.setUp(); front = 88; posted = []; background = []; screen = []; react = true; personWent = false
        element = ContextElement(attrs: ["AXActivationPoint": CGPoint(x: 130, y: 116), "AXMain": true])
        window = .init(element: element.ref, windowID: 7, pid: 77, title: "Test", frame: element.rect!)
        var s = Focus.System(); s.frontPID = { self.front }; s.noAttention = { _ in }; s.personWent = { _, _ in self.personWent }
        s.now = { self.clock.time }; s.sleep = { self.clock.sleep($0) }; s.background = { self.background.append($0) }
        s.freeze = { self.screen.append("freeze") }; s.thaw = { self.screen.append("thaw") }
        s.post = { pid, event in
            self.posted.append((pid, event))
            if self.react && event.type.rawValue == Focus.appKitDefined {
                self.ax.el(self.ax.app(pid: pid)).attrs["AXFrontmost"] = (NSEvent(cgEvent: event)?.subtype.rawValue == 1)
            }
        }
        focus = Focus(system: s)
    }
    func testActivationThreeEventsNoRealFocusAndBeliefLasts() throws {
        let e = focus.enforcer(target); XCTAssertFalse(e.believesFocus)
        try e.active(window: window) { XCTAssertTrue(e.believesFocus) }
        XCTAssertTrue(e.believesFocus); XCTAssertFalse(e.reallyActive); XCTAssertEqual(front, 88)
        XCTAssertEqual(posted.map { $0.1.type.rawValue }, [13, 1, 2]); XCTAssertTrue(posted.allSatisfy { $0.0 == 77 })
        XCTAssertEqual(posted[0].1.flags.rawValue, Focus.activationFlags); XCTAssertEqual(posted[1].1.location, CGPoint(x: 130, y: 116))
        XCTAssertTrue(ax.sets.isEmpty && ax.performed.isEmpty); XCTAssertEqual(screen, ["freeze", "thaw"])
    }
    func testNoWindowOrNoPointOnlyActivationNotice() throws {
        try focus.enforcer(target).active(window: nil) {}; XCTAssertEqual(posted.count, 1); XCTAssertEqual(posted[0].1.flags.rawValue, 0)
        focus = Focus(system: focus.system); ax.el(ax.app(pid: 77)).attrs = [:]; posted = []; element.attrs["AXActivationPoint"] = nil
        try focus.enforcer(target).active(window: window) {}; XCTAssertEqual(posted.count, 1)
    }
    func testThreeTruthsAndNoEventsWhenFocusedOrRealActive() throws {
        let e = focus.enforcer(target); _ = try e.enforce(window); posted = []
        XCTAssertFalse(try e.enforce(window)); XCTAssertTrue(posted.isEmpty)
        front = 77; XCTAssertTrue(e.reallyActive && e.believesActive && e.believesFocus)
        front = 88; ax.el(ax.app(pid: 77)).attrs["AXFrontmost"] = false
        XCTAssertFalse(e.believesActive); XCTAssertFalse(e.believesFocus)
        front = 77; _ = try e.enforce(window); XCTAssertTrue(posted.isEmpty)
    }
    func testActiveButUnfocusedOnlyKeyNoticeNotLeakWatch() throws {
        ax.el(ax.app(pid: 77)).attrs["AXFrontmost"] = true
        try focus.enforcer(target).active(window: window) {}
        XCTAssertEqual(posted.count, 1); XCTAssertEqual(posted[0].1.type.rawValue, 21)
        XCTAssertEqual(UInt16(bitPattern: NSEvent(cgEvent: posted[0].1)!.subtype.rawValue), 0x8000); XCTAssertTrue(background.isEmpty)
    }
    func testBeliefWaitAndClickedWindowMainWait() throws {
        react = false; _ = try focus.enforcer(target).enforce(window); XCTAssertEqual(clock.time, 1000.25, accuracy: 0.011)
        focus = Focus(system: focus.system); react = true; element.attrs["AXMain"] = false; clock.time = 1000
        clock.onSleep = { if self.clock.time >= 1000.05 { self.element.attrs["AXMain"] = true } }
        _ = try focus.enforcer(target).enforce(window); XCTAssertEqual(clock.time, 1000.05, accuracy: 0.011)
    }
    func testImmediateLeakRestoredAndWorkErrorStillRestores() {
        ax.onSet = { [frontState] _, name, _ in if name == "AXFrontmost" { frontState.withLock { $0 = 88 } } }
        XCTAssertThrowsError(try focus.enforcer(target).active(window: window) { self.front = 77; throw Errors.make("no_windows") })
        XCTAssertEqual(front, 88); XCTAssertEqual(ax.sets.count, 1)
    }
    func testPersonSwitchNotRestored() throws {
        personWent = true
        try focus.enforcer(target).active(window: window) { self.front = 77 }
        XCTAssertEqual(front, 77); XCTAssertTrue(ax.sets.isEmpty); XCTAssertTrue(background.isEmpty)
    }
    func testDelayedLeakWatchRestoresOnlyWithinThreeSeconds() throws {
        try focus.enforcer(target).active(window: window) {}; XCTAssertEqual(background.count, 1)
        front = 77; clock.time += 1.9; ax.onSet = { [frontState] _, _, _ in frontState.withLock { $0 = 88 } }; background.removeFirst()()
        XCTAssertEqual(front, 88); XCTAssertEqual(ax.sets.count, 1)
        focus.release(target); try focus.enforcer(target).active(window: window) {}; clock.time += 3.1; front = 77; background.removeFirst()()
        XCTAssertEqual(ax.sets.count, 1)
    }
    func testDelayedPersonSwitchLeftAlone() throws {
        try focus.enforcer(target).active(window: window) {}; personWent = true; front = 77; background.removeFirst()()
        XCTAssertTrue(ax.sets.isEmpty)
    }
    func testRestoreTimeoutTextAndBudget() {
        assertHarnessError(Errors.make("front_not_back").message) {
            try self.focus.enforcer(self.target).active(window: self.window) { self.front = 77 }
        }
        XCTAssertEqual(clock.time, 1002, accuracy: 0.02)
    }
    func testFreezeThawOnActivationReadFailure() {
        ax.failGet = ["AXActivationPoint"]
        XCTAssertThrowsError(try focus.enforcer(target).active(window: window) {})
        XCTAssertEqual(screen, ["freeze", "thaw"])
    }
    func testReleaseOnceAndReallyActiveUntouched() throws {
        _ = try focus.enforcer(target).enforce(window); posted = []; focus.release(target); focus.release(target)
        XCTAssertEqual(posted.map { $0.1.type.rawValue }, [21, 13]); XCTAssertEqual(NSEvent(cgEvent: posted[1].1)?.subtype.rawValue, 2)
        posted = []; focus.enforcer(target).release(); XCTAssertTrue(posted.isEmpty)
        front = 77; focus.releaseAll(); XCTAssertTrue(posted.isEmpty)
    }
    func testSharedPerPIDAndInputLockHeldThroughAction() throws {
        XCTAssertTrue(focus.enforcer(target) === focus.enforcer(target))
        let result = DispatchSemaphore(value: 0)
        try focus.enforcer(target).active(window: window) {
            DispatchQueue.global().async {
                let acquired = Focus.inputLock.try()
                XCTAssertFalse(acquired); if acquired { Focus.inputLock.unlock() }; result.signal()
            }
            XCTAssertEqual(result.wait(timeout: .now() + 1), .success)
        }
    }
    func testElementFocusRefusal() {
        XCTAssertTrue(Focus.focusElement(element.ref)); XCTAssertEqual(element.attrs["AXFocused"] as? Bool, true)
        ax.failSet = true; XCTAssertFalse(Focus.focusElement(element.ref))
    }
}
