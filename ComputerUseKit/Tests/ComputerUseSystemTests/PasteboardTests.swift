import AppKit
import ComputerUseCore
import XCTest
import os
@testable import ComputerUseSystem

private typealias Pasteboard = ComputerUseSystem.Pasteboard

// Live-service suite: compile only in the ownership milestone. XCTest enters
// these synchronous lifecycle methods on main; no worker captures the test case.
// Only the actor-owned fixture crosses XCTest's nonisolated lifecycle bridge;
// XCTestCase itself is not Sendable.
@MainActor
private final class LivePasteboardFixture {
    var board: NSPasteboard!
    var folder: URL!
    var pasteboard: Pasteboard!
    nonisolated init() {}
    func setUp() throws {
        folder = try temporaryFolder()
        board = NSPasteboard.withUniqueName() // Never the person's real clipboard.
        let item = NSPasteboardItem()
        item.setString("the person's text", forType: .init(Pasteboard.plain))
        item.setString("<b>the person's text</b>", forType: .init(Pasteboard.html))
        board.clearContents(); XCTAssertTrue(board.writeObjects([item]))
        let backend = Pasteboard.Backend(board: board), state = folder!
        pasteboard = Pasteboard(board: { backend }, stateDirectory: { state })
    }
    func tearDown() throws {
        board.releaseGlobally(); try FileManager.default.removeItem(at: folder)
        board = nil; pasteboard = nil
    }
}

@MainActor
final class PasteboardTests: XCTestCase {
    private nonisolated let fixture = LivePasteboardFixture()
    private var board: NSPasteboard! { fixture.board }
    private var folder: URL! { fixture.folder }
    private var pasteboard: Pasteboard! { fixture.pasteboard }
    nonisolated override func setUpWithError() throws {
        let fixture = fixture
        try MainActor.assumeIsolated { try fixture.setUp() }
    }
    nonisolated override func tearDownWithError() throws {
        let fixture = fixture
        try MainActor.assumeIsolated { try fixture.tearDown() }
    }
    private var path: URL { folder.appendingPathComponent(Pasteboard.restoreFile) }
    private func read(_ kind: String = Pasteboard.plain) -> Data? { board.data(forType: .init(kind)) }
    func testLazyPasteAndRestorationOfEveryRepresentation() throws {
        let before = Pasteboard.snapshot(board)
        var seen: [String] = []
        try pasteboard.paste("typed by the tool", format: "text", sendPasteKey: {
            XCTAssertEqual(board.pasteboardItems?.count, 1)
            seen.append(String(data: read()!, encoding: .utf8)!)
        })
        XCTAssertEqual(seen, ["typed by the tool"]); XCTAssertEqual(Pasteboard.snapshot(board), before)
    }
    func testPastesAreSerializedAcrossInstances() {
        let backend = Pasteboard.Backend(snapshot: { [] }, write: { _ in 1 }, restore: { _, _ in true })
        let counter = PasteConcurrencyCounter(), group = DispatchGroup()
        let state = folder!
        for _ in 0..<4 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                let paste = Pasteboard(board: { backend }, stateDirectory: { state }, wait: { _, _, _ in true })
                do {
                    try paste.paste("x", format: "text", sendPasteKey: {
                        counter.begin(); Thread.sleep(forTimeInterval: 0.01); counter.end()
                    })
                } catch { XCTFail("Concurrent paste failed: \(error)") }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(counter.maximum, 1)
    }
    func testEmptyClipboardStaysEmpty() throws {
        board.clearContents()
        try pasteboard.paste("x", format: "text", sendPasteKey: { _ = read() })
        XCTAssertEqual(Pasteboard.snapshot(board), [])
    }
    func testPersonCopyWinsConflict() {
        assertHarnessError(name: "server_error") {
            try pasteboard.paste("x", format: "text", sendPasteKey: {
                _ = read(); board.clearContents(); board.setString("copied by the person meanwhile", forType: .init(Pasteboard.plain))
            })
        }
        XCTAssertEqual(Pasteboard.snapshot(board), [[Pasteboard.plain: Data("copied by the person meanwhile".utf8)]])
    }
    func testTimeoutRestoresAndRemovesRecoveryFile() {
        let before = Pasteboard.snapshot(board)
        assertHarnessError("The app did not take the text from the clipboard in time") { try pasteboard.paste("x", format: "text", sendPasteKey: {}, timeout: 0.01) }
        XCTAssertEqual(Pasteboard.snapshot(board), before); XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        XCTAssertEqual(Pasteboard.readTimeout, 2)
    }
    func testWriteFailure() {
        let backend = Pasteboard.Backend(snapshot: { [] }, write: { _ in nil }, restore: { _, _ in XCTFail("Never wrote"); return false })
        let state = folder!
        let paste = Pasteboard(board: { backend }, stateDirectory: { state })
        assertHarnessError("The text could not be put on the clipboard") { try paste.paste("x", format: "text", sendPasteKey: { XCTFail("Never wrote") }) }
    }
    func testPromisedProviderIsNotReadOnWrite() {
        let provider = LazyPasteData(payload: [Pasteboard.plain: Data("x".utf8)])
        XCTAssertNotNil(Pasteboard.write(board, provider: provider)); XCTAssertFalse(provider.wasRead)
        XCTAssertEqual(read(), Data("x".utf8)); XCTAssertTrue(provider.wasRead)
        XCTAssertEqual(Pasteboard.currentHostOnly, 1)
    }
    func testWaitForLandingBeforeRestoration() throws {
        var asked: [String] = []
        try pasteboard.paste("x", format: "text", sendPasteKey: { _ = read() }, landed: {
            asked.append(String(data: self.read()!, encoding: .utf8)!); return asked.count == 3
        })
        XCTAssertEqual(asked, ["x", "x", "x"]); XCTAssertEqual(Pasteboard.landTimeout, 2); XCTAssertEqual(Pasteboard.landPoll, 0.025)
    }
    func testLandingTimeoutIsNonfatalAndUsesExactPoll() throws {
        let recorded = OSAllocatedUnfairLock(initialState: [(Double, Double)]())
        let backend = Pasteboard.Backend(board: board), state = folder!
        let paste = Pasteboard(board: { backend }, stateDirectory: { state }, wait: { done, timeout, poll in
            let first = recorded.withLock { $0.append((timeout, poll)); return $0.count == 1 }
            return first ? done() : false
        })
        try paste.paste("x", format: "text", sendPasteKey: { _ = read() }, landed: { false })
        let calls = recorded.withLock { $0 }
        XCTAssertEqual(calls.map { $0.0 }, [2, 2]); XCTAssertEqual(calls.map { $0.1 }, [0.01, 0.025])
    }
    func testRecoveryFileExistsOnlyDuringPasteAndIs0600() throws {
        let saved = Pasteboard.snapshot(board)
        // Even a pre-existing recovery file must be tightened before secrets are written.
        try Data().write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)
        try pasteboard.paste("x", format: "text", sendPasteKey: {
            let left = try PropertyListSerialization.propertyList(from: Data(contentsOf: path), format: nil) as! [String: Any]
            XCTAssertEqual(left["items"] as? Pasteboard.Snapshot, saved); XCTAssertGreaterThan(left["count"] as! Int, 0)
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as! NSNumber).intValue, 0o600)
            _ = read()
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }
    func testCrashRecovery() throws {
        let saved = Pasteboard.snapshot(board)
        board.clearContents(); board.setString("the tool's text, left behind", forType: .init(Pasteboard.plain))
        let data = try PropertyListSerialization.data(fromPropertyList: ["count": board.changeCount, "items": saved], format: .xml, options: 0)
        try data.write(to: path)
        pasteboard.restoreSaved()
        XCTAssertEqual(Pasteboard.snapshot(board), saved); XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }
    func testStaleAndCorruptRecoveryNeverOverwritePerson() throws {
        let before = Pasteboard.snapshot(board)
        let stale = try PropertyListSerialization.data(fromPropertyList: ["count": board.changeCount - 1, "items": [[Pasteboard.plain: Data("old".utf8)]]], format: .xml, options: 0)
        for data in [stale, Data(), Data("not a plist".utf8)] {
            try data.write(to: path); pasteboard.restoreSaved()
            XCTAssertEqual(Pasteboard.snapshot(board), before); XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        }
        pasteboard.restoreSaved()
    }
    func testSendFailureStillRestoresClipboard() {
        let saved = Pasteboard.snapshot(board)
        XCTAssertThrowsError(try pasteboard.paste("x", format: "text", sendPasteKey: { throw WireError.closed }))
        XCTAssertEqual(Pasteboard.snapshot(board), saved); XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }
    func testFileWriteFailureStillRestoresClipboard() throws {
        let saved = Pasteboard.snapshot(board)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: folder.appendingPathComponent("nowhere"))
        XCTAssertThrowsError(try pasteboard.paste("x", format: "text", sendPasteKey: { XCTFail("Never sent") }))
        XCTAssertEqual(Pasteboard.snapshot(board), saved)
    }
    func testRepresentationsAndLazyRichText() throws {
        XCTAssertEqual(try Pasteboard.representations("**b**", format: "text"), [Pasteboard.plain: Data("**b**".utf8)])
        let made = try MainThread.callOnMain { try Pasteboard.representations("# Title\n\nSome **bold** text", format: "md") }
        XCTAssertEqual(Set(made.keys), [Pasteboard.html, Pasteboard.rtf, Pasteboard.plain])
        XCTAssertTrue(String(data: made[Pasteboard.html]!, encoding: .utf8)!.contains("<h1>Title</h1><p>Some <b>bold</b> text</p>"))
        XCTAssertTrue(made[Pasteboard.rtf]!.starts(with: Data("{\\rtf".utf8)))
        XCTAssertEqual(made[Pasteboard.plain], Data("# Title\n\nSome **bold** text".utf8))
        let page = try MainThread.callOnMain { try Pasteboard.representations("<p>café <i>au lait</i></p>", format: "html") }
        XCTAssertEqual(String(data: page[Pasteboard.plain]!, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), "café au lait")
        try pasteboard.paste("*hi*", format: "md", sendPasteKey: {
            for kind in [Pasteboard.html, Pasteboard.rtf, Pasteboard.plain] { XCTAssertNotNil(read(kind)) }
        })
    }
    func testMarkdownHTML() {
        for (source, page) in [("plain", "<p>plain</p>"), ("a\nb", "<p>a<br>b</p>"), ("## Two", "<h2>Two</h2>"), ("- a\n- b", "<ul><li>a</li><li>b</li></ul>"), ("1. a\n2. b", "<ol><li>a</li><li>b</li></ol>"), ("`x < y`", "<p><code>x &lt; y</code></p>"), ("[t](https://example.com)", "<p><a href=\"https://example.com\">t</a></p>"), ("2 * 3 * 4", "<p>2 * 3 * 4</p>")] { XCTAssertEqual(Pasteboard.markdownHTML(source), page) }
    }
}

private final class PasteConcurrencyCounter: Sendable {
    private struct State: Sendable { var active = 0, peak = 0 }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var maximum: Int { state.withLock { $0.peak } }
    func begin() { state.withLock { $0.active += 1; $0.peak = max($0.peak, $0.active) } }
    func end() { state.withLock { $0.active -= 1 } }
}
