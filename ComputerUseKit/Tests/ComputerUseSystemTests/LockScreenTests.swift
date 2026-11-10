import ComputerUseCore
import XCTest
@testable import ComputerUseSystem

final class LockScreenTests: XCTestCase {
    func testSessionDictionaryLockDetection() {
        for (session, expected): ([String: Any]?, Bool) in [([LockScreen.lockedKey: true, "kCGSSessionOnConsoleKey": true], true), (["kCGSSessionOnConsoleKey": true], false), (nil, false), ([:], false), ([LockScreen.lockedKey: 1], true), ([LockScreen.lockedKey: false], false)] {
            XCTAssertEqual(LockScreen.locked(session: { session }), expected)
        }
    }
    func testDistinctReadAndActionLockedTexts() {
        for (read, text) in [(true, "The Mac is locked, so its accessibility text cannot be read. It has to be unlocked first."), (false, "The Mac is locked. Ask the user to unlock it, then go on.")] {
            XCTAssertThrowsError(try LockScreen.gate(stateRead: read, isLocked: { true })) { error in
                let error = error as! HarnessError
                XCTAssertEqual(error.message, text); XCTAssertEqual(error.name, "mac_locked"); XCTAssertEqual(error.code, 134)
            }
        }
    }
    func testEveryCallReadsSessionExactlyOnce() throws {
        var reads = 0
        let unlocked = { LockScreen.locked(session: { reads += 1; return [:] }) }
        try LockScreen.gate(stateRead: true, isLocked: unlocked); try LockScreen.gate(stateRead: false, isLocked: unlocked)
        XCTAssertEqual(reads, 2)
        assertHarnessError(name: "mac_locked") { try LockScreen.gate(stateRead: false, isLocked: { LockScreen.locked(session: { reads += 1; return [LockScreen.lockedKey: true] }) }) }
        XCTAssertEqual(reads, 3)
    }
    func testNeverUnlocksOrDrawsOverLockScreen() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/ComputerUseSystem/LockScreen.swift")
        let text = try String(contentsOf: source)
        for banned in ["CGEventPost", "AXUIElement", "NSWindow", "unlock(", "setPassword"] { XCTAssertFalse(text.contains(banned)) }
    }
}
