import AppKit
import ComputerUseCore
import XCTest
@testable import ComputerUseSystem

final class EventsTests: XCTestCase {
    private let point = CGPoint(x: 150, y: 80)
    private var window: ComputerUseCore.WindowRef { ComputerUseCore.WindowRef(element: UIElementRef(NSObject()), windowID: 4242, pid: 77, title: "Fixture", frame: CGRect(x: 100, y: 50, width: 600, height: 400)) }
    private func field(_ event: CGEvent, _ field: UInt32) -> Int64 { event.getIntegerValueField(CGEventField(rawValue: field)!) }
    func testMouseBuilders() {
        for (kind, button, type, count) in [("down", 0, 1, 1), ("up", 0, 2, 1), ("dragged", 0, 6, 0), ("down", 1, 3, 1), ("up", 1, 4, 1), ("dragged", 1, 7, 0), ("down", 2, 25, 1), ("up", 2, 26, 1), ("dragged", 2, 27, 0), ("moved", 0, 5, 1), ("down", 0, 1, 2)] {
            let event = Events.mouse(kind, point: point, window: window, button: button, click: count == 2 ? 2 : 1, flags: UInt64(Keys.command))
            XCTAssertEqual(event.type.rawValue, UInt32(type)); XCTAssertEqual(event.flags.rawValue & Events.modifiers, UInt64(Keys.command))
            XCTAssertEqual(field(event, 1), Int64(count)); XCTAssertEqual(field(event, 3), Int64(button)); XCTAssertEqual(field(event, 7), 3)
            for f: UInt32 in [51, 91, 92] { XCTAssertEqual(field(event, f), 4242) }
            XCTAssertEqual(event.location, point)
        }
        XCTAssertEqual(Events.clickHold, 0.05)
    }
    func testWindowLocalPoint() throws {
        typealias Read = @convention(c) (CGEvent) -> CGPoint
        guard let symbol = Events.privateSymbol("CGEventGetWindowLocation") else { throw XCTSkip("Private readback call not present") }
        let read = unsafeBitCast(symbol, to: Read.self)
        for event in [Events.mouse("down", point: point, window: window), Events.wheel(point, dx: 0, dy: -10, window: window)] { XCTAssertEqual(read(event), CGPoint(x: 50, y: 30)) }
    }
    func testRunningEventNumbers() {
        let numbers = ["down", "up", "dragged"].map { field(Events.mouse($0, point: point, window: window), 0) }
        XCTAssertEqual(numbers, [numbers[0], numbers[0] + 1, numbers[0] + 2])
    }
    func testWheel() {
        for (dx, dy) in [(0, -150), (0, 150), (-120, 0), (120, 0)] {
            let event = Events.wheel(point, dx: dx, dy: dy, window: window)
            XCTAssertEqual(event.type.rawValue, 22); XCTAssertEqual(field(event, 96), Int64(dy)); XCTAssertEqual(field(event, 97), Int64(dx))
            XCTAssertEqual(field(event, 88), 1); XCTAssertEqual(field(event, 51), 4242)
        }
    }
    func testKeyboardAndUnicode() {
        let down = Events.key(9, flags: UInt64(Keys.command)), up = Events.key(9, flags: UInt64(Keys.command), down: false)
        XCTAssertEqual(down.type.rawValue, 10); XCTAssertEqual(up.type.rawValue, 11)
        XCTAssertEqual(field(down, 9), 9); XCTAssertEqual(down.flags.rawValue, UInt64(Keys.command))
        for text in ["é", "😀", "e\u{301}"] {
            let event = Events.key(0, flags: 0, text: text)
            var units = [UniChar](repeating: 0, count: 16), length = 0
            event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &length, unicodeString: &units)
            XCTAssertEqual(length, text.utf16.count); XCTAssertEqual(String(utf16CodeUnits: units, count: length), text)
        }
    }
    func testFlagsChangedAndNotice() {
        let event = Events.flagsChanged(UInt64(Keys.command)); XCTAssertEqual(event.type.rawValue, 12); XCTAssertEqual(event.flags.rawValue, UInt64(Keys.command))
        let active = Events.notice(13, subtype: 1, windowID: 4242, flags: 0xc0000)
        XCTAssertEqual(active.type.rawValue, 13); XCTAssertEqual(field(active, 83), 1); XCTAssertEqual(field(active, 51), 4242); XCTAssertEqual(active.flags.rawValue, 0xc0000)
        let focus = Events.notice(21, subtype: 0x8000)
        XCTAssertEqual(focus.type.rawValue, 21); XCTAssertEqual(field(focus, 64), 0x8000)
    }
    func testPostStampsAndSendsToOnlyOnePID() {
        var sent: [pid_t] = [], slept: [Double] = []
        let event = Events.key(0, flags: 0)
        for delay in [0.01, 0] { Events.post(77, event: event, delay: delay, send: { pid, _ in sent.append(pid) }, sleep: { slept.append($0) }, timestamp: { 12345 }) }
        XCTAssertEqual(sent, [77, 77]); XCTAssertEqual(slept, [0.01]); XCTAssertEqual(field(event, Events.userDataField), Events.ownTag); XCTAssertEqual(event.timestamp, 12345)
    }
    func testMissingPrivateSymbolIsLoggedOnceAndDisablesOnlyItsStep() {
        var logs: [String] = []
        let symbols = PrivateSymbols(path: "/not/a/framework", log: { logs.append($0) })
        XCTAssertNil(symbols.lookup("Missing")); XCTAssertNil(symbols.lookup("Missing")); XCTAssertEqual(logs, ["Missing"])
    }
    func testNoSystemStreamOrPointerMutation() throws {
        let sourceFolder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/ComputerUseSystem")
        for file in ["Events.swift", "Keys.swift", "Pasteboard.swift"] {
            let text = try String(contentsOf: sourceFolder.appendingPathComponent(file))
            for banned in ["CGEventPost(", "CGWarpMouse", "MoveCursor", "CGAssociate", "HideCursor", "CGEventTapPostEvent", "IOHIDPostEvent"] { XCTAssertFalse(text.contains(banned), "\(file): \(banned)") }
        }
    }
}
