import AppKit
import SwiftUI
import TermLLMMacKit

struct DiagnosticsView: View {
    @EnvironmentObject private var model: CompanionModel
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Diagnostics").font(.title2.weight(.semibold))
                    Text("What the app observes, with credentials redacted.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(copied ? "Copied" : "Copy Report") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(model.diagnosticsText(), forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
                }
                Button("Refresh") { Task { await model.refresh() } }
                    .disabled(model.busy)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.diagnostics.checks) { check in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: symbol(for: check.level))
                                .foregroundStyle(color(for: check.level))
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(check.title).font(.callout.weight(.semibold))
                                Text(check.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }

            HStack {
                Text(model.controller?.logsFollowCommand() ?? "term-llm service logs web")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Last refresh \(model.lastRefresh.formatted(date: .omitted, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }

    private func symbol(for level: DiagnosticLevel) -> String {
        switch level {
        case .ok: return "checkmark.circle.fill"
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }

    private func color(for level: DiagnosticLevel) -> Color {
        switch level {
        case .ok: return .green
        case .info: return .secondary
        case .warning: return .orange
        case .failed: return .red
        }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject private var model: CompanionModel
    @Environment(\.openWindow) private var openWindow

    private var serviceAutostart: Binding<Bool> {
        Binding(get: { model.status?.autostart ?? false },
                set: { model.setServiceAutostart($0) })
    }

    private var loginItem: Binding<Bool> {
        Binding(get: { model.loginItemEnabled },
                set: { model.setLoginItem($0) })
    }

    var body: some View {
        Text(statusLine)
        Divider()
        Button("Open TermLLM") { show(.setup) }
        Button("Open Local Chat") { model.openChat(); show(.chat) }
        Divider()
        if model.status?.running == true {
            Button("Stop Local Service") { model.stopService() }
        } else {
            Button("Start Local Service") { model.startService() }
        }
        Button("Restart Local Service") { model.restartService() }
        Toggle("Start local service at login", isOn: serviceAutostart)
            .disabled(model.status?.installed != true)
        Toggle("Open menu-bar app at login", isOn: loginItem)
        Divider()
        Button("Permissions & Diagnostics…") { show(.diagnostics) }
        Divider()
        Button("Quit menu bar app") { model.quitMenuBarApp() }
        Button("Quit and stop local service…") { model.confirmStopAndQuit() }
            .disabled(model.status?.installed != true)
    }

    private var statusLine: String {
        if let status = model.status {
            var line = "term-llm · \(model.statusTitle)"
            if let port = status.port { line += " · 127.0.0.1:\(port)" }
            return line
        }
        return "term-llm · \(model.statusTitle)"
    }

    private func show(_ tab: CompanionTab) {
        model.tab = tab
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
