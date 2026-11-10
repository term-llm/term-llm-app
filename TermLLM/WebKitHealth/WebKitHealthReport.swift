import Foundation

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
