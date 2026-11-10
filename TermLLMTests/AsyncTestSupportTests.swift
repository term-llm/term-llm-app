import XCTest
@testable import TermLLM

@MainActor
final class AsyncTestSupportTests: XCTestCase {
    func testAlreadySatisfiedConditionDoesNotSuspend() async throws {
        var checks = 0
        try await pollUntil(timeout: .zero, interval: .milliseconds(1)) {
            checks += 1
            return true
        }
        XCTAssertEqual(checks, 1)
    }

    func testPollingAllowsMainActorWorkToComplete() async throws {
        var ready = false
        let work = Task { @MainActor in ready = true }
        defer { work.cancel() }
        try await pollUntil("main-actor work", timeout: .seconds(2), interval: .milliseconds(1)) { ready }
        XCTAssertTrue(ready)
    }

    func testTimeoutReportsDescriptionAndForwardedSourceLocation() async {
        let options = XCTExpectedFailure.Options()
        options.issueMatcher = { issue in
            issue.compactDescription.contains("waiting for never ready")
                && issue.sourceCodeContext.location?.fileURL.lastPathComponent == "AsyncTestSupportTests.swift"
                && issue.sourceCodeContext.location?.lineNumber == 123
        }
        XCTExpectFailure("A bounded poll must report its caller's timeout", options: options)
        do {
            try await pollUntil("never ready", timeout: .zero, interval: .milliseconds(1),
                                file: #filePath, line: 123) { false }
            XCTFail("Timeout must stop throwing callers")
        } catch let error as TestPollingTimeout {
            XCTAssertTrue(error.description.contains("never ready"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCancellationStopsPollingWithoutReportingATimeout() async {
        let task = Task { @MainActor in
            try await pollUntil(timeout: .seconds(10), interval: .milliseconds(1)) { false }
        }
        task.cancel()
        do {
            try await task.value
            XCTFail("Cancelled polling must stop")
        } catch is CancellationError {
            // Cancellation is not a readiness failure.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
