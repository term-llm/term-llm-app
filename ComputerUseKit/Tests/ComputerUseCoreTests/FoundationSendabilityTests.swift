import os
import XCTest

@testable import ComputerUseCore

final class FoundationSendabilityTests: XCTestCase {
    // A generic constraint keeps these imported Swift 5 value types honest even
    // when a compiler treats missing Sendable conformances as compatibility warnings.
    private func snapshot<Value: Sendable>(_ value: Value) -> Value { value }

    func testActivitySnapshotsCanBeUpdatedIndependentlyOnWorkers() {
        var original = ActivityWindow()
        original.update(working: true, now: 10)
        let initial = snapshot(original)
        let results = OSAllocatedUnfairLock<[Int: ActivityWindow]>(initialState: [:])

        DispatchQueue.concurrentPerform(iterations: 32) { index in
            var copy = initial
            copy.update(working: false, now: Double(index))
            results.withLock { [copy] in $0[index] = copy }
        }

        XCTAssertTrue(original.working)
        XCTAssertEqual(original.changed, 10)
        let copies = results.withLock { $0 }
        XCTAssertEqual(copies.count, 32)
        for index in 0..<32 {
            XCTAssertEqual(copies[index]?.changed, Double(index))
            XCTAssertEqual(copies[index]?.working, false)
            XCTAssertEqual(copies[index]?.remaining(now: Double(index) + 1), 2)
        }
    }

    func testSessionGrantCanBeSharedWithWorkersAsAValue() {
        let grant = snapshot(ApprovalStore.SessionGrant(agent: "named", bundleID: "com.example.App"))
        let results = OSAllocatedUnfairLock<[ApprovalStore.SessionGrant]>(initialState: [])

        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            results.withLock { $0.append(grant) }
        }

        let grants = results.withLock { $0 }
        XCTAssertEqual(grants.count, 32)
        XCTAssertEqual(Set(grants), [grant])
        XCTAssertEqual(grants.first?.agent, "named")
        XCTAssertEqual(grants.first?.bundleID, "com.example.App")
    }
}
