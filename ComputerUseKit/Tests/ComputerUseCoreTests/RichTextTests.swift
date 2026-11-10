import XCTest
@testable import ComputerUseCore

final class RichTextTests: XCTestCase {
    func md(_ runs: RichText.Run...) throws -> String { try RichText.markdown(runs).0 }
    func testAttributedTextRenderedMarkdown() throws {
        let whole = "Line one\nLINE 2 is here\nline three"
        XCTAssertEqual(try md((whole, ["bold": true])), "**\(whole)**")
        XCTAssertEqual(try md(("plain text\nstays", [:])), "plain text\nstays")
        XCTAssertEqual(try md(("a ", [:]), ("b", ["italic": true]), (" c", [:])), "a *b* c")
        for (style, want) in [(["bold": true, "italic": true], "***x***"), (["underline": 1], "<u>x</u>"), (["strikethrough": 1], "~~x~~")] {
            XCTAssertEqual(try md(("x", style)), want)
        }
        XCTAssertEqual(try md(("Title\n", ["heading": 2]), ("body", [:])), "## Title\nbody")
        XCTAssertEqual(try md(("said\nagain", ["quote": 1])), "> said\n> again")
        XCTAssertEqual(try md(("one\ntwo", ["list": true])), "- one\n- two")
        XCTAssertEqual(try md(("x = 1", ["code": true])), "```\nx = 1\n```")
    }
    func testMoreConstructs() throws {
        for (style, want): ([String: Any], String) in [(["list": "todo"], "- [ ] x"), (["list": "done"], "- [x] x"),
              (["superscript": true], "<sup>x</sup>"), (["subscript": true], "<sub>x</sub>"),
              (["collapsed": true], "<details><summary>x" + RichText.collapsed),
              (["paragraph": "Title"], "# x"), (["paragraph": "Heading"], "## x"), (["paragraph": "Subheading"], "### x"),
              (["paragraph": "Body"], "x"), (["paragraph": "Fixed width"], "```\nx\n```"), (["quote": 2], "> > x")] {
            XCTAssertEqual(try md(("x", style)), want)
        }
    }
    func testLinksInsideText() throws {
        XCTAssertEqual(try md(("see ", [:]), ("the docs", ["link": "https://example.org/d"]), (".", [:])), "see [the docs](https://example.org/d).")
    }
    func testMarkersHugWordsAndEqualRunsJoin() throws {
        XCTAssertEqual(try md((" bold ", ["bold": true]), ("next", [:])), " **bold** next")
        XCTAssertEqual(try md(("a", ["bold": true]), ("b", ["bold": true])), "**ab**")
        XCTAssertEqual(try md(("  \n", ["bold": true])), "  \n")
        XCTAssertEqual(try md(), "")
    }
    func testSourceCodeContextNotReadAsRichText() throws {
        let app = try FakeApp.load("controls"), area = app.window.at([15, 0])
        area.attrs["AXNumberOfCharacters"] = 1
        area.attrs["AXAttributedStringForRange"] = NSAttributedString(string: "x", attributes: [.init("AXFont"): ["AXFontName": "Bold"]])
        var asked = 0
        app.ax.paramHook = { _, name, _ in if name == "AXAttributedStringForRange" { asked += 1 }; return nil }
        XCTAssertEqual(try app.read().lines[18].value, "**x**")
        area.attrs["AXTextualContext"] = Tree.sourceCode
        XCTAssertEqual(try app.read().lines[18].value, "Line 1\nLine 2")
        XCTAssertEqual(asked, 1)
    }
    func testBoldItalicFromFontName() throws {
        XCTAssertEqual(try Tree.style(["AXFont": ["AXFontName": "Helvetica-Bold", "AXVisibleName": "Helvetica Bold"]]) as NSDictionary, ["bold": true] as NSDictionary)
        XCTAssertEqual(try Tree.style(["AXFont": ["AXFontName": "Helvetica-Oblique"], "AXUnderline": 1]) as NSDictionary, ["underline": 1, "italic": true] as NSDictionary)
        XCTAssertEqual(try Tree.style(["AXLink": "https://example.org", "AXForegroundColor": NSObject()]) as NSDictionary, ["link": "example.org"] as NSDictionary)
        XCTAssertTrue(try Tree.style(["AXFont": ["AXFontName": "Helvetica"]]).isEmpty)
    }
    func testAttributedRangeAndLinkElementURL() throws {
        let link = El("AXLink", ["AXURL": "https://example.org/d"]), area = El("AXTextArea", ["AXNumberOfCharacters": 13])
        let text = NSMutableAttributedString(string: "see the docs.")
        text.addAttribute(.init("AXLink"), value: link.ref, range: NSRange(location: 4, length: 8))
        let ax = FakeAX(); AX.backend = ax
        ax.paramHook = { _, name, arg in
            XCTAssertEqual(name, "AXAttributedStringForRange")
            XCTAssertEqual(arg as? NSRange, NSRange(location: 0, length: 13))
            return text
        }
        let runs = try XCTUnwrap(Tree.runs(area.ref))
        XCTAssertEqual(runs.map { $0.text }, ["see ", "the docs", "."])
        XCTAssertEqual(runs[1].style as NSDictionary, ["link": "example.org/d"] as NSDictionary)
    }
    func testDocsHostsAndPattern() {
        for (host, want) in [("docs.google.com", true), ("DOCS.GOOGLE.CO.UK", true), ("x.docs.google.com", true), ("notdocs.google.com", false), ("google.com", false)] { XCTAssertEqual(RichText.isDocsHost(host), want) }
        for (host, want) in [("docs.google.com\n", true), ("docs.google.com\r", false), ("docs.google.com\u{2028}", false), ("docſ.google.İıſK", true), ("docs.google.com\n\n", false)] { XCTAssertEqual(RichText.isDocsHost(host), want) }
        XCTAssertEqual(RichText.docsHost, "(?i)(?:^|\\.)docs\\.google\\.[a-z.]+$")
    }
    func testMarkdownMappedToSourceOffsets() throws {
        let runs: [RichText.Run] = [("Plain ", [:]), ("bold words", ["bold": true]), (" and the end", [:])]
        let (text, offsets) = try RichText.markdown(runs), plain = runs.map { $0.text }.joined()
        XCTAssertEqual(text, "Plain **bold words** and the end")
        XCTAssertEqual(offsets.count, text.unicodeScalars.count + 1)
        for target in ["bold words", "Plain", "end", "words"] {
            let (start, end) = try XCTUnwrap(RichText.find(text, offsets, target))
            XCTAssertEqual(ReadString.slice(plain, start, end), target)
        }
        let words = RichText.find(text, offsets, "words", prefix: "bold ")
        XCTAssertEqual(words?.0, 11); XCTAssertEqual(words?.1, 16)
        for (prefix, offset) in [("Plain ", 6), (text, plain.count)] {
            let found = RichText.find(text, offsets, "", prefix: prefix)
            XCTAssertEqual(found?.0, offset); XCTAssertEqual(found?.1, offset)
        }
    }
    func testSearchNeedsExactlyOneHit() {
        let text = "the cat and the hat and the cat"
        for target in ["the", "missing", ""] { XCTAssertNil(RichText.find(text, nil, target)) }
        let hat = RichText.find(text, nil, "the", suffix: " hat"), cat = RichText.find(text, nil, "cat", prefix: "the ", suffix: " and")
        XCTAssertEqual(hat?.0, 12); XCTAssertEqual(hat?.1, 15)
        XCTAssertEqual(cat?.0, 4); XCTAssertEqual(cat?.1, 7)
        XCTAssertNil(RichText.find("aaa", nil, "aa"))
    }
    func testUnicodeScalarOffsetsAndInvalidStyles() throws {
        let (text, offsets) = try RichText.markdown([("👩‍💻e\u{301}", ["bold": true])])
        XCTAssertEqual(offsets.count, 10)
        XCTAssertEqual(RichText.find(text, offsets, "e\u{301}")?.0, 3)
        XCTAssertThrowsError(try RichText.markdown([("a", ["heading": "not a number"])]))
        for style: [String: Any] in [["heading": "0"], ["heading": 0.5], ["heading": -1]] {
            XCTAssertEqual(try RichText.markdown([("a", style)]).0, " a")
        }
        XCTAssertEqual(try RichText.markdown([("a", ["heading": "٠_٢"])]).0, "## a")
        XCTAssertThrowsError(try RichText.markdown([("a", ["quote": Double.nan])] ))
    }
}
