import CoreGraphics
import Foundation
import os

// The accessibility seam (macos-harness ax.py). Backends are shared dependencies:
// calls may overlap on arbitrary worker threads. Implementations must synchronize
// mutable state; injected dependencies must themselves support concurrent calls.
// This does NOT make Any results Sendable. Arguments/results belong to the
// synchronous calling operation: do not retain mutable inputs, share mutable
// results, or move heterogeneous values into a task/callback. Make typed snapshots
// at an actual concurrency boundary. UIElementRef is a handle, not its object graph.
//
// Known values are normalized to Swift/Foundation forms below. Opaque SDK values
// (e.g. text markers) may remain Any for synchronous parameterized round trips;
// neither those nor Foundation reference values acquire a Sendable guarantee:
//   AXUIElement            -> UIElementRef
//   CFString               -> String
//   CFBoolean              -> Bool        (never NSNumber)
//   CFNumber               -> Int or Double
//   CFArray                -> [Any]       (elements inside as UIElementRef)
//   CFDictionary           -> [String: Any]
//   AXValue CGPoint/CGSize/CGRect/CFRange -> CGPoint / CGSize / CGRect / NSRange
//   AXValue error placeholder (a failed name of a batch) -> nil
//   CFURL                  -> URL
//   CFAttributedString     -> NSAttributedString
// Parameterized attribute arguments go in the same forms (NSRange, CGPoint, ...).

public protocol AXBackend: AnyObject, Sendable {
    /// The application element of a process.
    func app(pid: pid_t) -> UIElementRef
    /// One attribute. nil when the element has no such attribute or no value
    /// (the "missing" codes); throws `Errors.make("accessibility")` on any other failure.
    func get(_ element: UIElementRef, _ name: String) throws -> Any?
    /// The attribute names the element says it has.
    func names(_ element: UIElementRef) -> [String]
    /// One batched read: a name that fails gives nil, the rest arrive. A failure of the
    /// whole batch throws.
    func getMany(_ element: UIElementRef, _ names: [String]) throws -> [Any?]
    func set(_ element: UIElementRef, _ name: String, _ value: Any) throws
    func settable(_ element: UIElementRef, _ name: String) -> Bool
    /// Action names, in the app's order.
    func actionNames(_ element: UIElementRef) -> [String]
    /// The app's description of one action ("" when it has none).
    func actionDescription(_ element: UIElementRef, _ action: String) -> String
    func perform(_ element: UIElementRef, _ action: String) throws
    /// A parameterized attribute; nil on any failure.
    func param(_ element: UIElementRef, _ name: String, _ argument: Any) -> Any?
    func pid(_ element: UIElementRef) throws -> pid_t
    /// The window server id of a window element (private `_AXUIElementGetWindow`); 0 when unknown.
    func windowID(_ element: UIElementRef) -> UInt32
    /// Global points, origin top left. nil when position or size is missing.
    func frame(_ element: UIElementRef) -> CGRect?
    /// Hit test inside one app; with no app it asks the whole system.
    func at(_ app: UIElementRef?, x: Double, y: Double) -> UIElementRef?
    /// Optional one-call hierarchy copy; nil falls back to per-element batched reads.
    /// Values have exactly the requested attribute order. Backends without the private
    /// hierarchy API need not implement this optimization.
    func subtree(_ element: UIElementRef, _ names: [String], maxChildren: Int) -> [(UIElementRef, [Any?])]?
    /// False once the element is destroyed (kAXErrorInvalidUIElement).
    func alive(_ element: UIElementRef) -> Bool
    /// Hear `names` on `element` of process `pid`, delivered on the main run loop.
    /// The callback gets (notification name, element) and must only store.
    func observe(pid: pid_t, element: UIElementRef, names: [String],
                 callback: @escaping @Sendable (String, UIElementRef) -> Void) throws -> AXObservation
}

public extension AXBackend {
    func subtree(_ element: UIElementRef, _ names: [String], maxChildren: Int) -> [(UIElementRef, [Any?])]? { nil }
}

public protocol AXObservation: AnyObject, Sendable {
    /// Close delivery before removing notifications. Idempotent and reentrant.
    /// The delivery gate never waits for an already claimed callback, which may
    /// finish after stop returns. SDK source uninstall may synchronously wait
    /// behind an in-flight main-run-loop callback; reentrant stop must not wait
    /// for itself. Concurrent subsequent stops may return before the cleanup
    /// claimant finishes uninstalling the source and removing notifications.
    func stop()
}

public enum AX {
    /// The shared backend. Install at helper startup, before accepting requests.
    /// Replacement is safe for reference ownership, not a transaction spanning
    /// several AX operations: an operation needing that must retain one snapshot.
    public static var backend: any AXBackend {
        get { (scopedRegistry ?? registry).backend }
        set { (scopedRegistry ?? registry).backend = newValue }
    }
    private static let registry = AXBackendRegistry(UnavailableAX())
    @TaskLocal private static var scopedRegistry: AXBackendRegistry?

    /// A synchronous dependency scope, primarily for tests. Installs/replacements
    /// inside body affect only this scope, never the production registry or another
    /// test. Structured tasks inherit the scope; arbitrary GCD work does not. Pass
    /// a captured backend explicitly to such workers. Do not escape unjoined work.
    public static func withBackend<R>(_ backend: any AXBackend, _ body: () throws -> R) rethrows -> R {
        try $scopedRegistry.withValue(AXBackendRegistry(backend), operation: body)
    }

    public static let errorNames: [Int32: String] = [
        -25200: "failure",
        -25201: "illegalArgument",
        -25202: "invalidUIElement",
        -25203: "invalidUIElementObserver",
        -25204: "cannotComplete",
        -25205: "attributeUnsupported",
        -25206: "actionUnsupported",
        -25207: "notificationUnsupported",
        -25208: "notImplemented",
        -25209: "notificationAlreadyRegistered",
        -25210: "notificationNotRegistered",
        -25211: "apiDisabled",
        -25212: "noValue",
        -25213: "parameterizedAttributeUnsupported",
        -25214: "notEnoughPrecision",
    ]
    public static let cannotComplete: Int32 = -25204
    public static let invalidElement: Int32 = -25202
    /// Codes that mean "this element has no such thing". Every other code is a failure.
    public static let missing: Set<Int32> = [-25212, -25205, -25213, -25206, -25200, -25201, -25208]

    public static func errorName(_ code: Int32) -> String {
        if let name = errorNames[code] { return "AXError.\(name)" }
        return "(undocumented AXError)"
    }

    /// The error a failed AX call raises.
    public static func failure(_ code: Int32) -> HarnessError {
        Errors.make("accessibility", ["ax_error_name": errorName(code)])
    }

    /// Both present and the same element.
    public static func same(_ a: UIElementRef?, _ b: UIElementRef?) -> Bool {
        guard let a, let b else { return false }
        return a.isSame(b)
    }
}

/// The backend before the helper installs one: every call fails.
final class UnavailableAX: AXBackend {
    private func fail() -> HarnessError { Errors.serverError("accessibility is not available") }
    func app(pid: pid_t) -> UIElementRef { UIElementRef(NSNull()) }
    func get(_ element: UIElementRef, _ name: String) throws -> Any? { throw fail() }
    func names(_ element: UIElementRef) -> [String] { [] }
    func getMany(_ element: UIElementRef, _ names: [String]) throws -> [Any?] { throw fail() }
    func set(_ element: UIElementRef, _ name: String, _ value: Any) throws { throw fail() }
    func settable(_ element: UIElementRef, _ name: String) -> Bool { false }
    func actionNames(_ element: UIElementRef) -> [String] { [] }
    func actionDescription(_ element: UIElementRef, _ action: String) -> String { "" }
    func perform(_ element: UIElementRef, _ action: String) throws { throw fail() }
    func param(_ element: UIElementRef, _ name: String, _ argument: Any) -> Any? { nil }
    func pid(_ element: UIElementRef) throws -> pid_t { throw fail() }
    func windowID(_ element: UIElementRef) -> UInt32 { 0 }
    func frame(_ element: UIElementRef) -> CGRect? { nil }
    func at(_ app: UIElementRef?, x: Double, y: Double) -> UIElementRef? { nil }
    func alive(_ element: UIElementRef) -> Bool { false }
    func observe(pid: pid_t, element: UIElementRef, names: [String],
                 callback: @escaping @Sendable (String, UIElementRef) -> Void) throws -> AXObservation { throw fail() }
}

/// Compiler-visible shared ownership of a genuinely Sendable backend, not a box
/// that asserts an arbitrary backend graph safe. Never call or release a backend
/// under this registry lock: its deinit may reenter the registry or wait on main.
final class AXBackendRegistry: Sendable {
    private let state: OSAllocatedUnfairLock<any AXBackend>
    init(_ backend: any AXBackend) { state = OSAllocatedUnfairLock(initialState: backend) }
    var backend: any AXBackend {
        get { state.withLock { $0 } }
        set {
            let old = state.withLock { backend in
                let old = backend
                backend = newValue
                return old
            }
            withExtendedLifetime(old) {}
        }
    }
}

/// A nonblocking callback gate shared by real and fake observations. The claim is
/// made under a lock, but client code is ALWAYS invoked outside it. Closing gates
/// future claims, not callbacks already claimed. This permits reentrant stop and
/// avoids worker/main-run-loop deadlocks. It does not impose callback serialization.
public final class AXObservationDelivery: Sendable {
    private let open = OSAllocatedUnfairLock(initialState: true)
    private let callback: @Sendable (String, UIElementRef) -> Void
    public init(_ callback: @escaping @Sendable (String, UIElementRef) -> Void) { self.callback = callback }
    public func deliver(_ name: String, _ element: UIElementRef) {
        guard open.withLock({ $0 }) else { return }
        callback(name, element)
    }
    public func stop() { open.withLock { $0 = false } }
}
