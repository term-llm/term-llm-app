import ApplicationServices
import ComputerUseCore
import Foundation

/// Thin wrappers over accessibility. Any thread may call them. No messaging timeout
/// is set by default: the system default applies to every call, as upstream.
public final class SystemAX: AXBackend {
    // ComputerUseRuntime installs SystemAX in AX.backend before serving requests.

    // The one-call hierarchy copy is deliberately off upstream: measured on Lab
    // (12 Oct) it took 11 ms against 30 ms for the walk, but left out a web view's
    // page (15 elements, the walk 53 lines). Use the ordinary batched walk instead.
    public struct Calls {
        public var get: (AXUIElement, String) -> (Int32, Any?) = { el, name in
            var value: CFTypeRef?
            let code = AXUIElementCopyAttributeValue(el, name as CFString, &value)
            return (code.rawValue, value)
        }
        public var names: (AXUIElement) -> [String] = { el in
            var value: CFArray?
            return AXUIElementCopyAttributeNames(el, &value) == .success ? value as? [String] ?? [] : []
        }
        public var getMany: (AXUIElement, [String]) -> (Int32, [Any]) = { el, names in
            var values: CFArray?
            let code = AXUIElementCopyMultipleAttributeValues(el, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values)
            return (code.rawValue, values as? [Any] ?? [])
        }
        public var set: (AXUIElement, String, CFTypeRef) -> Int32 = { AXUIElementSetAttributeValue($0, $1 as CFString, $2).rawValue }
        public var settable: (AXUIElement, String) -> Bool = { el, name in
            var flag = DarwinBoolean(false)
            return AXUIElementIsAttributeSettable(el, name as CFString, &flag) == .success && flag.boolValue
        }
        public var actionNames: (AXUIElement) -> [String] = { el in
            var names: CFArray?
            return AXUIElementCopyActionNames(el, &names) == .success ? names as? [String] ?? [] : []
        }
        public var actionDescription: (AXUIElement, String) -> String = { el, name in
            var text: CFString?
            return AXUIElementCopyActionDescription(el, name as CFString, &text) == .success ? text as String? ?? "" : ""
        }
        public var perform: (AXUIElement, String) -> Int32 = { AXUIElementPerformAction($0, $1 as CFString).rawValue }
        public var param: (AXUIElement, String, CFTypeRef) -> Any? = { el, name, argument in
            var value: CFTypeRef?
            return AXUIElementCopyParameterizedAttributeValue(el, name as CFString, argument, &value) == .success ? value : nil
        }
        public var pid: (AXUIElement) -> (Int32, pid_t) = { el in
            var pid: pid_t = 0
            return (AXUIElementGetPid(el, &pid).rawValue, pid)
        }
        public var at: (AXUIElement, Float, Float) -> AXUIElement? = { el, x, y in
            var found: AXUIElement?
            return AXUIElementCopyElementAtPosition(el, x, y, &found) == .success ? found : nil
        }
        public var timeout: (AXUIElement, Float) -> Void = { _ = AXUIElementSetMessagingTimeout($0, $1) }
        public var windowID: (AXUIElement) -> UInt32 = { el in
            guard let call = windowCall else { return 0 }
            var number: UInt32 = 0
            return call(el, &number) == 0 ? number : 0
        }
        public init() {}
    }

    /// Observer operations are injectable without granting AX or observing real apps.
    public struct ObserverCalls {
        public var create: (pid_t, @escaping (String, UIElementRef) -> Void) throws -> AnyObject = { pid, callback in
            let box = ObserverBox(callback)
            var observer: AXObserver?
            try check(AXObserverCreate(pid, { _, element, name, context in
                guard let context else { return }
                Unmanaged<ObserverBox>.fromOpaque(context).takeUnretainedValue().callback(name as String, UIElementRef(element))
            }, &observer).rawValue)
            box.observer = observer!
            return box
        }
        public var add: (AnyObject, AXUIElement, String) -> Int32 = { object, el, name in
            let box = object as! ObserverBox
            return AXObserverAddNotification(box.observer!, el, name as CFString, Unmanaged.passUnretained(box).toOpaque()).rawValue
        }
        public var remove: (AnyObject, AXUIElement, String) -> Void = { object, el, name in
            _ = AXObserverRemoveNotification((object as! ObserverBox).observer!, el, name as CFString)
        }
        public var install: (AnyObject) -> Void = { object in
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource((object as! ObserverBox).observer!), .defaultMode)
        }
        public var uninstall: (AnyObject) -> Void = { object in
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource((object as! ObserverBox).observer!), .defaultMode)
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
        let element = unsafeBitCast(ref.object, to: AXUIElement.self)
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
    public func observe(pid: pid_t, element: UIElementRef, names: [String], callback: @escaping (String, UIElementRef) -> Void) throws -> AXObservation {
        let token = try observerCalls.create(pid, callback)
        let observation = Observation(token: token, calls: observerCalls)
        do {
            for name in names {
                let code = observerCalls.add(token, raw(element), name)
                if code == AX.cannotComplete { continue } // This app does not send that one.
                try Self.check(code)
                observation.registered.append((raw(element), name))
            }
            MainThread.callOnMain { self.observerCalls.install(token) }
            return observation
        } catch { observation.stop(); throw error }
    }
    static func check(_ code: Int32) throws { if code != 0 { throw AX.failure(code) } }

    /// Normalize every value crossing the AX seam, including nested collections.
    static func value(_ input: Any?) -> Any? {
        guard let input, !(input is NSNull) else { return nil }
        let cf = input as CFTypeRef
        let type = CFGetTypeID(cf)
        if type == CFStringGetTypeID() { return input as! String }
        if type == AXUIElementGetTypeID() { return UIElementRef(input as AnyObject) }
        if type == CFBooleanGetTypeID() { return CFBooleanGetValue(unsafeBitCast(cf, to: CFBoolean.self)) }
        if type == CFNumberGetTypeID() {
            let number = unsafeBitCast(cf, to: CFNumber.self)
            return CFNumberIsFloatType(number) ? (input as! NSNumber).doubleValue as Any : (input as! NSNumber).intValue as Any
        }
        if type == AXValueGetTypeID() {
            let ax = unsafeBitCast(cf, to: AXValue.self)
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
    private static let symbols = PrivateSymbols(path: "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices") { name in
        NSLog("private accessibility call %@ is missing: its step is off", name)
    }
    private static let windowCall: WindowCall? = symbols.lookup("_AXUIElementGetWindow").map { unsafeBitCast($0, to: WindowCall.self) }

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
private final class ObserverBox {
    let callback: (String, UIElementRef) -> Void
    var observer: AXObserver?
    init(_ callback: @escaping (String, UIElementRef) -> Void) { self.callback = callback }
}
private final class Observation: AXObservation {
    let token: AnyObject
    let calls: SystemAX.ObserverCalls
    var registered: [(AXUIElement, String)] = []
    private let lock = NSLock()
    private var stopped = false
    init(token: AnyObject, calls: SystemAX.ObserverCalls) { self.token = token; self.calls = calls }
    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }; stopped = true
        lock.unlock()
        let calls = calls, token = token
        for (el, name) in registered { calls.remove(token, el, name) }
        MainThread.callOnMain { calls.uninstall(token) }
    }
    deinit { stop() }
}
