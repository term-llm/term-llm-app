import Foundation
import XCTest
@testable import TermLLM

final class FlightRecorderTests: XCTestCase {
    private final class Clock {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_800_000_000)
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ seconds: TimeInterval) { lock.lock(); value.addTimeInterval(seconds); lock.unlock() }
    }

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("flight-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func entries(_ report: String) throws -> [FlightRecord] {
        let start = try XCTUnwrap(report.range(of: "\n{"))
        let data = Data(report[report.index(after: start.lowerBound)...].utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        struct Snapshot: Decodable { let version: Int; let events: [FlightRecord] }
        let snapshot = try decoder.decode(Snapshot.self, from: data)
        XCTAssertEqual(snapshot.version, 1)
        return snapshot.events
    }

    func testPersistenceAcrossRecorderRelaunchPreservesRunAndChangesNewRun() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = Clock()
        let first = FlightRecorder(directory: root, clock: clock.now)
        first.record(event: .launch)
        let firstReport = await first.report()
        let previous = try XCTUnwrap(entries(firstReport).first)
        let second = FlightRecorder(directory: root, clock: clock.now)
        second.record(event: .active)
        let report = await second.report()
        let events = try entries(report)
        XCTAssertEqual(events.map(\.event), [.launch, .active])
        XCTAssertEqual(events[0].runID, previous.runID)
        XCTAssertNotEqual(events[0].runID, events[1].runID)
        XCTAssertTrue(report.contains("Persistence available."))
    }

    func testAdmissionIsBoundedAndInitializationAndRecordingDoNoCallerDiskIO() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = DispatchQueue(label: "flight-tests-controlled-storage")
        storage.suspend()
        var limits = FlightRecorder.Limits()
        limits.maximumPending = 2
        let recorder = FlightRecorder(directory: root, limits: limits, storageQueue: storage)
        for _ in 0..<100 { recorder.record(event: .active) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "All directory creation/loading/writes must wait for storage queue")
        storage.resume()
        let report = await recorder.report()
        XCTAssertEqual(try entries(report).count, 2)
        XCTAssertTrue(report.contains("Dropped on admission this run: 98"))
    }

    func testEventAndByteCapsAlsoApplyToFileAndRelaunch() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = Clock()
        var limits = FlightRecorder.Limits()
        limits.maximumEvents = 3
        limits.maximumBytes = 1024
        let recorder = FlightRecorder(directory: root, limits: limits, clock: clock.now)
        for _ in 0..<20 {
            recorder.record(event: .bridgeStarted, browserID: UUID(), documentID: UUID(), operationID: UUID(), bridge: .deviceTools)
        }
        let report = await recorder.report()
        XCTAssertLessThanOrEqual(try entries(report).count, 3)
        XCTAssertFalse(try entries(report).isEmpty)
        let file = root.appendingPathComponent("flight-recorder.json")
        XCTAssertLessThanOrEqual(try Data(contentsOf: file).count, 1024)
        let relaunched = FlightRecorder(directory: root, limits: limits, clock: clock.now)
        let next = await relaunched.report()
        XCTAssertLessThanOrEqual(try entries(next).count, 3)
        XCTAssertLessThanOrEqual(try Data(contentsOf: file).count, 1024)
    }

    func testAgeRetentionAndExportExpirationUseSimulatedClock() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = Clock()
        var limits = FlightRecorder.Limits()
        limits.maximumAge = 10
        let recorder = FlightRecorder(directory: root, limits: limits, clock: clock.now)
        recorder.record(event: .launch)
        let exported = await recorder.export()
        let url = try XCTUnwrap(exported)
        clock.advance(11)
        recorder.record(event: .active)
        let report = await recorder.report()
        XCTAssertEqual(try entries(report).map(\.event), [.active])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        clock.advance(11)
        let relaunched = FlightRecorder(directory: root, limits: limits, clock: clock.now)
        let empty = await relaunched.report()
        XCTAssertTrue(try entries(empty).isEmpty)
    }

    func testBackwardWallClockDoesNotRetainFarFutureRecords() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = Clock()
        let recorder = FlightRecorder(directory: root, clock: clock.now)
        recorder.record(event: .launch)
        _ = await recorder.report()
        clock.advance(-3600)
        recorder.record(event: .active)
        let report = await recorder.report()
        XCTAssertEqual(try entries(report).map(\.event), [.active])
    }

    func testDurationSanitizationAndBridgePairStructure() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = FlightRecorder(directory: root)
        let browser = UUID(), document = UUID()
        let call = BridgeFlightCall(bridge: .deviceTools, context: (browser, document), recorder: recorder)
        call.finish(succeeded: false)
        recorder.record(event: .nativeRecovered, duration: Double.nan)
        recorder.record(event: .nativeRecovered, duration: -Double.infinity)
        recorder.record(event: .nativeRecovered, duration: -1)
        recorder.record(event: .nativeRecovered, duration: 1_000_000)
        let report = await recorder.report()
        let events = try entries(report)
        XCTAssertEqual(events[0].event, .bridgeStarted)
        XCTAssertEqual(events[1].event, .bridgeFailed)
        XCTAssertEqual(events[0].operationID, events[1].operationID)
        XCTAssertNotNil(events[0].operationID)
        XCTAssertEqual(events[0].browserID, browser)
        XCTAssertEqual(events[1].documentID, document)
        XCTAssertEqual(events[1].bridge, .deviceTools)
        XCTAssertNotNil(events[1].duration)
        XCTAssertTrue(events[2...4].allSatisfy { $0.duration == nil })
        XCTAssertEqual(events[5].duration, 86400)
    }

    func testExportIsBoundedReplaceableAndDropsUnknownStringPayloadsOnReload() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = FlightRecorder(directory: root)
        recorder.record(event: .launch)
        _ = await recorder.report()
        let file = root.appendingPathComponent("flight-recorder.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let secret = "SECRET_CHAT_AUDIO_COOKIE_TOKEN_URL_TOOL_ARGS_RAW_ERROR"
        object["chat"] = secret
        var events = try XCTUnwrap(object["events"] as? [[String: Any]])
        events[0]["url"] = "https://private.example/path?token=\(secret)"
        events[0]["error"] = secret
        object["events"] = events
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        let relaunched = FlightRecorder(directory: root)
        let report = await relaunched.report()
        XCTAssertFalse(report.contains(secret))
        XCTAssertFalse(report.contains("private.example"))
        let first = await relaunched.export()
        let url = try XCTUnwrap(first)
        let exported = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(exported.contains(secret))
        XCTAssertEqual(try entries(exported).count, 1)
        XCTAssertLessThanOrEqual(exported.utf8.count, FlightRecorder.Limits().maximumBytes + 1024)
        let second = await relaunched.export()
        XCTAssertEqual(first, second, "Do not accumulate export files")
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(Set(files), Set(["flight-recorder.json", "freeze-diagnostics.txt"]))
        let afterRelaunch = FlightRecorder(directory: root)
        _ = await afterRelaunch.report()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "Old exports are not a second persistent archive")
    }

    func testCorruptOversizedAndUnavailableStorageUseOnlyFixedStatusMessages() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("flight-recorder.json")
        try Data("secret raw error with https://private.example".utf8).write(to: file)
        let corrupt = FlightRecorder(directory: root)
        let corruptReport = await corrupt.report()
        XCTAssertTrue(corruptReport.contains("Unreadable history was discarded."))
        XCTAssertFalse(corruptReport.contains("private.example"))
        try Data(repeating: 65, count: 2048).write(to: file)
        var limits = FlightRecorder.Limits()
        limits.maximumBytes = 512
        let oversized = FlightRecorder(directory: root, limits: limits)
        let oversizedReport = await oversized.report()
        XCTAssertTrue(oversizedReport.contains("Oversized history was discarded."))
        XCTAssertLessThanOrEqual(try Data(contentsOf: file).count, 512)
        let blocker = root.appendingPathComponent("secret-token-file-not-directory")
        try Data().write(to: blocker)
        let unavailable = FlightRecorder(directory: blocker)
        unavailable.record(event: .launch)
        let unavailableReport = await unavailable.report()
        XCTAssertTrue(unavailableReport.contains("Persistence unavailable"))
        XCTAssertFalse(unavailableReport.contains(blocker.path))
        XCTAssertEqual(try entries(unavailableReport).count, 1)
        let export = await unavailable.export()
        XCTAssertNil(export)
    }
}
