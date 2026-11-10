import XCTest
@testable import ComputerUseCore

final class ElementsTests: XCTestCase {
    let window = El("AXWindow")
    var ax: FakeAX!
    override func setUp() { super.setUp(); ax = FakeAX([100: El("AXApplication")]); AX.backend = ax }
    func revisions() throws -> Revisions { let r = Revisions(); try r.watch(demoTarget); return r }
    func field(_ el: El = El(), title: String = "Name", value: String = "", role: String = "AXTextField") -> Line {
        testLine(1, "text field \(title)", el, role: role, value: value, match: [role, "", title, "", "", "", "", ""])
    }
    func state(_ lines: Line...) -> Capture { testCapture([testLine(0, "window", window)] + lines) }
    func never() throws -> Capture { XCTFail("tree was read again"); throw Errors.serverError("unexpected reread") }
    func failure(_ body: () throws -> Line, file: StaticString = #filePath, line: UInt = #line) -> HarnessError {
        do { _ = try body(); XCTFail("expected failure", file: file, line: line) } catch let error as HarnessError { return error } catch { XCTFail("unexpected \(error)", file: file, line: line) }
        return Errors.serverError("missing failure")
    }
    func numbers(_ name: String) throws -> [[Int]] {
        let r = Revisions()
        return try chain(name).map { read, full, _ in _ = r.present(read, disableDiff: full); return read.lines.map { $0.id! } }
    }
    func testDepthFirstNumbersAndNothingInheritsBaseOne() throws {
        XCTAssertEqual(try numbers("added-subtree")[0], Array(0..<7))
        let values = try numbers("nothing-inherits")
        XCTAssertEqual(values[0], [0, 1]); XCTAssertEqual(values[1], [1, 2])
        let texts = try replay("nothing-inherits")
        XCTAssertEqual(texts[1].components(separatedBy: "\n")[1], "1 sheet")
        XCTAssertTrue(texts[2].hasSuffix("~\t2 button Saved")); XCTAssertEqual(texts[3].components(separatedBy: "\n")[1], "0 sheet")
    }
    func testKeptElementsRetainNumbersAndDepartedNumbersReusable() throws {
        let reads = try chain("order"), r = Revisions()
        _ = r.present(reads[0].0)
        let before = reads[0].0.lines
        _ = r.present(reads[1].0)
        for old in before { XCTAssertEqual(reads[1].0.lines.first { AX.same($0.element, old.element) }?.id, old.id) }
        let ns = try numbers("number-reuse")
        XCTAssertEqual(ns[0], [0, 1, 2, 3, 4, 5, 6]); XCTAssertEqual(ns[1], [0, 7, 8, 9, 4, 5, 6]); XCTAssertEqual(ns[2], [0, 7, 8, 4, 9, 5, 6])
        XCTAssertEqual(Array(try numbers("added-subtree")[1][3..<7]), [7, 8, 9, 10])
    }
    func testExtraFocusAndSelectionCountAfterTreeAndShareIDs() throws {
        let texts = try replay("focus-outside")
        XCTAssertTrue(texts[0].hasSuffix("is 2 text field Search")); XCTAssertTrue(texts[1].hasSuffix("is 3 text field Search"))
        let button = El(), twice = El(), outside = El(), r = Revisions()
        let lines = [testLine(0, "window"), testLine(1, "button", button)]
        _ = r.present(testCapture(lines))
        let read = testCapture(lines + [testLine(1, "row", twice), testLine(1, "row", twice)], focused: testLine(1, "button", button), selected: [testLine(1, "row", twice), testLine(0, "text", outside)])
        _ = r.present(read)
        XCTAssertEqual(read.lines.map { $0.id! }, [0, 1, 2, 2]); XCTAssertEqual(read.focused?.id, 1)
        XCTAssertEqual(read.selected.map { $0.id! }, [2, 3])
    }
    func testCFEqualNotPointerOrHashIdentity() {
        class OneHash: El { override var hash: Int { 7 } }
        let first = OneHash(), second = OneHash(), r = Revisions()
        _ = r.present(state(testLine(1, "a", first), testLine(1, "b", second)))
        let read = state(testLine(1, "b", second), testLine(1, "c", OneHash()))
        _ = r.present(read); XCTAssertEqual(read.lines.dropFirst().map { $0.id! }, [2, 3])
        class EqualElement: El {
            override var hash: Int { 7 }
            override func isEqual(_ object: Any?) -> Bool { guard let other = object as? EqualElement else { return false }; return attrs as NSDictionary == other.attrs as NSDictionary }
        }
        _ = r.present(state(testLine(1, "b", EqualElement("AXGroup", ["uid": 1]))), disableDiff: true)
        let again = state(testLine(1, "b", EqualElement("AXGroup", ["uid": 1])))
        XCTAssertTrue(r.present(again).hasPrefix("Nothing changed in window"))
    }
    func testStableIDsRequireLongLivedSessionAndIdentifiersAreNotKeys() throws {
        XCTAssertEqual(try numbers("order")[1], [0, 5, 1, 2, 6, 3, 4])
        let read = try chain("order")[1].0; _ = Revisions().present(read)
        XCTAssertEqual(read.lines.map { $0.id! }, Array(0..<7))
        let button = El(), r = Revisions(), text = testLine(1, "text")
        _ = r.present(state(testLine(1, "button OK, ID: ok", button), text))
        XCTAssertTrue(r.present(state(testLine(1, "button OK, ID: confirm", button), text)).hasSuffix("~\t1 button OK, ID: confirm"))
        XCTAssertTrue(r.present(state(testLine(1, "button OK, ID: confirm"), text)).contains("IDs of elements that went away: 1\n+\t3 button"))
    }
    func testAliveStoredElementThenDeadRefetchedAndCached() throws {
        let old = El(), new = El(), r = try revisions()
        _ = r.present(state(field(old)))
        XCTAssertTrue(AX.same(try r.resolve(1, reread: never).element, old.ref))
        old.dead = true
        XCTAssertTrue(AX.same(try r.resolve(1, reread: { self.state(self.field(new)) }).element, new.ref))
        XCTAssertTrue(AX.same(try r.resolve(1, reread: never).element, new.ref))
    }
    func testResolveTreeAndOutOfTreeFocusNumbers() throws {
        let r = try revisions(), read = state(field(), testLine(1, "button"))
        _ = r.present(read)
        XCTAssertTrue(try r.resolve(2, reread: never) === read.lines[2])
        let outside = testLine(1, "text field Search")
        _ = r.present(testCapture(read.lines, focused: outside))
        XCTAssertTrue(try r.resolve(3, reread: never) === outside)
    }
    func testDistinctRefetchFailuresExactText() throws {
        let r = try revisions(), one = El(), two = El(), three = El()
        one.dead = true; two.dead = true; three.dead = true
        _ = r.present(state(field(one), field(two), field(three, title: "Other")))
        let prefix = "term-llm Computer Use error 100: "
        let refetch = "The element went away, and more than one element now fits its description, so looking it up again could not be "
        let retry = "Read the app state again, then retry with the new element IDs."
        XCTAssertEqual(failure { try r.resolve(9999, reread: never) }.message, prefix + "No element has the ID 9999 in the last read. Use an ID from the newest `get_app_state` text.")
        XCTAssertEqual(failure { try r.resolve(1, reread: never) }.message, prefix + refetch + "started. " + retry)
        XCTAssertEqual(failure { try r.resolve(3, reread: { self.state(self.field(), self.field()) }) }.message, prefix + "That element ID is from an older read. " + retry)
        XCTAssertEqual(failure { try r.resolve(3, reread: { self.state(self.field(title: "Other"), self.field(title: "Other")) }) }.message, prefix + refetch + "finished. " + retry)
    }
    func testRefetchIgnoreValueAndMatchRole() throws {
        let r = try revisions(), old = El(), new = El(); old.dead = true
        _ = r.present(state(field(old, value: "draft")))
        let typed = { self.state(self.field(new, value: "draft!")) }
        XCTAssertTrue(failure { try r.resolve(1, reread: typed) }.message.contains("from an older read"))
        XCTAssertTrue(AX.same(try r.resolve(1, reread: typed, ignoreValue: true).element, new.ref))
        _ = r.present(state(field(old)))
        XCTAssertTrue(AX.same(try r.resolve(1, reread: { self.state(self.field(new), self.field(role: "AXComboBox")) }).element, new.ref))
        new.dead = true
        XCTAssertTrue(failure { try r.resolve(1, reread: { self.state(self.field(), self.field()) }) }.message.contains("finished"))
    }
    func testNoInvalidationMonitorAndMachineReadableTags() throws {
        let r = Revisions(); _ = r.present(state(field()))
        XCTAssertEqual(failure { try r.resolve(1, reread: never) }.message, "term-llm Computer Use error 100: Internal error: this app session has no change monitor.")
        XCTAssertTrue(failure { try r.resolve(7, reread: never) }.message.contains("No element has the ID"))
        let watched = try revisions(), a = El(), b = El(); a.dead = true; b.dead = true
        _ = watched.present(state(field(a), field(b)))
        XCTAssertEqual(failure { try watched.resolve(5, reread: never) }.tag, "invalid_element_id")
        XCTAssertEqual(failure { try watched.resolve(1, reread: never) }.tag, "invalid_element_id")
        _ = watched.present(state(field(a)))
        let gone = failure { try watched.resolve(1, reread: { self.state() }) }
        XCTAssertEqual(gone.tag, "invalid_element_id"); XCTAssertEqual(gone.code, 100)
    }
    func testDestroyedNotificationsAndFreshReadClearsMarks() throws {
        let r = try revisions(), old = El(), new = El(), observer = ax.observers[0]
        XCTAssertEqual(observer.names, ["AXUIElementDestroyed"])
        _ = r.present(state(field(old)))
        observer.fire("AXUIElementDestroyed", old)
        XCTAssertTrue(AX.same(try r.resolve(1, reread: { self.state(self.field(new)) }).element, new.ref))
        observer.fire("AXUIElementDestroyed", new)
        _ = r.present(state(field(new)))
        XCTAssertTrue(AX.same(try r.resolve(1, reread: never).element, new.ref))
    }
    func testWatchOnceRelaunchAndResetStopsObservation() throws {
        let r = try revisions(); try r.watch(demoTarget); XCTAssertEqual(ax.observers.count, 1)
        ax.apps[200] = El("AXApplication")
        var relaunched = demoTarget; relaunched.pid = 200
        try r.watch(relaunched)
        XCTAssertEqual(ax.observers.map { $0.stopped }, [true, false])
        _ = r.present(state(field())); r.reset()
        XCTAssertTrue(ax.observers[1].stopped); XCTAssertNil(r.last)
        XCTAssertTrue(failure { try r.resolve(1, reread: never) }.message.contains("No element has the ID"))
    }
    func testAppSessionDefaultsAndMutableState() {
        let agent = AgentSession(key: "test"), session = AppSession(agent: agent, target: demoTarget)
        XCTAssertTrue(session.agent === agent); XCTAssertEqual(session.target, demoTarget)
        XCTAssertNil(session.revisions); XCTAssertNil(session.shot); XCTAssertNil(session.watching)
        XCTAssertFalse(session.cancel()); XCTAssertFalse(session.active); XCTAssertFalse(session.needsSettle); XCTAssertFalse(session.pageUnchecked)
        session.cancel = { true }; XCTAssertTrue(session.cancel())
    }
}
