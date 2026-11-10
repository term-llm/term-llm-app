import XCTest
@testable import ComputerUseHelper

final class HelperTests: XCTestCase {
    func testVersion() { XCTAssertFalse(ComputerUseHelperInfo.version.isEmpty) }
}
