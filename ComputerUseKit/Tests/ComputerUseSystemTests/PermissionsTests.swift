import ComputerUseCore
import XCTest
import os
@testable import ComputerUseSystem

/// Safe fake for every production hook, including the synchronous main seam.
private final class PermissionFixtureState: Sendable {
    struct State: Sendable {
        var granted = Dictionary(uniqueKeysWithValues: Permissions.Kind.allCases.map { ($0, true) })
        var checks: [Permissions.Kind] = [], requests: [Permissions.Kind] = [], opened: [URL] = []
        var settingsRunning = false, settingsLaunches = true, toolCanCapture = false
        var now = 1000.0, toolChecks = 0
        var after: (@Sendable (PermissionFixtureState) -> Void)?
    }
    let state = OSAllocatedUnfairLock(initialState: State())
    var granted: [Permissions.Kind: Bool] {
        get { state.withLock { $0.granted } }
        set { state.withLock { $0.granted = newValue } }
    }
    var checks: [Permissions.Kind] { state.withLock { $0.checks } }
    var requests: [Permissions.Kind] { state.withLock { $0.requests } }
    var opened: [URL] { state.withLock { $0.opened } }
    var settingsRunning: Bool {
        get { state.withLock { $0.settingsRunning } }
        set { state.withLock { $0.settingsRunning = newValue } }
    }
    var settingsLaunches: Bool {
        get { state.withLock { $0.settingsLaunches } }
        set { state.withLock { $0.settingsLaunches = newValue } }
    }
    var toolCanCapture: Bool {
        get { state.withLock { $0.toolCanCapture } }
        set { state.withLock { $0.toolCanCapture = newValue } }
    }
    var now: Double {
        get { state.withLock { $0.now } }
        set { state.withLock { $0.now = newValue } }
    }
    var toolChecks: Int { state.withLock { $0.toolChecks } }
    var after: (@Sendable (PermissionFixtureState) -> Void)? {
        get { state.withLock { $0.after } }
        set { state.withLock { $0.after = newValue } }
    }
}
private final class FakePermissionMac: Sendable {
    let fixture = PermissionFixtureState()
    let permissions: Permissions
    init() {
        let fixture = fixture
        var calls = permissionCalls()
        calls.granted = { kind in fixture.state.withLock { $0.checks.append(kind); return $0.granted[kind]! } }
        calls.request = { kind in fixture.state.withLock { $0.requests.append(kind) } }
        calls.open = { url in fixture.state.withLock { $0.opened.append(url); $0.settingsRunning = $0.settingsLaunches } }
        calls.settingsOpen = { fixture.settingsRunning }
        calls.canCapture = { fixture.state.withLock { $0.toolChecks += 1; return $0.toolCanCapture } }
        calls.time = { fixture.now }; calls.monotonic = { fixture.now }
        calls.sleep = { duration in
            let after = fixture.state.withLock { $0.now += duration; return $0.after }
            after?(fixture)
        }
        permissions = Permissions(calls: calls)
    }
    var granted: [Permissions.Kind: Bool] {
        get { fixture.granted }
        set { fixture.granted = newValue }
    }
    var checks: [Permissions.Kind] { fixture.checks }
    var requests: [Permissions.Kind] { fixture.requests }
    var opened: [URL] { fixture.opened }
    var settingsRunning: Bool {
        get { fixture.settingsRunning }
        set { fixture.settingsRunning = newValue }
    }
    var settingsLaunches: Bool {
        get { fixture.settingsLaunches }
        set { fixture.settingsLaunches = newValue }
    }
    var toolCanCapture: Bool {
        get { fixture.toolCanCapture }
        set { fixture.toolCanCapture = newValue }
    }
    var now: Double {
        get { fixture.now }
        set { fixture.now = newValue }
    }
    var toolChecks: Int { fixture.toolChecks }
    var after: (@Sendable (PermissionFixtureState) -> Void)? {
        get { fixture.after }
        set { fixture.after = newValue }
    }
    func gate() throws { try permissions.gate(deadline: now + 120) }
}
/// New regressions start with fail-fast fakes: accidental use of any real default
/// (prompt, Settings, capture, clock, sleep or main-loop state) is impossible.
private func permissionCalls() -> Permissions.Calls {
    var calls = Permissions.Calls()
    calls.granted = { _ in XCTFail("Unexpected preflight"); return false }
    calls.request = { _ in XCTFail("Unexpected request") }
    calls.open = { _ in XCTFail("Unexpected Settings launch") }
    calls.settingsOpen = { XCTFail("Unexpected Settings query"); return false }
    calls.canCapture = { XCTFail("Unexpected capture check"); return false }
    calls.time = { XCTFail("Unexpected wall clock"); return 1000 }
    calls.monotonic = { XCTFail("Unexpected monotonic clock"); return 1000 }
    calls.sleep = { _ in XCTFail("Unexpected sleep") }
    calls.callOnMain = { $0() }
    return calls
}
final class PermissionsTests: XCTestCase {
    func testAllowForLaunchReadGrantAsksForOneRelaunchAfterSettingsCloses() {
        let mac = FakePermissionMac(); mac.granted[.inputMonitoring] = false
        XCTAssertFalse(mac.permissions.wantsRelaunch())
        mac.permissions.openSettings(.inputMonitoring)
        XCTAssertFalse(mac.permissions.wantsRelaunch())  // Settings still open
        mac.settingsRunning = false
        XCTAssertTrue(mac.permissions.wantsRelaunch())
        XCTAssertFalse(mac.permissions.wantsRelaunch())  // once only
    }
    func testNoRelaunchWithoutSettingsSeenOrForLiveGrants() {
        let mac = FakePermissionMac(); mac.granted[.inputMonitoring] = false; mac.settingsLaunches = false
        mac.permissions.openSettings(.inputMonitoring)
        XCTAssertFalse(mac.permissions.wantsRelaunch())  // the pane never showed
        let live = FakePermissionMac(); live.granted[.accessibility] = false
        live.permissions.openSettings(.accessibility)
        live.settingsRunning = false
        XCTAssertFalse(live.permissions.wantsRelaunch())  // AXIsProcessTrusted is live
        let done = FakePermissionMac()  // already granted: nothing to wait for
        done.permissions.openSettings(.postEvents); done.settingsRunning = false
        XCTAssertFalse(done.permissions.wantsRelaunch())
    }
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
    func testOnlyRequestAndOpenUseSynchronousMainHandoff() {
        let inHandoff = OSAllocatedUnfairLock(initialState: false)
        let log = OSAllocatedUnfairLock<[String]>(initialState: [])
        var calls = permissionCalls()
        calls.callOnMain = { work in
            XCTAssertFalse(inHandoff.withLock { $0 })
            inHandoff.withLock { $0 = true }
            log.withLock { $0.append("hop") }
            work()
            inHandoff.withLock { $0 = false }
        }
        calls.granted = { kind in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertFalse(inHandoff.withLock { $0 })
            return kind != .screenRecording && kind != .inputMonitoring
        }
        calls.canCapture = {
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertFalse(inHandoff.withLock { $0 })
            return false
        }
        calls.monotonic = { XCTAssertFalse(inHandoff.withLock { $0 }); return 1000 }
        calls.settingsOpen = { XCTAssertFalse(inHandoff.withLock { $0 }); return true }
        calls.time = { XCTAssertFalse(inHandoff.withLock { $0 }); return 1000 }
        calls.request = { _ in
            XCTAssertTrue(inHandoff.withLock { $0 }); log.withLock { $0.append("request") }
        }
        calls.open = { _ in
            XCTAssertTrue(inHandoff.withLock { $0 }); log.withLock { $0.append("open") }
        }
        let permissions = Permissions(calls: calls)
        let done = DispatchGroup(); done.enter()
        DispatchQueue.global().async {
            XCTAssertFalse(permissions.status()["screen_recording"]!)
            permissions.request(.accessibility)
            permissions.openSettings(.inputMonitoring)
            XCTAssertFalse(permissions.wantsRelaunch())
            // The second gate step cancels without sleeping or moving preflights
            // onto main, even though grant status is still missing.
            assertHarnessError(name: "request_timed_out") {
                try permissions.gate(deadline: 1120, abandoned: {
                    XCTAssertFalse(inHandoff.withLock { $0 }); return true
                })
            }
            done.leave()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(log.withLock { $0 }, ["hop", "request", "hop", "request", "open", "hop", "request", "open"])
    }

    func testCaptureClaimCoversReentrantClockAndCaptureCallbacks() {
        let owner = OSAllocatedUnfairLock<Permissions?>(initialState: nil)
        let probes = OSAllocatedUnfairLock(initialState: 0)
        var calls = permissionCalls()
        calls.monotonic = {
            XCTAssertFalse(owner.withLock { $0 }!.toolCanCapture())
            return 1000
        }
        calls.canCapture = {
            probes.withLock { $0 += 1 }
            XCTAssertFalse(owner.withLock { $0 }!.toolCanCapture())
            return true
        }
        let permissions = Permissions(calls: calls)
        owner.withLock { $0 = permissions }
        defer { owner.withLock { $0 = nil } }
        XCTAssertTrue(permissions.toolCanCapture())
        // A fresh clock callback sees the already published result, not a lock.
        // Replaceable dependency values are copied at init, not mutated in place.
        XCTAssertEqual(probes.withLock { $0 }, 1)
    }

    func testConcurrentCaptureRefreshIsSingleflightAndKeepsCooldown() {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let clock = OSAllocatedUnfairLock(initialState: 1000.0)
        let probes = OSAllocatedUnfairLock(initialState: 0)
        var calls = permissionCalls()
        calls.monotonic = { clock.withLock { $0 } }
        calls.canCapture = {
            let count = probes.withLock { $0 += 1; return $0 }
            if count == 1 {
                entered.signal()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            }
            return true
        }
        let permissions = Permissions(calls: calls)
        let done = DispatchGroup(); done.enter()
        DispatchQueue.global().async { XCTAssertTrue(permissions.toolCanCapture()); done.leave() }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        let waiters = DispatchGroup(), started = DispatchSemaphore(value: 0)
        for _ in 0..<10 {
            waiters.enter()
            DispatchQueue.global().async {
                started.signal()
                XCTAssertTrue(permissions.toolCanCapture())
                waiters.leave()
            }
        }
        for _ in 0..<10 { XCTAssertEqual(started.wait(timeout: .now() + 5), .success) }
        // Starting a worker does not prove it waited for the in-flight probe.
        // None may complete with the initial cached false before publication.
        XCTAssertEqual(waiters.wait(timeout: .now() + 0.2), .timedOut)
        XCTAssertEqual(probes.withLock { $0 }, 1)
        release.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(waiters.wait(timeout: .now() + 5), .success)
        clock.withLock { $0 = 1000.999 }
        XCTAssertTrue(permissions.toolCanCapture())
        XCTAssertEqual(probes.withLock { $0 }, 1)
        clock.withLock { $0 = 1001 }
        DispatchQueue.concurrentPerform(iterations: 100) { _ in XCTAssertTrue(permissions.toolCanCapture()) }
        XCTAssertEqual(probes.withLock { $0 }, 2)
    }

    func testRefreshClockClaimPreventsOutOfOrderPublication() {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let clocks = OSAllocatedUnfairLock(initialState: 0)
        let probes = OSAllocatedUnfairLock(initialState: 0)
        var calls = permissionCalls()
        calls.monotonic = {
            let count = clocks.withLock { $0 += 1; return $0 }
            if count == 1 {
                entered.signal()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
                return 1000
            }
            return 1000.5
        }
        calls.canCapture = { probes.withLock { $0 += 1 }; return true }
        let permissions = Permissions(calls: calls)
        let done = DispatchGroup(); done.enter()
        DispatchQueue.global().async { XCTAssertTrue(permissions.toolCanCapture()); done.leave() }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        let waiter = DispatchGroup(), started = DispatchSemaphore(value: 0)
        waiter.enter()
        DispatchQueue.global().async {
            started.signal()
            XCTAssertTrue(permissions.toolCanCapture())
            waiter.leave()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(waiter.wait(timeout: .now() + 0.2), .timedOut)
        XCTAssertEqual(clocks.withLock { $0 }, 1)
        release.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(waiter.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(permissions.toolCanCapture())
        XCTAssertEqual(probes.withLock { $0 }, 1)
    }

    func testRequiredGrantClaimAllowsReentrantGateAndCachesOnlySuccess() throws {
        let owner = OSAllocatedUnfairLock<Permissions?>(initialState: nil)
        let counts = OSAllocatedUnfairLock<[Permissions.Kind: Int]>(initialState: [:])
        var calls = permissionCalls()
        calls.granted = { kind in
            counts.withLock { $0[kind, default: 0] += 1 }
            if kind == .accessibility {
                // The in-flight AX grant is not published yet; nested gate is
                // passive and never recursively probes AX or launches UI.
                assertHarnessError(name: "permissions_waiting") {
                    try owner.withLock { $0 }!.gate(deadline: 1120, requestUI: false)
                }
            }
            return true
        }
        let permissions = Permissions(calls: calls)
        owner.withLock { $0 = permissions }
        defer { owner.withLock { $0 = nil } }
        try permissions.gate(deadline: 1120, requestUI: false)
        try permissions.gate(deadline: 1120, requestUI: false)
        XCTAssertEqual(counts.withLock { $0 }, [.accessibility: 1, .screenRecording: 1])
    }

    func testConcurrentInitiallyGrantedPassiveGatesWaitForProbeAndKeepLiveStatus() throws {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let waiting = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        let counts = OSAllocatedUnfairLock<[Permissions.Kind: Int]>(initialState: [:])
        let allow = OSAllocatedUnfairLock(initialState: true)
        let waiterReturned = OSAllocatedUnfairLock(initialState: false)
        var calls = permissionCalls()
        calls.granted = { kind in
            let count = counts.withLock { $0[kind, default: 0] += 1; return $0[kind]! }
            if kind == .accessibility && count == 1 {
                entered.signal()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            }
            return allow.withLock { $0 }
        }
        calls.canCapture = { false }; calls.monotonic = { 1000 }; calls.time = { 1000 }
        calls.sleep = { _ in
            waiting.signal()
            XCTAssertEqual(resume.wait(timeout: .now() + 5), .success)
        }
        let permissions = Permissions(calls: calls)
        let owner = DispatchGroup(); owner.enter()
        DispatchQueue.global().async {
            do { try permissions.gate(deadline: 1120, requestUI: false) }
            catch { XCTFail("Unexpected owner gate error: \(error)") }
            owner.leave()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        let waiter = DispatchGroup(); waiter.enter()
        DispatchQueue.global().async {
            do { try permissions.gate(deadline: 1120, requestUI: false) }
            catch { XCTFail("Pending AX is not denied: \(error)") }
            waiterReturned.withLock { $0 = true }
            waiter.leave()
        }
        XCTAssertEqual(waiting.wait(timeout: .now() + 5), .success)
        XCTAssertFalse(waiterReturned.withLock { $0 })
        XCTAssertEqual(counts.withLock { $0 }, [.accessibility: 1, .screenRecording: 1])
        release.signal()
        XCTAssertEqual(owner.wait(timeout: .now() + 5), .success)
        resume.signal()
        XCTAssertEqual(waiter.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(counts.withLock { $0 }, [.accessibility: 1, .screenRecording: 1])
        allow.withLock { $0 = false }
        try permissions.gate(deadline: 1120, requestUI: false)
        XCTAssertEqual(permissions.status(), Dictionary(uniqueKeysWithValues: Permissions.Kind.allCases.map { ($0.rawValue, false) }))
    }

    func testConcurrentDeniedPassiveGatesWaitThenBothReportMissingBeforeDeadline() {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let waiting = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        let checks = OSAllocatedUnfairLock(initialState: 0)
        let clock = OSAllocatedUnfairLock(initialState: 1000.0)
        let sleeps = OSAllocatedUnfairLock(initialState: 0)
        let errors = OSAllocatedUnfairLock<[String]>(initialState: [])
        var calls = permissionCalls()
        calls.granted = { kind in
            guard kind == .accessibility else { return true }
            let count = checks.withLock { $0 += 1; return $0 }
            if count == 1 {
                entered.signal()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            }
            return false
        }
        calls.time = { clock.withLock { $0 } }
        calls.sleep = { duration in
            let count = sleeps.withLock { $0 += 1; return $0 }
            clock.withLock { $0 += duration }
            if count == 1 {
                waiting.signal()
                XCTAssertEqual(resume.wait(timeout: .now() + 5), .success)
            } else {
                XCTFail("Published denial must not keep waiting")
                clock.withLock { $0 = 1110 } // Bound a broken retry loop at its deadline.
            }
        }
        let permissions = Permissions(calls: calls)
        let attempt: @Sendable () -> Void = {
            do {
                try permissions.gate(deadline: 1120, requestUI: false)
                XCTFail("Denied Accessibility must fail the passive gate")
            } catch let error as HarnessError {
                errors.withLock { $0.append(error.name) }
                XCTAssertEqual(error.name, "permissions_missing")
            } catch { XCTFail("Unexpected error: \(error)") }
        }
        let owner = DispatchGroup(); owner.enter()
        DispatchQueue.global().async { attempt(); owner.leave() }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        let waiter = DispatchGroup(); waiter.enter()
        DispatchQueue.global().async { attempt(); waiter.leave() }
        // The injected sleep establishes that the second gate actually observed
        // the pending AX probe, not merely that its worker was scheduled.
        XCTAssertEqual(waiting.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(errors.withLock { $0.isEmpty })
        XCTAssertEqual(checks.withLock { $0 }, 1)
        release.signal()
        XCTAssertEqual(owner.wait(timeout: .now() + 5), .success)
        resume.signal()
        XCTAssertEqual(waiter.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(errors.withLock { $0 }, ["permissions_missing", "permissions_missing"])
        XCTAssertEqual(sleeps.withLock { $0 }, 1)
        XCTAssertEqual(clock.withLock { $0 }, 1000.25) // Far before the 1110 give-up threshold.
    }

    func testPassiveGateWaitsForInitiallyPendingCaptureInsteadOfDenying() {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let waiting = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        let waiterReturned = OSAllocatedUnfairLock(initialState: false)
        let probes = OSAllocatedUnfairLock(initialState: 0)
        var calls = permissionCalls()
        calls.granted = { $0 != .screenRecording }
        calls.monotonic = { 1000 }; calls.time = { 1000 }
        calls.canCapture = {
            probes.withLock { $0 += 1 }
            entered.signal()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            return true
        }
        calls.sleep = { _ in
            waiting.signal()
            XCTAssertEqual(resume.wait(timeout: .now() + 5), .success)
        }
        let permissions = Permissions(calls: calls)
        let owner = DispatchGroup(); owner.enter()
        DispatchQueue.global().async { XCTAssertTrue(permissions.toolCanCapture()); owner.leave() }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        let waiter = DispatchGroup(); waiter.enter()
        DispatchQueue.global().async {
            do { try permissions.gate(deadline: 1120, requestUI: false) }
            catch { XCTFail("Pending capture is not denied: \(error)") }
            waiterReturned.withLock { $0 = true }
            waiter.leave()
        }
        XCTAssertEqual(waiting.wait(timeout: .now() + 5), .success)
        XCTAssertFalse(waiterReturned.withLock { $0 })
        XCTAssertEqual(probes.withLock { $0 }, 1)
        release.signal()
        XCTAssertEqual(owner.wait(timeout: .now() + 5), .success)
        resume.signal()
        XCTAssertEqual(waiter.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(probes.withLock { $0 }, 1)
    }

    func testReentrantMainHandoffAndRequestsCanReadPermissionState() {
        let owner = OSAllocatedUnfairLock<Permissions?>(initialState: nil)
        let requests = OSAllocatedUnfairLock(initialState: 0)
        var calls = permissionCalls()
        calls.granted = { _ in false }
        calls.settingsOpen = { false }
        calls.callOnMain = { work in
            XCTAssertFalse(owner.withLock { $0 }!.wantsRelaunch())
            work()
        }
        calls.request = { _ in
            requests.withLock { $0 += 1 }
            XCTAssertFalse(owner.withLock { $0 }!.wantsRelaunch())
        }
        calls.open = { _ in XCTAssertFalse(owner.withLock { $0 }!.wantsRelaunch()) }
        let permissions = Permissions(calls: calls)
        owner.withLock { $0 = permissions }
        defer { owner.withLock { $0 = nil } }
        permissions.openSettings(.inputMonitoring)
        XCTAssertEqual(requests.withLock { $0 }, 1)
    }

    func testReentrantSettingsPollCannotConsumeNewAllowRecord() {
        let owner = OSAllocatedUnfairLock<Permissions?>(initialState: nil)
        let reenter = OSAllocatedUnfairLock(initialState: false)
        let settingsOpen = OSAllocatedUnfairLock(initialState: true)
        var calls = permissionCalls()
        calls.granted = { _ in false }
        calls.request = { _ in }; calls.open = { _ in }
        calls.settingsOpen = {
            let again = reenter.withLock { value in let again = value; value = false; return again }
            if again { owner.withLock { $0 }!.openSettings(.postEvents) }
            return settingsOpen.withLock { $0 }
        }
        let permissions = Permissions(calls: calls)
        owner.withLock { $0 = permissions }
        defer { owner.withLock { $0 = nil } }
        permissions.openSettings(.inputMonitoring)
        XCTAssertFalse(permissions.wantsRelaunch())
        settingsOpen.withLock { $0 = false }
        reenter.withLock { $0 = true }
        XCTAssertFalse(permissions.wantsRelaunch()) // stale closed sample cannot consume new intent
        XCTAssertFalse(permissions.wantsRelaunch()) // new intent has not seen Settings yet
        settingsOpen.withLock { $0 = true }
        XCTAssertFalse(permissions.wantsRelaunch())
        settingsOpen.withLock { $0 = false }
        XCTAssertTrue(permissions.wantsRelaunch())
        XCTAssertFalse(permissions.wantsRelaunch())
    }

    func testStaleOpenSettingsSampleCannotMarkNewRecordAsSeen() {
        let owner = OSAllocatedUnfairLock<Permissions?>(initialState: nil)
        let reenter = OSAllocatedUnfairLock(initialState: true)
        let open = OSAllocatedUnfairLock(initialState: true)
        var calls = permissionCalls()
        calls.granted = { _ in false }; calls.request = { _ in }; calls.open = { _ in }
        calls.settingsOpen = {
            let again = reenter.withLock { value in let again = value; value = false; return again }
            if again { owner.withLock { $0 }!.openSettings(.postEvents) }
            return open.withLock { $0 }
        }
        let permissions = Permissions(calls: calls)
        owner.withLock { $0 = permissions }
        defer { owner.withLock { $0 = nil } }
        permissions.openSettings(.inputMonitoring)
        XCTAssertFalse(permissions.wantsRelaunch())
        open.withLock { $0 = false }
        XCTAssertFalse(permissions.wantsRelaunch())
    }

    func testStaleDeniedPreflightCannotResurrectConsumedRelaunch() {
        let owner = OSAllocatedUnfairLock<Permissions?>(initialState: nil)
        let consume = OSAllocatedUnfairLock(initialState: false)
        let open = OSAllocatedUnfairLock(initialState: true)
        var calls = permissionCalls()
        calls.granted = { _ in
            let shouldConsume = consume.withLock { value in let result = value; value = false; return result }
            if shouldConsume { XCTAssertTrue(owner.withLock { $0 }!.wantsRelaunch()) }
            return false
        }
        calls.request = { _ in }; calls.open = { _ in }
        calls.settingsOpen = { open.withLock { $0 } }
        let permissions = Permissions(calls: calls)
        owner.withLock { $0 = permissions }
        defer { owner.withLock { $0 = nil } }
        permissions.openSettings(.inputMonitoring)
        XCTAssertFalse(permissions.wantsRelaunch())
        open.withLock { $0 = false }; consume.withLock { $0 = true }
        permissions.openSettings(.postEvents)
        open.withLock { $0 = true }
        XCTAssertFalse(permissions.wantsRelaunch())
        open.withLock { $0 = false }
        XCTAssertFalse(permissions.wantsRelaunch())
    }

    func testConcurrentSettingsCloseClaimsRelaunchExactlyOnce() {
        let mac = FakePermissionMac()
        mac.granted[.inputMonitoring] = false
        mac.permissions.openSettings(.inputMonitoring)
        XCTAssertFalse(mac.permissions.wantsRelaunch())
        mac.settingsRunning = false
        let claims = OSAllocatedUnfairLock(initialState: 0)
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            if mac.permissions.wantsRelaunch() { claims.withLock { $0 += 1 } }
        }
        XCTAssertEqual(claims.withLock { $0 }, 1)
    }

    func testSettingsPollClaimAllowsDirectReentry() {
        let owner = OSAllocatedUnfairLock<Permissions?>(initialState: nil)
        let open = OSAllocatedUnfairLock(initialState: true)
        let polls = OSAllocatedUnfairLock(initialState: 0)
        var calls = permissionCalls()
        calls.granted = { _ in false }; calls.request = { _ in }; calls.open = { _ in }
        calls.settingsOpen = {
            polls.withLock { $0 += 1 }
            XCTAssertFalse(owner.withLock { $0 }!.wantsRelaunch())
            return open.withLock { $0 }
        }
        let permissions = Permissions(calls: calls)
        owner.withLock { $0 = permissions }
        defer { owner.withLock { $0 = nil } }
        permissions.openSettings(.inputMonitoring)
        XCTAssertFalse(permissions.wantsRelaunch())
        open.withLock { $0 = false }
        XCTAssertTrue(permissions.wantsRelaunch())
        XCTAssertFalse(permissions.wantsRelaunch())
        XCTAssertEqual(polls.withLock { $0 }, 2)
    }

    func testOverlappingSettingsPollCannotPublishOutOfOrderSeenState() {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let open = OSAllocatedUnfairLock(initialState: false)
        let polls = OSAllocatedUnfairLock(initialState: 0)
        var calls = permissionCalls()
        calls.granted = { _ in false }; calls.request = { _ in }; calls.open = { _ in }
        calls.settingsOpen = {
            let sample = open.withLock { $0 }
            let count = polls.withLock { $0 += 1; return $0 }
            if count == 1 {
                entered.signal()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            }
            return sample
        }
        let permissions = Permissions(calls: calls)
        permissions.openSettings(.inputMonitoring)
        let done = DispatchGroup(); done.enter()
        DispatchQueue.global().async { XCTAssertFalse(permissions.wantsRelaunch()); done.leave() }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        open.withLock { $0 = true }
        XCTAssertFalse(permissions.wantsRelaunch()) // no second overlapping sample
        XCTAssertEqual(polls.withLock { $0 }, 1)
        release.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        open.withLock { $0 = false }
        XCTAssertFalse(permissions.wantsRelaunch()) // no published open sample yet
        open.withLock { $0 = true }
        XCTAssertFalse(permissions.wantsRelaunch())
        open.withLock { $0 = false }
        XCTAssertTrue(permissions.wantsRelaunch())
    }

    func testOverlappingDifferentLaunchReadIntentsRetainDeniedGrant() {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let open = OSAllocatedUnfairLock(initialState: true)
        var calls = permissionCalls()
        calls.granted = { kind in
            if kind == .inputMonitoring {
                entered.signal()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
                return false
            }
            return true
        }
        calls.request = { _ in }; calls.open = { _ in }
        calls.settingsOpen = { open.withLock { $0 } }
        let permissions = Permissions(calls: calls)
        let done = DispatchGroup(); done.enter()
        DispatchQueue.global().async { permissions.openSettings(.inputMonitoring); done.leave() }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        permissions.openSettings(.postEvents) // must not invalidate the other kind's claim
        release.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertFalse(permissions.wantsRelaunch())
        open.withLock { $0 = false }
        XCTAssertTrue(permissions.wantsRelaunch())
    }

    func testNewerSameKindPreflightInvalidatesOlderDeniedPublication() {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let checks = OSAllocatedUnfairLock(initialState: 0)
        var calls = permissionCalls()
        calls.granted = { _ in
            let count = checks.withLock { $0 += 1; return $0 }
            if count == 1 {
                entered.signal()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
                return false
            }
            return true
        }
        calls.request = { _ in }; calls.open = { _ in }
        let permissions = Permissions(calls: calls)
        let done = DispatchGroup(); done.enter()
        DispatchQueue.global().async { permissions.openSettings(.inputMonitoring); done.leave() }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        permissions.openSettings(.inputMonitoring)
        release.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertFalse(permissions.wantsRelaunch()) // no record and no Settings query
    }

    func testAbandonedGateDoesNotWaitOnAnotherWorkersCaptureClaim() {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        var calls = permissionCalls()
        calls.granted = { $0 != .screenRecording }
        calls.monotonic = { 1000 }; calls.time = { 1000 }
        calls.request = { _ in }; calls.open = { _ in }
        calls.canCapture = {
            entered.signal()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            return true
        }
        let permissions = Permissions(calls: calls)
        let done = DispatchGroup(); done.enter()
        DispatchQueue.global().async { XCTAssertTrue(permissions.toolCanCapture()); done.leave() }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        assertHarnessError(name: "request_timed_out") {
            try permissions.gate(deadline: 1120, abandoned: { true })
        }
        release.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
    }

    func testReentrantCaptureGateReportsPendingWithoutWaitingOrDenying() {
        let owner = OSAllocatedUnfairLock<Permissions?>(initialState: nil)
        var calls = permissionCalls()
        calls.granted = { $0 != .screenRecording }; calls.monotonic = { 1000 }
        calls.canCapture = {
            assertHarnessError(name: "permissions_waiting") {
                try owner.withLock { $0 }!.gate(deadline: 1120, requestUI: false)
            }
            return true
        }
        let permissions = Permissions(calls: calls)
        owner.withLock { $0 = permissions }
        defer { owner.withLock { $0 = nil } }
        XCTAssertTrue(permissions.toolCanCapture())
        XCTAssertNoThrow(try permissions.gate(deadline: 1120, requestUI: false))
    }

    func testPendingRequiredProbeWaitHonorsCancellationAndDeadlineWithoutUI() {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let clock = OSAllocatedUnfairLock(initialState: 1000.0)
        var calls = permissionCalls()
        calls.granted = { kind in
            if kind == .accessibility {
                entered.signal()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            }
            return true
        }
        calls.time = { clock.withLock { $0 } }
        calls.sleep = { duration in clock.withLock { $0 += duration } }
        let permissions = Permissions(calls: calls)
        let owner = DispatchGroup(); owner.enter()
        DispatchQueue.global().async {
            do { try permissions.gate(deadline: 1120, requestUI: false) }
            catch { XCTFail("Unexpected owner gate error: \(error)") }
            owner.leave()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        assertHarnessError(name: "request_timed_out") {
            try permissions.gate(deadline: 1120, abandoned: { clock.withLock { $0 >= 1000.5 } }, requestUI: false)
        }
        XCTAssertEqual(clock.withLock { $0 }, 1000.5)
        clock.withLock { $0 = 1000 }
        assertHarnessError(name: "permissions_waiting") {
            try permissions.gate(deadline: 1010.5, requestUI: false)
        }
        XCTAssertEqual(clock.withLock { $0 }, 1000.5)
        release.signal()
        XCTAssertEqual(owner.wait(timeout: .now() + 5), .success)
    }

}
