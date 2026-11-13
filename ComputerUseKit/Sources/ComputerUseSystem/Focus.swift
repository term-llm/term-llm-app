import AppKit
import ComputerUseCore
import os

/// Tell an app it is active without raising it or moving the real pointer. Restore
/// the person's front app if activation leaks into a real switch.
public final class Focus: Sendable {
    // Recursive physical-input execution lock, held through an action. This is
    // not a state lock: dependency calls and same-thread reentry are intentional.
    // Two apps cannot believe they are frontmost for input at once. Independent
    // human-priority restoration deliberately bypasses this execution lock.
    public static let inputLock = NSRecursiveLock()
    public static let appKitDefined: UInt = 13, processNotice: UInt = 21
    public static let activated = 1, deactivated = 2, keyFocusReturned = 0x8000, keyFocusRemoved = 0x4000 // measured to work
    public static let activationFlags: UInt64 = 0xC0000
    public static let believeWait = 0.25, restoreWait = 2.0, leakWatch = 3.0, poll = 0.01
    // Pages came forward 1.9 s after being told it was active for a key.
    public struct System: Sendable {
        public var frontPID: @Sendable () -> pid_t = { Focus.frontPID() }
        public var noAttention: @Sendable (pid_t) -> Void = { Focus.noAttention($0) }
        public var post: @Sendable (pid_t, CGEvent) -> Void = { Events.post($0, event: $1) }
        public var freeze: @Sendable () -> Void = { Focus.updateScreen(frozen: true) }
        public var thaw: @Sendable () -> Void = { Focus.updateScreen(frozen: false) }
        public var now: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        public var sleep: @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
        public var background: @Sendable (@escaping @Sendable () -> Void) -> Void = { work in DispatchQueue.global().async(execute: DispatchWorkItem(block: work)) }
        public var personWent: @Sendable (pid_t, TimeInterval) -> Bool = { Person.shared.wentTo($0, since: $1) }
        public init() {}
    }
    public static let shared = Focus()
    public let system: System
    private let enforcers = OSAllocatedUnfairLock(initialState: [pid_t: Enforcer]())
    public init(system: System = .init()) { self.system = system }
    private static let services = PrivateSymbols(path: "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", log: { NSLog("%@ is not on this system: its step is skipped", $0) })
    // ProcessSerialNumber is two UInt32s. Use raw pointers at the C boundary.
    public static func frontPID() -> pid_t { frontPID(symbol: services.lookup) }
    public static func frontPID(symbol: (String) -> UnsafeMutableRawPointer?) -> pid_t {
        typealias Front = @convention(c) (UnsafeMutableRawPointer) -> Int32
        typealias PID = @convention(c) (UnsafeRawPointer, UnsafeMutablePointer<pid_t>) -> Int32
        guard let f = symbol("GetFrontProcess"), let p = symbol("GetProcessPID") else { return 0 }
        var number: UInt64 = 0, pid: pid_t = 0
        _ = withUnsafeMutablePointer(to: &number) { unsafeBitCast(f, to: Front.self)($0) }
        _ = withUnsafePointer(to: &number) { unsafeBitCast(p, to: PID.self)($0, &pid) }
        return pid
    }
    public static func noAttention(_ pid: pid_t) { noAttention(pid, symbol: services.lookup) }
    public static func noAttention(_ pid: pid_t, symbol: (String) -> UnsafeMutableRawPointer?) {
        typealias Get = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32
        typealias Desires = @convention(c) (UnsafeRawPointer, Bool) -> Int32
        guard let g = symbol("GetProcessForPID"), let d = symbol("_SetApplicationDesiresAttention") else { return }
        var number: UInt64 = 0
        withUnsafeMutablePointer(to: &number) { ptr in
            if unsafeBitCast(g, to: Get.self)(pid, ptr) == 0 { _ = unsafeBitCast(d, to: Desires.self)(ptr, false) }
        }
    }
    public static func updateScreen(frozen: Bool) { updateScreen(frozen: frozen, symbol: Events.privateSymbol) }
    public static func updateScreen(frozen: Bool, symbol: (String) -> UnsafeMutableRawPointer?) {
        typealias Connection = @convention(c) () -> Int32
        typealias Update = @convention(c) (Int32) -> Int32
        guard let c = symbol("CGSMainConnectionID"), let f = symbol("CGSDisableUpdate"), let t = symbol("CGSReenableUpdate") else { return }
        _ = unsafeBitCast(frozen ? f : t, to: Update.self)(unsafeBitCast(c, to: Connection.self)())
    }
    public static func focusElement(_ element: UIElementRef) -> Bool {
        do { try AX.backend.set(element, "AXFocused", true); return true } catch { return false }
    }
    public func enforcer(_ target: AppTarget) -> Enforcer {
        // Preserve action/registry ordering without putting AX or callbacks under
        // the short registry state lock. Belief getters remain independent.
        Self.inputLock.lock(); defer { Self.inputLock.unlock() }
        return enforcers.withLock { enforcers in
            let pid = target.pid ?? 0
            if let found = enforcers[pid] { return found }
            let found = Enforcer(pid: pid, focus: self); enforcers[pid] = found; return found
        }
    }
    public func release(_ target: AppTarget) {
        Self.inputLock.lock(); defer { Self.inputLock.unlock() }
        let found = enforcers.withLock { $0.removeValue(forKey: target.pid ?? 0) }
        found?.release()
    }
    public func releaseAll() {
        Self.inputLock.lock(); defer { Self.inputLock.unlock() }
        let found = enforcers.withLock { state in let found = Array(state.values); state.removeAll(); return found }
        for enforcer in found { enforcer.release() }
    }
    func reportsFrontmost(_ pid: pid_t) -> Bool? { (try? AX.backend.get(AX.backend.app(pid: pid), "AXFrontmost")) as? Bool }
    public func bringBack(_ pid: pid_t) throws {
        // Human-priority restoration must not wait behind another app's physical
        // action (which may be a long drag/hold). Callbacks own their synchronization.
        try AX.backend.set(AX.backend.app(pid: pid), "AXFrontmost", true)
        let end = system.now() + Self.restoreWait
        while system.frontPID() != pid {
            if system.now() >= end { throw Errors.make("front_not_back") }; system.sleep(Self.poll)
        }
    }
    func watchLeak(_ pid: pid_t, before: pid_t, since: TimeInterval) {
        let backend = AX.backend
        system.background { [self] in
            AX.withBackend(backend) {
                while system.now() < since + Self.leakWatch {
                    // Intentionally independent of inputLock: the person's app
                    // must be restored even while another action is executing.
                    if system.frontPID() == pid {
                        if !system.personWent(pid, since) { try? bringBack(before) }
                        return
                    }
                    system.sleep(Self.poll)
                }
            }
        }
    }
    public final class Enforcer: Sendable {
        public let pid: pid_t
        let focus: Focus
        private struct Belief: Sendable {
            var active = false, focused = false
            var revision: UInt64 = 0
        }
        private let belief = OSAllocatedUnfairLock(initialState: Belief())
        public init(pid: pid_t, focus: Focus = .shared) { self.pid = pid; self.focus = focus }
        public var reallyActive: Bool { focus.system.frontPID() == pid }
        public var believesActive: Bool {
            if reallyActive { return true }
            let revision = belief.withLock { $0.revision }
            // Ordinary reads stay on their caller and do not take the global
            // physical-input lock. A slow app cannot stall another app's getter.
            let reported = focus.reportsFrontmost(pid)
            return belief.withLock { belief in
                // release/enforce or a reentrant/newer sample wins over this read.
                if belief.revision == revision, let reported {
                    belief.active = reported; belief.focused = belief.focused && reported
                    belief.revision &+= 1
                }
                return belief.active
            }
        }
        public var believesFocus: Bool {
            reallyActive || (believesActive && belief.withLock { $0.focused })
        }
        public func active<T>(window: ComputerUseCore.WindowRef?, _ work: () throws -> T) throws -> T {
            Focus.inputLock.lock(); defer { Focus.inputLock.unlock() }
            let before = focus.system.frontPID(), since = focus.system.now()
            var activated = false
            func restore() throws {
                let leaked = before != 0 && before != pid && focus.system.frontPID() == pid
                if leaked && !focus.system.personWent(pid, since) { try focus.bringBack(before) }
                else if before != 0 && before != pid && activated && !leaked { focus.watchLeak(pid, before: before, since: since) }
            }
            let result: Result<T, Error>
            do { activated = try enforce(window); result = .success(try work()) } catch { result = .failure(error) }
            try restore() // Like finally: restoration failure takes precedence.
            return try result.get()
        }
        @discardableResult public func enforce(_ window: ComputerUseCore.WindowRef?) throws -> Bool {
            Focus.inputLock.lock(); defer { Focus.inputLock.unlock() }
            if believesFocus { return false }
            let activated = !believesActive
            if !activated { focus.system.post(pid, Events.notice(Focus.processNotice, subtype: Focus.keyFocusReturned)) }
            else {
                focus.system.freeze()
                let clicked: Bool
                do { clicked = try activate(window); focus.system.thaw() } catch { focus.system.thaw(); throw error }
                // Do not overtake activation: a menu opened before this click arrives
                // is closed by the click. Wait for the app to work through the events.
                let end = focus.system.now() + Focus.believeWait
                while focus.system.now() < end {
                    if focus.reportsFrontmost(pid) == true {
                        if !clicked { break }
                        if let window, (try? AX.backend.get(window.element, "AXMain")) as? Bool == true { break }
                    }
                    focus.system.sleep(Focus.poll)
                }
            }
            belief.withLock { $0.active = true; $0.focused = true; $0.revision &+= 1 }
            return activated
        }
        @discardableResult public func activate(_ window: ComputerUseCore.WindowRef?) throws -> Bool {
            Focus.inputLock.lock(); defer { Focus.inputLock.unlock() }
            let id = window?.windowID ?? 0
            focus.system.post(pid, Events.notice(Focus.appKitDefined, subtype: Focus.activated, windowID: id, flags: id == 0 ? 0 : Focus.activationFlags))
            guard id != 0, let window, let point = try AX.backend.get(window.element, "AXActivationPoint") as? CGPoint else { return false }
            for kind in ["down", "up"] { focus.system.post(pid, Events.mouse(kind, point: point, window: window)) }
            return true
        }
        public func release() {
            Focus.inputLock.lock(); defer { Focus.inputLock.unlock() }
            if !reallyActive && believesActive {
                for (kind, subtype) in [(Focus.processNotice, Focus.keyFocusRemoved), (Focus.appKitDefined, Focus.deactivated)] { focus.system.post(pid, Events.notice(kind, subtype: subtype)) }
            }
            belief.withLock { $0.active = false; $0.focused = false; $0.revision &+= 1 }
        }
    }
}
