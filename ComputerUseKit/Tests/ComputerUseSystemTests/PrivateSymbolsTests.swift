import Foundation
import os
import XCTest
@testable import ComputerUseSystem

// Every library and symbol address here is fabricated, immutable and never
// dereferenced or called. No test opens a library or resolves a host symbol.
private final class SymbolRecorder: Sendable {
    struct State: Sendable {
        var paths: [String] = []
        var lookups: [String] = []
        var warnings: [String] = []
    }
    let state = OSAllocatedUnfairLock(initialState: State())

    func symbols(opened: Bool = true) -> PrivateSymbols {
        PrivateSymbols(path: "fake-library", open: { path in
            self.state.withLock { $0.paths.append(path) }
            return opened ? UnsafeMutableRawPointer(bitPattern: 0x1000) : nil
        }, resolve: { handle, name in
            XCTAssertEqual(UInt(bitPattern: handle), 0x1000)
            self.state.withLock { $0.lookups.append(name) }
            return name == "Found" ? UnsafeMutableRawPointer(bitPattern: 0x2000) : nil
        }, log: { name in
            self.state.withLock { $0.warnings.append(name) }
        })
    }
}

final class PrivateSymbolsTests: XCTestCase {
    func testFoundAddressIsCachedWithoutWarning() {
        let recorder = SymbolRecorder()
        let symbols = recorder.symbols()
        for _ in 0..<3 {
            XCTAssertEqual(symbols.lookup("Found").map { UInt(bitPattern: $0) }, 0x2000)
        }
        let state = recorder.state.withLock { $0 }
        XCTAssertEqual(state.paths, ["fake-library"])
        XCTAssertEqual(state.lookups, ["Found"])
        XCTAssertTrue(state.warnings.isEmpty)
    }

    func testMissingAddressIsResolvedAndWarnedOncePerName() {
        let recorder = SymbolRecorder()
        let symbols = recorder.symbols()
        for _ in 0..<3 {
            XCTAssertNil(symbols.lookup("Missing"))
            XCTAssertNil(symbols.lookup("OtherMissing"))
        }
        XCTAssertEqual(symbols.lookup("Found").map { UInt(bitPattern: $0) }, 0x2000)
        let state = recorder.state.withLock { $0 }
        XCTAssertEqual(state.lookups, ["Missing", "OtherMissing", "Found"])
        XCTAssertEqual(state.warnings, ["Missing", "OtherMissing"])
    }

    func testFailedOpenDoesNotInvokeResolverAndCachesEachMiss() {
        let recorder = SymbolRecorder()
        let symbols = recorder.symbols(opened: false)
        for _ in 0..<3 {
            XCTAssertNil(symbols.lookup("Missing"))
            XCTAssertNil(symbols.lookup("OtherMissing"))
        }
        let state = recorder.state.withLock { $0 }
        XCTAssertEqual(state.paths, ["fake-library"])
        XCTAssertTrue(state.lookups.isEmpty)
        XCTAssertEqual(state.warnings, ["Missing", "OtherMissing"])
    }

    func testConcurrentFoundAndMissingLookupsResolveOncePerName() {
        let recorder = SymbolRecorder()
        let symbols = recorder.symbols()
        let incorrect = OSAllocatedUnfairLock(initialState: 0)
        DispatchQueue.concurrentPerform(iterations: 256) { index in
            let name = index.isMultiple(of: 2) ? "Found" : "Missing"
            let actual = symbols.lookup(name).map { UInt(bitPattern: $0) }
            let expected: UInt? = name == "Found" ? 0x2000 : nil
            if actual != expected { incorrect.withLock { $0 += 1 } }
        }
        let state = recorder.state.withLock { $0 }
        XCTAssertEqual(incorrect.withLock { $0 }, 0)
        XCTAssertEqual(state.paths, ["fake-library"])
        XCTAssertEqual(state.lookups.sorted(), ["Found", "Missing"])
        XCTAssertEqual(state.warnings, ["Missing"])
    }

    func testConcurrentLookupsDuringFirstResolutionDoNotRepeatResolver() {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let attempts = DispatchSemaphore(value: 0)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let warnings = OSAllocatedUnfairLock(initialState: 0)
        let symbols = PrivateSymbols(path: "fake-library", open: { _ in
            UnsafeMutableRawPointer(bitPattern: 0x1000)
        }, resolve: { _, _ in
            calls.withLock { $0 += 1 }
            entered.signal()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            return nil
        }, log: { _ in warnings.withLock { $0 += 1 } })
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            XCTAssertNil(symbols.lookup("Missing"))
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        for _ in 0..<8 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                attempts.signal()
                XCTAssertNil(symbols.lookup("Missing"))
            }
        }
        for _ in 0..<8 { XCTAssertEqual(attempts.wait(timeout: .now() + 5), .success) }
        XCTAssertEqual(calls.withLock { $0 }, 1)
        // Negative timing assertion: no second resolver may enter before release.
        XCTAssertEqual(entered.wait(timeout: .now() + 0.2), .timedOut)
        release.signal()
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(calls.withLock { $0 }, 1)
        XCTAssertEqual(warnings.withLock { $0 }, 1)
    }

    func testLoggerCanReenterSameAndDifferentNames() {
        let owner = OSAllocatedUnfairLock<PrivateSymbols?>(initialState: nil)
        defer { owner.withLock { $0 = nil } }
        let lookups = OSAllocatedUnfairLock<[String]>(initialState: [])
        let warnings = OSAllocatedUnfairLock<[String]>(initialState: [])
        let symbols = PrivateSymbols(path: "fake-library", open: { _ in
            UnsafeMutableRawPointer(bitPattern: 0x1000)
        }, resolve: { _, name in
            lookups.withLock { $0.append(name) }
            return name == "Found" ? UnsafeMutableRawPointer(bitPattern: 0x2000) : nil
        }, log: { name in
            warnings.withLock { $0.append(name) }
            let symbols = owner.withLock { $0 }!
            XCTAssertNil(symbols.lookup(name))
            if name == "Missing" {
                XCTAssertEqual(symbols.lookup("Found").map { UInt(bitPattern: $0) }, 0x2000)
                XCTAssertNil(symbols.lookup("OtherMissing"))
            }
        })
        owner.withLock { $0 = symbols }
        // A bounded worker keeps a regression from hanging the whole test run.
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            XCTAssertNil(symbols.lookup("Missing"))
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(lookups.withLock { $0 }, ["Missing", "Found", "OtherMissing"])
        XCTAssertEqual(warnings.withLock { $0 }, ["Missing", "OtherMissing"])
    }

    func testBlockedLoggerDoesNotBlockOtherLookupsOrRepeatWarning() {
        let logging = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let warnings = OSAllocatedUnfairLock(initialState: 0)
        let calls = OSAllocatedUnfairLock<[String]>(initialState: [])
        let symbols = PrivateSymbols(path: "fake-library", open: { _ in
            UnsafeMutableRawPointer(bitPattern: 0x1000)
        }, resolve: { _, name in
            calls.withLock { $0.append(name) }
            return name == "Found" ? UnsafeMutableRawPointer(bitPattern: 0x2000) : nil
        }, log: { _ in
            warnings.withLock { $0 += 1 }
            logging.signal()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
        })
        let first = DispatchGroup()
        first.enter()
        DispatchQueue.global().async {
            defer { first.leave() }
            XCTAssertNil(symbols.lookup("Missing"))
        }
        XCTAssertEqual(logging.wait(timeout: .now() + 5), .success)
        let second = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            XCTAssertNil(symbols.lookup("Missing"))
            XCTAssertEqual(symbols.lookup("Found").map { UInt(bitPattern: $0) }, 0x2000)
            second.signal()
        }
        XCTAssertEqual(second.wait(timeout: .now() + 2), .success)
        release.signal()
        XCTAssertEqual(first.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(calls.withLock { $0 }, ["Missing", "Found"])
        XCTAssertEqual(warnings.withLock { $0 }, 1)
    }
}
