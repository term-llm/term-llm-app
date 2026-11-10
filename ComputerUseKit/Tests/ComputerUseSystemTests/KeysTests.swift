import ComputerUseCore
import Foundation
import XCTest
@testable import ComputerUseSystem

final class KeysTests: XCTestCase {
    func testAll210GoldenTableEntries() throws {
        let url = Bundle.module.url(forResource: "table", withExtension: "json", subdirectory: "Fixtures/keys")!
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[Any]]
        XCTAssertEqual(rows.count, 210); XCTAssertEqual(Keys.table.count, 210)
        for row in rows {
            let name = row[0] as! String, key = Keys.table[name]!
            XCTAssertEqual(key.code, row[1] is NSNull ? nil : (row[1] as! Int), name)
            XCTAssertEqual(key.flags, name == "equal" ? 0 : row[2] as! Int, name)
            XCTAssertEqual(key == Keys.Key(nil, 0), row[3] as! Bool, name)
        }
    }
    func testEditingNavigationKeypadAndFunctionKeys() throws {
        XCTAssertEqual(try Keys.chords("BackSpace Tab Linefeed Clear Return Escape Delete Home Left Up Right Down").map(\.code), [51, 48, 36, 71, 36, 53, 117, 115, 123, 126, 124, 125])
        XCTAssertEqual(try Keys.chords("Prior Page_Up Next Page_Down End Begin").map(\.code), [116, 116, 121, 121, 119, 115])
        XCTAssertEqual(try Keys.chords("KP_0 KP_1 KP_2 KP_3 KP_4 KP_5 KP_6 KP_7 KP_8 KP_9").map(\.code), [82, 83, 84, 85, 86, 87, 88, 89, 91, 92])
        XCTAssertEqual(try Keys.chords("KP_Enter KP_Add F1 F20 Menu Help").map(\.code), [76, 69, 122, 90, 110, 114])
        for name in "Select Print Execute Insert Undo Redo Find Cancel Break Num_Lock KP_Home Hyper_L".split(separator: " ") { assertHarnessError("This key does not exist on a Mac") { _ = try Keys.chords(String(name)) } }
        assertHarnessError("No key is called \"F21\"") { _ = try Keys.chords("F21") }
    }
    func testModifierNamesAndPunctuation() throws {
        for (name, flag) in [("Shift", Keys.shift), ("Control", Keys.control), ("Alt", Keys.option), ("Meta", Keys.command), ("Super", Keys.command)] {
            XCTAssertEqual(Keys.table[name + "_L"], Keys.Key(nil, flag)); XCTAssertEqual(Keys.table[name + "_R"], Keys.Key(nil, flag))
        }
        XCTAssertEqual(Keys.table["Caps_Lock"], Keys.Key(57, 0)); XCTAssertEqual(Keys.table["Shift_Lock"], Keys.Key(57, 0))
        for name in ["super", "meta", "command", "Command", "cmd"] { XCTAssertEqual(try Keys.chords(name + "+a"), [.init(0, Keys.command)]) }
        XCTAssertEqual(try Keys.chords("a A 1 exclam minus underscore space"), [.init(0, 0), .init(0, Keys.shift), .init(18, 0), .init(18, Keys.shift), .init(27, 0), .init(27, Keys.shift), .init(49, 0)])
    }
    func testChordSequence() throws {
        XCTAssertEqual(try Keys.chords("Down Down Return"), [.init(125, 0), .init(125, 0), .init(36, 0)])
        XCTAssertEqual(try Keys.chords("super+shift+g"), [.init(5, Keys.command | Keys.shift)])
        XCTAssertEqual(try Keys.chords("super+A"), [.init(0, Keys.command | Keys.shift)])
        XCTAssertEqual(try Keys.chords("  Tab   Tab "), [.init(48, 0), .init(48, 0)])
    }
    func testChordErrorsAndLookupBeforeValidation() {
        for (spec, error) in [("NoSuchKey", "No key is called \"NoSuchKey\""), ("super+nope", "No key is called \"nope\""), ("fn", "No key is called \"fn\""), ("Pause", "This key does not exist on a Mac"), ("a+b", "A chord takes only one key that is not a modifier"), ("a+shift", "A chord takes only one key that is not a modifier"), ("shift", "A chord needs one key that is not a modifier"), ("super+shift", "A chord needs one key that is not a modifier"), ("+", "A chord needs one key that is not a modifier"), ("", "A chord needs one key that is not a modifier"), ("Tab nope", "No key is called \"nope\""), ("shift nope", "No key is called \"nope\"")] {
            assertHarnessError(error) { _ = try Keys.chords(spec) }
        }
    }
    func testLenientAliasesAndCase() throws {
        let cases: [(String, Int, Int)] = [("Ctrl+a", 0, Keys.control), ("Control+a", 0, Keys.control), ("Alt+a", 0, Keys.option), ("Option+a", 0, Keys.option), ("opt+a", 0, Keys.option), ("Shift+Tab", 48, Keys.shift), ("CMD+a", 0, Keys.command), ("COMMAND+a", 0, Keys.command), ("Enter", 36, 0), ("ESC", 53, 0), ("Esc", 53, 0), ("PageUp", 116, 0), ("pagedown", 121, 0), ("Del", 117, 0), ("ctrl + a", 0, Keys.control), ("cmd +shift+ z", 6, Keys.command | Keys.shift), ("equal", 24, 0), ("plus", 24, Keys.shift), ("return", 36, 0), ("backspace", 51, 0), ("TAB", 48, 0), ("escape", 53, 0), ("down", 125, 0), ("f5", 96, 0), ("arrowup", 126, 0), ("ArrowDown", 125, 0), ("arrowleft", 123, 0), ("arrowright", 124, 0), ("spacebar", 49, 0), ("a", 0, 0), ("A", 0, Keys.shift)]
        for (spec, code, flags) in cases { XCTAssertEqual(try Keys.chords(spec), [.init(code, flags)], spec) }
    }
    func testStrictMode() {
        for name in ["ESC", "return"] { assertHarnessError("No key is called \"\(name)\"") { _ = try Keys.chords(name, lenient: false) } }
        assertHarnessError("A chord needs one key that is not a modifier") { _ = try Keys.chords("ctrl + a", lenient: false) }
    }
    func testCommonKeyStrings() throws {
        let common = "Return super+shift+g super+a Down Escape super+t BackSpace super+Left Tab super+k super+l alt+shift+Tab super+comma r super+Down super+o Right super+p space super+space super+shift+n alt+Tab Home Left super+f super+shift+p super+z super+w super+r"
        for spec in common.split(separator: " ") {
            let names = spec.split(separator: "+").map(String.init)
            let code = Keys.table[names.last!]!.code!
            let flags = names.reduce(0) { $0 | Keys.table[$1]!.flags }
            XCTAssertEqual(try Keys.chords(String(spec)), [.init(code, flags)], String(spec))
        }
    }
    func testClickModifiersOnly() throws {
        XCTAssertEqual(try Keys.modifiers("shift"), Keys.shift)
        XCTAssertEqual(try Keys.modifiers("cmd+Shift"), Keys.command | Keys.shift)
        XCTAssertEqual(try Keys.modifiers("ctrl+ctrl"), Keys.control)
        for spec in ["a", "", "Pause"] { assertHarnessError("A click takes one chord of keys, not a sequence") { _ = try Keys.modifiers(spec) } }
    }
    private func us(_ code: Int, _ mods: Int) -> String? {
        ["0,0": "a", "5,0": "a", "0,512": "A", "18,0": "1", "18,512": "!", "36,0": "\r", "48,0": "\t", "49,0": " ", "19,2560": "€", "14,2048": "´", "0,4096": "\u{1}"]["\(code),\(mods)"]
    }
    func testLayoutSearch() throws {
        XCTAssertEqual(try Keys.presses("aA1!€", layout: us), [.init(0, 0, "a"), .init(0, Keys.shift, "A"), .init(18, 0, "1"), .init(18, Keys.shift, "!"), .init(19, Keys.shift | Keys.option, "€")])
    }
    func testLayoutSearchOrder() throws {
        var asked: [String] = []
        _ = try Keys.presses("x", layout: { asked.append("\($0),\($1)"); return nil })
        XCTAssertEqual(asked, [0, 512, 2048, 2560, 4096, 4608, 6144, 6656].flatMap { mods in (0..<128).map { "\($0),\(mods)" } })
    }
    func testNewlinesAndTabs() throws {
        for text in ["\n", "\r\n"] { XCTAssertEqual(try Keys.presses(text, layout: us), [.init(36, 0, "\r")]) }
        XCTAssertEqual(try Keys.presses("\t", layout: us), [.init(48, 0, "\t")])
    }
    func testMissingKeyboardLayoutHasItsOwnError() {
        assertHarnessError("The current keyboard layout could not be read.") { _ = try Keys.layoutTranslator(data: nil, keyboard: 0) }
    }
    func testDirectUnicodeAndUnmatchedSwitch() throws {
        XCTAssertEqual(try Keys.presses("aé✓😀", layout: us), ["a", "é", "✓", "😀"].map { .init(0, 0, $0) })
        XCTAssertEqual(try Keys.presses("aé", layout: us, typeUnmatched: false), [.init(0, 0, "a")])
        XCTAssertEqual(try Keys.presses("e\u{301}", layout: { _, _ in nil }).count, 2)
    }
}
