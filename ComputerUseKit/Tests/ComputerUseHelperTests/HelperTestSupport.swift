import Foundation
import os
import XCTest

/// Typed fixture ownership only. Callbacks are snapshotted by callers and invoked
/// outside this lock. Replacement retains the retired value until after unlock,
/// so captured values may safely reenter fixture state from deinit.
final class HelperFixtureBox<Value: Sendable>: Sendable {
    private let storage: OSAllocatedUnfairLock<Value>
    init(_ value: Value) { storage = OSAllocatedUnfairLock(initialState: value) }
    var value: Value {
        get { storage.withLock { $0 } }
        set {
            let retired = storage.withLock { value in
                let old = value
                value = newValue
                return old
            }
            withExtendedLifetime(retired) {}
        }
    }
    /// Only typed state operations belong here, never an injected callback.
    func update<Result: Sendable>(_ body: @Sendable (inout Value) -> Result) -> Result {
        storage.withLock(body)
    }
}

private final class FixtureReleaseProbe: Sendable {
    let released: @Sendable () -> Void
    init(released: @escaping @Sendable () -> Void) { self.released = released }
    deinit { released() }
}

/// Pure fixture-only checks: no HelperServer, dependency constructors, CGEvents,
/// apps, AX, sockets, pasteboard, input, or power primitives are used here.
final class PureFixtureOwnershipTests: XCTestCase {
    func testConcurrentTypedUpdatesKeepEveryEntry() {
        let entries = HelperFixtureBox<[Int]>([])
        DispatchQueue.concurrentPerform(iterations: 500) { index in
            entries.update { $0.append(index) }
        }
        XCTAssertEqual(entries.value.sorted(), Array(0..<500))
    }

    func testCallbackSnapshotCanReplaceItselfOutsideLock() {
        let callback = HelperFixtureBox<(@Sendable () -> Void)?>(nil)
        let calls = HelperFixtureBox(0)
        callback.value = {
            calls.update { $0 += 1 }
            callback.value = nil
        }
        let snapshot = callback.value
        snapshot?()
        XCTAssertEqual(calls.value, 1)
        XCTAssertNil(callback.value)
    }

    func testRetiredCallbackCaptureCanReenterStorageFromDeinit() {
        let callback = HelperFixtureBox<(@Sendable () -> Void)?>(nil)
        let released = HelperFixtureBox(false)
        func install() {
            let probe = FixtureReleaseProbe {
                XCTAssertNil(callback.value)
                released.value = true
            }
            callback.value = { [probe] in withExtendedLifetime(probe) {} }
        }
        install()
        XCTAssertFalse(released.value)
        callback.value = nil
        XCTAssertTrue(released.value)
    }
}
