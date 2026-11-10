import os
import XCTest
@testable import ComputerUseSystem

final class SystemTests: XCTestCase {
    func testMainThreadRunsInlineWithoutLoop() {
        let ran = OSAllocatedUnfairLock(initialState: false)
        MainThread.onMain { ran.withLock { $0 = true } }
        XCTAssertTrue(ran.withLock { $0 })
    }
}
