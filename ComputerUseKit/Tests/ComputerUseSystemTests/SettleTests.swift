import ComputerUseCore
import XCTest
@testable import ComputerUseSystem

final class SettleTests: ContextTestCase {
    var reads = 0, loading = false, hasWindow = true
    func wait(_ kind: AppKind = .init(), poll: Double? = nil, quiet: Double = Settle.quiet, limit: Double = Settle.limit, abandoned: () -> Bool = { false }) throws -> Capture? {
        try Settle.wait(target: target, kind: kind, read: { _ in
            self.reads += 1; return Capture(windowTitle: "Test", appName: "Test", windowID: 7, lines: [], loading: self.loading)
        }, poll: poll, quiet: quiet, limit: limit, now: clock.now, sleep: { self.clock.sleep($0) }, abandoned: abandoned, keyWindow: { _ in
            if !self.hasWindow { throw Errors.make("no_windows") }; return fixtureWindow()
        })
    }
    func testNativeFloorThreePollsOneCapture() throws {
        XCTAssertNotNil(try wait()); XCTAssertEqual(clock.sleeps, [0.1, 0.1, 0.1]); XCTAssertEqual(reads, 1); XCTAssertTrue(ax.observations[0].stopped)
    }
    func testWebLikeFloorAndCatalystNative() throws {
        for kind in [AppKind(electron: true), AppKind(chromium: true), AppKind(http: true), AppKind(catalyst: true)] {
            clock.sleeps = []; _ = try wait(kind)
            XCTAssertEqual(clock.sleeps, kind.webLike ? [0.25] : [0.1, 0.1, 0.1])
        }
    }
    func testExplicitPollAndQuietOverride() throws {
        _ = try wait(.init(http: true), poll: 0.1); XCTAssertEqual(clock.sleeps, [0.1, 0.1, 0.1])
        clock.sleeps = []; _ = try wait(poll: 0.05, quiet: 0.1); XCTAssertEqual(clock.sleeps.count, 3) // binary floating-point at uptime 1000
    }
    func testNotificationDelaysQuietRead() throws {
        var fired = false
        clock.onSleep = {
            if !fired && self.clock.time >= 1000.1 { fired = true; self.ax.observations[0].fire("AXLayoutChanged", self.ax.app(pid: 77)) }
        }
        _ = try wait(); XCTAssertEqual(clock.time, 1000.4, accuracy: 0.0001); XCTAssertEqual(reads, 1)
    }
    func testNotificationsVocabulary() {
        XCTAssertEqual(Settle.notifications.count, 10)
        XCTAssertEqual(Set(Settle.notifications), ["AXTitleChanged", "AXLayoutChanged", "AXFocusedWindowChanged", "AXFocusedUIElementChanged", "AXElementBusyChanged", "AXMenuOpened", "AXSheetCreated", "AXWindowCreated", "AXCreated", "AXUIElementDestroyed"])
        for name in Settle.notifications where name != Settle.titleChanged {
            let heard = Settle.Heard(now: clock.now); clock.time += 1; heard.note(name, element: ax.app(pid: 77)); XCTAssertEqual(heard.quietFor(), 0)
        }
    }
    func testRepeatedSameTitleIgnoredNewTitleCountsAndElementsSeparate() {
        let heard = Settle.Heard(now: clock.now), one = ContextElement(attrs: ["AXTitle": "A"]), two = ContextElement(attrs: ["AXTitle": "A"])
        clock.time += 1; heard.note(Settle.titleChanged, element: one.ref); XCTAssertEqual(heard.quietFor(), 0)
        clock.time += 1; heard.note(Settle.titleChanged, element: one.ref); XCTAssertEqual(heard.quietFor(), 1)
        one.attrs["AXTitle"] = "B"; heard.note(Settle.titleChanged, element: one.ref); XCTAssertEqual(heard.quietFor(), 0)
        clock.time += 1; heard.note(Settle.titleChanged, element: two.ref); XCTAssertEqual(heard.quietFor(), 0)
    }
    func testNonTextAndFailedTitleDoNotCount() {
        let heard = Settle.Heard(now: clock.now), e = ContextElement(attrs: ["AXTitle": 5])
        clock.time += 1; heard.note(Settle.titleChanged, element: e.ref); XCTAssertEqual(heard.quietFor(), 1)
        ax.failGet = ["AXTitle"]; heard.note(Settle.titleChanged, element: e.ref); XCTAssertEqual(heard.quietFor(), 1)
    }
    func testNoWindowAndLoadingReachFiveSecondLimit() throws {
        hasWindow = false; XCTAssertNil(try wait()); XCTAssertEqual(reads, 0); XCTAssertEqual(clock.time, 1005, accuracy: 0.11)
        hasWindow = true; loading = true; clock.time = 1000; XCTAssertNil(try wait()); XCTAssertGreaterThan(reads, 45)
    }
    func testLimitCheckedBeforeSleepOnly() throws {
        hasWindow = false; XCTAssertNil(try wait(poll: 0.25, limit: 0.3)); XCTAssertEqual(clock.sleeps, [0.25, 0.25])
    }
    func testWindowAppearsAndLoadingEnds() throws {
        hasWindow = false; clock.onSleep = { if self.clock.time >= 1002 { self.hasWindow = true } }
        XCTAssertNotNil(try wait(poll: 0.05)); XCTAssertEqual(clock.time, 1002, accuracy: 0.06)
        loading = true; clock.onSleep = { self.loading = self.clock.time < 1003 }
        XCTAssertNotNil(try wait()); XCTAssertEqual(clock.time, 1003, accuracy: 0.11)
    }
    func testAbandonmentStopsObserver() {
        loading = true
        assertHarnessError(name: "request_timed_out") { _ = try self.wait(abandoned: { self.clock.time >= 1000.5 }) }
        XCTAssertTrue(ax.observations[0].stopped)
    }
    func testOtherWindowErrorAndReadFailurePropagateWithCleanup() {
        for failRead in [false, true] {
            XCTAssertThrowsError(try Settle.wait(target: target, kind: .init(), read: { _ in throw Errors.make("front_not_back") }, now: clock.now, sleep: { self.clock.sleep($0) }, keyWindow: { _ in if failRead { return fixtureWindow() }; throw Errors.make("front_not_back") }))
            XCTAssertTrue(ax.observations.last!.stopped)
        }
    }
    func testRegistrationFailurePropagates() {
        ax.failObserve = true; XCTAssertThrowsError(try wait()); XCTAssertTrue(clock.sleeps.isEmpty)
    }
}
