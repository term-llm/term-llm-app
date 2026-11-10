import AppKit
import os
import XCTest
@testable import ComputerUseSystem

// C-compatible fakes for dlsym boundaries: never call the window server.
// C function pointers cannot capture, so the fakes record into this global.
private struct PrivateCalls: Sendable { var trace: [String] = [], status: Int32 = 0 }
private let privateCalls = OSAllocatedUnfairLock(initialState: PrivateCalls())
private var privateTrace: [String] {
    get { privateCalls.withLock { $0.trace } }
    set { privateCalls.withLock { $0.trace = newValue } }
}
private var privateStatus: Int32 {
    get { privateCalls.withLock { $0.status } }
    set { privateCalls.withLock { $0.status = newValue } }
}
private let getFront: @convention(c) (UnsafeMutableRawPointer) -> Int32 = { pointer in pointer.storeBytes(of: UInt64(123), as: UInt64.self); return 0 }
private let getPID: @convention(c) (UnsafeRawPointer, UnsafeMutablePointer<pid_t>) -> Int32 = { number, pid in
    privateTrace.append("pid:\(number.load(as: UInt64.self))"); pid.pointee = 77; return 0
}
private let getProcess: @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32 = { pid, pointer in
    privateTrace.append("process:\(pid)"); pointer.storeBytes(of: UInt64(123), as: UInt64.self); return privateStatus
}
private let attention: @convention(c) (UnsafeRawPointer, Bool) -> Int32 = { number, wants in
    privateTrace.append("attention:\(number.load(as: UInt64.self)):\(wants)"); return 0
}
private let connection: @convention(c) () -> Int32 = { 5 }
private let freeze: @convention(c) (Int32) -> Int32 = { privateTrace.append("freeze:\($0)"); return 0 }
private let thaw: @convention(c) (Int32) -> Int32 = { privateTrace.append("thaw:\($0)"); return 0 }
private let copyAssociated: @convention(c) (Int32, UInt32) -> Unmanaged<CFArray>? = { connection, id in
    privateTrace.append("associated:\(connection):\(id)")
    return Unmanaged.passRetained([NSNumber(value: 7), NSNumber(value: 8)] as CFArray)
}
final class ContextPrivateCallsTests: XCTestCase {
    var symbols: [String: UnsafeMutableRawPointer] {
        ["GetFrontProcess": unsafeBitCast(getFront, to: UnsafeMutableRawPointer.self),
         "GetProcessPID": unsafeBitCast(getPID, to: UnsafeMutableRawPointer.self),
         "GetProcessForPID": unsafeBitCast(getProcess, to: UnsafeMutableRawPointer.self),
         "_SetApplicationDesiresAttention": unsafeBitCast(attention, to: UnsafeMutableRawPointer.self),
         "CGSMainConnectionID": unsafeBitCast(connection, to: UnsafeMutableRawPointer.self),
         "CGSDisableUpdate": unsafeBitCast(freeze, to: UnsafeMutableRawPointer.self),
         "CGSReenableUpdate": unsafeBitCast(thaw, to: UnsafeMutableRawPointer.self),
         "CGSCopyAssociatedWindows": unsafeBitCast(copyAssociated, to: UnsafeMutableRawPointer.self)]
    }
    override func setUp() { privateTrace = []; privateStatus = 0 }
    func testFrontProcessReadOnlyAndAbsentSymbols() {
        XCTAssertEqual(Focus.frontPID(symbol: { self.symbols[$0] }), 77); XCTAssertEqual(privateTrace, ["pid:123"])
        XCTAssertEqual(Focus.frontPID(symbol: { _ in nil }), 0)
    }
    func testNoAttentionOnlyForFoundProcessAndSymbol() {
        Focus.noAttention(77, symbol: { self.symbols[$0] }); XCTAssertEqual(privateTrace, ["process:77", "attention:123:false"])
        privateTrace = []; privateStatus = -600; Focus.noAttention(77, symbol: { self.symbols[$0] }); XCTAssertEqual(privateTrace, ["process:77"])
        privateTrace = []; Focus.noAttention(77, symbol: { _ in nil }); XCTAssertTrue(privateTrace.isEmpty)
    }
    func testFreezeThawRequireAllSymbols() {
        Focus.updateScreen(frozen: true, symbol: { self.symbols[$0] }); Focus.updateScreen(frozen: false, symbol: { self.symbols[$0] })
        XCTAssertEqual(privateTrace, ["freeze:5", "thaw:5"])
        privateTrace = []; Focus.updateScreen(frozen: true, symbol: { $0 == "CGSReenableUpdate" ? nil : self.symbols[$0] }); XCTAssertTrue(privateTrace.isEmpty)
    }
    func testAssociatedWindowsAndUnavailableFallback() {
        XCTAssertEqual(Windows.systemAssociated(9, symbol: { self.symbols[$0] }), [7, 8]); XCTAssertEqual(privateTrace, ["associated:5:9"])
        XCTAssertTrue(Windows.systemAssociated(9, symbol: { _ in nil }).isEmpty)
    }
}
