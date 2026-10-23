import SwiftUI

@MainActor
struct PhoneHubView: View {
    @ObservedObject var connections: HubConnectionStore
    @ObservedObject var aggregate: HubAggregateStore
    let onOpenChat: (UUID, URL) -> Void
    let onSettings: () -> Void
    @State private var panel: Panel = .nodes
    @State private var editor: Editor?
    @State private var detailID: UUID?
    @State private var navigationError: String?
    @State private var directSignInID: UUID?
    @State private var showingReset = false

    enum Panel: String, CaseIterable { case nodes = "Nodes", attention = "Attention", sessions = "Sessions" }
    struct Editor: Identifiable { let id = UUID(); var source: HubConnection? }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    // Dedicated text marker: never override descendant AX IDs
                    // by assigning the home ID to the NavigationStack/List.
                    Text("Phone Hub").font(.headline).accessibilityIdentifier("phoneHub.home")
                    Button("Add Connection", systemImage: "plus") { editor = Editor() }
                        .accessibilityIdentifier("phoneHub.addConnection")
                    if connections.connections.isEmpty {
                        Text("Your Hub lives on this phone. Add a Hub or Direct Node to see nodes, attention, and sessions here.")
                            .foregroundStyle(.secondary)
                        Button("Try demo") {
                            do {
                                let source = try connections.save(name: "Demo", kind: .directNode, address: ServerAddress.demo)
                                onOpenChat(source.id, source.url)
                            } catch { navigationError = error.localizedDescription }
                        }.accessibilityIdentifier("phoneHub.demo")
                    }
                }
                Section("Connections") {
                    if let error = connections.persistenceError {
                        Text(error).foregroundStyle(.orange)
                        Button("Reset unreadable catalog", role: .destructive) { showingReset = true }
                            .accessibilityIdentifier("phoneHub.resetCatalog")
                    }
                    ForEach(connections.connections.filter { $0.needsKindReview == true }) { source in
                        VStack(alignment: .leading) {
                            Text(source.name).font(.headline).accessibilityIdentifier("phoneHub.source.\(source.id.uuidString)")
                            Text("Confirm Hub or Direct Node. Discovery could not verify this legacy connection.").font(.caption)
                            Button("Review connection kind") { editor = Editor(source: source) }
                                .accessibilityIdentifier("phoneHub.edit.\(source.id.uuidString)")
                            Button("Remove", role: .destructive) { connections.remove(source.id) }
                                .accessibilityIdentifier("phoneHub.remove.\(source.id.uuidString)")
                        }
                    }
                    ForEach(aggregate.sources) { source in sourceRow(source) }
                }
                Section {
                    HStack {
                        ForEach(Panel.allCases, id: \.self) { candidate in
                            Button(candidate.rawValue) { panel = candidate }
                                .buttonStyle(.bordered)
                                .tint(panel == candidate ? .cyan : .secondary)
                                .accessibilityIdentifier("phoneHub." + candidate.rawValue.lowercased())
                        }
                    }
                    if let navigationError { Text(navigationError).foregroundStyle(.orange) }
                    switch panel {
                    case .nodes: nodes
                    case .attention: attention
                    case .sessions: sessions
                    }
                }
            }
            .navigationTitle("Hub")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape", action: onSettings)
                        .accessibilityIdentifier("phoneHub.settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Refresh", systemImage: "arrow.clockwise") { aggregate.refresh() }
                        .accessibilityIdentifier("phoneHub.refresh")
                }
            }
            .refreshable { aggregate.refresh() }
            .sheet(item: $editor) { editor in
                PhoneHubConnectionEditor(connections: connections, source: editor.source)
                    .safeAreaInset(edge: .top, spacing: 0) { PhoneHubFixtureBanner() }
            }
            .sheet(isPresented: Binding(get: { detailID != nil }, set: { if !$0 { detailID = nil } })) {
                if let id = detailID, let source = aggregate.source(id), let workspace = source.hubWorkspace {
                    VStack(spacing: 0) {
                        Button("Back to Phone Hub") { detailID = nil }
                            .padding().accessibilityIdentifier("phoneHub.details.close")
                        HubView(server: source.connection.url, workspace: workspace,
                                cookieSink: source.nativeCookieSink(epoch: source.authEpoch), onOpenChat: { url in
                            openDetailDestination(url, source: source)
                        }, onSettings: { detailID = nil; onSettings() }, onAuthenticated: {
                            source.hubDetailAuthenticationSucceeded()
                        })
                    }
                    .safeAreaInset(edge: .top, spacing: 0) { PhoneHubFixtureBanner() }
                }
            }
            .sheet(isPresented: Binding(get: { directSignInID != nil }, set: { if !$0 { directSignInID = nil } })) {
                if let id = directSignInID, let source = aggregate.source(id) {
                    PhoneHubDirectAuthentication(source: source)
                        .safeAreaInset(edge: .top, spacing: 0) { PhoneHubFixtureBanner() }
                }
            }
        }
        .onChange(of: connections.connections, initial: true) { _, sources in aggregate.synchronize(sources.filter { $0.needsKindReview != true }) }
        .task { await connections.resolveLegacyKinds() }
        .confirmationDialog("Reset the unreadable catalog?", isPresented: $showingReset, titleVisibility: .visible) {
            Button("Reset saved connections", role: .destructive) { connections.resetUnreadableCatalog() }
        } message: { Text("This explicitly replaces the preserved catalog. You will need to add your connections again.") }
    }

    private func sourceRow(_ source: HubSourceWorkspace) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(source.connection.name).font(.headline)
                .accessibilityIdentifier("phoneHub.source.\(source.id.uuidString)")
            Text("\(source.connection.kind.title) · \(source.connection.url.absoluteString)")
                .font(.caption).foregroundStyle(.secondary)
            if source.store.unauthorized {
                Text("Needs sign-in").foregroundStyle(.orange)
                Button("Sign in") { showAuthentication(source) }
                    .accessibilityIdentifier("phoneHub.signIn.\(source.id.uuidString)")
            } else {
                if source.store.nodesLoading || source.store.attentionLoading { ProgressView("Loading \(source.connection.name)…") }
                if let error = source.error { Text(error).font(.caption).foregroundStyle(.orange) }
            }
            if let status = source.store.attentionClearStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
            if source.store.attentionHasMore && !source.store.unauthorized {
                Button("Load more attention") { Task { await source.store.loadMoreAttention() } }
                    .accessibilityIdentifier("phoneHub.moreAttention.\(source.id.uuidString)")
            }
            HStack {
                Button(connections.selectedID == source.id ? "Selected" : "Select") { connections.select(source.id) }
                    .accessibilityIdentifier("phoneHub.select.\(source.id.uuidString)")
                Button("Edit") { editor = Editor(source: source.connection) }
                    .accessibilityIdentifier("phoneHub.edit.\(source.id.uuidString)")
                Button("Remove", role: .destructive) { connections.remove(source.id) }
                    .accessibilityIdentifier("phoneHub.remove.\(source.id.uuidString)")
            }.buttonStyle(.borderless)
            HStack {
                Button("Retry") {
                    if source.store.unauthorized { showAuthentication(source) }
                    else { Task { await source.store.refresh() } }
                }.accessibilityIdentifier("phoneHub.retry.\(source.id.uuidString)")
                if source.connection.kind == .hub {
                    Button("Manage / Security") { detailID = source.id }
                        .accessibilityIdentifier("phoneHub.details.\(source.id.uuidString)")
                } else {
                    Button("Authentication") { directSignInID = source.id }
                        .accessibilityIdentifier("phoneHub.details.\(source.id.uuidString)")
                    Text("Hub administration unavailable").font(.caption2).foregroundStyle(.secondary)
                }
            }.buttonStyle(.borderless)
        }.padding(.vertical, 4)
    }

    @ViewBuilder private var nodes: some View {
        ForEach(aggregate.nodes) { row in
            Button {
                open(row.node.new_session_path, source: row.source, nodeID: row.node.id)
            } label: {
                VStack(alignment: .leading) {
                    Text(row.node.name).font(.headline)
                    Text("\(row.source.name) · \(row.node.status.state)").font(.caption).foregroundStyle(.secondary)
                    Text(row.node.sessions?.count_label ?? "New conversation").font(.caption)
                }
            }.accessibilityIdentifier("phoneHub.node.\(row.source.id.uuidString).\(row.node.id)")
                .disabled(!row.node.status.reachable)
        }
        if aggregate.nodes.isEmpty { Text("No nodes available yet").foregroundStyle(.secondary) }
    }
    @ViewBuilder private var sessions: some View {
        ForEach(aggregate.sessions) { row in
            Button { open(row.session.resume_path, source: row.source, nodeID: row.node.id) } label: {
                VStack(alignment: .leading) {
                    Text(row.session.short_title.isEmpty ? "Session \(row.session.number.map(String.init) ?? row.session.id)" : row.session.short_title)
                    Text("\(row.source.name) · \(row.node.name)").font(.caption).foregroundStyle(.secondary)
                }
            }.accessibilityIdentifier("phoneHub.session.\(row.source.id.uuidString).\(row.node.id).\(row.session.id)")
        }
        if aggregate.sessions.isEmpty { Text("No sessions available yet").foregroundStyle(.secondary) }
    }
    @ViewBuilder private var attention: some View {
        ForEach(aggregate.attention) { row in
            VStack(alignment: .leading) {
                Button { open(row.path, source: row.source, nodeID: row.nodeID) } label: {
                    VStack(alignment: .leading) {
                        Text(row.title)
                        Text("\(row.source.name) · \(row.nodeID) · \(row.inputRequired ? "Input required" : "Unseen")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.accessibilityIdentifier("phoneHub.attention.\(row.source.id.uuidString).\(row.nodeID).\(row.sessionID).\(row.itemKey)")
                if let request = row.seenRequest {
                    Button("Mark seen") {
                        guard let source = aggregate.source(row.source.id),
                              let item = source.store.inbox.first(where: { $0.node_id == row.nodeID && $0.session_id == request.session_id && $0.store_instance_id == request.store_instance_id && $0.attention_seq == request.attention_seq }) else { return }
                        Task { await source.store.markInboxItemSeen(item) }
                    }.buttonStyle(.borderless)
                }
            }
        }
        if aggregate.attention.isEmpty { Text("No attention items available").foregroundStyle(.secondary) }
    }
    private func showAuthentication(_ source: HubSourceWorkspace) {
        if source.connection.kind == .hub { detailID = source.id }
        else { directSignInID = source.id }
    }
    private func open(_ path: String, source: HubConnection, nodeID: String) {
        guard let url = aggregate.destination(path: path, sourceID: source.id, nodeID: nodeID) else {
            navigationError = "The source supplied an unsafe chat path. Navigation blocked."
            return
        }
        onOpenChat(source.id, url)
    }
    private func openDetailDestination(_ url: URL, source: HubSourceWorkspace) {
        guard source.isActive, !source.store.unauthorized else { return }
        if url == source.connection.url {
            detailID = nil
            onOpenChat(source.id, url)
            return
        }
        let nodeIDs = Set(source.store.nodes.map(\.id) + source.store.inputRequired.map(\.node_id) + source.store.inbox.map(\.node_id))
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let path = parts.percentEncodedPath + (parts.percentEncodedQuery.map { "?" + $0 } ?? "")
        guard url.scheme == source.connection.url.scheme, url.host == source.connection.url.host, url.port == source.connection.url.port,
              nodeIDs.contains(where: { aggregate.destination(path: path, sourceID: source.id, nodeID: $0) == url }) else {
            navigationError = "The source supplied an unsafe chat path. Navigation blocked."
            return
        }
        detailID = nil
        onOpenChat(source.id, url)
    }
}

/// Dedicated marker, never an AX identifier on a broad container.
struct PhoneHubFixtureBanner: View {
    var body: some View {
        if PhoneHubFixture.isEnabled {
            Text("DEMO FIXTURE · LOCAL")
                .font(.caption.bold()).frame(maxWidth: .infinity).padding(6)
                .background(.orange.opacity(0.25))
                .accessibilityIdentifier("phoneHub.fixtureBanner")
        }
    }
}

@MainActor private struct PhoneHubConnectionEditor: View {
    @ObservedObject var connections: HubConnectionStore
    let source: HubConnection?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var address: String
    @State private var kind: HubConnection.Kind
    @State private var error: String?
    init(connections: HubConnectionStore, source: HubConnection?) {
        self.connections = connections
        self.source = source
        _name = State(initialValue: source?.name ?? "")
        _address = State(initialValue: source?.url.absoluteString ?? "")
        _kind = State(initialValue: source?.kind ?? .hub)
    }
    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name).accessibilityIdentifier("phoneHub.connection.name")
                Picker("Kind", selection: $kind) {
                    ForEach(HubConnection.Kind.allCases, id: \.self) { kind in Text(kind.title).tag(kind) }
                }.pickerStyle(.segmented).accessibilityIdentifier("phoneHub.connection.kind")
                TextField("https://server.example/prefix/", text: $address)
                    .textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("phoneHub.connection.url")
                Text("Choose the server kind explicitly. Sign-in is separate; do not include a token in the URL.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.orange) }
            }
            .navigationTitle(source == nil ? "Add Connection" : "Edit Connection")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("phoneHub.connection.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try connections.save(id: source?.id, name: name, kind: kind, address: address)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }.accessibilityIdentifier("phoneHub.connection.save")
                }
            }
        }
    }
}

@MainActor private struct PhoneHubDirectAuthentication: View {
    @ObservedObject var source: HubSourceWorkspace
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var signingIn = false
    @State private var login = NativeLogin()
    var body: some View {
        NavigationStack {
            Form {
                Section(source.connection.name) {
                    Text("Use this Direct Node’s passkey or bearer token. Credentials are isolated from every other connection.")
                    Button("Sign in with passkey") {
                        Task {
                            guard let epoch = await source.prepareAuthentication() else { return }
                            signingIn = true
                            login.cookieSink = source.nativeCookieSink(epoch: epoch)
                            login.signIn(to: source.connection.url) { result in
                                signingIn = false
                                switch result {
                                case .success: Task { await source.authenticationSucceeded(epoch: epoch) }
                                case .failure(let error): source.authenticationError = error.localizedDescription
                                }
                            }
                        }
                    }.disabled(signingIn || PhoneHubFixture.isEnabled)
                    SecureField("Node token", text: $token).accessibilityIdentifier("phoneHub.direct.token")
                    Button("Sign in with token") {
                        let candidate = token
                        token = ""
                        signingIn = true
                        Task { await source.signInWithBearer(candidate); signingIn = false }
                    }.disabled(token.isEmpty || signingIn).accessibilityIdentifier("phoneHub.direct.signIn")
                    if signingIn { ProgressView("Signing in…") }
                    if let error = source.authenticationError { Text(error).foregroundStyle(.orange) }
                }
                Text("Direct nodes do not support Hub node administration, delegation, or Hub credential management here.")
                    .font(.caption).foregroundStyle(.secondary)
            }.navigationTitle("Node Authentication")
                .toolbar { Button("Done") { dismiss() } }
        }
    }
}
