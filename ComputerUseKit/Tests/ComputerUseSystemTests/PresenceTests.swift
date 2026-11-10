import ComputerUseCore
import XCTest
import os

@testable import ComputerUseSystem

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
        var seen: [OverlayCommand] = []
        let p = Presence(
            send: { seen.append($0) }, schedule: { $0() }, ask: { _ in }, withdraw: { _ in })
        let window = WindowRef(
            element: UIElementRef(NSObject()), windowID: 7, pid: 42, title: nil,
            frame: CGRect(x: 10, y: 20, width: 300, height: 200))
        XCTAssertTrue(p.pointerMove(CGPoint(x: 50, y: 60), window: window))
        p.pointerPress(count: 2)
        p.pointerActivity("loading")
        p.flash(CGRect(x: 30, y: 40, width: 10, height: 20), window: window)
        p.halo(window)
        p.turnDone()
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
        var count = 0
        let p = Presence(
            enabled: { false }, send: { _ in count += 1 }, schedule: { _ in count += 1 },
            ask: { _ in count += 1 }, withdraw: { _ in count += 1 })
        XCTAssertFalse(p.pointerMove(.zero))
        XCTAssertFalse(p.pointerPress())
        XCTAssertFalse(p.pointerActivity("paused"))
        XCTAssertFalse(p.flash(.zero))
        XCTAssertFalse(p.halo(nil))
        XCTAssertFalse(p.liveView(nil))
        XCTAssertFalse(p.turnDone())
        XCTAssertFalse(p.ask(title: "a", choices: ["yes"], onAnswer: { _ in }))
        XCTAssertFalse(p.withdraw(title: "a"))
        XCTAssertEqual(count, 0)
    }
    func testPauseSuppressesIdleAndLoadingUntilPersonWindowEnds() {
        var time = 1.0
        var seen: [String] = []
        let p = Presence(now: { time }, send: { if case .activity(let s) = $0 { seen.append(s) } })
        p.pointerActivity("paused")
        time = 5.74
        p.pointerActivity("idle")
        p.pointerActivity("loading")
        XCTAssertEqual(seen, ["paused"])
        time = 5.75
        p.pointerActivity("loading")
        XCTAssertEqual(seen, ["paused", "loading"])
    }
    func testTurnDoneClearsPauseButKeepsQuestions() {
        var seen: [String] = []
        let questions = AskQueue()
        let p = Presence(
            now: { 1 }, send: { if case .activity(let s) = $0 { seen.append(s) } },
            schedule: { $0() },
            ask: { questions.append($0) }, withdraw: { questions.withdraw(title: $0) })
        p.ask(title: "a", choices: ["yes"], onAnswer: { _ in })
        p.pointerActivity("paused")
        p.turnDone()
        p.pointerActivity("idle")
        XCTAssertEqual(seen, ["paused", "idle"])
        XCTAssertEqual(questions.asks.count, 1)
    }
    func testAsksAreQueuedWithoutWaitingAndWithdrawnUnanswered() {
        var pending: [() -> Void] = []
        let answers = OSAllocatedUnfairLock<[String]>(initialState: [])
        let questions = AskQueue()
        let p = Presence(
            send: { _ in }, schedule: { pending.append($0) }, ask: { questions.append($0) },
            withdraw: { questions.withdraw(title: $0) })
        XCTAssertTrue(p.ask(title: "a", choices: ["yes"]) { choice in answers.withLock { $0.append(choice) } })
        XCTAssertTrue(questions.asks.isEmpty)
        pending.removeFirst()()
        let ask = questions.asks[0]
        questions.answer(ask, choice: "yes")
        questions.answer(ask, choice: "yes")
        XCTAssertEqual(answers.withLock { $0 }, ["yes"])
        p.ask(title: "b", choices: ["yes"]) { choice in answers.withLock { $0.append(choice) } }
        pending.removeFirst()()
        p.withdraw(title: "b")
        pending.removeFirst()()
        XCTAssertTrue(questions.asks.isEmpty)
        XCTAssertEqual(answers.withLock { $0 }, ["yes"])
    }
    func testNilWindowAndLiveViewAreNoOpsAndInvalidInputsDoNotReachDrawing() {
        var count = 0
        let p = Presence(send: { _ in count += 1 })
        XCTAssertTrue(p.halo(nil))
        XCTAssertTrue(p.liveView(nil))
        XCTAssertFalse(p.pointerMove(CGPoint(x: Double.nan, y: 0)))
        XCTAssertFalse(p.pointerPress(count: 0))
        XCTAssertFalse(p.pointerActivity("unknown"))
        XCTAssertEqual(count, 0)
    }
    func testCallsDoNotWaitForScheduledUI() {
        var scheduled = 0
        let p = Presence(send: { _ in }, schedule: { _ in scheduled += 1 }, ask: { _ in XCTFail() })
        for _ in 0..<100 {
            XCTAssertTrue(p.ask(title: "test", choices: ["yes"], onAnswer: { _ in }))
        }
        XCTAssertEqual(scheduled, 100)
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
}
