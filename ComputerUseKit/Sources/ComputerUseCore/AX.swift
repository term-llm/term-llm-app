import CoreGraphics
import Foundation

// The accessibility seam (macos-harness ax.py). Every module reaches the AX API
// through `AX.backend`: the helper installs the real one (ComputerUseSystem's
// `SystemAX`), tests install fakes. Any thread may call it.
//
// Values crossing the seam are plain Swift/Foundation values, never CF types:
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

public protocol AXBackend: AnyObject {
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
    /// False once the element is destroyed (kAXErrorInvalidUIElement).
    func alive(_ element: UIElementRef) -> Bool
    /// Hear `names` on `element` of process `pid`, delivered on the main run loop.
    /// The callback gets (notification name, element) and must only store.
    func observe(pid: pid_t, element: UIElementRef, names: [String],
                 callback: @escaping (String, UIElementRef) -> Void) throws -> AXObservation
}

public protocol AXObservation: AnyObject {
    /// Remove every notification. A second stop does nothing.
    func stop()
}

public enum AX {
    /// The backend every module uses. Set once by the helper at start, or by a test.
    nonisolated(unsafe) public static var backend: AXBackend = UnavailableAX()

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
                 callback: @escaping (String, UIElementRef) -> Void) throws -> AXObservation { throw fail() }
}
