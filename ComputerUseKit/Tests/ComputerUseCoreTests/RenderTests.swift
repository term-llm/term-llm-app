import XCTest
@testable import ComputerUseCore

final class RenderTests: XCTestCase {
    func one(_ node: Node) -> String { Render.lines(node, Context())[0].text }
    func b(_ title: String = "") -> Node { Node(role: "AXButton", roleDescription: "button", title: title) }
    func controls() throws -> String { try captureText(FakeApp.load("controls").read()) }
    func urls(_ urls: [String], role: String = "AXLink") -> [Line] {
        let lines = urls.map { Render.lines(Node(role: role, roleDescription: "link", title: "t", url: $0), Context())[0] }
        Render.shortenURLs(lines); return lines
    }
    func testHeadersLiteralTitlesAndEnvelope() throws {
        XCTAssertEqual(Render.header("Downloads", "Finder"), "Window: \"Downloads\", App: Finder.")
        XCTAssertEqual(Render.header("", "Demo"), "Window: \"\", App: Demo.")
        XCTAssertEqual(Render.header("Say \"hi\"", "A"), "Window: \"Say \"hi\"\", App: A.")
        XCTAssertTrue(try captureText(FakeApp.load("sheet").read()).hasPrefix("Window: \"Unknown\", App: Demo.\n0 sheet GoToWindow"))
        let web = try captureText(FakeApp.load("web").read()).components(separatedBy: "\n")
        XCTAssertEqual(web[0], "Window: \"Reader\", App: Reader."); XCTAssertTrue(web[1].hasPrefix("0 standard window Reader – 2 found"))
        let out = try controls().components(separatedBy: "\n")
        XCTAssertTrue(out[0].hasPrefix("Window: ")); XCTAssertTrue(out[1].hasPrefix("0 "))
        XCTAssertEqual(out[out.count - 2], ""); XCTAssertTrue(out.last!.hasPrefix("The focused UI element is "))
    }
    func testGrammarAndTabIndentation() throws {
        let output = try controls().replacingOccurrences(of: "Line 1\nLine 2", with: "Line 1 Line 2")
        let pattern = "^\\t*\\d+( [^(\\n]+)?( \\([a-z, ]+\\))?( .+)?$"
        for line in output.components(separatedBy: "\n").dropFirst().dropLast(2) { XCTAssertNotNil(line.range(of: pattern, options: .regularExpression)) }
        XCTAssertEqual(one(Node(role: "AXButton")), "unknown")
        XCTAssertEqual(one(b("Back")), "button Back")
        let back = b("Back"); back.enabled = false; XCTAssertEqual(one(back), "button (disabled) Back")
        let read = try FakeApp.load("controls").read(), depths = read.lines.map { $0.depth }
        XCTAssertEqual(depths.first, 0)
        for (a, b) in zip(depths, depths.dropFirst()) { XCTAssertLessThanOrEqual(b - a, 1) }
        XCTAssertTrue(try controls().contains("\n\t\t\t20 value indicator"))
        XCTAssertTrue(read.lines.allSatisfy { $0.id == nil && $0.element != nil })
    }
    func testRolelessLinesAndLocalizedRoleWords() {
        XCTAssertEqual(one(Node(role: "AXMenuBarItem", title: "Finder")), "Finder")
        XCTAssertEqual(one(Node(role: "AXMenuItem", title: "Halves", enabled: false)), "(disabled) Halves")
        XCTAssertEqual(one(Node(role: "AXMenuItem", title: "DESC", selected: true)), "(selected) DESC")
        XCTAssertEqual(one(Node(role: "AXRadioGroup", help: "Mode", identifier: "m")), "Help: Mode, ID: m")
        XCTAssertEqual(one(Node(role: "AXMenuItem")), "")
        for (role, desc, want) in [("AXButton", "minimise button", "minimise button"), ("AXCheckBox", "Tick box", "Tick box"), ("AXGroup", "group", "container"), ("AXRow", "outline row", "row"), ("AXMenu", "", "menu"), ("AXMenuBar", "", "menu bar"), ("AXWebArea", "HTML content", "HTML content"), ("AXGenericElement", "", "element"), ("AXOther", "", "unknown")] { XCTAssertEqual(one(Node(role: role, roleDescription: desc)), want) }
        XCTAssertEqual(one(Node(role: "AXGroup", roleDescription: "navigation", title: "Main")), "container Main")
        XCTAssertEqual(one(Node(role: "AXStaticText", roleDescription: "text", value: "x")), "text x")
        XCTAssertEqual(Render.roleWords, ["AXGroup": "container", "AXRow": "row", "AXLink": "link", "AXMenuItem": "", "AXMenuBarItem": "", "AXRadioGroup": ""])
    }
    func testFieldsCommaSpaceAndCanonicalOrder() {
        XCTAssertEqual(one(Node(role: "AXButton", roleDescription: "button", title: "A, B", description: "say \"x\"", value: "1, 2", identifier: "i d")), "button A, B, Description: say \"x\", Value: 1, 2, ID: i d")
        let node = Node(role: "AXCell", roleDescription: "cell", title: "T", description: "D", value: "V", details: "Dt", rows: "0-1", columns: "2-3", placeholder: "P", help: "H", identifier: "I", url: "https://www.a.example/x", actions: [("Raise", "AXRaise"), ("open", "AXOpen")])
        XCTAssertEqual(one(node), "cell T, Description: D, Rows: 0-1, Columns: 2-3, URL: a.example/x, Help: H, Value: V, Details: Dt, Placeholder: P, ID: I, Secondary Actions: Raise, open")
        XCTAssertEqual(one(Node(role: "AXButton", roleDescription: "button", title: "t", details: "not selected")), "button t, Details: not selected")
        XCTAssertEqual(one(Node(role: "AXButton", roleDescription: "button", title: "t", placeholder: "Search")), "button t, Placeholder: Search")
        for path in [\Node.description, \Node.value, \Node.help, \Node.placeholder, \Node.identifier, \Node.details] {
            let text = Node(role: "AXStaticText", roleDescription: "text"); text[keyPath: path] = "Today"
            XCTAssertEqual(one(text), "text Today")
        }
        let back = b("Back"); back.identifier = "b"; XCTAssertEqual(one(back), "button Back, ID: b")
        XCTAssertEqual(one(Node(role: "AXMenu", actions: [("Cancel", "AXCancel")])), "menu Secondary Actions: Cancel")
        let help = b(); help.help = "h"; help.actions = [("zoom", "AXZoom")]; XCTAssertEqual(one(help), "button Help: h, Secondary Actions: zoom")
    }
    func testLongFieldsStablePartitionAndNewlinesRaw() throws {
        for length in [100, 101] {
            let node = b("t"); node.value = String(repeating: "v", count: length); node.identifier = "i"
            XCTAssertEqual(one(node).hasSuffix(", ID: i"), length == 100)
            XCTAssertEqual(one(node).hasSuffix("Value: " + node.value), length == 101)
        }
        let title = String(repeating: "T", count: 101), url = "file:///" + String(repeating: "u", count: 101)
        XCTAssertEqual(one(Node(role: "AXWindow", roleDescription: "standard window", title: title, identifier: "w", url: url)), "standard window ID: w, \(title), URL: \(url)")
        let action = b(title); action.description = "d\ne"; action.actions = [("Raise", "AXRaise")]
        XCTAssertEqual(one(action), "button Secondary Actions: Raise, \(title), Description: d\ne")
        let newline = b("t"); newline.value = "a\nb"; newline.identifier = "i"
        XCTAssertEqual(one(newline), "button t, ID: i, Value: a\nb")
        XCTAssertTrue(try controls().contains("\n\t\t18 text entry area (settable) ID: notes, Value: Line 1\nLine 2\n"))
        XCTAssertEqual(one(b("a b\u{200b} ")), "button a b\u{200b} ")
    }
    func testLinksUseTargetsRegardlessOfEngine() {
        for desc in ["link", "hyperlink"] {
            XCTAssertEqual(one(Node(role: "AXLink", roleDescription: desc, title: "Apps", url: "https://www.example.org/a")), "link Apps, Value: example.org/a")
        }
        XCTAssertEqual(one(Node(role: "AXLink", description: "Apps", url: "https://www.example.org/a")), "link Description: Apps, Value: example.org/a")
        XCTAssertEqual(one(Node(role: "AXLink", url: "https://www.example.org/a")), "link example.org/a")
    }
    func testTextCapsBeforeMergingAndEditableWhole() throws {
        for length in [512, 513] {
            XCTAssertEqual(Render.cut(String(repeating: "x", count: length)).count, 512)
            XCTAssertEqual(Tree.text(String(repeating: "y", count: length)), String(repeating: "y", count: 512))
        }
        XCTAssertEqual(Render.textCap, 512)
        XCTAssertEqual(Tree.value(String(repeating: "z", count: 4000), settable: true).0.count, 4000)
        let app = try FakeApp.load("controls")
        for (node, letter) in zip(app.window.children.prefix(2), ["v", "w"]) { node.attrs["AXValue"] = String(repeating: letter, count: 600) }
        XCTAssertEqual(try app.read().lines[1].value, String(repeating: "v", count: 512) + " " + String(repeating: "w", count: 512))
    }
    func testStateTokensAndValueTypes() throws {
        XCTAssertEqual(one(Node(role: "AXRow", valueType: "integer", enabled: false, selected: true, selectable: true, expanded: true, settable: true)), "row (selected, disabled, expanded, settable, integer)")
        XCTAssertEqual(one(Node(role: "AXRow", selectable: true, expanded: false)), "row (selectable, collapsed)")
        let node = b(); node.focused = true; node.focusable = true; XCTAssertEqual(one(node), "button")
        for (type, value, want) in [("float", "0.5", "button (settable, float) 0.5"), ("unknown", "", "button (settable, unknown)")] {
            let n = b(); n.value = value; n.valueType = type; n.settable = true; XCTAssertEqual(one(n), want)
        }
        XCTAssertEqual(one(Node(role: "AXTextField", roleDescription: "text field", valueType: "string", settable: true)), "text field (settable)")
        XCTAssertEqual(one(Node(role: "AXTextField", roleDescription: "text field", title: "Connection URL", settable: true)), "text field (settable) Connection URL")
        XCTAssertEqual(one(Node(role: "AXTextField", roleDescription: "secure text field", value: "••••", settable: true)), "secure text field (settable) ••••")
        let output = try controls(), web = try captureText(FakeApp.load("web").read())
        let regex = try NSRegularExpression(pattern: "^\\t*\\d+ [^(\\n]*\\(([a-z, ]+)\\) ?", options: .anchorsMatchLines)
        let all = output + web, ns = all as NSString
        let groups = regex.matches(in: all, range: NSRange(location: 0, length: ns.length))
        let tokens = Set(groups.flatMap { ns.substring(with: $0.range(at: 1)).components(separatedBy: ", ") })
        XCTAssertFalse(tokens.isEmpty); XCTAssertTrue(tokens.isSubset(of: Set("selected selectable disabled expanded collapsed settable float integer boolean date unknown".split(separator: " ").map(String.init))))
        for needle in ["\t12 slider (settable, float) Value: 25, ID: level", "\t7 checkbox Enable option, Value: 0", "\t8 toggle button Description: Show info, Value: off, Details: not", "\t9 radio button All, Value: 1"] { XCTAssertTrue(output.contains(needle)) }
        XCTAssertTrue(web.contains("\t\t9 heading Serendipity, Value: 1\n"))
    }
    func testNumbersPythonFormatting() {
        for (n, want) in [(25.0, "25"), (0.553133514986376, "0.553133514986376"), (-1, "-1"), (3, "3"), (.nan, "nan"), (5.0 / 14, "0.3571428571428572"), (75.0 / 346, "0.2167630057803468"), (113.0 / 230, "0.491304347826087")] { XCTAssertEqual(Tree.number(n), want) }
        XCTAssertEqual(Tree.value(false, settable: false).0, "off"); XCTAssertEqual(Tree.value(false, settable: false).1, "boolean")
    }
    func testActionsAndIdentifiers() throws {
        XCTAssertEqual(one(Node(role: "AXWindow", roleDescription: "standard window", title: "Neo", actions: [("Raise", "AXRaise")])), "standard window Neo, Secondary Actions: Raise")
        XCTAssertEqual(Tree.label("AXRaise", described: ""), "Raise")
        XCTAssertEqual(Tree.label("AXZoomWindow", described: "zoom the window"), "zoom the window")
        XCTAssertEqual(Tree.label("AXScrollToTop", described: ""), "AXScrollToTop")
        XCTAssertEqual(Tree.label("Name:Move previous\nTarget:0x0\nSelector:(null)", described: ""), "Move previous")
        XCTAssertFalse(try controls().replacingOccurrences(of: "Press me", with: "").contains("Press"))
        let area = try FakeApp.load("controls").read().lines[17]
        XCTAssertEqual(area.actions.map { $0.action }, ["AXScrollUpByPage", "AXScrollDownByPage"])
        XCTAssertTrue(area.text.hasSuffix("Secondary Actions: Scroll Up, Scroll Down"))
        XCTAssertEqual(["_NS:12", "NSButton7", "press", "N"].map(Render.visibleID), ["", "", "press", "N"])
    }
    func testURLsAndBudgetSteps() {
        let kept = ["file:///a/b", "localhost:3000/x", "mailto:a@b.c", "chrome://settings", "about:blank"]
        XCTAssertEqual(urls(["https://www.apple.com/mac", "http://example.org"] + kept).map { $0.value }, ["apple.com/mac", "example.org"] + kept)
        XCTAssertEqual(urls(["https://a.example/x?q=1#top"])[0].text, "link t, Value: a.example/x?q=1#top")
        XCTAssertEqual(Set(urls(Array(repeating: "https://developer.apple.com/get-started/now?x=1", count: 111)).map { $0.value }), ["developer.apple.com/get-start…"])
        XCTAssertEqual(Array(urls(Array(repeating: ["x-dictionary:r:'3M?lang=en", "x-dictionary:r:'Serendipity?lang=en"], count: 126).flatMap { $0 }).prefix(2)).map { $0.value }, ["x-dictionary:r:'3M", "x-dictionary:r:'Ser…"])
        let lines = urls((0..<300).map { String(format: "https://example.org/%04d/long/path/here", $0) }), values = lines.map { $0.value }
        XCTAssertEqual(values[0], "example.org/0000/lo…"); XCTAssertEqual(values.firstIndex(of: "…"), 200)
        XCTAssertEqual(Set(values.dropFirst(200)), ["…"]); XCTAssertEqual(lines[250].text, "link t, Value: …")
        XCTAssertTrue(urls(Array(repeating: "file:///" + String(repeating: "p", count: 300), count: 300)).allSatisfy { $0.value.count == 308 })
        XCTAssertEqual(Render.urlBudget, 4000)
        XCTAssertEqual(Render.urlLimits.map { $0.0 }, [110, 250, nil]); XCTAssertEqual(Render.urlLimits.map { $0.1 }, [nil, 30, 20])
        XCTAssertEqual(urls(Array(repeating: "https://www.example.org/" + String(repeating: "a", count: 60), count: 111), role: "AXWindow")[0].text, "link t, URL: example.org/aaaaaaaaaaaaaaaaa…")
    }
    func testFooterFormsAndPrecedence() {
        let focused = testLine(0, "text field (settable) Placeholder: Name, ID: name", id: 6)
        XCTAssertEqual(Render.footer(testCapture([], focused: focused), true), "The focused UI element is 6 text field (settable) Placeholder: Name, ID: name")
        let listed = testCapture([], focused: testLine(0, "list", id: 3, detail: "(showing 0-10 of 200 items)"))
        XCTAssertTrue(Render.footer(listed, true).hasSuffix("3 list (showing 0-10 of 200 items)"))
        XCTAssertEqual(Render.footer(listed, false), "The focused UI element is list (showing 0-10 of 200 items)")
        XCTAssertEqual(Render.footer(testCapture([], focused: focused, selectedText: "Line 30\nLine 31"), true), "Selected text: ```\nLine 30\nLine 31\n```\n\n" + Render.note)
        let selected = testCapture([], focused: focused, selected: [testLine(0, "row (selected)", id: 38), testLine(0, "row (selected)", id: 40)])
        XCTAssertEqual(Render.footer(selected, true), "Selected:\n\t38 row (selected)\n\t40 row (selected)\n\n" + Render.note)
        XCTAssertFalse(Render.footer(selected, true).contains("focused"))
        selected.selectedText = "a"
        XCTAssertEqual(Render.footer(selected, true).components(separatedBy: "\n\nNote: ").count, 2)
        XCTAssertEqual(Render.footer(testCapture([]), true), "")
        XCTAssertTrue(Render.note.hasPrefix("Note: the user has selected something")); XCTAssertTrue(Render.note.hasSuffix("or something else that is visible."))
        XCTAssertFalse(Render.footer(listed, true).hasPrefix("\n"))
    }
    func testSelectionMenuKeepsTextAndOutputHasNoDebugPayload() throws {
        let app = try FakeApp.load("menu"), bar = (app.app.attrs["AXMenuBar"] as! UIElementRef).object as! El
        app.menuPath = nil; app.app.attrs["AXFocusedUIElement"] = bar.children[1].ref
        bar.children[1].attrs["AXSelectedChildren"] = [bar.at([1, 0]).ref]
        XCTAssertEqual(try app.read().selected.map { $0.text }, ["menu Secondary Actions: Cancel"])
        let output = try controls()
        XCTAssertTrue(output.contains("\n\t43 View, ID: viewMenu\n\nThe focused UI element is 6 "))
        for token in ["AX", "pid", " 100", "[truncated to visible range]", "<app_state>"] { XCTAssertFalse(output.contains(token)) }
        XCTAssertNil(output.range(of: "\\b(x|y|width|height|frame)[=:] ?\\d", options: .regularExpression))
        let web = try FakeApp.load("web"); web.window.at([1, 1]).attrs["AXDOMClassList"] = ["hw", "big"]
        XCTAssertFalse(try captureText(web.read()).contains("hw"))
        let wanted = "AXRole AXSubrole AXRoleDescription AXTitle AXDescription AXValue AXValueDescription AXPlaceholderValue AXHelp AXIdentifier AXDOMClassList AXSelected AXFocused AXEnabled AXDisclosing AXElementBusy AXLoaded".split(separator: " ").map(String.init)
        XCTAssertTrue(Set(wanted).isSubset(of: Set(Tree.attributes)))
        let labels = ["Description", "Rows", "Columns", "URL", "Help", "Value", "Details", "Placeholder", "ID", "Secondary Actions"]
        let regex = try NSRegularExpression(pattern: "(?:, | )(" + labels.joined(separator: "|") + "): ")
        let ns = output as NSString
        let found = Set(regex.matches(in: output, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) })
        XCTAssertFalse(found.isEmpty); XCTAssertTrue(found.isSubset(of: Set(labels))); XCTAssertEqual(labels.count, 10)
    }
}
