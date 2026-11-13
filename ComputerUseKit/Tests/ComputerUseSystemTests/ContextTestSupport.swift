import AppKit
import ComputerUseCore
import XCTest
import os
@testable import ComputerUseSystem

// Shared only by the new context tests. No real AX reads, taps, input, focus or apps.
final class ContextElement: NSObject, Sendable {
    // Mutable fixture state is owned by this lock. Snapshots contain value data,
    // immutable test values, synchronized nodes, or @Sendable callbacks. Hooks run
    // outside locks; heterogeneous values never escape to asynchronous work.
    // uncheckedState/withLockUnchecked admit operation-local Any, not Sendable
    // object graphs. Fixture reference values must be immutable or synchronized.
    private struct State {
        var attrs: [String: Any] = [:]
        var pid: pid_t = 77
        var id: UInt32 = 7
        var rect: CGRect? = nil
        var alive: Bool = true
    }
    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    var attrs: [String: Any] {
        get { state.withLockUnchecked { $0.attrs } }
        set { state.withLockUnchecked { $0.attrs = newValue } }
    }
    var pid: pid_t {
        get { state.withLockUnchecked { $0.pid } }
        set { state.withLockUnchecked { $0.pid = newValue } }
    }
    var id: UInt32 {
        get { state.withLockUnchecked { $0.id } }
        set { state.withLockUnchecked { $0.id = newValue } }
    }
    var rect: CGRect? {
        get { state.withLockUnchecked { $0.rect } }
        set { state.withLockUnchecked { $0.rect = newValue } }
    }
    var alive: Bool {
        get { state.withLockUnchecked { $0.alive } }
        set { state.withLockUnchecked { $0.alive = newValue } }
    }

    init(_ role: String = "AXWindow", pid: pid_t = 77, id: UInt32 = 7, rect: CGRect? = CGRect(x: -100, y: 50, width: 200, height: 100), attrs: [String: Any] = [:]) {
        super.init()
        self.attrs = attrs; self.attrs["AXRole"] = role; self.pid = pid; self.id = id; self.rect = rect
    }
    func set(_ name: String, _ value: Any) { state.withLockUnchecked { $0.attrs[name] = value } }
    var ref: UIElementRef { UIElementRef(self) }
}
final class ContextObservation: AXObservation {
    private let closed = OSAllocatedUnfairLock(initialState: false)
    var stopped: Bool { closed.withLock { $0 } }
    let names: [String]
    private let delivery: AXObservationDelivery
    private let callback: @Sendable (String, UIElementRef) -> Void
    private let stopHook = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
    var onStop: (@Sendable () -> Void)? {
        get { stopHook.withLock { $0 } }
        set { stopHook.withLock { $0 = newValue } }
    }
    init(_ names: [String], _ callback: @escaping @Sendable (String, UIElementRef) -> Void) {
        self.names = names; self.callback = callback; self.delivery = AXObservationDelivery(callback)
    }
    func stop() {
        let first = closed.withLock { closed in if closed { return false }; closed = true; return true }
        guard first else { return }
        delivery.stop(); onStop?()
    }
    // Models a delivery already claimed before stop closed the real gate.
    func fireClaimed(_ name: String, _ element: UIElementRef) { callback(name, element) }
    func fire(_ name: String, _ element: UIElementRef) { if names.contains(name) { delivery.deliver(name, element) } }
}
final class ContextAX: AXBackend {
    // Mutable fixture state is owned by this lock. Snapshots contain value data,
    // immutable test values, synchronized nodes, or @Sendable callbacks. Hooks run
    // outside locks; heterogeneous values never escape to asynchronous work.
    // uncheckedState/withLockUnchecked admit operation-local Any, not Sendable
    // object graphs. Fixture reference values must be immutable or synchronized.
    private struct State {
        var apps: [pid_t: ContextElement] = [:]
        var observations: [ContextObservation] = []
        var gets: [(UIElementRef, String)] = []
        var sets: [(UIElementRef, String, Any)] = []
        var performed: [(UIElementRef, String)] = []
        var failGet: Set<String> = []
        var failSet: Bool = false
        var failObserve: Bool = false
        var failPerform: Bool = false
        var onSet: (@Sendable (UIElementRef, String, Any) -> Void)? = nil
        var hit: UIElementRef? = nil
        var offered: [String] = []
        var unsettable: Set<String> = []
        var onPerform: (@Sendable (UIElementRef, String) throws -> Void)? = nil
        var onParam: (@Sendable (UIElementRef, String, Any) -> Any?)? = nil
        var onGet: (@Sendable (UIElementRef, String) throws -> Any?)? = nil
        var onObserve: (@Sendable (ContextObservation) throws -> Void)? = nil
    }
    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    var apps: [pid_t: ContextElement] {
        get { state.withLockUnchecked { $0.apps } }
        set { state.withLockUnchecked { $0.apps = newValue } }
    }
    var observations: [ContextObservation] {
        get { state.withLockUnchecked { $0.observations } }
        set { state.withLockUnchecked { $0.observations = newValue } }
    }
    var gets: [(UIElementRef, String)] {
        get { state.withLockUnchecked { $0.gets } }
        set { state.withLockUnchecked { $0.gets = newValue } }
    }
    var sets: [(UIElementRef, String, Any)] {
        get { state.withLockUnchecked { $0.sets } }
        set { state.withLockUnchecked { $0.sets = newValue } }
    }
    var performed: [(UIElementRef, String)] {
        get { state.withLockUnchecked { $0.performed } }
        set { state.withLockUnchecked { $0.performed = newValue } }
    }
    var failGet: Set<String> {
        get { state.withLockUnchecked { $0.failGet } }
        set { state.withLockUnchecked { $0.failGet = newValue } }
    }
    var failSet: Bool {
        get { state.withLockUnchecked { $0.failSet } }
        set { state.withLockUnchecked { $0.failSet = newValue } }
    }
    var failObserve: Bool {
        get { state.withLockUnchecked { $0.failObserve } }
        set { state.withLockUnchecked { $0.failObserve = newValue } }
    }
    var failPerform: Bool {
        get { state.withLockUnchecked { $0.failPerform } }
        set { state.withLockUnchecked { $0.failPerform = newValue } }
    }
    var onSet: (@Sendable (UIElementRef, String, Any) -> Void)? {
        get { state.withLockUnchecked { $0.onSet } }
        set { state.withLockUnchecked { $0.onSet = newValue } }
    }
    var hit: UIElementRef? {
        get { state.withLockUnchecked { $0.hit } }
        set { state.withLockUnchecked { $0.hit = newValue } }
    }
    var offered: [String] {
        get { state.withLockUnchecked { $0.offered } }
        set { state.withLockUnchecked { $0.offered = newValue } }
    }
    var unsettable: Set<String> {
        get { state.withLockUnchecked { $0.unsettable } }
        set { state.withLockUnchecked { $0.unsettable = newValue } }
    }
    var onPerform: (@Sendable (UIElementRef, String) throws -> Void)? {
        get { state.withLockUnchecked { $0.onPerform } }
        set { state.withLockUnchecked { $0.onPerform = newValue } }
    }
    var onParam: (@Sendable (UIElementRef, String, Any) -> Any?)? {
        get { state.withLockUnchecked { $0.onParam } }
        set { state.withLockUnchecked { $0.onParam = newValue } }
    }

    var onGet: (@Sendable (UIElementRef, String) throws -> Any?)? {
        get { state.withLockUnchecked { $0.onGet } }
        set { state.withLockUnchecked { $0.onGet = newValue } }
    }
    var onObserve: (@Sendable (ContextObservation) throws -> Void)? {
        get { state.withLockUnchecked { $0.onObserve } }
        set { state.withLockUnchecked { $0.onObserve = newValue } }
    }

    func el(_ e: UIElementRef) -> ContextElement { e.object as! ContextElement }
    func app(pid: pid_t) -> UIElementRef {
        state.withLockUnchecked {
            if let e = $0.apps[pid] { return e.ref }
            let e = ContextElement("AXApplication", pid: pid, id: 0, rect: nil)
            $0.apps[pid] = e
            return e.ref
        }
    }
    func get(_ element: UIElementRef, _ name: String) throws -> Any? {
        state.withLockUnchecked { $0.gets.append((element, name)) }; if failGet.contains(name) { throw Errors.make("no_windows") }; if let onGet { return try onGet(element, name) }; return el(element).attrs[name]
    }
    func names(_ element: UIElementRef) -> [String] { Array(el(element).attrs.keys) }
    func getMany(_ element: UIElementRef, _ names: [String]) throws -> [Any?] { try names.map { try get(element, $0) } }
    func set(_ element: UIElementRef, _ name: String, _ value: Any) throws {
        if failSet { throw Errors.make("no_windows") }; state.withLockUnchecked { $0.sets.append((element, name, value)) }; el(element).set(name, value); onSet?(element, name, value)
    }
    func settable(_ element: UIElementRef, _ name: String) -> Bool { !unsettable.contains(name) }
    func actionNames(_ element: UIElementRef) -> [String] { offered }
    func actionDescription(_ element: UIElementRef, _ action: String) -> String { "" }
    func perform(_ element: UIElementRef, _ action: String) throws { if failPerform { throw Errors.make("no_windows") }; state.withLockUnchecked { $0.performed.append((element, action)) }; try onPerform?(element, action) }
    func param(_ element: UIElementRef, _ name: String, _ argument: Any) -> Any? { onParam?(element, name, argument) }
    func pid(_ element: UIElementRef) throws -> pid_t { el(element).pid }
    func windowID(_ element: UIElementRef) -> UInt32 { el(element).id }
    func frame(_ element: UIElementRef) -> CGRect? { el(element).rect }
    func at(_ app: UIElementRef?, x: Double, y: Double) -> UIElementRef? { hit }
    func alive(_ element: UIElementRef) -> Bool { el(element).alive }
    func observe(pid: pid_t, element: UIElementRef, names: [String], callback: @escaping @Sendable (String, UIElementRef) -> Void) throws -> AXObservation {
        if failObserve { throw Errors.make("no_windows") }; let o = ContextObservation(names, callback); state.withLockUnchecked { $0.observations.append(o) }; try onObserve?(o); return o
    }
}
// Typed fake state shared by ownership tests. No callbacks run under its lock.
final class ContextBox<Value: Sendable>: Sendable {
    private let state: OSAllocatedUnfairLock<Value>
    init(_ value: Value) { state = OSAllocatedUnfairLock(initialState: value) }
    var value: Value {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
    @discardableResult func withValue<T: Sendable>(_ work: @Sendable (inout Value) -> T) -> T { state.withLock(work) }
}
final class ContextClock: Sendable {
    private struct State: Sendable {
        var time = 1000.0
        var sleeps: [Double] = []
        var onSleep: (@Sendable () -> Void)?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var time: Double {
        get { state.withLock { $0.time } }
        set { state.withLock { $0.time = newValue } }
    }
    var now: @Sendable () -> TimeInterval { { [self] in time } }
    var sleeps: [Double] {
        get { state.withLock { $0.sleeps } }
        set { state.withLock { $0.sleeps = newValue } }
    }
    var onSleep: (@Sendable () -> Void)? {
        get { state.withLock { $0.onSleep } }
        set { state.withLock { $0.onSleep = newValue } }
    }
    func sleep(_ seconds: Double) {
        let callback = state.withLock { $0.time += seconds; $0.sleeps.append(seconds); return $0.onSleep }
        callback?()
    }
}
class ContextTestCase: XCTestCase {
    override func invokeTest() { AX.withBackend(AX.backend) { super.invokeTest() } }
    var ax: ContextAX!; var previous: AXBackend!; var clock: ContextClock!
    let target = AppTarget(path: "/A/Test.app", bundleID: "dev.test", name: "Test", pid: 77)
    override func setUp() { super.setUp(); previous = AX.backend; ax = ContextAX(); AX.backend = ax; clock = ContextClock() }
    override func tearDown() { AX.backend = previous; ax = nil; clock = nil; super.tearDown() }
    func windowSystem() -> Windows.System {
        var s = isolatedWindowsSystem(); s.rows = { _, _ in [] }; s.associated = { _ in [] }; s.noAttention = { _ in }
        let clock = clock!
        s.now = { clock.time }; s.sleep = { clock.sleep($0) }; return s
    }
}

// Fail-fast seams for pure ownership regressions. No unoverridden dependency can
// reach apps, WindowServer, AX SDK, input posting, Person, power or pasteboard.
func isolatedAppsSystem() -> Apps.System {
    var s = Apps.System()
    s.running = { XCTFail("Unexpected process listing"); return [] }
    s.executable = { _ in XCTFail("Unexpected executable lookup"); return "" }
    s.regular = { _ in XCTFail("Unexpected app policy lookup"); return false }
    s.bundlePaths = { _ in XCTFail("Unexpected bundle lookup"); return [] }
    s.named = { _ in XCTFail("Unexpected LaunchServices lookup"); return nil }
    s.open = { _ in XCTFail("Unexpected app launch"); return nil }
    s.frontPIDs = { XCTFail("Unexpected WindowServer query"); return [] }
    s.used = { XCTFail("Unexpected metadata query"); return [] }
    s.info = { _ in XCTFail("Unexpected plist read"); return nil }
    s.entries = { _ in XCTFail("Unexpected directory read"); return [] }
    s.realPath = { _ in XCTFail("Unexpected filesystem lookup"); return "" }
    s.expandUser = { _ in XCTFail("Unexpected home lookup"); return "" }
    s.ownPID = { XCTFail("Unexpected own-PID lookup"); return 0 }
    s.panelServices = { XCTFail("Unexpected service lookup"); return [:] }
    s.processBundleID = { _ in XCTFail("Unexpected process lookup"); return "" }
    s.now = { XCTFail("Unexpected clock sample"); return 0 }
    s.wallTime = { XCTFail("Unexpected wall clock sample"); return 0 }
    s.sleep = { _ in XCTFail("Unexpected wait") }
    s.keyWindow = { _ in XCTFail("Unexpected window lookup"); throw Errors.make("no_windows") }
    return s
}
func isolatedFocusSystem() -> Focus.System {
    var s = Focus.System()
    s.frontPID = { XCTFail("Unexpected front-PID lookup"); return 0 }
    s.noAttention = { _ in XCTFail("Unexpected private attention call") }
    s.post = { _, _ in XCTFail("Unexpected input post") }
    s.freeze = { XCTFail("Unexpected screen freeze") }
    s.thaw = { XCTFail("Unexpected screen thaw") }
    s.now = { XCTFail("Unexpected clock sample"); return 0 }
    s.sleep = { _ in XCTFail("Unexpected focus wait") }
    s.background = { _ in XCTFail("Unexpected background scheduling") }
    s.personWent = { _, _ in XCTFail("Unexpected Person lookup"); return false }
    return s
}
func isolatedWindowsSystem() -> Windows.System {
    var s = Windows.System()
    s.rows = { _, _ in XCTFail("Unexpected WindowServer rows"); return [] }
    s.associated = { _ in XCTFail("Unexpected private associated-windows query"); return [] }
    s.noAttention = { _ in XCTFail("Unexpected private attention call") }
    s.now = { XCTFail("Unexpected clock sample"); return 0 }
    s.sleep = { _ in XCTFail("Unexpected menu wait") }
    return s
}
