import XCTest
@testable import ComputerUseCore

final class PruneTests: XCTestCase {
    let ctx = Context(markdown: RichText.markdown)
    func n(_ role: String = "AXGroup", _ children: Node..., title: String = "", value: String = "") -> Node { Node(role: role, title: title, value: value, children: children) }
    func t(_ value: String) -> Node { Node(role: "AXStaticText", value: value) }
    func shape(_ node: Node) -> String {
        let said = !node.title.isEmpty ? node.title : !node.value.isEmpty ? node.value : node.description
        return String(node.role.dropFirst(2)) + ":" + said + (node.children.isEmpty ? "" : "[" + node.children.map(shape).joined(separator: ",") + "]")
    }
    @discardableResult func run(_ root: Node, _ context: Context? = nil) -> Node { Prune.run(root, context ?? ctx) }
    func testPassOrderAndFourRuleResults() {
        XCTAssertEqual(Prune.passes.map { $0.name }, ["filterActions", "associateTitles", "flattenIntoSelectable", "flattenRedundantHierarchy", "mergeSingleItemGroups", "pruneNonDescriptive", "pruneEmptyDisabled", "dropSilent", "flattenRepetitiveText", "flattenLinks", "mergeTextSiblings", "calendarEvents", "richText"])
        let root = n("AXWindow", t("keep"), t("drop"), t("split"), t("change"))
        Prune.each(root, ctx) { node, _ in
            switch node.value { case "drop": return []; case "split": return [self.t("a"), self.t("b")]; case "change": node.value = "changed"; fallthrough; default: return nil }
        }
        XCTAssertEqual(root.children.map { $0.value }, ["keep", "a", "b", "changed"])
        XCTAssertTrue(Prune.each(root, ctx, { _, _ in [] }) === root)
    }
    func testCalendarEventsConditionedOnBundleAndShape() {
        for bundle in ["com.example.other", Prune.calendar] {
            let event = Node(role: "AXStaticText", roleDescription: "Event", value: "Standup", children: [t("9:00")])
            let two = Node(role: "AXStaticText", roleDescription: "Event", children: [t("a"), n("AXButton", title: "b")])
            run(n("AXWindow", event, two, title: "w"), Context(bundleID: bundle))
            XCTAssertEqual(event.children.count, bundle == Prune.calendar ? 0 : 1)
            XCTAssertEqual(two.children.count, 2)
        }
    }
    func testDroppedActionsAndLabels() {
        for action in Prune.droppedActions {
            let node = Node(role: "AXButton", title: "b", actions: [("Label", action), ("Raise", "AXRaise")])
            _ = Prune.filterActions(node, ctx)
            XCTAssertEqual(node.actions.map { $0.label }, ["Raise"])
        }
        XCTAssertEqual(Prune.droppedLabels, ["Add comment", "Remove unused rows", "Remove unused columns", "Remove unused rows and columns"])
        for label in Prune.droppedLabels {
            let node = Node(role: "AXCell", actions: [(label, "Name:" + label), ("open", "AXOpen")])
            _ = Prune.filterActions(node, ctx)
            XCTAssertEqual(node.actions.map { $0.label }, ["open"])
        }
    }
    func testRoleSpecificActionFilteringAndScrollAxes() {
        let all = ["Cancel", "Pick", "Confirm", "Increment", "Scroll Up", "Scroll Left"]
        let names = ["AXCancel", "AXPick", "AXConfirm", "AXIncrement", "AXScrollUpByPage", "AXScrollLeftByPage"]
        func left(_ role: String, settable: Bool = false, axes: String = "") -> [String] {
            let node = Node(role: role, settable: settable, actions: Array(zip(all, names)), scrollAxes: axes)
            _ = Prune.filterActions(node, ctx); return node.actions.map { $0.label }
        }
        XCTAssertEqual(left("AXMenuBarItem"), all)
        XCTAssertEqual(left("AXMenuItem"), Array(all.dropFirst(2)))
        XCTAssertEqual(left("AXTextField"), all.filter { $0 != "Confirm" })
        XCTAssertEqual(left("AXComboBox", settable: true), all.filter { $0 != "Increment" })
        XCTAssertEqual(left("AXScrollArea"), Array(all.prefix(4)))
        XCTAssertEqual(left("AXScrollArea", axes: "v"), Array(all.prefix(5)))
        XCTAssertEqual(left("AXScrollArea", axes: "vh"), all)
    }
    func testAssociateTitlesExceptDescendantsOrOwnTitle() {
        let label = t("Where:"), inside = t("Item 1")
        let popup = Node(role: "AXPopUpButton", value: "Red", titleNode: label)
        let cell = Node(role: "AXCell", titleNode: inside, children: [inside])
        let named = Node(role: "AXButton", title: "Own", titleNode: t("Other"))
        let root = run(n("AXWindow", label, popup, cell, named, title: "w"))
        XCTAssertEqual(root.children.map(shape), ["PopUpButton:Where:", "Cell:[StaticText:Item 1]", "Button:Own"])
        let menuTitle = Node(role: "AXMenuBarItem", title: "File")
        menuTitle.children = [Node(role: "AXMenu", titleNode: menuTitle, children: [n("AXMenuItem", title: "New")])]
        XCTAssertEqual(shape(run(menuTitle)), "MenuBarItem:File[Menu:[MenuItem:New]]")
    }
    func testSelectableAncestorFlattensExceptRowsAndInteractiveChildren() {
        let image = Node(role: "AXImage", description: "External drive")
        let eject = Node(role: "AXButton", title: "Eject", description: "eject", acts: ["AXPress"])
        let plain = Node(role: "AXRow", subrole: "AXOutlineRow", selectable: true, children: [n("AXCell", image, t(" Backup "), eject)])
        let table = Node(role: "AXRow", subrole: "AXTableRow", selectable: true, children: [n("AXCell", t("Item 1")), n("AXCell", t("3"))])
        let editable = Node(role: "AXRow", selectable: true, children: [n("AXCell", Node(role: "AXTextField", value: "Name", settable: true))])
        let nested = Node(role: "AXRow", selectable: true, children: [Node(role: "AXCell", selectable: true, children: [t("x")])])
        let selectedOnly = Node(role: "AXRow", selected: true, children: [t("Users")])
        run(n("AXOutline", plain, table, editable, nested, selectedOnly, title: "o"))
        XCTAssertEqual(plain.title, "Eject"); XCTAssertEqual(plain.value, "Backup"); XCTAssertEqual(plain.description, "External drive\neject"); XCTAssertTrue(plain.children.isEmpty)
        XCTAssertEqual(shape(table.children[0]), "Cell:[StaticText:Item 1]")
        XCTAssertEqual(shape(editable.children[0]), "Cell:[TextField:Name]")
        XCTAssertEqual(shape(nested.children[0]), "Cell:x")
        XCTAssertEqual(shape(selectedOnly.children[0]), "StaticText:Users")
    }
    func testPruneNonDescriptiveAndPredicates() {
        let root = Node(role: "AXWindow", title: "w", children: [
            Node(role: "AXButton", title: "Full screen", acts: ["AXPress"], children: [n()]),
            Node(role: "AXColumn", identifier: "item"), Node(role: "AXStaticText", value: " ", acts: ["AXShowMenu", "AXScrollToVisible"]),
            Node(role: "AXButton", acts: ["AXPress"]), Node(role: "AXList", focusable: true), Node(role: "AXList", subset: (0, 0, 500))])
        XCTAssertEqual(run(root).children.map(shape), ["Button:Full screen", "Button:", "List:", "List:"])
        XCTAssertFalse(Prune.described(Node(value: " \n", identifier: "only-an-id")))
        XCTAssertTrue(Prune.described(Node(help: "hint"))); XCTAssertTrue(Prune.described(Node(placeholder: "p")))
        XCTAssertFalse(Prune.interactive(Node(acts: ["AXShowMenu", "AXScrollToVisible"])))
        for node in [Node(selectable: true), Node(settable: true), Node(focusable: true), Node(selected: true), Node(focused: true), Node(acts: ["AXPress"])] { XCTAssertTrue(Prune.interactive(node)) }
    }
    func testDisabledSeparatorsOnly() {
        let root = Node(role: "AXMenu", children: [Node(role: "AXMenuItem", enabled: false, acts: ["AXPick"]), Node(role: "AXMenuItem", title: "Paste", enabled: false, acts: ["AXPick"]), Node(role: "AXButton", enabled: false, acts: ["AXPress"])])
        XCTAssertEqual(run(root).children.map(shape), ["MenuItem:Paste", "Button:"])
    }
    func testPlainSplitGroupGivesWayButIdentifiedOneStays() {
        let files = n("AXScrollArea", n("AXButton", title: "list")), side = n("AXScrollArea", n("AXButton", title: "side"))
        let root = run(n("AXWindow", n("AXSplitGroup", side, n("AXSplitGroup", files, n("AXUnknown", title: "status bar"))), title: "w"))
        XCTAssertEqual(root.children[0].children.map { $0.role }, ["AXScrollArea", "AXScrollArea", "AXUnknown"])
        let named = Node(role: "AXSplitGroup", identifier: "SidebarNavigationSplitView", children: [n("AXButton", title: "a")])
        let kept = run(n("AXWindow", n("AXSplitGroup", named), title: "w"))
        XCTAssertEqual(kept.children[0].children[0].role, "AXSplitGroup")
    }
    func testTopDownGroupsMergedBeforePruning() {
        func button(_ title: String) -> Node { Node(role: "AXButton", title: title, acts: ["AXPress"]) }
        let toolbar = n("AXToolbar", button("Back")), page = n("AXScrollArea", button("page")), tabs = n("AXTabGroup", button("tab"))
        let inner = n("AXGroup", n("AXGroup", toolbar, n()), n("AXGroup", n("AXGroup", n(), page, n())), n("AXGroup", n("AXGroup", button("Tab search")), n("AXGroup", tabs, n()), n()), n())
        let root = run(n("AXWindow", n("AXGroup", n("AXGroup", n("AXGroup", inner)), title: "Chrome"), title: "w"))
        XCTAssertEqual(shape(root.children[0]), "Group:Chrome[Group:[Toolbar:[Button:Back],Group:[ScrollArea:[Button:page]],Button:Tab search,Group:[TabGroup:[Button:tab]]]]")
    }
    func testEmptyGroupsOnlyPressedSetOrSelectedStay() {
        let spacer = Node(role: "AXGroup", acts: ["Name:Move previous", "Name:Remove from toolbar"], actions: [("Move previous", "Name:Move previous")])
        let root = Node(role: "AXWindow", title: "w", children: [Node(role: "AXGroup", focusable: true), spacer, Node(role: "AXGroup", acts: ["AXPress"]), Node(role: "AXGroup", selectable: true), Node(role: "AXUnknown", focusable: true), t("x")])
        XCTAssertEqual(run(root).children.map { $0.role }, ["AXGroup", "AXGroup", "AXUnknown", "AXStaticText"])
    }
    func testSharedTitleAndHelpedLabelStay() {
        let label = t("Spacing"), own = t("Size"), helped = Node(role: "AXStaticText", value: "Drop Cap", help: "Select to...")
        let triangle = Node(role: "AXDisclosureTriangle", value: "0", acts: ["AXPress"], titleNode: label)
        let popup = Node(role: "AXPopUpButton", value: "1.0", acts: ["AXPress"], titleNode: label)
        let box = Node(role: "AXCheckBox", value: "0", acts: ["AXPress"], titleNode: own), cap = Node(role: "AXCheckBox", value: "0", acts: ["AXPress"], titleNode: helped)
        let root = run(n("AXWindow", triangle, label, popup, own, box, helped, cap, title: "w"))
        XCTAssertEqual([triangle.title, popup.title, box.title, cap.title], ["", "", "Size", ""])
        XCTAssertEqual(root.children.map { $0.role }, ["AXDisclosureTriangle", "AXStaticText", "AXPopUpButton", "AXCheckBox", "AXStaticText", "AXCheckBox"])
    }
    func testSelectableTableKeepsRowsAndCellImageStaysBare() {
        let rows = (1...2).map { n("AXRow", n("AXCell", t("Item \($0)")), title: String($0)) }
        let table = Node(role: "AXTable", title: "expenses", selectable: true, children: rows)
        run(n("AXWindow", table, title: "w"))
        XCTAssertEqual(table.children.map { $0.role }, ["AXRow", "AXRow"])
        let cell = n("AXCell", n("AXImage"), Node(role: "AXTextField", value: "alpha.txt", settable: true))
        let root = run(n("AXWindow", n("AXOutline", n("AXRow", cell)), n("AXGroup", n("AXImage"), t("x")), title: "w"))
        XCTAssertEqual(cell.children.map { $0.role }, ["AXImage", "AXTextField"])
        XCTAssertFalse(root.children[1].walk().contains { $0.role == "AXImage" })
    }
    func testSingleGroupsAndBareContainers() {
        let hosted = n("AXGroup", n("AXGroup", n("AXButton", title: "Deep")))
        let helped = Node(role: "AXGroup", help: "Filter", children: [n("AXCheckBox", title: "Filter")])
        let named = n("AXGroup", t("inside"), title: "Formatting")
        let pressed = Node(role: "AXGroup", acts: ["AXPress", "AXShowMenu"], children: [t("web")])
        let two = n("AXGroup", n("AXButton", title: "a"), n("AXButton", title: "b"))
        let root = run(n("AXWindow", hosted, helped, named, pressed, two, title: "w"))
        XCTAssertEqual(root.children.map(shape), ["Button:Deep", "CheckBox:Filter", "Group:Formatting[StaticText:inside]", "Group:[StaticText:web]", "Group:[Button:a,Button:b]"])
    }
    func testCollapsedDetailsSummaryAndOpenGroup() {
        let closed = run(n("AXWebArea", Node(role: "AXGroup", expanded: false, acts: ["AXPress"], children: [n("AXDisclosureTriangle", title: "More")])))
        XCTAssertEqual(shape(closed.children[0]), "DisclosureTriangle:More")
        let open = run(n("AXWebArea", Node(role: "AXGroup", expanded: true, acts: ["AXPress"], children: [n("AXDisclosureTriangle", title: "More"), t("Hidden")])))
        XCTAssertEqual(open.children[0].role, "AXGroup")
    }
    func testRedundantHierarchyAndSilentRolelessGroups() {
        func pair() -> [Node] { [Node(role: "AXLink", title: "a", url: "u"), t(" by ")] }
        let outer = Node(role: "AXGroup", children: [Node(role: "AXLink", title: "first", url: "u"), Node(role: "AXGroup", children: pair())])
        let titled = Node(role: "AXGroup", title: "Box", children: [Node(role: "AXGroup", children: pair()), n("AXButton", title: "x")])
        let radios = n("AXRadioGroup", n("AXRadioButton", title: "All"), n("AXRadioButton", title: "x"))
        let helped = Node(role: "AXRadioGroup", help: "View mode", children: [n("AXRadioButton", title: "Grid")])
        let root = run(n("AXWebArea", outer, titled, radios, helped, title: "page"))
        XCTAssertEqual(root.children[0].children.map { $0.role }, ["AXLink", "AXLink", "AXStaticText"])
        XCTAssertEqual(root.children[1].children[0].role, "AXGroup")
        XCTAssertEqual(root.children[2...3].map { $0.title }, ["All", "x"])
        XCTAssertEqual(root.children[4].role, "AXRadioGroup")
    }
    func testRepetitiveTextOnlyNeighboursAndRepeatingDescendants() {
        let root = run(n("AXWebArea", t("."), t("."), n("AXImage", title: "i"), t(".")))
        XCTAssertEqual(root.children.map(shape), ["StaticText:.", "Image:i", "StaticText:."])
        let labels = run(n("AXWebArea", Node(role: "AXStaticText", value: "Query", children: [t("Query")]), Node(role: "AXStaticText", value: "Total", children: [t("3")])))
        XCTAssertEqual(labels.children.map(shape), ["StaticText:Query", "StaticText:Total[StaticText:3]"])
        XCTAssertEqual(run(n("AXWebArea", t("Today"), n("AXImage", title: "i"), t("Today"))).children.map { $0.value }, ["Today", "", "Today"])
    }
    func testLinksFlattenWithoutMarkdown() {
        let labelled = Node(role: "AXLink", title: "Luck", url: "u", children: [t("Luck"), Node(role: "AXImage", description: "pic")])
        let bare = Node(role: "AXLink", url: "u", children: [t("Read"), t("more")])
        XCTAssertEqual(run(n("AXGroup", labelled, bare, title: "p")).children.map(shape), ["Link:Luck", "Link:Read more"])
        XCTAssertFalse(bare.title.contains("]("))
    }
    func testMergeTextSiblingsPreservesFirstElementAndPageBlocksStayApart() {
        let first = Node(role: "AXStaticText", value: "Status: idle", identifier: "status", url: "file:///")
        let root = run(n("AXWindow", first, Node(role: "AXStaticText", value: "Count: 0", identifier: "count"), n("AXButton", title: "b")))
        XCTAssertTrue(root.children[0] === first); XCTAssertEqual(first.value, "Status: idle Count: 0")
        XCTAssertEqual(first.identifier, "status"); XCTAssertEqual(first.url, "file:///"); XCTAssertEqual(root.children.count, 2)
        XCTAssertEqual(run(n("AXWebArea", t("noun"), t("a chance"))).children.map { $0.value }, ["noun", "a chance"])
        XCTAssertEqual(shape(run(n("AXRow", t("Threads"), title: "Threads"))), "Row:Threads[StaticText:Threads]")
        XCTAssertEqual(run(n("AXWindow", Node(role: "AXImage", acts: ["AXPress"]), n("AXCell", t("x")))).children.map { $0.role }, ["AXImage", "AXCell"])
    }
    func testRichAreasAndBrokenMarkdownKeepsPlain() {
        let rich = Node(role: "AXTextArea", value: "one two", runs: [("one ", [:]), ("two", ["bold": true])])
        let code = Node(role: "AXTextArea", value: "x = 1")
        XCTAssertEqual(run(n("AXWindow", rich, code, title: "w")).children.map { $0.value }, ["one **two**", "x = 1"])
        let broken = Node(role: "AXTextArea", value: "plain", runs: [("a", ["heading": "not a number"])])
        XCTAssertEqual(run(n("AXWindow", broken, title: "w")).children[0].value, "plain")
        XCTAssertFalse(Mirror(reflecting: Node()).children.contains { $0.label == "sentByMe" })
    }
    func testMeasuredScrollBarAndFinderMachineryStillPrinted() throws {
        let text = try captureText(FakeApp.load("controls").read())
        for needle in ["\t\t\t21 increment page button", "\t39 full screen button Help: this button also has an action to zoom the window", "\t5 button Description: Hide Sidebar, Secondary Actions: Increment, Decrement"] { XCTAssertTrue(text.contains(needle)) }
    }
}
