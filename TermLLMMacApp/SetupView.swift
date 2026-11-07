import SwiftUI
import TermLLMMacKit

struct ServiceControls: View {
    @EnvironmentObject private var model: CompanionModel
    var compact = false

    var body: some View {
        HStack(spacing: 8) {
            if model.status?.running == true {
                Button("Stop") { model.stopService() }
                    .help("Stop the service. Your start-at-login preference is preserved.")
            } else {
                Button("Start") { model.startService() }
                    .help("Start the service. Your start-at-login preference is not changed.")
            }
            Button("Restart") { model.restartService() }
                .help("Restart the running service without changing the login preference.")
        }
        .controlSize(compact ? .small : .regular)
        .disabled(model.busy || model.status?.installed != true)
    }
}

struct SetupView: View {
    @EnvironmentObject private var model: CompanionModel

    private var serviceAutostart: Binding<Bool> {
        Binding(get: { model.status?.autostart ?? false },
                set: { model.setServiceAutostart($0) })
    }

    private var loginItem: Binding<Bool> {
        Binding(get: { model.loginItemEnabled },
                set: { model.setLoginItem($0) })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                intro
                if let error = model.actionError {
                    banner(error, color: .red, symbol: "exclamationmark.triangle.fill")
                }
                if let action = model.lastAction {
                    banner(action, color: .secondary, symbol: "info.circle")
                }
                cliSection
                serviceSection
                chatSection
                appLoginSection
            }
            .padding(22)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your Mac companion")
                .font(.largeTitle.weight(.semibold))
            Text("Install a real term-llm command, run the local service independently of this window, and chat through the server's own authenticated web UI.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var cliSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                statusLine(
                    title: "Command-line tool",
                    ok: model.selection != nil && model.cliProblems.isEmpty,
                    detail: cliDetail
                )
                if let selection = model.selection {
                    Text(selection.binaryPath)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
                if !model.cliProblems.isEmpty {
                    Text(model.cliProblems.map(\.description).joined(separator: " "))
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if let link = model.pathLink {
                    Text(pathLinkDetail(link))
                        .font(.caption)
                        .foregroundStyle(linkIsWarning(link) ? .orange : .secondary)
                }
                HStack {
                    Button("Install Bundled CLI") { model.installBundledCLI() }
                        .disabled(model.busy)
                        .help(model.payloadPresent
                              ? "Copy the app's term-llm payload to ~/Library/Application Support/TermLLM/bin."
                              : "This build has no CLI payload.")
                    Button("Find Existing Installations") { model.detectExternalCLIs() }
                        .disabled(model.busy)
                    Button("Re-verify") { model.verifyCLI() }
                        .disabled(model.busy)
                }
                if !model.externalCandidates.isEmpty {
                    Divider()
                    Text("Existing installations (used as-is; updates stay with their owner)")
                        .font(.caption.weight(.semibold))
                    ForEach(model.externalCandidates, id: \.path) { candidate in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.version.isEmpty ? candidate.provenance : "\(candidate.provenance) · \(candidate.version)")
                                    .font(.callout)
                                Text(candidate.path)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Use") { model.adopt(candidate) }
                                .disabled(model.busy)
                        }
                    }
                }
            }
            .padding(6)
        } label: {
            Label("1 · CLI", systemImage: "terminal")
                .font(.headline)
        }
    }

    private var cliDetail: String {
        if let error = model.selectionError { return error }
        guard let selection = model.selection else {
            return model.payloadPresent
                ? "Not installed. The app contains a bundled payload (version \(model.payloadVersion.isEmpty ? "development" : model.payloadVersion))."
                : "Not installed, and this build has no bundled payload."
        }
        let source = selection.source == .bundled ? "Bundled" : selection.provenance
        let version = selection.version.isEmpty ? "version unknown" : selection.version
        return "\(source) · \(version)"
    }

    private var serviceSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                statusLine(title: "Local web service", ok: model.status?.state == .ready,
                           detail: serviceDetail)
                if let status = model.status {
                    if let url = status.url {
                        Text(url)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    }
                    if status.auth == "passkey", status.enrollment == .pending {
                        banner("This passkey service has no enrolled credential. The app will not bypass it. Enroll in a browser or create a fresh service below.",
                               color: .orange, symbol: "key.slash")
                    }
                }
                if let error = model.statusError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Button(model.status?.installed == true ? "Reinstall Service" : "Create Local Service") {
                        model.installService()
                    }
                    .disabled(model.busy || model.controller == nil)
                    ServiceControls()
                }
                Toggle("Start local service at login", isOn: serviceAutostart)
                    .disabled(model.busy || model.status?.installed != true)
                Text("The service keeps running when this window or the menu-bar app is closed. Starting and stopping it never rewrites this preference.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.status?.installed == true {
                    Text("Managed by term-llm: \(model.controller?.logsFollowCommand() ?? "term-llm service logs web")")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(6)
        } label: {
            Label("2 · Local service", systemImage: "gearshape.2")
                .font(.headline)
        }
    }

    private var serviceDetail: String {
        guard let status = model.status else {
            return model.controller == nil ? "Select a working CLI first." : "No service status yet."
        }
        switch status.state {
        case .ready:
            return "Running (pid \(status.pid.map(String.init) ?? "?")) · \(status.auth ?? "unknown auth") · autostart \(status.autostart ? "on" : "off")"
        case .stopped:
            return "Stopped · autostart \(status.autostart ? "on" : "off")"
        case .notInstalled:
            return "Not installed. The app creates a fresh loopback service with explicit bearer authentication."
        case .notRegistered:
            return "Saved configuration without a registered service. Reinstall to repair."
        case .unmanaged:
            return "An unmanaged service exists and is left untouched."
        case .unhealthy:
            return "Running but not healthy: \(status.healthError ?? "health check failed")"
        case .error:
            return status.error ?? "The service manager reported an error."
        }
    }

    private var chatSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                statusLine(title: "Authenticated local chat", ok: model.isChatAvailable,
                           detail: chatDetail)
                Text("The app reads the core's managed bearer token from your login Keychain on demand and injects it only into the embedded chat for the owned loopback origin. It never puts the token in a URL. Ordinary remote connections keep normal HTTPS validation; passkey services keep their own sign-in and are never bypassed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Open Chat") { model.openChat() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.busy || model.status?.state != .ready)
                    Button("Verify Sign-in") { model.verifySession() }
                        .disabled(model.token == nil)
                }
            }
            .padding(6)
        } label: {
            Label("3 · Chat", systemImage: "bubble.left.and.bubble.right")
                .font(.headline)
        }
    }

    private var chatDetail: String {
        if let outcome = model.sessionOutcome {
            return outcome.description
        }
        switch model.readiness {
        case .ready: return "Ready; verifying the local session."
        case .needsServiceInstall: return "Create the local service first."
        case .needsStart: return "Start the local service."
        case .needsAuthentication: return "Waiting for the local credential."
        case .passkeyEnrollmentRequired: return "Passkey enrollment is pending; the app will not fake it."
        case .unmanagedService: return "An unmanaged service blocks this app's local chat."
        case .unhealthy(let reason): return reason
        case .unsupported(let reason): return reason
        }
    }

    private var appLoginSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Open menu-bar app at login", isOn: loginItem)
                    .disabled(model.busy)
                Text("This is the app's own launch agent, separate from the service. Quitting the menu bar does not stop the server, and stopping the server does not remove the app from login items.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(6)
        } label: {
            Label("4 · App login", systemImage: "menubar.rectangle")
                .font(.headline)
        }
    }

    private func statusLine(title: String, ok: Bool, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ok ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func banner(_ text: String, color: Color, symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).font(.callout).foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func linkIsWarning(_ status: PATHLinkStatus) -> Bool {
        switch status {
        case .collision, .failed: return true
        default: return false
        }
    }

    private func pathLinkDetail(_ status: PATHLinkStatus) -> String {
        switch status {
        case .linked(let path): return "Linked \(path) → managed CLI"
        case .alreadyLinked(let path): return "\(path) already points at the managed CLI"
        case .notLinked(let path): return "\(path) is not linked yet; installing the bundled CLI creates it"
        case .skippedExternal: return "Using the external installation's own command"
        case .collision(let path): return "\(path) belongs to something else and was not changed"
        case .failed(let reason): return "Could not link the command: \(reason)"
        }
    }
}
