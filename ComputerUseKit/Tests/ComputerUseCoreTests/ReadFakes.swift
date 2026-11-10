import Foundation
import XCTest
@testable import ComputerUseCore

// El/FakeAx and the JSON loader port tests/fakes.py and fakes_b.py. Equality is
// normally identity; tests can override NSObject equality to exercise CFEqual.
class El: NSObject {
    var role: String
    var attrs: [String: Any]
    var children: [El]
    var acts: [(String, String)]
    var settableNames: Set<String>
    var ownerPID: pid_t = 100
    var winID: UInt32 = 1
    var rect: CGRect?
    var dead = false
    var performed: [String] = []
    var ref: UIElementRef { UIElementRef(self) }
    init(_ role: String = "AXGroup", _ attrs: [String: Any] = [:], children: [El] = [],
         acts: [(String, String)] = [], settable: Set<String> = [], rect: CGRect? = nil) {
        self.role = role; self.attrs = attrs; self.children = children; self.acts = acts
        self.settableNames = settable; self.rect = rect
    }
    func walk() -> [El] { [self] + children.flatMap { $0.walk() } }
    func at(_ path: [Int]) -> El { path.reduce(self) { $0.children[$1] } }
}
final class FakeObserver: AXObservation {
    let names: [String]
    let callback: (String, UIElementRef) -> Void
    var stopped = false
    init(_ names: [String], _ callback: @escaping (String, UIElementRef) -> Void) { self.names = names; self.callback = callback }
    func stop() { stopped = true }
    func fire(_ name: String, _ el: El) { if !stopped && names.contains(name) { callback(name, el.ref) } }
}
class FakeAX: AXBackend {
    var apps: [pid_t: El] = [:]
    var observers: [FakeObserver] = []
    var gets: [(El, String)] = []
    var sets: [(El, String, Any)] = []
    var setHook: ((El, String, Any) throws -> Void)?
    var batches = 0
    var copy: [(UIElementRef, [Any?])]?
    var getHook: ((El, String) throws -> Any?)?
    var paramHook: ((El, String, Any) -> Any?)?
    var failObserve = false
    init(_ apps: [pid_t: El] = [:]) { self.apps = apps }
    func el(_ ref: UIElementRef) -> El { ref.object as! El }
    func app(pid: pid_t) -> UIElementRef { (apps[pid] ?? El("AXApplication")).ref }
    func get(_ element: UIElementRef, _ name: String) throws -> Any? {
        let e = el(element); gets.append((e, name))
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
        batches += 1
        if el(element).dead { throw AX.failure(AX.invalidElement) }
        return try names.map { try get(element, $0) }
    }
    func set(_ element: UIElementRef, _ name: String, _ value: Any) throws {
        let e = el(element)
        sets.append((e, name, value))
        if let setHook { try setHook(e, name, value) }
        e.attrs[name] = value; e.performed.append("set " + name)
    }
    func settable(_ element: UIElementRef, _ name: String) -> Bool { el(element).settableNames.contains(name) }
    func actionNames(_ element: UIElementRef) -> [String] { el(element).acts.map { $0.0 } }
    func actionDescription(_ element: UIElementRef, _ action: String) -> String { el(element).acts.first { $0.0 == action }?.1 ?? "" }
    func perform(_ element: UIElementRef, _ action: String) throws { el(element).performed.append(action) }
    func param(_ element: UIElementRef, _ name: String, _ argument: Any) -> Any? { paramHook?(el(element), name, argument) ?? el(element).attrs[name] }
    func pid(_ element: UIElementRef) throws -> pid_t { el(element).ownerPID }
    func windowID(_ element: UIElementRef) -> UInt32 { el(element).winID }
    func frame(_ element: UIElementRef) -> CGRect? { el(element).rect }
    func at(_ app: UIElementRef?, x: Double, y: Double) -> UIElementRef? { nil }
    func alive(_ element: UIElementRef) -> Bool { !el(element).dead }
    func subtree(_ element: UIElementRef, _ names: [String], maxChildren: Int) -> [(UIElementRef, [Any?])]? { copy }
    func observe(pid: pid_t, element: UIElementRef, names: [String], callback: @escaping (String, UIElementRef) -> Void) throws -> AXObservation {
        if failObserve { throw AX.failure(-25202) }
        let observer = FakeObserver(names, callback); observers.append(observer); return observer
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
        AX.backend = ax
        let ref = WindowRef(element: window.ref, windowID: 7, pid: 100, title: title, frame: window.rect ?? CGRect(x: 0, y: 0, width: 800, height: 600))
        let bar = (app.attrs["AXMenuBar"] as? UIElementRef).map { $0.object as! El }
        let menu = menu ?? menuPath.flatMap { bar?.at($0).ref }
        var target = demoTarget; target.name = name
        return try Tree.read(target, ref, kind, menu: menu)
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
