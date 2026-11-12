import XCTest
@testable import ComputerUseCore

/// Swift String normalizes equality and counts graphemes. Python does neither;
/// these cases deliberately go beyond the ASCII-heavy upstream goldens.
final class ReadUnicodeTests: AXTestCase {
    let composed = "é"
    let decomposed = "e\u{301}"
    func testDuplicateFieldsAndRepeatedTextsCompareLiteralScalars() {
        let node = Node(role: "AXButton", roleDescription: "button", title: composed, description: decomposed, value: composed, details: decomposed, help: decomposed)
        XCTAssertEqual(Data(Render.lines(node, Context())[0].text.utf8), Data("button é, Description: e\u{301}, Value: é, Details: e\u{301}".utf8))
        node.description = ""
        XCTAssertTrue(Render.fields(node).contains("Help: e\u{301}"))
        let root = Node(role: "AXWebArea", children: [Node(role: "AXStaticText", value: composed), Node(role: "AXStaticText", value: decomposed)])
        XCTAssertEqual(Prune.run(root, Context()).children.count, 2)
    }
    func testDiffAndRefetchDoNotNormalizeTextOrKeys() throws {
        let old = testLine(0, composed, id: 0), new = testLine(0, decomposed, id: 0)
        XCTAssertEqual(Diff.pair([old], [new], key: { $0.id }).first?.kind, "update")
        XCTAssertEqual(Diff.pair([old], [new], key: { $0.text }).map { $0.kind }, ["insert", "remove"])
        let ax = FakeAX(), dead = El(), alive = El(), r = Revisions(); AX.backend = ax
        dead.dead = true
        try r.watch(demoTarget)
        _ = r.present(testCapture([testLine(0, "field", dead, match: [composed])]))
        XCTAssertThrowsError(try r.resolve(0, reread: { testCapture([testLine(0, "field", alive, match: [self.decomposed])]) })) { error in
            XCTAssertEqual((error as? HarnessError)?.message, Errors.make("stale_element").message)
        }
    }
    func testCutsAndOffsetMapsUseScalarsNotGraphemesOrUTF16() throws {
        let text = String(repeating: "👩‍💻", count: 200)
        XCTAssertEqual(Render.cut(text).unicodeScalars.count, 512)
        let (printed, offsets) = try RichText.markdown([(text, ["bold": true])])
        XCTAssertEqual(printed.unicodeScalars.count, 604); XCTAssertEqual(offsets.count, 605)
        XCTAssertNil(RichText.find(decomposed, nil, composed))
        XCTAssertEqual(RichText.find("👩‍💻word", nil, "word")?.0, 3)
    }
    func testPythonWhitespaceDoesNotStripZeroWidthSpace() throws {
        XCTAssertEqual(ReadString.strip("\u{1c}a\u{1f}"), "a")
        XCTAssertEqual(ReadString.strip("\u{200b}"), "\u{200b}")
        XCTAssertEqual(try RichText.markdown([("\u{200b}x\u{200b}", ["bold": true])]).0, "**\u{200b}x\u{200b}**")
        XCTAssertTrue(Prune.described(Node(value: "\u{200b}")))
    }
    func testActionDictionaryReplacementKeepsInsertionOrderAndLiteralKeys() throws {
        let ax = FakeAX(); AX.backend = ax
        let el = El("AXButton", ["AXTitle": "b"], acts: [("Name:é", ""), ("Name:e\u{301}", ""), ("Name:é\nTarget:2", "")])
        let node = try Tree.readNode(el.ref, Context(), depth: 0)
        XCTAssertEqual(node.actions.count, 2)
        XCTAssertEqual(node.actions[0].action, "Name:é\nTarget:2")
        XCTAssertEqual(Data(node.actions[1].label.utf8), Data(decomposed.utf8))
    }
    func testBoolAndNumberStayDistinctInAttributes() throws {
        AX.backend = FakeAX()
        for raw: Any in [0, 0.0] {
            let el = El("AXButton", ["AXTitle": "b", "AXEnabled": raw, "AXExpanded": raw, "AXSelected": raw], settable: ["AXExpanded", "AXSelected"])
            let node = try Tree.readNode(el.ref, Context(), depth: 0)
            XCTAssertTrue(node.enabled); XCTAssertNil(node.expanded); XCTAssertFalse(node.selectable)
        }
        XCTAssertEqual(Tree.value(1.0, settable: false).1, "float")
        XCTAssertEqual(Tree.value(1, settable: false).1, "integer")
        XCTAssertEqual(Tree.value(true, settable: false).1, "boolean")
        XCTAssertEqual(Tree.text(true), "True"); XCTAssertEqual(Tree.text(1.0), "1.0")
        XCTAssertEqual(Tree.text(URL(string: "https://example.org")!), "https://example.org")
        XCTAssertEqual(Tree.text(NSAttributedString(string: "rich")), "rich")
    }
}
