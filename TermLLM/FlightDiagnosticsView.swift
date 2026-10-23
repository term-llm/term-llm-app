import SwiftUI

/// Entirely native: opening, reading and sharing diagnostics never calls WKWebView.
struct FlightDiagnosticsView: View {
    @State private var report = "Loading local diagnostics…"
    @State private var exportURL: URL?
    @State private var preparing = false
    @State private var refreshing = false
    @State private var exportFailed = false

    var body: some View {
        List {
            Section {
                Text("Local, bounded timing events only. No chat, audio, credentials, URLs, tool arguments, results or error text. Nothing is uploaded automatically.")
                Text("Suspected stalls are timing observations, not crash reports or stack traces. A blocked native main thread must recover before Settings can respond.")
                    .foregroundStyle(.secondary)
            }
            Section("Report") {
                Text(String(report.prefix(24_000)))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("flightDiagnosticsReport")
                if report.count > 24_000 {
                    Text("Preview limited to 24,000 characters. Export includes the full retained report.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Button("Refresh report") {
                    guard !refreshing, !preparing else { return }
                    refreshing = true
                    Task {
                        report = await FlightRecorder.shared.report()
                        refreshing = false
                    }
                }
                .disabled(refreshing || preparing)
                Button("Prepare export") {
                    guard !preparing, !refreshing else { return }
                    preparing = true
                    exportFailed = false
                    Task {
                        exportURL = await FlightRecorder.shared.export()
                        exportFailed = exportURL == nil
                        preparing = false
                    }
                }
                .disabled(preparing || refreshing)
                .accessibilityIdentifier("prepareFlightDiagnosticsExport")
                if let exportURL {
                    ShareLink("Share diagnostics file", item: exportURL)
                        .disabled(preparing)
                        .accessibilityIdentifier("shareFlightDiagnosticsExport")
                }
                if exportFailed { Text("Diagnostics export is unavailable. Try again later.").foregroundStyle(.secondary) }
            } footer: {
                Text("Sharing is your choice. The report includes event times and random local correlation IDs; review it before sending.")
            }
        }
        .navigationTitle("Freeze diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            refreshing = true
            report = await FlightRecorder.shared.report()
            refreshing = false
        }
    }
}
