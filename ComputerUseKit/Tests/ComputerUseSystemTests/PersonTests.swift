import AppKit
import ComputerUseCore
import XCTest
import os
@testable import ComputerUseSystem

// Every Person dependency is explicitly fake. CGEvents below are only constructed
// and inspected; they are never posted. No live tap, HID query, AX, or prompt.
final class PersonFixture: Sendable {
    static let inertWatch = Person.Watch(
        isRunning: { false }, schedule: { _ in XCTFail("No lifecycle work expected") },
        create: { _ in XCTFail("Worker-only tests must never create a tap"); return nil })
    struct Post: Sendable { let type: UInt32, key: Int64 }
    struct State: Sendable {
        var time = 1000.0, sleeps: [Double] = []
        var onSleep: (@Sendable () -> Void)?
        var timers: [(Double, @Sendable () -> Void)] = [], activity: [String] = [], posted: [Post] = []
        var front: pid_t = 77, idle = Double.infinity, secure: pid_t?, bundles: [pid_t: String] = [:], owner: pid_t = 0
        var menu: UIElementRef?
    }
    let state = OSAllocatedUnfairLock(initialState: State())
    var time: Double { get { state.withLock { $0.time } } set { state.withLock { $0.time = newValue } } }
    var sleeps: [Double] { state.withLock { $0.sleeps } }
    var onSleep: (@Sendable () -> Void)? { get { state.withLock { $0.onSleep } } set { state.withLock { $0.onSleep = newValue } } }
    func sleep(_ seconds: Double) {
        let callback = state.withLock { state in state.time += seconds; state.sleeps.append(seconds); return state.onSleep }
        callback?()
    }
    var system: Person.System {
        .init(now: { self.time }, sleep: { self.sleep($0) },
              frontmostPID: { self.state.withLock { $0.front } },
              bundleOf: { pid in self.state.withLock { $0.bundles[pid] ?? "" } },
              hidIdle: { _ in self.state.withLock { $0.idle } },
              secureInputPID: { self.state.withLock { $0.secure } },
              windowPID: { _ in self.state.withLock { $0.owner } }, canListen: { false })
    }
    var hooks: Person.Hooks {
        .init(pointerActivity: { value in self.state.withLock { $0.activity.append(value) } },
              shownMenu: { _ in self.state.withLock { $0.menu } },
              post: { _, event in
                  let value = Post(type: event.type.rawValue, key: event.getIntegerValueField(.keyboardEventKeycode))
                  self.state.withLock { $0.posted.append(value) }
              }, later: { delay, work in self.state.withLock { $0.timers.append((delay, work)) } })
    }
}

final class PersonTests: XCTestCase {
    override func invokeTest() { AX.withBackend(AX.backend) { super.invokeTest() } }
    private var fixture: PersonFixture!
    var person: Person!, agent: AgentSession!, ax: ContextAX!, previous: (any AXBackend)!
    let target = AppTarget(path: "/A/Test.app", bundleID: "dev.test", name: "Test", pid: 77)
    private var clock: PersonFixture { fixture }
    private var timers: [(Double, @Sendable () -> Void)] { get { fixture.state.withLock { $0.timers } } set { fixture.state.withLock { $0.timers = newValue } } }
    private var activity: [String] { fixture.state.withLock { $0.activity } }
    private var posted: [PersonFixture.Post] { get { fixture.state.withLock { $0.posted } } set { fixture.state.withLock { $0.posted = newValue } } }
    var front: pid_t { get { fixture.state.withLock { $0.front } } set { fixture.state.withLock { $0.front = newValue } } }
    var idle: Double { get { fixture.state.withLock { $0.idle } } set { fixture.state.withLock { $0.idle = newValue } } }
    var secure: pid_t? { get { fixture.state.withLock { $0.secure } } set { fixture.state.withLock { $0.secure = newValue } } }
    var bundles: [pid_t: String] { get { fixture.state.withLock { $0.bundles } } set { fixture.state.withLock { $0.bundles = newValue } } }
    var owner: pid_t { get { fixture.state.withLock { $0.owner } } set { fixture.state.withLock { $0.owner = newValue } } }
    override func setUp() {
        super.setUp(); fixture = PersonFixture(); previous = AX.backend; ax = ContextAX(); AX.backend = ax
        person = Person(system: fixture.system, hooks: fixture.hooks, watch: PersonFixture.inertWatch)
        person.startWatch(ownPID: 4242); person.simulatedTapAvailable = true; agent = AgentSession(key: "one")
    }
    override func tearDown() {
        clock.onSleep = nil; person = nil; agent = nil; AX.backend = previous; ax = nil; fixture = nil; previous = nil
        super.tearDown()
    }
    func gate(_ read: Bool = false, abandoned: () -> Bool = { false }) throws { try person.gate(agent: agent, target: target, stateRead: read, abandoned: abandoned) }
    func event(_ kind: UInt32 = 1, pid: pid_t = 77, source: pid_t = 0, tag: Int64 = 0, key: Int = 0, stray: Bool = false, command: Bool = false) { person.saw(kind: kind, sourcePID: source, tag: tag, pid: pid, keycode: key, stray: stray, command: command) }
    func testNoRecordAndDrivenNewestPID() throws {
        try gate(); try gate(true); XCTAssertEqual(clock.time, 1000); XCTAssertEqual(person.driven(), [target])
        var newer = target; newer.pid = 88; try person.gate(agent: agent, target: newer, stateRead: true); XCTAssertEqual(person.driven(), [newer])
    }
    func testActionsRefusedUntilReadAfterDebounce() throws {
        try gate(); event(); clock.sleep(6)
        for _ in 0..<2 { assertHarnessError(name: "user_took_over") { try self.gate() } }
        try gate(true); person.afterStateRead(target); try gate(); XCTAssertEqual(clock.time, 1006)
    }
    func testBusyWaitFiveSecondsAndReadDoesNotClearEarly() throws {
        try gate(); event(); person.afterStateRead(target); XCTAssertTrue(person.interrupted(target, since: 1000))
        assertHarnessError(name: "user_took_over") { try self.gate() }; XCTAssertEqual(clock.time, 1005)
        try gate(true); person.afterStateRead(target); XCTAssertFalse(person.interrupted(target, since: 1000))
    }
    func testContinuousInteractionCapsAt100SecondsForActionAndRead() throws {
        for stateRead in [false, true] {
            try gate(true); event(); let start = clock.time; clock.onSleep = { [person] in person!.saw(kind: 22, sourcePID: 0, tag: 0, pid: 77) }
            assertHarnessError(Errors.make("still_interacting", ["app_path": target.path]).message) { try self.gate(stateRead) }
            XCTAssertEqual(clock.time - start, 100, accuracy: 0.25); clock.onSleep = nil; clock.sleep(6); person.afterStateRead(target)
        }
    }
    func testAbandonmentReleasesWait() throws {
        try gate(); event(); clock.onSleep = { [person] in person!.saw(kind: 1, sourcePID: 0, tag: 0, pid: 77) }
        assertHarnessError(name: "request_timed_out") { try self.gate(abandoned: { self.clock.time >= 1002 }) }; XCTAssertEqual(clock.time, 1002)
    }
    func testEventVocabularyAndOwnEventsIgnored() throws {
        try gate()
        for kind in [UInt32(2), 4, 5, 6, 11, 12] { event(kind); XCTAssertFalse(person.interrupted(target, since: 1000)) }
        event(source: 4242); event(tag: Events.ownTag); XCTAssertFalse(person.interrupted(target, since: 1000))
        for kind in Person.eventTypes {
            event(kind); XCTAssertTrue(person.interrupted(target, since: clock.time)); clock.time += 6; person.afterStateRead(target)
        }
    }
    func testOtherAppsIgnoredAndBundleMatch() throws {
        try gate(); event(pid: 99); XCTAssertFalse(person.interrupted(target, since: 1000))
        bundles[99] = target.bundleID; event(pid: 99); XCTAssertTrue(person.interrupted(target, since: 1000))
    }
    func testStrayClosesCancelWithoutCounting() throws {
        let menu = ContextElement("AXMenu"); fixture.state.withLock { $0.menu = menu.ref }
        try gate(); event(stray: true); XCTAssertFalse(person.interrupted(target, since: 1000)); XCTAssertEqual(timers.first?.0, 0)
        timers.removeFirst().1(); XCTAssertEqual(ax.performed.first?.1, "AXCancel"); XCTAssertTrue(posted.isEmpty)
    }
    func testStrayWithoutMenuOrCancelFailureSendsEscapePair() throws {
        try gate(); event(stray: true); timers.removeFirst().1()
        XCTAssertEqual(posted.map { $0.type }, [10, 11]); XCTAssertTrue(posted.allSatisfy { $0.key == 53 })
        let menu = ContextElement("AXMenu"); fixture.state.withLock { $0.menu = menu.ref }; ax.failPerform = true; posted = []
        person.closeMenu(target); XCTAssertEqual(posted.count, 2)
    }
    func testWentToOnlyOwnClickCommandTabOrDockNotTypingElsewhere() {
        event(10, pid: 88); XCTAssertFalse(person.wentTo(77, since: 1000))
        event(pid: 88); XCTAssertFalse(person.wentTo(77, since: 1000)); XCTAssertTrue(person.wentTo(88, since: 1000))
        event(pid: 77, stray: true); XCTAssertFalse(person.wentTo(77, since: 1000))
        event(10, key: 48, command: true); XCTAssertTrue(person.wentTo(77, since: 1000))
        clock.time += 1; bundles[9] = Person.dock; event(pid: 9); XCTAssertTrue(person.wentTo(77, since: 1001))
    }
    func testWithoutTapHardwareClickCountsAsWentTo() {
        person.simulatedTapAvailable = false; idle = 2
        XCTAssertTrue(person.wentTo(99, since: 998)); XCTAssertFalse(person.wentTo(99, since: 999))
    }
    func testPointerPausedThenLoadingAndDebouncedTimer() throws {
        try gate(); event(); XCTAssertEqual(activity, ["paused"]); XCTAssertEqual(timers.count, 1)
        clock.time += 3; event(); XCTAssertEqual(timers.count, 1)
        clock.time += 2; timers.removeFirst().1(); XCTAssertEqual(timers.first?.0, 3)
        clock.time += 3; timers.removeFirst().1(); XCTAssertEqual(activity.last, "loading")
    }
    func testIdleFallbackOnlyWithoutTapOrSecureAndOnlyFrontApp() throws {
        idle = 2; try gate(); XCTAssertTrue(clock.sleeps.isEmpty)
        person.simulatedTapAvailable = false; assertHarnessError(name: "user_took_over") { try self.gate() }; XCTAssertEqual(clock.time, 1003)
        person.afterStateRead(target); idle = 2; front = 88; try gate(); XCTAssertFalse(person.interrupted(target, since: 1003))
        front = 77; secure = 9; person.simulatedTapAvailable = true
        assertHarnessError(name: "user_took_over") { try self.gate() }; XCTAssertEqual(clock.time, 1006)
    }
    func testIdleFallbackNeverMovesQuietBackward() throws {
        try gate(); event(); clock.time += 1; idle = 4; person.touchFromIdleTime(target)
        XCTAssertEqual(person.quietAt[target.path], 1005)
    }
    func testInterruptedUsesEventTimeInclusive() throws {
        try gate(); XCTAssertFalse(person.interrupted(target, since: 0)); event()
        XCTAssertTrue(person.interrupted(target, since: 1000)); XCTAssertFalse(person.interrupted(target, since: 1000.001))
    }
    func testTurnEndedRefusesBeforeTrackingAndClearsDenied() throws {
        agent.ended = true; assertHarnessError(name: "turn_ended") { try self.gate() }; XCTAssertTrue(person.driven().isEmpty)
        agent.ended = false; try gate(); event(); agent.denied = ["/Denied.app"]; person.turnEnded(agent)
        XCTAssertTrue(agent.denied.isEmpty && person.driven().isEmpty); XCTAssertFalse(person.interrupted(target, since: 0))
    }
    func testOneAgentTurnEndKeepsOtherDriversMarks() throws {
        try gate(); let other = AgentSession(key: "two"); try person.gate(agent: other, target: target, stateRead: true); event()
        person.turnEnded(agent); XCTAssertEqual(person.driven(), [target]); XCTAssertTrue(person.interrupted(target, since: 1000))
        person.turnEnded(other); XCTAssertTrue(person.driven().isEmpty)
    }
    func testTargetPIDNamedWindowThenFrontAndStrayUnknownWindow() {
        let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left)!
        event.setIntegerValueField(.eventTargetUnixProcessID, value: 99); XCTAssertEqual(person.targetPID(event), 99)
        event.setIntegerValueField(.eventTargetUnixProcessID, value: 0); event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: 7); owner = 88
        XCTAssertEqual(person.targetPID(event), 88); XCTAssertTrue(person.stray(event, kind: 1, pid: 77))
        owner = 0; XCTAssertEqual(person.targetPID(event), 77); XCTAssertFalse(person.stray(event, kind: 1, pid: 77))
        XCTAssertTrue(person.stray(event, kind: 10, pid: 88)); XCTAssertFalse(person.stray(event, kind: 10, pid: 77))
    }
    func testNoRunLoopInstallsNothing() {
        // The inert watch tests the no-loop guard. Running-loop grant denial is
        // covered by PersonOwnershipTests.testNoGrantAndFailedCreationAreRetryable.
        person.simulatedTapAvailable = false; person.startWatch(ownPID: 4242); XCTAssertFalse(person.tapAvailable)
        XCTAssertEqual(person.ownPID, 4242)
    }
    func testCallbackReadsTagSourceTargetKeyAndReenablesDisabledTap() throws {
        try gate()
        func key(sourcePID: pid_t, tag: Int64) -> CGEvent {
            let source = CGEventSource(stateID: .privateState)!
            source.userData = tag
            let event = CGEvent(keyboardEventSource: source, virtualKey: 48, keyDown: true)!
            event.flags = .maskCommand
            event.setIntegerValueField(.eventTargetUnixProcessID, value: 77)
            event.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(sourcePID))
            return event
        }
        var enabled = 0
        person.onEvent(kind: 10, event: key(sourcePID: 4242, tag: 123), reenable: { enabled += 1 })
        XCTAssertFalse(person.interrupted(target, since: 1000))
        person.onEvent(kind: 10, event: key(sourcePID: 0, tag: Events.ownTag), reenable: { enabled += 1 })
        XCTAssertFalse(person.interrupted(target, since: 1000))
        let stranger = key(sourcePID: 0, tag: 123)
        person.onEvent(kind: 10, event: stranger, reenable: { enabled += 1 })
        XCTAssertTrue(person.interrupted(target, since: 1000)); XCTAssertTrue(person.wentTo(77, since: 1000))
        person.onEvent(kind: UInt32.max, event: stranger, reenable: { enabled += 1 })
        XCTAssertEqual(enabled, 1)
    }
    func testSecureInputOwnerFromSessionDictionary() {
        XCTAssertNil(Person.secureInputPID(session: [:]))
        XCTAssertEqual(Person.secureInputPID(session: ["kCGSSessionSecureInputPID": 99]), 99)
    }

}
