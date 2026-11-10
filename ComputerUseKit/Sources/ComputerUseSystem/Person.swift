import AppKit
import ComputerUseCore
import os

/// The person comes first. A listen-only tap records their input; calls wait until
/// five seconds of quiet, then actions fail until the agent reads the changed app.
public final class Person {
    public static let eventTypes: [UInt32] = [1, 3, 25, 22, 10]
    public static let keyDown: UInt32 = 10, escape = 53, tab = 48
    public static let clicks: [UInt32] = [1, 3, 25], dock = "com.apple.dock"
    public static let debounceS = 5.0, waitCapS = 100.0, pollS = 0.25
    public struct Hooks {
        // ComputerUseRuntime installs Presence.pointerActivity (paused/loading).
        public var pointerActivity: (String) -> Void = { _ in }
        public var shownMenu: (AppTarget) throws -> UIElementRef? = { try Windows.shared.shownMenu($0) }
        public var post: (pid_t, CGEvent) -> Void = { Events.post($0, event: $1) }
        public var later: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: DispatchWorkItem(block: work)) }
        public init() {}
    }
    public struct System {
        public var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        public var sleep: (TimeInterval) -> Void = Thread.sleep(forTimeInterval:)
        public var frontmostPID: () -> pid_t = { NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0 }
        public var bundleOf: (pid_t) -> String = { PersonBundleIDs.shared.bundleOf($0) }
        public var hidIdle: ([UInt32]) -> TimeInterval = { kinds in kinds.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: $0)!) }.min() ?? .infinity }
        public var secureInputPID: () -> pid_t? = Person.secureInputPID
        public var windowPID: (UInt32) -> pid_t = { id in Windows.systemRows(8, id).first?.pid ?? 0 }
        public var canListen: () -> Bool = { CGPreflightListenEventAccess() }
        public init() {}
    }
    public static let shared = Person()
    public var hooks: Hooks; public var system: System
    let lock = NSRecursiveLock()
    var drivers: [String: Set<String>] = [:], targets: [String: AppTarget] = [:]
    var quietAt: [String: TimeInterval] = [:], awaitingQuiet: Set<String> = []
    var ownPID: pid_t = 0
    var clicked: (pid_t, TimeInterval) = (0, -.infinity), switched: TimeInterval = -.infinity
    private var tap: CFMachPort?, source: CFRunLoopSource?
    /// Injectable tap availability for no-grant tests, not a request for permission.
    public var tapAvailable: Bool { tap != nil || simulatedTapAvailable }
    public var simulatedTapAvailable = false
    public init(system: System = .init(), hooks: Hooks = .init()) { self.system = system; self.hooks = hooks }
    public func driven() -> [AppTarget] { lock.lock(); defer { lock.unlock() }; return Array(targets.values) }
    public func gate(agent: AgentSession, target: AppTarget, stateRead: Bool, abandoned: () -> Bool = { false }) throws {
        if agent.ended { throw Errors.make("turn_ended") }
        let until = system.now() + Self.waitCapS
        lock.lock(); drivers[target.path, default: []].insert(agent.key); targets[target.path] = target; lock.unlock()
        if !tapAvailable || system.secureInputPID() != nil { touchFromIdleTime(target) }
        var quiet: TimeInterval?
        while true {
            let now = system.now(); lock.lock(); quiet = quietAt[target.path]; lock.unlock()
            if quiet == nil || now >= quiet! { break }
            if now >= until { throw Errors.make("still_interacting", ["app_path": target.path]) }
            if abandoned() { throw Errors.make("request_timed_out") }; system.sleep(Self.pollS)
        }
        if quiet != nil && !stateRead { throw Errors.make("user_changed", ["app_path": target.path]) }
    }
    public func afterStateRead(_ target: AppTarget) {
        lock.lock(); defer { lock.unlock() }
        if (quietAt[target.path] ?? .infinity) <= system.now() { quietAt.removeValue(forKey: target.path) }
    }
    public func interrupted(_ target: AppTarget, since: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }; return (quietAt[target.path] ?? -.infinity) - Self.debounceS >= since
    }
    public func turnEnded(_ agent: AgentSession) {
        agent.denied.removeAll()
        lock.lock(); defer { lock.unlock() }
        for path in Array(drivers.keys) {
            drivers[path]?.remove(agent.key)
            if drivers[path]?.isEmpty == true { drivers.removeValue(forKey: path); targets.removeValue(forKey: path); quietAt.removeValue(forKey: path) }
        }
    }
    public func drivenPath(_ pid: pid_t) -> String? {
        let targets = driven()
        if let target = targets.first(where: { $0.pid == pid }) { return target.path }
        let bundle = targets.isEmpty ? "" : system.bundleOf(pid)
        return targets.first { !bundle.isEmpty && $0.bundleID == bundle }?.path
    }
    public func saw(kind: UInt32, sourcePID: pid_t, tag: Int64, pid: pid_t, keycode: Int = 0, stray: Bool = false, command: Bool = false) {
        guard Self.eventTypes.contains(kind), sourcePID != ownPID, tag != Events.ownTag else { return }
        let now = system.now()
        lock.lock(); defer { lock.unlock() }
        if Self.clicks.contains(kind) && !stray {
            if system.bundleOf(pid) == Self.dock { switched = now } else { clicked = (pid, now) }
        } else if kind == Self.keyDown && keycode == Self.tab && command { switched = now }
        guard let path = drivenPath(pid) else { return }
        if stray, let target = targets[path] {
            // A background web pop-up stole input intended for the person's app.
            // Close it so the next event reaches that app; don't count this event.
            hooks.later(0) { [weak self] in self?.closeMenu(target) }; return
        }
        quietAt[path] = now + Self.debounceS
        hooks.pointerActivity("paused"); tellWhenQuiet(path)
    }
    func tellWhenQuiet(_ path: String) {
        if awaitingQuiet.contains(path) { return }
        awaitingQuiet.insert(path)
        hooks.later(Self.debounceS) { [weak self] in self?.checkQuiet(path) }
    }
    func checkQuiet(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        let left = (quietAt[path] ?? 0) - system.now()
        if left > 0 { hooks.later(left) { [weak self] in self?.checkQuiet(path) } }
        else { awaitingQuiet.remove(path); hooks.pointerActivity("loading") }
    }
    public func closeMenu(_ target: AppTarget) {
        do { if let menu = try hooks.shownMenu(target) { try AX.backend.perform(menu, "AXCancel"); return } } catch {}
        guard let pid = target.pid else { return }
        for down in [true, false] { hooks.post(pid, Events.key(Self.escape, flags: 0, down: down)) }
    }
    public func touchFromIdleTime(_ target: AppTarget) {
        // Only hardware state: private event state can hang. Pid-targeted harness
        // events do not reset hardware idle time (measured). It cannot name an app,
        // so only count it for the real front app.
        let idle = system.hidIdle(Self.eventTypes)
        guard idle < Self.debounceS, let pid = target.pid, system.frontmostPID() == pid else { return }
        let quiet = system.now() + Self.debounceS - idle
        lock.lock(); quietAt[target.path] = max(quiet, quietAt[target.path] ?? quiet); lock.unlock()
    }
    public func wentTo(_ pid: pid_t, since: TimeInterval) -> Bool {
        if !tapAvailable { return system.now() - system.hidIdle(Self.clicks) >= since }
        lock.lock(); defer { lock.unlock() }
        // Typing elsewhere says nothing: keys also follow an accidental switch.
        return max(switched, clicked.0 == pid ? clicked.1 : -.infinity) >= since
    }
    public static func secureInputPID() -> pid_t? {
        secureInputPID(session: CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:])
    }
    public static func secureInputPID(session: [String: Any]) -> pid_t? {
        (session["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value
    }
    public func targetPID(_ event: CGEvent) -> pid_t {
        let pid = pid_t(truncatingIfNeeded: event.getIntegerValueField(.eventTargetUnixProcessID))
        if pid != 0 { return pid }
        let window = UInt32(truncatingIfNeeded: event.getIntegerValueField(.mouseEventWindowUnderMousePointer))
        if window != 0 { let owner = system.windowPID(window); if owner != 0 { return owner } }
        return system.frontmostPID()
    }
    public func stray(_ event: CGEvent, kind: UInt32, pid: pid_t) -> Bool {
        if kind == Self.keyDown { return pid != system.frontmostPID() }
        let window = UInt32(truncatingIfNeeded: event.getIntegerValueField(.mouseEventWindowUnderMousePointer))
        let owner = window == 0 ? 0 : system.windowPID(window)
        return owner != 0 && owner != pid
    }
    /// Tap callback logic, separated so tests can feed events without a live tap.
    /// Only read/store here; never suppress or modify the person's input.
    public func onEvent(kind: UInt32, event: CGEvent, reenable: () -> Void) {
        guard Self.eventTypes.contains(kind) else { reenable(); return }
        let pid = driven().isEmpty ? 0 : targetPID(event)
        saw(kind: kind, sourcePID: pid_t(truncatingIfNeeded: event.getIntegerValueField(.eventSourceUnixProcessID)),
            tag: event.getIntegerValueField(.eventSourceUserData), pid: pid,
            keycode: Int(event.getIntegerValueField(.keyboardEventKeycode)),
            stray: pid != 0 && stray(event, kind: kind, pid: pid), command: event.flags.contains(.maskCommand))
    }
    public func startWatch(ownPID: pid_t) {
        self.ownPID = ownPID
        MainThread.onMain { [self] in startTap() }
    }
    private func startTap() {
        guard tap == nil, system.canListen() else { return } // No grant: no tap/prompt.
        let callback: CGEventTapCallBack = { _, kind, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let person = Unmanaged<Person>.fromOpaque(context).takeUnretainedValue()
            person.onEvent(kind: kind.rawValue, event: event) {
                if let tap = person.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            }
            return Unmanaged.passUnretained(event)
        }
        tap = CGEvent.tapCreate(tap: .cgAnnotatedSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                eventsOfInterest: Self.eventTypes.reduce(0) { $0 | (1 << $1) }, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        if let tap {
            source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes); CGEvent.tapEnable(tap: tap, enable: true)
        }
    }
    deinit {
        if let tap { CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    }
}

private final class PersonBundleIDs: Sendable {
    static let shared = PersonBundleIDs()
    private struct Cache: Sendable { var values: [pid_t: String] = [:], order: [pid_t] = [] }
    private let cache = OSAllocatedUnfairLock(initialState: Cache())
    func bundleOf(_ pid: pid_t) -> String {
        cache.withLock { cache in
            let value = cache.values[pid] ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
            cache.values[pid] = value; cache.order.removeAll { $0 == pid }; cache.order.append(pid)
            if cache.order.count > 256 { cache.values.removeValue(forKey: cache.order.removeFirst()) }
            return value
        }
    }
}
