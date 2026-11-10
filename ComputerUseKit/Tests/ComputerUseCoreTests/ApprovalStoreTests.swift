import XCTest

@testable import ComputerUseCore

final class ApprovalStoreTests: XCTestCase {
    var folder: URL!, store: ApprovalStore!
    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = ApprovalStore(directory: folder)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: folder) }
    func testFileFormatPermissionsAndAtomicReplacement() throws {
        XCTAssertEqual(store.file.lastPathComponent, "approvals.json")
        XCTAssertEqual(store.always(), [:])
        try store.save(bundleID: "com.example.App", now: Date(timeIntervalSince1970: 0))
        let dict = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: store.file)) as? [String: Any])
        XCTAssertEqual(
            dict["always"] as? [String: String], ["com.example.App": "1970-01-01T00:00:00Z"])
        XCTAssertEqual(dict["modified"] as? String, "1970-01-01T00:00:00Z")
        try store.save(bundleID: "second")
        XCTAssertEqual(store.always().count, 2)
        let mode =
            try FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions]
            as! NSNumber
        XCTAssertEqual(mode.intValue, 0o600)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: folder.path), ["approvals.json"])
    }
    func testBrokenAndOldFilesAreEmptyAndExternalRemovalIsObserved() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for text in [
            "invalid", "[]", "{}", "{\"always\": [\"old\"]}", "{\"always\": {\"test\":true}}",
        ] {
            try text.write(to: store.file, atomically: true, encoding: .utf8)
            XCTAssertEqual(store.always(), [:])
        }
        try store.save(bundleID: "app")
        XCTAssertNotNil(store.always()["app"])
        try "{\"always\":{}}".write(to: store.file, atomically: true, encoding: .utf8)
        XCTAssertEqual(store.always(), [:])
    }
    func testPIDNeverStoredAlways() throws {
        try store.save(bundleID: "#pid:42")
        XCTAssertEqual(store.always(), [:])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.file.path))
    }
    func testSessionPersistenceFiltersDeadProcesses() throws {
        try store.saveSession(agent: "42:123", bundleID: "one", alive: { _ in true })
        try store.saveSession(agent: "named", bundleID: "two", alive: { _ in true })
        XCTAssertEqual(
            store.sessions(alive: { $0 == "named" }), [.init(agent: "named", bundleID: "two")])
        let mode =
            try FileManager.default.attributesOfItem(atPath: store.sessionsFile.path)[
                .posixPermissions]
            as! NSNumber
        XCTAssertEqual(mode.intValue, 0o600)
        try "[[\"bad\"],[\"named\",\"three\"]]".write(
            to: store.sessionsFile, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            store.sessions(alive: { _ in true }), [.init(agent: "named", bundleID: "three")])
    }
    func testAtomicWriteDoesNotFollowDestinationSymlink() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let victim = folder.appendingPathComponent("victim")
        try Data("untouched".utf8).write(to: victim)
        try FileManager.default.createSymbolicLink(at: store.file, withDestinationURL: victim)
        try store.save(bundleID: "app")
        XCTAssertEqual(try String(contentsOf: victim), "untouched")
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: store.file.path)[.type]
                as? FileAttributeType, .typeRegular)
    }
}
