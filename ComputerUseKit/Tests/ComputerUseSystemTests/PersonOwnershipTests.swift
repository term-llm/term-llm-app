import ComputerUseCore
import Foundation
import os
import XCTest
@testable import ComputerUseSystem

// Pure lifecycle and worker tests: no CGEvent construction, real tap, AX,
// permission preflight, HID query, app lookup, input post, or UI control.
private final class PersonMainQueue: Sendable {
    private let work = OSAllocatedUnfairLock(initialState: [@MainActor @Sendable () -> Void]())
    func append(_ callback: @escaping @MainActor @Sendable () -> Void) { work.withLock { $0.append(callback) } }
    var count: Int { work.withLock { $0.count } }
    @MainActor func drain() {
        while let callback = work.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) { callback() }
    }
}
private final class PersonLifetimeLog: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: [String]())
    func add(_ value: String) { state.withLock { $0.append(value) } }
    var values: [String] { state.withLock { $0 } }
}
@MainActor private final class FakePersonTap: Person.Tap {
    let log: PersonLifetimeLog
    var onInstall: (@MainActor () -> Void)?, onEnable: (@MainActor () -> Void)?, onRemove: (@MainActor () -> Void)?
    init(log: PersonLifetimeLog) { self.log = log }
    func install() { log.add("install"); onInstall?() }
    func enable() { log.add("enable"); onEnable?() }
    func remove() { log.add("remove"); onRemove?() }
    deinit { log.add("deinit") }
}
@MainActor private final class PersonWatchFixture {
    let queue = PersonMainQueue(), log = PersonLifetimeLog()
    var callbacks: [@MainActor @Sendable (Person.Input) -> Void] = []
    var taps: [FakePersonTap] = []
    var onCreate: (@MainActor (FakePersonTap) -> Void)?
    var failCreate = false
    var watch: Person.Watch {
        let queue = queue
        return .init(isRunning: { true }, schedule: { queue.append($0) }, create: { [self] callback in
            log.add("create"); callbacks.append(callback)
            guard !failCreate else { return nil }
            let tap = FakePersonTap(log: log); taps.append(tap); onCreate?(tap); return tap
        })
    }
    func person(canListen: @escaping @Sendable () -> Bool = { true }) -> Person {
        let f = PersonFixture(), s = f.system
        let system = Person.System(now: s.now, sleep: s.sleep, frontmostPID: s.frontmostPID,
                                   bundleOf: s.bundleOf, hidIdle: s.hidIdle, secureInputPID: s.secureInputPID,
                                   windowPID: s.windowPID, canListen: canListen)
        return Person(system: system, hooks: f.hooks, watch: watch)
    }
}
private final class PersonReference: Sendable {
    private struct State: Sendable { weak var value: Person? }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var value: Person? { get { state.withLock { $0.value } } set { state.withLock { $0.value = newValue } } }
}

final class PersonOwnershipTests: XCTestCase {
    private static let target = AppTarget(path: "/Fake/Test.app", bundleID: "dev.test", name: "Test", pid: 77)

    func testDefaultNoRunLoopDoesNotEvenPreflight() {
        XCTAssertFalse(MainThread.isRunning)
        let system = Person.System(canListen: { XCTFail("No permission preflight without run loop"); return true })
        let person = Person(system: system, watch: .init(schedule: { _ in XCTFail("No lifecycle work without run loop") },
                                                        create: { _ in XCTFail("No real tap"); return nil }))
        person.startWatch(ownPID: 4242)
        XCTAssertEqual(person.ownPID, 4242); XCTAssertFalse(person.tapAvailable)
    }

    func testNoGrantAndFailedCreationAreRetryable() async {
        await MainActor.run {
            let f = PersonWatchFixture(), preflights = PersonLifetimeLog()
            let denied = f.person(canListen: { preflights.add("denied"); return false })
            denied.startWatch(ownPID: 4242); f.queue.drain()
            XCTAssertEqual(preflights.values, ["denied"]) // Fake loop is running; the grant gate was reached.
            XCTAssertTrue(f.log.values.isEmpty); XCTAssertFalse(denied.tapAvailable)
            let person = f.person(); f.failCreate = true
            person.startWatch(ownPID: 4242); f.queue.drain()
            XCTAssertFalse(person.tapAvailable); XCTAssertEqual(f.log.values, ["create"])
            f.failCreate = false; person.startWatch(ownPID: 4242); f.queue.drain()
            XCTAssertTrue(person.tapAvailable); XCTAssertEqual(f.log.values, ["create", "create", "install", "enable"])
            person.stopWatch(); f.queue.drain()
        }
    }

    func testIdempotentStartStopAndDisabledDelivery() async throws {
        try await MainActor.run {
            let f = PersonWatchFixture(), person = f.person(), agent = AgentSession(key: "one")
            person.startWatch(ownPID: 4242); person.startWatch(ownPID: 4242); f.queue.drain()
            XCTAssertTrue(person.tapAvailable); XCTAssertEqual(f.log.values, ["create", "install", "enable"])
            try person.gate(agent: agent, target: Self.target, stateRead: true)
            f.callbacks[0](.init(kind: 10, sourcePID: 4242, targetPID: 77))
            f.callbacks[0](.init(kind: 10, tag: Events.ownTag, targetPID: 77))
            XCTAssertFalse(person.interrupted(Self.target, since: 1000))
            f.callbacks[0](.init(kind: UInt32.max)); XCTAssertEqual(f.log.values.last, "enable")
            f.callbacks[0](.init(kind: 10, targetPID: 77, keycode: 48, command: true))
            XCTAssertTrue(person.interrupted(Self.target, since: 1000)); XCTAssertTrue(person.wentTo(77, since: 1000))
            person.stopWatch(); person.stopWatch(); f.queue.drain()
            XCTAssertFalse(person.tapAvailable); XCTAssertEqual(f.log.values.filter { $0 == "remove" }.count, 1)
        }
    }

    func testOldCallbackCannotDeliverOrReenableAfterRestart() async throws {
        try await MainActor.run {
            let f = PersonWatchFixture(), person = f.person(), agent = AgentSession(key: "one")
            try person.gate(agent: agent, target: Self.target, stateRead: true)
            person.startWatch(ownPID: 4242); f.queue.drain()
            let old = f.callbacks[0]
            person.stopWatch(); person.startWatch(ownPID: 4242); f.queue.drain()
            let before = f.log.values
            old(.init(kind: UInt32.max)); old(.init(kind: 1, targetPID: 77))
            XCTAssertEqual(f.log.values, before); XCTAssertFalse(person.interrupted(Self.target, since: 1000))
            f.callbacks[1](.init(kind: 1, targetPID: 77))
            XCTAssertTrue(person.interrupted(Self.target, since: 1000))
            person.stopWatch(); f.queue.drain()
        }
    }

    func testStopReenteredDuringCreateRemovesUninstalledHandleOnce() async {
        await MainActor.run {
            let f = PersonWatchFixture(), person = f.person()
            f.onCreate = { _ in person.stopWatch(); f.queue.drain() }
            person.startWatch(ownPID: 4242); f.queue.drain()
            XCTAssertFalse(person.tapAvailable); XCTAssertEqual(f.log.values, ["create", "remove"])
            f.onCreate = nil
        }
    }

    func testStopReenteredDuringInstallDoesNotEnable() async {
        await MainActor.run {
            let f = PersonWatchFixture(), person = f.person()
            f.onCreate = { tap in tap.onInstall = { person.stopWatch(); f.queue.drain() } }
            person.startWatch(ownPID: 4242); f.queue.drain()
            XCTAssertFalse(person.tapAvailable); XCTAssertEqual(f.log.values, ["create", "install", "remove"])
            f.taps[0].onInstall = nil; f.onCreate = nil
        }
    }

    func testStopReenteredDuringEnableClosesAvailability() async {
        await MainActor.run {
            let f = PersonWatchFixture(), person = f.person()
            f.onCreate = { tap in tap.onEnable = { person.stopWatch(); f.queue.drain() } }
            person.startWatch(ownPID: 4242); f.queue.drain()
            XCTAssertFalse(person.tapAvailable); XCTAssertEqual(f.log.values, ["create", "install", "enable", "remove"])
            f.taps[0].onEnable = nil; f.onCreate = nil
        }
    }

    func testRemoveReenteredWithStartKeepsNewAvailability() async {
        await MainActor.run {
            let f = PersonWatchFixture(), person = f.person()
            person.startWatch(ownPID: 4242); f.queue.drain()
            f.taps[0].onRemove = { person.startWatch(ownPID: 4242); f.queue.drain() }
            person.stopWatch(); f.queue.drain()
            XCTAssertTrue(person.tapAvailable)
            XCTAssertEqual(f.log.values, ["create", "install", "enable", "remove", "create", "install", "enable"])
            f.taps[0].onRemove = nil; person.stopWatch(); f.queue.drain()
        }
    }

    func testPendingStartDoesNotRetainPerson() async {
        await MainActor.run {
            let f = PersonWatchFixture()
            var person: Person? = f.person(); weak var weakPerson = person
            person!.startWatch(ownPID: 4242); person = nil
            XCTAssertNil(weakPerson); weakPerson = nil; f.queue.drain(); XCTAssertTrue(f.log.values.isEmpty)
        }
    }

    func testDeinitRetainsHandleUntilQueuedMainCleanupWithoutRetainingPerson() async {
        await MainActor.run {
            let f = PersonWatchFixture()
            var person: Person? = f.person(); weak var weakPerson = person
            person!.startWatch(ownPID: 4242); f.queue.drain()
            weak var weakTap = f.taps[0]; f.taps.removeAll()
            person = nil
            XCTAssertNil(weakPerson); XCTAssertNotNil(weakTap); XCTAssertEqual(f.queue.count, 1)
            // Callback context may still fire before queued uninstall; the weak
            // owner must reject it without resurrecting the released worker.
            f.callbacks[0](.init(kind: 1, targetPID: 77)); f.callbacks[0](.init(kind: UInt32.max))
            XCTAssertEqual(f.log.values, ["create", "install", "enable"])
            f.queue.drain()
            XCTAssertNil(weakTap); weakTap = nil; weakPerson = nil
            XCTAssertEqual(f.log.values, ["create", "install", "enable", "remove", "deinit"])
        }
    }

    func testLastWorkerReleaseOnlyQueuesMainCleanup() async {
        await MainActor.run {
            let f = PersonWatchFixture()
            var person: Person? = f.person()
            let reference = PersonReference(); reference.value = person
            person!.startWatch(ownPID: 4242); f.queue.drain()
            let holder = OSAllocatedUnfairLock(initialState: person)
            person = nil
            let done = DispatchGroup(); done.enter()
            DispatchQueue.global().async {
                var released = holder.withLock { value in let old = value; value = nil; return old }
                withExtendedLifetime(released) {}
                released = nil // Last strong release is on this worker, outside the holder lock.
                done.leave()
            }
            XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
            XCTAssertNil(reference.value)
            XCTAssertEqual(f.queue.count, 1)
            XCTAssertEqual(f.log.values, ["create", "install", "enable"])
            f.queue.drain()
            XCTAssertEqual(f.log.values, ["create", "install", "enable", "remove"])
        }
    }

    func testCallbacksCanReenterWorkerWithoutAnyStateLockHeld() throws {
        let reference = PersonReference(), f = PersonFixture(), s = f.system
        let log = PersonLifetimeLog()
        let reenter: @Sendable (String) -> Void = { name in
            _ = reference.value?.driven(); _ = reference.value?.tapAvailable; log.add(name)
        }
        let system = Person.System(
            now: { reenter("now"); return s.now() }, sleep: s.sleep,
            frontmostPID: { reenter("front"); return 77 },
            bundleOf: { _ in reenter("bundle"); return "dev.test" },
            hidIdle: { _ in reenter("hid"); return 2 },
            secureInputPID: { reenter("secure"); return nil },
            windowPID: { _ in reenter("window"); return 77 }, canListen: { false })
        let h = f.hooks
        let hooks = Person.Hooks(pointerActivity: { value in reenter(value); h.pointerActivity(value) },
                                 shownMenu: { _ in reenter("menu"); return nil },
                                 post: { _, _ in XCTFail("Pure ownership tests never construct/post escape") },
                                 later: { delay, work in reenter("later"); h.later(delay, work) })
        let person = Person(system: system, hooks: hooks, watch: PersonFixture.inertWatch)
        reference.value = person; person.startWatch(ownPID: 4242); person.simulatedTapAvailable = true
        try person.gate(agent: AgentSession(key: "one"), target: Self.target, stateRead: true)
        person.onInput(.init(kind: 1, window: 7)); person.afterStateRead(Self.target)
        person.touchFromIdleTime(Self.target)
        f.time += 5; let timer = f.state.withLock { $0.timers.removeFirst().1 }; timer()
        XCTAssertTrue(Set(["now", "front", "bundle", "hid", "secure", "window", "paused", "later", "loading"]).isSubset(of: Set(log.values)))
    }

    func testStaleQuietTimerCannotCompleteNewTurn() throws {
        let f = PersonFixture(), person = Person(system: f.system, hooks: f.hooks, watch: PersonFixture.inertWatch), agent = AgentSession(key: "one")
        person.startWatch(ownPID: 4242); person.simulatedTapAvailable = true
        try person.gate(agent: agent, target: Self.target, stateRead: true)
        person.saw(kind: 1, sourcePID: 0, tag: 0, pid: 77)
        let old = f.state.withLock { $0.timers.removeFirst().1 }
        person.turnEnded(agent)
        try person.gate(agent: agent, target: Self.target, stateRead: true)
        person.saw(kind: 1, sourcePID: 0, tag: 0, pid: 77)
        f.time += 5; old()
        XCTAssertEqual(f.state.withLock { $0.activity }, ["paused", "paused"])
        let new = f.state.withLock { $0.timers.removeFirst().1 }; new()
        XCTAssertEqual(f.state.withLock { $0.activity }, ["paused", "paused", "loading"])
    }

    func testQuietTimerResumesLoadingWhenOnlyOneOfTwoDriversEnds() throws {
        let f = PersonFixture(), person = Person(system: f.system, hooks: f.hooks, watch: PersonFixture.inertWatch)
        let first = AgentSession(key: "one"), second = AgentSession(key: "two")
        person.startWatch(ownPID: 4242); person.simulatedTapAvailable = true
        try person.gate(agent: first, target: Self.target, stateRead: true)
        try person.gate(agent: second, target: Self.target, stateRead: true)
        person.saw(kind: 1, sourcePID: 0, tag: 0, pid: 77)
        person.turnEnded(first)
        XCTAssertEqual(person.driven(), [Self.target])
        XCTAssertTrue(person.interrupted(Self.target, since: 1000))
        XCTAssertEqual(f.state.withLock { $0.timers.count }, 1)
        f.time += Person.debounceS
        let timer = f.state.withLock { $0.timers.removeFirst().1 }; timer()
        XCTAssertEqual(f.state.withLock { $0.activity }, ["paused", "loading"])
        XCTAssertTrue(f.state.withLock { $0.timers.isEmpty })
        XCTAssertEqual(person.driven(), [Self.target])
        person.turnEnded(second); XCTAssertTrue(person.driven().isEmpty)
    }

    func testConcurrentWorkersShareOnlyTypedStateAndDoNotLoseDrivers() {
        let f = PersonFixture(), person = Person(system: f.system, hooks: f.hooks, watch: PersonFixture.inertWatch)
        person.startWatch(ownPID: 4242); person.simulatedTapAvailable = true
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            let agent = AgentSession(key: "worker-\(index)")
            let target = AppTarget(path: "/Fake/\(index).app", bundleID: "dev.\(index)", name: "Fake", pid: pid_t(100 + index))
            do { try person.gate(agent: agent, target: target, stateRead: true) }
            catch { XCTFail("Unexpected gate error: \(error)") }
            person.saw(kind: 1, sourcePID: 0, tag: 0, pid: target.pid!)
            XCTAssertTrue(person.interrupted(target, since: 1000))
            person.turnEnded(agent)
        }
        XCTAssertTrue(person.driven().isEmpty); XCTAssertTrue(person.quietAt.isEmpty)
        let timers = f.state.withLock { $0.timers }; timers.forEach { $0.1() }
        XCTAssertEqual(f.state.withLock { $0.activity.filter { $0 == "loading" }.count }, 0)
    }

    func testDelayedOlderDockAndCommandTabSamplesCannotOverwriteNewerSwitch() {
        for olderIsDock in [false, true] {
            let f = PersonFixture(), block = OSAllocatedUnfairLock(initialState: false)
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), done = DispatchGroup()
            f.state.withLock { $0.bundles[9] = Person.dock }
            let s = f.system
            let system = Person.System(now: {
                let sampled = f.time
                if block.withLock({ flag in let old = flag; flag = false; return old }) {
                    entered.signal(); _ = release.wait(timeout: .now() + 5)
                }
                return sampled
            }, sleep: s.sleep, frontmostPID: s.frontmostPID, bundleOf: s.bundleOf, hidIdle: s.hidIdle,
                                       secureInputPID: s.secureInputPID, windowPID: s.windowPID, canListen: { false })
            let person = Person(system: system, hooks: f.hooks, watch: PersonFixture.inertWatch)
            person.startWatch(ownPID: 4242); person.simulatedTapAvailable = true
            block.withLock { $0 = true }; done.enter()
            DispatchQueue.global().async {
                person.saw(kind: olderIsDock ? 1 : 10, sourcePID: 0, tag: 0,
                           pid: olderIsDock ? 9 : 77, keycode: 48, command: true)
                done.leave()
            }
            XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
            f.time = 1003
            person.saw(kind: olderIsDock ? 10 : 1, sourcePID: 0, tag: 0,
                       pid: olderIsDock ? 77 : 9, keycode: 48, command: true)
            release.signal(); XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
            XCTAssertTrue(person.wentTo(77, since: 1003))
            XCTAssertFalse(person.wentTo(77, since: 1003.001))
        }
    }

    func testDelayedOlderClickCannotShortenQuietOrOverwriteNewerClick() throws {
        let f = PersonFixture(), block = OSAllocatedUnfairLock(initialState: false)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), done = DispatchGroup()
        let s = f.system
        let system = Person.System(now: {
            let sampled = f.time
            if block.withLock({ flag in let old = flag; flag = false; return old }) {
                entered.signal(); _ = release.wait(timeout: .now() + 5)
            }
            return sampled
        }, sleep: s.sleep, frontmostPID: s.frontmostPID, bundleOf: s.bundleOf, hidIdle: s.hidIdle,
                                   secureInputPID: s.secureInputPID, windowPID: s.windowPID, canListen: { false })
        let person = Person(system: system, hooks: f.hooks, watch: PersonFixture.inertWatch)
        person.startWatch(ownPID: 4242); person.simulatedTapAvailable = true
        try person.gate(agent: AgentSession(key: "one"), target: Self.target, stateRead: true)
        f.state.withLock { $0.bundles[88] = Self.target.bundleID }
        block.withLock { $0 = true }; done.enter()
        DispatchQueue.global().async { person.saw(kind: 1, sourcePID: 0, tag: 0, pid: 88); done.leave() }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        f.time = 1003; person.saw(kind: 1, sourcePID: 0, tag: 0, pid: 77)
        release.signal(); XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(person.quietAt[Self.target.path], 1008)
        XCTAssertTrue(person.wentTo(77, since: 1003))
        XCTAssertFalse(person.wentTo(88, since: 1000))
    }
}
