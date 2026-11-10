import XCTest
@testable import ComputerUseCore

final class WireTests: XCTestCase {
    func testFrameRoundTripOverSocketPair() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        let message = Wire.request(argv: ["get_app_state", "--app", "Finder"], stdin: nil, cwd: "/",
                                   env: ["HOME": "/Users/x", "TERM_LLM_HUB_TOKEN": "secret",
                                         "TERM_LLM_SESSION_ID": "s1"],
                                   deadline: 1000, version: "t")
        try Wire.write(message, to: fds[0])
        let read = try Wire.read(from: fds[1], deadline: Date().addingTimeInterval(2))
        let params = try XCTUnwrap(read["params"] as? [String: Any])
        XCTAssertEqual(params["argv"] as? [String], ["get_app_state", "--app", "Finder"])
        XCTAssertEqual(params["env"] as? [String: String], ["HOME": "/Users/x", "TERM_LLM_SESSION_ID": "s1"])
        XCTAssertEqual(params["callerApi"] as? String, Limits.apiVersion)
    }

    func testClosedPeerIsReported() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        close(fds[0])
        defer { close(fds[1]) }
        XCTAssertThrowsError(try Wire.read(from: fds[1], deadline: Date().addingTimeInterval(1))) {
            XCTAssertEqual($0 as? WireError, .closed)
        }
    }

    func testErrorTexts() {
        let error = Errors.make("not_active", ["app": "TextEdit"])
        XCTAssertEqual(error.code, 112)
        XCTAssertTrue(error.message.contains("term-llm Computer Use action needs that read"))
        XCTAssertEqual(Errors.make("stale_element").tag, "invalid_element_id")
        XCTAssertEqual(Errors.make("stale_element").code, 100)
        XCTAssertTrue(Errors.make("user_changed", ["app_path": "/A.app"]).cancelled)
        XCTAssertEqual(pythonRepr("it's"), "\"it's\"")
        XCTAssertEqual(pythonRepr("a"), "'a'")
        XCTAssertEqual(pythonFloat(3), "3.0")
        XCTAssertEqual(pythonFloat(2.5), "2.5")
    }
}
