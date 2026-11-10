import Foundation

/// The printed form: header, one line per element, footer. Nothing is quoted or
/// escaped; newlines inside values are printed raw.
public enum Render {
    public static let textCap = 512
    public static let longField = 100
    public static let note = "Note: the user has selected something on screen. When they ask about what they are looking at, they may mean the selection, or something else that is visible."
    public static let roleWords = ["AXGroup": "container", "AXRow": "row", "AXLink": "link", "AXMenuItem": "", "AXMenuBarItem": "", "AXRadioGroup": ""]
    public static let undescribed = ["AXMenu": "menu", "AXMenuBar": "menu bar", "AXGenericElement": "element"]
    public static let hiddenIDPrefixes = ["_", "NS"]
    public static let urlPrefixes = ["https://", "http://", "www."]
    public static let urlBudget = 4000
    // The per-URL step-down is an estimate; file paths print whole and cost nothing.
    public static let urlLimits: [(Int?, Int?)] = [(110, nil), (250, 30), (nil, 20)]
    public static let uncutURLs = ["file:"]
    public static let ellipsis = "…"
    public static func cut(_ text: String) -> String { ReadString.slice(text, 0, textCap) }
    public static func visibleID(_ identifier: String) -> String { hiddenIDPrefixes.contains { identifier.hasPrefix($0) } ? "" : identifier }
    public static func header(_ title: String, _ appName: String) -> String { "Window: \"\(title)\", App: \(appName)." }
    public static func role(_ node: Node) -> String { roleWords[node.role] ?? (node.roleDescription.isEmpty ? undescribed[node.role] ?? "unknown" : node.roleDescription) }
    public static func states(_ node: Node) -> String {
        [node.selected ? "selected" : node.selectable ? "selectable" : "", node.enabled ? "" : "disabled",
         node.expanded.map { $0 ? "expanded" : "collapsed" } ?? "", node.settable ? "settable" : "",
         node.settable && node.valueType != "string" ? node.valueType : ""].filter { !$0.isEmpty }.joined(separator: ", ")
    }
    public static func shortURL(_ url: String) -> String {
        var url = url
        for prefix in urlPrefixes where url.hasPrefix(prefix) { url = String(url.dropFirst(prefix.count)) }
        return url
    }
    public static func isLink(_ node: Node) -> Bool { node.role == "AXLink" && !node.url.isEmpty }
    public static func fields(_ node: Node) -> String {
        let link = isLink(node), said = [node.title, node.description, node.value]
        let labelled = [("Description", ReadString.equal(node.description, node.title) ? "" : node.description), ("Rows", node.rows),
                        ("Columns", node.columns), ("URL", link ? "" : shortURL(node.url)), ("Help", said.contains(where: { ReadString.equal($0, node.help) }) ? "" : node.help),
                        ("Value", link ? shortURL(node.url) : node.value), ("Details", ReadString.equal(node.details, node.value) ? "" : node.details),
                        ("Placeholder", node.placeholder), ("ID", node.identifier)]
        let present = labelled.filter { !$0.1.isEmpty }
        let actions = node.actions.map { $0.label }.joined(separator: ", ")
        var chunks: [String]
        if !node.title.isEmpty { chunks = [node.title] + present.map { "\($0.0): \($0.1)" } }
        else if present.count == 1 && actions.isEmpty { chunks = [present[0].1] }
        else { chunks = present.map { "\($0.0): \($0.1)" } }
        var sizes = (node.title.isEmpty ? [] : [node.title]) + present.map { $0.1 }
        if !actions.isEmpty { chunks.append("Secondary Actions: " + actions); sizes.append(actions) }
        let paired = zip(chunks, sizes).map { ($0.0, ReadString.count($0.1) > longField || $0.1.contains("\n")) }
        return (paired.filter { !$0.1 } + paired.filter { $0.1 }).map { $0.0 }.joined(separator: ", ")
    }
    public static func lines(_ root: Node, _ ctx: Context, depth: Int = 0) -> [Line] {
        let s = states(root)
        let line = Line(depth: depth, text: [role(root), s.isEmpty ? "" : "(\(s))", fields(root)].filter { !$0.isEmpty }.joined(separator: " "),
                        element: root.element, role: root.role,
                        detail: root.subset.map { "(showing \($0.0)-\($0.1) of \($0.2) items)" } ?? "",
                        name: root.title.isEmpty ? root.description : root.title, value: isLink(root) ? shortURL(root.url) : root.value,
                        match: [root.role, root.subrole, root.title, root.description, root.identifier, root.help, root.placeholder, root.url],
                        settable: root.settable, actions: root.actions)
        return [line] + root.children.flatMap { lines($0, ctx, depth: depth + 1) }
    }
    /// Crowded trees print each URL without query/fragment and cut to the count's
    /// limit. After the whole-tree budget is spent, only an ellipsis remains.
    public static func shortenURLs(_ lines: [Line]) {
        let urls = lines.filter { $0.match.count > 7 }.map { ($0, shortURL($0.match[7])) }.filter { !$0.1.isEmpty }
        let limit = urlLimits.first { $0.0 == nil || urls.count <= $0.0! }!.1
        var spent = 0
        for (line, full) in urls where !uncutURLs.contains(where: { full.hasPrefix($0) }) {
            var short = full
            if let limit {
                short = full.components(separatedBy: "?")[0].components(separatedBy: "#")[0]
                if ReadString.count(short) > limit { short = ReadString.slice(short, 0, limit - 1) + ellipsis }
            }
            if spent + ReadString.count(short) > urlBudget { short = ellipsis }
            spent += ReadString.count(short)
            if let range = line.text.range(of: full, options: .literal) { line.text.replaceSubrange(range, with: short) }
            if let range = line.value.range(of: full, options: .literal) { line.value.replaceSubrange(range, with: short) }
        }
    }
    public static func numbered(_ line: Line, _ numbered: Bool) -> String {
        let text = line.text + (line.detail.isEmpty ? "" : " " + line.detail)
        return numbered ? "\(line.id.map(String.init) ?? "None") \(text)" : text
    }
    /// At most one block: selected text, selected elements, or focused element.
    public static func footer(_ capture: Capture, _ numbered: Bool) -> String {
        if let text = capture.selectedText, !text.isEmpty { return "Selected text: ```\n\(text)\n```\n\n\(note)" }
        if !capture.selected.isEmpty { return "Selected:\n" + capture.selected.map { "\t" + self.numbered($0, numbered) }.joined(separator: "\n") + "\n\n" + note }
        if let focused = capture.focused { return "The focused UI element is " + self.numbered(focused, numbered) }
        return ""
    }
}
