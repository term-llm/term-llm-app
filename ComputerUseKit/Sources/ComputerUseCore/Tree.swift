import Foundation
import os

// Python strings count Unicode scalar values, not Swift extended graphemes or
// NSString UTF-16 units. Keep this distinction throughout printing and offset maps.
enum ReadString {
    static func equal(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
    static func equal(_ a: [String], _ b: [String]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { equal($0, $1) }
    }
    static func count(_ text: String) -> Int { text.unicodeScalars.count }
    static func slice(_ text: String, _ start: Int = 0, _ end: Int? = nil) -> String {
        let scalars = Array(text.unicodeScalars)
        let a = max(0, min(start, scalars.count))
        let b = max(a, min(end ?? scalars.count, scalars.count))
        return String(String.UnicodeScalarView(scalars[a..<b]))
    }
    // Python str.isspace(), not Foundation's set (which also includes U+200B).
    static let whitespace = CharacterSet(charactersIn: "\t\n\u{0b}\u{0c}\r\u{1c}\u{1d}\u{1e}\u{1f} \u{85}\u{a0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200a}\u{2028}\u{2029}\u{202f}\u{205f}\u{3000}")
    static func strip(_ text: String) -> String { text.trimmingCharacters(in: whitespace) }
    static func truth(_ value: Any?) -> Bool {
        guard let value else { return false }
        if let b = value as? NSNumber { return b.doubleValue != 0 }
        if let s = value as? String { return !s.isEmpty }
        if let a = value as? [Any] { return !a.isEmpty }
        if let d = value as? [String: Any] { return !d.isEmpty }
        return true
    }
    static func bool(_ value: Any?) -> Bool? {
        guard let value, CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() else { return nil }
        return value as? Bool
    }
}

/// One element as read, before pruning. Missing text fields are empty strings.
public final class Node {
    public var element: UIElementRef?
    public var role: String
    public var subrole: String
    public var roleDescription: String
    public var title: String
    public var description: String
    public var value: String
    public var valueType: String
    public var details: String
    public var rows: String
    public var columns: String
    public var placeholder: String
    public var help: String
    public var identifier: String
    public var url: String
    public var enabled: Bool
    public var selected: Bool
    public var selectable: Bool
    public var focused: Bool
    public var focusable: Bool
    /// nil: this element cannot disclose anything.
    public var expanded: Bool?
    public var settable: Bool
    public var acts: [String]
    /// Printed label -> AX name, in insertion order (including replacement in place).
    public var actions: [(label: String, action: String)]
    public var scrollAxes: String
    /// Children a to b of n were read.
    public var subset: (Int, Int, Int)?
    public var titleElement: UIElementRef?
    public var titleNode: Node?
    public var runs: [RichText.Run]?
    public var loading: Bool
    /// Set by pruning: its parent is a table cell.
    public var inCell: Bool
    public var children: [Node]

    public init(element: UIElementRef? = nil, role: String = "", subrole: String = "",
                roleDescription: String = "", title: String = "", description: String = "",
                value: String = "", valueType: String = "", details: String = "", rows: String = "",
                columns: String = "", placeholder: String = "", help: String = "", identifier: String = "",
                url: String = "", enabled: Bool = true, selected: Bool = false, selectable: Bool = false,
                focused: Bool = false, focusable: Bool = false, expanded: Bool? = nil, settable: Bool = false,
                acts: [String] = [], actions: [(label: String, action: String)] = [], scrollAxes: String = "",
                subset: (Int, Int, Int)? = nil, titleElement: UIElementRef? = nil, titleNode: Node? = nil,
                runs: [RichText.Run]? = nil, loading: Bool = false, inCell: Bool = false, children: [Node] = []) {
        self.element = element; self.role = role; self.subrole = subrole; self.roleDescription = roleDescription
        self.title = title; self.description = description; self.value = value; self.valueType = valueType
        self.details = details; self.rows = rows; self.columns = columns; self.placeholder = placeholder
        self.help = help; self.identifier = identifier; self.url = url; self.enabled = enabled
        self.selected = selected; self.selectable = selectable; self.focused = focused; self.focusable = focusable
        self.expanded = expanded; self.settable = settable; self.acts = acts; self.actions = actions
        self.scrollAxes = scrollAxes; self.subset = subset; self.titleElement = titleElement; self.titleNode = titleNode
        self.runs = runs; self.loading = loading; self.inCell = inCell; self.children = children
    }
    public func walk() -> [Node] { [self] + children.flatMap { $0.walk() } }
}

/// What the passes and printer may know about the app.
public final class Context {
    public var kind: AppKind
    public var bundleID: String
    public var windowFrame: CGRect?
    /// Menu bar titles: no actions or children are read.
    public var light: Bool
    /// A web table lists each cell again under columns and header: omit repeats.
    public var seen: [UIElementRef] = []
    public var markdown: (([RichText.Run]) throws -> (String, [Int]))?
    /// Whole-window hierarchy copy, when supported. Compare CFEqual, not pointers.
    public var prefetched: [(UIElementRef, [Any?])] = []
    public init(kind: AppKind = AppKind(), bundleID: String = "", windowFrame: CGRect? = nil,
                light: Bool = false, markdown: (([RichText.Run]) throws -> (String, [Int]))? = nil) {
        self.kind = kind; self.bundleID = bundleID; self.windowFrame = windowFrame
        self.light = light; self.markdown = markdown
    }
}

/// The window walk, footer facts, first ask, and counted accessibility switch.
public enum Tree {
    public static let maxChildren = 100
    public static let maxFiltered = 499
    public static let neighbours = 100
    // Real trees stop near depth 50; this is a guard for the walk.
    public static let maxDepth = 100
    public static let spinnerClass = "macos-mac-parity-spinner"
    public static let sourceCode = "AXTextualContextSourceCode"
    public static let fileReference = "file:///.file/id="
    public static let unresolvedFile = "com-apple-unresolvable-file-reference-url:"
    // A web view hands out its page only this long after first asked (measured 38 ms).
    public static let firstAskWait = 0.05
    public static let firstAskLimit = 3000 // 2,000 elements take 130 to 200 ms.
    public static let attributes = [
        "AXRole", "AXSubrole", "AXRoleDescription", "AXTitle", "AXDescription", "AXValue",
        "AXValueDescription", "AXPlaceholderValue", "AXHelp", "AXIdentifier", "AXURL", "AXDocument",
        "AXEnabled", "AXSelected", "AXFocused", "AXExpanded", "AXDisclosing", "AXMenuItemMarkChar",
        "AXTitleUIElement", "AXVerticalScrollBar", "AXHorizontalScrollBar", "AXTextualContext",
        "AXRowIndexRange", "AXColumnIndexRange", "AXElementBusy", "AXLoaded", "AXDOMClassList", "AXChildren"
    ]
    public static let actionLabels = [
        "AXPress": "Press", "AXShowMenu": "Show Menu", "AXConfirm": "Confirm", "AXRaise": "Raise",
        "AXCancel": "Cancel", "AXPick": "Pick", "AXDelete": "Delete", "AXIncrement": "Increment",
        "AXDecrement": "Decrement", "AXExpand": "Expand", "AXCollapse": "Collapse",
        "AXScrollUpByPage": "Scroll Up", "AXScrollDownByPage": "Scroll Down",
        "AXScrollLeftByPage": "Scroll Left", "AXScrollRightByPage": "Scroll Right",
        "AXScrollToVisible": "Scroll to Visible", "AXShowAlternateUI": "Show Alternate UI",
        "AXShowDefaultUI": "Show Default UI"
    ]
    public static let valueRoles = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXSlider"]
    public static let switches = [("AXCheckBox", "AXToggle"), ("AXCheckBox", "AXSwitch")]
    public static let visibleAttributes = ["AXVisibleRows", "AXVisibleChildren"]
    public static let selectionAttributes = ["AXSelectedRows", "AXSelectedChildren"]
    public static let textFields = ["title", "description", "value", "details", "placeholder", "help", "identifier", "url", "rows", "columns"]
    public static let runStyles = ["AXUnderline": "underline", "AXStrikethrough": "strikethrough", "AXLink": "link", "AXHeadingLevel": "heading", "AXBlockQuoteLevel": "quote"]
    public static let rangePattern = "location:(\\d+) length:(\\d+)"

    public static func text(_ value: Any?, cap: Bool = true) -> String {
        guard let value else { return "" }
        let s: String
        if let url = value as? URL { s = url.absoluteString }
        else if let attributed = value as? NSAttributedString { s = attributed.string }
        else if let v = value as? String { s = v }
        else if let b = ReadString.bool(value) { s = b ? "True" : "False" }
        else if let n = value as? NSNumber {
            s = CFNumberIsFloatType(n) ? pythonFloat(n.doubleValue) : n.stringValue
        } else { s = String(describing: value) }
        return cap ? Render.cut(s) : s
    }
    public static func filePath(_ reference: Any) -> String {
        let url = (reference as? URL) ?? URL(string: text(reference, cap: false))
        guard let url, let path = (url as NSURL).filePathURL else { return unresolvedFile }
        return path.absoluteString
    }
    public static func span(_ value: Any?) -> String {
        if let range = value as? NSRange {
            return range.length > 1 ? "\(range.location)-\(range.location + range.length - 1)" : ""
        }
        guard let value, let regex = try? NSRegularExpression(pattern: rangePattern) else { return "" }
        let str = text(value, cap: false) as NSString
        guard let m = regex.firstMatch(in: str as String, range: NSRange(location: 0, length: str.length)),
              let first = Int(str.substring(with: m.range(at: 1))), let length = Int(str.substring(with: m.range(at: 2))), length > 1 else { return "" }
        return "\(first)-\(first + length - 1)"
    }
    public static func number(_ value: Int) -> String { String(value) }
    public static func number(_ value: Double) -> String {
        guard value.isFinite else { return pythonFloat(value) }
        if value.rounded(.towardZero) == value {
            return String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), value == 0 ? 0 : value)
        }
        return String(format: "%.16g", locale: Locale(identifier: "en_US_POSIX"), value)
    }
    public static func value(_ raw: Any?, settable: Bool) -> (String, String) {
        if let b = ReadString.bool(raw) { return (b ? "on" : "off", "boolean") }
        if let n = raw as? NSNumber {
            let float = CFNumberIsFloatType(n)
            return (float ? number(n.doubleValue) : n.stringValue, float ? "float" : "integer")
        }
        if raw is String || raw is NSAttributedString { return (text(raw, cap: !settable), "string") }
        if let date = raw as? Date { return (String(describing: date), "date") }
        return ("", "unknown")
    }
    public static func label(_ name: String, described: String) -> String {
        if name.hasPrefix("Name:") { return String(name.dropFirst(5)).components(separatedBy: "\nTarget:")[0] }
        return actionLabels[name] ?? (described.isEmpty ? name : described)
    }
    public static func runs(_ el: UIElementRef) throws -> [RichText.Run]? {
        let length = try AX.backend.get(el, "AXNumberOfCharacters")
        guard ReadString.bool(length) == nil, let n = length as? NSNumber, !CFNumberIsFloatType(n), n.intValue > 0 else { return nil }
        // AXBackend carries NSRange; SystemAX wraps it as an accessibility value.
        // A plain CFRange/NSValue gets no answer from the real API.
        guard let attributed = AX.backend.param(el, "AXAttributedStringForRange", NSRange(location: 0, length: n.intValue)) as? NSAttributedString else { return nil }
        var out: [RichText.Run] = []
        var at = 0
        while at < attributed.length {
            var range = NSRange()
            let attrs = attributed.attributes(at: at, effectiveRange: &range)
            let dictionary = Dictionary(uniqueKeysWithValues: attrs.map { ($0.key.rawValue, $0.value) })
            guard let styled = try? style(dictionary), range.length > 0 else { return nil }
            // Python slices the string by code points using the AX range's length.
            out.append((ReadString.slice(attributed.string, at, at + range.length), styled))
            at += range.length
        }
        return out.isEmpty ? nil : out
    }
    public static func styled(_ role: String, _ value: String, _ context: Any?) -> Bool {
        role == "AXTextArea" && !value.isEmpty && (context as? String) != sourceCode
    }
    public static func printedText(_ el: UIElementRef) throws -> (String, [Int]?) {
        let raw = try AX.backend.getMany(el, ["AXRole", "AXValue", "AXTextualContext"])
        let plain = text(raw[1], cap: false)
        if styled(text(raw[0]), plain, raw[2]), let runs = try runs(el), !runs.isEmpty {
            if let result = try? RichText.markdown(runs) { return (result.0, result.1) }
        }
        return (plain, nil)
    }
    public static func style(_ attributes: [String: Any]) throws -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in attributes { if let name = runStyles[key] { out[name] = value } }
        let font = attributes["AXFont"] as? [String: Any] ?? [:]
        let name = "\(text(font["AXFontName"], cap: false)) \(text(font["AXVisibleName"], cap: false))".lowercased()
        for key in ["bold", "italic"] where name.contains(key) { out[key] = true }
        if name.contains("oblique") { out["italic"] = true }
        if var link = out["link"] {
            if let element = link as? UIElementRef { link = try AX.backend.get(element, "AXURL") ?? "" }
            out["link"] = Render.shortURL(text(link, cap: false))
        }
        return out
    }
    public static func node(_ el: UIElementRef, _ ctx: Context, depth: Int = 0) throws -> Node? {
        do { return try readNode(el, ctx, depth: depth) } catch is HarnessError { return nil }
    }
    public static func prefetch(_ root: UIElementRef) -> [(UIElementRef, [Any?])] {
        AX.backend.subtree(root, attributes, maxChildren: maxChildren) ?? []
    }
    public static func attributes(_ el: UIElementRef, _ ctx: Context) throws -> [Any?] {
        if let entry = ctx.prefetched.first(where: { AX.same($0.0, el) }) { return entry.1 }
        return try AX.backend.getMany(el, attributes)
    }
    public static func canSet(_ el: UIElementRef, _ name: String) -> Bool { AX.backend.settable(el, name) }
    /// A menu's pointed-at item is selected, not its check mark. Menu bar titles
    /// never print selected (Electron/Finder, 12 Oct).
    public static func selected(_ role: String, _ raw: [String: Any]) -> Bool {
        role != "AXMenuBarItem" && ReadString.truth(raw["AXSelected"])
    }
    public static func takesAValue(_ role: String, _ raw: Any?) -> Bool {
        valueRoles.contains(role) || ReadString.bool(raw) != nil || ((raw as? NSNumber).map { CFNumberIsFloatType($0) } ?? false)
    }
    public static func readNode(_ el: UIElementRef, _ ctx: Context, depth: Int) throws -> Node {
        let values = try attributes(el, ctx)
        // Keep missing attributes distinct from false, and Bool distinct from 0/1.
        var raw: [String: Any] = [:]
        for (name, value) in zip(attributes, values) { raw[name] = value }
        let role = text(raw["AXRole"])
        let menuItem = ["AXMenuItem", "AXMenuBarItem"].contains(role)
        let inMenu = menuItem || ["AXMenu", "AXMenuBar"].contains(role)
        var settable = raw["AXValue"] != nil && canSet(el, "AXValue")
        // Chromium claims even its toolbar and buttons have settable values. Only
        // fields and on/off or sliding values are useful (Chrome/Electron, 13 Oct).
        if settable && (ctx.kind.electron || ctx.kind.chromium) && !takesAValue(role, raw["AXValue"]) { settable = false }
        var (printed, type) = value(raw["AXValue"], settable: settable)
        if switches.contains(where: { $0.0 == role && $0.1 == text(raw["AXSubrole"]) }) && ["0", "1"].contains(printed) {
            printed = printed == "0" ? "off" : "on"; type = "boolean"
        }
        let given = ReadString.truth(raw["AXURL"]) ? raw["AXURL"] : raw["AXDocument"]
        var url = text(given, cap: false)
        if role == "AXImage" { url = "" } // An image's source is never printed (measured).
        if url.hasPrefix(fileReference) { url = filePath(given ?? url) }
        var disclosing = ReadString.bool(raw["AXDisclosing"])
        if disclosing != nil && !canSet(el, "AXDisclosing") { disclosing = nil }
        var expanded = disclosing
        // A web <summary> says its disclosure state in its value only. Listing an
        // attribute is insufficient: Pages can set unlisted ones; Chromium lists
        // AXExpanded on popups that cannot set it (13 Oct).
        if expanded == nil && !inMenu && role != "AXDisclosureTriangle", let b = ReadString.bool(raw["AXExpanded"]), canSet(el, "AXExpanded") { expanded = b }
        let node = Node(element: el, role: role, subrole: text(raw["AXSubrole"]), roleDescription: text(raw["AXRoleDescription"]),
                        title: text(raw["AXTitle"]), description: text(raw["AXDescription"]), value: printed, valueType: type,
                        details: text(raw["AXValueDescription"]), rows: span(raw["AXRowIndexRange"]), columns: span(raw["AXColumnIndexRange"]),
                        placeholder: text(raw["AXPlaceholderValue"]), help: text(raw["AXHelp"]), identifier: Render.visibleID(text(raw["AXIdentifier"])), url: url,
                        enabled: ReadString.bool(raw["AXEnabled"]) != false,
                        selected: selected(role, raw),
                        selectable: !menuItem && ReadString.bool(raw["AXSelected"]) != nil && canSet(el, "AXSelected"),
                        focused: ReadString.bool(raw["AXFocused"]) == true, expanded: expanded, settable: settable,
                        scrollAxes: (raw["AXVerticalScrollBar"] != nil ? "v" : "") + (raw["AXHorizontalScrollBar"] != nil ? "h" : ""),
                        titleElement: raw["AXTitleUIElement"] as? UIElementRef,
                        loading: role == "AXBusyIndicator" || (role == "AXWebArea" && ReadString.bool(raw["AXLoaded"]) == false) || ReadString.bool(raw["AXElementBusy"]) == true || (raw["AXDOMClassList"] as? [String] ?? []).contains(spinnerClass))
        if !ctx.light {
            node.acts = AX.backend.actionNames(el)
            for name in node.acts {
                let label = label(name, described: AX.backend.actionDescription(el, name))
                if let i = node.actions.firstIndex(where: { ReadString.equal($0.label, label) }) { node.actions[i].action = name }
                else { node.actions.append((label, name)) }
            }
            if let disclosing {
                let label = disclosing ? "Collapse" : "Expand"
                if !node.actions.contains(where: { $0.label == label }) { node.actions.append((label, "AXDisclosing")) }
            }
            if styled(role, printed, raw["AXTextualContext"]) { node.runs = try runs(el) }
            var kids = depth < maxDepth ? raw["AXChildren"] as? [UIElementRef] ?? [] : []
            (kids, node.subset) = try visible(el, kids, ctx)
            // Mark all siblings before descending, just like the Python walk.
            kids = kids.filter { kid in
                if ctx.seen.contains(where: { AX.same($0, kid) }) { return false }
                ctx.seen.append(kid); return true
            }
            node.children = try kids.compactMap { try self.node($0, ctx, depth: depth + 1) }
            let said = node.title + node.description + node.value + node.help + node.placeholder
            if node.children.isEmpty && ReadString.strip(said).isEmpty && !node.selectable && !settable {
                node.focusable = canSet(el, "AXFocused") // Asked only for bare leaves.
            }
        }
        return node
    }
    public static func visible(_ el: UIElementRef, _ kids: [UIElementRef], _ ctx: Context) throws -> ([UIElementRef], (Int, Int, Int)?) {
        let count = kids.count
        if count <= maxChildren { return (kids, nil) }
        for name in visibleAttributes {
            if let shown = try AX.backend.get(el, name) as? [UIElementRef], !shown.isEmpty {
                let first = kids.firstIndex { AX.same($0, shown[0]) } ?? 0
                // Electron, 12 Oct: 200 items all visible prints no subset.
                return (shown, shown.count < count ? (first, first + shown.count, count) : nil)
            }
        }
        if count > maxFiltered { return ([], (0, 0, count)) }
        let seen = kids.indices.filter { onScreen(AX.backend.frame(kids[$0]), ctx) }
        var low = seen.first ?? 0
        let high = min(count, max((seen.last.map { $0 + 1 }) ?? 0, low + neighbours))
        low = min(low, max(0, high - neighbours))
        return (Array(kids[low..<high]), (low, high, count))
    }
    public static func onScreen(_ rect: CGRect?, _ ctx: Context) -> Bool {
        guard let rect, let clip = ctx.windowFrame else { return false }
        return rect.origin.x < clip.origin.x + clip.width && clip.origin.x < rect.origin.x + rect.width && rect.origin.y < clip.origin.y + clip.height && clip.origin.y < rect.origin.y + rect.height
    }
    public static func linkTitles(_ root: Node) {
        let nodes = root.walk()
        for node in nodes where node.titleElement != nil { node.titleNode = nodes.first { AX.same($0.element, node.titleElement) } }
    }
    public static func menuBar(_ app: UIElementRef) throws -> Node? {
        guard let bar = try AX.backend.get(app, "AXMenuBar") as? UIElementRef else { return nil }
        let light = Context(light: true)
        guard let node = try node(bar, light) else { return nil }
        let items = try AX.backend.get(bar, "AXChildren") as? [UIElementRef] ?? []
        node.children = try items.compactMap { try self.node($0, light) }.filter { $0.title != "Apple" }
        return node
    }
    public static func lines(_ roots: [Node], _ ctx: Context) -> [Line] {
        let lines = roots.flatMap { Render.lines($0, ctx) }
        Render.shortenURLs(lines)
        return lines
    }
    public static func alone(_ el: UIElementRef, _ ctx: Context) throws -> Node? {
        try node(el, ctx, depth: maxDepth).map { Prune.run($0, ctx) }
    }
    public static func ownLine(_ el: UIElementRef, _ lines: [Line]) -> Line? { lines.first { AX.same($0.element, el) } }
    public static func briefLine(_ el: UIElementRef, _ ctx: Context) throws -> Line? {
        guard let node = try alone(el, ctx) else { return nil }
        if node.role != "AXMenu" {
            node.title = ""; node.description = ""; node.value = ""; node.details = ""; node.placeholder = ""
            node.help = ""; node.identifier = ""; node.url = ""; node.rows = ""; node.columns = ""; node.actions = []
        }
        return Render.lines(node, ctx).first
    }
    public static func selectedText(_ el: UIElementRef) throws -> String? {
        var text = try AX.backend.get(el, "AXSelectedText")
        if !ReadString.truth(text), let markers = try AX.backend.get(el, "AXSelectedTextMarkerRange"), ReadString.truth(markers) {
            text = AX.backend.param(el, "AXStringForTextMarkerRange", markers)
        }
        return ReadString.truth(text) ? self.text(text, cap: false) : nil
    }
    public static func read(_ target: AppTarget, _ window: WindowRef, _ kind: AppKind, menu: UIElementRef? = nil) throws -> Capture {
        let ctx = Context(kind: kind, bundleID: target.bundleID, windowFrame: window.frame, markdown: RichText.markdown)
        let app = AX.backend.app(pid: target.pid ?? 0)
        let start = menu ?? window.element
        ctx.prefetched = prefetch(start)
        var roots = [try node(start, ctx)].compactMap { $0 }
        if menu == nil, let bar = try menuBar(app) { roots.append(bar) }
        roots.forEach(linkTitles)
        let all = roots.flatMap { $0.walk() }
        let loading = all.contains { $0.loading }
        let page = all.first { $0.role == "AXWebArea" && !$0.url.isEmpty }?.url ?? roots.first?.url ?? ""
        roots = roots.map { Prune.run($0, ctx) }
        // Title association is finished. Break possible ancestor/self reference
        // cycles in these intermediate nodes before discarding the read tree.
        for node in all { node.titleNode = nil }
        let capture = Capture(windowTitle: window.title ?? "Unknown", appName: target.name, windowID: window.windowID, lines: lines(roots, ctx), menuOpen: menu != nil, loading: loading, url: (kind.http || kind.chromium) && !page.isEmpty ? page : nil)
        if menu == nil {
            // No footer beats no state if the focus disappeared during the read.
            do { try footerFacts(capture, AX.backend.get(app, "AXFocusedUIElement") as? UIElementRef, ctx) } catch is HarnessError {}
        }
        return capture
    }
    public static func askOnce(_ element: UIElementRef, limit: Int = firstAskLimit, clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) throws {
        let start = clock()
        var todo = [element], seen = 0
        while !todo.isEmpty && seen < limit {
            seen += 1
            let el = todo.removeLast()
            do {
                if let kids = try AX.backend.get(el, "AXChildren") as? [UIElementRef] { todo += kids }
            } catch is HarnessError {}
        }
        sleep(max(0, start + firstAskWait - clock()))
    }
    public static func footerFacts(_ capture: Capture, _ focus: UIElementRef?, _ ctx: Context) throws {
        guard let focus else { return }
        capture.focused = ownLine(focus, capture.lines)
        guard capture.focused != nil else { return } // A field editor in another window: say nothing.
        capture.selectedText = try selectedText(focus)
        var chosen: [UIElementRef] = []
        for name in selectionAttributes {
            if let found = try AX.backend.get(focus, name) as? [UIElementRef], !found.isEmpty { chosen = found; break }
        }
        capture.selected = try chosen.compactMap { try briefLine($0, ctx) }
    }

    // Counted per app: two agents may drive the same app.
    public static let manual = "AXManualAccessibility"
    private struct Held: Sendable { var count: Int; let element: UIElementRef; let name: String; let was: Bool }
    private struct HeldSwitches: Sendable {
        var held: [pid_t: Held] = [:]
        var order: [pid_t] = [] // Python popitem() releases newest first.
    }
    // Held across the switch writes too, so two apps' turns never interleave them.
    private static let heldSwitches = OSAllocatedUnfairLock(initialState: HeldSwitches())
    public static func enable(_ target: AppTarget, _ kind: AppKind) -> Bool {
        let app = AX.backend.app(pid: target.pid ?? 0)
        // Electron takes manual even without listing it. Chrome does not: manual
        // in the background gave 42 of 665 lines (12 Oct). Asking Chrome's app role
        // enables its page even though it refuses both switches: 39 -> 665 lines.
        let offers = kind.electron || AX.backend.names(app).contains(manual)
        _ = try? AX.backend.get(app, "AXRole")
        let pid = target.pid ?? 0
        let name = offers ? manual : "AXEnhancedUserInterface"
        return heldSwitches.withLock { switches in
            if switches.held[pid] == nil { switches.order.append(pid) }
            var held = switches.held[pid] ?? Held(count: 0, element: app, name: name, was: ReadString.bool(try? AX.backend.get(app, name)) == true)
            held.count += 1
            switches.held[pid] = held
            if held.count == 1 { set(held, on: true) }
            return held.count == 1
        }
    }
    public static func disable(_ target: AppTarget) {
        let pid = target.pid ?? 0
        heldSwitches.withLock { switches in
            guard var held = switches.held[pid] else { return }
            held.count -= 1
            if held.count <= 0 {
                switches.held.removeValue(forKey: pid); switches.order.removeAll { $0 == pid }; set(held, on: false)
            }
            else { switches.held[pid] = held }
        }
    }
    public static func disableAll() {
        heldSwitches.withLock { switches in
            for pid in switches.order.reversed() { if let held = switches.held[pid] { set(held, on: false) } }
            switches.held.removeAll(); switches.order.removeAll()
        }
    }
    private static func set(_ held: Held, on: Bool) {
        // VoiceOver/another tool may have held it before us: leave that switch on.
        if on || !held.was { try? AX.backend.set(held.element, held.name, on) }
    }
}
