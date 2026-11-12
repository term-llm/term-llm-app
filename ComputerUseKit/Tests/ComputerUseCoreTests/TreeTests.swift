import XCTest
@testable import ComputerUseCore

final class TreeTests: AXTestCase {
    override func tearDown() { Tree.disableAll(); super.tearDown() }
    func big(_ count: Int, _ visible: String? = nil, onScreen: Range<Int> = 0..<0) -> FakeApp {
        let rows: [[String: Any]] = (0..<count).map { ["role": "AXButton", "AXRoleDescription": "button", "AXTitle": "r\($0)", "rect": [0, onScreen.contains($0) ? 1 : 9000, 5, 5]] }
        var holder: [String: Any] = ["role": "AXList", "AXRoleDescription": "list", "children": rows]
        if let visible { holder[visible] = ["$paths": (20..<25).map { [0, $0] }] }
        return FakeApp(["title": "Big", "app": "Demo", "window": ["role": "AXWindow", "AXRoleDescription": "window", "children": [holder], "rect": [0, 0, 800, 600]]])
    }
    func printedRows(_ app: FakeApp) throws -> (String, [String]) {
        let capture = try app.read(); return (capture.lines[1].detail, capture.lines.dropFirst(2).map { $0.text })
    }
    func testChildCountThresholdAndVisibleAttributes() throws {
        for visible in [nil, "AXVisibleRows", "AXVisibleChildren"] {
            let (detail, rows) = try printedRows(big(100, visible))
            XCTAssertEqual(detail, ""); XCTAssertEqual(rows.count, 100)
        }
        for count in [101, 499, 500] {
            for visible in ["AXVisibleRows", "AXVisibleChildren"] {
                let (detail, rows) = try printedRows(big(count, visible))
                XCTAssertEqual(detail, "(showing 20-25 of \(count) items)")
                XCTAssertEqual(rows, (20..<25).map { "button r\($0)" })
            }
        }
    }
    func testShowingEveryItemDoesNotPrintSubset() throws {
        let app = big(200), holder = app.window.children[0]
        holder.attrs["AXVisibleChildren"] = holder.children.map { $0.ref }
        let (detail, rows) = try printedRows(app)
        XCTAssertEqual(detail, ""); XCTAssertEqual(rows.count, 200)
    }
    func testPositionFilterWidensToNeighboursAndFitsWindow() throws {
        XCTAssertEqual(try printedRows(big(101, onScreen: 30..<40)).0, "(showing 1-101 of 101 items)")
        let (detail, rows) = try printedRows(big(499, onScreen: 200..<230))
        XCTAssertEqual(detail, "(showing 200-300 of 499 items)"); XCTAssertEqual(rows.first, "button r200"); XCTAssertEqual(rows.count, 100)
        XCTAssertEqual(try printedRows(big(499, onScreen: 0..<150)).0, "(showing 0-150 of 499 items)")
    }
    func testTooManyToFilterAndEmptyVisibleAnswer() throws {
        let (detail, rows) = try printedRows(big(500))
        XCTAssertEqual(detail, "(showing 0-0 of 500 items)"); XCTAssertEqual(rows, [])
        XCTAssertEqual(try big(101, "AXVisibleRows").read().lines[1].text, "list")
        let app = big(101, onScreen: 0..<5); app.window.children[0].attrs["AXVisibleRows"] = [UIElementRef]()
        XCTAssertEqual(try printedRows(app).0, "(showing 0-100 of 101 items)")
        XCTAssertEqual(Tree.maxChildren, 100); XCTAssertEqual(Tree.maxFiltered, 499)
    }
    func testMenuBarLastNoAppleAndNoMenuDescentByDefault() throws {
        let app = try FakeApp.load("controls"), capture = try app.read(), text = captureText(capture)
        XCTAssertFalse(capture.menuOpen)
        XCTAssertTrue(text.contains("\n41 menu bar\n\t42 Demo\n\t43 View, ID: viewMenu\n\n"))
        XCTAssertEqual(capture.lines.filter { $0.depth == 0 }.map { $0.text.components(separatedBy: " ")[0] }, ["standard", "menu"])
        XCTAssertFalse(text.contains("Apple"))
        let menus = try FakeApp.load("menu"); menus.menuPath = nil
        XCTAssertTrue(try captureText(menus.read()).hasSuffix("2 menu bar\n\t3 Format\n\nThe focused UI element is 1 button OK"))
    }
    func testMenuOnlyNestedSubmenusAndItemIdentity() throws {
        let app = try FakeApp.load("menu"), capture = try app.read(), output = captureText(capture), bar = (app.app.attrs["AXMenuBar"] as! UIElementRef).object as! El
        XCTAssertTrue(capture.menuOpen); XCTAssertNil(capture.focused); XCTAssertTrue(capture.selected.isEmpty)
        XCTAssertTrue(output.hasPrefix("Window: \"Demo\", App: Demo.\n1 Format, Secondary Actions: C"))
        XCTAssertTrue(output.hasSuffix("8 Smaller\n")); XCTAssertFalse(output.contains("menu bar")); XCTAssertFalse(output.contains("button OK"))
        let lines = output.components(separatedBy: "\n")
        XCTAssertEqual(lines[3], "\t\t3 Bold, ID: bold:")
        XCTAssertEqual(Array(lines[4...8]), ["\t\t4 (disabled) Paste, ID: paste:", "\t\t5 Font", "\t\t\t6 menu Secondary Actions: Cancel", "\t\t\t\t7 Bigger", "\t\t\t\t8 Smaller"])
        XCTAssertTrue(AX.same(capture.lines[2].element, bar.at([1, 0, 0]).ref))
        let popup = try captureText(app.read(menu: bar.at([1, 0, 3, 0]).ref)).components(separatedBy: "\n")
        XCTAssertEqual(Array(popup[1...2]), ["1 menu Secondary Actions: Cancel", "\t2 Bigger"])
    }
    func testOpenPopupMenuPrintedUnderItsButton() throws {
        let app = try FakeApp.load("controls"), closed = try captureText(app.read()).components(separatedBy: "\n"), button = app.window.at([10])
        let items = ["Red", "Green", "Blue"].map { El("AXMenuItem", ["AXTitle": $0]) }
        items[0].attrs["AXMenuItemMarkChar"] = "✓"; items[0].attrs["AXSelected"] = true
        button.children.append(El("AXMenu", children: items, acts: [("AXCancel", "cancel")]))
        let opened = try captureText(app.read()).components(separatedBy: "\n"), at = closed.firstIndex { $0.contains("pop up button") }!
        let number = Int(closed[at].trimmingCharacters(in: .whitespaces).components(separatedBy: " ")[0])!
        XCTAssertEqual(Array(opened.prefix(at + 1)), Array(closed.prefix(at + 1)))
        XCTAssertEqual(Array(opened[(at + 1)...(at + 4)]), ["\t\t\(number + 1) menu Secondary Actions: Cancel", "\t\t\t\(number + 2) (selected) Red", "\t\t\t\(number + 3) Green", "\t\t\t\(number + 4) Blue"])
        XCTAssertEqual(opened.count, closed.count + 4)
    }
    func testMeasuredWebPartsAndUnresolvedFileReference() throws {
        let app = try FakeApp.load("controls")
        app.window.children += [El("AXDisclosureTriangle", ["AXRoleDescription": "summary", "AXTitle": "More", "AXValue": false, "AXExpanded": false]), El("AXImage", ["AXRoleDescription": "image", "AXDescription": "A red square", "AXURL": "data:image/gif;base64,R0l"]), El("AXLink", ["AXTitle": "a link", "AXRoleDescription": "hyperlink", "AXURL": "x.org/2"]), El("AXTextField", ["AXRoleDescription": "text field", "AXValue": "alpha.txt", "AXURL": "file:///.file/id=6571367.195846319"])]
        let capture = try app.read()
        for expected in ["summary More, Value: off", "image A red square", "link a link, Value: x.org/2", "text field URL: com-apple-unresolvable-file-reference-url:, Value: alpha.txt"] { XCTAssertTrue(capture.lines.contains { $0.text == expected }, expected) }
    }
    func testResolvedFileReferencePrintsPath() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("alpha.txt"); try Data("a".utf8).write(to: file)
        // Bridging an NSURL reference to Swift URL eagerly resolves it. Keep
        // the CFURL's string, as Python's NSURL.absoluteString() does.
        let reference = try XCTUnwrap(CFURLCreateFileReferenceURL(nil, file as CFURL, nil)).takeRetainedValue()
        let referenceText = CFURLGetString(reference)! as String
        XCTAssertTrue(referenceText.hasPrefix(Tree.fileReference))
        let canonical = try XCTUnwrap(realpath(file.path, nil))
        defer { free(canonical) }
        let resolved = URL(fileURLWithPath: String(cString: canonical))
        XCTAssertEqual(Tree.filePath(referenceText), resolved.absoluteString)
    }
    func testFirstAskVisitsOnceLimitAndWait() throws {
        let leaves = (0..<5).map { _ in El("AXButton") }, root = El("AXWindow", children: [El(children: Array(leaves.prefix(3)))] + leaves.suffix(2))
        let ax = FakeAX(); AX.backend = ax
        var now = 10.0, slept = 0.0
        try Tree.askOnce(root.ref, clock: { now }, sleep: { slept += $0; now += $0 })
        XCTAssertEqual(ax.gets.count, 7); XCTAssertEqual(Set(ax.gets.map { ObjectIdentifier($0.0) }).count, 7)
        XCTAssertEqual(slept, 0.05, accuracy: 0.000001)
        ax.gets = []
        try Tree.askOnce(root.ref, limit: 3, clock: { now }, sleep: { _ in })
        XCTAssertEqual(ax.gets.count, 3)
    }
    func testPrefetchedHierarchyEqualsWalkWithMissingElementFallback() throws {
        let walked = try captureText(FakeApp.load("controls").read()), app = try FakeApp.load("controls")
        let nodes = app.window.walk()
        app.ax.copy = try nodes.dropLast().map { ($0.ref, try app.ax.getMany($0.ref, Tree.attributes)) }
        app.ax.gets = []; app.ax.batches = 0
        XCTAssertEqual(try captureText(app.read()), walked)
        let ownGets = app.ax.gets.filter { item in nodes.contains { $0 === item.0 } && item.1 == "AXRole" }
        XCTAssertEqual(ownGets.count, 1); XCTAssertTrue(ownGets[0].0 === nodes.last!)
    }
    func testEmptyAndReadAttributeTable() throws {
        let capture = try FakeApp.load("empty").read()
        XCTAssertTrue(capture.lines.isEmpty); XCTAssertNil(capture.focused)
        XCTAssertEqual(captureText(capture), "Window: \"\", App: Demo.\n\n")
        XCTAssertFalse(Tree.attributes.contains("AXExtrasMenuBar"))
        XCTAssertTrue(Set(["AXTitleUIElement", "AXMenuItemMarkChar"]).isSubset(of: Set(Tree.attributes)))
        XCTAssertTrue(Set(["AXKeyShortcutsValue", "AXMenuItemCmdChar"]).isDisjoint(with: Set(Tree.attributes)))
    }
    func testStateRequiresSettableNotMerelyListed() throws {
        let ax = FakeAX(); AX.backend = ax
        let page = El("AXTextArea", ["AXValue": "x", "AXSelected": false, "unlisted": ["AXSelected"]], settable: ["AXSelected"])
        let popup = El("AXPopUpButton", ["AXValue": "Red", "AXExpanded": false])
        XCTAssertTrue(try Tree.readNode(page.ref, Context(), depth: 0).selectable)
        XCTAssertNil(try Tree.readNode(popup.ref, Context(), depth: 0).expanded)
    }
    func testChromiumValuesTakenOnlyByFieldsBooleansAndFloats() {
        for (role, value): (String, Any) in [("AXTextField", ""), ("AXTextArea", "x"), ("AXRadioButton", true), ("AXSlider", 3), ("AXValueIndicator", 0.5)] { XCTAssertTrue(Tree.takesAValue(role, value)) }
        for (role, value): (String, Any) in [("AXGroup", ""), ("AXButton", ""), ("AXPopUpButton", "Red"), ("AXCheckBox", 0)] { XCTAssertFalse(Tree.takesAValue(role, value)) }
    }
    func testMenuSelectionIsPointedAtNotChecked() throws {
        AX.backend = FakeAX()
        for (role, selected, want) in [("AXMenuItem", true, true), ("AXMenuItem", false, false), ("AXMenuBarItem", true, false), ("AXRow", true, true)] {
            let e = El(role, ["AXSelected": selected, "AXMenuItemMarkChar": "✓"])
            XCTAssertEqual(try Tree.readNode(e.ref, Context(), depth: 0).selected, want)
        }
    }
    func testFocusMustBeInTreeAndSelectedTextReadTwoWays() throws {
        let app = try FakeApp.load("controls"), capture = try app.read()
        XCTAssertTrue(capture.focused === capture.lines[6]); XCTAssertNil(capture.selectedText); XCTAssertTrue(app.app.performed.isEmpty)
        let editor = El("AXTextField", ["AXRoleDescription": "x", "AXSelectedText": "alpha"])
        app.app.attrs["AXFocusedUIElement"] = editor.ref
        let noFocus = try app.read(); XCTAssertNil(noFocus.focused); XCTAssertNil(noFocus.selectedText); XCTAssertTrue(noFocus.selected.isEmpty)
        let area = app.window.at([15, 0]); app.app.attrs["AXFocusedUIElement"] = area.ref
        area.attrs["AXSelectedText"] = "Line 2"; XCTAssertEqual(try app.read().selectedText, "Line 2")
        area.attrs["AXSelectedText"] = ""; area.attrs["AXSelectedTextMarkerRange"] = "markers"
        app.ax.paramHook = { _, name, arg in name == "AXStringForTextMarkerRange" ? "text of \(arg)" : nil }
        XCTAssertEqual(try app.read().selectedText, "text of markers")
    }
    func testSelectionBlockDropsText() throws {
        let app = try FakeApp.load("controls"), table = app.window.at([16, 0])
        table.attrs["AXSelectedRows"] = [table.children[1].ref]; app.app.attrs["AXFocusedUIElement"] = table.ref
        let capture = try app.read()
        XCTAssertEqual(capture.selected.map { $0.text }, ["row (selected)"])
        XCTAssertTrue(captureText(capture).contains("Selected:\n\t29 row (selected)\n\nNote: "))
    }
    func testLoadingSignsAndPagePolicyURL() throws {
        let app = try FakeApp.load("web"), capture = try app.read(), web = app.window.at([1])
        XCTAssertTrue(capture.loading); XCTAssertEqual(capture.url, "https://www.example.com/docs/page?lang=en#top")
        web.children.removeLast(); XCTAssertFalse(try app.read().loading)
        for sign in ["AXLoaded", "AXElementBusy"] {
            web.attrs[sign] = sign != "AXLoaded"; XCTAssertTrue(try app.read().loading)
            web.attrs["AXLoaded"] = true; web.attrs["AXElementBusy"] = false
        }
        web.children[1].attrs["AXDOMClassList"] = ["x", Tree.spinnerClass]
        XCTAssertTrue(try app.read().loading)
        app.kind = AppKind(); XCTAssertNil(try app.read().url)
    }
    func testLinesCarryRefetchAndActionFieldsWithoutPressState() throws {
        let capture = try FakeApp.load("controls").read(), stepper = capture.lines[14]
        XCTAssertEqual(stepper.actions.map { $0.label }, ["Increment", "Decrement"])
        XCTAssertEqual(stepper.actions.map { $0.action }, ["AXIncrement", "AXDecrement"])
        XCTAssertEqual(stepper.match, ["AXIncrementor", "", "", "", "stepper", "", "", ""])
        XCTAssertEqual(stepper.role, "AXIncrementor"); XCTAssertEqual(stepper.value, "3.5"); XCTAssertFalse(stepper.settable)
        XCTAssertEqual(try FakeApp.load("web").read().lines[3].actions.map { $0.action }, ["AXDisclosing"])
        let out = captureText(capture)
        for token in ["button Press me, ID: press", "Secondary Actions: Raise", "\n41 menu bar", "\t\t\t21 increment page button"] { XCTAssertTrue(out.contains(token)) }
        XCTAssertFalse(out.contains("(settable) Press"))
    }
    func testMaxDepthGuard() throws {
        let root = El("AXWindow", ["AXTitle": "top"]), app = FakeApp(["title": "Deep", "app": "Demo"])
        var current = root
        for depth in 0..<(Tree.maxDepth + 5) { let child = El("AXButton", ["AXTitle": "d\(depth)"]); current.children = [child]; current = child }
        app.window = root
        XCTAssertEqual(Tree.maxDepth, 100); XCTAssertEqual(try app.read().lines.count, 101)
    }
    func testValueConversionsAndCaps() {
        for (raw, text, type): (Any, String, String) in [("abc", "abc", "string"), (0.3571428571428572, "0.3571428571428572", "float"), (Double.nan, "nan", "float"), (true, "on", "boolean"), (3, "3", "integer"), (NSObject(), "", "unknown")] {
            let got = Tree.value(raw, settable: false); XCTAssertEqual(got.0, text); XCTAssertEqual(got.1, type)
        }
        XCTAssertEqual(Tree.value(String(repeating: "x", count: 600), settable: false).0.count, 512)
        XCTAssertEqual(Tree.value(String(repeating: "x", count: 600), settable: true).0.count, 600)
    }
    func testAccessibilitySwitchChoiceAndAppRoleAsk() {
        for (kind, attribute) in [(AppKind(electron: true), Tree.manual), (AppKind(chromium: true), "AXEnhancedUserInterface"), (AppKind(), "AXEnhancedUserInterface"), (AppKind(catalyst: true), "AXEnhancedUserInterface")] {
            let app = El("AXApplication"), ax = FakeAX([100: app]); AX.backend = ax
            XCTAssertTrue(Tree.enable(demoTarget, kind)); XCTAssertEqual(app.attrs[attribute] as? Bool, true)
            XCTAssertEqual(app.attrs.count, 1); XCTAssertEqual(app.performed, ["set " + attribute])
            XCTAssertTrue(ax.gets.contains { $0.0 === app && $0.1 == "AXRole" })
            Tree.disable(demoTarget)
        }
        let app = El("AXApplication", [Tree.manual: false]); AX.backend = FakeAX([100: app])
        XCTAssertTrue(Tree.enable(demoTarget, AppKind())); XCTAssertEqual(app.attrs[Tree.manual] as? Bool, true)
        XCTAssertNil(app.attrs["AXEnhancedUserInterface"])
    }
    func testAccessibilitySwitchReferenceCountingAndDisableAll() {
        let app = El("AXApplication"); AX.backend = FakeAX([100: app])
        XCTAssertTrue(Tree.enable(demoTarget, AppKind())); XCTAssertFalse(Tree.enable(demoTarget, AppKind()))
        Tree.disable(demoTarget); XCTAssertEqual(app.attrs["AXEnhancedUserInterface"] as? Bool, true)
        Tree.disable(demoTarget); XCTAssertEqual(app.attrs["AXEnhancedUserInterface"] as? Bool, false)
        Tree.disable(demoTarget)
        XCTAssertTrue(Tree.enable(demoTarget, AppKind())); Tree.disableAll()
        XCTAssertEqual(app.attrs["AXEnhancedUserInterface"] as? Bool, false)
        XCTAssertTrue(Tree.enable(demoTarget, AppKind()))
    }
    func testPreviouslyOnSwitchRemainsOn() {
        let app = El("AXApplication", ["AXEnhancedUserInterface": true]); AX.backend = FakeAX([100: app])
        _ = Tree.enable(demoTarget, AppKind()); Tree.disable(demoTarget)
        XCTAssertEqual(app.attrs["AXEnhancedUserInterface"] as? Bool, true)
    }
    func testSwitchReleaseUsesOriginalAppAndReverseInsertionOrder() {
        let first = El("AXApplication"), second = El("AXApplication"), ax = FakeAX([100: first, 200: second])
        AX.backend = ax
        var other = demoTarget; other.pid = 200
        _ = Tree.enable(demoTarget, AppKind()); _ = Tree.enable(other, AppKind())
        ax.apps[100] = El("AXApplication") // release the switched-on instance, not a replacement
        ax.sets = []
        Tree.disableAll()
        XCTAssertEqual(ax.sets.count, 2)
        XCTAssertTrue(ax.sets[0].0 === second); XCTAssertTrue(ax.sets[1].0 === first)
        XCTAssertEqual(ax.sets.map { $0.2 as? Bool }, [false, false])
    }
    func testUnsupportedSwitchAndGoneFirstAskAreBestEffort() throws {
        let app = El("AXApplication"), ax = FakeAX([100: app]); AX.backend = ax
        ax.setHook = { _, _, _ in throw AX.failure(-25205) }
        XCTAssertTrue(Tree.enable(demoTarget, AppKind()))
        Tree.disable(demoTarget)
        ax.getHook = { _, _ in throw AX.failure(-25202) }
        var waited = false
        try Tree.askOnce(app.ref, clock: { 1 }, sleep: { waited = $0 == Tree.firstAskWait || abs($0 - Tree.firstAskWait) < 0.00001 })
        XCTAssertTrue(waited)
    }
    func testUnexpectedReadErrorsAreNotHiddenAsGoneElements() {
        enum Broken: Error { case implementation }
        let ax = FakeAX(); AX.backend = ax
        ax.getHook = { _, _ in throw Broken.implementation }
        XCTAssertThrowsError(try Tree.node(El().ref, Context()))
        XCTAssertThrowsError(try Tree.askOnce(El().ref, sleep: { _ in }))
    }
    func testFooterFailureDoesNotLoseStateAndGoneElementsOmitted() throws {
        let app = try FakeApp.load("controls"), gone = app.window.children[2]
        gone.dead = true
        app.ax.getHook = { [root = app.app.ref, ax = app.ax] e, name in
            if AX.same(e.ref, root) && name == "AXFocusedUIElement" { throw AX.failure(-25202) }
            return ax.raw(e, name)
        }
        let capture = try app.read()
        XCTAssertNil(capture.focused); XCTAssertFalse(capture.lines.contains { AX.same($0.element, gone.ref) })
    }
}
