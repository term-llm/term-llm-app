import AppKit
import ComputerUseCore
import XCTest
import os
@testable import ComputerUseSystem

private final class FocusFixture: Sendable {
    // CGEvents are immutable, operation-local test records, protected with the rest of the fixture. Stored callbacks are @Sendable; never invoked under the state lock.
    private struct State {
        var posted: [(pid_t, CGEvent)] = []
        var background: [@Sendable () -> Void] = []
        var screen: [String] = []
        var react: Bool = true
        var personWent: Bool = false
    }
    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    var posted: [(pid_t, CGEvent)] {
        get { state.withLockUnchecked { $0.posted } }
        set { state.withLockUnchecked { $0.posted = newValue } }
    }
    var background: [@Sendable () -> Void] {
        get { state.withLockUnchecked { $0.background } }
        set { state.withLockUnchecked { $0.background = newValue } }
    }
    var screen: [String] {
        get { state.withLockUnchecked { $0.screen } }
        set { state.withLockUnchecked { $0.screen = newValue } }
    }
    var react: Bool {
        get { state.withLockUnchecked { $0.react } }
        set { state.withLockUnchecked { $0.react = newValue } }
    }
    var personWent: Bool {
        get { state.withLockUnchecked { $0.personWent } }
        set { state.withLockUnchecked { $0.personWent = newValue } }
    }
    func record(_ pid: pid_t, _ event: CGEvent) { state.withLockUnchecked { $0.posted.append((pid, event)) } }
    func schedule(_ callback: @escaping @Sendable () -> Void) { state.withLockUnchecked { $0.background.append(callback) } }
    func screenChanged(_ operation: String) { state.withLockUnchecked { $0.screen.append(operation) } }

}

final class FocusTests: ContextTestCase {
    var focus: Focus!, window: ComputerUseCore.WindowRef!, element: ContextElement!
    private let frontState = OSAllocatedUnfairLock<pid_t>(initialState: 88)
    var front: pid_t {
        get { frontState.withLock { $0 } }
        set { frontState.withLock { $0 = newValue } }
    }
    private let fixture = FocusFixture()
    var posted: [(pid_t, CGEvent)] {
        get { fixture.posted }
        set { fixture.posted = newValue }
    }
    var background: [@Sendable () -> Void] {
        get { fixture.background }
        set { fixture.background = newValue }
    }
    var screen: [String] {
        get { fixture.screen }
        set { fixture.screen = newValue }
    }
    var react: Bool {
        get { fixture.react }
        set { fixture.react = newValue }
    }
    var personWent: Bool {
        get { fixture.personWent }
        set { fixture.personWent = newValue }
    }
    override func setUp() {
        super.setUp(); front = 88; posted = []; background = []; screen = []; react = true; personWent = false
        element = ContextElement(attrs: ["AXActivationPoint": CGPoint(x: 130, y: 116), "AXMain": true])
        window = .init(element: element.ref, windowID: 7, pid: 77, title: "Test", frame: element.rect!)
        let fixture = fixture, clock = clock!, ax = ax!, frontState = frontState
        var s = isolatedFocusSystem(); s.frontPID = { frontState.withLock { $0 } }; s.noAttention = { _ in }; s.personWent = { _, _ in fixture.personWent }
        s.now = { clock.time }; s.sleep = { clock.sleep($0) }; s.background = { fixture.schedule($0) }
        s.freeze = { fixture.screenChanged("freeze") }; s.thaw = { fixture.screenChanged("thaw") }
        s.post = { pid, event in
            fixture.record(pid, event)
            if fixture.react && event.type.rawValue == Focus.appKitDefined {
                ax.el(ax.app(pid: pid)).attrs["AXFrontmost"] = (NSEvent(cgEvent: event)?.subtype.rawValue == 1)
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
        clock.onSleep = { [clock = clock!, element = element!] in if clock.time >= 1000.05 { element.set("AXMain", true) } }
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

/// Unlike FocusTests, these paths never construct CGEvents or resolve private
/// functions. Already-active targets and explicit fail-fast system fakes only.
final class FocusOwnershipTests: XCTestCase {
    private let target = AppTarget(path: "/Fixture/Test.app", bundleID: "test", name: "Test", pid: 77)

    func testSharedEnforcerGettersAndDirectOperationsAreSynchronized() {
        var system = isolatedFocusSystem(); system.frontPID = { 77 }; system.now = { 0 }
        let focus = Focus(system: system), target = target, identity = ContextBox<Set<ObjectIdentifier>>([])
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            let enforcer = focus.enforcer(target)
            identity.withValue { $0.insert(ObjectIdentifier(enforcer)) }
            XCTAssertTrue(enforcer.reallyActive && enforcer.believesActive && enforcer.believesFocus)
            XCTAssertFalse(try! enforcer.enforce(nil))
            enforcer.release()
        }
        XCTAssertEqual(identity.value.count, 1)
        focus.releaseAll()
    }

    func testExecutionLockExcludesOtherThreadsAndAllowsSameThreadReentry() throws {
        var system = isolatedFocusSystem(); system.frontPID = { 77 }; system.now = { 0 }
        let focus = Focus(system: system), target = target, enforcer = focus.enforcer(target)
        let started = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        try enforcer.active(window: nil) {
            // All public operations can be called recursively without a state-lock deadlock.
            XCTAssertTrue(enforcer.believesFocus)
            enforcer.release(); focus.release(target)
            XCTAssertFalse(try focus.enforcer(target).enforce(nil))
            DispatchQueue.global().async {
                started.signal()
                do { let activated = try enforcer.enforce(nil); XCTAssertFalse(activated) } catch { XCTFail("Unexpected enforce failure: \(error)") }
                finished.signal()
            }
            XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
            XCTAssertEqual(finished.wait(timeout: .now() + 0.1), .timedOut)
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        focus.releaseAll()
    }

    func testReportedBeliefsCanBeReadConcurrentlyWithoutInputEvents() {
        let backend = ContextAX()
        backend.el(backend.app(pid: 77)).set("AXFrontmost", true)
        var system = isolatedFocusSystem(); system.frontPID = { 88 }
        let focus = Focus(system: system), enforcer = focus.enforcer(target)
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            AX.withBackend(backend) {
                XCTAssertTrue(enforcer.believesActive)
                XCTAssertFalse(enforcer.believesFocus)
            }
        }
        backend.el(backend.app(pid: 77)).set("AXFrontmost", false)
        AX.withBackend(backend) { XCTAssertFalse(enforcer.believesActive) }
        AX.withBackend(backend) { focus.releaseAll() }
    }

    func testLeakWatcherCapturesBackendBeforeInjectedBackgroundHop() {
        let caller = ContextAX(), worker = ContextAX(), front = ContextBox<pid_t>(77)
        let pending = ContextBox<(@Sendable () -> Void)?>(nil)
        caller.onSet = { _, name, _ in if name == "AXFrontmost" { front.value = 88 } }
        var system = isolatedFocusSystem()
        system.frontPID = { front.value }; system.now = { 1 }; system.personWent = { _, _ in false }
        system.background = { pending.value = $0 }
        let focus = Focus(system: system)
        AX.withBackend(caller) { focus.watchLeak(77, before: 88, since: 0) }
        let done = DispatchSemaphore(value: 0), work = pending.value!
        DispatchQueue.global().async {
            AX.withBackend(worker) { work() }
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(front.value, 88)
        XCTAssertEqual(caller.sets.map { $0.1 }, ["AXFrontmost"])
        XCTAssertTrue(worker.sets.isEmpty)
        pending.value = nil
    }

    func testReleaseCallbackCanReenterEnforcerRegistry() {
        let owner = ContextBox<Focus?>(nil), target = target
        var system = isolatedFocusSystem()
        system.frontPID = {
            _ = owner.value?.enforcer(target)
            return 77
        }
        let focus = Focus(system: system); owner.value = focus
        _ = focus.enforcer(target)
        focus.releaseAll() // frontPID is called after removing the snapshot, outside its lock.
        owner.value = nil
        focus.releaseAll()
    }
}

extension FocusOwnershipTests {
    func testSlowGetterDoesNotSerializeOtherPIDsAndReleaseInvalidatesSample() throws {
        let backend = ContextAX(), front = ContextBox<pid_t>(88)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        var system = isolatedFocusSystem(); system.frontPID = { front.value }
        let focus = Focus(system: system), enforcer = focus.enforcer(target)
        backend.onGet = { element, name in
            if (element.object as! ContextElement).pid == 77, name == "AXFrontmost" {
                entered.signal(); XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
                return true // Now stale: release happened after this read began.
            }
            return false
        }
        DispatchQueue.global().async {
            AX.withBackend(backend) { XCTAssertFalse(enforcer.believesActive) }
            finished.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        var other = target; other.pid = 99
        AX.withBackend(backend) { XCTAssertFalse(focus.enforcer(other).believesActive) }
        front.value = 77
        enforcer.release() // Already-active fake path: no CGEvent construction.
        front.value = 88
        XCTAssertEqual(finished.wait(timeout: .now() + 0.05), .timedOut)
        release.signal(); XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        backend.onGet = nil
        AX.withBackend(backend) { focus.releaseAll() }
    }
}

extension FocusOwnershipTests {
    func testLateLeakRestoresDuringAnotherPhysicalActionAndGettersStayIndependent() {
        let caller = ContextAX(), worker = ContextAX(), front = ContextBox<pid_t>(88), now = ContextBox(0.0)
        let pending = ContextBox<(@Sendable () -> Void)?>(nil)
        let held = DispatchSemaphore(value: 0), unlock = DispatchSemaphore(value: 0), unlocked = DispatchSemaphore(value: 0)
        let polled = DispatchSemaphore(value: 0), leak = DispatchSemaphore(value: 0), restored = DispatchSemaphore(value: 0)
        let watched = DispatchSemaphore(value: 0), getters = DispatchSemaphore(value: 0), lookupStarted = DispatchSemaphore(value: 0), lookup = DispatchSemaphore(value: 0)
        caller.onSet = { _, name, _ in
            XCTAssertTrue(AX.backend === caller)
            if name == "AXFrontmost" { front.value = 88; restored.signal() }
        }
        var system = isolatedFocusSystem()
        system.frontPID = { front.value }; system.now = { now.value }; system.personWent = { _, _ in false }
        system.background = { pending.value = $0 }
        system.sleep = { _ in polled.signal(); XCTAssertEqual(leak.wait(timeout: .now() + 5), .success) }
        let focus = Focus(system: system), target = target, cached = focus.enforcer(target)
        var other = target; other.pid = 99
        let otherCached = focus.enforcer(other)
        AX.withBackend(caller) { focus.watchLeak(77, before: 88, since: 0) }
        DispatchQueue.global().async {
            Focus.inputLock.lock(); held.signal()
            XCTAssertEqual(unlock.wait(timeout: .now() + 5), .success)
            AX.withBackend(caller) { focus.release(target) } // Still inside B's execution.
            Focus.inputLock.unlock(); unlocked.signal()
        }
        XCTAssertEqual(held.wait(timeout: .now() + 2), .success)
        let work = pending.value!
        DispatchQueue.global().async { AX.withBackend(worker) { work() }; watched.signal() }
        XCTAssertEqual(polled.wait(timeout: .now() + 2), .success)
        now.value = 1.9; front.value = 77; leak.signal()
        XCTAssertEqual(restored.wait(timeout: .now() + 2), .success, "Human-priority restoration cannot wait for action B's input lock")
        XCTAssertEqual(watched.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(front.value, 88)
        DispatchQueue.global().async {
            AX.withBackend(caller) {
                XCTAssertFalse(cached.believesActive)
                XCTAssertFalse(otherCached.believesFocus)
            }
            getters.signal()
        }
        XCTAssertEqual(getters.wait(timeout: .now() + 1), .success, "Cached belief getters cannot wait in the physical action queue")
        DispatchQueue.global().async {
            lookupStarted.signal()
            XCTAssertFalse(focus.enforcer(target) === cached, "Lookup must follow B's removal, not hand out the stale registered object")
            lookup.signal()
        }
        XCTAssertEqual(lookupStarted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(lookup.wait(timeout: .now() + 0.05), .timedOut, "Registry lookup retains its original action ordering")
        now.value = Focus.leakWatch + 1 // B holds execution past A's entire leak window.
        unlock.signal()
        XCTAssertEqual(unlocked.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(lookup.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(worker.sets.isEmpty)
        XCTAssertEqual(caller.sets.map { $0.1 }, ["AXFrontmost"])
        pending.value = nil
        AX.withBackend(caller) { focus.releaseAll() }
    }

    func testDirectBringBackDoesNotWaitForAnotherPhysicalAction() {
        let backend = ContextAX(), front = ContextBox<pid_t>(77)
        let held = DispatchSemaphore(value: 0), unlock = DispatchSemaphore(value: 0), unlocked = DispatchSemaphore(value: 0), restored = DispatchSemaphore(value: 0)
        backend.onSet = { _, name, _ in if name == "AXFrontmost" { front.value = 88 } }
        var system = isolatedFocusSystem(); system.frontPID = { front.value }; system.now = { 0 }
        let focus = Focus(system: system)
        DispatchQueue.global().async {
            Focus.inputLock.lock(); held.signal()
            XCTAssertEqual(unlock.wait(timeout: .now() + 5), .success)
            Focus.inputLock.unlock(); unlocked.signal()
        }
        XCTAssertEqual(held.wait(timeout: .now() + 2), .success)
        DispatchQueue.global().async {
            do { try AX.withBackend(backend) { try focus.bringBack(88) } } catch { XCTFail("Unexpected restore failure: \(error)") }
            restored.signal()
        }
        XCTAssertEqual(restored.wait(timeout: .now() + 2), .success, "Independent restoration must finish before the input lock is released")
        XCTAssertEqual(front.value, 88)
        unlock.signal()
        XCTAssertEqual(unlocked.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(backend.sets.map { $0.1 }, ["AXFrontmost"])
    }
}
