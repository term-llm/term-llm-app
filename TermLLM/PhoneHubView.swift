import SwiftUI

@MainActor
struct PhoneHubView: View {
    @ObservedObject var connections: HubConnectionStore
    @ObservedObject var aggregate: HubAggregateStore
    @Binding var pendingConnectionURL: URL?
    let isVisible: Bool
    let onOpenChat: (UUID, URL) -> Void
    let onSettings: () -> Void
    /// Only the Mac/iPad workspace supplies chrome; the phone keeps its native bar.
    var usesWorkspaceChrome = false
    var onToggleSidebar: (() -> Void)? = nil
    @State private var panel: Panel = .nodes
    /// Offline agents cannot be opened, so they are hidden from the list by
    /// default; the opt-in lives with connection management, not the list.
    @AppStorage("phoneHub.showOfflineAgents", store: PhoneHubFixture.defaults) private var showOfflineNodes = false
    @State private var editor: Editor?
    @State private var navigationError: String?
    /// Agent pages pushed on the Agents stack; kept across Chat round-trips.
    @State private var agentPath: [PhoneHubAgentRoute] = []
    @State private var sessionSearch = ""
    @AppStorage("phoneHub.sessionSort", store: PhoneHubFixture.defaults) private var sessionSort: PhoneHubSessionSort = .recent
    /// Search keeps its own order: relevance by default, per query session.
    @State private var searchSort: PhoneHubSessionSort = .relevance
    @FocusState private var sessionSearchFocused: Bool

    enum Panel: String, CaseIterable { case nodes = "Agents", attention = "Attention", sessions = "Sessions" }
    struct Editor: Identifiable { let id = UUID(); var source: HubConnection?; var address: String? }

    private var loadingSources: [HubSourceWorkspace] {
        aggregate.sources.filter { !$0.store.unauthorized && ($0.store.nodesLoading || $0.store.attentionLoading) }
    }
    private var connectionIssueCount: Int {
        PhoneHubConnectionsView.issueCount(connections: connections, aggregate: aggregate)
    }
    private var isRefreshing: Bool { aggregate.sources.contains { $0.store.refreshing } }
    private var visibleNodes: [PhoneHubNode] {
        aggregate.nodes.filter { showOfflineNodes || $0.node.status.reachable }
    }
    /// Strongest attention state per session: input required beats unseen.
    private var sessionAttention: [PhoneHubSessionKey: PhoneHubSessionAttention] {
        var flags: [PhoneHubSessionKey: PhoneHubSessionAttention] = [:]
        for row in aggregate.attention {
            let key = PhoneHubSessionKey(sourceID: row.source.id, nodeID: row.nodeID, sessionID: row.sessionID)
            if row.inputRequired { flags[key] = .inputRequired } else if flags[key] == nil { flags[key] = .unseen }
        }
        return flags
    }

    /// Badge text for the Attention segment; nil when nothing needs attention.
    private var attentionBadge: String? {
        let count = aggregate.attention.count
        guard count > 0 else { return nil }
        let more = aggregate.sources.contains { !$0.store.unauthorized && $0.store.attentionHasMore }
        return more ? "\(count)+" : "\(count)"
    }

    var body: some View {
        NavigationStack(path: $agentPath) {
            List {
                if connections.connections.isEmpty {
                    Section {
                        VStack(spacing: 16) {
                            Image(systemName: "network").font(.largeTitle).foregroundStyle(.secondary)
                            Text("Your agents, all in one place").font(.title3.bold())
                            Text("Add a connection to bring your agents together.")
                                .foregroundStyle(.secondary)
                            Button { editor = Editor() } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "plus")
                                        .accessibilityHidden(true)
                                    Text("Add Connection")
                                }
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 28)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .buttonBorderShape(.roundedRectangle(radius: 16))
                            .frame(maxWidth: 320)
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
            // The grouped list's default top margin leaves a gap far larger
            // than the 8 pt rhythm of the pinned controls above it.
            .contentMargins(.top, 8, for: .scrollContent)
            // Pinned outside the List: a list row clips the control with its
            // own rounded shape, and a pinned switcher stays reachable.
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    if usesWorkspaceChrome {
                        WorkspaceHeader(title: "Agents", subtitle: "All connections", onToggleSidebar: onToggleSidebar) {
                            Button { aggregate.refresh() } label: {
                                ZStack {
                                    Image(systemName: "arrow.clockwise").opacity(loadingSources.isEmpty ? 1 : 0)
                                    ProgressView().opacity(loadingSources.isEmpty ? 0 : 1)
                                }
                                .frame(width: 32, height: 44)
                            }
                            .accessibilityLabel(loadingSources.isEmpty ? "Refresh" : "Syncing connections")
                            .disabled(isRefreshing || aggregate.sources.isEmpty)
                            .accessibilityIdentifier("phoneHub.refresh")
                        }
                    }
                    if !connections.connections.isEmpty {
                        VStack(alignment: usesWorkspaceChrome ? .leading : .center, spacing: 8) {
                            PhoneHubPanelSelector(selection: panel, attention: attentionBadge, onSelect: { panel = $0 })
                                .equatable()
                                .frame(maxWidth: usesWorkspaceChrome ? 480 : .infinity)
                            if panel == .sessions { sessionControls }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, usesWorkspaceChrome ? 12 : 6)
                        .frame(maxWidth: usesWorkspaceChrome ? 900 : .infinity)
                        .frame(maxWidth: .infinity)
                        .background(Color(.systemGroupedBackground))
                    }
                }
            }
            .modifier(WorkspaceListWidth(enabled: usesWorkspaceChrome))
            .navigationTitle("Agents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(isVisible && !usesWorkspaceChrome ? .visible : .hidden, for: .navigationBar)
            .toolbar {
                if isVisible && !usesWorkspaceChrome {
                    ToolbarItem(placement: .principal) {
                        Text("Agents").font(.headline).accessibilityIdentifier("phoneHub.home")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        // Connections live in Settings; their issues badge it.
                        Button(action: onSettings) {
                            Image(systemName: "gearshape")
                                .overlay(alignment: .topTrailing) {
                                    Circle().fill(.orange).frame(width: 8, height: 8)
                                        .offset(x: 3, y: -3).opacity(connectionIssueCount > 0 ? 1 : 0)
                                }
                        }
                        .accessibilityLabel("Settings")
                        .accessibilityValue(connectionIssueCount == 0 ? "" : "\(connectionIssueCount) connection\(connectionIssueCount == 1 ? "" : "s") need attention")
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
            .refreshable {
                await aggregate.refreshAndWait()
                aggregate.rerunSearch()
            }
            .sheet(item: $editor) { editor in
                PhoneHubConnectionEditor(connections: connections, source: editor.source, initialAddress: editor.address, onDone: {})
                    .safeAreaInset(edge: .bottom, spacing: 0) { PhoneHubFixtureBanner() }
            }
            .navigationDestination(for: PhoneHubAgentRoute.self) { route in
                PhoneHubAgentView(route: route, aggregate: aggregate, isVisible: isVisible,
                                  onOpenChat: onOpenChat, onSettings: onSettings)
                    // A pushed agent still owns its native back/navigation controls.
                    .toolbar(isVisible ? .visible : .hidden, for: .navigationBar)
                    // An edited endpoint is a new source identity: start over
                    // with it rather than keep the old one's history.
                    .id(aggregate.source(route.sourceID).map(ObjectIdentifier.init))
            }
        }
        .onChange(of: aggregate.sources.map(\.id)) { _, ids in
            // A removed connection takes its agent pages with it.
            let live = Set(ids)
            if agentPath.contains(where: { !live.contains($0.sourceID) }) {
                agentPath.removeAll { !live.contains($0.sourceID) }
            }
        }
        .onChange(of: sessionSearch) { _, text in aggregate.updateSearchQuery(text) }
        .onChange(of: connections.connections, initial: true) { _, sources in aggregate.synchronize(sources.filter { $0.needsKindReview != true }) }
        .task { await connections.resolveLegacyKinds() }
        .onChange(of: isVisible) { _, visible in
            guard !visible else { return }
            // A chat/push/voice handoff must not leave a connection editor
            // over the retained browser destination.
            editor = nil
        }
        .onChange(of: pendingConnectionURL, initial: true) { _, url in
            guard let url else { return }
            let canonical = HubConnectionStore.canonicalURL(url.absoluteString)
            editor = Editor(source: connections.connections.first { $0.url == canonical }, address: url.absoluteString)
            pendingConnectionURL = nil
        }
    }

    @ViewBuilder private var nodes: some View {
        let visibleNodes = visibleNodes
        // The connection name only disambiguates when several hubs are
        // configured, and "Online" is the default state, so neither earns a
        // line on its own: show only what differs between rows.
        let multipleSources = aggregate.sources.count > 1
        ForEach(visibleNodes) { row in
            let detail = ([
                multipleSources ? row.source.name : nil,
                row.node.status.reachable ? nil : "Offline",
                row.node.sessions?.count_label,
            ] as [String?]).compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            // The row opens the agent's page (new, pinned and recent
            // conversations); the compose button keeps a one-tap new chat.
            NavigationLink(value: PhoneHubAgentRoute(sourceID: row.source.id, nodeID: row.node.id)) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.node.name).font(.headline).foregroundStyle(.primary)
                        if !detail.isEmpty {
                            Text(detail).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    Button {
                        open(row.node.new_session_path, source: row.source, nodeID: row.node.id)
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(Color.accentColor.opacity(0.12)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("New conversation with \(row.node.name)")
                    .accessibilityIdentifier("phoneHub.node.\(row.source.id.uuidString).\(row.node.id).new")
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier("phoneHub.node.\(row.source.id.uuidString).\(row.node.id)")
            .disabled(!row.node.status.reachable)
            .opacity(row.node.status.reachable ? 1 : 0.5)
        }
        if visibleNodes.isEmpty { emptyPanel(.nodes) }
    }
    private var isSearchingSessions: Bool { !aggregate.searchQuery.isEmpty }

    /// Pinned under the panel switcher so it stays reachable while scrolling.
    private var sessionControls: some View {
        let searching = !sessionSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let options = searching ? PhoneHubSessionSort.searchOptions : PhoneHubSessionSort.browseOptions
        let current = searching ? searchSort : sessionSort
        return HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Search sessions", text: $sessionSearch)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { aggregate.searchAllAgents() }
                    .focused($sessionSearchFocused)
                    .accessibilityIdentifier("phoneHub.sessionSearch")
                if !sessionSearch.isEmpty {
                    Button {
                        sessionSearch = ""
                        sessionSearchFocused = false
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                    .accessibilityIdentifier("phoneHub.sessionSearch.clear")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
            Menu {
                Picker("Sort by", selection: Binding(get: { current }, set: { if searching { searchSort = $0 } else { sessionSort = $0 } })) {
                    ForEach(options) { Text($0.label).tag($0) }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .frame(width: 36, height: 36)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
            }
            .accessibilityLabel("Sort sessions")
            .accessibilityValue(current.label)
            .accessibilityIdentifier("phoneHub.sessionSort")
        }
    }

    private func sessionFlag(_ row: PhoneHubSession, flags: [PhoneHubSessionKey: PhoneHubSessionAttention]) -> PhoneHubSessionAttention? {
        if row.session.interaction_required == true { return .inputRequired }
        if let flag = flags[PhoneHubSessionKey(sourceID: row.source.id, nodeID: row.node.id, sessionID: row.session.id)] { return flag }
        return row.unseen ? .unseen : nil
    }

    @ViewBuilder private var sessions: some View {
        let flags = sessionAttention
        if isSearchingSessions {
            sessionSearchResults(flags: flags)
        } else {
            let sort = PhoneHubSessionSort.browseOptions.contains(sessionSort) ? sessionSort : .recent
            let rows = aggregate.sortedSessions(sort, flags: flags) { sessionFlag($0, flags: flags) }
            ForEach(rows) { row in sessionRow(row, flag: sessionFlag(row, flags: flags)) }
            if rows.isEmpty { emptyPanel(.sessions) }
        }
    }

    @ViewBuilder private func sessionSearchResults(flags: [PhoneHubSessionKey: PhoneHubSessionAttention]) -> some View {
        let sort = searchSort
        let results = aggregate.sortedSearchResults(sort, flags: flags) { sessionFlag($0, flags: flags) }
        let agents = aggregate.searchAgents
        let pending = agents.filter { $0.state == .searching }.count
        if pending > 0 {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Searching \(pending) of \(agents.count) agent\(agents.count == 1 ? "" : "s")…")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("phoneHub.sessionSearch.progress")
        }
        if sort == .relevance {
            // Rankings are per node, so relevance is shown agent by agent.
            ForEach(agents) { agent in
                let rows = results.filter { $0.source.id == agent.source.id && $0.node.id == agent.node.id }
                if !rows.isEmpty || agent.state != .done(0) {
                    searchAgentHeader(agent, count: rows.count)
                    ForEach(rows) { row in sessionRow(row, flag: sessionFlag(row, flags: flags)) }
                }
            }
            // Loaded title matches from agents that were not searchable.
            let asked = Set(agents.map(\.id))
            let others = results.filter { !asked.contains(PhoneHubIdentity(sourceID: $0.source.id, nodeID: $0.node.id, sessionID: "", key: "search")) }
            ForEach(others) { row in sessionRow(row, flag: sessionFlag(row, flags: flags)) }
        } else {
            ForEach(agents.filter { if case .failed = $0.state { true } else { false } }) { agent in
                searchAgentHeader(agent, count: 0)
            }
            ForEach(results) { row in sessionRow(row, flag: sessionFlag(row, flags: flags)) }
        }
        let asked = aggregate.agentSearchQuery != nil
        if results.isEmpty && pending == 0 && (asked || aggregate.searchableAgentCount == 0) {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true)
                Text("No matching sessions").font(.headline)
                Text(asked && !agents.isEmpty ? "Searched \(agents.count) agent\(agents.count == 1 ? "" : "s")." : "No online agents to search.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.vertical, 24)
            .accessibilityIdentifier("phoneHub.sessionSearch.empty")
        }
        if !asked && aggregate.searchableAgentCount > 0 {
            searchAgentsButton(localMatches: results.count)
        }
    }

    /// Typing only filters loaded sessions; asking every agent is explicit
    /// because each search costs a request per agent.
    private func searchAgentsButton(localMatches: Int) -> some View {
        let count = aggregate.searchableAgentCount
        return Button { aggregate.searchAllAgents() } label: {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass.circle.fill").font(.title2).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Search \(count == 1 ? "1 agent" : "all \(count) agents") for “\(aggregate.searchQuery)”")
                        .fontWeight(.semibold)
                    Text(localMatches == 0 ? "No loaded sessions match. Agents search their full history."
                         : "Includes older sessions and message text.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .accessibilityIdentifier("phoneHub.sessionSearch.agents")
    }

    private func searchAgentHeader(_ agent: PhoneHubSearchAgent, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(agent.node.name)
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            Spacer(minLength: 0)
            switch agent.state {
            case .searching: ProgressView().controlSize(.mini)
            case .done: Text("\(count)").font(.caption).foregroundStyle(.secondary)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("phoneHub.sessionSearch.agent.\(agent.source.id.uuidString).\(agent.node.id)")
    }

    private func sessionRow(_ row: PhoneHubSession, flag: PhoneHubSessionAttention?) -> some View {
        Button { open(row.session.resume_path, source: row.source, nodeID: row.node.id) } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(flag == .inputRequired ? Color.orange : Color.accentColor)
                    .frame(width: 9, height: 9)
                    .opacity(flag == nil ? 0 : 1)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.displayTitle)
                        .foregroundStyle(.primary)
                        .fontWeight(flag == nil ? .regular : .semibold)
                    if let snippet = row.snippet, !snippet.isEmpty {
                        Text(Self.highlighted(snippet))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Text(sessionCaption(row)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if flag == .inputRequired {
                    Text("Input")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                } else if row.session.active_run == true {
                    ProgressView().controlSize(.mini).accessibilityLabel("Running")
                }
            }
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityValue(flag == .inputRequired ? "Input required" : (flag == .unseen ? "Unseen" : ""))
            .accessibilityIdentifier("phoneHub.session.\(row.source.id.uuidString).\(row.node.id).\(row.session.id)")
    }

    private func sessionCaption(_ row: PhoneHubSession) -> String {
        var parts = [row.node.name]
        if let ms = row.session.last_message_at, ms > 0 {
            parts.append(Date(timeIntervalSince1970: TimeInterval(ms) / 1000).formatted(.relative(presentation: .named)))
        }
        return parts.joined(separator: " · ")
    }

    /// Node snippets mark matched terms with `**`; render them bold without
    /// interpreting any other Markdown in untrusted transcript text.
    static func highlighted(_ snippet: String) -> AttributedString {
        var out = AttributedString()
        for (index, part) in snippet.components(separatedBy: "**").enumerated() {
            var segment = AttributedString(part)
            if index % 2 == 1 { segment.inlinePresentationIntent = .stronglyEmphasized }
            out += segment
        }
        return out
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
                Text(unavailable ? "Open Settings › Connections to sign in or try again." : (offlineOnly ? "Offline agents are hidden. Turn on Show offline agents in Settings › Connections to see them." : (aggregate.sources.isEmpty ? "Add a connection to get started." : (panel == .attention ? "New requests and results will appear here." : "Your \(panel.rawValue.lowercased()) will appear here when available."))))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.vertical, 24)
    }

    private func open(_ path: String, source: HubConnection, nodeID: String) {
        guard let url = aggregate.destination(path: path, sourceID: source.id, nodeID: nodeID) else {
            navigationError = "The source supplied an unsafe chat path. Navigation blocked."
            return
        }
        onOpenChat(source.id, url)
    }
}

/// Saved connections are app configuration, so they live in Settings. The list
/// only shows identity and status; every action lives on a connection's detail
/// page. Which connection Chat shows is navigation state, not a setting here.
@MainActor
struct PhoneHubConnectionsView: View {
    @ObservedObject var connections: HubConnectionStore
    @ObservedObject var aggregate: HubAggregateStore
    /// Opening a chat from a connection leaves Settings.
    let onOpenChat: (UUID, URL) -> Void
    @AppStorage("phoneHub.showOfflineAgents", store: PhoneHubFixture.defaults) private var showOfflineNodes = false
    @State private var editor: PhoneHubView.Editor?
    @State private var showingReset = false

    /// Connections needing the user: unidentified, signed out, failing, or an
    /// unreadable catalog. Badges Settings and its Connections row.
    static func issueCount(connections: HubConnectionStore, aggregate: HubAggregateStore) -> Int {
        connections.connections.filter { $0.needsKindReview == true }.count +
        aggregate.sources.filter { $0.store.unauthorized || $0.error != nil }.count +
        (connections.persistenceError == nil ? 0 : 1)
    }

    private var reviewSources: [HubConnection] { connections.connections.filter { $0.needsKindReview == true } }

    var body: some View {
        List {
            if let error = connections.persistenceError {
                Section {
                    Text(error).foregroundStyle(.orange)
                    Button("Reset unreadable catalog", role: .destructive) { showingReset = true }
                        .accessibilityIdentifier("phoneHub.resetCatalog")
                }
            }
            Section {
                ForEach(reviewSources) { source in
                    Button { editor = PhoneHubView.Editor(source: source) } label: {
                        PhoneHubConnectionRowLabel(
                            name: source.name, style: .init(source), showsChevron: true,
                            subtitle: "Couldn’t identify server · Tap to review", tone: .warning)
                    }
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("phoneHub.source.\(source.id.uuidString)")
                    .swipeActions {
                        Button("Remove", role: .destructive) { connections.remove(source.id) }
                            .accessibilityIdentifier("phoneHub.swipeRemove.\(source.id.uuidString)")
                    }
                }
                ForEach(aggregate.sources) { source in
                    NavigationLink {
                        PhoneHubConnectionDetailView(source: source, store: source.store, connections: connections,
                                                     aggregate: aggregate, onOpenChat: onOpenChat)
                    } label: {
                        PhoneHubConnectionRow(source: source, store: source.store)
                    }
                    .accessibilityIdentifier("phoneHub.source.\(source.id.uuidString)")
                    .swipeActions {
                        Button(source.connection.isLinkedDevices ? "Forget" : "Remove", role: .destructive) { connections.remove(source.id) }
                            .accessibilityIdentifier("phoneHub.swipeRemove.\(source.id.uuidString)")
                    }
                }
                if reviewSources.isEmpty && aggregate.sources.isEmpty {
                    Text("No connections yet. Tap + to add a server.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Servers")
            } footer: {
                if !(reviewSources.isEmpty && aggregate.sources.isEmpty) {
                    Text("Select a connection to see its status, sign in, or manage it.")
                }
                if ProcessInfo.processInfo.isiOSAppOnMac {
                    Text("To link a device on Mac, open the one-use pairing link from the host’s Settings → Linked devices. You don’t need to scan a QR code.")
                }
            }
            Section {
                Toggle("Show offline agents", isOn: $showOfflineNodes)
                    .accessibilityIdentifier("phoneHub.showOfflineAgents")
            } header: {
                Text("Agents")
            } footer: {
                Text("Offline agents can’t be opened. When shown, they appear greyed out in the Agents list.")
            }
        }
        .transaction { $0.animation = nil }
        .navigationTitle("Connections")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add Connection", systemImage: "plus") { editor = PhoneHubView.Editor() }
                    .accessibilityIdentifier("phoneHub.connections.add")
            }
        }
        .sheet(item: $editor) { editor in
            PhoneHubConnectionEditor(connections: connections, source: editor.source, initialAddress: editor.address, onDone: {})
                .safeAreaInset(edge: .bottom, spacing: 0) { PhoneHubFixtureBanner() }
        }
        .confirmationDialog("Reset the unreadable catalog?", isPresented: $showingReset, titleVisibility: .visible) {
            Button("Reset saved connections", role: .destructive) { connections.resetUnreadableCatalog() }
        } message: { Text("This explicitly replaces the preserved catalog. You will need to add your connections again.") }
    }
}

/// Visual identity per connection kind, shared by the list and detail page.
struct PhoneHubConnectionStyle {
    let symbol: String
    let colors: [Color]
    let title: String

    init(kind: HubConnection.Kind, linked: Bool) {
        if linked {
            symbol = "laptopcomputer"; title = "Linked device"
            colors = [Color(red: 0.75, green: 0.35, blue: 0.95), Color(red: 0.54, green: 0.27, blue: 0.67)]
        } else if kind == .hub {
            symbol = "server.rack"; title = kind.title
            colors = [Color(red: 0.37, green: 0.36, blue: 0.90), Color(red: 0.21, green: 0.20, blue: 0.64)]
        } else {
            symbol = "dot.radiowaves.left.and.right"; title = kind.title
            colors = [Color(red: 0.19, green: 0.69, blue: 0.78), Color(red: 0.11, green: 0.50, blue: 0.57)]
        }
    }
    init(_ connection: HubConnection) { self.init(kind: connection.kind, linked: connection.isLinkedDevices) }

    /// Address without scheme or trailing slash; linked devices show a key prefix.
    static func address(_ connection: HubConnection) -> String {
        if connection.isLinkedDevices {
            return (connection.linkedDevicesHostKey.map { String($0.prefix(12)) } ?? "unknown identity") + "…"
        }
        var text = connection.url.absoluteString
        for scheme in ["https://", "http://"] where text.hasPrefix(scheme) { text.removeFirst(scheme.count) }
        if text.hasSuffix("/") { text.removeLast() }
        return text
    }
}

struct PhoneHubConnectionIcon: View {
    let style: PhoneHubConnectionStyle
    var size: CGFloat = 36
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(LinearGradient(colors: style.colors, startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: style.symbol)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

/// Status shown for a connection, in list and detail.
struct PhoneHubConnectionStatus {
    enum Tone { case ok, warning, neutral, busy }
    let text: String
    let tone: Tone

    var color: Color {
        switch tone {
        case .ok: .green
        case .warning: .orange
        case .neutral: .secondary
        case .busy: .blue
        }
    }

    @MainActor
    static func of(_ source: HubSourceWorkspace, linked: LinkedDevicesRuntime) -> Self {
        if source.connection.isLinkedDevices {
            let status = linked.status(for: source.id)
            let tone: Tone = switch status {
            case .connected(_): .ok
            case .connecting: .busy
            case .revoked, .identityChanged, .failed(_): .warning
            case .offline, .suspended: .neutral
            }
            return .init(text: status.label, tone: tone)
        }
        let store = source.store
        if store.unauthorized { return .init(text: "Needs sign-in", tone: .warning) }
        if source.error != nil { return .init(text: "Couldn’t update", tone: .warning) }
        if store.nodesLoading || store.attentionLoading { return .init(text: "Updating…", tone: .busy) }
        if store.nodesVerified && store.attentionVerified { return .init(text: "Up to date", tone: .ok) }
        return .init(text: "Waiting for server…", tone: .neutral)
    }
}

struct PhoneHubConnectionRowLabel: View {
    let name: String
    let style: PhoneHubConnectionStyle
    var showsChevron = false
    let subtitle: String
    let tone: PhoneHubConnectionStatus.Tone

    var body: some View {
        HStack(spacing: 12) {
            PhoneHubConnectionIcon(style: style)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).lineLimit(1)
                HStack(spacing: 5) {
                    Circle().fill(PhoneHubConnectionStatus(text: "", tone: tone).color).frame(width: 7, height: 7)
                    Text(subtitle)
                        .foregroundStyle(tone == .warning ? Color.orange : Color.secondary)
                        .lineLimit(1)
                }
                .font(.footnote)
            }
            Spacer(minLength: 0)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Observes the source and its store so status changes redraw only this row.
@MainActor
private struct PhoneHubConnectionRow: View {
    @ObservedObject var source: HubSourceWorkspace
    @ObservedObject var store: HubStore
    @ObservedObject private var linkedDevices = LinkedDevicesRuntime.shared

    var body: some View {
        let status = PhoneHubConnectionStatus.of(source, linked: linkedDevices)
        let style = PhoneHubConnectionStyle(source.connection)
        // Problems replace the address; healthy rows keep a stable subtitle.
        let subtitle = status.tone == .warning ? status.text
            : (source.connection.isLinkedDevices ? "\(style.title) · \(status.text)"
               : "\(style.title) · \(PhoneHubConnectionStyle.address(source.connection))")
        PhoneHubConnectionRowLabel(name: source.connection.name, style: style, subtitle: subtitle, tone: status.tone)
    }
}

/// One connection's status and every action for it, in Settings style:
/// action rows, navigation rows, and one destructive row at the bottom.
@MainActor
private struct PhoneHubConnectionDetailView: View {
    @ObservedObject var source: HubSourceWorkspace
    @ObservedObject var store: HubStore
    @ObservedObject var connections: HubConnectionStore
    @ObservedObject var aggregate: HubAggregateStore
    let onOpenChat: (UUID, URL) -> Void
    @ObservedObject private var linkedDevices = LinkedDevicesRuntime.shared
    @Environment(\.dismiss) private var dismiss
    @State private var editor: PhoneHubView.Editor?
    @State private var showingManage = false
    @State private var showingDirectAuth = false
    @State private var confirmingRemove = false
    @State private var navigationError: String?

    private var isLinked: Bool { source.connection.isLinkedDevices }
    private var style: PhoneHubConnectionStyle { PhoneHubConnectionStyle(source.connection) }

    var body: some View {
        List {
            Section { header }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 4, trailing: 16))
            if let navigationError {
                Section { Text(navigationError).foregroundStyle(.orange) }
            }
            if isLinked { linkedSections } else { serverSections }
            Section {
                Button(isLinked ? "Forget Device" : "Remove Connection", role: .destructive) { confirmingRemove = true }
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("phoneHub.remove.\(source.id.uuidString)")
            }
        }
        .accessibilityIdentifier("phoneHub.connectionDetail")
        .navigationTitle(source.connection.name)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(isLinked ? "Forget \(source.connection.name)?" : "Remove \(source.connection.name)?",
                            isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button(isLinked ? "Forget Device" : "Remove Connection", role: .destructive) {
                let id = source.id
                dismiss()
                connections.remove(id)
            }
            .accessibilityIdentifier("phoneHub.remove.confirm")
        } message: {
            Text(isLinked ? "This app will need to be linked again to use this device."
                 : "Its agents disappear from the app. You can add it again later.")
        }
        .sheet(item: $editor) { editor in
            PhoneHubConnectionEditor(connections: connections, source: editor.source, initialAddress: editor.address, onDone: {})
                .safeAreaInset(edge: .bottom, spacing: 0) { PhoneHubFixtureBanner() }
        }
        .sheet(isPresented: $showingManage) {
            if let workspace = source.hubWorkspace {
                VStack(spacing: 0) {
                    Button("Back to \(source.connection.name)") { showingManage = false }
                        .padding().accessibilityIdentifier("phoneHub.details.close")
                    HubView(source: source, workspace: workspace, onOpenChat: { url in
                        openDestination(url, nodeID: nil)
                    }, onOpenNodeChat: { url, nodeID in
                        openDestination(url, nodeID: nodeID)
                    }, onSettings: { showingManage = false })
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { PhoneHubFixtureBanner() }
            }
        }
        .sheet(isPresented: $showingDirectAuth) {
            PhoneHubDirectAuthentication(source: source)
                .safeAreaInset(edge: .bottom, spacing: 0) { PhoneHubFixtureBanner() }
        }
    }

    private var header: some View {
        let status = PhoneHubConnectionStatus.of(source, linked: linkedDevices)
        return VStack(spacing: 6) {
            PhoneHubConnectionIcon(style: style, size: 64)
            Text(source.connection.name)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .padding(.top, 6)
            Text("\(style.title) · \(PhoneHubConnectionStyle.address(source.connection))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            statusCapsule(status).padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
    }

    /// A fixed-shape status slot: refreshing changes its contents, not layout.
    private func statusCapsule(_ status: PhoneHubConnectionStatus) -> some View {
        HStack(spacing: 6) {
            ZStack {
                Circle().fill(status.color).frame(width: 7, height: 7).opacity(status.tone == .busy ? 0 : 1)
                ProgressView().controlSize(.mini).opacity(status.tone == .busy ? 1 : 0)
            }
            .frame(width: 12, height: 12)
            Group {
                // Freshness only describes data the app could load.
                if !isLinked, !store.unauthorized, let updated = store.lastNodesRefresh {
                    Text("\(status.text) · \(updated, style: .relative) ago")
                } else {
                    Text(status.text)
                }
            }
            .lineLimit(1)
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(status.tone == .neutral ? Color.secondary : status.color)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill((status.tone == .neutral ? Color.secondary : status.color).opacity(0.14)))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(store.nodesLoading ? "phoneHub.nodesLoading.\(source.id.uuidString)" : "phoneHub.syncStatus.\(source.id.uuidString)")
    }

    @ViewBuilder private var serverSections: some View {
        if store.unauthorized {
            Section {
                Button("Sign in") { showAuthentication() }
                    .accessibilityIdentifier("phoneHub.signIn.\(source.id.uuidString)")
            } footer: {
                Text("Sign in to see this server’s agents. Credentials are kept separately for each connection.")
            }
        } else if let error = source.error {
            Section("Last error") {
                Text(error).font(.callout).foregroundStyle(.secondary)
            }
        }
        Section("Server") {
            // Signed out: Sign in above is the one way forward.
            if !store.unauthorized {
                LabeledContent("Agents", value: agentsSummary)
                Button("Open in Chat") { openDestination(source.connection.url, nodeID: nil) }
                    .disabled(!source.isActive)
                    .accessibilityIdentifier("phoneHub.openChat.\(source.id.uuidString)")
                Button(source.error == nil ? "Refresh now" : "Retry") { Task { await store.refresh() } }
                    .disabled(store.refreshing)
                    .accessibilityIdentifier("phoneHub.retry.\(source.id.uuidString)")
            }
            if source.connection.kind == .hub {
                navigationRow("Manage server") { showingManage = true }
                    .accessibilityIdentifier("phoneHub.details.\(source.id.uuidString)")
            } else {
                navigationRow("Authentication") { showingDirectAuth = true }
                    .accessibilityIdentifier("phoneHub.details.\(source.id.uuidString)")
            }
            navigationRow("Address & name", value: "Edit") { editor = PhoneHubView.Editor(source: source.connection) }
                .accessibilityIdentifier("phoneHub.edit.\(source.id.uuidString)")
        }
    }

    @ViewBuilder private var linkedSections: some View {
        Section("Device") {
            LabeledContent("Agents", value: agentsSummary)
            Button("Connect now") { linkedDevices.reconnectNow(source.id) }
                .accessibilityIdentifier("phoneHub.retry.\(source.id.uuidString)")
        }
    }

    private var agentsSummary: String {
        let nodes = store.nodes
        guard store.nodesVerified || !nodes.isEmpty else { return "—" }
        let online = nodes.filter { $0.status.reachable }.count
        return online == nodes.count ? "\(nodes.count) online" : "\(online) of \(nodes.count) online"
    }

    private func navigationRow(_ title: String, value: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let value { Text(value).foregroundStyle(.secondary) }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
    }

    private func showAuthentication() {
        if source.connection.kind == .hub { showingManage = true } else { showingDirectAuth = true }
    }

    private func openDestination(_ url: URL, nodeID: String?) {
        guard source.isActive, !store.unauthorized else { return }
        if nodeID == nil, url == source.connection.url {
            showingManage = false
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
        showingManage = false
        onOpenChat(source.id, url)
    }
}

/// Segmented view switcher with an Attention badge. A native segmented picker
/// cannot render the badge, so this draws the segments itself.
/// Polling invalidates the aggregate view frequently; equatable on the
/// selection and badge keeps unrelated updates from re-rendering it. The
/// callback only writes the owning view's panel state.
@MainActor struct PhoneHubPanelSelector: View, Equatable {
    let selection: PhoneHubView.Panel
    /// Attention badge text; nil hides the badge.
    let attention: String?
    let onSelect: (PhoneHubView.Panel) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.selection == rhs.selection && lhs.attention == rhs.attention }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(PhoneHubView.Panel.allCases, id: \.self) { candidate in
                segment(candidate)
            }
        }
        .padding(2)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("phoneHub.panels")
    }

    private func segment(_ candidate: PhoneHubView.Panel) -> some View {
        let selected = candidate == selection
        return Button { onSelect(candidate) } label: {
            HStack(spacing: 5) {
                Text(candidate.rawValue)
                    .fontWeight(selected ? .semibold : .medium)
                    .foregroundStyle(.primary)
                if candidate == .attention, let attention {
                    Text(attention)
                        .font(.caption2.weight(.bold)).monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Capsule().fill(.orange))
                }
            }
            .font(.subheadline)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, minHeight: 36)
            .padding(.horizontal, 4)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color(.systemBackground))
                        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(candidate.rawValue)
        .accessibilityValue(candidate == .attention ? (attention.map { "\($0) need attention" } ?? "None") : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("phoneHub." + (candidate == .nodes ? "nodes" : candidate.rawValue.lowercased()))
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

/// Quiet, native root chrome for the larger-screen workspace. Live Chat never
/// uses this: its existing web header remains the sole conversation header.
struct WorkspaceHeader<Actions: View>: View {
    let title: String
    var subtitle: String? = nil
    var onToggleSidebar: (() -> Void)? = nil
    @ViewBuilder var actions: () -> Actions
    @ScaledMetric(relativeTo: .headline) private var titleSize = 16

    var body: some View {
        HStack(spacing: 12) {
            if let onToggleSidebar {
                Button(action: onToggleSidebar) {
                    Image(systemName: "sidebar.left")
                        .frame(width: 32, height: 44)
                }
                .accessibilityLabel("Show sidebar")
                .accessibilityIdentifier("workspace.sidebar.toggle")
            }
            Text(title)
                .font(.system(size: titleSize, weight: .semibold))
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("workspace.header.title")
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
            Spacer(minLength: 8)
            actions()
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.vertical, 4)
        .frame(minHeight: 52)
        .background(Color(.secondarySystemGroupedBackground))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.header")
    }
}

/// Wide lists keep a comfortable reading measure without constraining their
/// navigation stacks or changing the phone's standard grouped-list margins.
struct WorkspaceListWidth: ViewModifier {
    var enabled: Bool
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        if enabled {
            content
                .contentMargins(.horizontal, max(20, (width - 900) / 2), for: .scrollContent)
                .background {
                    GeometryReader { geometry in
                        Color.clear
                            .onAppear { width = geometry.size.width }
                            .onChange(of: geometry.size.width) { _, value in width = value }
                    }
                }
        } else {
            content
        }
    }
}
