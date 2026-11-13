import CoreFoundation
import CoreGraphics
import Foundation
import os

// Shared data shapes (macos-harness model.py). Nothing here imports AppKit.

public enum Limits {
    /// Client and helper must agree on this.
    public static let apiVersion = "TermLLMComputerUse-1"
    /// One message on the socket, either way.
    public static let maxFrameBytes = 8 * 1024 * 1024
    /// The client gives up after this long.
    public static let callTimeout: TimeInterval = 120
    /// The system process that draws every app's open and save panels.
    public static let panelService = "com.apple.appkit.xpc.openAndSavePanelService"
    /// Seconds after every typed key event.
    public static let typeDelay: TimeInterval = 0.00025
    /// Bundle id -> its own delay after every typed key event.
    public static let slowTyping: [String: TimeInterval] = ["com.apple.ScreenContinuity": 0.005]
}

/// A live accessibility element (an `AXUIElement`), or any object a test uses in
/// its place. Two refs are the same element when `CFEqual` says so; never compare
/// by pointer.
// Unchecked SDK handle interop, not Sendable for an arbitrary object graph.
// Production wraps immutable AXUIElement handles accepted by AX on any thread.
// A test object supplied here must synchronize all mutable state itself; wrapping
// it does not provide that synchronization or make other captured objects safe.
public struct UIElementRef: @unchecked Sendable {
    public let object: AnyObject

    public init(_ object: AnyObject) { self.object = object }

    public func isSame(_ other: UIElementRef) -> Bool {
        CFEqual(object as CFTypeRef, other.object as CFTypeRef)
    }
}

/// One app the model named, after resolving.
public struct AppTarget: Hashable, Sendable {
    /// Full path of the .app bundle: the session key, and the name used in error texts.
    public var path: String
    public var bundleID: String
    /// Display name.
    public var name: String
    /// nil while the app is not running.
    public var pid: pid_t?

    public init(path: String, bundleID: String, name: String, pid: pid_t? = nil) {
        self.path = path
        self.bundleID = bundleID
        self.name = name
        self.pid = pid
    }
}

public struct AppKind: Equatable, Sendable {
    public var electron = false
    public var chromium = false
    /// The bundle declares the http URL scheme, as every browser does.
    public var http = false
    public var catalyst = false

    public init(electron: Bool = false, chromium: Bool = false, http: Bool = false, catalyst: Bool = false) {
        self.electron = electron
        self.chromium = chromium
        self.http = http
        self.catalyst = catalyst
    }

    public var webLike: Bool { electron || chromium || http }
}

/// Global screen points, origin top left, signed. Nothing is clamped to zero.
public struct WindowRef: Sendable {
    /// The window's accessibility element.
    public var element: UIElementRef
    /// Window server id, 0 when unknown.
    public var windowID: UInt32
    /// The process that owns the window. It can differ from the app's pid.
    public var pid: pid_t
    public var title: String?
    public var frame: CGRect

    public init(element: UIElementRef, windowID: UInt32, pid: pid_t, title: String?, frame: CGRect) {
        self.element = element
        self.windowID = windowID
        self.pid = pid
        self.title = title
        self.frame = frame
    }
}

// Typed replacement is restricted to Sendable storage and fields. Keeping the
// displaced value alive until after unlocking also permits reentrant deinit of a
// handle, observation, or a capture owned by an @Sendable cancellation closure.
extension OSAllocatedUnfairLock where State: Sendable {
    func exchangeModelValue<Value: Sendable>(_ key: WritableKeyPath<State, Value> & Sendable, with value: Value) -> Value {
        withLock { state in
            let old = state[keyPath: key]
            state[keyPath: key] = value
            return old
        }
    }

    func replaceModelValue<Value: Sendable>(_ key: WritableKeyPath<State, Value> & Sendable, with value: Value) {
        let old = exchangeModelValue(key, with: value)
        withExtendedLifetime(old) {}
    }
}

/// One printed element line, before it has a number.
/// Accessors are synchronized, not a multi-field or read-modify-write transaction.
/// The canonical app FIFO still owns edits, numbering, and rendering as a whole.
public final class Line: Sendable {
    // A snapshot copies value fields and retains only checked, synchronized model
    // references (or the narrow SDK handle). It does not deep-copy Line identity.
    struct Snapshot: Sendable {
        var depth: Int
        var text: String
        var element: UIElementRef?
        var role: String
        var detail: String
        var name: String
        var value: String
        var match: [String]
        var settable: Bool
        var actions: [(label: String, action: String)]
        var id: Int?
    }
    private let state: OSAllocatedUnfairLock<Snapshot>
    func snapshot() -> Snapshot { state.withLock { $0 } }
    // Used by Revisions' validated commit. Return the displaced handle so it is
    // retained beyond BOTH the Line lock and the enclosing Revisions state lock.
    func exchangeElement(_ element: UIElementRef?) -> UIElementRef? {
        state.exchangeModelValue(\.element, with: element)
    }

    public var depth: Int {
        get { state.withLock { $0.depth } }
        set { state.replaceModelValue(\.depth, with: newValue) }
    }
    /// Everything after "<id> ": role, state group, fields.
    public var text: String {
        get { state.withLock { $0.text } }
        set { state.replaceModelValue(\.text, with: newValue) }
    }
    /// Live accessibility element. Compare with `isSame`, never by hash.
    public var element: UIElementRef? {
        get { state.withLock { $0.element } }
        set { state.replaceModelValue(\.element, with: newValue) }
    }
    /// Raw accessibility role, used for pairing and refetch.
    public var role: String {
        get { state.withLock { $0.role } }
        set { state.replaceModelValue(\.role, with: newValue) }
    }
    /// Printed after the text with one space. Ignored when two states are compared.
    public var detail: String {
        get { state.withLock { $0.detail } }
        set { state.replaceModelValue(\.detail, with: newValue) }
    }
    /// Title, else description, used for refetch.
    public var name: String {
        get { state.withLock { $0.name } }
        set { state.replaceModelValue(\.name, with: newValue) }
    }
    /// Printed value. Refetch may ignore it.
    public var value: String {
        get { state.withLock { $0.value } }
        set { state.replaceModelValue(\.value, with: newValue) }
    }
    /// Refetch key, filled by the tree read, compared as one tuple:
    /// (role, subrole, title, description, identifier, help, placeholder, url).
    /// The value is compared apart.
    public var match: [String] {
        get { state.withLock { $0.match } }
        set { state.replaceModelValue(\.match, with: newValue) }
    }
    public var settable: Bool {
        get { state.withLock { $0.settable } }
        set { state.replaceModelValue(\.settable, with: newValue) }
    }
    /// Printed label -> accessibility action name, in printed order.
    public var actions: [(label: String, action: String)] {
        get { state.withLock { $0.actions } }
        set { state.replaceModelValue(\.actions, with: newValue) }
    }
    /// Set by the numbering (elements).
    public var id: Int? {
        get { state.withLock { $0.id } }
        set { state.replaceModelValue(\.id, with: newValue) }
    }

    public init(depth: Int, text: String, element: UIElementRef?, role: String, detail: String = "",
                name: String = "", value: String = "", match: [String] = [], settable: Bool = false,
                actions: [(label: String, action: String)] = [], id: Int? = nil) {
        state = OSAllocatedUnfairLock(initialState: Snapshot(
            depth: depth, text: text, element: element,
            role: role, detail: detail, name: name,
            value: value, match: match, settable: settable,
            actions: actions, id: id))
    }
}

/// What one state read saw, before numbering and diffing.
/// Accessors synchronize ownership; the app FIFO owns logical multi-field changes.
/// Referenced Lines remain the very same synchronized objects in all three blocks.
public final class Capture: Sendable {
    // A shallow read of this Capture's value fields and synchronized Line
    // references, not a frozen tree or a multi-object transaction. The app FIFO
    // still owns coordinated field changes; no Line identity is copied/replaced.
    struct Snapshot: Sendable {
        var windowTitle: String
        var appName: String
        var windowID: UInt32
        var lines: [Line]
        var focused: Line?
        var selectedText: String?
        var selected: [Line]
        var menuOpen: Bool
        var loading: Bool
        var url: String?
    }
    private let state: OSAllocatedUnfairLock<Snapshot>
    func snapshot() -> Snapshot { state.withLock { $0 } }

    /// Header title. "" and "Unknown" are real values.
    public var windowTitle: String {
        get { state.withLock { $0.windowTitle } }
        set { state.replaceModelValue(\.windowTitle, with: newValue) }
    }
    public var appName: String {
        get { state.withLock { $0.appName } }
        set { state.replaceModelValue(\.appName, with: newValue) }
    }
    public var windowID: UInt32 {
        get { state.withLock { $0.windowID } }
        set { state.replaceModelValue(\.windowID, with: newValue) }
    }
    /// The main tree in depth-first order. Parent and child come from depth.
    public var lines: [Line] {
        get { state.withLock { $0.lines } }
        set { state.replaceModelValue(\.lines, with: newValue) }
    }
    /// The focused element's line. Usually one of `lines` (same element); it may be
    /// one that is not, which the numbering then numbers after the main tree.
    public var focused: Line? {
        get { state.withLock { $0.focused } }
        set { state.replaceModelValue(\.focused, with: newValue) }
    }
    public var selectedText: String? {
        get { state.withLock { $0.selectedText } }
        set { state.replaceModelValue(\.selectedText, with: newValue) }
    }
    /// The selection block. Same rule as `focused`.
    public var selected: [Line] {
        get { state.withLock { $0.selected } }
        set { state.replaceModelValue(\.selected, with: newValue) }
    }
    /// `lines` hold only the open menu.
    public var menuOpen: Bool {
        get { state.withLock { $0.menuOpen } }
        set { state.replaceModelValue(\.menuOpen, with: newValue) }
    }
    /// A loading sign was found. Settle reads this.
    public var loading: Bool {
        get { state.withLock { $0.loading } }
        set { state.replaceModelValue(\.loading, with: newValue) }
    }
    /// The window's page URL when the app is a browser. The URL policy reads it.
    public var url: String? {
        get { state.withLock { $0.url } }
        set { state.replaceModelValue(\.url, with: newValue) }
    }

    public init(windowTitle: String, appName: String, windowID: UInt32, lines: [Line],
                focused: Line? = nil, selectedText: String? = nil, selected: [Line] = [],
                menuOpen: Bool = false, loading: Bool = false, url: String? = nil) {
        state = OSAllocatedUnfairLock(initialState: Snapshot(
            windowTitle: windowTitle, appName: appName, windowID: windowID,
            lines: lines, focused: focused, selectedText: selectedText,
            selected: selected, menuOpen: menuOpen, loading: loading,
            url: url))
    }
}

/// One screenshot file and how its pixels map to the screen.
public struct Shot: Equatable, Sendable {
    public var path: String
    /// Screenshot pixels per screen point.
    public var scale: Double
    /// Top left of the captured rect in global points.
    public var origin: CGPoint
    /// Pixels.
    public var width: Int
    public var height: Int

    public init(path: String, scale: Double, origin: CGPoint, width: Int, height: Int) {
        self.path = path
        self.scale = scale
        self.origin = origin
        self.width = width
        self.height = height
    }

    public func toScreen(x: Double, y: Double) -> CGPoint {
        CGPoint(x: x / scale + origin.x, y: y / scale + origin.y)
    }
}

public struct PolicyDecision: Equatable, Sendable {
    public enum Decision: String, Sendable { case allowed, denied, forbidden }
    public enum Risk: String, Sendable { case low, high }

    public var decision: Decision
    public var risk: Risk
    public var allowPersistent: Bool
    /// Shown in the approval prompt when risk is high.
    public var warning: String?
    /// The person is asked before the app's first use.
    public var ask: Bool

    public init(decision: Decision, risk: Risk, allowPersistent: Bool, warning: String?, ask: Bool = true) {
        self.decision = decision
        self.risk = risk
        self.allowPersistent = allowPersistent
        self.warning = warning
        self.ask = ask
    }
}

/// One calling agent (a term-llm session). Lives in the helper between calls.
/// Mutable state is synchronized across calls, turn hooks and approval callbacks.
// Unchecked: every mutable field is private and read or written only while holding the recursive `stateLock`.
public final class AgentSession: @unchecked Sendable {
    public let key: String
    /// Shared by lifecycle workers, approval callbacks and calls on different app
    /// FIFOs. Collection mutation uses _modify so insert/remove is atomic too.
    private let stateLock = NSRecursiveLock()
    public func withState<T>(_ work: () throws -> T) rethrows -> T {
        stateLock.lock(); defer { stateLock.unlock() }; return try work()
    }
    /// A turn-ended signal arrived and no turn-started since.
    public var ended: Bool {
        get { withState { _ended } }
        set { withState { _ended = newValue } }
        _modify { stateLock.lock(); defer { stateLock.unlock() }; yield &_ended }
    }
    private var _ended: Bool = false
    /// This host has sent turn-started at least once.
    public var signalsTurns: Bool {
        get { withState { _signalsTurns } }
        set { withState { _signalsTurns = newValue } }
        _modify { stateLock.lock(); defer { stateLock.unlock() }; yield &_signalsTurns }
    }
    private var _signalsTurns: Bool = false
    /// Turn ends that also stop the action it still runs.
    public var cancels: Int {
        get { withState { _cancels } }
        set { withState { _cancels = newValue } }
        _modify { stateLock.lock(); defer { stateLock.unlock() }; yield &_cancels }
    }
    private var _cancels: Int = 0
    /// Its host died and left this command's shell running.
    public var exited: Bool {
        get { withState { _exited } }
        set { withState { _exited = newValue } }
        _modify { stateLock.lock(); defer { stateLock.unlock() }; yield &_exited }
    }
    private var _exited: Bool = false
    /// Bundle ids whose instruction note was printed.
    public var instructed: Set<String> {
        get { withState { _instructed } }
        set { withState { _instructed = newValue } }
        _modify { stateLock.lock(); defer { stateLock.unlock() }; yield &_instructed }
    }
    private var _instructed: Set<String> = []
    /// App paths the person refused in this turn.
    public var denied: Set<String> {
        get { withState { _denied } }
        set { withState { _denied = newValue } }
        _modify { stateLock.lock(); defer { stateLock.unlock() }; yield &_denied }
    }
    private var _denied: Set<String> = []
    /// Every .app bundle on the caller's parent chain. The policy forbids these:
    /// an agent may not drive its host.
    public var hosts: Set<String> {
        get { withState { _hosts } }
        set { withState { _hosts = newValue } }
        _modify { stateLock.lock(); defer { stateLock.unlock() }; yield &_hosts }
    }
    private var _hosts: Set<String> = []
    /// The TERM_LLM_* variables of the call that runs now; replaced on every call.
    public var env: [String: String] {
        get { withState { _env } }
        set { withState { _env = newValue } }
        _modify { stateLock.lock(); defer { stateLock.unlock() }; yield &_env }
    }
    private var _env: [String: String] = [:]

    public init(key: String, hosts: Set<String> = [], exited: Bool = false) {
        self.key = key
        self.hosts = hosts
        self.exited = exited
    }
}
