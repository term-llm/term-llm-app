import AppKit
import ComputerUseCore
import os

/// The person comes first: calls wait for five seconds of quiet, then actions
/// remain blocked until the agent reads the changed app.
/// Synchronous worker interface. Only the tap/source lifecycle belongs to main;
/// clocks, HID fallback, AX menu work and injected callbacks run on their caller.
/// The production menu/window defaults still call the legacy Swift 5 Windows
/// adapter synchronously. This checked worker does not make Windows, Apps, Focus,
/// or arbitrary graphs captured by external hooks Sendable. Custom hooks must
/// uphold their @Sendable contract independently.
public final class Person: Sendable {
    public static let eventTypes: [UInt32] = [1, 3, 25, 22, 10]
    public static let keyDown: UInt32 = 10, escape = 53, tab = 48
    public static let clicks: [UInt32] = [1, 3, 25], dock = "com.apple.dock"
    public static let debounceS = 5.0, waitCapS = 100.0, pollS = 0.25
    public struct Hooks: Sendable {
        public let pointerActivity: @Sendable (String) -> Void
        public let shownMenu: @Sendable (AppTarget) throws -> UIElementRef?
        public let post: @Sendable (pid_t, CGEvent) -> Void
        public let later: @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void
        public init(
            pointerActivity: @escaping @Sendable (String) -> Void = { _ in },
            shownMenu: @escaping @Sendable (AppTarget) throws -> UIElementRef? = { try Windows.shared.shownMenu($0) },
            post: @escaping @Sendable (pid_t, CGEvent) -> Void = { Events.post($0, event: $1) },
            later: @escaping @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void = { delay, work in
                DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work)
            }
        ) {
            self.pointerActivity = pointerActivity; self.shownMenu = shownMenu
            self.post = post; self.later = later
        }
    }
    public struct System: Sendable {
        public let now: @Sendable () -> TimeInterval
        public let sleep: @Sendable (TimeInterval) -> Void
        public let frontmostPID: @Sendable () -> pid_t
        public let bundleOf: @Sendable (pid_t) -> String
        public let hidIdle: @Sendable ([UInt32]) -> TimeInterval
        public let secureInputPID: @Sendable () -> pid_t?
        public let windowPID: @Sendable (UInt32) -> pid_t
        public let canListen: @Sendable () -> Bool
        public init(
            now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
            sleep: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
            frontmostPID: @escaping @Sendable () -> pid_t = { NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0 },
            bundleOf: (@Sendable (pid_t) -> String)? = nil,
            hidIdle: @escaping @Sendable ([UInt32]) -> TimeInterval = { kinds in
                kinds.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: $0)!) }.min() ?? .infinity
            },
            secureInputPID: @escaping @Sendable () -> pid_t? = { Person.secureInputPID() },
            windowPID: @escaping @Sendable (UInt32) -> pid_t = { id in Windows.systemRows(8, id).first?.pid ?? 0 },
            canListen: @escaping @Sendable () -> Bool = { CGPreflightListenEventAccess() }
        ) {
            self.now = now; self.sleep = sleep; self.frontmostPID = frontmostPID
            self.bundleOf = bundleOf ?? { PersonBundleIDs.shared.bundleOf($0) }
            self.hidIdle = hidIdle; self.secureInputPID = secureInputPID; self.windowPID = windowPID; self.canListen = canListen
        }
    }
    /// A tap's opaque SDK values never cross this main-actor seam. Fakes need no
    /// CoreGraphics objects, permission grant, or running helper loop.
    @MainActor public protocol Tap: AnyObject, Sendable {
        func install()
        func enable()
        func remove()
    }
    /// `create` returns an uninstalled handle whose `remove` also works before
    /// installation. `schedule` must retain and execute every submitted callback
    /// once on main, including cleanup after `isRunning` becomes false. If the
    /// main loop has exited, the default queue retains cleanup until it drains.
    public struct Watch: Sendable {
        public let isRunning: @Sendable () -> Bool
        public let schedule: @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void
        public let create: @MainActor @Sendable (@escaping @MainActor @Sendable (Input) -> Void) -> (any Tap)?
        public init(
            isRunning: @escaping @Sendable () -> Bool = { MainThread.isRunning },
            schedule: @escaping @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void = { work in DispatchQueue.main.async(execute: work) },
            create: (@MainActor @Sendable (@escaping @MainActor @Sendable (Input) -> Void) -> (any Tap)?)? = nil
        ) {
            self.isRunning = isRunning; self.schedule = schedule
            self.create = create ?? { LivePersonTap.create($0) }
        }
    }
    /// Operation-local CGEvent fields copied before delivery. No CGEvent is sent
    /// between workers or retained in worker state.
    public struct Input: Sendable {
        public var kind: UInt32, sourcePID: pid_t, tag: Int64, targetPID: pid_t, window: UInt32, keycode: Int, command: Bool
        public init(kind: UInt32, sourcePID: pid_t = 0, tag: Int64 = 0, targetPID: pid_t = 0,
                    window: UInt32 = 0, keycode: Int = 0, command: Bool = false) {
            self.kind = kind; self.sourcePID = sourcePID; self.tag = tag; self.targetPID = targetPID
            self.window = window; self.keycode = keycode; self.command = command
        }
        fileprivate init(kind: UInt32, event: CGEvent) {
            self.init(kind: kind,
                      sourcePID: pid_t(truncatingIfNeeded: event.getIntegerValueField(.eventSourceUnixProcessID)),
                      tag: event.getIntegerValueField(.eventSourceUserData),
                      targetPID: pid_t(truncatingIfNeeded: event.getIntegerValueField(.eventTargetUnixProcessID)),
                      window: UInt32(truncatingIfNeeded: event.getIntegerValueField(.mouseEventWindowUnderMousePointer)),
                      keycode: Int(event.getIntegerValueField(.keyboardEventKeycode)), command: event.flags.contains(.maskCommand))
        }
    }
    // Immutable production composition; Focus's legacy default also reads this
    // same instance. Runtime must not replace hooks after workers have started.
    public static let shared = Person(hooks: Hooks(pointerActivity: { _ = Presence.shared.pointerActivity($0) }))
    public let hooks: Hooks, system: System
    private struct State: Sendable {
        var drivers: [String: Set<String>] = [:], targets: [String: AppTarget] = [:]
        var quietAt: [String: TimeInterval] = [:], awaitingQuiet: [String: UInt64] = [:]
        var nextQuiet: UInt64 = 0
        var ownPID: pid_t = 0
        var clicked: (pid_t, TimeInterval) = (0, -.infinity), switched: TimeInterval = -.infinity
        var simulatedTapAvailable = false
    }
    private enum InputEffect: Sendable { case ignored, stray(AppTarget), human(String, UInt64?) }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let available: OSAllocatedUnfairLock<Bool>
    private let tapOwner: PersonTapOwner
    private let watch: Watch
    public var tapAvailable: Bool { available.withLock { $0 } || state.withLock { $0.simulatedTapAvailable } }
    /// Explicit fake availability; never creates a tap.
    public var simulatedTapAvailable: Bool {
        get { state.withLock { $0.simulatedTapAvailable } }
        set { state.withLock { $0.simulatedTapAvailable = newValue } }
    }
    var ownPID: pid_t { state.withLock { $0.ownPID } }
    var quietAt: [String: TimeInterval] { state.withLock { $0.quietAt } }
    public init(system: System = .init(), hooks: Hooks = .init(), watch: Watch = .init()) {
        self.system = system; self.hooks = hooks; self.watch = watch
        let available = OSAllocatedUnfairLock(initialState: false)
        self.available = available; self.tapOwner = PersonTapOwner(watch: watch, available: available)
    }
    public func driven() -> [AppTarget] { state.withLock { Array($0.targets.values) } }
    public func gate(agent: AgentSession, target: AppTarget, stateRead: Bool, abandoned: () -> Bool = { false }) throws {
        if agent.ended { throw Errors.make("turn_ended") }
        let until = system.now() + Self.waitCapS
        state.withLock { $0.drivers[target.path, default: []].insert(agent.key); $0.targets[target.path] = target }
        if !tapAvailable || system.secureInputPID() != nil { touchFromIdleTime(target) }
        var quiet: TimeInterval?
        while true {
            let now = system.now(); quiet = state.withLock { $0.quietAt[target.path] }
            if quiet == nil || now >= quiet! { break }
            if now >= until { throw Errors.make("still_interacting", ["app_path": target.path]) }
            if abandoned() { throw Errors.make("request_timed_out") }; system.sleep(Self.pollS)
        }
        if quiet != nil && !stateRead { throw Errors.make("user_changed", ["app_path": target.path]) }
    }
    public func afterStateRead(_ target: AppTarget) {
        let now = system.now()
        state.withLock { if ($0.quietAt[target.path] ?? .infinity) <= now { $0.quietAt.removeValue(forKey: target.path) } }
    }
    public func interrupted(_ target: AppTarget, since: TimeInterval) -> Bool {
        state.withLock { ($0.quietAt[target.path] ?? -.infinity) - Self.debounceS >= since }
    }
    public func turnEnded(_ agent: AgentSession) {
        agent.denied.removeAll()
        state.withLock { state in
            for path in Array(state.drivers.keys) {
                state.drivers[path]?.remove(agent.key)
                if state.drivers[path]?.isEmpty == true {
                    state.drivers.removeValue(forKey: path); state.targets.removeValue(forKey: path); state.quietAt.removeValue(forKey: path)
                    // A previously scheduled callback must not affect a later turn.
                    state.awaitingQuiet.removeValue(forKey: path)
                }
            }
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
        // All dependency calls precede the claim. Revalidate the target under the
        // lock: a reentrant lookup may end its turn. Claimed advisory callbacks
        // run outside the lock and may finish after that turn ends.
        let bundle = Self.clicks.contains(kind) && !stray ? system.bundleOf(pid) : ""
        let path = drivenPath(pid)
        let effect: InputEffect = state.withLock { state in
            if Self.clicks.contains(kind) && !stray {
                if bundle == Self.dock { state.switched = max(state.switched, now) }
                else if now >= state.clicked.1 { state.clicked = (pid, now) }
            } else if kind == Self.keyDown && keycode == Self.tab && command { state.switched = max(state.switched, now) }
            guard let path, let target = state.targets[path] else { return .ignored }
            if stray { return .stray(target) }
            state.quietAt[path] = max(state.quietAt[path] ?? -.infinity, now + Self.debounceS)
            if state.awaitingQuiet[path] != nil { return .human(path, nil) }
            state.nextQuiet &+= 1; state.awaitingQuiet[path] = state.nextQuiet
            return .human(path, state.nextQuiet)
        }
        switch effect {
        case .ignored: break
        case .stray(let target):
            // Close the pop-up without counting input meant for the person's app.
            hooks.later(0) { [weak self] in self?.closeMenu(target) }
        case .human(let path, let token):
            hooks.pointerActivity("paused")
            if let token { scheduleQuiet(path, token: token, delay: Self.debounceS) }
        }
    }
    private func scheduleQuiet(_ path: String, token: UInt64, delay: TimeInterval) {
        hooks.later(delay) { [weak self] in self?.checkQuiet(path, token: token) }
    }
    private func checkQuiet(_ path: String, token: UInt64) {
        let now = system.now()
        let left: TimeInterval? = state.withLock { state in
            guard state.awaitingQuiet[path] == token else { return nil }
            let left = (state.quietAt[path] ?? 0) - now
            if left <= 0 { state.awaitingQuiet.removeValue(forKey: path) }
            return left
        }
        guard let left else { return }
        if left > 0 { scheduleQuiet(path, token: token, delay: left) }
        else { hooks.pointerActivity("loading") }
    }
    public func closeMenu(_ target: AppTarget) {
        do { if let menu = try hooks.shownMenu(target) { try AX.backend.perform(menu, "AXCancel"); return } } catch {}
        guard let pid = target.pid else { return }
        for down in [true, false] { hooks.post(pid, Events.key(Self.escape, flags: 0, down: down)) }
    }
    public func touchFromIdleTime(_ target: AppTarget) {
        // Only hardware state: private event state can hang. Pid-targeted harness
        // events do not reset hardware idle time. It cannot name an app, so only
        // count it for the real front app.
        let idle = system.hidIdle(Self.eventTypes)
        guard idle < Self.debounceS, let pid = target.pid, system.frontmostPID() == pid else { return }
        let quiet = system.now() + Self.debounceS - idle
        state.withLock { $0.quietAt[target.path] = max(quiet, $0.quietAt[target.path] ?? quiet) }
    }
    public func wentTo(_ pid: pid_t, since: TimeInterval) -> Bool {
        if !tapAvailable { return system.now() - system.hidIdle(Self.clicks) >= since }
        // Typing elsewhere is not proof the person went to this app: keys can
        // also follow an accidental switch.
        return state.withLock { max($0.switched, $0.clicked.0 == pid ? $0.clicked.1 : -.infinity) >= since }
    }
    public static func secureInputPID() -> pid_t? {
        secureInputPID(session: CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:])
    }
    public static func secureInputPID(session: [String: Any]) -> pid_t? {
        (session["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value
    }
    public func targetPID(_ event: CGEvent) -> pid_t { targetPID(Input(kind: event.type.rawValue, event: event)) }
    private func targetPID(_ input: Input) -> pid_t {
        if input.targetPID != 0 { return input.targetPID }
        if input.window != 0 { let owner = system.windowPID(input.window); if owner != 0 { return owner } }
        return system.frontmostPID()
    }
    public func stray(_ event: CGEvent, kind: UInt32, pid: pid_t) -> Bool { stray(Input(kind: kind, event: event), pid: pid) }
    private func stray(_ input: Input, pid: pid_t) -> Bool {
        if input.kind == Self.keyDown { return pid != system.frontmostPID() }
        let owner = input.window == 0 ? 0 : system.windowPID(input.window)
        return owner != 0 && owner != pid
    }
    /// Listen-only callback logic: never suppress or modify the person's input.
    public func onEvent(kind: UInt32, event: CGEvent, reenable: () -> Void) {
        onInput(Input(kind: kind, event: event), reenable: reenable)
    }
    public func onInput(_ input: Input, reenable: () -> Void = {}) {
        guard Self.eventTypes.contains(input.kind) else { reenable(); return }
        let pid = driven().isEmpty ? 0 : targetPID(input)
        saw(kind: input.kind, sourcePID: input.sourcePID, tag: input.tag, pid: pid,
            keycode: input.keycode, stray: pid != 0 && stray(input, pid: pid), command: input.command)
    }
    public func startWatch(ownPID: pid_t) {
        state.withLock { $0.ownPID = ownPID }
        // No run-loop fallback may create a real tap or even perform a preflight.
        // Preflight stays on the caller, not behind a global main-thread hop.
        guard watch.isRunning(), system.canListen() else { return }
        let owner = tapOwner
        watch.schedule { [weak self] in
            guard let self else { return }
            owner.start { [weak self] input in self?.onInput(input) }
        }
    }
    /// Enqueue source teardown; worker state remains usable synchronously. Tap
    /// availability becomes false when main claims the stop, before removal.
    public func stopWatch() {
        let owner = tapOwner
        watch.schedule { owner.stop() }
    }
}

/// Main owns the whole SDK resource lifecycle. Worker reads see only `available`.
/// A generation invalidates callbacks/partially created resources on reentry.
@MainActor private final class PersonTapOwner {
    private let watch: Person.Watch
    private let available: OSAllocatedUnfairLock<Bool>
    private var tap: (any Person.Tap)?
    private var starting = false
    private var generation: UInt64 = 0
    nonisolated init(watch: Person.Watch, available: OSAllocatedUnfairLock<Bool>) {
        self.watch = watch; self.available = available
    }
    func start(deliver: @escaping @Sendable (Person.Input) -> Void) {
        guard tap == nil, !starting else { return }
        starting = true; generation &+= 1
        let ticket = generation
        let created = watch.create { [weak self] input in
            guard let self, self.generation == ticket, let tap = self.tap else { return }
            if Person.eventTypes.contains(input.kind) { deliver(input) } else { tap.enable() }
        }
        guard generation == ticket else { created?.remove(); return }
        starting = false
        guard let created else { return }
        tap = created
        created.install()
        guard generation == ticket else { return }
        available.withLock { $0 = true }
        created.enable()
    }
    func stop() {
        generation &+= 1; starting = false
        let old = tap; tap = nil
        available.withLock { $0 = false }
        old?.remove()
    }
    deinit {
        available.withLock { $0 = false }
        // Retain the handle (and callback context) until main removes its source.
        // No owner/Person is captured; an in-flight callback holds its own context.
        if let tap { watch.schedule { tap.remove() } }
    }
}

@MainActor private final class LivePersonTap: Person.Tap {
    private final class Context: Sendable {
        let deliver: @MainActor @Sendable (Person.Input) -> Void
        init(_ deliver: @escaping @MainActor @Sendable (Person.Input) -> Void) { self.deliver = deliver }
    }
    private let context: Context
    private let tap: CFMachPort
    private let source: CFRunLoopSource
    private var removed = false
    private init(context: Context, tap: CFMachPort, source: CFRunLoopSource) {
        self.context = context; self.tap = tap; self.source = source
    }
    static func create(_ deliver: @escaping @MainActor @Sendable (Person.Input) -> Void) -> LivePersonTap? {
        let context = Context(deliver)
        let callback: CGEventTapCallBack = { _, kind, event, raw in
            // Listen-only: always return the original event, never suppress or
            // modify the person's real input.
            guard let raw else { return Unmanaged.passUnretained(event) }
            let context = Unmanaged<Context>.fromOpaque(raw).takeUnretainedValue()
            // Installed exclusively on the main run loop. Retain through delivery,
            // including reentrant teardown; invalidation prevents future calls.
            MainActor.assumeIsolated { context.deliver(Person.Input(kind: kind.rawValue, event: event)) }
            withExtendedLifetime(context) {}
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgAnnotatedSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                         eventsOfInterest: Person.eventTypes.reduce(0) { $0 | (1 << $1) },
                                         callback: callback, userInfo: Unmanaged.passUnretained(context).toOpaque()) else { return nil }
        guard let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else { CFMachPortInvalidate(tap); return nil }
        return LivePersonTap(context: context, tap: tap, source: source)
    }
    func install() { if !removed { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) } }
    func enable() { if !removed { CGEvent.tapEnable(tap: tap, enable: true) } }
    func remove() {
        guard !removed else { return }; removed = true
        CFMachPortInvalidate(tap)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        withExtendedLifetime(context) {}
    }
    deinit {
        let wasRemoved = removed
        assert(wasRemoved, "Tap/source must be removed before releasing their callback context")
    }
}

private final class PersonBundleIDs: Sendable {
    static let shared = PersonBundleIDs()
    private struct Cache: Sendable { var values: [pid_t: String] = [:], order: [pid_t] = [] }
    private let cache = OSAllocatedUnfairLock(initialState: Cache())
    func bundleOf(_ pid: pid_t) -> String {
        let sampled = cache.withLock { $0.values[pid] } ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        return cache.withLock { cache in
            let value = cache.values[pid] ?? sampled
            cache.values[pid] = value; cache.order.removeAll { $0 == pid }; cache.order.append(pid)
            if cache.order.count > 256 { cache.values.removeValue(forKey: cache.order.removeFirst()) }
            return value
        }
    }
}
