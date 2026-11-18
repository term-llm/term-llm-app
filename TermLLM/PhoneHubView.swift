import AuthenticationServices
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
    /// Agent pages stay on the stack across Chat round-trips.
    @State private var path: [Route] = []
    @State private var sessionSearch = ""
    @AppStorage("phoneHub.sessionSort", store: PhoneHubFixture.defaults) private var sessionSort: PhoneHubSessionSort = .recent
    /// Search keeps its own order: relevance by default, per query session.
    @State private var searchSort: PhoneHubSessionSort = .relevance
    @State private var selectedSession: PhoneHubSessionKey?

    /// A connection opened from the home issue banner: its page, or straight to sign-in.
    @State private var connectionSheet: ConnectionSheet?
    /// Banner sign-in goes straight to the system passkey sheet.
    @State private var nativeLogin = NativeLogin()
    @State private var signingInSourceID: UUID?

    enum Panel: String, CaseIterable { case nodes = "Agents", attention = "Attention", sessions = "Sessions" }
    private enum Route: Hashable {
        case agent(PhoneHubAgentRoute)
        #if os(macOS)
        case connection(UUID)
        #endif

        var sourceID: UUID {
            switch self {
            case .agent(let route): route.sourceID
            #if os(macOS)
            case .connection(let sourceID): sourceID
            #endif
            }
        }
    }

    struct Editor: Identifiable { let id = UUID(); var source: HubConnection?; var address: String? }
    struct ConnectionSheet: Identifiable {
        enum Route { case details, hubSignIn, directSignIn }
        let id = UUID()
        let sourceID: UUID
        let route: Route
    }

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
        NavigationStack(path: $path) {
            Group {
                // Mac and iPad give the Agents panel a page of its own: one
                // agent's live work, or a card per agent. iPhone keeps the list.
                if usesWorkspaceChrome && panel == .nodes && !connections.connections.isEmpty && !visibleNodes.isEmpty {
                    PhoneHubAgentsOverview(aggregate: aggregate, nodes: visibleNodes, isVisible: isVisible,
                                           navigationError: navigationError,
                                           onOpen: { path, source, nodeID in open(path, source: source, nodeID: nodeID) },
                                           onShowAttention: { panel = .attention })
                } else {
                    rootList
                }
            }
            // Polling must not animate or rebuild the surrounding list layout.
            .transaction { $0.animation = nil }
            // The grouped list's default top margin leaves a gap far larger
            // than the 8 pt rhythm of the pinned controls above it.
            .contentMargins(.top, 8, for: .scrollContent)
            // Pinned outside the scrolling rows: a list row clips the control with its
            // own rounded shape, and a pinned switcher stays reachable.
            .workspaceTopBar {
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
                        PhoneHubPanelControls(selection: panel, attention: attentionBadge,
                                              usesWorkspaceChrome: usesWorkspaceChrome,
                                              onSelect: { panel = $0 }) {
                            sessionControls
                        }
                        PhoneHubConnectionIssuesBanner(aggregate: aggregate, signingInSourceID: signingInSourceID,
                                                       onOpen: openIssue, onShowAll: onSettings)
                    } else {
                        PhoneHubAddConnectionBanner(top: usesWorkspaceChrome ? 12 : 8) { editor = Editor() }
                    }
                }
            }
            .navigationTitle("Agents")
            .inlineNavigationTitle()
            .navigationBarVisibility(isVisible && !usesWorkspaceChrome ? .visible : .hidden)
            .toolbar {
                if isVisible && !usesWorkspaceChrome {
                    ToolbarItem(placement: .principal) {
                        Text("Agents").font(.headline).accessibilityIdentifier("phoneHub.home")
                    }
                    ToolbarItem(placement: .platformTrailing) {
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
                    ToolbarItem(placement: .platformTrailing) {
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
            .sheet(item: $connectionSheet) { sheet in
                connectionSheetContent(sheet)
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .agent(let agent):
                    PhoneHubAgentView(route: agent, aggregate: aggregate, isVisible: isVisible,
                                      onOpenChat: onOpenChat, onSettings: onSettings)
                        // A pushed agent still owns its native back/navigation controls.
                        .navigationBarVisibility(isVisible ? .visible : .hidden)
                        // An edited endpoint is a new source identity: start over
                        // with it rather than keep the old one's history.
                        .id(aggregate.source(agent.sourceID).map(ObjectIdentifier.init))
                #if os(macOS)
                case .connection(let sourceID):
                    if let source = aggregate.source(sourceID) {
                        PhoneHubConnectionDetailView(source: source, store: source.store, connections: connections,
                                                     aggregate: aggregate, onOpenChat: { id, url in
                            closeConnectionDetails()
                            onOpenChat(id, url)
                        }, onClose: closeConnectionDetails)
                        .id(ObjectIdentifier(source))
                    }
                #endif
                }
            }
        }
        .onChange(of: aggregate.sources.map(\.id)) { _, ids in
            // A removed connection takes its agent pages with it.
            let live = Set(ids)
            if let sheet = connectionSheet, !live.contains(sheet.sourceID) { connectionSheet = nil }
            path.removeAll { !live.contains($0.sourceID) }
        }
        .onChange(of: sessionSearch) { _, text in aggregate.updateSearchQuery(text) }
        .onChange(of: connections.connections, initial: true) { _, sources in aggregate.synchronize(sources.filter { $0.needsKindReview != true }) }
        .task { await connections.resolveLegacyKinds() }
        .onChange(of: isVisible) { _, visible in
            guard !visible else { return }
            // A chat/push/voice handoff must not leave a connection editor
            // over the retained browser destination.
            editor = nil
            connectionSheet = nil
            #if os(macOS)
            closeConnectionDetails()
            #endif
        }
        .onChange(of: pendingConnectionURL, initial: true) { _, url in
            guard let url else { return }
            let canonical = HubConnectionStore.canonicalURL(url.absoluteString)
            editor = Editor(source: connections.connections.first { $0.url == canonical }, address: url.absoluteString)
            pendingConnectionURL = nil
        }
    }

    private var rootList: some View {
        WorkspaceSessionList(wide: usesWorkspaceChrome) {
            if connections.connections.isEmpty {
                Section {
                    VStack(spacing: 16) {
                        Image(systemName: "network").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Your agents, all in one place").font(.title3.bold())
                        // Add Connection lives in the pinned banner above.
                        Text("Add a connection above to bring your agents together, or look around first.")
                            .foregroundStyle(.secondary)
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
                #if os(macOS)
                .listSectionSeparator(.hidden)
                #endif
            }
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
                row.node.sessions?.countLabel,
            ] as [String?]).compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            // The row opens the agent's page (new, pinned and recent
            // conversations); the compose button keeps a one-tap new chat.
            NavigationLink(value: Route.agent(PhoneHubAgentRoute(sourceID: row.source.id, nodeID: row.node.id))) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.node.name).font(.headline).foregroundStyle(.primary)
                        if !detail.isEmpty {
                            Text(detail).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    Button {
                        open(row.node.newSessionPath, source: row.source, nodeID: row.node.id)
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
            PhoneHubSessionSearchField(text: $sessionSearch) { aggregate.searchAllAgents() }
            Menu {
                Picker("Sort by", selection: Binding(get: { current }, set: { if searching { searchSort = $0 } else { sessionSort = $0 } })) {
                    ForEach(options) { Text($0.label).tag($0) }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .frame(width: AppPlatform.isMac ? 32 : 36, height: AppPlatform.isMac ? 32 : 36)
                    .background(Color.platformSecondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 8))
            }
            #if os(macOS)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            #endif
            .accessibilityLabel("Sort sessions")
            .accessibilityValue(current.label)
            .accessibilityIdentifier("phoneHub.sessionSort")
        }
    }

    private func sessionFlag(_ row: PhoneHubSession, flags: [PhoneHubSessionKey: PhoneHubSessionAttention]) -> PhoneHubSessionAttention? {
        if row.session.interactionRequired == true { return .inputRequired }
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
        let key = PhoneHubSessionKey(sourceID: row.source.id, nodeID: row.node.id, sessionID: row.session.id)
        return Button {
            selectedSession = key
            open(row.session.resumePath, source: row.source, nodeID: row.node.id)
        } label: {
            HStack(spacing: 10) {
                if !AppPlatform.isMac {
                    Circle()
                        .fill(flag == .inputRequired ? Color.orange : Color.accentColor)
                        .frame(width: 9, height: 9)
                        .opacity(flag == nil ? 0 : 1)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: AppPlatform.isMac ? 3 : 2) {
                    Text(row.displayTitle)
                        .foregroundStyle(.primary)
                        .font(AppPlatform.isMac ? .system(size: 15) : .body)
                        .fontWeight(flag == nil ? .regular : .semibold)
                        .lineLimit(AppPlatform.isMac ? 2 : nil)
                        .multilineTextAlignment(.leading)
                    if let snippet = row.snippet, !snippet.isEmpty {
                        Text(Self.highlighted(snippet))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Text(sessionCaption(row))
                        .font(AppPlatform.isMac ? .system(size: 12) : .caption)
                        .foregroundStyle(.secondary)
                }
                .overlay(alignment: .topLeading) {
                    if AppPlatform.isMac, flag != nil {
                        Circle()
                            .fill(flag == .inputRequired ? Color.orange : Color.accentColor)
                            .frame(width: 6, height: 6)
                            .offset(x: -9, y: 7)
                            .accessibilityHidden(true)
                    }
                }
                Spacer(minLength: 0)
                if flag == .inputRequired {
                    Text("Input")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                } else if row.session.activeRun == true {
                    ProgressView().controlSize(.mini).accessibilityLabel("Running")
                }
            }
            .modifier(WorkspaceConversationLabel())
        }
        .buttonStyle(.plain)
        .modifier(WorkspaceConversationRow(isSelected: selectedSession == key))
        .accessibilityValue(flag == .inputRequired ? "Input required" : (flag == .unseen ? "Unseen" : ""))
        .accessibilityIdentifier("phoneHub.session.\(row.source.id.uuidString).\(row.node.id).\(row.session.id)")
    }

    private func sessionCaption(_ row: PhoneHubSession) -> String {
        var parts = [row.node.name]
        if let ms = row.session.lastMessageAt, ms > 0 {
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
                   let item = source.store.inbox.first(where: { $0.nodeID == row.nodeID && $0.sessionID == request.sessionID && $0.storeInstanceID == request.storeInstanceID && $0.attentionSeq == request.attentionSeq }) {
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
        let unavailableAll = unavailable && aggregate.sources.allSatisfy { source in
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
                Text(unavailable ? "Can’t reach \(unavailableAll ? "your connections" : "some connections")" : (offlineOnly ? "No agents online" : (panel == .attention ? "You’re all caught up" : "No \(panel.rawValue.lowercased()) yet")))
                    .font(.headline)
                Text(unavailable ? "Reconnect above to see their \(panel.rawValue.lowercased())." : (offlineOnly ? "Offline agents are hidden. Turn on Show offline agents in Settings › Connections to see them." : (aggregate.sources.isEmpty ? "Add a connection to get started." : (panel == .attention ? "New requests and results will appear here." : "Your \(panel.rawValue.lowercased()) will appear here when available."))))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.vertical, 24)
    }

    private func openIssue(_ source: HubSourceWorkspace, action: PhoneHubConnectionIssue.Action?) {
        if action == .signIn && !source.connection.isLinkedDevices {
            signIn(source)
        } else {
            openConnectionDetails(source.id)
        }
    }

    private func openConnectionDetails(_ sourceID: UUID) {
        #if os(macOS)
        // AppKit vetoes app termination while a document-modal sheet is up.
        // Routine connection status and retry belong in the Agents window.
        path.append(.connection(sourceID))
        #else
        connectionSheet = ConnectionSheet(sourceID: sourceID, route: .details)
        #endif
    }

    #if os(macOS)
    private func closeConnectionDetails() {
        if case .connection = path.last { path.removeLast() }
    }
    #endif

    /// One tap from the banner to the system passkey sheet, as Chat's sign-in
    /// does. Only a token Hub needs a page first, to type its token.
    private func signIn(_ source: HubSourceWorkspace) {
        guard signingInSourceID == nil else { return }
        let tokenPage: ConnectionSheet.Route = source.connection.kind == .hub
            ? (source.hubWorkspace == nil ? .details : .hubSignIn) : .directSignIn
        // Fixtures cannot complete a system passkey ceremony.
        guard tokenPage != .details else { openConnectionDetails(source.id); return }
        guard !PhoneHubFixture.isEnabled else {
            connectionSheet = ConnectionSheet(sourceID: source.id, route: tokenPage)
            return
        }
        signingInSourceID = source.id
        source.authenticationError = nil
        Task { @MainActor in
            if source.connection.kind == .hub, let client = source.hubWorkspace?.client,
               case .page(let config)? = try? await client.discover() {
                source.store.setAuthMode(HubAuthMode(rawValue: config.authMode) ?? .passkey)
                if config.authMode == HubAuthMode.bearer.rawValue {
                    signingInSourceID = nil
                    connectionSheet = ConnectionSheet(sourceID: source.id, route: tokenPage)
                    return
                }
            }
            guard let epoch = await source.prepareAuthentication() else { signingInSourceID = nil; return }
            nativeLogin.cookieSink = source.nativeCookieSink(epoch: epoch)
            nativeLogin.signIn(to: source.connection.url) { result in
                signingInSourceID = nil
                guard source.isActive, source.authEpoch == epoch else { return }
                switch result {
                case .success:
                    Task { _ = await source.authenticationSucceeded(epoch: epoch) }
                case .failure(let error):
                    // Closing the passkey sheet is a choice, not a failure.
                    if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin { return }
                    source.authenticationError = error.localizedDescription
                }
            }
        }
    }

    @ViewBuilder private func connectionSheetContent(_ sheet: ConnectionSheet) -> some View {
        if let source = aggregate.source(sheet.sourceID) {
            let close = { connectionSheet = nil }
            let openChat: (UUID, URL) -> Void = { id, url in
                connectionSheet = nil
                onOpenChat(id, url)
            }
            Group {
                switch sheet.route {
                case .hubSignIn:
                    PhoneHubManageSheet(source: source, closeTitle: "Done", onOpen: { url, nodeID in
                        switch PhoneHubConnectionDetailView.destination(url, nodeID: nodeID, source: source, aggregate: aggregate) {
                        case .ignore: return
                        case .unsafe: navigationError = PhoneHubConnectionDetailView.unsafeDestinationMessage; close()
                        case .open: openChat(source.id, url)
                        }
                    }, onClose: close)
                case .directSignIn:
                    PhoneHubDirectAuthentication(source: source)
                        .safeAreaInset(edge: .bottom, spacing: 0) { PhoneHubFixtureBanner() }
                case .details:
                    #if !os(macOS)
                    NavigationStack {
                        PhoneHubConnectionDetailView(source: source, store: source.store, connections: connections,
                                                     aggregate: aggregate, onOpenChat: openChat, onClose: close)
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Done", action: close).accessibilityIdentifier("phoneHub.issueSheet.done")
                                }
                            }
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) { PhoneHubFixtureBanner() }
                    #endif
                }
            }
            #if os(macOS)
            .frame(minWidth: 480, idealWidth: 540, minHeight: 520, idealHeight: 640)
            #endif
        }
    }

    private func open(_ path: String, source: HubConnection, nodeID: String) {
        guard let url = aggregate.destination(path: path, sourceID: source.id, nodeID: nodeID) else {
            navigationError = "The source supplied an unsafe chat path. Navigation blocked."
            return
        }
        onOpenChat(source.id, url)
    }
}
