import ComputerUseCore
import XCTest
import os

@testable import ComputerUseSystem

// Every UI/output dependency is explicit, including fail-fast unused paths.
// No test uses Overlay.shared, Panel.shared or the production scheduler.
private func presence(
    enabled: @escaping @Sendable () -> Bool = { true },
    now: @escaping @Sendable () -> Double = { 1 },
    send: @escaping @Sendable (OverlayCommand) -> Void = { _ in XCTFail("Unexpected overlay") },
    schedule: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = { _ in XCTFail("Unexpected schedule") },
    ask: @escaping @Sendable (Ask) -> Void = { _ in XCTFail("Unexpected question") },
    withdraw: @escaping @Sendable (String) -> Void = { _ in XCTFail("Unexpected withdrawal") }
) -> Presence {
    Presence(enabled: enabled, now: now, send: send, schedule: schedule, ask: ask, withdraw: withdraw)
}

final class PresenceTests: XCTestCase {
    func testSwitchValues() {
        for value in ["0", "false", "no", "off", "FALSE", "OFF"] {
            XCTAssertFalse(Overlay.enabled(environment: ["TERM_LLM_COMPUTER_POINTER": value]))
        }
        for value in ["", "1", "true", "yes", "on", " false "] {
            XCTAssertTrue(Overlay.enabled(environment: ["TERM_LLM_COMPUTER_POINTER": value]))
        }
    }
    func testEveryActionHandsOverItsWindowAndFrame() {
        let commands = OSAllocatedUnfairLock<[OverlayCommand]>(initialState: [])
        let p = presence(
            send: { command in commands.withLock { $0.append(command) } }, schedule: { $0() }, ask: { _ in }, withdraw: { _ in })
        let window = WindowRef(
            element: UIElementRef(NSObject()), windowID: 7, pid: 42, title: nil,
            frame: CGRect(x: 10, y: 20, width: 300, height: 200))
        XCTAssertTrue(p.pointerMove(CGPoint(x: 50, y: 60), window: window))
        p.pointerPress(count: 2)
        p.pointerActivity("loading")
        p.flash(CGRect(x: 30, y: 40, width: 10, height: 20), window: window)
        p.halo(window)
        p.turnDone()
        let seen = commands.withLock { $0 }
        XCTAssertEqual(seen.count, 6)
        if case .move(let point, let pid, let id, let animate) = seen[0] {
            XCTAssertEqual(point, CGPoint(x: 50, y: 60))
            XCTAssertEqual(pid, 42)
            XCTAssertEqual(id, 7)
            XCTAssertTrue(animate)
        } else {
            XCTFail()
        }
        if case .flash(_, let within, let pid, let id) = seen[3] {
            XCTAssertEqual(within, window.frame)
            XCTAssertEqual(pid, 42)
            XCTAssertEqual(id, 7)
        } else {
            XCTFail()
        }
        if case .done = seen.last! {} else { XCTFail() }
    }
    func testOffDoesNotScheduleOrSendAnything() {
        let count = OSAllocatedUnfairLock(initialState: 0)
        let p = presence(
            enabled: { false }, send: { _ in count.withLock { $0 += 1 } }, schedule: { _ in count.withLock { $0 += 1 } },
            ask: { _ in count.withLock { $0 += 1 } }, withdraw: { _ in count.withLock { $0 += 1 } })
        XCTAssertFalse(p.pointerMove(.zero))
        XCTAssertFalse(p.pointerPress())
        XCTAssertFalse(p.pointerActivity("paused"))
        XCTAssertFalse(p.flash(.zero))
        XCTAssertFalse(p.halo(nil))
        XCTAssertFalse(p.liveView(nil))
        XCTAssertFalse(p.turnDone())
        XCTAssertFalse(p.ask(title: "a", choices: ["yes"], onAnswer: { _ in }))
        XCTAssertFalse(p.withdraw(title: "a"))
        XCTAssertEqual(count.withLock { $0 }, 0)
    }
    func testPauseSuppressesIdleAndLoadingUntilPersonWindowEnds() {
        let time = OSAllocatedUnfairLock(initialState: 1.0)
        let seen = OSAllocatedUnfairLock<[String]>(initialState: [])
        let p = presence(now: { time.withLock { $0 } }, send: { if case .activity(let s) = $0 { seen.withLock { $0.append(s) } } })
        p.pointerActivity("paused")
        time.withLock { $0 = 5.74 }
        p.pointerActivity("idle")
        p.pointerActivity("loading")
        XCTAssertEqual(seen.withLock { $0 }, ["paused"])
        time.withLock { $0 = 5.75 }
        p.pointerActivity("loading")
        XCTAssertEqual(seen.withLock { $0 }, ["paused", "loading"])
    }
    func testTurnDoneClearsPauseButKeepsQuestions() {
        let seen = OSAllocatedUnfairLock<[String]>(initialState: [])
        let questions = AskQueue()
        let p = presence(
            now: { 1 }, send: { if case .activity(let s) = $0 { seen.withLock { $0.append(s) } } },
            schedule: { $0() },
            ask: { questions.append($0) }, withdraw: { questions.withdraw(title: $0) })
        p.ask(title: "a", choices: ["yes"], onAnswer: { _ in })
        p.pointerActivity("paused")
        p.turnDone()
        p.pointerActivity("idle")
        XCTAssertEqual(seen.withLock { $0 }, ["paused", "idle"])
        XCTAssertEqual(questions.asks.count, 1)
    }
    func testAsksAreQueuedWithoutWaitingAndWithdrawnUnanswered() {
        let pending = OSAllocatedUnfairLock<[@Sendable () -> Void]>(initialState: [])
        let answers = OSAllocatedUnfairLock<[String]>(initialState: [])
        let questions = AskQueue()
        let p = presence(
            send: { _ in }, schedule: { work in pending.withLock { $0.append(work) } }, ask: { questions.append($0) },
            withdraw: { questions.withdraw(title: $0) })
        XCTAssertTrue(p.ask(title: "a", choices: ["yes"]) { choice in answers.withLock { $0.append(choice) } })
        XCTAssertTrue(questions.asks.isEmpty)
        pending.withLock { $0.removeFirst() }()
        let ask = questions.asks[0]
        questions.answer(ask, choice: "yes")
        questions.answer(ask, choice: "yes")
        XCTAssertEqual(answers.withLock { $0 }, ["yes"])
        p.ask(title: "b", choices: ["yes"]) { choice in answers.withLock { $0.append(choice) } }
        pending.withLock { $0.removeFirst() }()
        p.withdraw(title: "b")
        pending.withLock { $0.removeFirst() }()
        XCTAssertTrue(questions.asks.isEmpty)
        XCTAssertEqual(answers.withLock { $0 }, ["yes"])
    }
    func testNilWindowAndLiveViewAreNoOpsAndInvalidInputsDoNotReachDrawing() {
        let count = OSAllocatedUnfairLock(initialState: 0)
        let p = presence(send: { _ in count.withLock { $0 += 1 } })
        XCTAssertTrue(p.halo(nil))
        XCTAssertTrue(p.liveView(nil))
        XCTAssertFalse(p.pointerMove(CGPoint(x: Double.nan, y: 0)))
        XCTAssertFalse(p.pointerPress(count: 0))
        XCTAssertFalse(p.pointerActivity("unknown"))
        XCTAssertEqual(count.withLock { $0 }, 0)
    }
    func testCallsDoNotWaitForScheduledUI() {
        let scheduled = OSAllocatedUnfairLock(initialState: 0)
        let p = presence(send: { _ in }, schedule: { _ in scheduled.withLock { $0 += 1 } }, ask: { _ in XCTFail() })
        for _ in 0..<100 {
            XCTAssertTrue(p.ask(title: "test", choices: ["yes"], onAnswer: { _ in }))
        }
        XCTAssertEqual(scheduled.withLock { $0 }, 100)
    }
    func testEscGateIgnoresOwnEvents() {
        XCTAssertTrue(ActivityBanner.isStopKey(code: 53, tag: 0))
        XCTAssertFalse(ActivityBanner.isStopKey(code: 53, tag: Events.ownTag))
        XCTAssertFalse(ActivityBanner.isStopKey(code: 12, tag: 0))
    }
    func testPressTransformKeepsAnchorFixed() {
        let p = Pointer.pressAnchor
        let transform = Overlay.transform(shape: Pointer.rest, press: 0.881)
        let affine = CATransform3DGetAffineTransform(transform)
        let got = p.applying(affine)
        XCTAssertEqual(got.x, p.x, accuracy: 1e-9)
        XCTAssertEqual(got.y, p.y, accuracy: 1e-9)
    }
    func testClockCanReenterPauseStateWithoutDeadlock() {
        let owner = OSAllocatedUnfairLock<Presence?>(initialState: nil)
        let seen = OSAllocatedUnfairLock<[String]>(initialState: [])
        let p = presence(now: {
            // This used to deadlock: pointerActivity held its lock across now().
            owner.withLock { $0 }?.turnDone()
            return 10
        }, send: { command in
            if case .activity(let activity) = command { seen.withLock { $0.append(activity) } }
        })
        owner.withLock { $0 = p }
        defer { owner.withLock { $0 = nil } }
        XCTAssertTrue(p.pointerActivity("paused"))
        XCTAssertTrue(p.pointerActivity("idle"))
        XCTAssertEqual(seen.withLock { $0 }, ["paused", "idle"])
    }

    func testEnabledScheduleShowWithdrawAndSendMayReenter() {
        let owner = OSAllocatedUnfairLock<Presence?>(initialState: nil)
        let enabledOnce = OSAllocatedUnfairLock(initialState: false)
        let sent = OSAllocatedUnfairLock(initialState: 0)
        let drops = OSAllocatedUnfairLock<[String]>(initialState: [])
        let p = presence(enabled: {
            let reenter = enabledOnce.withLock { value in
                if value { return false }; value = true; return true
            }
            if reenter { XCTAssertTrue(owner.withLock { $0 }!.liveView(nil)) }
            return true
        }, send: { _ in
            sent.withLock { $0 += 1 }
            XCTAssertTrue(owner.withLock { $0 }!.halo(nil))
        }, schedule: { work in
            XCTAssertTrue(owner.withLock { $0 }!.pointerPress())
            work()
        }, ask: { question in
            XCTAssertTrue(owner.withLock { $0 }!.withdraw(title: question.title))
        }, withdraw: { title in
            drops.withLock { $0.append(title) }
            XCTAssertTrue(owner.withLock { $0 }!.turnDone())
        })
        owner.withLock { $0 = p }
        defer { owner.withLock { $0 = nil } }
        XCTAssertTrue(p.ask(title: "reenter", choices: ["yes"], onAnswer: { _ in XCTFail("No answer") }))
        XCTAssertEqual(drops.withLock { $0 }, ["reenter"])
        XCTAssertEqual(sent.withLock { $0 }, 3)
    }

    func testSharedPresenceKeepsPauseAndScheduledQuestionsAcrossWorkers() {
        let activities = OSAllocatedUnfairLock<[String]>(initialState: [])
        let pending = OSAllocatedUnfairLock<[@Sendable () -> Void]>(initialState: [])
        let questions = AskQueue()
        let p = presence(now: { 100 }, send: { command in
            if case .activity(let activity) = command { activities.withLock { $0.append(activity) } }
        }, schedule: { work in pending.withLock { $0.append(work) } },
            ask: { questions.append($0) }, withdraw: { questions.withdraw(title: $0) })
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            XCTAssertTrue(p.pointerActivity("paused"))
            XCTAssertTrue(p.pointerActivity("loading"))
            XCTAssertTrue(p.ask(title: "q\(index)", choices: ["yes"], onAnswer: { _ in XCTFail("No answer") }))
        }
        XCTAssertEqual(activities.withLock { $0 }, Array(repeating: "paused", count: 100))
        XCTAssertTrue(questions.asks.isEmpty)
        let work = pending.withLock { pending in let work = pending; pending.removeAll(); return work }
        for run in work { run() }
        XCTAssertEqual(questions.asks.count, 100)
        p.turnDone()
        p.pointerActivity("idle")
        XCTAssertEqual(activities.withLock { $0.last }, "idle")
        XCTAssertEqual(questions.asks.count, 100)
    }

    func testDelayedOlderPauseSampleCannotShortenNewerPause() {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let done = DispatchGroup()
        let samples = OSAllocatedUnfairLock(initialState: 0)
        let activities = OSAllocatedUnfairLock<[String]>(initialState: [])
        let p = presence(now: {
            let index = samples.withLock { $0 += 1; return $0 }
            if index == 1 {
                entered.signal()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
                return 1
            }
            return index == 2 ? 10 : (index == 3 ? 12 : 14.75)
        }, send: { command in
            if case .activity(let activity) = command { activities.withLock { $0.append(activity) } }
        })
        done.enter()
        DispatchQueue.global().async { p.pointerActivity("paused"); done.leave() }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        p.pointerActivity("paused")
        release.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        p.pointerActivity("loading")
        XCTAssertEqual(activities.withLock { $0 }, ["paused", "paused"])
        p.pointerActivity("loading")
        XCTAssertEqual(activities.withLock { $0 }, ["paused", "paused", "loading"])
    }

}
