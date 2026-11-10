import ComputerUseCore
import CryptoKit
import XCTest
@testable import ComputerUseSystem

final class InstructionsTests: XCTestCase {
    var folder: URL!, notes: Instructions!
    let slack = "com.tinyspeck.slackmacgap"
    override func setUpWithError() throws {
        folder = try temporaryFolder(); notes = Instructions(stateDirectory: { self.folder })
        try FileManager.default.createDirectory(at: notes.personalDirectory(), withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }
    func put(_ name: String, _ text: String) throws { try text.write(to: notes.personalDirectory().appendingPathComponent(name + ".md"), atomically: true, encoding: .utf8) }
    func testPrefixOncePerAgentCaseInsensitive() {
        let one = AgentSession(key: "one"), two = AgentSession(key: "two")
        let block = notes.prefix(agent: one, bundleID: slack)
        XCTAssertTrue(block!.hasPrefix("<app_notes>\n## Slack\n")); XCTAssertTrue(block!.hasSuffix("\n</app_notes>\n"))
        XCTAssertNil(notes.prefix(agent: one, bundleID: slack.uppercased())); XCTAssertEqual(notes.prefix(agent: two, bundleID: slack), block)
        XCTAssertTrue(notes.prefix(agent: one, bundleID: "com.spotify.client")!.contains("## Spotify"))
    }
    func testNumbersNeverPrintedEvenPersonalAndUnknownNotMarked() throws {
        let a = AgentSession(key: "one"); XCTAssertNotNil(notes.note("com.apple.iWork.Numbers"))
        try put("com.apple.iWork.Numbers", "mine"); XCTAssertNil(notes.prefix(agent: a, bundleID: "com.apple.iWork.Numbers"))
        XCTAssertNil(notes.prefix(agent: a, bundleID: "com.apple.finder")); XCTAssertTrue(a.instructed.isEmpty)
    }
    func testAllBrowserPrefixesAndBuildsButNotMail() {
        for id in Instructions.browsers + ["com.google.Chrome.canary", "com.google.chrome.for.testing", "com.apple.SafariTechnologyPreview"] {
            XCTAssertTrue(notes.note(id)!.hasPrefix("## Browser use"), id)
        }
        for id in ["org.mozilla.thunderbird", "com.apple.mail"] { XCTAssertNil(notes.note(id)) }
    }
    func testPersonalReplacementAndNewApp() throws {
        try put(slack, "Never post in #general.\n")
        XCTAssertEqual(notes.prefix(agent: AgentSession(key: "one"), bundleID: slack), "<app_notes>\nNever post in #general.\n</app_notes>\n")
        try put("com.apple.finder", "Use list view."); XCTAssertEqual(notes.note("com.apple.Finder"), "Use list view.")
        XCTAssertEqual(notes.personalDirectory(), folder.appendingPathComponent("instructions"))
    }
    func testPersonalBrowserGeneralAndSpecificPrecedence() throws {
        try put("browser", "all browsers"); try put("com.google.Chrome", "only this one")
        XCTAssertEqual(notes.note("com.google.Chrome"), "only this one"); XCTAssertEqual(notes.note("com.apple.Safari"), "all browsers")
    }
    func testEmptyUnreadableOrInvalidPersonalNoteSuppressesBuiltIn() throws {
        try put(slack, "\n"); XCTAssertNil(notes.note(slack))
        let file = notes.personalDirectory().appendingPathComponent(slack + ".md")
        try Data([0xff, 0xfe]).write(to: file); XCTAssertNil(notes.note(slack))
        try FileManager.default.removeItem(at: file); try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertNil(notes.note(slack))
    }
    func testMissingFolderFallsBack() throws {
        try FileManager.default.removeItem(at: notes.personalDirectory()); XCTAssertTrue(notes.note(slack)!.hasPrefix("## Slack"))
    }
    func testEightEmbeddedTextsMatchUpstreamExactlyAfterTrimming() {
        // SHA-256 of the pinned 43d9edf UTF-8 texts after Python str.strip().
        let expected = [
            "browser": "8489763fdeee1857ca3abedc0c472a8c9c8074874d68a6f4aa1357602706c9b4",
            "com.apple.music": "c5beb6c247a7e204edf39f028448202c7f79d836a9d378a3da0ae0d87a1ed1a1",
            "com.apple.screencontinuity": "ab14320e307fec31bb2d2b4a41c73ec8f636f899e1aa1717a34b5988e8295980",
            "com.apple.clock": "0b95e9734b13ddac6daec32c288888ced8f24c11cae7f1a919c7ddd11bee5e69",
            "com.apple.iwork.numbers": "359f635c3dee40bc6245f601668ed91123f94c195369cbdec6f11c52da9738af",
            "com.spotify.client": "833b1633050667f0b6f865792dd3f38c9b7e0ba204291e956622e1b1215bc425",
            "com.tinyspeck.slackmacgap": "360f6329d0f78f7cf5bc755be6d3cdce999390e1d49698933b59708be2cc691d",
            "notion.id": "315884acf24eafbb5b4427709fd1c08364fe550a12ed417cb39080d6c6f3dd27",
        ]
        XCTAssertEqual(Set(Instructions.builtIn.keys), Set(expected.keys))
        for (key, hash) in expected {
            let text = Instructions.builtIn[key]!
            XCTAssertTrue(text.hasPrefix("## ")); XCTAssertFalse(text.hasSuffix("\n"))
            XCTAssertEqual(SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined(), hash, key)
            XCTAssertFalse(text.contains("get-app-state")); XCTAssertFalse(text.contains("--click-count"))
        }
    }
}
