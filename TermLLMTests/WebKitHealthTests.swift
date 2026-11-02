import SwiftUI
import WebKit
import XCTest
@testable import TermLLM

/// Builds probe reports through the real parser, as the bridge does.
private func report(_ fields: [String: Any] = [:]) -> WebPageHealthSample {
    var body: [String: Any] = ["v": WebKitHealthProbe.version, "doc": "doc-1", "seq": 0, "span": 5_000, "vis": "hidden"]
    body.merge(fields) { $1 }
    return WebKitHealthProbe.parse(body)!
}

private func reports(every step: TimeInterval = 5, from start: TimeInterval, through end: TimeInterval,
                     _ fields: [String: Any]) -> [TimedPageSample] {
    stride(from: start, through: end, by: step).map { TimedPageSample(uptime: $0, sample: report(fields)) }
}

private func native(_ uptime: TimeInterval, app: Double? = 0.05, device: Double? = 0.3,
                    thermal: ProcessInfo.ThermalState = .nominal) -> NativeHealthSample {
    // 800_000_040 s after the reference date starts a minute.
    NativeHealthSample(uptime: uptime, date: Date(timeIntervalSinceReferenceDate: 800_000_040 + uptime),
                       appCPU: app, deviceCPU: device, cpuCount: 6, wakeupsPerSecond: 3, footprintMB: 80,
                       thermal: thermal, lowPower: false, batteryLevel: 0.5, charging: false,
                       appActive: true, appBackground: false, cpuInterval: 5)
}

final class WebKitHealthPolicyTests: XCTestCase {
    private let policy = WebKitHealthPolicy()
    private let offScreen = WebKitPageContext(userCanSee: false)

    private func verdict(now: TimeInterval, context: WebKitPageContext? = nil, hiddenSince: TimeInterval? = 0,
                         visibleSince: TimeInterval? = nil, lastSampleAt: TimeInterval? = nil, armed: Bool = true,
                         samples: [TimedPageSample] = [], thermal: ProcessInfo.ThermalState = .nominal,
                         outside: Double? = nil) -> WebKitHealthPolicy.Verdict {
        policy.verdict(.init(now: now, context: context ?? offScreen, hiddenSince: hiddenSince, visibleSince: visibleSince,
                             lastSampleAt: lastSampleAt ?? samples.last?.uptime, armed: armed, samples: samples,
                             thermal: thermal, outsideAppCPU: outside))
    }

    private func stopReason(_ verdict: WebKitHealthPolicy.Verdict) -> WebKitTeardownReason? {
        if case .teardown(let reason, _) = verdict { return reason }
        return nil
    }

    func testOffScreenPageThatKeepsDrawingIsStoppedAfterGraceAndWindow() {
        // WebKit still runs it as visible: 60 frames/s off screen.
        let drawing = reports(from: 5, through: 150, ["vis": "visible", "frames": 300])
        XCTAssertEqual(verdict(now: 50, samples: drawing.filter { $0.uptime <= 50 }), .healthy, "inside the grace period")
        XCTAssertEqual(verdict(now: 90, samples: drawing.filter { $0.uptime <= 90 }), .healthy, "not active for long enough yet")
        guard case .teardown(.hiddenActivity, let detail) = verdict(now: 150, samples: drawing) else {
            return XCTFail("a page drawing off screen for two minutes must be stopped")
        }
        XCTAssertTrue(detail.contains("60 frames/s"), detail)
    }

    func testOccasionalActivityIsNotARunaway() {
        let mixed = stride(from: 5.0, through: 150, by: 5).map { time in
            TimedPageSample(uptime: time, sample: report(Int(time) % 10 == 0 ? ["vis": "visible", "frames": 300] : [:]))
        }
        XCTAssertEqual(verdict(now: 150, samples: mixed), .healthy)
    }

    func testHiddenPageDOMChangesAloneDoNotStopIt() {
        // A response that offers device tools keeps streaming into a hidden page.
        let streaming = reports(from: 5, through: 180, ["vis": "hidden", "mutations": 200, "mutMs": 1_000])
        XCTAssertEqual(verdict(now: 180, samples: streaming), .healthy)
        // The same changes in a page WebKit renders as visible off screen do count.
        let rendered = reports(from: 5, through: 180, ["vis": "visible", "mutations": 200, "mutMs": 1_000])
        XCTAssertEqual(stopReason(verdict(now: 180, samples: rendered)), .hiddenActivity)
    }

    func testHiddenPagePollingOrRunningAudioIsStopped() {
        let polling = reports(from: 5, through: 180, ["resources": 10])
        XCTAssertEqual(stopReason(verdict(now: 180, samples: polling)), .hiddenActivity)
        let audio = reports(from: 5, through: 180, ["audio": 1, "audioTotal": 1])
        XCTAssertEqual(stopReason(verdict(now: 180, samples: audio)), .hiddenActivity)
    }

    func testCallsVoiceLaunchesToolRepliesSignInAndPlayingMediaAreProtected() {
        let audio = reports(from: 5, through: 180, ["audio": 1, "audioTotal": 1, "vis": "visible", "frames": 300])
        for context in [WebKitPageContext(capturing: true), WebKitPageContext(voiceLaunching: true),
                        WebKitPageContext(toolCalls: 1), WebKitPageContext(signingIn: true)] {
            XCTAssertEqual(verdict(now: 180, context: context, samples: audio), .healthy, "\(context)")
        }
        let playing = reports(from: 5, through: 180, ["vis": "visible", "frames": 300, "media": 1])
        XCTAssertEqual(verdict(now: 180, samples: playing), .healthy, "page media may be what the user listens to")
    }

    func testOnScreenPageIsNeverStoppedForActivity() {
        let drawing = reports(from: 5, through: 180, ["vis": "visible", "frames": 300, "audio": 1])
        XCTAssertEqual(verdict(now: 180, context: WebKitPageContext(userCanSee: true), hiddenSince: nil,
                               visibleSince: 0, samples: drawing), .healthy)
    }

    func testHotPhoneStopsOnlyAnAwakeOffScreenPage() {
        let awake = reports(from: 5, through: 30, [:])
        XCTAssertEqual(stopReason(verdict(now: 40, samples: awake, thermal: .serious)), .thermal)
        XCTAssertEqual(stopReason(verdict(now: 40, samples: awake, thermal: .critical)), .thermal)
        XCTAssertEqual(verdict(now: 40, samples: awake, thermal: .fair), .healthy)
        XCTAssertEqual(verdict(now: 20, samples: reports(from: 5, through: 20, [:]), thermal: .serious), .healthy,
                       "inside the thermal grace")
        XCTAssertEqual(verdict(now: 100, samples: awake, thermal: .serious), .healthy,
                       "a page that stopped reporting is suspended, not the cause")
        XCTAssertEqual(verdict(now: 40, hiddenSince: 0, samples: [], thermal: .serious), .healthy)
    }

    func testSilentOnScreenPageIsStoppedOnlyWhileThePhoneStaysBusy() {
        let onScreen = WebKitPageContext(userCanSee: true)
        func silent(_ now: TimeInterval, context: WebKitPageContext = onScreen, armed: Bool = true,
                    outside: Double?) -> WebKitHealthPolicy.Verdict {
            verdict(now: now, context: context, hiddenSince: nil, visibleSince: 0, lastSampleAt: 0, armed: armed,
                    outside: outside)
        }
        XCTAssertEqual(silent(10, outside: 2), .healthy)
        XCTAssertEqual(silent(20, outside: 2), .stalled(20))
        XCTAssertEqual(stopReason(silent(50, outside: 1.2)), .unresponsive, "an endless loop burns a core")
        XCTAssertEqual(silent(50, outside: 0.1), .stalled(50), "paused in Web Inspector or deadlocked: costs nothing")
        XCTAssertEqual(silent(50, outside: nil), .stalled(50), "no evidence without device counters")
        XCTAssertEqual(silent(50, context: WebKitPageContext(userCanSee: true, loading: true), outside: 2), .healthy)
        XCTAssertEqual(silent(50, context: WebKitPageContext(userCanSee: true, signingIn: true), outside: 2), .stalled(50))
        XCTAssertEqual(silent(50, armed: false, outside: 2), .healthy, "no probe, no heartbeat to miss")
        XCTAssertEqual(silent(1_100, context: WebKitPageContext(userCanSee: true, appBackground: true), outside: 2),
                       .healthy, "a stale visibility context must not turn background suspension into a stall")
        // Silence is counted from when the page came on screen, not its last hidden report.
        XCTAssertEqual(verdict(now: 100, context: onScreen, hiddenSince: nil, visibleSince: 90, lastSampleAt: 0,
                               outside: 2), .healthy)
    }
}

final class WebKitHealthProbeParsingTests: XCTestCase {
    func testParsesAReportAndKeepsOnlyCodeNames() throws {
        let sample = try XCTUnwrap(WebKitHealthProbe.parse([
            "v": WebKitHealthProbe.version, "doc": "abc-123", "seq": 4, "span": 5_000, "vis": "visible",
            "hidden": 1_000, "ticks": 5, "late": 9_999, "maxLate": 700, "frames": 120, "frameMs": 30,
            "mutations": 40, "mutMs": 1_000, "resources": 2, "longTasks": -1, "dom": 1_234, "running": 3,
            "anims": [["name": "spin", "target": "div.spinner::before", "props": ["transform"], "infinite": true,
                       "composited": true],
                      ["name": "Read secret https://x.example/?q=1", "target": "p", "props": ["color"]]],
            "audio": 1, "audioTotal": 2, "tracks": 1, "peers": 0, "sockets": 1, "sources": 0, "media": 0, "probe": 2.5,
        ]))
        XCTAssertEqual(sample.documentID, "abc-123")
        XCTAssertTrue(sample.isVisible)
        XCTAssertEqual(sample.lateMilliseconds, 5_000, "clamped to the span")
        XCTAssertEqual(sample.busyFraction, 1)
        XCTAssertEqual(sample.framesPerSecond, 24)
        XCTAssertEqual(sample.mutationsPerSecond, 40, "per counted second, not per span")
        XCTAssertEqual(sample.resourcesPerMinute, 24)
        XCTAssertNil(sample.longTasks)
        XCTAssertEqual(sample.domNodes, 1_234)
        XCTAssertEqual(sample.animations.first, .init(name: "spin", target: "div.spinner::before",
                                                      properties: ["transform"], infinite: true, composited: true))
        XCTAssertEqual(sample.animations.last?.name, "Read?secret?https:??x.example??q?1",
                       "free text can only pass as code-name characters")
        XCTAssertEqual(sample.repaintingAnimations.count, 1)
        XCTAssertEqual(sample.probeShare, 0.0005, accuracy: 1e-9)
    }

    func testParsesNativeMeasurementWindowWithoutRequiringItForInitialReports() {
        XCTAssertNil(report().windowID)
        XCTAssertEqual(report(["window": "window-123"]).windowID, "window-123")
        XCTAssertEqual(report(["window": String(repeating: "a", count: 100)]).windowID?.count, 40)
        XCTAssertEqual(report(["window": "not a token"]).windowID, "not?a?token")
    }

    func testRejectsMalformedOrForeignReports() {
        XCTAssertNil(WebKitHealthProbe.parse("text"))
        XCTAssertNil(WebKitHealthProbe.parse(["v": 1, "doc": "a", "span": 5_000]), "old probe version")
        XCTAssertNil(WebKitHealthProbe.parse(["v": WebKitHealthProbe.version, "span": 5_000]), "no document")
        XCTAssertNil(WebKitHealthProbe.parse(["v": WebKitHealthProbe.version, "doc": "a", "span": 0]))
        XCTAssertNil(WebKitHealthProbe.parse(["v": WebKitHealthProbe.version, "doc": "a", "span": true]))
        let odd = WebKitHealthProbe.parse(["v": WebKitHealthProbe.version, "doc": "a", "span": 5_000, "vis": "sneaky",
                                           "frames": -5, "audio": 1e9, "mutations": "many"])
        XCTAssertEqual(odd?.visibility, "unknown")
        XCTAssertEqual(odd?.frames, 0)
        XCTAssertEqual(odd?.audioContextsRunning, 64)
        XCTAssertEqual(odd?.mutations, 0)
    }

    /// The probe reports counts and code names only: it must never read page
    /// text, form values, titles, addresses, cookies or storage.
    func testProbeNeverReadsPageContent() {
        let script = WebKitHealthProbe.script(origin: "https://example.com")
        for forbidden in ["innerText", "textContent", "innerHTML", "outerHTML", "document.title",
                          "location.href", "document.URL", "cookie", "localStorage", "sessionStorage", "fetch("] {
            XCTAssertFalse(script.contains(forbidden), forbidden)
        }
        XCTAssertNil(script.range(of: #"\.value(?![A-Za-z])"#, options: .regularExpression), "form values")
        XCTAssertTrue(script.contains("location.origin !== ORIGIN"))
    }
}

/// Executes the production probe in WebKit with a deterministic clock/timer.
/// This tests lifecycle math, not physical-device suspension behavior.
@MainActor
final class WebKitHealthProbeLifecycleTests: XCTestCase {
    private final class Samples: NSObject, WKScriptMessageHandler {
        var values: [WebPageHealthSample] = []
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if let sample = WebKitHealthProbe.parse(message.body) { values.append(sample) }
        }
    }

    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for probe lifecycle evidence")
                throw NSError(domain: "WebKitHealthProbeLifecycleTests", code: 1)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testLifecycleAndNativeResetsDiscardSuspensionButNotSubsequentLongTasks() async throws {
        let samples = Samples()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let controller = configuration.userContentController
        controller.add(samples, name: WebKitHealthProbe.handlerName)
        // No real-time delays, UI visibility dependency, network or busy loop.
        let clock = """
        window.__healthClock = 0;
        Object.defineProperty(performance, 'now', { value: () => window.__healthClock });
        Object.defineProperty(document, 'visibilityState', { get: () => 'visible' });
        window.setTimeout = (callback) => { window.__healthTimer = callback; return 1; };
        window.clearTimeout = () => { window.__healthTimer = null; };
        window.__healthAdvance = (milliseconds) => {
          window.__healthClock += milliseconds;
          window.__healthTimer();
        };
        """
        controller.addUserScript(WKUserScript(source: clock + WebKitHealthProbe.script(origin: "https://example.com"),
                                             injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let web = WKWebView(frame: .zero, configuration: configuration)
        defer {
            web.stopLoading()
            controller.removeScriptMessageHandler(forName: WebKitHealthProbe.handlerName)
        }
        web.loadHTMLString("<!doctype html><html><body>Probe fixture</body></html>",
                           baseURL: URL(string: "https://example.com/ui/"))
        try await until { !web.isLoading && web.url != nil }
        _ = try await web.evaluateJavaScript(WebKitHealthProbe.resetScript(windowID: "native-window"))
        let events = [("document", "visibilitychange"), ("window", "pagehide"), ("window", "pageshow"),
                      ("document", "freeze"), ("document", "resume")]
        for (target, event) in events {
            let count = samples.values.count
            _ = try await web.evaluateJavaScript("""
            window.__healthClock += 1065700;
            \(target).dispatchEvent(new Event('\(event)'));
            for (let i = 0; i < 5; i++) window.__healthAdvance(1000);
            """)
            try await until { samples.values.count > count }
            let sample = try XCTUnwrap(samples.values.last)
            XCTAssertEqual(samples.values.count, count + 1, "\(event) must not flush a suspension-spanning report")
            XCTAssertEqual(sample.windowID, "native-window")
            XCTAssertEqual(sample.spanSeconds, 5, accuracy: 0.001, event)
            XCTAssertEqual(sample.ticks, 5, event)
            XCTAssertEqual(sample.maxLateMilliseconds, 0, event)
            XCTAssertEqual(sample.busyFraction, 0, event)
        }
        let count = samples.values.count
        _ = try await web.evaluateJavaScript("window.__healthClock += 1065700;")
        _ = try await web.evaluateJavaScript(WebKitHealthProbe.resetScript(windowID: "resumed-window"))
        _ = try await web.evaluateJavaScript("for (let i = 0; i < 5; i++) window.__healthAdvance(1000);")
        try await until { samples.values.count > count }
        let resumed = try XCTUnwrap(samples.values.last)
        XCTAssertEqual(resumed.windowID, "resumed-window")
        XCTAssertEqual(resumed.spanSeconds, 5, accuracy: 0.001)
        XCTAssertEqual(resumed.maxLateMilliseconds, 0)
        _ = try await web.evaluateJavaScript("window.__healthAdvance(85000);")
        try await until { samples.values.count > count + 1 }
        let blocked = try XCTUnwrap(samples.values.last)
        XCTAssertEqual(blocked.windowID, "resumed-window")
        XCTAssertEqual(blocked.spanSeconds, 85, accuracy: 0.001)
        XCTAssertEqual(blocked.maxLateMilliseconds, 84_000, accuracy: 0.001)
        XCTAssertGreaterThan(blocked.busyFraction, 0.9, "a long foreground task without a lifecycle reset is still measured")
    }
}

final class WebKitHealthFindingsTests: XCTestCase {
    private func evaluate(context: WebKitPageContext, samples: [TimedPageSample], hiddenSince: TimeInterval? = nil,
                          natives: [NativeHealthSample] = [], alive: Int = 1, now: TimeInterval = 60) -> Set<String> {
        let page = WebKitHealthFindings.Page(context: context, samples: samples, hiddenSince: hiddenSince, verdict: .healthy)
        return Set(WebKitHealthFindings.evaluate(natives: natives, page: page, threads: [], webViewsAlive: alive,
                                                 pages: 1, now: now).map(\.id))
    }

    func testExplainsAnOnScreenPageThatKeepsTheCPUBusy() {
        let busy = reports(from: 30, through: 60, ["vis": "visible", "frames": 300, "late": 3_000, "running": 2,
                                                   "anims": [["name": "paint", "target": "div", "props": ["background-position"]]]])
        let ids = evaluate(context: WebKitPageContext(userCanSee: true), samples: busy)
        XCTAssertEqual(ids, ["frames", "busy", "animations"])
    }

    func testFlagsAnOffScreenPageWebKitStillRunsAsVisible() {
        let ids = evaluate(context: WebKitPageContext(userCanSee: false, inWindow: true, viewHidden: true),
                           samples: reports(from: 30, through: 60, ["vis": "visible"]), hiddenSince: 20)
        XCTAssertTrue(ids.contains("visibility"))
        XCTAssertFalse(evaluate(context: WebKitPageContext(userCanSee: false),
                                samples: reports(from: 30, through: 60, ["vis": "hidden"]), hiddenSince: 20)
            .contains("visibility"))
    }

    func testOnlyReportsSentAfterHidingShowAHiddenPageRunningAsVisible() {
        let offScreen = WebKitPageContext(userCanSee: false)
        // Sent while Chat was on screen; once hidden, the page went quiet.
        let onScreen = reports(from: 5, through: 30, ["vis": "visible"])
        XCTAssertFalse(evaluate(context: offScreen, samples: onScreen, hiddenSince: 32).contains("visibility"))
        let late = onScreen + [TimedPageSample(uptime: 45, sample: report(["vis": "visible"]))]
        XCTAssertFalse(evaluate(context: offScreen, samples: late, hiddenSince: 32).contains("visibility"),
                       "one late report is not a page running at full speed")
        let sustained = onScreen + reports(from: 45, through: 55, ["vis": "visible"])
        XCTAssertTrue(evaluate(context: offScreen, samples: sustained, hiddenSince: 32).contains("visibility"))
    }

    func testSeparatesAppCPUFromOtherProcessesAndLeakedViews() {
        let natives = stride(from: 0.0, through: 60, by: 5).map { native($0, app: 0.8, device: 3) }
        let ids = evaluate(context: WebKitPageContext(userCanSee: true), samples: [], natives: natives, alive: 2)
        XCTAssertEqual(ids, ["app-cpu", "other-cpu", "web-views"])
    }

    func testAudioWithoutACallButNotDuringOne() {
        let audio = reports(from: 30, through: 60, ["audio": 1, "audioTotal": 1])
        XCTAssertTrue(evaluate(context: WebKitPageContext(userCanSee: true), samples: audio).contains("audio"))
        XCTAssertFalse(evaluate(context: WebKitPageContext(userCanSee: true, capturing: true), samples: audio).contains("audio"))
    }
}

final class WebKitHealthHistoryTests: XCTestCase {
    func testReportsIncludePodcastBytesAndCoverageInBothFormats() {
        let now = Date(timeIntervalSince1970: 1_793_600_000)
        let usage = ListenNetworkUsage.Snapshot(todayBytes: 101, weekBytes: 202, monthBytes: 303,
                                              totalBytes: 404, recentBytes: 55, startedAt: now)
        for compact in [false, true] {
            let text = WebKitHealthReport.make(status: WebKitHealthStatus(), events: [], minutes: [], natives: [],
                                               probeEnabled: true, autoStop: true, now: now,
                                               device: "test", app: "test", compact: compact, listenUsage: usage)
            XCTAssertTrue(text.contains("today 101 B; this week 202 B; this month 303 B; since tracking began 404 B; last 60 s 55 B"), text)
            XCTAssertTrue(text.contains("Earlier downloads unknown"), text)
            XCTAssertTrue(text.contains("Excludes direct AVPlayer streams"), text)
            XCTAssertTrue(text.contains("including retries and re-downloads"), text)
            XCTAssertTrue(text.contains(now.ISO8601Format()), text)
        }
    }

    func testMinuteSummaryUsesCountedTimeAndMeasuresItsOwnCost() throws {
        var accumulator = MinuteAccumulator()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func add(_ uptime: TimeInterval, cost: UInt64) -> WebKitHealthMinute? {
            accumulator.add(native(uptime, app: 0.1, device: 1), chatOnScreen: true, webViews: 1,
                            monitorNanoseconds: cost, calendar: calendar)
        }
        XCTAssertNil(add(5, cost: 0))
        accumulator.add(report(["vis": "visible", "frames": 50, "mutations": 30, "mutMs": 1_000, "probe": 1]))
        accumulator.add(report(["vis": "visible", "frames": 50, "mutations": 10, "mutMs": 1_000, "probe": 1]))
        XCTAssertNil(add(35, cost: 3_000_000))
        let minute = try XCTUnwrap(add(65, cost: 3_500_000))
        XCTAssertEqual(minute.app ?? 0, 0.1, accuracy: 1e-9)
        XCTAssertEqual(minute.device ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(minute.pageReports, 2)
        XCTAssertEqual(minute.fps ?? 0, 10, accuracy: 1e-9)
        XCTAssertEqual(minute.mutations ?? 0, 20, accuracy: 1e-9, "40 changes over 2 counted seconds")
        XCTAssertEqual(minute.probe ?? 0, 0.0002, accuracy: 1e-9, "2 ms over 10 s")
        XCTAssertEqual(minute.monitor ?? 0, 0.0001, accuracy: 1e-9, "3 ms over 30 s")
        XCTAssertEqual(minute.chatOnScreen, 1)
    }

    func testJournalSurvivesRelaunchAndClears() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WebKitHealth-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = WebKitHealthJournal(directory: directory)
        journal.append(event: WebKitHealthEvent(date: Date(), kind: "stop", message: "Stopped"))
        journal.append(event: WebKitHealthEvent(date: Date(), kind: "effect", message: "Dropped"))
        journal.append(minute: WebKitHealthMinute(start: Date(), thermal: 2, foreground: 1, chatOnScreen: 0,
                                                  pageReports: 3, webViews: 1, probe: 0.0001))
        let reopened = WebKitHealthJournal(directory: directory)
        let loaded = await withCheckedContinuation { continuation in
            // Same queue order is not shared across instances: load after the writes land.
            journal.load { _, _ in
                reopened.load { events, minutes in continuation.resume(returning: (events, minutes)) }
            }
        }
        XCTAssertEqual(loaded.0.map(\.kind), ["stop", "effect"])
        XCTAssertEqual(loaded.1.first?.thermal, 2)
        XCTAssertEqual(loaded.1.first?.probe, 0.0001)
        journal.clear()
        let cleared = await withCheckedContinuation { continuation in
            journal.load { events, minutes in continuation.resume(returning: events.count + minutes.count) }
        }
        XCTAssertEqual(cleared, 0)
    }

    func testReportCarriesMeasurementsNotAddresses() {
        var status = WebKitHealthStatus()
        status.native = native(10)
        status.latest = report(["vis": "visible", "frames": 300])
        status.monitorShare = 0.00002
        status.probeShare = 0.0001
        let text = WebKitHealthReport.make(status: status, events: [WebKitHealthEvent(date: Date(), kind: "stop", message: "Stopped")],
                                           minutes: [], natives: [native(10)], probeEnabled: true, autoStop: true,
                                           now: Date(), device: "iPhone17,1 iOS 26.1", app: "1.0 (1)")
        XCTAssertTrue(text.contains("Monitor cost: app 0.002% of a core since launch, page probe 0.010% (this page, up to 10 min)"), text)
        XCTAssertTrue(text.contains("60.0 frames/s"))
        XCTAssertFalse(text.contains("Last on-screen report"), "the latest report is already the on-screen one")
        XCTAssertFalse(text.contains("http"))
    }

    func testAgentReportIncludesOldEvidencePeaksFreshnessAndSamplingLimits() {
        var status = WebKitHealthStatus()
        status.lastReportAge = 93
        var accumulator = MinuteAccumulator()
        _ = accumulator.add(native(0, app: 0.9), chatOnScreen: false, webViews: 1)
        let minute = accumulator.add(native(65), chatOnScreen: false, webViews: 1)!
        let events = (0..<100).map {
            WebKitHealthEvent(date: Date(), kind: "native-cpu", message: "evidence-\($0)")
        }
        let text = WebKitHealthReport.make(status: status, events: events, minutes: [minute],
                                          natives: [native(0), native(65)], probeEnabled: true, autoStop: true,
                                          now: Date(), device: "iPhone", app: "1.0")
        XCTAssertTrue(text.contains("Report schema: 2"))
        XCTAssertTrue(text.contains("Page report age: 93 s"))
        XCTAssertTrue(text.contains("evidence-0"), "do not drop an older CPU incident at the old 80-event export limit")
        XCTAssertTrue(text.contains("| 90 0.30 80"), text)
        XCTAssertTrue(text.contains("| 65.0 65.0 5.0 true false 80 normal"), text)
        XCTAssertTrue(text.contains("not time-weighted"))
        XCTAssertTrue(text.contains("not a stack trace"))
        XCTAssertTrue(text.contains("Findings (current only):"))
    }

    func testCompactReportSelectsWorstCPURecoveryAndDeduplicatesNoise() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        var events = [
            WebKitHealthEvent(date: date, kind: "native-cpu", message: "app 80%; threads main#42 70%"),
            WebKitHealthEvent(date: date.addingTimeInterval(5), kind: "native-cpu", message: "CPU episode ended at app 5%; peak 150%. worst-recovery"),
            WebKitHealthEvent(date: date.addingTimeInterval(10), kind: "stop", message: "Paused page"),
            WebKitHealthEvent(date: date.addingTimeInterval(15), kind: "effect", message: "After closing: CPU unchanged")
        ]
        events += (0..<200).map {
            WebKitHealthEvent(date: date.addingTimeInterval(Double(20 + $0)), kind: "app", message: "Returned to foreground.")
        }
        events.append(WebKitHealthEvent(date: date.addingTimeInterval(230), kind: "native-cpu", message: "app 40%; threads worker#43 35%"))
        let compact = WebKitHealthReport.make(status: WebKitHealthStatus(), events: events, minutes: [], natives: [],
                                             probeEnabled: true, autoStop: true, now: date, device: "iPhone", app: "1.0", compact: true)
        XCTAssertTrue(compact.contains("worst-recovery"), compact)
        XCTAssertTrue(compact.contains("main#42 70%"))
        XCTAssertTrue(compact.contains("After closing: CPU unchanged"))
        XCTAssertTrue(compact.contains("(x200 identical)"))
        XCTAssertEqual(compact.components(separatedBy: "Returned to foreground.").count - 1, 1)
        XCTAssertTrue(compact.contains("Selection is lossy"))
        XCTAssertTrue(compact.contains("no stacks"))
        XCTAssertTrue(compact.contains("Current findings: none"))
        XCTAssertFalse(compact.contains("Samples (retained"))
    }

    func testCompactReportIsMuchSmallerButKeepsPeakAndBoundaryMinutes() {
        var accumulator = MinuteAccumulator()
        var minutes: [WebKitHealthMinute] = []
        for index in 0...360 {
            if let minute = accumulator.add(native(Double(index * 60), app: index == 50 ? 0.95 : 0.05),
                                            chatOnScreen: index < 100, webViews: 1) {
                minutes.append(minute)
            }
        }
        let events = (0..<300).map {
            WebKitHealthEvent(date: Date(timeIntervalSince1970: Double($0)), kind: "app", message: "Returned to foreground.")
        }
        let samples = (0..<360).map { native(Double($0 * 5)) }
        let compact = WebKitHealthReport.make(status: WebKitHealthStatus(), events: events, minutes: minutes,
                                             natives: samples, probeEnabled: true, autoStop: true, now: Date(),
                                             device: "iPhone", app: "1.0", compact: true)
        let full = WebKitHealthReport.make(status: WebKitHealthStatus(), events: events, minutes: minutes,
                                          natives: samples, probeEnabled: true, autoStop: true, now: Date(), device: "iPhone", app: "1.0")
        XCTAssertTrue(compact.contains("95/95"), compact)
        XCTAssertTrue(compact.contains(minutes[0].start.ISO8601Format()))
        XCTAssertTrue(compact.contains(minutes[359].start.ISO8601Format()))
        XCTAssertTrue(full.contains(minutes[0].start.formatted(.dateTime.hour().minute().second())), full)
        XCTAssertLessThan(compact.count, 16_000)
        XCTAssertLessThan(compact.count * 5, full.count, "representative long history should shrink by at least 80%")
    }

    func testFullReportFileIsUTF8AndOwnsAnIsolatedDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = "term-llm health\nthermal warm → normal\nthreads main#42 70%\n"
        let first = try WebKitHealthReport.writeFile(text, directory: root)
        let second = try WebKitHealthReport.writeFile("second", directory: root)
        XCTAssertEqual(first.pathExtension, "txt")
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), text)
        XCTAssertNotEqual(first.deletingLastPathComponent(), second.deletingLastPathComponent())
        try FileManager.default.removeItem(at: first.deletingLastPathComponent())
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "second")
        XCTAssertThrowsError(try WebKitHealthReport.writeFile("blocked", directory: second))
    }

    /// Opening diagnostics hides Chat, so the report keeps what the page did on screen.
    func testReportKeepsTheLastOnScreenActivityOnceChatIsHidden() {
        var status = WebKitHealthStatus()
        status.latest = report(["vis": "hidden"])
        status.lastOnScreen = report(["vis": "visible", "frames": 300, "running": 1,
                                      "anims": [["name": "shimmer", "target": "div.row", "props": ["background-position-x"]]]])
        status.lastOnScreenAge = 12
        let text = WebKitHealthReport.make(status: status, events: [], minutes: [], natives: [], probeEnabled: true,
                                           autoStop: true, now: Date(), device: "iPhone", app: "1.0 (1)")
        XCTAssertTrue(text.contains("Last on-screen report (12 s ago): busy 0%, 60.0 frames/s, 1 running animations"), text)
        XCTAssertTrue(text.contains("shimmer on div.row [background-position-x] REPAINTS"), text)
    }
}

@MainActor
final class WebKitHealthMonitorTests: XCTestCase {
    private func monitor() -> WebKitHealthMonitor {
        WebKitHealthMonitor(defaults: UserDefaults(suiteName: "WebKitHealthTests-\(UUID().uuidString)")!, journal: nil)
    }

    func testSuspensionGapIsRejectedBeforeEitherTheReportOrNativeTickCanUseIt() throws {
        for reportFirst in [true, false] {
            let monitor = monitor()
            let web = WKWebView(frame: .zero)
            let session = monitor.makeSession(for: web, now: 0)
            session.contextProvider = { WebKitPageContext(userCanSee: true) }
            var stops: [WebKitTeardownReason] = []
            session.onTeardown = { reason, _ in stops.append(reason) }
            monitor.record(report(["vis": "visible"]), from: session, now: 0)
            monitor.tick(now: 0, native: native(0, device: 2))
            // Simulate delivery before UIKit's foreground notification, including
            // the report's 1049 s timer lateness from the user's diagnosis.
            let suspended = report(["vis": "visible", "span": 1_065_700,
                                    "late": 1_049_000, "maxLate": 1_049_000])
            if reportFirst { monitor.record(suspended, from: session, now: 1_065.7) }
            monitor.tick(now: 1_065.7, native: native(1_065.7, device: 2))
            if !reportFirst { monitor.record(suspended, from: session, now: 1_065.7) }
            XCTAssertNotNil(session.activityWindowID)
            XCTAssertNil(session.lastSampleAt)
            XCTAssertTrue(session.samples.isEmpty)
            for time in stride(from: 1_070.7, through: 1_130.7, by: 5) {
                monitor.tick(now: time, native: native(time, device: 2))
            }
            XCTAssertTrue(stops.isEmpty)
            XCTAssertFalse(monitor.events.contains { ["blocked", "stalled", "stop", "would-stop"].contains($0.kind) })
            XCTAssertFalse(monitor.status.findings.contains { ["busy", "stalled", "stop-unresponsive"].contains($0.id) })
            XCTAssertEqual(monitor.status.pageState, .waiting)
            XCTAssertTrue(session.webView === web, "suspension must preserve the retained Chat document")
            withExtendedLifetime(web) {}
        }
    }

    func testBackgroundAndForegroundRequireFreshWindowEvenForLateShortReports() throws {
        let monitor = monitor()
        let web = WKWebView(frame: .zero)
        let session = monitor.makeSession(for: web, now: 0)
        var context = WebKitPageContext(userCanSee: true)
        session.contextProvider = { context }
        var stops: [WebKitTeardownReason] = []
        session.onTeardown = { reason, _ in stops.append(reason) }
        let old = report(["vis": "visible", "maxLate": 3_000])
        monitor.record(report(["vis": "visible"]), from: session, now: 0)
        monitor.tick(now: 0, native: native(0, device: 2))
        context = WebKitPageContext(appBackground: true)
        monitor.applicationDidEnterBackground(now: 5)
        let backgroundWindow = try XCTUnwrap(session.activityWindowID)
        XCTAssertNil(session.lastSampleAt)
        XCTAssertTrue(session.samples.isEmpty)
        // This genuine background sample still cannot arm a future foreground stall.
        monitor.record(report(["window": backgroundWindow, "vis": "hidden"]), from: session, now: 10)
        XCTAssertEqual(session.lastSampleAt, 10)
        context = WebKitPageContext(userCanSee: true)
        monitor.applicationWillEnterForeground(now: 1_075)
        let foregroundWindow = try XCTUnwrap(session.activityWindowID)
        XCTAssertNotEqual(foregroundWindow, backgroundWindow)
        XCTAssertNil(session.lastSampleAt)
        for time in stride(from: 1_075.0, through: 1_140, by: 5) {
            // A short queued pre-background report cannot evade rejection merely
            // because enough time has passed since resume for its span to fit.
            monitor.record(old, from: session, now: time)
            monitor.record(report(["window": backgroundWindow, "vis": "visible"]), from: session, now: time)
            monitor.tick(now: time, native: native(time, device: 2))
        }
        XCTAssertTrue(stops.isEmpty)
        XCTAssertNil(session.lastSampleAt)
        XCTAssertFalse(monitor.events.contains { ["blocked", "stalled", "stop"].contains($0.kind) })
        monitor.record(report(["window": foregroundWindow, "vis": "visible"]), from: session, now: 1_145)
        XCTAssertEqual(session.lastSampleAt, 1_145)
        XCTAssertEqual(session.samples.count, 1)
        withExtendedLifetime(web) {}
    }

    func testContextTransitionBeforeNotificationRejectsQueuedReports() throws {
        let monitor = monitor()
        let web = WKWebView(frame: .zero)
        let session = monitor.makeSession(for: web, now: 0)
        var context = WebKitPageContext(userCanSee: true)
        session.contextProvider = { context }
        monitor.record(report(["vis": "visible"]), from: session, now: 0)
        context = WebKitPageContext(appBackground: true)
        monitor.record(report(["vis": "visible", "maxLate": 4_000]), from: session, now: 5)
        let beforeBackgroundNotification = try XCTUnwrap(session.activityWindowID)
        XCTAssertNil(session.lastSampleAt)
        monitor.applicationDidEnterBackground(now: 6)
        let backgroundWindow = try XCTUnwrap(session.activityWindowID)
        XCTAssertNotEqual(beforeBackgroundNotification, backgroundWindow)
        context = WebKitPageContext(userCanSee: true)
        monitor.record(report(["window": backgroundWindow, "vis": "visible", "maxLate": 4_000]),
                       from: session, now: 20)
        let beforeForegroundNotification = try XCTUnwrap(session.activityWindowID)
        XCTAssertNil(session.lastSampleAt)
        monitor.applicationWillEnterForeground(now: 21)
        XCTAssertNotEqual(beforeForegroundNotification, session.activityWindowID)
        monitor.record(report(["window": beforeForegroundNotification, "vis": "visible"]), from: session, now: 25)
        XCTAssertNil(session.lastSampleAt)
        XCTAssertFalse(monitor.events.contains { $0.kind == "blocked" })
        withExtendedLifetime(web) {}
    }

    func testFreshPostResumeHeartbeatArmsAGenuineSubsequentForegroundStall() throws {
        let monitor = monitor()
        let web = WKWebView(frame: .zero)
        let session = monitor.makeSession(for: web, now: 0)
        session.contextProvider = { WebKitPageContext(userCanSee: true) }
        var stops: [WebKitTeardownReason] = []
        session.onTeardown = { reason, _ in stops.append(reason) }
        monitor.record(report(["vis": "visible"]), from: session, now: 0)
        monitor.applicationWillEnterForeground(now: 1_075)
        let window = try XCTUnwrap(session.activityWindowID)
        monitor.record(report(["window": window, "vis": "visible"]), from: session, now: 1_080)
        for time in stride(from: 1_080.0, through: 1_130, by: 5) {
            monitor.tick(now: time, native: native(time, device: 2))
        }
        XCTAssertEqual(stops, [.unresponsive])
        XCTAssertTrue(monitor.events.contains { $0.kind == "stalled" && $0.message.contains("15 s") })
        XCTAssertEqual(monitor.events.filter { $0.kind == "stop" }.count, 1)
        withExtendedLifetime(web) {}
    }

    func testContinuousNativeSamplingStillRecordsALongForegroundBlockAfterResume() throws {
        let monitor = monitor()
        monitor.autoStopEnabled = false
        let web = WKWebView(frame: .zero)
        let session = monitor.makeSession(for: web, now: 0)
        session.contextProvider = { WebKitPageContext(userCanSee: true) }
        monitor.applicationWillEnterForeground(now: 1_000)
        let window = try XCTUnwrap(session.activityWindowID)
        monitor.record(report(["window": window, "vis": "visible"]), from: session, now: 1_005)
        for time in stride(from: 1_005.0, through: 1_095, by: 5) {
            monitor.tick(now: time, native: native(time, device: 2))
        }
        monitor.record(report(["window": window, "vis": "visible", "span": 90_000,
                               "late": 85_000, "maxLate": 85_000]), from: session, now: 1_095)
        XCTAssertEqual(session.activityWindowID, window)
        XCTAssertTrue(monitor.events.contains { $0.kind == "blocked" && $0.message.contains("85.0 s") })
        XCTAssertTrue(monitor.events.contains { $0.kind == "would-stop" })
        XCTAssertEqual(try XCTUnwrap(session.latest).busyFraction, 85.0 / 90.0, accuracy: 0.0001)
        for time in stride(from: 1_100.0, through: 1_125, by: 5) {
            monitor.record(report(["window": window, "vis": "visible", "late": 4_000, "maxLate": 4_000]),
                           from: session, now: time)
            monitor.tick(now: time, native: native(time, device: 2))
        }
        XCTAssertTrue(monitor.status.findings.contains { $0.id == "busy" }, "genuine post-resume busy reports still produce findings")
        withExtendedLifetime(web) {}
    }

    func testNewDocumentAfterResumeMustAlsoAcknowledgeTheCurrentWindow() throws {
        let monitor = monitor()
        let web = WKWebView(frame: .zero)
        let session = monitor.makeSession(for: web, now: 0)
        session.contextProvider = { WebKitPageContext(userCanSee: true) }
        monitor.applicationWillEnterForeground(now: 10)
        let window = try XCTUnwrap(session.activityWindowID)
        monitor.documentWillChange(session)
        monitor.record(report(["doc": "new-doc", "vis": "visible"]), from: session, now: 15)
        XCTAssertNil(session.lastSampleAt)
        monitor.record(report(["doc": "new-doc", "window": window, "vis": "visible"]), from: session, now: 20)
        XCTAssertEqual(session.documentID, "new-doc")
        XCTAssertEqual(session.lastSampleAt, 20)
        withExtendedLifetime(web) {}
    }

    func testRealSamplerReportsCounterIntervalAndThreadIdentities() throws {
        let sampler = ProcessUsageSampler()
        let first = sampler.sample(uptime: 10, appActive: true, appBackground: false)
        XCTAssertNil(first.cpuInterval)
        let tooSoon = sampler.sample(uptime: 10.2, appActive: true, appBackground: false)
        XCTAssertNil(tooSoon.cpuInterval)
        let next = sampler.sample(uptime: 11, appActive: true, appBackground: false)
        XCTAssertEqual(next.cpuInterval, 1)
        XCTAssertNotNil(next.appCPU)
        let threads = ProcessUsageSampler.busiestThreads(limit: 128, minimum: 0)
        let main = try XCTUnwrap(threads.first { $0.name == "main" || $0.name.hasPrefix("main:") })
        XCTAssertNotNil(main.threadID)
        XCTAssertEqual(Set(threads.compactMap(\.threadID)).count, threads.count)
    }

    func testCPUEvidenceSurvivesRecoveryAndIsRateLimited() {
        let monitor = monitor()
        let threads = [ThreadUsage(name: "main", cpu: 0.65, threadID: 42)]
        for time in stride(from: 0.0, through: 65, by: 5) {
            monitor.tick(now: time, native: native(time, app: time == 5 ? 0.95 : 0.8), threadUsage: threads)
        }
        let evidence = monitor.events.filter { $0.kind == "native-cpu" }
        XCTAssertEqual(evidence.count, 3, "first sample, 30 s, 60 s")
        XCTAssertEqual(evidence.first?.date, native(0).date)
        XCTAssertTrue(evidence[0].message.contains("main#42 65%"))
        XCTAssertTrue(evidence[0].message.contains("no chat page"))
        XCTAssertTrue(evidence[0].message.contains("over 5.0 s"))
        XCTAssertTrue(evidence[1].message.contains("episode peak 95%"))
        monitor.tick(now: 70, native: native(70, app: nil), threadUsage: [])
        XCTAssertEqual(monitor.events.filter { $0.kind == "native-cpu" }.count, 3, "missing CPU is not recovery")
        monitor.tick(now: 75, native: native(75), threadUsage: [])
        let text = monitor.report()
        XCTAssertTrue(text.contains("CPU episode ended at app 5%; observed span 75 s, peak 95%"), text)
        XCTAssertTrue(text.contains("main#42 65%"), "historical threads remain after current threads disappear")
        monitor.tick(now: 80, native: native(80, app: 0.4), threadUsage: [])
        XCTAssertEqual(monitor.events.filter { $0.kind == "native-cpu" }.count, 5, "new episode captures immediately")
        monitor.clearHistory()
        monitor.tick(now: 85, native: native(85, app: 0.4), threadUsage: [])
        XCTAssertEqual(monitor.events.filter { $0.kind == "native-cpu" }.count, 1)
    }

    func testCPUEvidenceIncludesStalePageAndProtectedWork() {
        let monitor = monitor()
        let web = WKWebView(frame: .zero)
        let session = monitor.makeSession(for: web, now: 0)
        session.contextProvider = {
            WebKitPageContext(userCanSee: false, inWindow: false, viewHidden: true,
                              capturing: true, voiceLaunching: true, toolCalls: 2)
        }
        monitor.record(report(["vis": "hidden"]), from: session, now: 0)
        monitor.tick(now: 90, native: native(90, app: 0.7), threadUsage: [])
        let evidence = monitor.events.first { $0.kind == "native-cpu" }?.message ?? ""
        XCTAssertTrue(evidence.contains("page report age 90 s"), evidence)
        XCTAssertTrue(evidence.contains("isHidden true"), evidence)
        XCTAssertTrue(evidence.contains("voiceLaunching true, toolCalls 2"), evidence)
        XCTAssertTrue(evidence.contains("none above 3% or unavailable"), evidence)
        withExtendedLifetime(web) {}
    }

    func testCPUEvidenceUsesExistingPersistentJournal() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = WebKitHealthJournal(directory: directory)
        let monitor = WebKitHealthMonitor(defaults: UserDefaults(suiteName: "HealthCPU-\(UUID().uuidString)")!, journal: journal)
        monitor.tick(now: 5, native: native(5, app: 0.8), threadUsage: [ThreadUsage(name: "main", cpu: 0.7, threadID: 99)])
        let events: [WebKitHealthEvent] = await withCheckedContinuation { continuation in
            journal.load { events, _ in continuation.resume(returning: events) }
        }
        XCTAssertTrue(events.contains { $0.kind == "native-cpu" && $0.message.contains("main#99 70%") })
    }

    private final class Stops { var reasons: [WebKitTeardownReason] = [] }

    private func drive(_ monitor: WebKitHealthMonitor, until end: TimeInterval) -> Stops {
        let stops = Stops()
        let web = WKWebView(frame: .zero)
        let session = monitor.makeSession(for: web, now: 0)
        session.contextProvider = { WebKitPageContext(userCanSee: false) }
        session.onTeardown = { reason, _ in stops.reasons.append(reason) }
        for time in stride(from: 0.0, through: end, by: 5) {
            monitor.record(report(["vis": "visible", "frames": 300, "seq": Int(time)]), from: session, now: time)
            monitor.tick(now: time, native: native(time))
        }
        withExtendedLifetime(web) {}
        return stops
    }

    func testStopsARunawayOffScreenPageOnceAndRecordsWhy() {
        let monitor = monitor()
        let stops = drive(monitor, until: 240)
        XCTAssertEqual(stops.reasons, [.hiddenActivity])
        let kinds = monitor.events.map(\.kind)
        XCTAssertTrue(kinds.contains("visibility"), "\(kinds)")
        XCTAssertEqual(kinds.filter { $0 == "stop" }.count, 1)
        XCTAssertTrue(kinds.contains("effect"), "records whether closing the page changed device CPU")
    }

    func testEffectCoversOnlyTheTimeThePageStayedClosed() throws {
        let monitor = monitor()
        let web = WKWebView(frame: .zero)
        let session = monitor.makeSession(for: web, now: 0)
        session.contextProvider = { WebKitPageContext(userCanSee: true) }
        var closes = 0
        session.onTeardown = { _, _ in closes += 1 }
        for time in stride(from: 0.0, through: 30, by: 5) { monitor.tick(now: time, native: native(time, device: 3)) }
        monitor.pausePage(now: 30)
        XCTAssertEqual(closes, 1)
        for time in stride(from: 35.0, through: 60, by: 5) { monitor.tick(now: time, native: native(time, device: 1)) }
        let page = WebKitParkedPage(reason: .manual, detail: "", restoreURL: nil, sourceID: nil,
                                    browserIdentity: nil, destinationID: nil)
        monitor.noteResumed(page, automatically: false, now: 62)
        // Samples after the reopen must not count, even once the window passes.
        for time in stride(from: 65.0, through: 90, by: 5) { monitor.tick(now: time, native: native(time, device: 5)) }
        let effects = monitor.events.filter { $0.kind == "effect" }.map(\.message)
        XCTAssertEqual(effects, ["After closing the page: device CPU 3.00 → 1.00 cores, app 0.05 → 0.05 cores."])
        withExtendedLifetime(web) {}
    }

    func testReopeningTooSoonSaysSo() {
        let monitor = monitor()
        let web = WKWebView(frame: .zero)
        let session = monitor.makeSession(for: web, now: 0)
        session.contextProvider = { WebKitPageContext(userCanSee: true) }
        monitor.tick(now: 0, native: native(0))
        monitor.pausePage(now: 5)
        monitor.tick(now: 10, native: native(10))
        monitor.noteResumed(WebKitParkedPage(reason: .manual, detail: "", restoreURL: nil, sourceID: nil,
                                             browserIdentity: nil, destinationID: nil), automatically: true, now: 15)
        XCTAssertEqual(monitor.events.filter { $0.kind == "effect" }.map(\.message),
                       ["Page reopened 10 s after closing, too soon to measure the effect."])
        withExtendedLifetime(web) {}
    }

    func testHiddenChatIsNotJudgedByReportsItSentOnScreen() {
        let monitor = monitor()
        let web = WKWebView(frame: .zero)
        let session = monitor.makeSession(for: web, now: 0)
        var context = WebKitPageContext(userCanSee: true, inWindow: true)
        session.contextProvider = { context }
        for time in stride(from: 0.0, through: 30, by: 5) {
            monitor.record(report(["vis": "visible", "seq": Int(time)]), from: session, now: time)
            monitor.tick(now: time, native: native(time))
        }
        // Chat leaves the window; WebKit throttles or suspends the hidden page.
        context = WebKitPageContext(userCanSee: false)
        for time in stride(from: 35.0, through: 95, by: 5) {
            monitor.tick(now: time, native: native(time))
            XCTAssertFalse(monitor.status.findings.contains { $0.id == "visibility" }, "at \(time) s")
            XCTAssertEqual(monitor.status.pageState, .offScreenQuiet, "at \(time) s")
        }
        XCTAssertFalse(monitor.events.contains { ["visibility", "finding"].contains($0.kind) },
                       "\(monitor.events.map(\.message))")
        // A report from the hidden page shows it is awake, and hidden as it should be.
        monitor.record(report(["vis": "hidden", "seq": 100]), from: session, now: 100)
        monitor.tick(now: 100, native: native(100))
        XCTAssertEqual(monitor.status.pageState, .offScreenAwake)
        XCTAssertFalse(monitor.status.findings.contains { $0.id == "visibility" })
        withExtendedLifetime(web) {}
    }

    func testOnlyRecordsWhatItWouldStopWhenStoppingIsOff() {
        let monitor = monitor()
        monitor.autoStopEnabled = false
        let stops = drive(monitor, until: 240)
        XCTAssertEqual(stops.reasons, [])
        XCTAssertEqual(monitor.events.filter { $0.kind == "would-stop" }.count, 1)
    }

    /// Watching must cost next to nothing: the monitor's whole 5 s sample
    /// (evaluation, findings, history) and a page report.
    func testMonitorWorkIsCheap() {
        let monitor = monitor()
        let web = WKWebView(frame: .zero)
        let session = monitor.makeSession(for: web, now: 0)
        session.contextProvider = { WebKitPageContext(userCanSee: true) }
        let iterations = 2_000
        let elapsed = ContinuousClock().measure {
            for index in 0..<iterations {
                let time = Double(index) * 5
                monitor.record(report(["vis": "visible", "frames": 30, "seq": index, "running": 1,
                                       "anims": [["name": "spin", "target": "div", "props": ["transform"]]]]),
                               from: session, now: time)
                monitor.tick(now: time, native: native(time))
            }
        }
        let perSample = elapsed / iterations
        let share = perSample / .seconds(WebKitHealthMonitor.interval)
        print("WebKit health: \(perSample) per 5 s sample = \(WebKitHealthReport.costText(share)) of a core")
        XCTAssertLessThan(perSample, .milliseconds(2), "a 5 s sample must stay far below 0.04% of a core")
        withExtendedLifetime(web) {}
    }

    func testReadingDeviceCountersIsCheap() {
        let sampler = ProcessUsageSampler()
        let iterations = 500
        let elapsed = ContinuousClock().measure {
            for _ in 0..<iterations { _ = sampler.sample(appActive: true, appBackground: false) }
        }
        let perSample = elapsed / iterations
        print("WebKit health: device counters \(perSample) per sample")
        XCTAssertLessThan(perSample, .milliseconds(1))
    }

    /// Back-to-back samples (a thermal change right after a timer tick) keep
    /// the baseline instead of reporting nothing for the next interval.
    func testRatesNeedHalfASecondButKeepTheirBaseline() async throws {
        let sampler = ProcessUsageSampler()
        XCTAssertNil(sampler.sample(appActive: true, appBackground: false).appCPU)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(sampler.sample(appActive: true, appBackground: false).appCPU)
        try await Task.sleep(for: .milliseconds(300))
        let sample = sampler.sample(appActive: true, appBackground: false)
        XCTAssertNotNil(sample.appCPU)
        XCTAssertNotNil(sample.wakeupsPerSecond)
        XCTAssertNotNil(sample.footprintMB)
    }
}

/// Renders the diagnostics screen with sample data in a real window, like
/// `ListenViewRenderingTests`; screenshots are attached to the test result.
@MainActor
final class WebKitHealthViewRenderingTests: XCTestCase {
    /// Chat drew on screen for a while, then this screen took it off screen.
    private func sampleMonitor(_ web: WKWebView) -> WebKitHealthMonitor {
        let monitor = WebKitHealthMonitor(defaults: UserDefaults(suiteName: "WebKitHealthRender-\(UUID().uuidString)")!,
                                          journal: nil)
        let session = monitor.makeSession(for: web, now: 0)
        var context = WebKitPageContext(userCanSee: true, inWindow: true)
        session.contextProvider = { context }
        monitor.record("native-cpu", "run 7145B9C4-E1AF-4B24-8F15-62BA171F5CC0; app 53% over 5.5 s; episode peak 53%; "
                       + "active true, background false; views 1, pages 1; [app 53% · device 3.4 cores · thermal normal]; "
                       + "wakeups 77/s; memory 120 MB; threads (recent decaying CPU): main#10042 41%")
        let threads = [ThreadUsage(name: "main", cpu: 0.14, threadID: 1),
                       ThreadUsage(name: "com.apple.NSURLConnectionLoader", cpu: 0.04, threadID: 2)]
        for time in stride(from: 0.0, through: 170, by: 5) {
            if time == 150 { context = WebKitPageContext(userCanSee: false) }
            if time < 150 {
                monitor.record(report(["vis": "visible", "frames": 140, "running": 1, "resources": 2, "seq": Int(time),
                                       "anims": [["name": "pulse", "target": "span.dot", "props": ["opacity"]]]]),
                               from: session, now: time)
            }
            monitor.tick(now: time, native: native(time, app: 0.08, device: 1.4, thermal: time >= 120 ? .fair : .nominal),
                         threadUsage: threads)
        }
        monitor.record("app", "Entered background. [app 3% · device 1.2 cores · thermal normal · chat off screen]")
        return monitor
    }

    private func render<Content: View>(_ view: Content, named name: String, scheme: ColorScheme) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        // Tall enough to lay out every section, not just the first screen.
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 3_400)
        window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousKeyWindow?.makeKey() }
        try await Task.sleep(for: .milliseconds(800))
        // The render server only snapshots on-screen windows; draw the layers
        // directly so the sections below the first screen are included too.
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { context in
            window.layer.render(in: context.cgContext)
        }
        let pixels = try XCTUnwrap(image.cgImage?.dataProvider?.data as Data?)
        // A blank-screen guard, not evidence of layout quality.
        XCTAssertTrue(stride(from: 0, to: max(0, pixels.count - 4), by: 4 * 97).contains {
            pixels[$0..<$0 + 4] != pixels.prefix(4)
        }, "\(name) rendered a blank screen")
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testHistoryEntriesLeadWithASummary() {
        func entry(_ kind: String, _ message: String) -> (title: String, body: String) {
            let entry = WebKitHealthView.historyEntry(WebKitHealthEvent(date: Date(), kind: kind, message: message))
            return (entry.title, entry.body)
        }
        let finding = entry("finding", "Page draws 28 frames/s. A requestAnimationFrame loop keeps rendering every frame.")
        XCTAssertEqual(finding.title, "Page draws 28 frames/s")
        XCTAssertEqual(finding.body, "A requestAnimationFrame loop keeps rendering every frame.")
        XCTAssertEqual(entry("app", "Returned to foreground.").title, "Back in foreground")
        XCTAssertEqual(entry("app", "Returned to foreground.").body, "")
        XCTAssertEqual(entry("app", "Entered background. [app 3%]").body, "[app 3%]")
        XCTAssertEqual(entry("native-cpu", "run 1; app 53%").title, "High app CPU")
        XCTAssertEqual(entry("native-cpu", "run 1; app 53%").body, "run 1; app 53%")
    }

    func testDiagnosticsScreen() async throws {
        let web = WKWebView(frame: .zero)
        let monitor = sampleMonitor(web)
        for (scheme, size) in [(ColorScheme.light, DynamicTypeSize.large), (.dark, .accessibility2)] {
            try await render(NavigationStack { WebKitHealthView(monitor: monitor, parked: nil, onReload: {}) }
                                .environment(\.dynamicTypeSize, size),
                             named: "webkit-health-\(scheme)-\(size)", scheme: scheme)
        }
        withExtendedLifetime(web) {}
    }
}
