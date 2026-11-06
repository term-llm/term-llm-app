import XCTest
@testable import TermLLMMacKit

final class ServiceContractTests: XCTestCase {
    func testDecodesReadyStatus() throws {
        let report = try JSONDecoder().decode(ServiceStatusReport.self,
                                              from: Data(ServiceFixtures.readyJSON.utf8))
        XCTAssertEqual(report.schemaVersion, 1)
        XCTAssertEqual(report.uid, 501)
        XCTAssertEqual(report.platform, "darwin")
        let service = try XCTUnwrap(report.service("web"))
        XCTAssertEqual(service.state, .ready)
        XCTAssertTrue(service.running)
        XCTAssertEqual(service.pid, 1234)
        XCTAssertTrue(service.autostart)
        XCTAssertEqual(service.port, 8765)
        XCTAssertEqual(service.basePath, "/ui")
        XCTAssertEqual(service.auth, "bearer")
        XCTAssertEqual(service.enrollment, .notRequired)
        let endpoint = try ManagedLoopbackEndpoint.make(from: service).get()
        XCTAssertEqual(endpoint.baseURL.absoluteString, "http://127.0.0.1:8765/ui/")
        XCTAssertTrue(endpoint.allows(try XCTUnwrap(URL(string: "http://127.0.0.1:8765/ui/chat"))))
    }

    func testDecodesStoppedPasskeyService() throws {
        let report = try JSONDecoder().decode(ServiceStatusReport.self,
                                              from: Data(ServiceFixtures.stoppedJSON.utf8))
        let service = try XCTUnwrap(report.service("web"))
        XCTAssertEqual(service.state, .stopped)
        XCTAssertEqual(service.enrollment, .pending)
        XCTAssertNil(service.pid)
        let endpoint = try ManagedLoopbackEndpoint.make(from: service).get()
        XCTAssertEqual(endpoint.basePath, "/prefix/")
        XCTAssertTrue(endpoint.allows(try XCTUnwrap(URL(string: "http://localhost:9000/prefix/chat?x=1"))))
    }

    func testRejectsUnsupportedSchemaVersion() throws {
        let runner = FakeCommandRunner()
        runner.enqueue(CommandResult(status: 0,
                                     stdout: #"{"schema_version": 2, "services": []}"#,
                                     stderr: ""))
        let controller = ServiceController(executable: URL(fileURLWithPath: "/bin/sh"), runner: runner)
        XCTAssertThrowsError(try controller.status()) { error in
            guard case ServiceContractError.unsupportedSchema(2) = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testStatusCommandUsesJSONAndKind() throws {
        let runner = FakeCommandRunner()
        runner.enqueue(CommandResult(status: 0, stdout: ServiceFixtures.readyJSON, stderr: ""))
        let controller = ServiceController(executable: URL(fileURLWithPath: "/bin/sh"), runner: runner)
        _ = try controller.status()
        XCTAssertEqual(runner.calls.first?.arguments, ["service", "status", "web", "--json"])
    }

    func testIndependentLifecycleArguments() throws {
        let runner = FakeCommandRunner()
        let controller = ServiceController(executable: URL(fileURLWithPath: "/bin/sh"), runner: runner)
        _ = try controller.start()
        _ = try controller.stop()
        _ = try controller.restart()
        _ = try controller.setAutostart(true)
        _ = try controller.setAutostart(false)
        _ = try controller.installFresh(authMode: "bearer", port: 9123)
        XCTAssertEqual(runner.calls.map(\.arguments), [
            ["service", "start", "web", "--no-enable"],
            ["service", "stop", "web", "--keep-enabled"],
            ["service", "restart", "web", "--no-enable"],
            ["service", "autostart", "web", "on"],
            ["service", "autostart", "web", "off"],
            ["service", "install", "web", "--yes", "--", "--auth", "bearer", "--port", "9123"],
        ])
    }

    func testTokenExtractionAcceptsDocumentedShapes() {
        XCTAssertEqual(ServiceController.extractToken("token: abc123\n"), "abc123")
        XCTAssertEqual(ServiceController.extractToken("service token web: abc123\n"), "abc123")
        XCTAssertEqual(ServiceController.extractToken("abc123\n"), "abc123")
        XCTAssertEqual(ServiceController.extractToken("  \n token: tok_abcdefghijklmnop \n"), "tok_abcdefghijklmnop")
        XCTAssertEqual(ServiceController.extractToken(""), "")
    }

    func testTokenFailureNeverEchoesStdout() {
        let result = CommandResult(status: 3, stdout: "token: super-secret-value\n", stderr: "")
        let message = ServiceController.tokenFailureMessage(from: result)
        XCTAssertFalse(message.contains("super-secret"))
        XCTAssertTrue(message.contains("exited with status 3"))
    }

    func testTokenFailureUsesStderrWhenPresent() {
        let result = CommandResult(status: 1, stdout: "token: super-secret-value\n",
                                   stderr: "Error: keychain unavailable\n")
        let message = ServiceController.tokenFailureMessage(from: result)
        XCTAssertEqual(message, "Error: keychain unavailable")
        XCTAssertFalse(message.contains("super-secret"))
    }

    func testTokenCommandRejectsShortOutput() throws {
        let runner = FakeCommandRunner()
        runner.enqueue(CommandResult(status: 0, stdout: "token: short\n", stderr: ""))
        let controller = ServiceController(executable: URL(fileURLWithPath: "/bin/sh"), runner: runner)
        XCTAssertThrowsError(try controller.token())
    }

    func testCommandFailureIsSurfacedWithoutStdoutSecrets() {
        let result = CommandResult(status: 2,
                                   stdout: "token: super-secret-value",
                                   stderr: "Error: service web is not installed\n")
        let message = ServiceController.message(from: result)
        XCTAssertEqual(message, "Error: service web is not installed")
        XCTAssertFalse(message.contains("super-secret"))
    }
}
