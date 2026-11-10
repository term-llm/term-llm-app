import XCTest
@testable import ComputerUseSystem

final class SystemTests: XCTestCase {
    func testMainThreadRunsInlineWithoutLoop() {
        var ran = false
        MainThread.onMain { ran = true }
        XCTAssertTrue(ran)
    }
}
