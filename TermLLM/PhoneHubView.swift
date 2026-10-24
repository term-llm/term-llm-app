import SwiftUI

@MainActor
struct PhoneHubView: View {
    @ObservedObject var connections: HubConnectionStore
    @ObservedObject var aggregate: HubAggregateStore
    @Binding var pendingConnectionURL: URL?
    let isVisible: Bool
    let onOpenChat: (UUID, URL) -> Void
    let onSettings: () -> Void
    @State private var panel: Panel = .nodes
    @State private var showOfflineNodes = false
    @State private var editor: Editor?
    @State private var detailID: UUID?
    @State private var navigationError: String?
    @State private var directSignInID: UUID?
    @State private var showingReset = false
    @State private var showingConnections = false

    enum Panel: String, CaseIterable { case nodes = "Agents", attention = "Attention", sessions = "Sessions" }
    struct Editor: Identifiable { let id = UUID(); var source: HubConnection?; var address: String? }

    private var loadingSources: [HubSourceWorkspace] {
        aggregate.sources.filter { !$0.store.unauthorized && ($0.store.nodesLoading || $0.store.attentionLoading) }
    }
    private var connectionIssueCount: Int {
        connections.connections.filter { $0.needsKindReview == true }.count +
        aggregate.sources.filter { $0.store.unauthorized || $0.error != nil }.count +
        (connections.persistenceError == nil ? 0 : 1)
    }
    private var isRefreshing: Bool { aggregate.sources.contains { $0.store.refreshing } }

    var body: some View {
        NavigationStack {
            List {
                if connections.connections.isEmpty {
                    Section {
                        VStack(spacing: 16) {
                            Image(systemName: "network").font(.largeTitle).foregroundStyle(.secondary)
                            Text("Your agents, all in one place").font(.title3.bold())
                            Text("Add a connection to bring your agents together.")
                                .foregroundStyle(.secondary)
                            Button("Add Connection", systemImage: "plus") { editor = Editor() }
                                .buttonStyle(.borderedProminent)
                                .accessibilityIdentifier("phoneHub.addConnection")
                            Button("Try demo") {
                                do {
                                    let source = try connections.save(name: "Demo", kind: .directNode, address: ServerAddress.demo)
                                    onOpenChat(source.id, source.url)
                                } catch { navigationError = error.localizedDescription }
                            }.accessibilityIdentifier("phoneHub.demo")
                        }
                        .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.vertical, 28)
                    }
                }
                if !connections.connections.isEmpty {
                    Section {
                        HStack {
                            PhoneHubPanelSelector(selection: panel, onSelect: { panel = $0 })
                                .equatable()
                            Spacer()
                            if panel == .nodes {
                                if aggregate.nodes.contains(where: { !$0.node.status.reachable }) || showOfflineNodes {
                                    Button(showOfflineNodes ? "Online only" : "Show all (\(aggregate.nodes.filter { !$0.node.status.reachable }.count) offline)") {
                                        showOfflineNodes.toggle()
                                    }
                                    .font(.caption)
                                    .buttonStyle(.borderless)
                                    .accessibilityIdentifier("phoneHub.nodes.showAll")
                                    .accessibilityValue(showOfflineNodes ? "All agents" : "Online only")
                                } else {
                                    Text("\(aggregate.nodes.count) online").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(minHeight: 44)
                        .listRowSeparator(.hidden)
                        if let navigationError { Text(navigationError).foregroundStyle(.orange) }
                        switch panel {
                        case .nodes: nodes
                        case .attention: attention
                        case .sessions: sessions
                        }
                    }
                }
            }
            // Polling must not animate or rebuild the surrounding list layout.
            .transaction { $0.animation = nil }
            .navigationTitle("Agents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(isVisible ? .visible : .hidden, for: .navigationBar)
            .toolbar {
                if isVisible && !showingConnections {
                    ToolbarItem(placement: .principal) {
                        Text("Agents").font(.headline).accessibilityIdentifier("phoneHub.home")
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Button { showingConnections = true } label: {
                            Text("Connections")
                                .font(.subheadline.weight(.medium))
                                .overlay(alignment: .topTrailing) {
                                    Circle().fill(.orange).frame(width: 7, height: 7)
                                        .offset(x: 4, y: -3).opacity(connectionIssueCount > 0 ? 1 : 0)
                                }
                        }
                        .accessibilityLabel("Connections")
                        .accessibilityValue(connectionIssueCount == 0 ? "\(connections.connections.count) saved" : "\(connectionIssueCount) need attention")
                        .accessibilityIdentifier("phoneHub.connections")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Settings", systemImage: "gearshape", action: onSettings)
                            .accessibilityIdentifier("phoneHub.settings")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { aggregate.refresh() } label: {
                            ZStack {
                                Image(systemName: "arrow.clockwise").opacity(loadingSources.isEmpty ? 1 : 0)
                                ProgressView().opacity(loadingSources.isEmpty ? 0 : 1)
                            }
                            .frame(width: 24, height: 24)
                        }
                        .accessibilityLabel(loadingSources.isEmpty ? "Refresh" : "Syncing connections")
                        .disabled(isRefreshing || aggregate.sources.isEmpty)
                        .accessibilityIdentifier("phoneHub.refresh")
                    }
                }
            }
            .navigationDestination(isPresented: $showingConnections) { connectionManagement }
            .refreshable { await aggregate.refreshAndWait() }
            .sheet(item: $editor) { editor in
                PhoneHubConnectionEditor(connections: connections, source: editor.source, initialAddress: editor.address, onDone: { showingConnections = false })
                    .safeAreaInset(edge: .bottom, spacing: 0) { PhoneHubFixtureBanner() }
            }
            .sheet(isPresented: Binding(get: { detailID != nil }, set: { if !$0 { detailID = nil } })) {
                if let id = detailID, let source = aggregate.source(id), let workspace = source.hubWorkspace {
                    VStack(spacing: 0) {
                        Button("Back to Agents") { detailID = nil }
                            .padding().accessibilityIdentifier("phoneHub.details.close")
                        HubView(source: source, workspace: workspace, onOpenChat: { url in
                            openDetailDestination(url, nodeID: nil, source: source)
                        }, onOpenNodeChat: { url, nodeID in
                            openDetailDestination(url, nodeID: nodeID, source: source)
                        }, onSettings: { detailID = nil; showingConnections = true })
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) { PhoneHubFixtureBanner() }
                }
            }
            .sheet(isPresented: Binding(get: { directSignInID != nil }, set: { if !$0 { directSignInID = nil } })) {
                if let id = directSignInID, let source = aggregate.source(id) {
                    PhoneHubDirectAuthentication(source: source)
                        .safeAreaInset(edge: .bottom, spacing: 0) { PhoneHubFixtureBanner() }
                }
            }
        }
        .onChange(of: connections.connections, initial: true) { _, sources in aggregate.synchronize(sources.filter { $0.needsKindReview != true }) }
        .task { await connections.resolveLegacyKinds() }
        .onChange(of: isVisible) { _, visible in
            guard !visible else { return }
            // A chat/push/voice handoff must not leave administration or an
            // authentication sheet over the retained browser destination.
            showingConnections = false
            detailID = nil
            directSignInID = nil
            editor = nil
        }
        .onChange(of: pendingConnectionURL, initial: true) { _, url in
            guard let url else { return }
            let canonical = HubConnectionStore.canonicalURL(url.absoluteString)
            editor = Editor(source: connections.connections.first { $0.url == canonical }, address: url.absoluteString)
            pendingConnectionURL = nil
        }
        .confirmationDialog("Reset the unreadable catalog?", isPresented: $showingReset, titleVisibility: .visible) {
            Button("Reset saved connections", role: .destructive) { connections.resetUnreadableCatalog() }
        } message: { Text("This explicitly replaces the preserved catalog. You will need to add your connections again.") }
    }

    private var connectionManagement: some View {
        List {
            Section {
                Button("Add Connection", systemImage: "plus") { editor = Editor() }
                    .accessibilityIdentifier("phoneHub.addConnection")
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
                        Text("Could not identify this server. Check its address and retry detection.").font(.caption)
                        Button("Review connection") { editor = Editor(source: source) }
                            .accessibilityIdentifier("phoneHub.edit.\(source.id.uuidString)")
                        Button("Remove", role: .destructive) { connections.remove(source.id) }
                            .accessibilityIdentifier("phoneHub.remove.\(source.id.uuidString)")
                    }
                }
                ForEach(aggregate.sources) { source in sourceRow(source) }
            }
        }
        .transaction { $0.animation = nil }
        .navigationTitle("Connections")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Agents", systemImage: "chevron.left") { showingConnections = false }
                    .accessibilityIdentifier("phoneHub.connections.close")
            }
        }
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
                sourceSyncStatus(source)
                if let error = source.error {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
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
                Button(source.error == nil ? "Refresh" : "Retry") {
                    if source.store.unauthorized { showAuthentication(source) }
                    else { Task { await source.store.refresh() } }
                }
                .disabled(source.store.refreshing)
                .accessibilityIdentifier("phoneHub.retry.\(source.id.uuidString)")
                if source.connection.kind == .hub {
                    Button("Manage Server") { detailID = source.id }
                        .accessibilityIdentifier("phoneHub.details.\(source.id.uuidString)")
                } else {
                    Button("Authentication") { directSignInID = source.id }
                        .accessibilityIdentifier("phoneHub.details.\(source.id.uuidString)")
                }
            }.buttonStyle(.borderless)
        }.padding(.vertical, 4)
    }

    /// A permanent status slot: refreshing changes its contents, never the
    /// number/height of rows above the node list or the user's scroll anchor.
    private func sourceSyncStatus(_ source: HubSourceWorkspace) -> some View {
        let busy = source.store.nodesLoading || source.store.attentionLoading
        let verified = source.store.nodesVerified && source.store.attentionVerified
        let failed = source.error != nil
        let message = failed ? "Couldn’t update" : (busy ? "Updating…" : (verified ? "Up to date" : "Waiting for server…"))
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                ZStack {
                    Image(systemName: failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(failed ? Color.orange : Color.green)
                        .opacity(busy || !verified && !failed ? 0 : 1)
                    ProgressView().controlSize(.small).opacity(busy ? 1 : 0)
                }
                .frame(width: 18, height: 18)
                Text(message).font(.caption.weight(.medium)).lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(source.store.nodesLoading ? "phoneHub.nodesLoading.\(source.id.uuidString)" : "phoneHub.syncStatus.\(source.id.uuidString)")
            Group {
                if let updated = source.store.lastNodesRefresh {
                    Text("Updated \(updated, style: .relative) ago")
                } else {
                    Text("Waiting for first update")
                }
            }
            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    @ViewBuilder private var nodes: some View {
        let allNodes = aggregate.nodes
        let visibleNodes = allNodes.filter { showOfflineNodes || $0.node.status.reachable }
        ForEach(visibleNodes) { row in
            Button {
                open(row.node.new_session_path, source: row.source, nodeID: row.node.id)
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.node.name).font(.headline).foregroundStyle(.primary)
                        Text("\(row.source.name) · \(row.node.status.reachable ? "Online" : "Offline")")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text(row.node.sessions?.count_label ?? "New conversation")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityIdentifier("phoneHub.node.\(row.source.id.uuidString).\(row.node.id)")
                .disabled(!row.node.status.reachable)
        }
        if visibleNodes.isEmpty { emptyPanel(.nodes) }
    }
    @ViewBuilder private var sessions: some View {
        ForEach(aggregate.sessions) { row in
            Button { open(row.session.resume_path, source: row.source, nodeID: row.node.id) } label: {
                VStack(alignment: .leading) {
                    Text(row.session.short_title.isEmpty ? "Session \(row.session.number.map(String.init) ?? row.session.id)" : row.session.short_title)
                        .foregroundStyle(.primary)
                    Text("\(row.source.name) · \(row.node.name)").font(.caption).foregroundStyle(.secondary)
                }
            }.buttonStyle(.plain)
                .accessibilityIdentifier("phoneHub.session.\(row.source.id.uuidString).\(row.node.id).\(row.session.id)")
        }
        if aggregate.sessions.isEmpty { emptyPanel(.sessions) }
    }
    @ViewBuilder private var attention: some View {
        ForEach(aggregate.attention) { row in
            VStack(alignment: .leading) {
                Button { open(row.path, source: row.source, nodeID: row.nodeID) } label: {
                    VStack(alignment: .leading) {
                        Text(row.title).foregroundStyle(.primary)
                        Text("\(row.source.name) · \(row.nodeID) · \(row.inputRequired ? "Input required" : "Unseen")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.buttonStyle(.plain)
                    .accessibilityIdentifier("phoneHub.attention.\(row.source.id.uuidString).\(row.nodeID).\(row.sessionID).\(row.itemKey)")
                if let request = row.seenRequest,
                   let source = aggregate.source(row.source.id),
                   let item = source.store.inbox.first(where: { $0.node_id == row.nodeID && $0.session_id == request.session_id && $0.store_instance_id == request.store_instance_id && $0.attention_seq == request.attention_seq }) {
                    let busy = source.store.markingSeen.contains(HubStore.inboxItemKey(item))
                    Button {
                        Task { await source.store.markInboxItemSeen(item) }
                    } label: {
                        HStack {
                            if busy { ProgressView().controlSize(.small) }
                            Text(busy ? "Marking seen…" : "Mark seen")
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(busy)
                }
            }
        }
        ForEach(aggregate.sources) { source in
            if let status = source.store.attentionClearStatus {
                Text("\(source.connection.name): \(status)").font(.caption).foregroundStyle(.secondary)
            }
            if source.store.attentionHasMore && !source.store.unauthorized {
                if source.store.canLoadMoreAttention {
                    Button("Load more from \(source.connection.name)") { Task { await source.store.loadMoreAttention() } }
                        .disabled(source.store.attentionLoading)
                        .accessibilityIdentifier("phoneHub.moreAttention.\(source.id.uuidString)")
                } else {
                    Text("\(source.connection.name): Showing the maximum of 500 results. Clear reviewed results to reveal more.")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("phoneHub.attentionMaximum.\(source.id.uuidString)")
                }
            }
        }
        if aggregate.attention.isEmpty { emptyPanel(.attention) }
    }
    @ViewBuilder private func emptyPanel(_ panel: Panel) -> some View {
        let loading = aggregate.sources.contains { source in
            !source.store.unauthorized && (panel == .attention ? source.store.attentionLoading : source.store.nodesLoading)
        }
        let unavailable = aggregate.sources.contains { source in
            source.store.unauthorized || (panel == .attention ? source.store.attentionError != nil : source.store.nodeError != nil)
        }
        let offlineOnly = panel == .nodes && !showOfflineNodes && !aggregate.nodes.isEmpty
        VStack(spacing: 12) {
            if loading {
                ProgressView()
                Text("Loading \(panel.rawValue.lowercased())…").font(.headline)
                Text("You can keep exploring while your servers respond.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                Image(systemName: unavailable ? "wifi.exclamationmark" : (panel == .attention ? "checkmark.circle" : "bubble.left.and.bubble.right"))
                    .font(.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true)
                Text(unavailable ? "Some results are unavailable" : (offlineOnly ? "No agents online" : (panel == .attention ? "You’re all caught up" : "No \(panel.rawValue.lowercased()) yet")))
                    .font(.headline)
                Text(unavailable ? "Open Connections to sign in or try again." : (offlineOnly ? "Offline agents are hidden. Use Show all to see them." : (aggregate.sources.isEmpty ? "Add a connection to get started." : (panel == .attention ? "New requests and results will appear here." : "Your \(panel.rawValue.lowercased()) will appear here when available."))))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.vertical, 24)
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
    private func openDetailDestination(_ url: URL, nodeID: String?, source: HubSourceWorkspace) {
        guard source.isActive, !source.store.unauthorized else { return }
        if nodeID == nil, url == source.connection.url {
            detailID = nil
            onOpenChat(source.id, url)
            return
        }
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let path = parts.percentEncodedPath + (parts.percentEncodedQuery.map { "?" + $0 } ?? "")
        guard url.scheme == source.connection.url.scheme, url.host == source.connection.url.host, url.port == source.connection.url.port,
              let nodeID, aggregate.destination(path: path, sourceID: source.id, nodeID: nodeID) == url else {
            navigationError = "The source supplied an unsafe chat path. Navigation blocked."
            return
        }
        detailID = nil
        onOpenChat(source.id, url)
    }
}

/// Polling invalidates the aggregate view frequently. Keep the native menu's
/// presentation independent of those updates, while allowing actual selections
/// to update its label. The callback only writes the owning view's panel state.
@MainActor private struct PhoneHubPanelSelector: View, Equatable {
    let selection: PhoneHubView.Panel
    let onSelect: (PhoneHubView.Panel) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.selection == rhs.selection }

    var body: some View {
        Picker("View", selection: Binding(get: { selection }, set: onSelect)) {
            ForEach(PhoneHubView.Panel.allCases, id: \.self) { candidate in
                Text(candidate.rawValue).tag(candidate)
                    .accessibilityIdentifier("phoneHub." + (candidate == .nodes ? "nodes" : candidate.rawValue.lowercased()))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .accessibilityIdentifier("phoneHub.panelMenu")
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
                    .background(Color(.systemGroupedBackground))
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
                                        .textContentType(.URL).keyboardType(.URL)
                                        .textInputAutocapitalization(.never).autocorrectionDisabled()
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
                                Text("Check that the address includes any server path, and that the server is online and reachable from your phone.")
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
            .navigationBarTitleDisplayMode(.inline)
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
