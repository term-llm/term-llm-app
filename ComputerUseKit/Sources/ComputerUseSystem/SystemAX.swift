import ApplicationServices
import ComputerUseCore
import Foundation
import os

/// Thin wrappers over accessibility. Any thread may call them. No messaging timeout
/// is set by default: the system default applies to every call, as upstream.
public final class SystemAX: AXBackend {
    // ComputerUseRuntime installs SystemAX in AX.backend before serving requests.

    // The one-call hierarchy copy is deliberately off upstream: measured on Lab
    // (12 Oct) it took 11 ms against 30 ms for the walk, but left out a web view's
    // page (15 elements, the walk 53 lines). Use the ordinary batched walk instead.
    // The installed copy is immutable. Builders may replace callbacks before init;
    // @Sendable checks their captured graph rather than trusting a let closure.
    public struct Calls: Sendable {
        public var get: @Sendable (AXUIElement, String) -> (Int32, Any?) = { el, name in
            var value: CFTypeRef?
            let code = AXUIElementCopyAttributeValue(el, name as CFString, &value)
            return (code.rawValue, value)
        }
        public var names: @Sendable (AXUIElement) -> [String] = { el in
            var value: CFArray?
            return AXUIElementCopyAttributeNames(el, &value) == .success ? value as? [String] ?? [] : []
        }
        public var getMany: @Sendable (AXUIElement, [String]) -> (Int32, [Any]) = { el, names in
            var values: CFArray?
            let code = AXUIElementCopyMultipleAttributeValues(el, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values)
            return (code.rawValue, values as? [Any] ?? [])
        }
        public var set: @Sendable (AXUIElement, String, CFTypeRef) -> Int32 = { AXUIElementSetAttributeValue($0, $1 as CFString, $2).rawValue }
        public var settable: @Sendable (AXUIElement, String) -> Bool = { el, name in
            var flag = DarwinBoolean(false)
            return AXUIElementIsAttributeSettable(el, name as CFString, &flag) == .success && flag.boolValue
        }
        public var actionNames: @Sendable (AXUIElement) -> [String] = { el in
            var names: CFArray?
            return AXUIElementCopyActionNames(el, &names) == .success ? names as? [String] ?? [] : []
        }
        public var actionDescription: @Sendable (AXUIElement, String) -> String = { el, name in
            var text: CFString?
            return AXUIElementCopyActionDescription(el, name as CFString, &text) == .success ? text as String? ?? "" : ""
        }
        public var perform: @Sendable (AXUIElement, String) -> Int32 = { AXUIElementPerformAction($0, $1 as CFString).rawValue }
        public var param: @Sendable (AXUIElement, String, CFTypeRef) -> Any? = { el, name, argument in
            var value: CFTypeRef?
            return AXUIElementCopyParameterizedAttributeValue(el, name as CFString, argument, &value) == .success ? value : nil
        }
        public var pid: @Sendable (AXUIElement) -> (Int32, pid_t) = { el in
            var pid: pid_t = 0
            return (AXUIElementGetPid(el, &pid).rawValue, pid)
        }
        public var at: @Sendable (AXUIElement, Float, Float) -> AXUIElement? = { el, x, y in
            var found: AXUIElement?
            return AXUIElementCopyElementAtPosition(el, x, y, &found) == .success ? found : nil
        }
        public var timeout: @Sendable (AXUIElement, Float) -> Void = { _ = AXUIElementSetMessagingTimeout($0, $1) }
        public var windowID: @Sendable (AXUIElement) -> UInt32 = { el in
            guard let call = windowCall else { return 0 }
            var number: UInt32 = 0
            return call(el, &number) == 0 ? number : 0
        }
        public init() {}
    }

    /// Observer operations are injectable without granting AX or observing real apps.
    // Tokens must have their own honest Sendable ownership (not arbitrary objects).
    // This is an injection seam for SystemAX, not an independently scheduled SDK
    // API: clients must not directly interleave lifecycle hooks for the same token.
    // Create/add run on the caller before publication and source installation.
    // Only source install/uninstall main-hop; add/remove can block on target IPC.
    // Teardown is claimed once by Observation, with removal after source uninstall.
    public struct ObserverCalls: Sendable {
        public var create: @Sendable (pid_t, @escaping @Sendable (String, UIElementRef) -> Void) throws -> any Sendable = { pid, callback in
            let context = ObserverCallback(callback)
            var observer: AXObserver?
            try check(AXObserverCreate(pid, { _, element, name, pointer in
                guard let pointer else { return }
                let context = Unmanaged<ObserverCallback>.fromOpaque(pointer).takeUnretainedValue()
                context.callback(name as String, UIElementRef(element))
                withExtendedLifetime(context) {}
            }, &observer).rawValue)
            return ObserverToken(observer: observer!, context: context)
        }
        public var add: @Sendable (any Sendable, AXUIElement, String) -> Int32 = { token, el, name in
            let token = token as! ObserverToken
            return AXObserverAddNotification(token.observer, el, name as CFString, Unmanaged.passUnretained(token.context).toOpaque()).rawValue
        }
        public var remove: @Sendable (any Sendable, AXUIElement, String) -> Void = { token, el, name in
            _ = AXObserverRemoveNotification((token as! ObserverToken).observer, el, name as CFString)
        }
        public var install: @Sendable (any Sendable) -> Void = { token in
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource((token as! ObserverToken).observer), .defaultMode)
        }
        public var uninstall: @Sendable (any Sendable) -> Void = { token in
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource((token as! ObserverToken).observer), .defaultMode)
        }
        /// Synchronous hop used only for source install/uninstall. The default
        /// runs inline when no helper run loop is running, including in tests.
        public var mainHop: @Sendable (@Sendable () -> Void) -> Void = { work in
            MainThread.callOnMain(work)
        }
        public init() {}
    }

    private let calls: Calls
    private let observerCalls: ObserverCalls
    private let messagingTimeout: Float?
    public init(messagingTimeout: Float? = nil, calls: Calls = Calls(), observerCalls: ObserverCalls = ObserverCalls()) {
        self.messagingTimeout = messagingTimeout
        self.calls = calls
        self.observerCalls = observerCalls
    }
    private func raw(_ ref: UIElementRef) -> AXUIElement {
        let element = unsafeDowncast(ref.object, to: AXUIElement.self)
        if let messagingTimeout { calls.timeout(element, messagingTimeout) }
        return element
    }
    public func app(pid: pid_t) -> UIElementRef { UIElementRef(AXUIElementCreateApplication(pid)) }
    public func get(_ element: UIElementRef, _ name: String) throws -> Any? {
        let (code, value) = calls.get(raw(element), name)
        if code != 0 && !AX.missing.contains(code) { try Self.check(code) }
        return code == 0 ? Self.value(value) : nil
    }
    public func names(_ element: UIElementRef) -> [String] { calls.names(raw(element)) }
    public func getMany(_ element: UIElementRef, _ names: [String]) throws -> [Any?] {
        let (code, values) = calls.getMany(raw(element), names)
        try Self.check(code) // A failure of the whole batch is never retried name by name.
        return values.map(Self.value)
    }
    public func set(_ element: UIElementRef, _ name: String, _ value: Any) throws { try Self.check(calls.set(raw(element), name, Self.argument(value))) }
    public func settable(_ element: UIElementRef, _ name: String) -> Bool { calls.settable(raw(element), name) }
    public func actionNames(_ element: UIElementRef) -> [String] { calls.actionNames(raw(element)) }
    public func actionDescription(_ element: UIElementRef, _ action: String) -> String { calls.actionDescription(raw(element), action) }
    /// Names are read now; descriptions are read and cached only when first asked.
    public func actions(_ element: UIElementRef) -> AXActions { AXActions(names: actionNames(element)) { self.actionDescription(element, $0) } }
    public func perform(_ element: UIElementRef, _ action: String) throws { try Self.check(calls.perform(raw(element), action)) }
    public func param(_ element: UIElementRef, _ name: String, _ argument: Any) -> Any? { Self.value(calls.param(raw(element), name, Self.argument(argument))) }
    public func pid(_ element: UIElementRef) throws -> pid_t { let (code, pid) = calls.pid(raw(element)); try Self.check(code); return pid }
    public func windowID(_ element: UIElementRef) -> UInt32 { calls.windowID(raw(element)) }
    public func frame(_ element: UIElementRef) -> CGRect? {
        guard let values = try? getMany(element, ["AXPosition", "AXSize"]), values.count == 2,
              let point = values[0] as? CGPoint, let size = values[1] as? CGSize else { return nil }
        return CGRect(origin: point, size: size)
    }
    public func at(_ app: UIElementRef?, x: Double, y: Double) -> UIElementRef? {
        calls.at(raw(app ?? UIElementRef(AXUIElementCreateSystemWide())), Float(x), Float(y)).map(UIElementRef.init)
    }
    public func alive(_ element: UIElementRef) -> Bool { calls.get(raw(element), "AXRole").0 != AX.invalidElement }
    public func observe(pid: pid_t, element: UIElementRef, names: [String], callback: @escaping @Sendable (String, UIElementRef) -> Void) throws -> AXObservation {
        // The creator owns the unpublished token until all registration completes.
        // AX notification registration is synchronous target IPC: keep it on the
        // calling worker, never inside the main run-loop source hop.
        let delivery = AXObservationDelivery(callback)
        let token: any Sendable
        do { token = try observerCalls.create(pid) { delivery.deliver($0, $1) } }
        catch { delivery.stop(); throw error }
        var registered: [(UIElementRef, String)] = []
        do {
            for name in names {
                let code = observerCalls.add(token, raw(element), name)
                if code == AX.cannotComplete { continue }
                try Self.check(code)
                registered.append((element, name))
            }
        } catch {
            delivery.stop()
            // No source was installed, so cleanup needs no main hop.
            for (element, name) in registered { observerCalls.remove(token, raw(element), name) }
            throw error
        }
        observerCalls.mainHop { observerCalls.install(token) }
        return Observation(token: token, registered: registered, calls: observerCalls, delivery: delivery)
    }

    static func check(_ code: Int32) throws { if code != 0 { throw AX.failure(code) } }

    /// Normalize every value crossing the AX seam, including nested collections.
    static func value(_ input: Any?) -> Any? {
        guard let input, !(input is NSNull) else { return nil }
        let cf = input as CFTypeRef
        let type = CFGetTypeID(cf)
        if type == CFStringGetTypeID() { return input as! String }
        if type == AXUIElementGetTypeID() { return UIElementRef(input as AnyObject) }
        if type == CFBooleanGetTypeID() { return CFBooleanGetValue(unsafeDowncast(cf, to: CFBoolean.self)) }
        if type == CFNumberGetTypeID() {
            let number = unsafeDowncast(cf, to: CFNumber.self)
            return CFNumberIsFloatType(number) ? (input as! NSNumber).doubleValue as Any : (input as! NSNumber).intValue as Any
        }
        if type == AXValueGetTypeID() {
            let ax = unsafeDowncast(cf, to: AXValue.self)
            switch AXValueGetType(ax) {
            case .cgPoint: var v = CGPoint.zero; return AXValueGetValue(ax, .cgPoint, &v) ? v : nil
            case .cgSize: var v = CGSize.zero; return AXValueGetValue(ax, .cgSize, &v) ? v : nil
            case .cgRect: var v = CGRect.zero; return AXValueGetValue(ax, .cgRect, &v) ? v : nil
            case .cfRange:
                var v = CFRange(); return AXValueGetValue(ax, .cfRange, &v) ? NSRange(location: v.location, length: v.length) : nil
            default: return nil // kAXValueAXErrorType (5): a failed name in a batch.
            }
        }
        if type == CFURLGetTypeID() { return input as! URL }
        if type == CFAttributedStringGetTypeID() { return input as! NSAttributedString }
        // The batch itself preserves failed slots as nil. Nested arrays/dictionaries
        // have nonoptional entries at the seam, so omit entries with no value.
        if let array = input as? [Any] { return array.compactMap { value($0) } }
        if let dict = input as? [String: Any] { return dict.compactMapValues { value($0) } }
        return input
    }
    static func argument(_ input: Any) -> CFTypeRef {
        if let ref = input as? UIElementRef { return ref.object }
        if var v = input as? CGPoint { return AXValueCreate(.cgPoint, &v)! }
        if var v = input as? CGSize { return AXValueCreate(.cgSize, &v)! }
        if var v = input as? CGRect { return AXValueCreate(.cgRect, &v)! }
        if let range = input as? NSRange { var v = CFRange(location: range.location, length: range.length); return AXValueCreate(.cfRange, &v)! }
        if let array = input as? [Any] { return array.map(argument) as CFArray }
        if let dict = input as? [String: Any] { return dict.mapValues(argument) as CFDictionary }
        return input as CFTypeRef
    }
    private typealias WindowCall = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> Int32
    // Only the immutable function pointer is shared. PrivateSymbols is a local
    // lookup owner, not a non-Sendable global reachable through Calls.windowID.
    // It intentionally leaves the library loaded for the pointer's lifetime.
    private static let windowCall: WindowCall? = {
        let symbols = PrivateSymbols(path: "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices") { name in
            NSLog("private accessibility call %@ is missing: its step is off", name)
        }
        return symbols.lookup("_AXUIElementGetWindow").map { unsafeBitCast($0, to: WindowCall.self) }
    }()

}

public final class AXActions {
    public let names: [String]
    private let read: (String) -> String
    private var cache: [String: String] = [:]
    private let lock = NSLock()
    init(names: [String], read: @escaping (String) -> String) { self.names = names; self.read = read }
    public subscript(name: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard names.contains(name) else { return nil }
        if let value = cache[name] { return value }
        let value = read(name); cache[name] = value; return value
    }
}
private final class ObserverCallback: Sendable {
    let callback: @Sendable (String, UIElementRef) -> Void
    init(_ callback: @escaping @Sendable (String, UIElementRef) -> Void) { self.callback = callback }
}

/// Narrow SDK interop: AXObserver lacks Sendable. The creator exclusively owns
/// this immutable handle and retained refcon until registration and installation
/// finish. Only source install/uninstall main-hop (or use the no-run-loop inline
/// fallback); one cleanup claimant removes registrations after source uninstall.
/// Callbacks may reenter stop: Observation retains its token for its full lifetime,
/// and the SDK callback retains its context through invocation. No SDK mutable
/// object is exposed to clients. This is NOT a conformance for arbitrary injected
/// token graphs: injected tokens must themselves be Sendable.
private struct ObserverToken: @unchecked Sendable {
    let observer: AXObserver
    let context: ObserverCallback
}

private final class Observation: AXObservation {
    // Keep the SDK observer alive even when stop is reentered by its own callback.
    private let token: any Sendable
    private let registered: OSAllocatedUnfairLock<[(UIElementRef, String)]?>
    private let calls: SystemAX.ObserverCalls
    private let delivery: AXObservationDelivery
    init(token: any Sendable, registered: [(UIElementRef, String)], calls: SystemAX.ObserverCalls, delivery: AXObservationDelivery) {
        self.token = token
        self.registered = OSAllocatedUnfairLock(initialState: registered)
        self.calls = calls
        self.delivery = delivery
    }
    func stop() {
        delivery.stop()
        let owned = registered.withLock { registered in
            let owned = registered
            registered = nil
            return owned
        }
        guard let owned else { return }
        // Never hold the claim lock across injected code or a main-thread wait.
        // Uninstall first, waiting behind any main callback; target IPC removal
        // then stays on this claiming caller. Reentrant/subsequent stops return.
        calls.mainHop { calls.uninstall(token) }
        for (el, name) in owned {
            calls.remove(token, unsafeDowncast(el.object, to: AXUIElement.self), name)
        }
    }
    deinit { stop() }
}
