import Foundation

/// The twelve pruning passes. A rule returns nil to keep a node, [] to remove
/// it, or replacements. Rules run children-first unless explicitly top-down.
public enum Prune {
    public typealias Rule = (Node, Context) -> [Node]?
    public static let group = "AXGroup", text = "AXStaticText", menuItem = "AXMenuItem"
    public static let splitGroup = "AXSplitGroup", link = "AXLink", webArea = "AXWebArea"
    public static let roleless = ["AXRadioGroup", menuItem, "AXMenuBarItem"]
    public static let calendar = "com.apple.iCal"
    public static let droppedActions: Set<String> = ["AXPress", "AXShowMenu", "AXScrollToVisible", "AXShowDefaultUI", "AXShowAlternateUI"]
    public static let everywhereActions = droppedActions.subtracting(["AXPress"])
    public static let droppedLabels: Set<String> = ["Add comment", "Remove unused rows", "Remove unused columns", "Remove unused rows and columns"]
    public static let droppedByRole: [String: Set<String>] = [menuItem: ["AXCancel", "AXPick"], "AXTextField": ["AXConfirm"], "AXTextArea": ["AXConfirm"]]
    public static let stepActions: Set<String> = ["AXIncrement", "AXDecrement"]
    public static let scrollAxis = ["AXScrollUpByPage": "v", "AXScrollDownByPage": "v", "AXScrollLeftByPage": "h", "AXScrollRightByPage": "h"]
    public static let flattened = ["title", "description", "value"]

    public static func described(_ node: Node) -> Bool {
        [node.title, node.description, node.value, node.help, node.placeholder].contains { !ReadString.strip($0).isEmpty }
    }
    public static func interactive(_ node: Node) -> Bool {
        node.acts.contains { !everywhereActions.contains($0) } || node.selectable || node.settable || node.focusable || node.selected || node.focused
    }
    public static func below(_ node: Node) -> [Node] { node.children.flatMap { $0.walk() } }
    public static func isText(_ node: Node) -> Bool { node.role == text && !node.value.isEmpty && node.children.isEmpty }
    /// Pass 1: drop the click itself, toolkit-wide actions, and four fixed labels.
    public static func filterActions(_ node: Node, _ ctx: Context) -> [Node]? {
        var dropped = droppedActions.union(droppedByRole[node.role] ?? [])
        if node.settable { dropped.formUnion(stepActions) }
        if node.role == "AXScrollArea" {
            for (name, axis) in scrollAxis where !node.scrollAxes.contains(axis) { dropped.insert(name) }
        }
        node.actions = node.actions.filter { !dropped.contains($0.action) && !droppedLabels.contains($0.label) }
        return nil
    }
    /// Pass 2: a text named as another element's title becomes that title. A title
    /// inside its owner (window/table cell) stays. A title named by two elements
    /// (Pages' "Spacing") stays, as does a label with its own help ("Drop Cap").
    public static func associateTitles(_ root: Node, _ ctx: Context) -> Node {
        let nodes = root.walk()
        let named = nodes.compactMap { $0.titleNode }
        var taken: Set<ObjectIdentifier> = []
        for node in nodes {
            guard let label = node.titleNode, label.role == text, node.title.isEmpty,
                  !below(node).contains(where: { $0 === label }),
                  named.filter({ $0 === label }).count <= 1, ReadString.strip(label.help).isEmpty else { continue }
            node.title = label.value.isEmpty ? label.title : label.value
            taken.insert(ObjectIdentifier(label))
        }
        for node in root.walk() { node.children.removeAll { taken.contains(ObjectIdentifier($0)) } }
        return root
    }
    /// Pass 3: selectable ancestors take over text below them and become leaves.
    /// Not table rows, selectable Numbers tables, or ancestors of selectable or
    /// settable children: those rows and cells must stay.
    public static func flattenIntoSelectable(_ node: Node, _ ctx: Context) -> [Node]? {
        let inside = below(node)
        guard node.selectable, !inside.isEmpty, node.subrole != "AXTableRow",
              !inside.contains(where: { $0.role == "AXRow" || $0.selectable || $0.settable }) else { return nil }
        for path in [\Node.title, \Node.description, \Node.value] {
            node[keyPath: path] = ([node] + inside).map { ReadString.strip($0[keyPath: path]) }.filter { !$0.isEmpty }.joined(separator: "\n")
        }
        node.children = []
        return nil
    }
    /// Pass 4: silent leaves go. Empty groups that can only focus (Chrome) or be
    /// moved in a toolbar (Numbers spacers) go. A Finder cell's bare icon stays.
    public static func pruneNonDescriptive(_ node: Node, _ ctx: Context) -> [Node]? {
        if !node.children.isEmpty || node.subset != nil || described(node) { return nil }
        if node.role == group {
            return node.selectable || node.settable || node.selected || node.focused || node.acts.contains("AXPress") ? nil : []
        }
        return interactive(node) || (node.role == "AXImage" && node.inCell) ? nil : []
    }
    /// Pass 5: disabled menu items without text are separators.
    public static func pruneEmptyDisabled(_ node: Node, _ ctx: Context) -> [Node]? {
        node.role == menuItem && !node.enabled && node.children.isEmpty && !described(node) ? [] : nil
    }
    /// Finder's inner split group gives way to panes; Font Book's named one stays.
    public static func plainSplit(_ node: Node) -> Bool { node.role == splitGroup && !described(node) && node.identifier.isEmpty }
    /// A pressable group is not plain unless pressing only opens it: a collapsed
    /// <details> gives way to its summary (measured).
    public static func plainGroup(_ node: Node) -> Bool {
        node.role == group && node.title.isEmpty && node.description.isEmpty && node.value.isEmpty && !(node.acts.contains("AXPress") && node.expanded != false) && !node.focused && !node.selected
    }
    /// Pass 6: a plain group around one child gives way to it.
    public static func mergeSingleItemGroups(_ node: Node, _ ctx: Context) -> [Node]? {
        plainGroup(node) && node.children.count == 1 ? node.children : nil
    }
    /// Top-down, one level at a time: a group that moved up is not reopened by its
    /// new parent. Measured Chrome (13 Oct), five nested groups: keep containers
    /// around page and tabs, none around toolbar. Bottom-up removed all three.
    public static func flattenRedundantHierarchy(_ root: Node, _ ctx: Context) -> Node {
        func visit(_ node: Node) {
            for plain in [plainGroup, plainSplit] where plain(node) {
                node.children = node.children.flatMap { plain($0) && !$0.children.isEmpty ? $0.children : [$0] }
            }
            node.children.forEach(visit)
        }
        visit(root); return root
    }
    /// A roleless element that says nothing gives way to its children (web content).
    public static func dropSilent(_ node: Node, _ ctx: Context) -> [Node]? {
        roleless.contains(node.role) && !described(node) && node.identifier.isEmpty && node.actions.isEmpty && !node.children.isEmpty ? node.children : nil
    }
    /// Pass 8: neighbouring identical texts keep one; a text loses children that
    /// only say its own words (web labels).
    public static func flattenRepetitiveText(_ node: Node, _ ctx: Context) -> [Node]? {
        if node.role == text && node.children.allSatisfy({ isText($0) && ReadString.equal($0.value, node.value) }) { node.children = [] }
        var kept: [Node] = []
        for child in node.children {
            if let last = kept.last, isText(child), isText(last), ReadString.equal(child.value, last.value) { continue }
            kept.append(child)
        }
        node.children = kept; return nil
    }
    /// Pass 9: a link is one line; its children repeat the label. Unlabelled links
    /// take text below them. Writing links into surrounding text as Markdown is off.
    public static func flattenLinks(_ node: Node, _ ctx: Context) -> [Node]? {
        guard node.role == link, !node.children.isEmpty else { return nil }
        if node.title.isEmpty && node.description.isEmpty {
            node.title = below(node).filter(isText).map { $0.value.isEmpty ? $0.title : $0.value }.joined(separator: " ")
        }
        node.children = []; return nil
    }
    /// Pass 10: neighbouring text leaves join with one space, preserving the first
    /// element/fields. Blocks directly under a web page stay apart.
    public static func mergeTextSiblings(_ node: Node, _ ctx: Context) -> [Node]? {
        var kept: [Node] = []
        for child in node.children {
            if let last = kept.last, isText(child), isText(last), node.role != webArea { last.value += " " + child.value }
            else { kept.append(child) }
        }
        node.children = kept; return nil
    }
    /// Pass 11: Calendar's event text loses its single text child.
    public static func calendarEvents(_ node: Node, _ ctx: Context) -> [Node]? {
        if node.role == text && node.roleDescription == "Event" && node.children.count == 1 && node.children[0].role == text && ctx.bundleID == calendar { node.children = [] }
        return nil
    }
    /// Pass 12: rich areas print Markdown. Source-code areas have no runs, and any
    /// failure in the writer preserves the plain value.
    public static func richText(_ node: Node, _ ctx: Context) -> [Node]? {
        if let runs = node.runs, !runs.isEmpty, let markdown = ctx.markdown, let result = try? markdown(runs) { node.value = result.0 }
        return nil
    }
    /// The root itself is never replaced, even when the rule returns replacements.
    @discardableResult public static func each(_ root: Node, _ ctx: Context, _ rule: Rule) -> Node {
        func visit(_ node: Node) -> [Node] {
            node.children = node.children.flatMap(visit)
            return rule(node, ctx) ?? [node]
        }
        _ = visit(root); return root
    }
    public static let passes: [(name: String, run: (Node, Context) -> Node)] = [
        ("filterActions", { each($0, $1, filterActions) }),
        ("associateTitles", associateTitles),
        ("flattenIntoSelectable", { each($0, $1, flattenIntoSelectable) }),
        ("flattenRedundantHierarchy", flattenRedundantHierarchy),
        ("mergeSingleItemGroups", { each($0, $1, mergeSingleItemGroups) }),
        ("pruneNonDescriptive", { each($0, $1, pruneNonDescriptive) }),
        ("pruneEmptyDisabled", { each($0, $1, pruneEmptyDisabled) }),
        ("dropSilent", { each($0, $1, dropSilent) }),
        ("flattenRepetitiveText", { each($0, $1, flattenRepetitiveText) }),
        ("flattenLinks", { each($0, $1, flattenLinks) }),
        ("mergeTextSiblings", { each($0, $1, mergeTextSiblings) }),
        ("calendarEvents", { each($0, $1, calendarEvents) }),
        ("richText", { each($0, $1, richText) })
    ]
    @discardableResult public static func run(_ root: Node, _ ctx: Context) -> Node {
        for node in root.walk() where node.role == "AXCell" { for child in node.children { child.inCell = true } }
        var result = root
        for pass in passes { result = pass.run(result, ctx) }
        return result
    }
}
