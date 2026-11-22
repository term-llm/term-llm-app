import Foundation

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
        // Only watch for missed reports on screen. Probe silence does not prove
        // a hang, and system CPU cannot attribute work to this page, so never
        // tear down a page on this evidence.
        if context.userCanSee, !context.appBackground, !context.loading, input.armed, let last = input.lastSampleAt,
           let visibleSince = input.visibleSince {
            let silent = input.now - max(last, visibleSince)
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
            findings.append(.init(id: "stalled", severity: .warning, title: "No page health report (\(Int(seconds)) s)",
                                  detail: "Monitoring data is missing. The chat page may still be working."))
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
