import Foundation
import Network
import WebKit
import XCTest
@testable import TermLLM

final class LinkedDevicesDiagnosticsTests: XCTestCase {
    func testDefaultOffCreatesNoRecorderOrEmissionPath() async throws {
        let suite = "LinkedDevicesDiagnosticsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(defaults.bool(forKey: LinkedDevicesDiagnostics.defaultsKey))
        let diagnostics = LinkedDevicesDiagnostics.configured(defaults: defaults)
        XCTAssertNil(diagnostics)

        let channel = ControlledRuntimeTestChannel()
        let multiplexer = PeerHTTPMultiplexer(channel: channel, diagnostics: diagnostics?.connection())
        var header = PeerHeader()
        header.set("X-Secret", "HEADER-SECRET")
        let request = PeerHTTPRequest(method: "GET", path: "/RAW-ID?token=QUERY-SECRET",
                                      header: header, body: Data("BODY-SECRET".utf8))
        let task = Task { try await multiplexer.forward(request) }
        await channel.waitForSentFrames(1)
        let id = try XCTUnwrap(channel.sentFrames.first?.id)
        try channel.deliver(PeerFrame(type: .responseStart, id: id, status: 200))
        try channel.deliver(PeerFrame(type: .responseEnd, id: id))
        _ = try await task.value
        multiplexer.close()
    }

    func testClosedRecordsClampValuesAndEmitTerminalExactlyOnce() {
        let clock = DiagnosticTestClock()
        let collector = DiagnosticTestCollector()
let diagnostics = LinkedDevicesDiagnostics(clock: { clock.now() }, sink: { collector.append($0) })
        let connection = diagnostics.connection()
        connection.emit(.requestStarted(request: 7, method: .other, route: .other))
        clock.advance(milliseconds: 12)
        connection.emit(.responseHeaders(request: 7, status: 42))
        clock.advance(milliseconds: 3)
        connection.emit(.requestTerminal(request: 7, outcome: .failed,
                                         reason: .channelClosed, bytes: Int.max))
        connection.emit(.requestTerminal(request: 7, outcome: .finished,
                                         reason: .completed, bytes: 1))

        let records = collector.records
        XCTAssertEqual(records.map(\.stage), [.requestStarted, .responseHeaders, .requestTerminal])
        guard records.count == 3 else { return XCTFail("unexpected diagnostic record count") }
        XCTAssertNil(records[1].status)
        XCTAssertEqual(records[2].durationMilliseconds, 15)
        XCTAssertEqual(records[2].bytes, 1_073_741_824)
        XCTAssertEqual(records[2].outcome, .failed)
        XCTAssertEqual(records[2].reason, .channelClosed)
        XCTAssertEqual(LinkedDevicesDiagnosticEvent.CandidateType("192.0.2.1"), .unknown)
        XCTAssertEqual(LinkedDevicesDiagnosticEvent.Method("SECRET-METHOD"), .other)
        clock.set(0)
        connection.emit(.recoveryAttempt)
        XCTAssertEqual(collector.records.last?.elapsedMilliseconds, 0)
    }

    func testRetiredConnectionsCannotAttributeOldCompletionToNewGeneration() {
        let clock = DiagnosticTestClock()
        let collector = DiagnosticTestCollector()
        let diagnostics = LinkedDevicesDiagnostics(clock: { clock.now() }, sink: { collector.append($0) })
        let old = diagnostics.connection()
        let replacement = diagnostics.connection()
        old.emit(.requestStarted(request: 1, method: .get, route: .sessions))
        replacement.emit(.requestStarted(request: 1, method: .get, route: .sessions))
        replacement.emit(.requestTerminal(request: 1, outcome: .finished, reason: .completed, bytes: 2))
        old.emit(.retired)
        old.emit(.requestTerminal(request: 1, outcome: .truncated, reason: .channelClosed, bytes: 1))
        old.emit(.requestTerminal(request: 1, outcome: .finished, reason: .completed, bytes: 99))

        let terminals = collector.records.filter { $0.stage == .requestTerminal }
        XCTAssertEqual(terminals.count, 2)
        XCTAssertEqual(terminals.map(\.connection), [replacement.sequence, old.sequence])
        XCTAssertEqual(terminals.map(\.outcome), [.finished, .truncated])
        XCTAssertEqual(collector.records.filter { $0.stage == .retired }.map(\.connection), [old.sequence])
    }
}
