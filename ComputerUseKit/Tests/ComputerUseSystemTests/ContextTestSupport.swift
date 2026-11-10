import AppKit
import ComputerUseCore
import XCTest
@testable import ComputerUseSystem

// Shared only by the new context tests. No real AX reads, taps, input, focus or apps.
final class ContextElement: NSObject {
    var attrs: [String: Any]; var pid: pid_t; var id: UInt32; var rect: CGRect?; var alive = true
    init(_ role: String = "AXWindow", pid: pid_t = 77, id: UInt32 = 7, rect: CGRect? = CGRect(x: -100, y: 50, width: 200, height: 100), attrs: [String: Any] = [:]) {
        self.attrs = attrs; self.attrs["AXRole"] = role; self.pid = pid; self.id = id; self.rect = rect
    }
    var ref: UIElementRef { UIElementRef(self) }
}
final class ContextObservation: AXObservation {
    var stopped = false; let names: [String]; let callback: (String, UIElementRef) -> Void
    init(_ names: [String], _ callback: @escaping (String, UIElementRef) -> Void) { self.names = names; self.callback = callback }
    func stop() { stopped = true }
    func fire(_ name: String, _ element: UIElementRef) { if !stopped && names.contains(name) { callback(name, element) } }
}
final class ContextAX: AXBackend {
    var apps: [pid_t: ContextElement] = [:], observations: [ContextObservation] = []
    var gets: [(UIElementRef, String)] = [], sets: [(UIElementRef, String, Any)] = [], performed: [(UIElementRef, String)] = []
    var failGet: Set<String> = [], failSet = false, failObserve = false, failPerform = false
    var onSet: ((UIElementRef, String, Any) -> Void)?
    var hit: UIElementRef?
    func el(_ e: UIElementRef) -> ContextElement { e.object as! ContextElement }
    func app(pid: pid_t) -> UIElementRef {
        if let e = apps[pid] { return e.ref }
        let e = ContextElement("AXApplication", pid: pid, id: 0, rect: nil); apps[pid] = e; return e.ref
    }
    func get(_ element: UIElementRef, _ name: String) throws -> Any? {
        gets.append((element, name)); if failGet.contains(name) { throw Errors.make("no_windows") }; return el(element).attrs[name]
    }
    func names(_ element: UIElementRef) -> [String] { Array(el(element).attrs.keys) }
    func getMany(_ element: UIElementRef, _ names: [String]) throws -> [Any?] { try names.map { try get(element, $0) } }
    func set(_ element: UIElementRef, _ name: String, _ value: Any) throws {
        if failSet { throw Errors.make("no_windows") }; sets.append((element, name, value)); el(element).attrs[name] = value; onSet?(element, name, value)
    }
    func settable(_ element: UIElementRef, _ name: String) -> Bool { true }
    func actionNames(_ element: UIElementRef) -> [String] { [] }
    func actionDescription(_ element: UIElementRef, _ action: String) -> String { "" }
    func perform(_ element: UIElementRef, _ action: String) throws { if failPerform { throw Errors.make("no_windows") }; performed.append((element, action)) }
    func param(_ element: UIElementRef, _ name: String, _ argument: Any) -> Any? { nil }
    func pid(_ element: UIElementRef) throws -> pid_t { el(element).pid }
    func windowID(_ element: UIElementRef) -> UInt32 { el(element).id }
    func frame(_ element: UIElementRef) -> CGRect? { el(element).rect }
    func at(_ app: UIElementRef?, x: Double, y: Double) -> UIElementRef? { hit }
    func alive(_ element: UIElementRef) -> Bool { el(element).alive }
    func observe(pid: pid_t, element: UIElementRef, names: [String], callback: @escaping (String, UIElementRef) -> Void) throws -> AXObservation {
        if failObserve { throw Errors.make("no_windows") }; let o = ContextObservation(names, callback); observations.append(o); return o
    }
}
final class ContextClock {
    var time = 1000.0, sleeps: [Double] = []
    var onSleep: (() -> Void)?
    func sleep(_ seconds: Double) { time += seconds; sleeps.append(seconds); onSleep?() }
}
class ContextTestCase: XCTestCase {
    var ax: ContextAX!; var previous: AXBackend!; var clock: ContextClock!
    let target = AppTarget(path: "/A/Test.app", bundleID: "dev.test", name: "Test", pid: 77)
    override func setUp() { super.setUp(); previous = AX.backend; ax = ContextAX(); AX.backend = ax; clock = ContextClock() }
    override func tearDown() { AX.backend = previous; ax = nil; clock = nil; super.tearDown() }
    func windowSystem() -> Windows.System {
        var s = Windows.System(); s.rows = { _, _ in [] }; s.associated = { _ in [] }; s.noAttention = { _ in }
        s.now = { self.clock.time }; s.sleep = { self.clock.sleep($0) }; return s
    }
}
