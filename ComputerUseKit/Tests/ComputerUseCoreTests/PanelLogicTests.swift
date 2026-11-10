import XCTest

@testable import ComputerUseCore

final class PanelLogicTests: XCTestCase {
    func testAnswerIsOnceAndByIdentity() {
        let queue = AskQueue()
        var answers: [String] = []
        let a = Ask(title: "Same", choices: ["Yes", "No"]) { answers.append($0) }
        let b = Ask(title: "Same", choices: ["Yes"]) { answers.append("b:" + $0) }
        queue.append(a)
        queue.append(b)
        queue.answer(a, choice: "invalid")
        XCTAssertEqual(queue.asks.count, 2)
        queue.answer(a, choice: "Yes")
        queue.answer(a, choice: "No")
        XCTAssertEqual(answers, ["Yes"])
        XCTAssertTrue(queue.asks[0] === b)
    }
    func testWithdrawalNeverAnswersAndRemovesMatchingTitles() {
        let queue = AskQueue()
        var answers = 0
        queue.append(Ask(title: "a", choices: ["Yes"]) { _ in answers += 1 })
        queue.append(Ask(title: "b", choices: []) { _ in answers += 1 })
        queue.append(Ask(title: "a", choices: []) { _ in answers += 1 })
        queue.withdraw(title: "a")
        XCTAssertEqual(queue.asks.map(\.title), ["b"])
        XCTAssertEqual(answers, 0)
    }
    func testReentrantAnswerRemovesBeforeCallback() {
        let queue = AskQueue()
        var count = 0
        var a: Ask!
        a = Ask(title: "a", choices: ["yes"]) { _ in
            count += 1
            queue.answer(a, choice: "yes")
        }
        queue.append(a)
        queue.answer(a, choice: "yes")
        XCTAssertEqual(count, 1)
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
