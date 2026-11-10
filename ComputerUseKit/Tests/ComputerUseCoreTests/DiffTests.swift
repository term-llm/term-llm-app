import XCTest
@testable import ComputerUseCore

final class DiffTests: XCTestCase {
    var main: String { Diff.header.replacingOccurrences(of: "{}", with: "Main") }
    let same = "Nothing changed in window \"Main\" since the last read."
    func tree(_ rows: String...) -> [Line] {
        rows.map { row in
            let depth = row.prefix { $0 == "." }.count, fields = row.dropFirst(depth).split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            return testLine(depth, String(fields[1]), id: Int(fields[0])!)
        }
    }
    func paired(_ old: [Line], _ new: [Line]) -> [String] { Diff.pair(old, new, key: { $0.id }).map { $0.kind + ":" + $0.lines.map { String($0.id!) }.joined(separator: ",") }.sorted() }
    func testThreeFormsAndExactHeader() throws {
        let texts = try replay("three-forms")
        XCTAssertTrue(texts[0].hasPrefix("Window: \"Main\", App: App.\n0 "))
        XCTAssertTrue(texts[1].hasPrefix(main + "\n~")); XCTAssertTrue(texts[2].hasPrefix(same))
        XCTAssertEqual(try replay("order")[1].components(separatedBy: "\n")[0], "What changed in window \"Main\" since the last read: a line that starts with ~ changed, a line that starts with + is new. Elements that went away are listed by ID.")
        XCTAssertEqual(texts[0].components(separatedBy: "\n")[1], "0 standard window Main")
    }
    func testRemovedIDRangesAndAddedWholeSubtrees() throws {
        XCTAssertEqual(Diff.ranges(Array(275..<280) + Array(16..<274)), "16-273, 275-279")
        XCTAssertEqual(Diff.ranges([44, 23, 24, 44]), "23-24, 44"); XCTAssertEqual(Diff.ranges([7]), "7")
        let added = try replay("added-subtree")[1].components(separatedBy: "\n")
        XCTAssertEqual(added[1], "IDs of elements that went away: 3-5")
        XCTAssertEqual(Array(added.dropFirst(2)), ["+\t\t7 list", "+\t\t\t8 row 1", "+\t\t\t\t9 cell", "+\t\t\t10 row 2"])
        XCTAssertEqual(try replay("number-reuse")[2].components(separatedBy: "\n")[2], "~\t\t8 row five")
        XCTAssertEqual(try replay("order")[1].components(separatedBy: "\n").dropFirst().map { $0.components(separatedBy: " ")[0] }, ["+\t5", "~\t1", "+\t\t6", "~\t4"])
    }
    func testBudgetOverflowAndFullFallback() throws {
        XCTAssertEqual(try replay("budget").map { $0.components(separatedBy: " ")[0] }, ["Window:", "What", "Window:", "Window:", "What"])
        let changes = Diff.pair(tree("0 a", ".1 b"), tree("2 c", ".3 d"), key: { $0.id })
        XCTAssertNil(Diff.text(changes, "Main", "", 2))
        XCTAssertEqual(Diff.text(changes, "Main", "", 3)?.filter { $0 == "\n" }.count, 3)
        // Even removed, as-yet unnumbered lines must cost a summary line. Their
        // IDs are not needed if the budget already requires a full-tree fallback.
        let unnumbered = Diff.pair([testLine(0, "old")], [], key: { $0.text })
        XCTAssertNil(Diff.text(unnumbered, "Main", "", 0))
    }
    func testPrintedLineHasAbsoluteDepthIDAndDetail() {
        let node = testLine(2, "list", id: 7, detail: "(showing 1-5 of 9 items)")
        XCTAssertEqual(Diff.line(node), "\t\t7 list (showing 1-5 of 9 items)")
        XCTAssertEqual(Diff.line(testLine(0, "", id: 3)), "3 ")
        XCTAssertEqual(Diff.line(testLine(-1, "negative depth", id: 3)), "3 negative depth")
        XCTAssertEqual(Diff.text(Diff.pair([], [node], key: { $0.id }), "Main", "", 1), main + "\n+" + Diff.line(node))
    }
    func testStructuralPairingMovementAndParentBoundary() {
        let old = tree("0 w", ".1 a", ".2 b", ".3 c", "..4 d")
        XCTAssertEqual(paired(old, tree("0 w", ".1 a", ".2 b!", ".3 c", "..4 d")), ["none:0", "none:1", "none:3", "none:4", "update:2"])
        XCTAssertEqual(paired(old, tree("0 w", ".3 c", "..4 d", ".1 a", ".2 b")), ["insert:3,4", "none:0", "none:1", "none:2"])
        XCTAssertEqual(paired(old, tree("0 w", ".1 a", "..4 d", ".2 b", ".3 c")), ["insert:4", "none:0", "none:1", "none:2", "none:3", "remove:4"])
        XCTAssertTrue(paired(old, tree("0 w", ".1 a", ".2 b")).contains("remove:3,4"))
        XCTAssertEqual(paired(old, tree("9 w", ".1 a")), ["insert:9,1", "remove:0,1,2,3,4"])
    }
    func testLongestIncreasingSiblingRun() {
        for (values, kept) in [([], Set<Int>()), ([0, 1, 2], [0, 1, 2]), ([2, 0, 1], [1, 2]), ([1, 2, 0], [0, 1]), ([3, 0, 4, 1, 2], [1, 3, 4])] { XCTAssertEqual(Diff.increasing(values), kept) }
    }
    func testNoChangeOptionalFooterAndDetailIgnored() throws {
        XCTAssertEqual(try replay("menu")[3], "Nothing changed in window \"Fixture\" since the last read.")
        XCTAssertEqual(try replay("three-forms")[2], same + "\nThe focused UI element is 2 text field (settable) Value: two")
        let e = El(), revisions = Revisions()
        _ = revisions.present(testCapture([testLine(0, "list", e, detail: "1 of 9")]))
        XCTAssertEqual(revisions.present(testCapture([testLine(0, "list", e, detail: "2 of 9")])), same)
    }
    func testForcedFullAndRebindingNewSession() throws {
        XCTAssertEqual(Array(try replay("base-advances")[4].components(separatedBy: "\n")[1...4]), ["0 window", "\t1 text new", "\t2 text 2", "\t3 button"])
        let (state, _, want) = try chain("three-forms")[0]
        XCTAssertEqual(Revisions().present(state), want); XCTAssertEqual(Revisions().present(state), want)
        XCTAssertEqual(try replay("menu").prefix(3).map { String($0.components(separatedBy: "\n")[1].prefix(2)) }, ["0 ", "1 ", "1 "])
    }
    func testWindowTitleAndWindowIdentityDoNotForceFull() throws {
        let texts = try replay("new-window")
        XCTAssertEqual(texts[2], same.replacingOccurrences(of: "Main", with: "Two renamed"))
        let changed = texts[1].components(separatedBy: "\n")
        XCTAssertEqual(changed[0], Diff.header.replacingOccurrences(of: "{}", with: "Two"))
        XCTAssertEqual(Array(changed[1...2]), ["IDs of elements that went away: 0-1", "+4 standard window Two"])
    }
    func testBaseAdvancesOnEveryPresentationIncludingScreenshotOnly() throws {
        let texts = try replay("base-advances")
        XCTAssertEqual(texts[2], same); XCTAssertEqual(Array(texts[5].components(separatedBy: "\n").dropFirst()), ["~\t2 text 3"])
        let revisions = Revisions(), states = try chain("base-advances").prefix(3).map { $0.0 }
        _ = revisions.present(states[0]); _ = revisions.present(states[1]) // caller printed only screenshot
        XCTAssertEqual(revisions.present(states[2]), same); XCTAssertTrue(revisions.last === states[2])
    }
    func testUnpresentedFailureKeepsBaseResetForgetsIt() throws {
        let states = try chain("three-forms"), revisions = Revisions()
        _ = revisions.present(states[0].0)
        XCTAssertEqual(revisions.present(states[1].0), states[1].2)
        revisions.reset()
        XCTAssertTrue(revisions.present(states[1].0).hasPrefix("Window: \"Main\"")); XCTAssertEqual(states[1].0.lines[0].id, 0)
    }
    func testNoRemovalHeaderVariantCumulativeOrDebugPayload() throws {
        var texts: [String] = []
        for path in try fixtureNames("diffs", "txt") { texts += try replay(path.deletingPathExtension().lastPathComponent) }
        let all = texts.joined(separator: "\n")
        XCTAssertFalse(all.contains("and -")); XCTAssertFalse(all.components(separatedBy: "\n").contains { $0.hasPrefix("-") })
        XCTAssertFalse(all.contains("cumulative"))
        // There is no global diff gate or parser: the explicit present flag is
        // the only switch, and states are typed captures, never parsed output.
        XCTAssertFalse(Mirror(reflecting: Revisions()).children.contains { $0.label == "enabled" })
        XCTAssertTrue(try replay("three-forms")[1].hasPrefix(main))
    }
}
