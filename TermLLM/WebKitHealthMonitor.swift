import Foundation
import os
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import WebKit

let webKitHealthLog = Logger(subsystem: "com.termllm.app", category: "webkit-health")

/// One live browser view. The coordinator owns it; the monitor holds it weakly.
@MainActor
final class WebKitPageSession {
    let number: Int
    let created: TimeInterval
    weak var webView: WKWebView?
    var contextProvider: () -> WebKitPageContext = { WebKitPageContext() }
    var onTeardown: (WebKitTeardownReason, String) -> Void = { _, _ in }

    fileprivate(set) var context = WebKitPageContext()
    fileprivate(set) var documentID: String?
    fileprivate(set) var samples: [TimedPageSample] = []
    fileprivate(set) var lastSampleAt: TimeInterval?
    /// After a lifecycle boundary only reports echoing this native reset token
    /// may arm stall detection or contribute activity evidence.
    fileprivate(set) var activityWindowID: String?
    fileprivate(set) var hiddenSince: TimeInterval?
    fileprivate(set) var visibleSince: TimeInterval?
    fileprivate var stalled = false
    fileprivate var reportedMismatch = false
    fileprivate var teardownRequested = false
    fileprivate var wouldStop: WebKitTeardownReason?
    fileprivate var episodes: Set<String> = []
    fileprivate var lastLongBlock: TimeInterval = -.infinity

    init(number: Int, created: TimeInterval) {
        self.number = number
        self.created = created
        hiddenSince = created
    }

    var latest: WebPageHealthSample? { samples.last?.sample }
}

// MARK: - Monitor

/// Watches the chat page's web content and the device so a hot phone can be
/// explained, and stops a runaway page. Samples every 5 s in the foreground and
/// every 30 s while the app runs in the background (playing audio); the page
/// reports by itself through the injected probe. A sample is a handful of
/// system calls; the monitor times its own work (`status.monitorShare`).
@MainActor
final class WebKitHealthMonitor: ObservableObject {
    static let shared = WebKitHealthMonitor()
    static let probeKey = "webKitHealth.probe"
    static let autoStopKey = "webKitHealth.autoStop"
    static let interval: TimeInterval = 5
    static let backgroundInterval: TimeInterval = 30
    static let retention: TimeInterval = 30 * 60

    @Published var probeEnabled: Bool {
        didSet { defaults.set(probeEnabled, forKey: Self.probeKey) }
    }
    @Published var autoStopEnabled: Bool {
        didSet {
            defaults.set(autoStopEnabled, forKey: Self.autoStopKey)
            record("setting", "Stop runaway pages \(autoStopEnabled ? "on" : "off").")
        }
    }
    @Published private(set) var status = WebKitHealthStatus()
    @Published private(set) var events: [WebKitHealthEvent] = []
    @Published private(set) var minutes: [WebKitHealthMinute] = []
    /// The diagnostics screen is open: also break down this app's threads.
    var detailed = false

    var policy = WebKitHealthPolicy()
    private let defaults: UserDefaults
    private let journal: WebKitHealthJournal?
    private let sampler = ProcessUsageSampler()
    private let runID = UUID().uuidString
    private var timer: Timer?
    private var lastNativeTickAt: TimeInterval?
    private(set) var natives: [NativeHealthSample] = []
    private var sessionRefs: [WeakSession] = []
    private let webViews = NSHashTable<WKWebView>.weakObjects()
    private var nextSession = 1
    private var accumulator = MinuteAccumulator()
    private var pendingEffect: PendingEffect?
    private var extraWebViewsSince: TimeInterval?
    private var reportedExtraWebViews = false
    private var cpuEpisodeStarted: TimeInterval?
    private var lastCPUEvidenceAt: TimeInterval?
    private var cpuEpisodePeak: Double = 0
    private var lastThermal = ProcessInfo.processInfo.thermalState
    private var observers: [NSObjectProtocol] = []
    private var systemObservers: [(NotificationCenter, NSObjectProtocol)] = []
    /// Why the display cannot show the page right now (Mac sleep, display
    /// sleep, screen lock, another user's session). WebKit throttles or
    /// suspends the page then, so its silence says nothing about a hang.
    private(set) var displayPausedBy: Set<String> = []
    private var parked: WebKitParkedPage?
    /// Main-thread time spent in this monitor since `costSince`.
    private var costNanoseconds: UInt64 = 0
    private var costSince: UInt64?

    private struct WeakSession { weak var session: WebKitPageSession? }
    private struct PendingEffect {
        let reason: WebKitTeardownReason
        let at: TimeInterval
        let deviceBefore: Double?
        let appBefore: Double?
    }

    init(defaults: UserDefaults = HubFixture.defaults, journal: WebKitHealthJournal? = .standard()) {
        self.defaults = defaults
        self.journal = journal
        probeEnabled = defaults.object(forKey: Self.probeKey) as? Bool ?? true
        autoStopEnabled = defaults.object(forKey: Self.autoStopKey) as? Bool ?? true
    }

    var sessions: [WebKitPageSession] { sessionRefs.compactMap(\.session) }

    // MARK: Lifecycle

    func start() {
        guard timer == nil else { return }
        journal?.load { [weak self] events, minutes in
            Task { @MainActor in
                guard let self else { return }
                self.events = Array((events + self.events).suffix(300))
                self.minutes = Array((minutes + self.minutes).suffix(360))
            }
        }
        record("launch", "Run \(runID). App \(Self.appVersion) on \(Self.deviceModel) \(NativeDevice.platformName) \(NativeDevice.systemVersion), \(sampler.cpuCount) cores. "
               + "Probe \(probeEnabled ? "on" : "off"), stop runaway pages \(autoStopEnabled ? "on" : "off").")
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.thermalChanged() }
            },
            center.addObserver(forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.record("power", "Low Power Mode \(ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off").")
                }
            },
            center.addObserver(forName: NativeApp.didReceiveMemoryWarning, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.record("memory", "Memory warning. \(self?.snapshot() ?? "")") }
            },
            center.addObserver(forName: NativeApp.didEnterBackground, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.applicationDidEnterBackground()
                    // Only alive while playing audio; a coarse history is enough.
                    self.schedule(every: Self.backgroundInterval)
                }
            },
            center.addObserver(forName: NativeApp.willEnterForeground, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.applicationWillEnterForeground()
                    self.schedule(every: Self.interval)
                    self.tick()
                }
            },
        ]
        observeDisplayPauses()
        schedule(every: NativeApp.state == .background ? Self.backgroundInterval : Self.interval)
        tick()
    }

    private func observeDisplayPauses() {
        #if os(macOS)
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let events: [(NotificationCenter, Notification.Name, String, Bool)] = [
            (workspace, NSWorkspace.willSleepNotification, "sleep", true),
            (workspace, NSWorkspace.didWakeNotification, "sleep", false),
            (workspace, NSWorkspace.screensDidSleepNotification, "display", true),
            (workspace, NSWorkspace.screensDidWakeNotification, "display", false),
            (workspace, NSWorkspace.sessionDidResignActiveNotification, "session", true),
            (workspace, NSWorkspace.sessionDidBecomeActiveNotification, "session", false),
            (distributed, Notification.Name("com.apple.screenIsLocked"), "lock", true),
            (distributed, Notification.Name("com.apple.screenIsUnlocked"), "lock", false),
        ]
        systemObservers = events.map { center, name, cause, paused in
            (center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if paused { self?.displayDidPause(cause) } else { self?.displayDidResume(cause) }
                }
            })
        }
        #endif
    }

    /// The Mac slept, its display slept or locked: the page cannot be seen
    /// and WebKit stops running it, so stop judging its silence.
    func displayDidPause(_ cause: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard displayPausedBy.insert(cause).inserted else { return }
        invalidateActivityWindows(now: now)
        record("display", "Display paused (\(cause)).")
    }

    /// Back from a pause: the page must report afresh before its silence
    /// counts again, however long WebKit takes to resume it.
    func displayDidResume(_ cause: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard displayPausedBy.remove(cause) != nil else { return }
        invalidateActivityWindows(now: now)
        record("display", "Display resumed (\(cause)).")
    }

    /// Invalidate before doing any sampling or accepting queued page messages.
    /// UIKit's state and the browser's SwiftUI context may update in either order.
    func applicationDidEnterBackground(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        invalidateActivityWindows(now: now, background: true)
        record("app", "Entered background. \(snapshot())")
    }

    func applicationWillEnterForeground(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        invalidateActivityWindows(now: now, background: false)
        record("app", "Returned to foreground.")
    }

    private func invalidateActivityWindows(now: TimeInterval, background: Bool? = nil) {
        lastNativeTickAt = nil
        for session in sessions {
            if let background {
                session.context.appBackground = background
                if background { session.context.userCanSee = false }
            }
            invalidateActivityWindow(session, now: now)
        }
    }

    private func invalidateActivityWindow(_ session: WebKitPageSession, now: TimeInterval) {
        session.activityWindowID = UUID().uuidString
        session.samples.removeAll()
        session.lastSampleAt = nil
        session.hiddenSince = session.context.userCanSee ? nil : now
        session.visibleSince = session.context.userCanSee ? now : nil
        session.stalled = false
        session.reportedMismatch = false
        session.episodes.removeAll()
        session.wouldStop = nil
        session.lastLongBlock = -.infinity
        resetProbeWindow(session)
    }

    private func resetProbeWindow(_ session: WebKitPageSession) {
        guard let id = session.activityWindowID else { return }
        session.webView?.evaluateJavaScript(WebKitHealthProbe.resetScript(windowID: id), completionHandler: nil)
    }

    /// A suspended native timer can resume before the foreground notification or
    /// a queued script message. With no continuous native observations, neither
    /// page silence nor heartbeat lateness is evidence of foreground work.
    private func invalidateAfterSamplingGap(now: TimeInterval) {
        guard let last = lastNativeTickAt, now - last > Self.backgroundInterval * 2.5 else { return }
        invalidateActivityWindows(now: now)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        for (center, observer) in systemObservers { center.removeObserver(observer) }
        systemObservers = []
    }

    private func schedule(every interval: TimeInterval) {
        if let timer, timer.isValid, timer.timeInterval == interval { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Lets iOS coalesce the wakeup with others.
        timer.tolerance = interval / 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Adds the duration of monitor work started at `began` to its running cost.
    private func charge(since began: UInt64) {
        let end = DispatchTime.now().uptimeNanoseconds
        if costSince == nil { costSince = began }
        costNanoseconds &+= end >= began ? end - began : 0
    }

    /// Share of one core this monitor has used since its first sample.
    var monitorShare: Double? {
        guard let since = costSince else { return nil }
        let elapsed = DispatchTime.now().uptimeNanoseconds &- since
        return elapsed >= 1_000_000_000 ? Double(costNanoseconds) / Double(elapsed) : nil
    }

    // MARK: Browser views

    func makeSession(for webView: WKWebView, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> WebKitPageSession {
        let session = WebKitPageSession(number: nextSession, created: now)
        nextSession += 1
        session.webView = webView
        webViews.add(webView)
        sessionRefs.removeAll { $0.session == nil }
        sessionRefs.append(WeakSession(session: session))
        return session
    }

    func detach(_ session: WebKitPageSession) {
        sessionRefs.removeAll { $0.session == nil || $0.session === session }
        extraWebViewsSince = nil
        reportedExtraWebViews = false
    }

    /// Native state changed (SwiftUI update, capture, tool call): log
    /// visibility transitions promptly rather than at the next sample.
    func refresh(_ session: WebKitPageSession, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let began = DispatchTime.now().uptimeNanoseconds
        defer { charge(since: began) }
        invalidateAfterSamplingGap(now: now)
        update(session, context: session.contextProvider(), now: now)
    }

    func documentWillChange(_ session: WebKitPageSession) {
        session.documentID = nil
        session.samples.removeAll()
        session.lastSampleAt = nil
        session.stalled = false
        session.reportedMismatch = false
        session.episodes.removeAll()
    }

    func contentProcessTerminated(_ session: WebKitPageSession) {
        record("terminated", "WebKit's page process exited (crash, memory limit or iOS). \(snapshot(session))")
        documentWillChange(session)
    }

    func record(_ sample: WebPageHealthSample, from session: WebKitPageSession,
                now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard probeEnabled else { return }
        let began = DispatchTime.now().uptimeNanoseconds
        defer { charge(since: began) }
        invalidateAfterSamplingGap(now: now)
        update(session, context: session.contextProvider(), now: now)
        if let window = session.activityWindowID, sample.windowID != window {
            // This can be a queued old report, or a new document whose probe
            // has not received the reset yet. Neither arms the watchdog.
            resetProbeWindow(session)
            return
        }
        if session.documentID != sample.documentID {
            session.documentID = sample.documentID
            session.samples.removeAll()
            session.episodes.removeAll()
            session.reportedMismatch = false
        }
        session.samples.append(TimedPageSample(uptime: now, sample: sample))
        session.samples.removeAll { now - $0.uptime > 10 * 60 }
        session.lastSampleAt = now
        if session.stalled {
            session.stalled = false
            record("recovered", "Page health reports resumed.")
        }
        accumulator.add(sample)
        if sample.isVisible, !session.context.appBackground, sample.maxLateMilliseconds >= 2000, now - session.lastLongBlock >= 60 {
            session.lastLongBlock = now
            record("blocked", "Page main thread blocked for \(String(format: "%.1f", sample.maxLateMilliseconds / 1000)) s.")
        }
        let context = session.context
        if !session.reportedMismatch, WebKitHealthFindings.runsAsVisibleWhileHidden(
            session.samples, hiddenSince: session.hiddenSince, userCanSee: context.userCanSee) {
            session.reportedMismatch = true
            record("visibility", "Chat page off screen but WebKit still runs it as visible (view \(context.inWindow ? "in" : "not in") window\(context.viewHidden ? ", isHidden" : ""), app \(context.appBackground ? "background" : "foreground")). \(describe(sample))")
        }
    }

    /// Diagnostics "Pause": close the most relevant page's web view now.
    func pausePage(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard let session = primarySession() else { return }
        teardown(session, reason: .manual, detail: "Paused from diagnostics to see what closing the page changes.", now: now)
    }

    func noteParked(_ page: WebKitParkedPage) {
        parked = page
        status.parked = page
    }

    /// A stopped page that will not be reopened (its connection changed).
    func noteDiscarded(_ page: WebKitParkedPage) {
        if parked?.id == page.id { parked = nil }
        status.parked = parked
    }

    func noteResumed(_ page: WebKitParkedPage, automatically: Bool,
                     now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if parked?.id == page.id { parked = nil }
        status.parked = parked
        // The page is back: judge the close only by the time it stayed closed.
        finishEffect(until: now)
        record("resumed", automatically ? "Chat page reopened on return to Chat." : "Chat page reloaded.")
    }

    // MARK: Sampling

    func tick(now: TimeInterval = ProcessInfo.processInfo.systemUptime, native: NativeHealthSample? = nil,
              threadUsage: [ThreadUsage]? = nil) {
        let began = DispatchTime.now().uptimeNanoseconds
        defer { charge(since: began) }
        invalidateAfterSamplingGap(now: now)
        lastNativeTickAt = now
        let application = NativeApp.state
        let sample = native ?? sampler.sample(uptime: now, appActive: application == .active,
                                              appBackground: application == .background)
        natives.append(sample)
        natives.removeAll { now - $0.uptime > Self.retention }
        let current = sessions
        sessionRefs.removeAll { $0.session == nil }
        for session in current {
            update(session, context: session.contextProvider(), now: now)
            evaluate(session, now: now)
        }
        let alive = webViews.allObjects.count
        if alive > current.count {
            extraWebViewsSince = extraWebViewsSince ?? now
            if let since = extraWebViewsSince, now - since >= 15, !reportedExtraWebViews {
                reportedExtraWebViews = true
                record("leak", "\(alive - current.count) web view(s) still alive \(Int(now - since)) s after their browser closed.")
            }
        } else {
            extraWebViewsSince = nil
            reportedExtraWebViews = false
        }
        checkEffect(now: now)
        let threads = threadUsage ?? ((detailed || (sample.appCPU ?? 0) >= 0.3) ? ProcessUsageSampler.busiestThreads() : [])
        let primary = primarySession()
        recordCPUEvidence(sample: sample, threads: threads, primary: primary, alive: alive, now: now)
        if let finished = accumulator.add(sample, chatOnScreen: primary?.context.userCanSee ?? false, webViews: alive,
                                          monitorNanoseconds: costNanoseconds) {
            minutes.append(finished)
            if minutes.count > 360 { minutes.removeFirst(minutes.count - 360) }
            journal?.append(minute: finished)
        }
        publish(now: now, native: sample, primary: primary, threads: threads, alive: alive, pages: current.count)
    }

    /// Keep attribution after recovery/relaunch, not only while diagnostics is open.
    /// Public thread counters are a decaying estimate, not stacks or interval CPU.
    private func recordCPUEvidence(sample: NativeHealthSample, threads: [ThreadUsage],
                                   primary: WebKitPageSession?, alive: Int, now: TimeInterval) {
        guard let cpu = sample.appCPU else { return }
        if cpu >= 0.3 {
            cpuEpisodeStarted = cpuEpisodeStarted ?? now
            cpuEpisodePeak = max(cpuEpisodePeak, cpu)
            guard lastCPUEvidenceAt.map({ now - $0 >= 30 }) ?? true else { return }
            lastCPUEvidenceAt = now
            let interval = sample.cpuInterval.map { String(format: "%.1f", $0) } ?? "unknown"
            var parts = ["run \(runID)", "app \(WebKitHealthFindings.percent(cpu)) over \(interval) s",
                         "episode peak \(WebKitHealthFindings.percent(cpuEpisodePeak))",
                         "active \(sample.appActive), background \(sample.appBackground)",
                         "views \(alive), pages \(sessions.count)", snapshot(primary)]
            let listenUsage = ListenNetworkUsage.shared.snapshot(now: sample.date)
            parts.append("Listen received \(listenUsage.recentBytes) B in last 60 s (managed media, this run only)")
            if let wakeups = sample.wakeupsPerSecond { parts.append("wakeups \(Int(wakeups))/s") }
            if let memory = sample.footprintMB { parts.append("memory \(Int(memory)) MB") }
            if let primary {
                let c = primary.context
                parts.append("inWindow \(c.inWindow), isHidden \(c.viewHidden), loading \(c.loading), signingIn \(c.signingIn), voiceLaunching \(c.voiceLaunching), toolCalls \(c.toolCalls)")
                parts.append(primary.lastSampleAt.map { "page report age \(Int(max(0, now - $0))) s" } ?? "no page report")
                if let page = primary.latest {
                    parts.append("requests \(Int(page.resourcesPerMinute.rounded()))/min, WebRTC \(page.peerConnections), WebSocket \(page.webSockets), EventSource \(page.eventSources), media \(page.mediaPlaying)")
                }
            } else {
                parts.append("no chat page")
            }
            parts.append("threads (recent decaying CPU): " + (threads.isEmpty ? "none above 3% or unavailable" : threads.map {
                "\($0.label) \(WebKitHealthFindings.percent($0.cpu))"
            }.joined(separator: ", ")))
            record("native-cpu", parts.joined(separator: "; "), date: sample.date)
        } else if let started = cpuEpisodeStarted {
            record("native-cpu", "CPU episode ended at app \(WebKitHealthFindings.percent(cpu)); observed span \(Int(max(0, now - started))) s, peak \(WebKitHealthFindings.percent(cpuEpisodePeak)). Run \(runID). Gaps may include suspension.", date: sample.date)
            cpuEpisodeStarted = nil
            lastCPUEvidenceAt = nil
            cpuEpisodePeak = 0
        }
    }

    private func update(_ session: WebKitPageSession, context: WebKitPageContext, now: TimeInterval) {
        let previous = session.context
        session.context = context
        if previous.appBackground != context.appBackground {
            invalidateActivityWindow(session, now: now)
        }
        if context.userCanSee {
            if session.visibleSince == nil { session.visibleSince = now }
            session.hiddenSince = nil
            session.wouldStop = nil
        } else {
            if session.hiddenSince == nil { session.hiddenSince = now }
            session.visibleSince = nil
            session.stalled = false
        }
        if previous.capturing != context.capturing {
            record("capture", context.capturing ? "Page started using the microphone/camera." : "Page stopped using the microphone/camera.")
        }
    }

    private func evaluate(_ session: WebKitPageSession, now: TimeInterval) {
        guard !session.teardownRequested else { return }
        let thermal = natives.last?.thermal ?? ProcessInfo.processInfo.thermalState
        switch policy.verdict(.init(now: now, context: session.context, hiddenSince: session.hiddenSince,
                                    visibleSince: session.visibleSince, lastSampleAt: session.lastSampleAt,
                                    armed: isArmed(session), samples: session.samples,
                                    thermal: thermal)) {
        case .healthy:
            break
        case .stalled(let seconds):
            if !session.stalled {
                session.stalled = true
                record("stalled", "No page health report for \(Int(seconds)) s while on screen. \(snapshot(session))")
            }
        case .teardown(let reason, let detail):
            if autoStopEnabled {
                teardown(session, reason: reason, detail: detail, now: now)
            } else if session.wouldStop != reason {
                session.wouldStop = reason
                record("would-stop", "Would stop the page (stop runaway pages is off): \(detail) \(snapshot(session))")
            }
        }
    }

    private func teardown(_ session: WebKitPageSession, reason: WebKitTeardownReason, detail: String, now: TimeInterval) {
        guard !session.teardownRequested else { return }
        session.teardownRequested = true
        let window = natives.filter { now - $0.uptime <= 60 }
        pendingEffect = PendingEffect(reason: reason, at: now,
                                      deviceBefore: optionalAverage(window.compactMap(\.deviceCPU)),
                                      appBefore: optionalAverage(window.compactMap(\.appCPU)))
        record("stop", "\(reason == .manual ? "Paused" : "Stopped") the chat page (\(reason.rawValue)): \(detail) \(snapshot(session))")
        webKitHealthLog.notice("Closing chat page web view: \(reason.rawValue, privacy: .public)")
        session.onTeardown(reason, detail)
    }

    private func checkEffect(now: TimeInterval) {
        guard let effect = pendingEffect, now - effect.at >= 40 else { return }
        finishEffect(until: now)
    }

    /// Records whether closing the page actually changed device CPU: the
    /// minute before against the time it stayed closed (from 10 s after).
    private func finishEffect(until end: TimeInterval) {
        guard let effect = pendingEffect else { return }
        pendingEffect = nil
        let after = natives.filter { $0.uptime > effect.at + 10 && $0.uptime <= end }
        guard after.count >= 2 else {
            record("effect", "Page reopened \(Int(end - effect.at)) s after closing, too soon to measure the effect.")
            return
        }
        func format(_ before: Double?, _ after: Double?) -> String {
            guard let before, let after else { return "n/a" }
            return String(format: "%.2f → %.2f cores", before, after)
        }
        record("effect", "After closing the page: device CPU \(format(effect.deviceBefore, optionalAverage(after.compactMap(\.deviceCPU)))), app \(format(effect.appBefore, optionalAverage(after.compactMap(\.appCPU)))).")
    }

    private func thermalChanged() {
        let state = ProcessInfo.processInfo.thermalState
        guard state != lastThermal else { return }
        let previous = lastThermal
        lastThermal = state
        record("thermal", "Thermal state \(WebKitHealthPolicy.thermalName(previous).lowercased()) → \(WebKitHealthPolicy.thermalName(state).lowercased()). \(snapshot())")
        tick()
    }

    /// Only expect reports after the current document has started sending them.
    private func isArmed(_ session: WebKitPageSession) -> Bool {
        session.documentID != nil && probeEnabled && displayPausedBy.isEmpty
    }

    private func primarySession() -> WebKitPageSession? {
        let current = sessions
        return current.first { $0.context.userCanSee } ?? current.max { $0.created < $1.created }
    }

    private func publish(now: TimeInterval, native: NativeHealthSample, primary: WebKitPageSession?,
                         threads: [ThreadUsage], alive: Int, pages: Int) {
        var next = WebKitHealthStatus()
        next.native = native
        let minute = natives.filter { now - $0.uptime <= 65 }
        next.appCPUMinute = optionalAverage(minute.compactMap(\.appCPU))
        next.deviceCPUMinute = optionalAverage(minute.compactMap(\.deviceCPU))
        next.threads = threads
        next.webViewsAlive = alive
        next.pages = pages
        next.parked = parked
        next.monitorShare = monitorShare
        var page: WebKitHealthFindings.Page?
        if let primary {
            let verdict = policy.verdict(.init(now: now, context: primary.context, hiddenSince: primary.hiddenSince,
                                               visibleSince: primary.visibleSince, lastSampleAt: primary.lastSampleAt,
                                               armed: isArmed(primary), samples: primary.samples,
                                               thermal: native.thermal))
            next.context = primary.context
            next.latest = primary.latest
            next.lastReportAge = primary.lastSampleAt.map { now - $0 }
            if let visible = primary.samples.last(where: { $0.sample.isVisible }) {
                next.lastOnScreen = visible.sample
                next.lastOnScreenAge = now - visible.uptime
            }
            // On screen the probe reports every 5 s, hidden every 15 s. Off screen,
            // only a report sent after hiding shows the page is still awake.
            let reporting = primary.lastSampleAt.map { last in
                primary.context.userCanSee ? now - last <= 15
                    : now - last <= 40 && primary.hiddenSince.map { last - $0 >= 2 } ?? true
            } ?? false
            // The page clock has 1 ms steps: average over all of this page's
            // retained reports (up to 10 min) rather than the last few.
            let reports = primary.samples.map(\.sample)
            let span = reports.reduce(0) { $0 + $1.spanSeconds }
            next.probeShare = span >= 1 ? reports.reduce(0) { $0 + $1.probeMilliseconds } / 1000 / span : nil
            if case .stalled(let seconds) = verdict {
                next.pageState = .stalled(seconds)
            } else if primary.context.loading {
                next.pageState = .loading
            } else if !primary.context.userCanSee {
                next.pageState = reporting ? .offScreenAwake : .offScreenQuiet
            } else {
                next.pageState = reporting ? .active : .waiting
            }
            page = .init(context: primary.context, samples: primary.samples, hiddenSince: primary.hiddenSince, verdict: verdict)
        }
        next.findings = WebKitHealthFindings.evaluate(natives: natives, page: page, threads: threads,
                                                      webViewsAlive: alive, pages: pages, now: now)
        for finding in next.findings where finding.severity >= .warning {
            guard let primary, ["busy", "frames", "audio", "animations", "visibility"].contains(finding.id) else { continue }
            if primary.episodes.insert(finding.id).inserted {
                record("finding", "\(finding.title). \(finding.detail)")
            }
        }
        if let primary {
            let active = Set(next.findings.map(\.id))
            primary.episodes = primary.episodes.filter { active.contains($0) }
        }
        if status != next { status = next }
    }

    // MARK: Journal

    func record(_ kind: String, _ message: String, date: Date = Date()) {
        let event = WebKitHealthEvent(date: date, kind: kind, message: message)
        events.append(event)
        if events.count > 300 { events.removeFirst(events.count - 300) }
        journal?.append(event: event)
        webKitHealthLog.info("[\(kind, privacy: .public)] \(message, privacy: .public)")
    }

    func clearHistory() {
        events = []
        minutes = []
        journal?.clear()
        cpuEpisodeStarted = nil
        lastCPUEvidenceAt = nil
        cpuEpisodePeak = 0
    }

    /// One line of current context for events.
    func snapshot(_ session: WebKitPageSession? = nil) -> String {
        var parts: [String] = []
        if let native = natives.last {
            if let app = native.appCPU { parts.append("app \(WebKitHealthFindings.percent(app))") }
            if let device = native.deviceCPU { parts.append(String(format: "device %.1f cores", device)) }
            parts.append("thermal \(WebKitHealthPolicy.thermalName(native.thermal).lowercased())")
        }
        if let page = session ?? primarySession() {
            parts.append(page.context.userCanSee ? "chat on screen" : "chat off screen")
            if page.context.capturing { parts.append("capturing") }
            if let latest = page.latest { parts.append(describe(latest)) }
        }
        return parts.isEmpty ? "" : "[" + parts.joined(separator: " · ") + "]"
    }

    func describe(_ sample: WebPageHealthSample) -> String {
        var parts = ["page \(sample.visibility)", "busy \(WebKitHealthFindings.percent(sample.busyFraction))",
                     "\(Int(sample.framesPerSecond.rounded())) fps", "\(sample.runningAnimations) anim"]
        if !sample.repaintingAnimations.isEmpty { parts.append("\(sample.repaintingAnimations.count) repainting") }
        if sample.audioContextsRunning > 0 { parts.append("\(sample.audioContextsRunning) audio") }
        if sample.liveTracks > 0 { parts.append("\(sample.liveTracks) tracks") }
        parts.append("\(Int(sample.mutationsPerSecond.rounded())) mut/s")
        return parts.joined(separator: " ")
    }

    func report(now: Date = Date(), compact: Bool = false) -> String {
        WebKitHealthReport.make(status: status, events: events, minutes: minutes, natives: natives,
                                probeEnabled: probeEnabled, autoStop: autoStopEnabled, now: now,
                                device: "\(Self.deviceModel) \(NativeDevice.platformName) \(NativeDevice.systemVersion)", app: Self.appVersion, compact: compact,
                                listenUsage: ListenNetworkUsage.shared.snapshot(now: now))
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    static var deviceModel: String {
        WebKitHealthProbe.token(NativeDevice.modelIdentifier, limit: 32) ?? NativeDevice.model
    }
}

func optionalAverage(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
