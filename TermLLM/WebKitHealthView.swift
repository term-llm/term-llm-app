import Charts
import SwiftUI
import UIKit

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
/// content, with a report to share when the phone runs hot.
struct WebKitHealthView: View {
    @ObservedObject var monitor: WebKitHealthMonitor
    let parked: WebKitParkedPage?
    let onReload: () -> Void
    @State private var copied = false
    @State private var sharing: SharedReport?
    @State private var exportURL: URL?
    @State private var exportFailed = false

    private struct SharedReport: Identifiable {
        let id = UUID()
        let url: URL
    }

    var body: some View {
        let status = monitor.status
        Form {
            Section {
                if let native = status.native {
                    LabeledContent("Phone temperature", value: WebKitHealthPolicy.thermalName(native.thermal))
                    LabeledContent("App CPU", value: status.appCPUMinute.map(WebKitHealthFindings.percent) ?? "Measuring…")
                    LabeledContent("Device CPU", value: status.deviceCPUMinute.map {
                        String(format: "%.1f of %d cores", $0, native.cpuCount)
                    } ?? "Unavailable")
                }
                LabeledContent("Chat page", value: pageSummary(status))
                let fresh = status.latest.flatMap { latest in status.lastReportAge.map { $0 <= 30 } == true ? latest : nil }
                if let latest = fresh {
                    LabeledContent("Page activity", value: activity(latest))
                    if latest.audioContextsRunning > 0 || latest.liveTracks > 0 {
                        LabeledContent("Audio", value: "\(latest.audioContextsRunning) engine(s) running, \(latest.liveTracks) live track(s)")
                    }
                }
                // This screen takes Chat off screen: show what the page did while visible.
                if let onScreen = status.lastOnScreen, fresh?.isVisible != true,
                   let age = status.lastOnScreenAge, age <= 600 {
                    LabeledContent("Last on screen", value: activity(onScreen) + " · " + ago(age))
                        .accessibilityIdentifier("webKitHealth.lastOnScreen")
                }
                if let animated = fresh?.isVisible == true ? fresh : status.lastOnScreen, !animated.animations.isEmpty {
                    LabeledContent("Animations", value: WebKitHealthFindings.describe(animated.animations))
                }
                if !status.threads.isEmpty {
                    LabeledContent("Busiest app threads", value: status.threads.prefix(3)
                        .map { "\($0.name) \(WebKitHealthFindings.percent($0.cpu))" }.joined(separator: ", "))
                }
                LabeledContent("Monitor cost", value: "app \(WebKitHealthReport.costText(status.monitorShare)) · page \(WebKitHealthReport.costText(status.probeShare))")
                    .accessibilityIdentifier("webKitHealth.cost")
            } header: {
                Text("Now")
            } footer: {
                Text("App CPU is this app's own process. Device CPU also includes WebKit's separate page, GPU and network processes, and iOS itself. Monitor cost is the share of one core this monitor and its page probe use.")
            }

            if !status.findings.isEmpty {
                Section("Findings") {
                    ForEach(status.findings) { finding in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(finding.title, systemImage: symbol(finding.severity))
                                .foregroundStyle(color(finding.severity))
                            Text(finding.detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }

            if monitor.minutes.count >= 2 {
                Section {
                    history
                        .frame(height: 140)
                        .accessibilityLabel("CPU over the last hour")
                } header: {
                    Text("Last hour")
                } footer: {
                    Text("Cores busy per minute: device (all processes) and this app. Orange and red marks: the phone was hot.")
                }
            }

            Section {
                if let parked {
                    Button("Reload chat page") { onReload() }
                        .accessibilityIdentifier("webKitHealth.reload")
                    Text("Stopped: \(parked.reason.title.lowercased()).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Pause chat page") { monitor.pausePage() }
                        .disabled(status.pages == 0)
                        .accessibilityIdentifier("webKitHealth.pause")
                }
                Button {
                    do {
                        let url = try WebKitHealthReport.writeFile(monitor.report())
                        exportURL = url
                        sharing = SharedReport(url: url)
                    } catch {
                        exportFailed = true
                    }
                } label: {
                    Label("Share full report (.txt)", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("webKitHealth.share")
                Button {
                    UIPasteboard.general.string = monitor.report(compact: true)
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy for diagnosis", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .accessibilityIdentifier("webKitHealth.copy")
            } footer: {
                Text("Copy for diagnosis gives an agent a compact, selected report to paste into chat. Share full report exports the complete retained detail as a .txt file. Pausing closes the chat page and its web process. About 40 s later (or when it is reopened) the history notes whether device CPU dropped while it was closed, which shows whether WebKit was the cause. Reports contain only measurements and code names, never page content or addresses.")
            }

            Section {
                Toggle("Watch page activity", isOn: $monitor.probeEnabled)
                    .accessibilityIdentifier("webKitHealth.probe")
                Toggle("Stop runaway pages", isOn: $monitor.autoStopEnabled)
                    .accessibilityIdentifier("webKitHealth.autoStop")
            } footer: {
                Text("Watching injects a small probe into the chat page (it applies from the next page load). Stopping closes the page if it stops responding for 45 s on screen while the phone stays busy, keeps drawing, polling or running audio for 2 minutes off screen, or keeps running off screen while the phone is hot. It never stops a live call, a voice launch or a device tool reply. Chat reopens the page where it was, with its draft.")
            }

            if !monitor.events.isEmpty {
                Section("History") {
                    ForEach(monitor.events.suffix(60).reversed()) { event in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.message)
                                .font(.footnote)
                            Text("\(event.date.formatted(date: .abbreviated, time: .standard)) · \(event.kind)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button("Clear history", role: .destructive) { monitor.clearHistory() }
                }
            }
        }
        .navigationTitle("Web page health")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { monitor.detailed = true }
        .onDisappear { monitor.detailed = false }
        .alert("Could not create report", isPresented: $exportFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Try again, or use Copy for diagnosis.")
        }
        .sheet(item: $sharing, onDismiss: {
            if let exportURL {
                try? FileManager.default.removeItem(at: exportURL.deletingLastPathComponent())
                self.exportURL = nil
            }
        }) { report in
            ActivitySheet(items: [report.url])
                .ignoresSafeArea()
        }
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

    private func pageSummary(_ status: WebKitHealthStatus) -> String {
        if let parked = status.parked ?? parked { return "Stopped (\(parked.reason.rawValue.replacingOccurrences(of: "_", with: " ")))" }
        let visibility = status.latest.map { " · WebKit: \($0.visibility)" } ?? ""
        switch status.pageState {
        case .none: return "Not open"
        case .loading: return "Loading"
        case .waiting: return monitor.probeEnabled ? "On screen, waiting for a report" : "On screen (not watched)"
        case .active: return "On screen" + visibility
        case .stalled(let seconds): return "Not responding (\(Int(seconds)) s)"
        case .offScreenAwake: return "Off screen, still running" + visibility
        case .offScreenQuiet: return "Off screen, quiet"
        }
    }

    private func activity(_ sample: WebPageHealthSample) -> String {
        var parts: [String]
        if sample.isVisible {
            parts = ["busy \(WebKitHealthFindings.percent(sample.busyFraction))",
                     "\(Int(sample.framesPerSecond.rounded())) fps",
                     "\(sample.runningAnimations) animation\(sample.runningAnimations == 1 ? "" : "s")",
                     "\(Int(sample.mutationsPerSecond.rounded())) DOM changes/s"]
        } else {
            // Hidden pages draw nothing; the probe skips its animation and DOM scans.
            parts = ["hidden, not drawing"]
        }
        if sample.resources > 0 { parts.append("\(Int(sample.resourcesPerMinute.rounded())) requests/min") }
        return parts.joined(separator: " · ")
    }

    private func ago(_ seconds: TimeInterval) -> String {
        seconds < 90 ? "\(max(1, Int(seconds.rounded()))) s ago" : "\(Int((seconds / 60).rounded())) min ago"
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
}

private struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
