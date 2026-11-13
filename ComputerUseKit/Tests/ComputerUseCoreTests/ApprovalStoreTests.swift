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
    func testRemoveTakesBackOneApprovalOnly() throws {
        try store.remove(bundleID: "absent")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.file.path))
        try store.save(bundleID: "com.example.A")
        try store.save(bundleID: "com.example.B")
        try store.remove(bundleID: "com.example.A")
        XCTAssertEqual(Array(store.always().keys), ["com.example.B"])
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
    // One writer deliberately: Sendable does not promise transactional merging
    // of concurrent read/modify/write operations, in this process or another.
    func testSharedStoreSingleWriterPublishesCompleteFilesToConcurrentReaders() throws {
        let store = store!
        try store.save(bundleID: "app")
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do {
                for index in 0..<40 {
                    try store.save(bundleID: "app", now: Date(timeIntervalSince1970: Double(index)))
                }
            } catch { XCTFail("Private store write failed: \(error)") }
        }
        for _ in 0..<4 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                for _ in 0..<80 {
                    XCTAssertEqual(Set(store.always().keys), ["app"])
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(store.always(), ["app": "1970-01-01T00:00:39Z"])
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions]
                as? NSNumber, NSNumber(value: 0o600))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["approvals.json"])
    }
    func testSessionLivenessCallbackCanReenterImmutableStore() throws {
        let store = store!
        try store.save(bundleID: "app")
        try store.saveSession(agent: "named", bundleID: "app", alive: { _ in true })
        try store.saveSession(agent: "second", bundleID: "app", alive: { _ in
            XCTAssertNotNil(store.always()["app"])
            return true
        })
        XCTAssertEqual(store.sessions(alive: { _ in true }), [
            .init(agent: "named", bundleID: "app"), .init(agent: "second", bundleID: "app"),
        ])
    }

}
