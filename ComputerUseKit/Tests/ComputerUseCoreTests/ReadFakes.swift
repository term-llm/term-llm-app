import Foundation
import os
import XCTest
@testable import ComputerUseCore

// El/FakeAx and the JSON loader port tests/fakes.py and fakes_b.py. Equality is
// normally identity; tests can override NSObject equality to exercise CFEqual.
class El: NSObject {
    // Mutable fixture state is owned by this lock. Snapshots contain value data,
    // immutable test values, synchronized nodes, or @Sendable callbacks. Hooks run
    // outside locks; heterogeneous values never escape to asynchronous work.
    // uncheckedState/withLockUnchecked are required for operation-local Any and
    // NSObject equality-test nodes, not to declare them Sendable. Never put an
    // unsynchronized mutable reference into attrs/copy or return one from a hook.
    private struct State {
        var role: String = "AXGroup"
        var attrs: [String: Any] = [:]
        var children: [El] = []
        var acts: [(String, String)] = []
        var settableNames: Set<String> = []
        var ownerPID: pid_t = 100
        var winID: UInt32 = 1
        var rect: CGRect? = nil
        var dead: Bool = false
        var performed: [String] = []
    }
    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    var role: String {
        get { state.withLockUnchecked { $0.role } }
        set { state.withLockUnchecked { $0.role = newValue } }
    }
    var attrs: [String: Any] {
        get { state.withLockUnchecked { $0.attrs } }
        set { state.withLockUnchecked { $0.attrs = newValue } }
    }
    var children: [El] {
        get { state.withLockUnchecked { $0.children } }
        set { state.withLockUnchecked { $0.children = newValue } }
    }
    var acts: [(String, String)] {
        get { state.withLockUnchecked { $0.acts } }
        set { state.withLockUnchecked { $0.acts = newValue } }
    }
    var settableNames: Set<String> {
        get { state.withLockUnchecked { $0.settableNames } }
        set { state.withLockUnchecked { $0.settableNames = newValue } }
    }
    var ownerPID: pid_t {
        get { state.withLockUnchecked { $0.ownerPID } }
        set { state.withLockUnchecked { $0.ownerPID = newValue } }
    }
    var winID: UInt32 {
        get { state.withLockUnchecked { $0.winID } }
        set { state.withLockUnchecked { $0.winID = newValue } }
    }
    var rect: CGRect? {
        get { state.withLockUnchecked { $0.rect } }
        set { state.withLockUnchecked { $0.rect = newValue } }
    }
    var dead: Bool {
        get { state.withLockUnchecked { $0.dead } }
        set { state.withLockUnchecked { $0.dead = newValue } }
    }
    var performed: [String] {
        get { state.withLockUnchecked { $0.performed } }
        set { state.withLockUnchecked { $0.performed = newValue } }
    }

    var ref: UIElementRef { UIElementRef(self) }
    init(_ role: String = "AXGroup", _ attrs: [String: Any] = [:], children: [El] = [],
         acts: [(String, String)] = [], settable: Set<String> = [], rect: CGRect? = nil) {
        super.init()
        self.role = role; self.attrs = attrs; self.children = children; self.acts = acts
        self.settableNames = settable; self.rect = rect
    }
    func recordSet(_ name: String, _ value: Any) {
        state.withLockUnchecked { $0.attrs[name] = value; $0.performed.append("set " + name) }
    }
    func recordAction(_ action: String) { state.withLockUnchecked { $0.performed.append(action) } }
    func walk() -> [El] { [self] + children.flatMap { $0.walk() } }
    func at(_ path: [Int]) -> El { path.reduce(self) { $0.children[$1] } }
}
final class FakeObserver: AXObservation {
    let names: [String]
    private let delivery: AXObservationDelivery
    private let closed = OSAllocatedUnfairLock(initialState: false)
    var stopped: Bool { closed.withLock { $0 } }
    init(_ names: [String], _ callback: @escaping @Sendable (String, UIElementRef) -> Void) {
        self.names = names; self.delivery = AXObservationDelivery(callback)
    }
    func stop() { delivery.stop(); closed.withLock { $0 = true } }
    func fire(_ name: String, _ el: El) { if names.contains(name) { delivery.deliver(name, el.ref) } }
}
final class FakeAX: AXBackend {
    // Mutable fixture state is owned by this lock. Snapshots contain value data,
    // immutable test values, synchronized nodes, or @Sendable callbacks. Hooks run
    // outside locks; heterogeneous values never escape to asynchronous work.
    // uncheckedState/withLockUnchecked are required for operation-local Any and
    // NSObject equality-test nodes, not to declare them Sendable. Never put an
    // unsynchronized mutable reference into attrs/copy or return one from a hook.
    private struct State {
        var apps: [pid_t: El] = [:]
        var observers: [FakeObserver] = []
        var gets: [(El, String)] = []
        var sets: [(El, String, Any)] = []
        var setHook: (@Sendable (El, String, Any) throws -> Void)? = nil
        var batches: Int = 0
        var copy: [(UIElementRef, [Any?])]? = nil
        var getHook: (@Sendable (El, String) throws -> Any?)? = nil
        var paramHook: (@Sendable (El, String, Any) -> Any?)? = nil
        var failObserve: Bool = false
    }
    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    var apps: [pid_t: El] {
        get { state.withLockUnchecked { $0.apps } }
        set { state.withLockUnchecked { $0.apps = newValue } }
    }
    var observers: [FakeObserver] {
        get { state.withLockUnchecked { $0.observers } }
        set { state.withLockUnchecked { $0.observers = newValue } }
    }
    var gets: [(El, String)] {
        get { state.withLockUnchecked { $0.gets } }
        set { state.withLockUnchecked { $0.gets = newValue } }
    }
    var sets: [(El, String, Any)] {
        get { state.withLockUnchecked { $0.sets } }
        set { state.withLockUnchecked { $0.sets = newValue } }
    }
    var setHook: (@Sendable (El, String, Any) throws -> Void)? {
        get { state.withLockUnchecked { $0.setHook } }
        set { state.withLockUnchecked { $0.setHook = newValue } }
    }
    var batches: Int {
        get { state.withLockUnchecked { $0.batches } }
        set { state.withLockUnchecked { $0.batches = newValue } }
    }
    var copy: [(UIElementRef, [Any?])]? {
        get { state.withLockUnchecked { $0.copy } }
        set { state.withLockUnchecked { $0.copy = newValue } }
    }
    var getHook: (@Sendable (El, String) throws -> Any?)? {
        get { state.withLockUnchecked { $0.getHook } }
        set { state.withLockUnchecked { $0.getHook = newValue } }
    }
    var paramHook: (@Sendable (El, String, Any) -> Any?)? {
        get { state.withLockUnchecked { $0.paramHook } }
        set { state.withLockUnchecked { $0.paramHook = newValue } }
    }
    var failObserve: Bool {
        get { state.withLockUnchecked { $0.failObserve } }
        set { state.withLockUnchecked { $0.failObserve = newValue } }
    }

    private let onDeinit: @Sendable () -> Void
    init(_ apps: [pid_t: El] = [:], onDeinit: @escaping @Sendable () -> Void = {}) {
        self.onDeinit = onDeinit; self.apps = apps
    }
    deinit { onDeinit() }
    func el(_ ref: UIElementRef) -> El { ref.object as! El }
    func app(pid: pid_t) -> UIElementRef { (apps[pid] ?? El("AXApplication")).ref }
    func get(_ element: UIElementRef, _ name: String) throws -> Any? {
        let e = el(element); state.withLockUnchecked { $0.gets.append((e, name)) }
        if let hook = getHook { return try hook(e, name) }
        return raw(e, name)
    }
    func raw(_ e: El, _ name: String) -> Any? {
        if name == "AXRole" { return e.role }
        if name == "AXChildren" { return e.children.map { $0.ref } }
        return e.attrs[name]
    }
    func names(_ element: UIElementRef) -> [String] {
        let e = el(element), unlisted = e.attrs["unlisted"] as? [String] ?? []
        return ["AXRole"] + e.attrs.keys.filter { !unlisted.contains($0) }
    }
    func getMany(_ element: UIElementRef, _ names: [String]) throws -> [Any?] {
        state.withLockUnchecked { $0.batches += 1 }
        if el(element).dead { throw AX.failure(AX.invalidElement) }
        return try names.map { try get(element, $0) }
    }
    func set(_ element: UIElementRef, _ name: String, _ value: Any) throws {
        let e = el(element)
        state.withLockUnchecked { $0.sets.append((e, name, value)) }
        if let setHook { try setHook(e, name, value) }
        e.recordSet(name, value)
    }
    func settable(_ element: UIElementRef, _ name: String) -> Bool { el(element).settableNames.contains(name) }
    func actionNames(_ element: UIElementRef) -> [String] { el(element).acts.map { $0.0 } }
    func actionDescription(_ element: UIElementRef, _ action: String) -> String { el(element).acts.first { $0.0 == action }?.1 ?? "" }
    func perform(_ element: UIElementRef, _ action: String) throws { el(element).recordAction(action) }
    func param(_ element: UIElementRef, _ name: String, _ argument: Any) -> Any? { paramHook?(el(element), name, argument) ?? el(element).attrs[name] }
    func pid(_ element: UIElementRef) throws -> pid_t { el(element).ownerPID }
    func windowID(_ element: UIElementRef) -> UInt32 { el(element).winID }
    func frame(_ element: UIElementRef) -> CGRect? { el(element).rect }
    func at(_ app: UIElementRef?, x: Double, y: Double) -> UIElementRef? { nil }
    func alive(_ element: UIElementRef) -> Bool { !el(element).dead }
    func subtree(_ element: UIElementRef, _ names: [String], maxChildren: Int) -> [(UIElementRef, [Any?])]? { copy }
    func observe(pid: pid_t, element: UIElementRef, names: [String], callback: @escaping @Sendable (String, UIElementRef) -> Void) throws -> AXObservation {
        if failObserve { throw AX.failure(-25202) }
        let observer = FakeObserver(names, callback); state.withLockUnchecked { $0.observers.append(observer) }; return observer
    }
}

let demoTarget = AppTarget(path: "/Applications/Demo.app", bundleID: "dev.demo", name: "Demo", pid: 100)
let fixtureRoot = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
func fixtureNames(_ directory: String, _ ext: String) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: fixtureRoot.appendingPathComponent(directory), includingPropertiesForKeys: nil).filter { $0.pathExtension == ext }.sorted { $0.lastPathComponent < $1.lastPathComponent }
}
final class FakeApp {
    var title: String?
    var name: String
    var kind: AppKind
    var window: El
    var app: El
    var ax: FakeAX
    var menuPath: [Int]?
    init(_ spec: [String: Any]) {
        title = spec["title"] as? String; name = spec["app"] as? String ?? "Demo"
        let k = spec["kind"] as? [String: Bool] ?? [:]
        kind = AppKind(electron: k["electron"] ?? false, chromium: k["chromium"] ?? false, http: k["http"] ?? false, catalyst: k["catalyst"] ?? false)
        window = (spec["window"] as? [String: Any]).map(Self.build) ?? El()
        if spec["window"] == nil || spec["window"] is NSNull { window.dead = true }
        Self.resolve(window)
        app = El("AXApplication")
        if let bar = spec["menu_bar"] as? [String: Any] { app.attrs["AXMenuBar"] = Self.build(bar).ref }
        if let focus = spec["focus"] as? [Int] { app.attrs["AXFocusedUIElement"] = window.at(focus).ref }
        menuPath = spec["menu"] as? [Int]
        ax = FakeAX([100: app])
    }
    static func build(_ spec: [String: Any]) -> El {
        let own = ["role", "children", "actions", "settable", "rect"]
        var attrs = spec.filter { !own.contains($0.key) && !($0.value is NSNull) }
        // Python json.loads distinguishes 1 from 1.0; JSONSerialization preserves
        // NSNumber's underlying kind except for tiny integers bridged as booleans.
        for (key, value) in attrs { if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { attrs[key] = n } }
        let r = (spec["rect"] as? [NSNumber])?.map { $0.doubleValue }
        let actions = spec["actions"] as? [String: String] ?? [:]
        let order = spec["__actionOrder"] as? [String] ?? actions.keys.sorted()
        return El(spec["role"] as? String ?? "AXGroup", attrs,
                  children: (spec["children"] as? [[String: Any]] ?? []).map(build),
                  acts: order.map { ($0, actions[$0]!) },
                  settable: Set(spec["settable"] as? [String] ?? []), rect: r.map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) })
    }
    static func resolve(_ root: El) {
        for n in root.walk() { n.children = n.children.map { ($0.attrs["$dup"] as? [Int]).map { root.at($0) } ?? $0 } }
        for n in root.walk() {
            for (name, value) in n.attrs {
                guard let v = value as? [String: Any] else { continue }
                if let path = v["$path"] as? [Int] { n.attrs[name] = root.at(path).ref }
                else if let paths = v["$paths"] as? [[Int]] { n.attrs[name] = paths.map { root.at($0).ref } }
                else if let span = v["$range"] as? [Int] { n.attrs[name] = "location:\(span[0]) length:\(span[1])" }
            }
        }
    }
    static func load(_ name: String) throws -> FakeApp {
        let data = try Data(contentsOf: fixtureRoot.appendingPathComponent("trees/\(name).json"))
        // Preserve the source object's insertion order, which JSONSerialization's
        // Dictionary deliberately doesn't expose. Action dictionaries are flat.
        var source = String(decoding: data, as: UTF8.self)
        let objects = try NSRegularExpression(pattern: "\"actions\"\\s*:\\s*\\{[^}]*\\}")
        let keys = try NSRegularExpression(pattern: "\"([^\"]+)\"\\s*:")
        for m in objects.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
            let block = (source as NSString).substring(with: m.range)
            let names = keys.matches(in: block, range: NSRange(block.startIndex..., in: block)).dropFirst().map { (block as NSString).substring(with: $0.range(at: 1)) }
            let order = String(decoding: try JSONSerialization.data(withJSONObject: names), as: UTF8.self)
            source = (source as NSString).replacingCharacters(in: m.range, with: "\"__actionOrder\":\(order)," + block)
        }
        return FakeApp(try JSONSerialization.jsonObject(with: Data(source.utf8)) as! [String: Any])
    }
    func read(menu: UIElementRef? = nil) throws -> Capture {
        try AX.withBackend(ax) {
            let ref = WindowRef(element: window.ref, windowID: 7, pid: 100, title: title, frame: window.rect ?? CGRect(x: 0, y: 0, width: 800, height: 600))
            let bar = (app.attrs["AXMenuBar"] as? UIElementRef).map { $0.object as! El }
            let menu = menu ?? menuPath.flatMap { bar?.at($0).ref }
            var target = demoTarget; target.name = name
            return try Tree.read(target, ref, kind, menu: menu)
        }
    }
}
func captureText(_ capture: Capture) -> String {
    let first = capture.menuOpen ? 1 : 0
    for (i, line) in capture.lines.enumerated() { line.id = i + first }
    var spare = first + capture.lines.count
    for line in (capture.focused.map { [$0] } ?? []) + capture.selected where line.id == nil {
        if let twin = capture.lines.first(where: { AX.same($0.element, line.element) }) { line.id = twin.id }
        else { line.id = spare; spare += 1 }
    }
    let footer = Render.footer(capture, true)
    return Render.header(capture.windowTitle, capture.appName) + "\n" + capture.lines.map(Diff.line).joined(separator: "\n") + "\n" + (footer.isEmpty ? "" : "\n" + footer)
}
func testLine(_ depth: Int = 0, _ text: String = "", _ el: El = El(), role: String = "AXGroup", id: Int? = nil, detail: String = "", value: String = "", match: [String] = []) -> Line {
    Line(depth: depth, text: text, element: el.ref, role: role, detail: detail, value: value, match: match, id: id)
}
func testCapture(_ lines: [Line], title: String = "Main", focused: Line? = nil, selectedText: String? = nil, selected: [Line] = []) -> Capture {
    Capture(windowTitle: title, appName: "App", windowID: 1, lines: lines, focused: focused, selectedText: selectedText, selected: selected)
}
func chain(_ name: String) throws -> [(Capture, Bool, String)] {
    let text = try String(contentsOf: fixtureRoot.appendingPathComponent("diffs/\(name).txt"), encoding: .utf8)
    let blocks = Array(text.components(separatedBy: "== ").dropFirst())
    let regex = try NSRegularExpression(pattern: "^(\\.*)([*@]?)(\\w+) ?(.*)$", options: .dotMatchesLineSeparators)
    var known: [String: El] = [:], reads: [(Capture, Bool, String)] = []
    for i in stride(from: 0, to: blocks.count - 1, by: 2) {
        let read = blocks[i], newline = read.firstIndex(of: "\n")!
        let options = String(read[..<newline]), body = String(read[read.index(after: newline)...].dropLast())
        let flags = options.components(separatedBy: "title=")
        var lines: [Line] = [], focused: Line?
        for row in body.components(separatedBy: "\n") where !row.isEmpty {
            let str = row as NSString, m = regex.firstMatch(in: row, range: NSRange(location: 0, length: str.length))!
            let parts = (1...4).map { str.substring(with: m.range(at: $0)) }
            let e = known[parts[2]] ?? El(); known[parts[2]] = e
            let node = testLine(parts[0].count, parts[3], e)
            if !parts[1].isEmpty { focused = node }
            if parts[1] != "@" { lines.append(node) }
        }
        let capture = testCapture(lines, title: flags.count > 1 ? flags[1] : "Main", focused: focused)
        let want = String(blocks[i + 1].dropFirst("want\n".count).dropLast())
        reads.append((capture, flags[0].contains(" full"), want.replacingOccurrences(of: "<HEADER>", with: Diff.header.replacingOccurrences(of: "{}", with: capture.windowTitle))))
    }
    return reads
}
@discardableResult func replay(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String] {
    let r = Revisions()
    return try chain(name).map { capture, full, want in
        let text = r.present(capture, disableDiff: full)
        XCTAssertEqual(text, want, name, file: file, line: line)
        return text
    }
}

/// Each XCTest invocation (including setUp/tearDown) gets a private registry.
/// These fixtures are synchronous; no GCD worker implicitly inherits this scope.
class AXTestCase: XCTestCase {
    override func invokeTest() { AX.withBackend(UnavailableAX()) { super.invokeTest() } }
}
