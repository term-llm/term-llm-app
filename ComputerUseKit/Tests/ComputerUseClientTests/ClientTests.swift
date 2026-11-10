import Darwin
import XCTest

@testable import ComputerUseClient

final class ClientTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = URL(fileURLWithPath: "/tmp").appendingPathComponent("cuc-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        setenv("TERM_LLM_COMPUTER_HOME", folder.path, 1)
        setenv("TERM_LLM_COMPUTER_SOCKET", folder.appendingPathComponent("helper.sock").path, 1)
    }

    override func tearDown() {
        unsetenv("TERM_LLM_COMPUTER_HOME")
        unsetenv("TERM_LLM_COMPUTER_SOCKET")
        try? FileManager.default.removeItem(at: folder)
    }

    /// term-llm sends turn boundaries at every turn: with Computer Use enabled
    /// but no helper listening they succeed at once and never open the app.
    func testTurnBoundaryWithoutHelperSucceedsWithoutLaunching() throws {
        try Data().write(to: folder.appendingPathComponent("enabled"))
        let began = Date()
        XCTAssertEqual(ComputerUseClient.main(["term-llm-computer", "turn-started"]), 0)
        XCTAssertEqual(ComputerUseClient.main(["term-llm-computer", "turn-ended", "--cancel"]), 0)
        XCTAssertLessThan(Date().timeIntervalSince(began), 1, "a turn boundary waited for an app launch")
    }

    func testToolCallWithoutHelperOrSettingFails() {
        XCTAssertEqual(ComputerUseClient.main(["term-llm-computer", "list_apps"]), 1)
    }

    func testOnlyTurnCommandsAreBoundaries() {
        XCTAssertTrue(ComputerUseClient.turnBoundary(["turn-started"]))
        XCTAssertTrue(ComputerUseClient.turnBoundary(["turn-ended", "--cancel"]))
        XCTAssertFalse(ComputerUseClient.turnBoundary(["get_app_state", "--app", "turn-ended"]))
        XCTAssertFalse(ComputerUseClient.turnBoundary([]))
    }
}
