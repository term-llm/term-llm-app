import XCTest
@testable import ComputerUseCore

final class ReadGoldenTests: XCTestCase {
    func testEveryTreeFixtureByteIdentical() throws {
        let paths = try fixtureNames("trees", "json")
        XCTAssertEqual(paths.count, 5)
        for path in paths {
            let name = path.deletingPathExtension().lastPathComponent
            let actual = try captureText(FakeApp.load(name).read())
            let expected = try Data(contentsOf: path.deletingPathExtension().appendingPathExtension("txt"))
            XCTAssertEqual(Data(actual.utf8), expected, name)
        }
    }
    func testEveryDiffScenarioByteIdentical() throws {
        let paths = try fixtureNames("diffs", "txt")
        XCTAssertEqual(paths.count, 11)
        for path in paths { try replay(path.deletingPathExtension().lastPathComponent) }
    }
}
