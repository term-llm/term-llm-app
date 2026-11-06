import SwiftUI
import TermLLMMacKit

struct RootView: View {
    @EnvironmentObject private var model: CompanionModel

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar()
            Divider()
            content
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var content: some View {
        switch model.tab {
        case .chat:
            ChatPane()
        case .setup:
            SetupView()
        case .diagnostics:
            DiagnosticsView()
        }
    }
}

private struct HeaderBar: View {
    @EnvironmentObject private var model: CompanionModel

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(model.statusColor)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text("term-llm")
                    .font(.headline)
                Text(model.statusTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let status = model.status, let url = status.url {
                Text(url)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if model.busy {
                ProgressView().controlSize(.small)
            }
            Picker("View", selection: $model.tab) {
                ForEach(CompanionTab.allCases) { tab in
                    Label(tab.rawValue, systemImage: tab.symbol).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 330)
            ServiceControls(compact: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

private struct ChatPane: View {
    @EnvironmentObject private var model: CompanionModel
    @State private var loadError: String?

    var body: some View {
        Group {
            if model.isChatAvailable, let endpoint = model.endpoint, let token = model.token {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Label("Authenticated local chat", systemImage: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let outcome = model.sessionOutcome {
                            Text(outcome.isAuthenticated ? "Protected API verified" : outcome.description)
                                .font(.caption)
                                .foregroundStyle(outcome.isAuthenticated ? .green : .orange)
                        }
                        Spacer()
                        Button("Reload") { ChatReloadBus.shared.reload() }
                            .controlSize(.small)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    Divider()
                    ChatWebView(endpoint: endpoint, token: token, loadError: $loadError)
                        .id("\(endpoint.baseURL.absoluteString)|\(token)")
                }
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text(readinessTitle)
                        .font(.title3.weight(.semibold))
                    Text(readinessDetail)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 460)
                    Button("Open Setup") { model.tab = .setup }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(40)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let loadError {
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
            }
        }
    }

    private var readinessTitle: String {
        switch model.readiness {
        case .ready: return "Preparing your local chat"
        case .needsServiceInstall: return "Set up the local service first"
        case .needsStart: return "The local service is stopped"
        case .needsAuthentication: return "Sign-in to the local service is not ready"
        case .passkeyEnrollmentRequired: return "Passkey enrollment is required"
        case .unmanagedService: return "The local service is not managed by this app"
        case .unhealthy(let reason): return "The local service is unhealthy: \(reason)"
        case .unsupported(let reason): return "This service cannot be opened: \(reason)"
        }
    }

    private var readinessDetail: String {
        switch model.readiness {
        case .ready: return "The service is running and the local bearer credential was accepted."
        case .needsServiceInstall: return "Install or select the CLI, then create an owned local web service."
        case .needsStart: return "Start the service from the menu bar or Setup; starting does not change your login preference."
        case .needsAuthentication: return "The app could not read the core's managed token. Check Diagnostics."
        case .passkeyEnrollmentRequired:
            return "This service uses passkey authentication and has no enrolled credential. Enroll a passkey in a browser, or create a fresh service with the app's explicit bearer loopback mode."
        case .unmanagedService:
            return "An existing service that this app does not own was found. The app will not modify it; remove or adopt it deliberately."
        case .unhealthy(let reason): return reason
        case .unsupported(let reason): return reason
        }
    }
}

/// Small app-wide reload channel so the toolbar can reload the retained web view
/// without recreating or discarding it.
final class ChatReloadBus {
    static let shared = ChatReloadBus()
    private var handler: (() -> Void)?
    private init() {}

    func register(_ handler: @escaping () -> Void) { self.handler = handler }
    func reload() { handler?() }
}
