import ComputerUseCore
import XCTest
@testable import ComputerUseSystem

private final class FakePermissionMac {
    var granted = Dictionary(uniqueKeysWithValues: Permissions.Kind.allCases.map { ($0, true) })
    var checks: [Permissions.Kind] = [], requests: [Permissions.Kind] = [], opened: [URL] = []
    var settingsRunning = false, settingsLaunches = true, toolCanCapture = false
    var now = 1000.0, toolChecks = 0
    var after: ((FakePermissionMac) -> Void)?
    lazy var permissions: Permissions = {
        var calls = Permissions.Calls()
        calls.granted = { self.checks.append($0); return self.granted[$0]! }
        calls.request = { self.requests.append($0) }
        calls.open = { self.opened.append($0); self.settingsRunning = self.settingsLaunches }
        calls.settingsOpen = { self.settingsRunning }
        calls.canCapture = { self.toolChecks += 1; return self.toolCanCapture }
        calls.time = { self.now }; calls.monotonic = { self.now }
        calls.sleep = { self.now += $0; self.after?(self) }
        return Permissions(calls: calls)
    }()
    func gate() throws { try permissions.gate(deadline: now + 120) }
}
final class PermissionsTests: XCTestCase {
    func testEverythingGrantedCheckedOnlyOnceAndNeverPrompted() throws {
        let mac = FakePermissionMac()
        try mac.gate(); try mac.gate()
        XCTAssertEqual(mac.checks, [.accessibility, .screenRecording]); XCTAssertEqual(mac.now, 1000)
        XCTAssertTrue(mac.requests.isEmpty); XCTAssertTrue(mac.opened.isEmpty)
    }
    func testAbandonedClientStopsWaiting() {
        let mac = FakePermissionMac(); mac.granted[.accessibility] = false
        assertHarnessError(name: "request_timed_out") { try mac.permissions.gate(deadline: 1120, abandoned: { mac.now >= 1002 }) }
        XCTAssertEqual(mac.now, 1002, accuracy: 0.25)
    }
    func testPendingShowsOnlyOnceAndNamesThisHelper() {
        let mac = FakePermissionMac(); mac.granted[.accessibility] = false
        let expected = "The user is still allowing \(product) under Accessibility in System Settings. Call this tool again now, and do not end your turn."
        assertHarnessError(expected, name: "permissions_waiting") { try mac.gate() }
        XCTAssertEqual(mac.now, 1110, accuracy: 0.25); XCTAssertEqual(mac.requests, [.accessibility]); XCTAssertEqual(mac.opened, [Permissions.url(.accessibility)])
    }
    func testGrantWhileWaitingWorks() throws {
        let mac = FakePermissionMac(); mac.granted[.screenRecording] = false
        mac.after = { if $0.now >= 1003 { $0.granted[.screenRecording] = true } }
        try mac.gate(); XCTAssertEqual(mac.now, 1003, accuracy: 0.25)
    }
    func testClosedSettingsMeansNotGranted() {
        let mac = FakePermissionMac(); mac.granted[.accessibility] = false
        mac.after = { if $0.now >= 1002 { $0.settingsRunning = false } }
        let expected = "\(product) cannot work without Accessibility. Ask the user to allow \(product) under Accessibility in System Settings; the Computer Use item of the term-llm menu shows what is missing."
        assertHarnessError(expected, name: "permissions_missing") { try mac.gate() }
        XCTAssertEqual(mac.now, 1002, accuracy: 0.25)
    }
    func testSettingsNeverLaunchedIsNotRefusal() {
        let mac = FakePermissionMac(); mac.granted[.accessibility] = false; mac.settingsLaunches = false
        assertHarnessError(name: "permissions_waiting") { try mac.gate() }
    }
    func testEachSettingsPaneAndGrantOrder() {
        let mac = FakePermissionMac(); mac.granted[.accessibility] = false; mac.granted[.screenRecording] = false
        mac.after = { if $0.now >= 1002 { $0.granted[.accessibility] = true } }
        assertHarnessError("under Screen Recording in System Settings. Call this tool again now, and do not end your turn.") { try mac.gate() }
        XCTAssertEqual(mac.requests, [.accessibility, .screenRecording])
        XCTAssertEqual(mac.opened, [Permissions.url(.accessibility), Permissions.url(.screenRecording)])
        let panes = ["Privacy_Accessibility", "Privacy_ScreenCapture", "Privacy_Accessibility", "Privacy_ListenEvent"]
        for (kind, pane) in zip(Permissions.Kind.allCases, panes) { XCTAssertEqual(Permissions.url(kind).absoluteString, Permissions.settingsURL + pane) }
        mac.permissions.openSettings(.inputMonitoring)
        XCTAssertEqual(mac.requests.last, .inputMonitoring); XCTAssertEqual(mac.opened.last, Permissions.url(.inputMonitoring))
    }
    func testSeenGrantIsNotReasked() throws {
        let mac = FakePermissionMac(); try mac.gate()
        mac.granted[.accessibility] = false; mac.granted[.screenRecording] = false
        try mac.gate(); XCTAssertTrue(mac.opened.isEmpty)
    }
    func testFreshCaptureToolGrantCountsImmediately() throws {
        let mac = FakePermissionMac(); mac.granted[.screenRecording] = false
        XCTAssertEqual(mac.permissions.status()["screen_recording"], false)
        mac.toolCanCapture = true; mac.now += 1
        XCTAssertEqual(mac.permissions.status()["screen_recording"], true)
        try mac.gate(); XCTAssertTrue(mac.opened.isEmpty)
    }
    func testToolIsAskedAtMostOncePerSecond() {
        let mac = FakePermissionMac(); mac.toolCanCapture = true
        XCTAssertTrue(mac.permissions.toolCanCapture()); mac.now += 0.5
        XCTAssertTrue(mac.permissions.toolCanCapture()); XCTAssertEqual(mac.toolChecks, 1)
        mac.now += 0.5; XCTAssertTrue(mac.permissions.toolCanCapture()); XCTAssertEqual(mac.toolChecks, 2)
    }
    func testStatusHasFourFlagsAndTwoRequiredGrants() {
        let mac = FakePermissionMac(); mac.granted[.screenRecording] = false; mac.granted[.inputMonitoring] = false
        XCTAssertEqual(mac.permissions.status(), ["accessibility": true, "screen_recording": false, "post_events": true, "input_monitoring": false])
        XCTAssertEqual(Permissions.required, [.accessibility, .screenRecording])
        XCTAssertTrue(mac.requests.isEmpty); XCTAssertTrue(mac.opened.isEmpty)
    }
    func testDiagnosticsNamesHelperAndMissingGrantsWithoutPrompting() {
        let mac = FakePermissionMac(); mac.granted[.screenRecording] = false; mac.granted[.inputMonitoring] = false
        let diagnostics = mac.permissions.diagnostics()
        XCTAssertEqual(diagnostics["ready"] as? Bool, false); XCTAssertEqual(diagnostics["app"] as? String, product)
        XCTAssertEqual(diagnostics["missing"] as? [String: [String: String]], ["screen_recording": ["why": "\(product) reads screenshots to find where to click", "settings": Permissions.url(.screenRecording).absoluteString], "input_monitoring": ["why": "Lets \(product) notice when you use an app yourself, and step back", "settings": Permissions.url(.inputMonitoring).absoluteString]])
        mac.granted[.screenRecording] = true
        XCTAssertEqual(mac.permissions.diagnostics()["ready"] as? Bool, true)
        XCTAssertTrue(mac.requests.isEmpty); XCTAssertTrue(mac.opened.isEmpty)
        XCTAssertEqual(Permissions.responsibleApp(), product)
        XCTAssertEqual(Permissions.Kind.accessibility.why, "Allows \(product) to read and operate app interfaces")
        XCTAssertEqual(Permissions.poll, 0.25); XCTAssertEqual(Permissions.giveUp, 10)
    }
    func testRequestWithoutOpeningSettings() {
        let mac = FakePermissionMac(); mac.permissions.request(.postEvents)
        XCTAssertEqual(mac.requests, [.postEvents]); XCTAssertTrue(mac.opened.isEmpty)
    }
    func testMissingGrantNamesMatchSystemSettings() {
        XCTAssertEqual(Permissions.names([.accessibility, .screenRecording]), "Accessibility and Screen Recording")
        XCTAssertEqual(Permissions.names([.postEvents, .inputMonitoring]), "Post Events and Input Monitoring")
    }
}
