import SwiftUI

@MainActor struct PhoneHubConnectionEditor: View {
    @ObservedObject var connections: HubConnectionStore
    let source: HubConnection?
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var address: String
    @State private var isSaving = false
    @State private var saved: HubConnection?
    @State private var error: String?
    @FocusState private var focusedField: Field?
    private enum Field { case address, name }

    init(connections: HubConnectionStore, source: HubConnection?, initialAddress: String? = nil, onDone: @escaping () -> Void = {}) {
        self.connections = connections
        self.source = source
        self.onDone = onDone
        _name = State(initialValue: source?.name ?? "")
        _address = State(initialValue: initialAddress ?? source?.url.absoluteString ?? "")
    }

    private var serverURL: URL? { HubConnectionStore.canonicalURL(address) }
    private var connectionName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? serverURL?.host ?? "Connection" : trimmed
    }

    var body: some View {
        NavigationStack {
            Group {
                if let saved {
                    VStack(spacing: 20) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 64)).foregroundStyle(.green)
                            .accessibilityHidden(true)
                        Text(source == nil ? "Connection added" : "Connection updated")
                            .font(.title2.bold())
                            .accessibilityIdentifier("phoneHub.connection.success")
                        Text(saved.name).font(.headline)
                        Text("\(saved.kind.title) · \(saved.url.host ?? saved.url.absoluteString)")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text("You’re ready to explore. If this server needs sign-in, you’ll find it on the Hub.")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Back to Agents") { dismiss(); onDone() }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                            .accessibilityIdentifier("phoneHub.connection.done")
                    }
                    .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.platformGroupedBackground)
                } else {
                    Form {
                        Section {
                            VStack(alignment: .leading, spacing: 12) {
                                Label("Connect your server", systemImage: "network")
                                    .font(.headline)
                                Text("Paste an address. We’ll detect the server type for you.")
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                        Section {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Server address").font(.subheadline.weight(.medium))
                                HStack {
                                    TextField("https://server.example/", text: $address)
                                        .urlTextEntry().autocorrectionDisabled()
                                        .focused($focusedField, equals: .address)
                                        .submitLabel(.next)
                                        .onSubmit { focusedField = .name }
                                        .accessibilityIdentifier("phoneHub.connection.url")
                                    if !address.isEmpty {
                                        Button {
                                            address = ""
                                            focusedField = .address
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundStyle(.secondary)
                                                .frame(minWidth: 44, minHeight: 44)
                                        }
                                        .buttonStyle(.borderless)
                                        .accessibilityLabel("Clear server address")
                                        .accessibilityIdentifier("phoneHub.connection.clearAddress")
                                    }
                                }
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Name (optional)").font(.subheadline.weight(.medium))
                                TextField("My server", text: $name)
                                    .focused($focusedField, equals: .name)
                                    .submitLabel(.go)
                                    .onSubmit { if serverURL != nil { save() } }
                                    .accessibilityIdentifier("phoneHub.connection.name")
                            }
                        } footer: {
                            Text("Hub or Direct Node is detected automatically. Sign in after connecting—never put a token in the address.")
                            if serverURL?.host?.lowercased().hasSuffix(".ts.net") == true {
                                Text("For Tailscale, connect both devices to your tailnet and use the full HTTPS name covered by the server’s certificate. The server must offer HTTPS, for example through Tailscale Serve.")
                            }
                        }
                        .disabled(isSaving)
                        if isSaving {
                            Section {
                                HStack(spacing: 14) {
                                    ProgressView()
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Checking your server…").font(.headline)
                                        Text("Looking for a Hub or Direct Node at \(serverURL?.host ?? "this address"). This usually takes a few seconds.")
                                            .font(.subheadline).foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 8)
                                .accessibilityElement(children: .combine)
                                .accessibilityIdentifier("phoneHub.connection.checking")
                            }
                        } else if let error {
                            Section {
                                Label("Couldn’t connect yet", systemImage: "exclamationmark.triangle")
                                    .font(.headline).foregroundStyle(.orange)
                                    .accessibilityIdentifier("phoneHub.connection.error")
                                Text(error).font(.subheadline)
                                Text("Check that the address includes any server path, and that the server is online and reachable from this device.")
                                    .font(.subheadline).foregroundStyle(.secondary)
                                Button("Try again", action: save)
                                    .disabled(serverURL == nil)
                                    .accessibilityIdentifier("phoneHub.connection.retry")
                            }
                        }
                    }
                    .scrollDismissesKeyboard(.interactively)
                }
            }
            .task(id: isSaving) {
                guard isSaving else { return }
                do {
                    saved = try await connections.saveDetectingKind(id: source?.id, name: connectionName, address: address)
                } catch is CancellationError {
                    // Leaving the sheet cancels discovery without saving.
                } catch { self.error = error.localizedDescription }
                isSaving = false
            }
            .sensoryFeedback(.success, trigger: saved != nil)
            .sensoryFeedback(.error, trigger: error != nil)
            .navigationTitle(saved == nil ? (source == nil ? "Add Connection" : "Edit Connection") : "All set")
            .inlineNavigationTitle()
            .toolbar {
                if saved == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }.accessibilityIdentifier("phoneHub.connection.cancel")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(isSaving ? "Checking…" : (source == nil ? "Connect" : "Save"), action: save)
                            .disabled(isSaving || serverURL == nil)
                            .accessibilityIdentifier("phoneHub.connection.save")
                    }
                }
            }
        }
    }

    private func save() {
        guard !isSaving else { return }
        focusedField = nil
        error = nil
        isSaving = true
    }
}
