import os
import XCTest

@testable import ComputerUseCore

final class PanelLogicTests: XCTestCase {
    func testAnswerIsOnceAndByIdentity() {
        let queue = AskQueue()
        let answers = OSAllocatedUnfairLock<[String]>(initialState: [])
        let a = Ask(title: "Same", choices: ["Yes", "No"]) { choice in answers.withLock { $0.append(choice) } }
        let b = Ask(title: "Same", choices: ["Yes"]) { choice in answers.withLock { $0.append("b:" + choice) } }
        queue.append(a)
        queue.append(b)
        queue.answer(a, choice: "invalid")
        XCTAssertEqual(queue.asks.count, 2)
        queue.answer(a, choice: "Yes")
        queue.answer(a, choice: "No")
        XCTAssertEqual(answers.withLock { $0 }, ["Yes"])
        XCTAssertTrue(queue.asks[0] === b)
    }
    func testWithdrawalNeverAnswersAndRemovesMatchingTitles() {
        let queue = AskQueue()
        let answers = OSAllocatedUnfairLock(initialState: 0)
        queue.append(Ask(title: "a", choices: ["Yes"]) { _ in answers.withLock { $0 += 1 } })
        queue.append(Ask(title: "b", choices: []) { _ in answers.withLock { $0 += 1 } })
        queue.append(Ask(title: "a", choices: []) { _ in answers.withLock { $0 += 1 } })
        queue.withdraw(title: "a")
        XCTAssertEqual(queue.asks.map(\.title), ["b"])
        XCTAssertEqual(answers.withLock { $0 }, 0)
    }
    func testReentrantAnswerRemovesBeforeCallback() {
        let queue = AskQueue()
        let count = OSAllocatedUnfairLock(initialState: 0)
        let asked = OSAllocatedUnfairLock<Ask?>(initialState: nil)
        let a = Ask(title: "a", choices: ["yes"]) { _ in
            count.withLock { $0 += 1 }
            if let a = asked.withLock({ $0 }) { queue.answer(a, choice: "yes") }
        }
        asked.withLock { $0 = a }
        queue.append(a)
        queue.answer(a, choice: "yes")
        asked.withLock { $0 = nil } // Break the test callback's reference cycle.
        XCTAssertEqual(count.withLock { $0 }, 1)
    }
    func testConcurrentAnswersInvokeCallbackOnceOutsideTheQueueLock() {
        let queue = AskQueue()
        let count = OSAllocatedUnfairLock(initialState: 0)
        let ask = Ask(title: "Concurrent", choices: ["yes"]) { _ in
            count.withLock { $0 += 1 }
            // This would deadlock if answer invoked the callback under its lock.
            queue.append(Ask(title: "Next", choices: [], onAnswer: { _ in }))
        }
        queue.append(ask)
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            queue.answer(ask, choice: "yes")
        }
        XCTAssertEqual(count.withLock { $0 }, 1)
        XCTAssertEqual(queue.asks.map(\.title), ["Next"])
    }
    func testPanelOrigin() {
        XCTAssertEqual(PanelGeometry.width, 340)
        XCTAssertEqual(PanelGeometry.margin, 16)
        XCTAssertEqual(
            PanelGeometry.origin(
                size: CGSize(width: 340, height: 120),
                visible: CGRect(x: 0, y: 0, width: 1440, height: 877)
            ), CGPoint(x: 1084, y: 741))
        XCTAssertEqual(
            PanelGeometry.origin(
                size: CGSize(width: 340, height: 120),
                visible: CGRect(x: -1920, y: -180, width: 1920, height: 1080)),
            CGPoint(x: -356, y: 764))
    }
    func testBannerWorkingWindow() {
        var state = ActivityWindow()
        XCTAssertFalse(state.visible(now: 0))
        XCTAssertEqual(state.remaining(now: 0), 0)
        state.update(working: true, now: 1)
        XCTAssertTrue(state.visible(now: 100))
        XCTAssertEqual(state.remaining(now: 100), .infinity)
        state.update(working: false, now: 101)
        XCTAssertTrue(state.visible(now: 103.999))
        XCTAssertFalse(state.visible(now: 104))
        state.update(working: false, now: 105)
        XCTAssertTrue(state.visible(now: 107.999))
        XCTAssertFalse(state.visible(now: 108))
    }
    func testBannerNewWorkCancelsOldExpiry() {
        var state = ActivityWindow()
        state.update(working: true, now: 0)
        state.update(working: false, now: 1)
        state.update(working: true, now: 2)
        XCTAssertTrue(state.visible(now: 10))
        state.update(working: false, now: 11)
        XCTAssertTrue(state.visible(now: 13))
        XCTAssertFalse(state.visible(now: 14))
    }
}
