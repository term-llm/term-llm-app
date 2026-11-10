import Foundation
import os
#if os(iOS)
import UIKit
#endif
import WebKit

let webKitHealthLog = Logger(subsystem: "com.termllm.app", category: "webkit-health")

enum WebKitTeardownReason: String, Codable, Sendable, Equatable {
    case unresponsive
    case hiddenActivity = "hidden_activity"
    case thermal
    case manual

    var title: String {
        switch self {
        case .unresponsive: "The chat page stopped responding"
        case .hiddenActivity: "The chat page kept working off screen"
        case .thermal: "The phone was hot"
        case .manual: "Chat page paused"
        }
    }

    /// Off-screen stops reopen by themselves when Chat is shown again; a hung
    /// or manually paused page waits for an explicit reload (no reload loops).
    var resumesAutomatically: Bool { self == .hiddenActivity || self == .thermal }
}

/// A chat page whose web view was closed to stop its web process.
struct WebKitParkedPage: Equatable {
    let id = UUID()
    let reason: WebKitTeardownReason
    let detail: String
    let restoreURL: URL?
    let sourceID: UUID?
    let browserIdentity: UUID?
    /// Native destination at the time; a newer one (another chat) wins on resume.
    let destinationID: UUID?
    let date = Date()
}

/// Native facts about a browser view that its page cannot report itself.
struct WebKitPageContext: Equatable, Sendable {
    /// On screen in the active app and not covered by sign-in or error screens.
    var userCanSee = false
    var appBackground = false
    var inWindow = false
    var viewHidden = false
    var capturing = false
    var voiceLaunching = false
    var toolCalls = 0
    var signingIn = false
    var loading = false

    /// Work a teardown would break: a live call, a voice launch, a device tool reply, sign-in.
    var protectsPage: Bool { capturing || voiceLaunching || toolCalls > 0 || signingIn }
}

struct TimedPageSample: Equatable, Sendable {
    let uptime: TimeInterval
    let sample: WebPageHealthSample
}

struct WebKitHealthEvent: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    let date: Date
    let kind: String
    let message: String
}

struct WebKitHealthFinding: Identifiable, Equatable, Sendable {
    enum Severity: Int, Comparable, Sendable {
        case info, warning, critical
        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }
    let id: String
    let severity: Severity
    let title: String
    let detail: String
}

/// One wall-clock minute, kept for a few hours and persisted across launches.
struct WebKitHealthMinute: Codable, Equatable, Sendable {
    var start: Date
    var app: Double?
    var appPeak: Double?
    var device: Double?
    var devicePeak: Double?
    var thermal: Int
    var battery: Int?
    var charging: Bool?
    var foreground: Double
    var chatOnScreen: Double
    var pageReports: Int
    var pageVisible: Double?
    var busy: Double?
    var fps: Double?
    var animations: Int?
    var repainting: Int?
    var mutations: Double?
    var requests: Double?
    var audio: Int?
    var webViews: Int
    var memoryMB: Int?
    /// Share of one core the page probe used.
    var probe: Double?
    /// Share of one core this monitor used in the app process.
    var monitor: Double?
}

/// Everything the diagnostics screen shows, refreshed every sample.
struct WebKitHealthStatus: Equatable {
    enum PageState: Equatable {
        case none
        case loading
        case waiting
        case active
        case stalled(TimeInterval)
        case offScreenAwake
        case offScreenQuiet
    }

    var native: NativeHealthSample?
    var appCPUMinute: Double?
    var deviceCPUMinute: Double?
    var pageState: PageState = .none
    var context = WebKitPageContext()
    var latest: WebPageHealthSample?
    var lastReportAge: TimeInterval?
    /// Opening diagnostics takes Chat off screen, so also keep what the page
    /// last reported while it was visible.
    var lastOnScreen: WebPageHealthSample?
    var lastOnScreenAge: TimeInterval?
    var findings: [WebKitHealthFinding] = []
    var threads: [ThreadUsage] = []
    var webViewsAlive = 0
    var pages = 0
    var parked: WebKitParkedPage?
    /// What watching costs, as a share of one core: this monitor's own work in
    /// the app since launch, and the page probe over the last minute.
    var monitorShare: Double?
    var probeShare: Double?
}

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

// MARK: - Policy

/// Pure decisions, unit tested without WebKit.
struct WebKitHealthPolicy: Sendable {
    /// Off screen this long before its activity counts against it.
    var hiddenGrace: TimeInterval = 60
    /// Activity must last this long (in most reports) before a stop.
    var activityWindow: TimeInterval = 120
    var activityShare = 0.8
    var minimumReports = 6
    var stallAfter: TimeInterval = 15
    var unresponsiveAfter: TimeInterval = 45
    /// A silent page is only stopped while something outside the app burns
    /// at least this many cores: a page paused in Web Inspector or deadlocked
    /// costs no power, an endless loop does.
    var stuckCores = 0.5
    var thermalGrace: TimeInterval = 30

    enum Verdict: Equatable {
        case healthy
        case stalled(TimeInterval)
        case teardown(WebKitTeardownReason, String)
    }

    struct Input {
        var now: TimeInterval
        var context: WebKitPageContext
        var hiddenSince: TimeInterval?
        var visibleSince: TimeInterval?
        var lastSampleAt: TimeInterval?
        var armed: Bool
        var samples: [TimedPageSample]
        var thermal: ProcessInfo.ThermalState
        /// Recent average cores busy outside this app (WebKit's processes,
        /// iOS); nil when the device counters are unavailable.
        var outsideAppCPU: Double? = nil
    }

    struct Activity: Equatable, Sendable {
        enum Kind: String, Sendable { case frames, animations, busy, mutations, requests, audio }
        let kind: Kind
        let text: String
    }

    /// Why an off-screen page is costing power; empty when it is quiet.
    /// A page WebKit has hidden draws nothing and its timers are throttled,
    /// so DOM changes alone (a response that offers device tools keeps
    /// streaming while hidden) do not count; drawing, polling and audio do.
    func offScreenActivity(_ sample: WebPageHealthSample, capturing: Bool) -> [Activity] {
        var reasons: [Activity] = []
        if sample.framesPerSecond >= 1 {
            reasons.append(.init(kind: .frames, text: "drew \(Int(sample.framesPerSecond.rounded())) frames/s"))
        }
        if sample.isVisible, sample.runningAnimations > 0 {
            reasons.append(.init(kind: .animations, text: "ran \(sample.runningAnimations) animation\(sample.runningAnimations == 1 ? "" : "s") as if on screen"))
        }
        // Heartbeat lateness is only measured while WebKit reports the page visible.
        if sample.busyFraction >= 0.25 {
            reasons.append(.init(kind: .busy, text: "kept its main thread \(Int((sample.busyFraction * 100).rounded()))% busy"))
        }
        if sample.isVisible, sample.mutationsPerSecond >= 20 {
            reasons.append(.init(kind: .mutations, text: "changed its DOM \(Int(sample.mutationsPerSecond.rounded())) times/s"))
        }
        if sample.resourcesPerMinute >= 30 {
            reasons.append(.init(kind: .requests, text: "made \(Int(sample.resourcesPerMinute.rounded())) requests/min"))
        }
        if sample.audioContextsRunning > 0, !capturing {
            reasons.append(.init(kind: .audio, text: "kept its audio engine running without a call"))
        }
        return reasons
    }

    func verdict(_ input: Input) -> Verdict {
        let context = input.context
        // A hung page is checked only while the user is looking at it: hidden
        // and suspended pages legitimately stop reporting.
        if context.userCanSee, !context.appBackground, !context.loading, input.armed, let last = input.lastSampleAt,
           let visibleSince = input.visibleSince {
            let silent = input.now - max(last, visibleSince)
            if silent >= unresponsiveAfter, !context.signingIn, let busy = input.outsideAppCPU, busy >= stuckCores {
                return .teardown(.unresponsive, "No response from the page for \(Int(silent)) s while on screen, "
                                 + String(format: "with %.1f cores busy outside the app.", busy))
            }
            if silent >= stallAfter { return .stalled(silent) }
        }
        guard let hiddenSince = input.hiddenSince, !context.userCanSee, !context.protectsPage else { return .healthy }
        let hidden = input.now - hiddenSince
        // Media the page plays may be what the user is listening to.
        if input.samples.last?.sample.mediaPlaying ?? 0 > 0 { return .healthy }
        // A hidden page reports every 15 s while awake; a suspended one is not the cause.
        if input.thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue, hidden >= thermalGrace,
           let last = input.lastSampleAt, input.now - last <= 45 {
            return .teardown(.thermal, "The phone is \(Self.thermalName(input.thermal).lowercased()) and the off-screen chat page was still running.")
        }
        guard hidden >= hiddenGrace else { return .healthy }
        let from = max(input.now - activityWindow, hiddenSince + 5)
        let window = input.samples.filter { $0.uptime >= from }
        guard window.count >= minimumReports, let first = window.first,
              input.now - first.uptime >= activityWindow * 0.75 else { return .healthy }
        let reasons = window.map { offScreenActivity($0.sample, capturing: context.capturing) }
        let active = reasons.filter { !$0.isEmpty }.count
        guard Double(active) / Double(window.count) >= activityShare else { return .healthy }
        // Describe each kind of activity once, using its latest wording.
        var latest: [Activity.Kind: String] = [:]
        var order: [Activity.Kind] = []
        for activity in reasons.flatMap({ $0 }) {
            if latest[activity.kind] == nil { order.append(activity.kind) }
            latest[activity.kind] = activity.text
        }
        let summary = order.prefix(3).compactMap { latest[$0] }.joined(separator: ", ")
        return .teardown(.hiddenActivity, "Off screen for \(Int(hidden / 60)) min, the page \(summary).")
    }

    static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "Normal"
        case .fair: "Warm"
        case .serious: "Hot"
        case .critical: "Very hot"
        @unknown default: "Unknown"
        }
    }
}

// MARK: - Findings

enum WebKitHealthFindings {
    struct Page {
        var context: WebKitPageContext
        var samples: [TimedPageSample]
        var hiddenSince: TimeInterval?
        var verdict: WebKitHealthPolicy.Verdict
    }

    /// What looks wrong right now, most severe first. Thresholds are meant to
    /// flag sustained cost, not momentary spikes.
    static func evaluate(natives: [NativeHealthSample], page: Page?, threads: [ThreadUsage],
                         webViewsAlive: Int, pages: Int, now: TimeInterval) -> [WebKitHealthFinding] {
        var findings: [WebKitHealthFinding] = []
        let minute = natives.filter { now - $0.uptime <= 65 }
        if let latest = natives.last, latest.thermal.rawValue >= ProcessInfo.ThermalState.fair.rawValue {
            let name = WebKitHealthPolicy.thermalName(latest.thermal)
            findings.append(.init(id: "thermal", severity: latest.thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue ? .critical : .warning,
                                  title: "Phone is \(name.lowercased())", detail: "iOS reports the thermal state as \(name.lowercased())."))
        }
        let appValues = minute.compactMap(\.appCPU)
        if appValues.count >= 6, average(appValues) >= 0.5 {
            let top = threads.prefix(3).map { "\($0.name) \(percent($0.cpu))" }.joined(separator: ", ")
            findings.append(.init(id: "app-cpu", severity: .warning, title: "App process busy (\(percent(average(appValues))) CPU)",
                                  detail: top.isEmpty ? "The native app itself is using the CPU, not WebKit." : "Busiest threads: \(top)."))
        }
        let otherValues = minute.compactMap(\.otherCPU)
        if otherValues.count >= 6, average(otherValues) >= 1.5 {
            findings.append(.init(id: "other-cpu", severity: .warning,
                                  title: "Other processes busy (\(String(format: "%.1f", average(otherValues))) cores)",
                                  detail: "Work outside this app: WebKit, graphics or iOS itself."))
        }
        if webViewsAlive > pages {
            findings.append(.init(id: "web-views", severity: .warning, title: "\(count(webViewsAlive - pages, "closed web view")) still alive",
                                  detail: "A closed browser should release its web view and page process."))
        }
        guard let page else { return findings.sorted { $0.severity > $1.severity } }
        switch page.verdict {
        case .stalled(let seconds):
            findings.append(.init(id: "stalled", severity: .critical, title: "Page not responding (\(Int(seconds)) s)",
                                  detail: "The page's main thread is blocked."))
        case .teardown(let reason, let detail):
            findings.append(.init(id: "stop-" + reason.rawValue, severity: .critical, title: reason.title, detail: detail))
        case .healthy:
            break
        }
        let recentReports = page.samples.filter { now - $0.uptime <= 65 }
        let recent = recentReports.map(\.sample)
        guard let latest = recent.last else { return findings.sorted { $0.severity > $1.severity } }
        if runsAsVisibleWhileHidden(recentReports, hiddenSince: page.hiddenSince, userCanSee: page.context.userCanSee) {
            findings.append(.init(id: "visibility", severity: .warning, title: "Hidden page runs at full speed",
                                  detail: "WebKit still treats the chat page as visible, so its timers and animations aren't slowed."))
        }
        let visible = recent.filter(\.isVisible)
        if visible.count >= 6 {
            let busy = average(visible.map(\.busyFraction))
            if busy >= 0.5 {
                let longest = (visible.map(\.maxLateMilliseconds).max() ?? 0) / 1000
                findings.append(.init(id: "busy", severity: .warning, title: "Page main thread \(percent(busy)) busy",
                                      detail: "Long main-thread tasks; the longest took \(String(format: "%.1f", longest)) s."))
            }
            let fps = average(visible.map(\.framesPerSecond))
            if fps >= 20 {
                findings.append(.init(id: "frames", severity: .warning, title: "Page draws \(Int(fps.rounded())) frames/s",
                                      detail: "A requestAnimationFrame loop keeps rendering every frame."))
            }
            if visible.allSatisfy({ $0.runningAnimations > 0 }) {
                let animations = visible.last?.animations ?? []
                let repainting = animations.filter { !$0.composited }
                let composited = animations.filter(\.composited)
                var detail: [String] = []
                if !repainting.isEmpty { detail.append("Repaint every frame: " + describe(repainting) + ".") }
                if !composited.isEmpty { detail.append("Compositor only: " + describe(composited) + ".") }
                findings.append(.init(id: "animations", severity: repainting.isEmpty ? .info : .warning,
                                      title: "\(count(visible.last?.runningAnimations ?? 0, "animation")) running continuously",
                                      detail: detail.joined(separator: " ")))
            }
        }
        if recent.count >= 6, recent.allSatisfy({ $0.audioContextsRunning > 0 }), !page.context.capturing {
            findings.append(.init(id: "audio", severity: .warning, title: "Audio engine running without a call",
                                  detail: "Web Audio keeps the audio hardware and its render thread active."))
        }
        let connections = latest.webSockets + latest.eventSources
        if connections >= 5 || latest.peerConnections >= 2 {
            findings.append(.init(id: "connections", severity: .info, title: "\(connections + latest.peerConnections) open connections",
                                  detail: "\(latest.webSockets) WebSocket, \(latest.eventSources) EventSource, \(latest.peerConnections) WebRTC."))
        }
        if let nodes = latest.domNodes, nodes >= 30_000 {
            findings.append(.init(id: "dom", severity: .info, title: "Large page (\(nodes.formatted()) elements)",
                                  detail: "Style and layout cost grows with the document."))
        }
        return findings.sorted { $0.severity > $1.severity }
    }

    /// WebKit keeps running a page the user cannot see as visible: the last
    /// two reports that arrived 10 s or more after it was hidden both say so.
    /// A report sent while it was still on screen is not evidence (a hidden
    /// page usually goes quiet as WebKit throttles or suspends it), and
    /// neither is a single late report.
    static func runsAsVisibleWhileHidden(_ reports: [TimedPageSample], hiddenSince: TimeInterval?,
                                         userCanSee: Bool) -> Bool {
        guard !userCanSee, let hiddenSince else { return false }
        let afterHiding = reports.filter { $0.uptime - hiddenSince >= 10 }.suffix(2)
        return afterHiding.count == 2 && afterHiding.allSatisfy(\.sample.isVisible)
    }

    static func describe(_ animations: [WebPageHealthSample.Animation]) -> String {
        animations.prefix(4).map { animation in
            let props = animation.properties.isEmpty ? "" : " [\(animation.properties.joined(separator: ","))]"
            return "\(animation.name) on \(animation.target.isEmpty ? "?" : animation.target)\(props)"
        }.joined(separator: "; ")
    }

    static func average(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }
    /// "1 animation", "2 animations".
    static func count(_ value: Int, _ noun: String) -> String { "\(value) \(noun)\(value == 1 ? "" : "s")" }
    static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }
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
        schedule(every: NativeApp.state == .background ? Self.backgroundInterval : Self.interval)
        tick()
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
            record("recovered", "Page responding again.")
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
                                    armed: session.documentID != nil && probeEnabled, samples: session.samples,
                                    thermal: thermal, outsideAppCPU: outsideAppCPU(now: now))) {
        case .healthy:
            break
        case .stalled(let seconds):
            if !session.stalled {
                session.stalled = true
                record("stalled", "Page stopped answering for \(Int(seconds)) s while on screen. \(snapshot(session))")
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

    /// Average cores busy outside this app over the last 30 s.
    private func outsideAppCPU(now: TimeInterval) -> Double? {
        let values = natives.filter { now - $0.uptime <= 30 }.compactMap(\.otherCPU)
        return values.count >= 3 ? optionalAverage(values) : nil
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
                                               armed: primary.documentID != nil && probeEnabled, samples: primary.samples,
                                               thermal: native.thermal, outsideAppCPU: outsideAppCPU(now: now)))
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

// MARK: - Minute history

struct MinuteAccumulator {
    private var start: Date?
    private var app: [Double] = []
    private var device: [Double] = []
    private var thermal = 0
    private var battery: Int?
    private var charging: Bool?
    private var samples = 0
    private var foreground = 0
    private var chat = 0
    private var webViews = 0
    private var memory: Int?
    private var pages: [WebPageHealthSample] = []
    /// (uptime, cumulative monitor nanoseconds) at the minute's first and last sample.
    private var costFirst: (uptime: TimeInterval, nanoseconds: UInt64)?
    private var costLast: (uptime: TimeInterval, nanoseconds: UInt64)?

    mutating func add(_ sample: WebPageHealthSample) { pages.append(sample) }

    /// Returns the previous minute when `sample` starts a new one.
    mutating func add(_ sample: NativeHealthSample, chatOnScreen: Bool, webViews alive: Int,
                      monitorNanoseconds: UInt64 = 0, calendar: Calendar = .current) -> WebKitHealthMinute? {
        let minute = calendar.dateInterval(of: .minute, for: sample.date)?.start ?? sample.date
        var finished: WebKitHealthMinute?
        if let start, start != minute { finished = summary(start: start) }
        if start != minute { self = MinuteAccumulator(); start = minute }
        if costFirst == nil { costFirst = (sample.uptime, monitorNanoseconds) }
        costLast = (sample.uptime, monitorNanoseconds)
        if let value = sample.appCPU { app.append(value) }
        if let value = sample.deviceCPU { device.append(value) }
        thermal = max(thermal, sample.thermal.rawValue)
        battery = sample.batteryLevel.map { Int(($0 * 100).rounded()) }
        charging = sample.charging
        samples += 1
        if sample.appActive { foreground += 1 }
        if chatOnScreen { chat += 1 }
        webViews = max(webViews, alive)
        memory = sample.footprintMB.map { Int($0.rounded()) }
        return finished
    }

    private func summary(start: Date) -> WebKitHealthMinute {
        let count = Double(max(samples, 1))
        let span = pages.reduce(0) { $0 + $1.spanSeconds }
        let counted = pages.reduce(0) { $0 + $1.mutationSeconds }
        var monitor: Double?
        if let first = costFirst, let last = costLast, last.uptime - first.uptime >= 10, last.nanoseconds >= first.nanoseconds {
            monitor = Double(last.nanoseconds - first.nanoseconds) / 1_000_000_000 / (last.uptime - first.uptime)
        }
        return WebKitHealthMinute(
            start: start, app: optionalAverage(app), appPeak: app.max(), device: optionalAverage(device), devicePeak: device.max(),
            thermal: thermal, battery: battery, charging: charging,
            foreground: Double(foreground) / count, chatOnScreen: Double(chat) / count,
            pageReports: pages.count,
            pageVisible: pages.isEmpty ? nil : Double(pages.filter(\.isVisible).count) / Double(pages.count),
            busy: pages.isEmpty ? nil : WebKitHealthFindings.average(pages.map(\.busyFraction)),
            fps: span > 0 ? Double(pages.reduce(0) { $0 + $1.frames }) / span : nil,
            animations: pages.map(\.runningAnimations).max(),
            repainting: pages.map(\.repaintingAnimations.count).max(),
            mutations: counted >= 0.2 ? Double(pages.reduce(0) { $0 + $1.mutations }) / counted : nil,
            requests: span > 0 ? Double(pages.reduce(0) { $0 + $1.resources }) * 60 / span : nil,
            audio: pages.map(\.audioContextsRunning).max(),
            webViews: webViews, memoryMB: memory,
            probe: span > 0 ? pages.reduce(0) { $0 + $1.probeMilliseconds } / 1000 / span : nil,
            monitor: monitor)
    }
}

// MARK: - Persistence

/// JSON lines in Application Support, excluded from backups. Two small
/// rotating files per kind; writes happen off the main thread.
final class WebKitHealthJournal: Sendable {
    private let queue = DispatchQueue(label: "com.termllm.webkit-health.journal", qos: .utility)
    let directory: URL
    static let maximumBytes = 256 * 1024

    init(directory: URL) { self.directory = directory }

    static func standard() -> WebKitHealthJournal? {
        guard !HubFixture.isEnabled, !PhoneHubFixture.isEnabled,
              let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return WebKitHealthJournal(directory: base.appendingPathComponent("Diagnostics/WebKitHealth", isDirectory: true))
    }

    func append(event: WebKitHealthEvent) { append(event, to: "events") }
    func append(minute: WebKitHealthMinute) { append(minute, to: "minutes") }

    func load(_ completion: @escaping @Sendable ([WebKitHealthEvent], [WebKitHealthMinute]) -> Void) {
        queue.async { [self] in
            completion(Array(read("events", as: WebKitHealthEvent.self).suffix(200)),
                       Array(read("minutes", as: WebKitHealthMinute.self).suffix(360)))
        }
    }

    func clear() {
        queue.async { [self] in
            for name in ["events", "minutes"] {
                try? FileManager.default.removeItem(at: file(name))
                try? FileManager.default.removeItem(at: file(name, old: true))
            }
        }
    }

    private func file(_ name: String, old: Bool = false) -> URL {
        directory.appendingPathComponent(name + (old ? ".old" : "") + ".jsonl")
    }

    private func append<Value: Encodable & Sendable>(_ value: Value, to name: String) {
        queue.async { [self] in
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard var line = try? encoder.encode(value) else { return }
            line.append(0x0A)
            let manager = FileManager.default
            if !manager.fileExists(atPath: directory.path) {
                try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                var url = directory
                try? url.setResourceValues(values)
            }
            let url = file(name)
            if let size = (try? manager.attributesOfItem(atPath: url.path)[.size]) as? Int, size >= Self.maximumBytes {
                try? manager.removeItem(at: file(name, old: true))
                try? manager.moveItem(at: url, to: file(name, old: true))
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
        }
    }

    private func read<Value: Decodable>(_ name: String, as type: Value.Type) -> [Value] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var values: [Value] = []
        for url in [file(name, old: true), file(name)] {
            guard let data = try? Data(contentsOf: url) else { continue }
            for line in data.split(separator: 0x0A) {
                if let value = try? decoder.decode(Value.self, from: Data(line)) { values.append(value) }
            }
        }
        return values
    }
}

// MARK: - Report

enum WebKitHealthReport {
    static let downloadCoverage = "URLSession-delivered media body bytes for Listen's managed downloads and HTTPS audio playback, including retries and re-downloads. Cached file reads add no bytes; URLSession cache hits may count. Excludes direct AVPlayer streams (plain HTTP/video), artwork, Apple Music and network headers; not a carrier data meter."

    static func downloadBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func make(status: WebKitHealthStatus, events: [WebKitHealthEvent], minutes: [WebKitHealthMinute],
                     natives: [NativeHealthSample], probeEnabled: Bool, autoStop: Bool, now: Date,
                     device: String, app: String, compact: Bool = false,
                     listenUsage: ListenNetworkUsage.Snapshot? = nil) -> String {
        let time = Date.FormatStyle(date: .omitted, time: .standard)
        var lines = ["term-llm WebKit health report", compact ? "Report schema: 2 · compact diagnosis" : "Report schema: 2 · full"]
        if !compact { lines.append("Generated \(now.formatted(date: .abbreviated, time: .standard))") }
        lines.append("Device \(device) · app \(app) · probe \(probeEnabled ? "on" : "off") · stop runaway pages \(autoStop ? "on" : "off")")
        lines.append("Generated ISO8601: " + now.ISO8601Format())
#if targetEnvironment(simulator)
        lines.append("Runtime: Simulator (device CPU measures the Mac host)")
#elseif os(macOS)
        lines.append("Runtime: Mac app")
#else
        lines.append("Runtime: physical device")
#endif
        if let native = status.native {
            lines.append("Native state: active \(native.appActive), background \(native.appBackground)")
            var now = ["thermal \(WebKitHealthPolicy.thermalName(native.thermal).lowercased())"]
            if let battery = native.batteryLevel { now.append("battery \(Int((battery * 100).rounded()))%\(native.charging == true ? " charging" : "")") }
            if native.lowPower { now.append("Low Power Mode") }
            if let app = status.appCPUMinute { now.append("app CPU \(WebKitHealthFindings.percent(app)) (1 min)") }
            if let device = status.deviceCPUMinute { now.append(String(format: "device CPU %.2f of %d cores (1 min)", device, native.cpuCount)) }
            if let memory = native.footprintMB { now.append("app memory \(Int(memory)) MB") }
            if let wakeups = native.wakeupsPerSecond { now.append("app wakeups \(Int(wakeups))/s") }
            lines.append("Now: " + now.joined(separator: ", "))
        }
        let context = status.context
        lines.append("Chat page: \(pageState(status.pageState)), \(context.userCanSee ? "on screen" : "off screen"), view \(context.inWindow ? "in" : "not in") window\(context.viewHidden ? " (isHidden)" : ""), app \(context.appBackground ? "background" : "foreground")\(context.capturing ? ", capturing" : "")")
        if let age = status.lastReportAge { lines.append("Page report age: \(Int(age)) s (may be stale or suspended)") }
        if let latest = status.latest {
            lines.append("Last page report: visibility \(latest.visibility), busy \(WebKitHealthFindings.percent(latest.busyFraction)) (longest block \(Int(latest.maxLateMilliseconds)) ms), \(String(format: "%.1f", latest.framesPerSecond)) frames/s, \(latest.runningAnimations) running animations, \(Int(latest.mutationsPerSecond.rounded())) DOM changes/s, \(Int(latest.resourcesPerMinute.rounded())) requests/min, DOM \(latest.domNodes.map(String.init) ?? "?") elements")
            lines.append("  audio contexts \(latest.audioContextsRunning)/\(latest.audioContexts) running, live tracks \(latest.liveTracks), WebRTC \(latest.peerConnections), WebSocket \(latest.webSockets), EventSource \(latest.eventSources), media playing \(latest.mediaPlaying)")
            if !latest.animations.isEmpty {
                lines.append("  animations: " + latest.animations.prefix(compact ? 4 : latest.animations.count).map { "\($0.name) on \($0.target) [\($0.properties.joined(separator: ","))]\($0.infinite ? " infinite" : "")\($0.composited ? "" : " REPAINTS")" }.joined(separator: "; "))
            }
        }
        if let onScreen = status.lastOnScreen, status.latest?.isVisible != true, let age = status.lastOnScreenAge {
            lines.append("Last on-screen report (\(Int(age)) s ago): busy \(WebKitHealthFindings.percent(onScreen.busyFraction)), \(String(format: "%.1f", onScreen.framesPerSecond)) frames/s, \(onScreen.runningAnimations) running animations, \(Int(onScreen.mutationsPerSecond.rounded())) DOM changes/s, \(Int(onScreen.resourcesPerMinute.rounded())) requests/min")
            if !onScreen.animations.isEmpty {
                lines.append("  animations: " + onScreen.animations.prefix(compact ? 4 : onScreen.animations.count).map { "\($0.name) on \($0.target) [\($0.properties.joined(separator: ","))]\($0.infinite ? " infinite" : "")\($0.composited ? "" : " REPAINTS")" }.joined(separator: "; "))
            }
        }
        lines.append("Web views alive \(status.webViewsAlive), browser pages \(status.pages)\(status.parked.map { ", parked: \($0.reason.rawValue)" } ?? "")")
        if let usage = listenUsage {
            lines.append("Podcast downloads (Listen): today \(usage.todayBytes) B; this week \(usage.weekBytes) B; this month \(usage.monthBytes) B; since tracking began \(usage.totalBytes) B; last 60 s \(usage.recentBytes) B (this run only)")
            lines.append("  Tracking began \(usage.startedAt.ISO8601Format()); calendar \(Calendar.current.identifier), time zone \(TimeZone.current.identifier). Earlier downloads unknown. Daily buckets retain their recording time zone; zone changes may shift attribution. Abrupt termination may lose the last few seconds. \(downloadCoverage)")
        }
        lines.append("Monitor cost: app \(costText(status.monitorShare)) of a core since launch, page probe \(costText(status.probeShare)) (this page, up to 10 min)")
        if !status.threads.isEmpty {
            lines.append("Busiest app threads: " + status.threads.map { "\($0.label) \(WebKitHealthFindings.percent($0.cpu))" }.joined(separator: ", "))
        }
        lines.append("")
        if compact {
            lines.append("Diagnose native vs page activity from the evidence below; distinguish observations from hypotheses. Request the full .txt if omitted detail is needed.")
            lines.append("Units/limits: app 100%=1 core (excludes WebKit processes); device=all processes; memory=app only. Page busy=heartbeat lateness, not renderer/GPU CPU. Thread CPU=decaying estimate, IDs local to run UUID; no stacks. Minute values=sample averages, not time-weighted. Sampling 5s foreground/30s background when scheduled; suspension gaps possible. Events/minutes persist across launches; raw samples do not. Current findings do not clear past incidents.")
            lines.append("Current findings: " + (status.findings.isEmpty ? "none" : status.findings.map { "\($0.title): \($0.detail)" }.joined(separator: "; ")))
            lines.append(contentsOf: compactHistory(events: events, minutes: minutes, natives: natives))
            lines.append("Selection is lossy: up to 4 animations per page state, key events and peak/boundary minutes only. Share full report (.txt) for complete retained detail.")
            return lines.joined(separator: "\n")
        }
        lines.append("Interpretation for investigating agents:")
        lines.append("  App CPU: own process only; 100% = one core. Device CPU includes all processes, not just WebKit. Memory is app footprint only.")
        lines.append("  CPU samples are counter deltas over elapsed uptime, including suspension gaps; minute CPU/foreground/chat values are sample averages, not time-weighted.")
        lines.append("  Page busy measures heartbeat lateness, not total JavaScript, renderer or GPU CPU. A quiet/stale page does not rule out native work or WebKit internals.")
        lines.append("  Thread CPU is a recent decaying scheduler estimate, not a stack trace or the same interval as app CPU. IDs are process-local; correlate native-cpu events by run UUID. Missing threads are not evidence of idle CPU.")
        lines.append("  Native CPU >=30% captures evidence at most every 30 s plus recovery, persisted in Events. Short spikes between samples can be missed. No cross-thread stacks are collected; use physical-device Instruments Time Profiler for function attribution.")
        lines.append("  Native cadence: 5 s foreground, 30 s background while scheduled; iOS may suspend sampling. Events/minutes survive relaunch; raw samples and current findings do not. No findings now does not clear earlier incidents.")
        lines.append("  Monitor cost covers measured monitor work, not all indirect UI/bridge overhead. Simulator device CPU reflects the host; thermal/battery conclusions need a phone.")
        lines.append("")
        lines.append("Findings (current only):")
        if status.findings.isEmpty { lines.append("  none") }
        for finding in status.findings {
            lines.append("  [\(["info", "warning", "critical"][finding.severity.rawValue])] \(finding.title): \(finding.detail)")
        }
        lines.append("")
        lines.append("Events (newest first):")
        for event in events.suffix(300).reversed() {
            lines.append("  \(event.date.formatted(date: .numeric, time: .standard)) \(event.kind): \(event.message)")
        }
        lines.append("")
        lines.append("Minutes (newest first): time thermal app% dev-cores fg% chat% | reports vis% busy% fps anim repaint mut/s req/min audio | views battery | probe% monitor% | app-peak% dev-peak memory-MB")
        for minute in minutes.suffix(360).reversed() {
            func value(_ number: Double?, _ format: String = "%.0f") -> String { number.map { String(format: format, $0) } ?? "-" }
            lines.append("  \(minute.start.formatted(time)) \(WebKitHealthPolicy.thermalName(ProcessInfo.ThermalState(rawValue: minute.thermal) ?? .nominal).lowercased()) \(value(minute.app.map { $0 * 100 })) \(value(minute.device, "%.2f")) \(Int(minute.foreground * 100)) \(Int(minute.chatOnScreen * 100)) | \(minute.pageReports) \(value(minute.pageVisible.map { $0 * 100 })) \(value(minute.busy.map { $0 * 100 })) \(value(minute.fps, "%.1f")) \(minute.animations.map(String.init) ?? "-") \(minute.repainting.map(String.init) ?? "-") \(value(minute.mutations, "%.1f")) \(value(minute.requests)) \(minute.audio.map(String.init) ?? "-") | \(minute.webViews) \(minute.battery.map { "\($0)%" } ?? "-")\(minute.charging == true ? "+" : "") | \(value(minute.probe.map { $0 * 100 }, "%.3f")) \(value(minute.monitor.map { $0 * 100 }, "%.3f")) | \(value(minute.appPeak.map { $0 * 100 })) \(value(minute.devicePeak, "%.2f")) \(minute.memoryMB.map(String.init) ?? "-")")
        }
        if !natives.isEmpty {
            lines.append("")
            lines.append("Samples (retained this run, up to 30 min, newest first): time app% dev-cores wakeups/s | uptime-s tick-gap-s cpu-interval-s active background memory-MB thermal")
            for (index, sample) in natives.enumerated().reversed() {
                let interval = index > 0 ? String(format: "%.1f", sample.uptime - natives[index - 1].uptime) : "-"
                lines.append("  \(sample.date.formatted(time)) \(sample.appCPU.map { String(Int(($0 * 100).rounded())) } ?? "-") \(sample.deviceCPU.map { String(format: "%.2f", $0) } ?? "-") \(sample.wakeupsPerSecond.map { String(Int($0)) } ?? "-") | \(String(format: "%.1f", sample.uptime)) \(interval) \(sample.cpuInterval.map { String(format: "%.1f", $0) } ?? "-") \(sample.appActive) \(sample.appBackground) \(sample.footprintMB.map { String(Int($0)) } ?? "-") \(WebKitHealthPolicy.thermalName(sample.thermal).lowercased())")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Deterministic evidence selection, not an LLM summary. Never invent a cause.
    private static func compactHistory(events: [WebKitHealthEvent], minutes: [WebKitHealthMinute],
                                       natives: [NativeHealthSample]) -> [String] {
        var lines: [String] = []
        let events = Array(events.suffix(300))
        var selected = Set<Int>()
        let cpu = events.indices.filter { events[$0].kind == "native-cpu" }
        func appCPU(_ event: WebKitHealthEvent) -> Double {
            ["app ", "peak "].compactMap { marker -> Double? in
                guard let range = event.message.range(of: marker) else { return nil }
                return Double(event.message[range.upperBound...].prefix { $0.isNumber || $0 == "." })
            }.max() ?? -1
        }
        if let first = cpu.first { selected.insert(first) }
        if let last = cpu.last { selected.insert(last) }
        if let peak = cpu.max(by: { appCPU(events[$0]) < appCPU(events[$1]) }) { selected.insert(peak) }
        if let recovery = cpu.last(where: { events[$0].message.hasPrefix("CPU episode ended") }) { selected.insert(recovery) }
        // Keep the latest of each important kind instead of letting repeated app
        // foreground notifications crowd out stop/effect/thermal evidence.
        for kind in ["terminated", "memory", "stop", "effect", "thermal", "stalled", "blocked",
                     "leak", "finding", "visibility", "launch", "app"] {
            if let index = events.lastIndex(where: { $0.kind == kind }) { selected.insert(index) }
        }
        var eventLines: [(index: Int, text: String)] = []
        var characters = 0
        var seen = Set<String>()
        // Admit CPU evidence before incidental events if the text budget is tight.
        let candidates = selected.sorted {
            let leftCPU = events[$0].kind == "native-cpu"
            let rightCPU = events[$1].kind == "native-cpu"
            return leftCPU != rightCPU ? leftCPU : $0 > $1
        }
        for index in candidates {
            let event = events[index]
            guard seen.insert(event.kind + "\n" + event.message).inserted else { continue }
            let repeats = events.filter { $0.kind == event.kind && $0.message == event.message }.count
            let line = "\(event.date.ISO8601Format()) \(event.kind)\(repeats > 1 ? " (x\(repeats) identical)" : ""): \(event.message)"
            // Leave room for current state and timeline; do not cut a thread list mid-line.
            guard characters + line.count <= 8_000 else { continue }
            eventLines.append((index, line))
            characters += line.count
        }
        lines.append("Selected events: \(eventLines.count)/\(events.count) retained (chronological; repeats counted across retained history)")
        lines.append(contentsOf: eventLines.sorted { $0.index < $1.index }.map(\.text))

        let minutes = Array(minutes.suffix(360))
        var rows = Set<Int>()
        if let first = minutes.indices.first { rows.insert(first) }
        if let last = minutes.indices.last { rows.insert(last) }
        var peaks: [Int] = []
        if let app = minutes.indices.max(by: { (minutes[$0].appPeak ?? minutes[$0].app ?? -1) < (minutes[$1].appPeak ?? minutes[$1].app ?? -1) }) { peaks.append(app) }
        if let device = minutes.indices.max(by: { (minutes[$0].devicePeak ?? minutes[$0].device ?? -1) < (minutes[$1].devicePeak ?? minutes[$1].device ?? -1) }) { peaks.append(device) }
        if let thermal = minutes.indices.max(by: { minutes[$0].thermal < minutes[$1].thermal }) { peaks.append(thermal) }
        for peak in peaks {
            for index in (peak - 1)...(peak + 1) where minutes.indices.contains(index) { rows.insert(index) }
        }
        lines.append("Selected minutes: \(rows.count)/\(minutes.count) in last 360 retained; boundaries + app/device/thermal peaks and neighbours. '-'=unavailable, gaps omitted.")
        lines.append("time thermal app%/peak dev-cores/peak fg% chat% | page-reports vis% busy% fps anim req/min | MB battery%")
        func value(_ number: Double?, _ format: String = "%.0f") -> String { number.map { String(format: format, $0) } ?? "-" }
        for index in rows.sorted() {
            let m = minutes[index]
            lines.append("\(m.start.ISO8601Format()) \(WebKitHealthPolicy.thermalName(ProcessInfo.ThermalState(rawValue: m.thermal) ?? .nominal).lowercased()) \(value(m.app.map { $0 * 100 }))/\(value(m.appPeak.map { $0 * 100 })) \(value(m.device, "%.2f"))/\(value(m.devicePeak, "%.2f")) \(Int(m.foreground * 100)) \(Int(m.chatOnScreen * 100)) | \(m.pageReports) \(value(m.pageVisible.map { $0 * 100 })) \(value(m.busy.map { $0 * 100 })) \(value(m.fps, "%.1f")) \(m.animations.map(String.init) ?? "-") \(value(m.requests)) | \(m.memoryMB.map(String.init) ?? "-") \(m.battery.map(String.init) ?? "-")")
        }
        // Raw evidence still matters when the hot minute has not been flushed.
        var samples = Set<Int>()
        if let last = natives.indices.last { samples.insert(last) }
        if let peak = natives.indices.max(by: { (natives[$0].appCPU ?? -1) < (natives[$1].appCPU ?? -1) }) { samples.insert(peak) }
        if let wakeups = natives.indices.max(by: { (natives[$0].wakeupsPerSecond ?? -1) < (natives[$1].wakeupsPerSecond ?? -1) }) { samples.insert(wakeups) }
        lines.append("Selected raw samples: latest, app CPU peak, wakeup peak from this run's retained samples (up to 30 min).")
        for index in samples.sorted() {
            let n = natives[index]
            lines.append("\(n.date.ISO8601Format()) app=\(value(n.appCPU.map { $0 * 100 }))% dev=\(value(n.deviceCPU, "%.2f")) wakeups/s=\(value(n.wakeupsPerSecond)) CPU-interval-s=\(value(n.cpuInterval, "%.1f")) active=\(n.appActive) bg=\(n.appBackground)")
        }
        return lines
    }

    /// A URL payload makes the share sheet offer a real UTF-8 .txt attachment.
    /// Each share owns its directory so cleanup cannot affect another export.
    static func writeFile(_ text: String, directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let folder = directory.appendingPathComponent("term-llm-health-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("term-llm-health.txt")
        do {
            try Data(text.utf8).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return url
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// A small share of one core, e.g. "0.004%".
    static func costText(_ share: Double?) -> String {
        guard let share else { return "n/a" }
        let percent = share * 100
        return percent >= 1 ? String(format: "%.1f%%", percent) : String(format: "%.3f%%", percent)
    }

    static func pageState(_ state: WebKitHealthStatus.PageState) -> String {
        switch state {
        case .none: "not open"
        case .loading: "loading"
        case .waiting: "waiting for first report"
        case .active: "reporting"
        case .stalled(let seconds): "not responding for \(Int(seconds)) s"
        case .offScreenAwake: "still running"
        case .offScreenQuiet: "quiet (throttled or suspended)"
        }
    }
}
