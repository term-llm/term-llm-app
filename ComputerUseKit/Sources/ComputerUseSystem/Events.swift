import AppKit
import ComputerUseCore
import Foundation
import os

/// Input built for one window and posted to one process. Nothing here reaches the
/// system event stream: the real pointer and the person's keyboard focus stay put.
/// Without a window id a mouse/wheel event does nothing in a background app.
public enum Events {
    // The person detector reads this tag to tell our input from the person's.
    public static let ownTag: Int64 = 0x6D68_6576
    public static let userDataField: UInt32 = 42
    public static let modifiers: UInt64 = 0x1E0000
    public static let clickHold: TimeInterval = 0.05
    private static let source = HIDEventSource()
    private static let numbers = EventNumbers()
    private static let types: [String: [UInt]] = ["down": [1, 3, 25], "up": [2, 4, 26], "dragged": [6, 7, 27], "moved": [5, 5, 5]]
    private typealias Place = @convention(c) (CGEvent, CGPoint) -> Void
    private static let symbols = PrivateSymbols(path: "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics") { name in
        NSLog("%@ is not on this system: its step is skipped", name)
    }
    public static func privateSymbol(_ name: String) -> UnsafeMutableRawPointer? { symbols.lookup(name) }
    private static let place: Place? = privateSymbol("CGEventSetWindowLocation").map { unsafeBitCast($0, to: Place.self) }
    private static func inWindow(_ event: CGEvent, point: CGPoint, window: ComputerUseCore.WindowRef) -> CGEvent {
        event.location = point
        for field: UInt32 in [51, 91, 92] { event.setIntegerValueField(CGEventField(rawValue: field)!, value: Int64(window.windowID)) }
        place?(event, CGPoint(x: point.x - window.frame.minX, y: point.y - window.frame.minY))
        return event
    }
    public static func mouse(_ kind: String, point: CGPoint, window: ComputerUseCore.WindowRef, button: Int = 0, click: Int = 1, flags: UInt64 = 0) -> CGEvent {
        let count = kind == "dragged" ? 0 : kind == "moved" ? 1 : click
        let event = NSEvent.mouseEvent(with: NSEvent.EventType(rawValue: types[kind]![min(button, 2)])!, location: point, modifierFlags: [], timestamp: 0, windowNumber: Int(window.windowID), context: nil, eventNumber: numbers.next(), clickCount: count, pressure: 1)!.cgEvent!
        event.flags = CGEventFlags(rawValue: flags)
        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
        event.setIntegerValueField(.mouseEventSubtype, value: 3)
        return inWindow(event, point: point, window: window)
    }
    public static func wheel(_ point: CGPoint, dx: Int, dy: Int, window: ComputerUseCore.WindowRef) -> CGEvent {
        let event = source.wheel(dx: dx, dy: dy)
        return inWindow(event, point: point, window: window)
    }
    public static func key(_ code: Int, flags: UInt64, text: String? = nil, down: Bool = true) -> CGEvent {
        let event = source.key(code: code, down: down)
        event.flags = CGEventFlags(rawValue: flags)
        if let text, !text.isEmpty {
            let units = Array(text.utf16)
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        }
        return event
    }
    public static func flagsChanged(_ flags: UInt64) -> CGEvent {
        let event = source.event(); event.type = .flagsChanged; event.flags = CGEventFlags(rawValue: flags); return event
    }
    public static func heldFlags() -> UInt64 { CGEventSource.flagsState(.combinedSessionState).rawValue }
    public static func notice(_ kind: UInt, subtype: Int, windowID: UInt32 = 0, flags: UInt64 = 0) -> CGEvent {
        // The field is a signed 16-bit number.
        let signed = subtype > 0x7fff ? subtype - 0x10000 : subtype
        return NSEvent.otherEvent(with: NSEvent.EventType(rawValue: kind)!, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)), timestamp: 0, windowNumber: Int(windowID), context: nil, subtype: Int16(signed), data1: 0, data2: 0)!.cgEvent!
    }
    public static func post(_ pid: pid_t, event: CGEvent, delay: TimeInterval = 0,
                            send: (pid_t, CGEvent) -> Void = { $1.postToPid($0) },
                            sleep: (TimeInterval) -> Void = Thread.sleep(forTimeInterval:),
                            timestamp: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        event.setIntegerValueField(CGEventField(rawValue: userDataField)!, value: ownTag)
        event.timestamp = timestamp(); send(pid, event)
        if delay != 0 { sleep(delay) }
    }
}
private final class EventNumbers: Sendable {
    private let number = OSAllocatedUnfairLock(initialState: 0)
    func next() -> Int { number.withLock { $0 += 1; return $0 } }
}

/// The SDK does not mark CGEventSource Sendable. This private owner keeps the
/// original, single HID source (including a possible nil source) for all builders.
/// Only event creation touches it, always under the lock; the handle never escapes.
/// Each returned CGEvent is newly created and belongs exclusively to its caller.
private final class HIDEventSource: @unchecked Sendable {
    private let source = CGEventSource(stateID: .hidSystemState)
    private let lock = NSLock()

    func wheel(dx: Int, dy: Int) -> CGEvent {
        lock.lock(); defer { lock.unlock() }
        return CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                       wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0)!
    }
    func key(code: Int, down: Bool) -> CGEvent {
        lock.lock(); defer { lock.unlock() }
        return CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down)!
    }
    func event() -> CGEvent {
        lock.lock(); defer { lock.unlock() }
        return CGEvent(source: source)!
    }
}

/// One lookup and one warning per missing private call. A missing call disables
/// only its step; private symbols must never make the entire backend unavailable.
final class PrivateSymbols: Sendable {
    /// These opaque addresses identify a permanently loaded library or its code,
    /// never mutable Swift storage. We do not dereference them. The library is
    /// intentionally never dlclosed: returned function pointers outlive this owner.
    /// Injected open/resolve implementations must preserve the same lifetime.
    private struct Address: @unchecked Sendable {
        let pointer: UnsafeMutableRawPointer
    }
    private enum Resolution: Sendable {
        case found(Address)
        case missing
    }
    private let handle: Address?
    private let resolve: @Sendable (UnsafeMutableRawPointer, String) -> UnsafeMutableRawPointer?
    private let log: @Sendable (String) -> Void
    private let cache = OSAllocatedUnfairLock<[String: Resolution]>(initialState: [:])

    /// `open` runs once during initialization. `resolve` runs under the cache lock
    /// and must not reenter this cache. `log` runs outside that lock and may reenter,
    /// including looking up the missing name again. All callbacks may run off main.
    init(path: String,
         open: @Sendable (String) -> UnsafeMutableRawPointer? = { dlopen($0, RTLD_LAZY) },
         resolve: @escaping @Sendable (UnsafeMutableRawPointer, String) -> UnsafeMutableRawPointer? = { dlsym($0, $1) },
         log: @escaping @Sendable (String) -> Void) {
        handle = open(path).map { Address(pointer: $0) }
        self.resolve = resolve
        self.log = log
    }
    func lookup(_ name: String) -> UnsafeMutableRawPointer? {
        let (resolution, warn) = cache.withLock { cache -> (Resolution, Bool) in
            if let cached = cache[name] { return (cached, false) }
            if let handle, let value = resolve(handle.pointer, name) {
                let found = Resolution.found(Address(pointer: value))
                cache[name] = found
                return (found, false)
            }
            cache[name] = .missing
            return (.missing, true)
        }
        // Publish the miss before calling user code: recursive and concurrent
        // lookups neither repeat the resolver nor warn a second time.
        if warn { log(name) }
        if case .found(let address) = resolution { return address.pointer }
        return nil
    }
}
