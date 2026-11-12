import Foundation
import XCTest
import os
@testable import ComputerUseCore

final class AXOwnershipTests: XCTestCase {
    func testConcurrentRegistrySnapshotsAndReplacementUseSynchronizedBackends() {
        let first = FakeAX(), second = FakeAX()
        let registry = AXBackendRegistry(first)
        DispatchQueue.concurrentPerform(iterations: 1_000) { index in
            registry.backend = index.isMultiple(of: 2) ? first : second
            let backend = registry.backend
            let app = backend.app(pid: 7)
            XCTAssertEqual(try? backend.get(app, "AXRole") as? String, "AXApplication")
        }
        XCTAssertEqual(first.gets.count + second.gets.count, 1_000)
    }

    func testReplacedBackendDeinitCanReenterRegistry() {
        let registry = AXBackendRegistry(UnavailableAX())
        let released = DispatchSemaphore(value: 0)
        registry.backend = FakeAX(onDeinit: { [weak registry] in
            XCTAssertNotNil(registry?.backend)
            released.signal()
        })
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            registry.backend = UnavailableAX()
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(released.wait(timeout: .now() + 5), .success)
    }

    func testDependencyScopesDoNotReplaceAnotherTestOrProductionBackend() {
        let production = AX.backend
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            let first = FakeAX(), second = FakeAX()
            AX.withBackend(first) {
                XCTAssertTrue(AX.backend === first)
                AX.withBackend(second) {
                    XCTAssertTrue(AX.backend === second)
                    AX.backend = FakeAX()
                    XCTAssertFalse(AX.backend === first)
                }
                XCTAssertTrue(AX.backend === first)
                AX.backend = second
                XCTAssertTrue(AX.backend === second)
            }
        }
        XCTAssertTrue(AX.backend === production)
    }

    func testFixtureReadDoesNotInstallBackendOutsideItsScope() throws {
        let previous = AX.backend
        _ = try FakeApp.load("controls").read()
        XCTAssertTrue(AX.backend === previous)
    }

    func testBackendHookCanReenterWithoutHoldingFakeOrRegistryLock() throws {
        let backend = FakeAX([7: El("AXApplication")])
        let registry = AXBackendRegistry(backend)
        backend.getHook = { _, _ in
            registry.backend = backend
            return registry.backend.names(backend.app(pid: 7)).first
        }
        XCTAssertEqual(try backend.get(backend.app(pid: 7), "AXRole") as? String, "AXRole")
        backend.getHook = nil // release the intentionally reentrant capture graph
    }

    func testFakeNodesAndLogsSupportConcurrentCalls() {
        let backend = FakeAX([7: El("AXApplication")])
        let element = backend.app(pid: 7)
        DispatchQueue.concurrentPerform(iterations: 500) { index in
            do {
                try backend.set(element, "AXValue", index)
                try backend.perform(element, "AXPress")
                _ = try backend.getMany(element, ["AXRole", "AXValue"])
            } catch { XCTFail("Unexpected fake AX failure: \(error)") }
        }
        XCTAssertEqual(backend.sets.count, 500)
        XCTAssertEqual(backend.gets.count, 1_000)
        XCTAssertEqual(backend.batches, 500)
        XCTAssertEqual(backend.el(element).performed.count, 1_000)
    }

    func testFakeCallbackCanReenterStopAndLaterNotificationsAreDropped() {
        let slot = OSAllocatedUnfairLock<FakeObserver?>(initialState: nil)
        let count = OSAllocatedUnfairLock(initialState: 0)
        let observation = FakeObserver(["destroyed"]) { _, _ in
            count.withLock { $0 += 1 }
            slot.withLock { $0 }?.stop()
        }
        slot.withLock { $0 = observation }
        observation.fire("destroyed", El())
        observation.fire("destroyed", El())
        XCTAssertEqual(count.withLock { $0 }, 1)
        XCTAssertTrue(observation.stopped)
        slot.withLock { $0 = nil }
    }
}
