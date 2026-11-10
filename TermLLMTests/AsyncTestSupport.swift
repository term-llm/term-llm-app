import Foundation
import XCTest

struct TestPollingTimeout: Error, CustomStringConvertible {
    let description: String
}

/// Bounded, monotonic polling for observable completion, not for elapsed-time or
/// negative assertions. Reports the caller's source location and stops throwing
/// callers before they continue with state that never became ready.
@MainActor
func pollUntil(_ description: @autoclosure () -> String = "condition",
               timeout: Duration, interval: Duration,
               file: StaticString = #filePath, line: UInt = #line,
               _ condition: () -> Bool) async throws {
    precondition(timeout >= .zero && interval > .zero)
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        try Task.checkCancellation()
        let remaining = clock.now.duration(to: deadline)
        guard remaining > .zero else {
            let message = "Timed out after \(timeout) waiting for \(description())"
            XCTFail(message, file: file, line: line)
            throw TestPollingTimeout(description: message)
        }
        try await Task.sleep(for: min(interval, remaining))
    }
}

/// Listen's nonthrowing convenience; subsequent assertions still describe the
/// expected state, while pollUntil records a timeout at this helper's caller.
@MainActor
func eventually(_ timeout: TimeInterval = 5,
                file: StaticString = #filePath, line: UInt = #line,
                _ condition: () -> Bool) async {
    try? await pollUntil(timeout: .seconds(timeout), interval: .milliseconds(10),
                         file: file, line: line, condition)
}

/// A scheduling drain, deliberately not a completion/elapsed-time guarantee.
@MainActor
func settle() async {
    for _ in 0..<20 { await Task.yield() }
}
