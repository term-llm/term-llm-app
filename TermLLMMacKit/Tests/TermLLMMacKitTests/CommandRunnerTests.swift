import Darwin
import XCTest
@testable import TermLLMMacKit

final class CommandRunnerTests: XCTestCase {
    func testLargeStdoutAndStderrAreDrainedAndCapped() throws {
        let start = ContinuousClock.now
        let result = try runShell("""
        /usr/bin/head -c 3145728 /dev/zero &
        /usr/bin/head -c 3145728 /dev/zero >&2 &
        wait
        """, timeout: 3)

        XCTAssertEqual(result.status, 0)
        for output in [result.stdout, result.stderr] {
            XCTAssertTrue(output.hasPrefix(String(repeating: "\0", count: 1024)))
            XCTAssertTrue(output.hasSuffix("\n[output truncated after 2097152 bytes]\n"))
            XCTAssertEqual(output.utf8.count,
                           2 * 1024 * 1024 + "\n[output truncated after 2097152 bytes]\n".utf8.count)
        }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(3))
    }

    func testDescendantHoldingBothPipesDoesNotDelayChildResult() throws {
        let start = ContinuousClock.now
        let result = try runShell("/bin/sleep 5 & echo $!; echo hi; echo diagnostic >&2", timeout: 2)
        // Do not leave the fixture's intentionally surviving descendant around.
        let pid = try XCTUnwrap(Int32(result.stdout.split(separator: "\n").first.map(String.init) ?? ""))
        defer { kill(pid, SIGKILL) }

        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stdout.hasSuffix("\nhi\n"))
        XCTAssertEqual(result.stderr, "diagnostic\n")
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
    }

    func testContinuouslyWritingDescendantsDoNotDelaySuccessfulExit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pidFile = directory.appendingPathComponent("descendant.pid")
        defer {
            // Persist the PIDs separately so teardown also works if run throws
            // or output is truncated before the PIDs reach the result.
            if let contents = try? String(contentsOf: pidFile, encoding: .utf8) {
                for value in contents.split(whereSeparator: \.isWhitespace) {
                    if let pid = Int32(value), pid > 0 { kill(pid, SIGKILL) }
                }
            }
            try? FileManager.default.removeItem(at: directory)
        }

        let start = ContinuousClock.now
        let result = try ProcessCommandRunner().run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", """
            echo done
            echo diagnostic >&2
            /usr/bin/yes x &
            echo $! > "$COMMAND_RUNNER_TEST_PID_FILE"
            /usr/bin/yes y >&2 &
            echo $! >> "$COMMAND_RUNNER_TEST_PID_FILE"
            /bin/sleep 0.05
            """],
            environment: ["COMMAND_RUNNER_TEST_PID_FILE": pidFile.path], timeout: 2
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stdout.hasPrefix("done\n"))
        XCTAssertTrue(result.stderr.hasPrefix("diagnostic\n"))
        XCTAssertTrue(result.stdout.contains("x\n"))
        XCTAssertTrue(result.stderr.contains("y\n"))
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
        let pids = try String(contentsOf: pidFile, encoding: .utf8)
            .split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
        XCTAssertEqual(pids.count, 2)
    }

    func testTimeoutStillAppliesAfterBothPipesClose() {
        let start = ContinuousClock.now
        XCTAssertThrowsError(try runShell("exec 1>&- 2>&-; exec /bin/sleep 5", timeout: 0.15)) { error in
            XCTAssertEqual(error as? CommandError, .timedOut(seconds: 0.15))
        }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
    }

    func testTimeoutEscalatesWhenChildIgnoresTermination() {
        let start = ContinuousClock.now
        XCTAssertThrowsError(try runShell("trap '' TERM; while :; do :; done", timeout: 0.15)) { error in
            XCTAssertEqual(error as? CommandError, .timedOut(seconds: 0.15))
        }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
    }

    func testTimeoutWhileOutputIsContinuouslyReadable() {
        let start = ContinuousClock.now
        XCTAssertThrowsError(try runShell("exec /usr/bin/yes", timeout: 0.15)) { error in
            XCTAssertEqual(error as? CommandError, .timedOut(seconds: 0.15))
        }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
    }

    func testCancellationStopsRunningCommand() {
        let finished = expectation(description: "cancelled runner returned")
        let task = Task.detached {
            defer { finished.fulfill() }
            do {
                _ = try ProcessCommandRunner().run(executable: URL(fileURLWithPath: "/bin/sleep"),
                                                   arguments: ["5"], timeout: 5)
                XCTFail("Expected cancellation")
            } catch is CancellationError {
                // Expected, whether cancelled before launch or during polling.
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        Thread.sleep(forTimeInterval: 0.1)
        task.cancel()
        wait(for: [finished], timeout: 2)
    }

    func testPreservesExitStatusAndSmallOutput() throws {
        let result = try runShell("printf 'hello'; printf 'warning' >&2; exit 7")
        XCTAssertEqual(result, CommandResult(status: 7, stdout: "hello", stderr: "warning"))
    }

    func testLaunchFailurePreservesErrorType() {
        XCTAssertThrowsError(try ProcessCommandRunner().run(
            executable: URL(fileURLWithPath: "/nonexistent-term-llm-test-command"), arguments: []
        )) { error in
            guard case CommandError.launchFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    private func runShell(_ script: String, timeout: TimeInterval = 2) throws -> CommandResult {
        try ProcessCommandRunner().run(executable: URL(fileURLWithPath: "/bin/sh"),
                                       arguments: ["-c", script], timeout: timeout)
    }
}
