import Charts
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Settings row: names the worst current finding, otherwise the thermal state.
struct WebKitHealthSettingsRow: View {
    @ObservedObject var monitor: WebKitHealthMonitor

    var body: some View {
        let worst = monitor.status.findings.first
        LabeledContent {
            if let worst, worst.severity >= .warning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(worst.severity == .critical ? .red : .orange)
                    .accessibilityLabel(worst.title)
            } else if let native = monitor.status.native {
                Text(WebKitHealthPolicy.thermalName(native.thermal))
            }
        } label: {
            Label("Web page health", systemImage: "waveform.path.ecg")
        }
    }
}

/// Live readings, findings and the event history of the chat page's web
/// content, with a report to share when the phone runs hot. Detail and
/// measurement caveats live in the reports; this screen stays short.
struct WebKitHealthView: View {
    @ObservedObject var monitor: WebKitHealthMonitor
    let parked: WebKitParkedPage?
    let onReload: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var copied = false
    @State private var sharing: SharedReport?
    @State private var exportURL: URL?
    @State private var exportFailed = false
    @State private var expandedEvents: Set<UUID> = []
    @State private var usageDate = Date()

    private struct SharedReport: Identifiable {
        let id = UUID()
        let url: URL
    }

    var body: some View {
        let status = monitor.status
        Form {
            nowSection(status)
            if !status.findings.isEmpty {
                findingsSection(status.findings)
            }
            chatPageSection(status)
            if monitor.minutes.count >= 2 {
                historyChartSection
            }
            downloadsSection
            reportSection
            monitoringSection
            if !monitor.events.isEmpty {
                historySection
            }
        }
        .settingsPageTitle("Web page health")
        .onAppear { monitor.detailed = true }
        .onDisappear { monitor.detailed = false }
        .task {
            // Download counters are not observable: refresh them while shown.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                usageDate = Date()
            }
        }
        .alert("Could not create report", isPresented: $exportFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Try again, or use Copy for diagnosis.")
        }
        #if os(iOS)
        .sheet(item: $sharing, onDismiss: {
            if let exportURL {
                try? FileManager.default.removeItem(at: exportURL.deletingLastPathComponent())
                self.exportURL = nil
            }
        }) { report in
            ActivitySheet(items: [report.url])
                .ignoresSafeArea()
        }
        #endif
    }

    // MARK: Sections

    private func nowSection(_ status: WebKitHealthStatus) -> some View {
        Section {
            metricRow {
                HealthMetric(title: "Temperature",
                             value: status.native.map { WebKitHealthPolicy.thermalName($0.thermal) } ?? "—",
                             tint: thermalTint(status.native?.thermal))
                    .accessibilityIdentifier("webKitHealth.temperature")
                HealthMetric(title: "App CPU", value: status.appCPUMinute.map(WebKitHealthFindings.percent) ?? "—")
                HealthMetric(title: "Device CPU", value: status.deviceCPUMinute.map {
                    String(format: "%.1f cores", $0)
                } ?? "—")
            }
            if !status.threads.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Busiest threads")
                        .foregroundStyle(.secondary)
                    ForEach(Array(status.threads.prefix(3).enumerated()), id: \.offset) { _, thread in
                        HStack {
                            Text(thread.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 12)
                            Text(WebKitHealthFindings.percent(thread.cpu))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.subheadline)
                .accessibilityElement(children: .combine)
            }
            LabeledContent("Monitoring cost", value: "app \(WebKitHealthReport.costText(status.monitorShare)) · page \(WebKitHealthReport.costText(status.probeShare))")
                .accessibilityIdentifier("webKitHealth.cost")
        } header: {
            Text("Now")
        } footer: {
            Text("App CPU is this app alone; 100% is one core. Device CPU counts busy cores across every process, WebKit included.")
        }
    }

    private func findingsSection(_ findings: [WebKitHealthFinding]) -> some View {
        Section("Findings") {
            ForEach(findings) { finding in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Image(systemName: symbol(finding.severity))
                        .foregroundStyle(color(finding.severity))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(finding.title)
                        if !finding.detail.isEmpty {
                            Text(finding.detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func chatPageSection(_ status: WebKitHealthStatus) -> some View {
        let stopped = status.parked ?? parked
        return Section {
            LabeledContent("Status", value: pageSummary(status))
                .accessibilityIdentifier("webKitHealth.chatStatus")
            if status.context.userCanSee, let live = freshReport(status) {
                metricRow { pageMetrics(live) }
                audio(live)
            } else if stopped == nil, let onScreen = status.lastOnScreen,
                      let age = status.lastOnScreenAge, age <= 600 {
                // Opening this screen usually takes Chat off screen: show what
                // the page was doing while it was visible.
                LabeledContent("Last on screen", value: ago(age))
                    .accessibilityIdentifier("webKitHealth.lastOnScreen")
                metricRow { pageMetrics(onScreen) }
            }
            if parked != nil {
                Button("Reload chat page") { onReload() }
                    .accessibilityIdentifier("webKitHealth.reload")
            } else {
                Button("Pause chat page") { monitor.pausePage() }
                    .disabled(status.pages == 0)
                    .accessibilityIdentifier("webKitHealth.pause")
            }
        } header: {
            Text("Chat page")
        } footer: {
            Text(parked == nil
                 ? "Pause closes the page to see whether it's what keeps the phone busy. History shows the result about 40 s later."
                 : "Reloading reopens the page where it was, with its draft.")
        }
    }

    private var historyChartSection: some View {
        Section {
            history
                .frame(height: 140)
                .accessibilityLabel("CPU over the last hour")
        } header: {
            Text("Last hour")
        } footer: {
            Text("Cores busy each minute. Orange and red dots: the phone was warm or hot.")
        }
    }

    /// Not wrapped in a TimelineView: a Form treats that as one row, which
    /// pulled the header and footer into the card.
    private var downloadsSection: some View {
        let usage = ListenNetworkUsage.shared.snapshot(now: usageDate)
        return Section {
            LabeledContent("Last minute", value: WebKitHealthReport.downloadBytes(usage.recentBytes))
            LabeledContent("Today", value: WebKitHealthReport.downloadBytes(usage.todayBytes))
                .accessibilityIdentifier("webKitHealth.podcastBytesToday")
            LabeledContent("This week", value: WebKitHealthReport.downloadBytes(usage.weekBytes))
            LabeledContent("This month", value: WebKitHealthReport.downloadBytes(usage.monthBytes))
            LabeledContent {
                Text(WebKitHealthReport.downloadBytes(usage.totalBytes))
            } label: {
                Text("Since \(usage.startedAt.formatted(date: .abbreviated, time: .omitted))")
            }
        } header: {
            Text("Podcast downloads")
        } footer: {
            Text("Listen's downloads and HTTPS audio streams, repeats included. Video streams, artwork and Apple Music aren't counted.")
        }
    }

    private var reportSection: some View {
        Section {
            Button {
                NativeApp.copy(monitor.report(compact: true))
                copied = true
            } label: {
                Label(copied ? "Copied" : "Copy for diagnosis", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .accessibilityIdentifier("webKitHealth.copy")
            #if os(macOS)
            Button {
                saveReport()
            } label: {
                Label("Save full report…", systemImage: "square.and.arrow.down")
            }
            .accessibilityIdentifier("webKitHealth.share")
            #else
            Button {
                do {
                    let url = try WebKitHealthReport.writeFile(monitor.report())
                    exportURL = url
                    sharing = SharedReport(url: url)
                } catch {
                    exportFailed = true
                }
            } label: {
                Label("Share full report", systemImage: "square.and.arrow.up")
            }
            .accessibilityIdentifier("webKitHealth.share")
            #endif
        } header: {
            Text("Report")
        } footer: {
            Text("Copy for diagnosis gives an agent a short summary. Reports contain measurements only, never page content or addresses.")
        }
    }

    private var monitoringSection: some View {
        Section {
            Toggle("Watch page activity", isOn: $monitor.probeEnabled)
                .accessibilityIdentifier("webKitHealth.probe")
            Toggle("Stop runaway pages", isOn: $monitor.autoStopEnabled)
                .accessibilityIdentifier("webKitHealth.autoStop")
        } header: {
            Text("Monitoring")
        } footer: {
            Text("Stop runaway pages can close a busy off-screen page, but not during a call or tool reply. Chat reopens it where you left off. Missing health reports never close Chat. Turning on watching takes effect at the next page load.")
        }
    }

    private var historySection: some View {
        Section {
            ForEach(monitor.events.suffix(60).reversed()) { event in
                historyRow(event)
            }
            Button("Clear history", role: .destructive) {
                expandedEvents = []
                monitor.clearHistory()
            }
        } header: {
            Text("History")
        } footer: {
            Text("Tap an entry to see all of it.")
        }
    }

    // MARK: Rows

    /// Side by side, or stacked at accessibility text sizes.
    private func metricRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        return layout(content)
            .padding(.vertical, 4)
    }

    @ViewBuilder
    private func pageMetrics(_ sample: WebPageHealthSample) -> some View {
        HealthMetric(title: "Busy", value: WebKitHealthFindings.percent(sample.busyFraction))
        HealthMetric(title: "Frames", value: "\(Int(sample.framesPerSecond.rounded()))/s")
        HealthMetric(title: "Animations", value: "\(sample.runningAnimations)")
        HealthMetric(title: "Requests", value: "\(Int(sample.resourcesPerMinute.rounded()))/min")
    }

    @ViewBuilder
    private func audio(_ sample: WebPageHealthSample) -> some View {
        if sample.audioContextsRunning > 0 || sample.liveTracks > 0 {
            LabeledContent("Audio", value: [
                sample.audioContextsRunning > 0 ? WebKitHealthFindings.count(sample.audioContextsRunning, "engine") : nil,
                sample.liveTracks > 0 ? WebKitHealthFindings.count(sample.liveTracks, "live track") : nil,
            ].compactMap { $0 }.joined(separator: " · "))
        }
    }

    private func historyRow(_ event: WebKitHealthEvent) -> some View {
        let expanded = expandedEvents.contains(event.id)
        let entry = Self.historyEntry(event)
        return Button {
            if expanded { expandedEvents.remove(event.id) } else { expandedEvents.insert(event.id) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: entry.symbol)
                        .foregroundStyle(entry.tint)
                        .frame(width: 20)
                        .accessibilityHidden(true)
                    Text(entry.title)
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    Text(time(event.date))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if !entry.body.isEmpty {
                    Text(entry.body)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(expanded ? nil : 2)
                        .multilineTextAlignment(.leading)
                        .padding(.leading, 28)
                }
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(entry.body.isEmpty ? "" : expanded ? "Shows less" : "Shows the whole entry")
    }

    private var history: some View {
        let minutes = Array(monitor.minutes.suffix(60))
        return Chart {
            ForEach(minutes, id: \.start) { minute in
                if let device = minute.device {
                    LineMark(x: .value("Time", minute.start), y: .value("Cores", device), series: .value("Process", "Device"))
                        .foregroundStyle(by: .value("Process", "Device"))
                }
                if let app = minute.app {
                    LineMark(x: .value("Time", minute.start), y: .value("Cores", app), series: .value("Process", "App"))
                        .foregroundStyle(by: .value("Process", "App"))
                }
                if minute.thermal >= ProcessInfo.ThermalState.fair.rawValue {
                    PointMark(x: .value("Time", minute.start), y: .value("Cores", 0))
                        .foregroundStyle(minute.thermal >= ProcessInfo.ThermalState.serious.rawValue ? .red : .orange)
                        .symbolSize(20)
                }
            }
        }
        .chartLegend(position: .bottom)
    }

    // MARK: Text

    private func pageSummary(_ status: WebKitHealthStatus) -> String {
        if let stopped = status.parked ?? parked {
            switch stopped.reason {
            case .manual: return "Paused"
            case .hiddenActivity: return "Stopped · busy off screen"
            case .thermal: return "Stopped · phone was hot"
            }
        }
        switch status.pageState {
        case .none: return "Not open"
        case .loading: return "Loading"
        case .waiting: return monitor.probeEnabled ? "On screen · no report yet" : "On screen · not watched"
        case .active: return "On screen"
        case .stalled(let seconds): return "No health report · \(Int(seconds)) s"
        case .offScreenAwake: return "Off screen · awake"
        case .offScreenQuiet: return "Off screen · quiet"
        }
    }

    /// The page's latest report, if recent.
    private func freshReport(_ status: WebKitHealthStatus) -> WebPageHealthSample? {
        guard let latest = status.latest, let age = status.lastReportAge, age <= 30, latest.isVisible else { return nil }
        return latest
    }

    private func ago(_ seconds: TimeInterval) -> String {
        seconds < 90 ? "\(max(1, Int(seconds.rounded()))) s ago" : "\(Int((seconds / 60).rounded())) min ago"
    }

    private func time(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    private func thermalTint(_ state: ProcessInfo.ThermalState?) -> Color? {
        switch state {
        case .fair: .orange
        case .serious, .critical: .red
        default: nil
        }
    }

    private func symbol(_ severity: WebKitHealthFinding.Severity) -> String {
        switch severity {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .critical: "exclamationmark.octagon"
        }
    }

    private func color(_ severity: WebKitHealthFinding.Severity) -> Color {
        switch severity {
        case .info: .secondary
        case .warning: .orange
        case .critical: .red
        }
    }

    /// A readable title for a journal entry; the body keeps the recorded detail.
    static func historyEntry(_ event: WebKitHealthEvent) -> (title: String, body: String, symbol: String, tint: Color) {
        let message = event.message
        // Both are recorded as "<summary>. <detail>": lead with the summary.
        let split = message.range(of: ". ")
        let rest = split.map { String(message[$0.upperBound...]) } ?? ""
        switch event.kind {
        case "app":
            let background = message.hasPrefix("Entered background")
            return (background ? "Moved to background" : "Back in foreground", rest,
                    background ? "moon" : "sun.max", .secondary)
        case "finding":
            guard let split else { return ("Warning", message, "exclamationmark.triangle", .orange) }
            return (String(message[..<split.lowerBound]), rest, "exclamationmark.triangle", .orange)
        default:
            let style = historyStyle(event.kind)
            return (style.title, message, style.symbol, style.tint)
        }
    }

    private static func historyStyle(_ kind: String) -> (title: String, symbol: String, tint: Color) {
        switch kind {
        case "launch": ("App launched", "power", .secondary)
        case "setting": ("Setting changed", "gearshape", .secondary)
        case "power": ("Low Power Mode", "battery.25percent", .secondary)
        case "capture": ("Microphone or camera", "mic", .secondary)
        case "resumed": ("Page reopened", "arrow.clockwise", .secondary)
        case "recovered": ("Page responding again", "checkmark.circle", .green)
        case "effect": ("Effect of closing", "chart.line.downtrend.xyaxis", .secondary)
        case "thermal": ("Temperature changed", "thermometer.medium", .orange)
        case "native-cpu": ("High app CPU", "cpu", .orange)
        case "memory": ("Memory warning", "memorychip", .orange)
        case "blocked": ("Page blocked", "tortoise", .orange)
        case "visibility": ("Hidden page ran at full speed", "eye.slash", .orange)
        case "leak": ("Web view not released", "exclamationmark.triangle", .orange)
        case "would-stop": ("Would have stopped page", "stop.circle", .orange)
        case "stalled": ("Page not responding", "hourglass", .red)
        case "stop": ("Page stopped", "stop.circle", .red)
        case "terminated": ("Page process exited", "xmark.octagon", .red)
        default: (kind.capitalized, "circle", .secondary)
        }
    }
}

/// One reading: a small caption over a large value.
private struct HealthMetric: View {
    let title: String
    let value: String
    var tint: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(tint ?? .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

#if os(macOS)
extension WebKitHealthView {
    /// A Mac saves the full report where the user chooses instead of sharing it.
    fileprivate func saveReport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "term-llm-health.txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(monitor.report().utf8).write(to: url, options: .atomic)
        } catch {
            exportFailed = true
        }
    }
}
#endif

#if os(iOS)
private struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
