import XCTest
@testable import TermLLMMacKit

final class DiagnosticsTests: XCTestCase {
    func testReportRedactsTokenAndHome() {
        let home = URL(fileURLWithPath: "/Users/tester")
        let report = DiagnosticsReport(checks: [
            DiagnosticCheck(id: "service", title: "Service",
                            level: .ok,
                            detail: "running at /Users/tester/Library with token: abcdef1234567890"),
            DiagnosticCheck(id: "cookie", title: "Cookie",
                            level: .info,
                            detail: "term_llm_token=secretvalue; path=/"),
        ])
        let text = report.redactedText(appVersion: "1.0", home: home)
        XCTAssertFalse(text.contains("/Users/tester"))
        XCTAssertFalse(text.contains("abcdef1234567890"))
        XCTAssertFalse(text.contains("secretvalue"))
        XCTAssertTrue(text.contains("~/Library"))
        XCTAssertTrue(text.contains("<redacted>"))
    }

    func testBuilderPrioritisesBrokenState() {
        let selection = CLISelection(source: .bundled,
                                     binaryPath: "/Users/tester/.config/term-llm/app/bin/term-llm",
                                     version: "dev", sha256: "abc",
                                     provenance: "Bundled")
        let status = ServiceStatus(kind: "web", installed: true, managed: true, registered: true,
                                   state: .unhealthy, running: true, autostart: true,
                                   url: "http://127.0.0.1:8765/", host: "127.0.0.1", port: 8765,
                                   basePath: "/", auth: "bearer", enrollment: .notRequired,
                                   healthy: false, healthError: "connection refused")
        let report = CompanionDiagnostics.build(appVersion: "1.0",
                                                selection: selection,
                                                selectionError: nil,
                                                problems: [],
                                                pathLink: .linked("/Users/tester/.local/bin/term-llm"),
                                                status: status,
                                                endpoint: nil,
                                                tokenAvailable: false,
                                                loginItemEnabled: false,
                                                managedMarkerPresent: true)
        XCTAssertTrue(report.hasFailure)
        let service = report.checks.first { $0.id == "service" }
        XCTAssertEqual(service?.level, .failed)
        XCTAssertTrue(service?.detail.contains("connection refused") == true)
        let endpoint = report.checks.first { $0.id == "endpoint" }
        XCTAssertEqual(endpoint?.level, .info)
    }
}
