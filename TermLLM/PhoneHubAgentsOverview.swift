import SwiftUI

/// The Agents panel on Mac and iPad. One agent gets a page of its own with its
/// live work up front; several agents get a card each. iPhone keeps the list.
enum PhoneHubAgentsLayout: Equatable {
    case home, fleet

    static func `for`(agentCount: Int) -> Self? {
        if agentCount <= 0 { return nil }
        return agentCount == 1 ? .home : .fleet
    }
}

/// One agent's health and live activity, from the dashboard data that is
/// already polled. Needs-input and unread prefer attention counts, which also
/// drive the Attention badge; the node's own counts stand in until they
/// arrive. Running counts the conversations the page shows as running: one
/// waiting on you is listed under Needs you instead, so it is not counted twice.
struct PhoneHubAgentSummary: Identifiable {
    let source: HubConnection
    let node: HubNode
    let running: Int
    let needsInput: Int
    let unread: Int

    /// `waiting` holds the conversations attention says need input; the node's
    /// own listing can still show one of them as running.
    init(source: HubConnection, node: HubNode, attention: HubAttentionNode?, waiting: Set<String> = []) {
        self.source = source
        self.node = node
        let sessions = HubNavigation.nodeSessions(node)
        running = sessions.filter { $0.activeRun == true && $0.interactionRequired != true && !waiting.contains($0.id) }.count
        if let attention {
            needsInput = max(0, attention.inputRequiredCount)
            unread = max(0, attention.unseenCount)
        } else {
            needsInput = max(0, node.sessions?.inputRequiredCount ?? sessions.filter { $0.interactionRequired == true }.count)
            unread = max(0, node.sessions?.unseenCount ?? 0)
        }
    }

    var id: PhoneHubIdentity { PhoneHubIdentity(sourceID: source.id, nodeID: node.id, sessionID: "", key: "summary") }
    var route: PhoneHubAgentRoute { PhoneHubAgentRoute(sourceID: source.id, nodeID: node.id) }
    var isOnline: Bool { node.status.reachable }
    var isIdle: Bool { running == 0 && needsInput == 0 && unread == 0 }

    /// "Online · v0.9.99 · 41 ms". Latency is left out when it was not
    /// measured (a Direct Node reports 0); offline says why when it can.
    var statusText: String {
        guard isOnline else {
            let reason = node.status.error?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return reason.isEmpty ? String(localized: "Offline") : String(localized: "Offline · \(reason)")
        }
        var parts = [String(localized: "Online")]
        if let version = Self.versionLabel(node.status.version) { parts.append(version) }
        if node.status.latencyMs > 0 { parts.append(String(localized: "\(node.status.latencyMs) ms")) }
        return parts.joined(separator: " · ")
    }

    /// Where the agent lives, unless that only repeats its name.
    var place: String? {
        if source.isManagedLocalService { return String(localized: "Local service") }
        let name = source.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.caseInsensitiveCompare(node.name) != .orderedSame else { return nil }
        return source.kind == .hub ? String(localized: "via \(name)") : name
    }

    var symbol: String { source.isManagedLocalService ? "laptopcomputer" : "server.rack" }

    var conversationCount: PhoneHubCountLabel? { PhoneHubCountLabel(node.sessions?.countLabel) }

    static func versionLabel(_ version: String?) -> String? {
        guard let raw = version?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return raw.first?.isNumber == true ? "v" + raw : raw
    }

    /// Conversations worth surfacing for this agent, most urgent first and one
    /// row per conversation: waiting on you, running, unread, then recent.
    /// `attention` must already be limited to this agent.
    static func highlights(node: HubNode, attention: [PhoneHubAttention], limit: Int = .max) -> [PhoneHubAgentHighlight] {
        let sessions = HubNavigation.nodeSessions(node)
        let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let newestFirst = sessions.sorted { ($0.lastMessageAt ?? 0) > ($1.lastMessageAt ?? 0) }
        var seen = Set<String>()
        var rows: [PhoneHubAgentHighlight] = []
        func add(_ row: PhoneHubAgentHighlight) {
            guard rows.count < limit, seen.insert(row.sessionID).inserted else { return }
            rows.append(row)
        }
        func row(_ kind: PhoneHubAgentHighlight.Kind, _ item: PhoneHubAttention) -> PhoneHubAgentHighlight {
            let session = byID[item.sessionID]
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return PhoneHubAgentHighlight(kind: kind, sessionID: item.sessionID,
                                          title: title.isEmpty ? session.map(Self.title) ?? String(localized: "Untitled conversation") : title,
                                          path: item.path, date: Self.date(session?.lastMessageAt),
                                          messageCount: session?.messageCount,
                                          detail: kind == .needsInput ? PhoneHubAgentHighlight.inputDetail(item.kinds)
                                                                      : PhoneHubAgentHighlight.outcomeDetail(item.outcome))
        }
        func row(_ kind: PhoneHubAgentHighlight.Kind, _ session: HubNodeSession) -> PhoneHubAgentHighlight {
            PhoneHubAgentHighlight(kind: kind, sessionID: session.id, title: Self.title(session), path: session.resumePath,
                                   date: Self.date(session.lastMessageAt), messageCount: session.messageCount,
                                   detail: kind == .needsInput ? PhoneHubAgentHighlight.inputDetail(session.pendingInteractionKinds ?? []) : nil)
        }
        for item in attention where item.inputRequired { add(row(.needsInput, item)) }
        for session in newestFirst where session.interactionRequired == true { add(row(.needsInput, session)) }
        for session in newestFirst where session.activeRun == true { add(row(.running, session)) }
        for item in attention where !item.inputRequired { add(row(.unread, item)) }
        for session in newestFirst { add(row(.recent, session)) }
        return rows
    }

    private static func title(_ session: HubNodeSession) -> String {
        let short = session.shortTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !short.isEmpty { return short }
        if let long = session.longTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !long.isEmpty { return long }
        return session.number.map { String(localized: "Conversation \($0)") } ?? String(localized: "Untitled conversation")
    }

    private static func date(_ milliseconds: Int?) -> Date? {
        guard let milliseconds, milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
    }
}

/// A node's count label split for a statistic: "200 conversations" becomes
/// "200" over "conversations". Labels that do not lead with a number are not
/// statistics.
struct PhoneHubCountLabel: Equatable {
    let value: String
    let caption: String

    init(value: String, caption: String) {
        self.value = value
        self.caption = caption
    }

    init?(_ label: String?) {
        guard let label = label?.trimmingCharacters(in: .whitespacesAndNewlines),
              label.first?.isNumber == true else { return nil }
        let number = label.prefix { $0.isNumber || $0 == "," || $0 == "." || $0 == "+" }
        let rest = label.dropFirst(number.count).trimmingCharacters(in: .whitespaces)
        value = String(number)
        caption = rest.isEmpty ? String(localized: "conversations") : rest
    }
}

struct PhoneHubAgentHighlight: Identifiable, Equatable {
    enum Kind: Equatable { case needsInput, running, unread, recent }
    let kind: Kind
    let sessionID: String
    let title: String
    let path: String
    let date: Date?
    let messageCount: Int?
    let detail: String?
    var id: String { sessionID }

    static func inputDetail(_ kinds: [String]) -> String {
        kinds.contains { $0.lowercased() == "approval" } ? String(localized: "Approval requested") : String(localized: "Needs your input")
    }

    static func outcomeDetail(_ outcome: String?) -> String? {
        guard let outcome = outcome?.trimmingCharacters(in: .whitespacesAndNewlines), !outcome.isEmpty else { return nil }
        switch outcome.lowercased() {
        case "completed", "complete", "done", "success", "succeeded": return String(localized: "Completed")
        case "failed", "failure", "error", "errored": return String(localized: "Failed")
        case "cancelled", "canceled", "interrupted": return String(localized: "Stopped")
        default: return outcome.prefix(1).uppercased() + outcome.dropFirst()
        }
    }
}

// MARK: - Overview

@MainActor
struct PhoneHubAgentsOverview: View {
    @ObservedObject var aggregate: HubAggregateStore
    /// Already filtered to the agents the list would show.
    let nodes: [PhoneHubNode]
    let isVisible: Bool
    let navigationError: String?
    /// Opens a server-supplied path for one agent; the owner validates it.
    let onOpen: (String, HubConnection, String) -> Void
    let onShowAttention: () -> Void

    var body: some View {
        let attention = aggregate.attention
        let summaries = nodes.map { row in
            let waiting = attention.filter { $0.inputRequired && $0.source.id == row.source.id && $0.nodeID == row.node.id }
            return PhoneHubAgentSummary(source: row.source, node: row.node, attention: attentionNode(row),
                                        waiting: Set(waiting.map(\.sessionID)))
        }
        let layout = PhoneHubAgentsLayout.for(agentCount: summaries.count)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let navigationError {
                    Text(navigationError).foregroundStyle(.orange)
                }
                switch layout {
                case .home:
                    if let agent = summaries.first {
                        PhoneHubAgentHome(summary: agent, attention: Self.attention(attention, for: agent),
                                          aggregate: aggregate, isVisible: isVisible,
                                          onOpen: { onOpen($0, agent.source, agent.node.id) },
                                          onShowAttention: onShowAttention)
                            // An edited endpoint is a new source identity: start over.
                            .id(PhoneHubAgentHome.Identity(route: agent.route,
                                                           source: aggregate.source(agent.source.id).map(ObjectIdentifier.init)))
                    }
                case .fleet:
                    PhoneHubAgentFleet(summaries: summaries, attention: { Self.attention(attention, for: $0) },
                                       onOpen: { agent, path in onOpen(path, agent.source, agent.node.id) })
                case nil:
                    EmptyView()
                }
            }
            .frame(maxWidth: layout == .fleet ? 1040 : 940, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity)
        }
        #if os(iOS)
        .background(Color.platformGroupedBackground)
        #endif
        .accessibilityIdentifier("phoneHub.overview")
    }

    private func attentionNode(_ row: PhoneHubNode) -> HubAttentionNode? {
        guard let store = aggregate.source(row.source.id)?.store, store.attentionVerified, !store.unauthorized else { return nil }
        return store.attentionNodes.first { $0.nodeID == row.node.id }
    }

    private static func attention(_ rows: [PhoneHubAttention], for agent: PhoneHubAgentSummary) -> [PhoneHubAttention] {
        rows.filter { $0.source.id == agent.source.id && $0.nodeID == agent.node.id }
    }
}

// MARK: - One agent

@MainActor
private struct PhoneHubAgentHome: View {
    struct Identity: Hashable {
        let route: PhoneHubAgentRoute
        let source: ObjectIdentifier?
    }

    let summary: PhoneHubAgentSummary
    let attention: [PhoneHubAttention]
    @ObservedObject var aggregate: HubAggregateStore
    let isVisible: Bool
    let onOpen: (String) -> Void
    let onShowAttention: () -> Void
    /// The agent's first page of history: pins and recent conversations.
    @StateObject private var model: PhoneHubAgentSessions
    private static let needsYouLimit = 5
    private static let listLimit = 5

    init(summary: PhoneHubAgentSummary, attention: [PhoneHubAttention], aggregate: HubAggregateStore,
         isVisible: Bool, onOpen: @escaping (String) -> Void, onShowAttention: @escaping () -> Void) {
        self.summary = summary
        self.attention = attention
        self.aggregate = aggregate
        self.isVisible = isVisible
        self.onOpen = onOpen
        self.onShowAttention = onShowAttention
        _model = StateObject(wrappedValue: PhoneHubAgentSessions(source: aggregate.source(summary.source.id), nodeID: summary.node.id))
    }

    var body: some View {
        let highlights = PhoneHubAgentSummary.highlights(node: summary.node, attention: attention)
        let needsYou = highlights.filter { $0.kind == .needsInput || $0.kind == .unread }
        let running = highlights.filter { $0.kind == .running }
        let shown = Set((needsYou.prefix(Self.needsYouLimit) + running).map(\.sessionID))
        let pinned = Array(model.pinned.prefix(Self.listLimit))
        let recent = Array(model.history.filter { !shown.contains($0.id) && !$0.running && !$0.needsInput }.prefix(Self.listLimit))
        VStack(alignment: .leading, spacing: 14) {
            hero
            // At most two columns within the page's 940 pt measure; one when narrow.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14, alignment: .top)],
                      alignment: .leading, spacing: 14) {
                needsYouCard(needsYou)
                VStack(spacing: 14) {
                    runningCard(running)
                    if !pinned.isEmpty { pinnedCard(pinned) }
                }
            }
            recentCard(recent)
        }
        .onAppear(perform: appeared)
        .onChange(of: isVisible) { _, visible in if visible { appeared() } }
    }

    private func appeared() {
        guard summary.isOnline else { return }
        model.appeared()
    }

    // MARK: Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Actions beside the name, or below it when the page is narrow.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    identity
                    Spacer(minLength: 12)
                    actions
                }
                VStack(alignment: .leading, spacing: 12) {
                    identity
                    actions
                }
            }
            // One row of statistics, or two when the page is narrow.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { stats }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    stats
                }
            }
        }
        .padding(16)
        .background(OverviewStyle.heroFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(OverviewStyle.stroke))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("phoneHub.overview.agent")
    }

    private var identity: some View {
        HStack(spacing: 12) {
            PhoneHubAgentAvatar(symbol: summary.symbol, size: 44, online: summary.isOnline)
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.node.name)
                    .font(OverviewStyle.heroName)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                PhoneHubAgentStatusLine(summary: summary, includesPlace: true)
            }
        }
    }

    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { actionButtons }
            VStack(alignment: .leading, spacing: 10) { actionButtons }
        }
    }

    @ViewBuilder private var actionButtons: some View {
        NavigationLink(value: summary.route) {
            Text("All conversations").lineLimit(1)
        }
        .buttonStyle(.bordered)
        .fixedSize()
        .accessibilityIdentifier("phoneHub.node.\(summary.source.id.uuidString).\(summary.node.id)")
        Button { onOpen(summary.node.newSessionPath) } label: {
            Label("New conversation", systemImage: "square.and.pencil").lineLimit(1)
        }
        .buttonStyle(.borderedProminent)
        .fixedSize()
        .disabled(!summary.isOnline)
        .accessibilityLabel("New conversation with \(summary.node.name)")
        .accessibilityIdentifier("phoneHub.node.\(summary.source.id.uuidString).\(summary.node.id).new")
    }

    @ViewBuilder private var stats: some View {
        PhoneHubAgentStat(value: "\(summary.running)", label: String(localized: "Running"),
                          indicator: summary.running > 0 ? .spinner : .none)
        PhoneHubAgentStat(value: "\(summary.needsInput)", label: String(localized: "Needs your input"),
                          indicator: .none, alert: summary.needsInput > 0)
        PhoneHubAgentStat(value: "\(summary.unread)", label: String(localized: "Unread results"),
                          indicator: summary.unread > 0 ? .dot : .none)
        if let count = summary.conversationCount {
            PhoneHubAgentStat(value: count.value, label: count.caption.capitalized, indicator: .none)
        }
    }

    // MARK: Sections

    private func needsYouCard(_ rows: [PhoneHubAgentHighlight]) -> some View {
        PhoneHubOverviewCard(title: String(localized: "Needs you"), count: rows.isEmpty ? nil : rows.count) {
            if rows.count > Self.needsYouLimit {
                Button("Show all", action: onShowAttention)
                    .buttonStyle(.plain)
                    .font(OverviewStyle.caption)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityIdentifier("phoneHub.overview.showAttention")
            }
        } content: {
            if rows.isEmpty {
                PhoneHubOverviewMessage(symbol: "checkmark.circle", text: String(localized: "You’re all caught up"))
            }
            ForEach(rows.prefix(Self.needsYouLimit)) { row in
                PhoneHubOverviewRow(indicator: row.kind == .needsInput ? .needsInput : .done, title: row.title,
                                    caption: row.detail, captionTint: row.kind == .needsInput ? .orange : .secondary,
                                    trailing: row.kind == .needsInput ? .review : .time(row.date),
                                    emphasized: true) { onOpen(row.path) }
                    .accessibilityIdentifier("phoneHub.overview.needsYou.\(row.sessionID)")
            }
        }
    }

    private func runningCard(_ rows: [PhoneHubAgentHighlight]) -> some View {
        PhoneHubOverviewCard(title: String(localized: "Running now"), count: rows.isEmpty ? nil : rows.count) {
            EmptyView()
        } content: {
            if rows.isEmpty {
                PhoneHubOverviewMessage(symbol: "moon.zzz", text: String(localized: "Nothing running"))
            }
            ForEach(rows.prefix(Self.listLimit)) { row in
                PhoneHubOverviewRow(indicator: .running, title: row.title, caption: Self.messages(row.messageCount),
                                    trailing: .time(row.date)) { onOpen(row.path) }
                    .accessibilityIdentifier("phoneHub.overview.running.\(row.sessionID)")
            }
        }
    }

    private func pinnedCard(_ rows: [PhoneHubAgentConversation]) -> some View {
        PhoneHubOverviewCard(title: String(localized: "Pinned"), count: nil) {
            EmptyView()
        } content: {
            ForEach(rows) { row in
                PhoneHubOverviewRow(indicator: .pinned, title: row.title, trailing: .time(row.lastActivity),
                                    emphasized: row.unseen || row.needsInput) { open(row) }
                    .accessibilityIdentifier("phoneHub.overview.pinned.\(row.id)")
            }
        }
    }

    private func recentCard(_ rows: [PhoneHubAgentConversation]) -> some View {
        PhoneHubOverviewCard(title: String(localized: "Recent"), count: nil) {
            EmptyView()
        } content: {
            if rows.isEmpty {
                if !model.hasLoadedFirstPage && model.paging == .loading {
                    PhoneHubOverviewMessage(symbol: nil, text: String(localized: "Loading conversations…"), loading: true)
                } else {
                    PhoneHubOverviewMessage(symbol: "bubble.left.and.bubble.right",
                                            text: String(localized: "Recent conversations will appear here."))
                }
            }
            ForEach(rows) { row in
                PhoneHubOverviewRow(indicator: row.unseen ? .unread : .none, title: row.title,
                                    caption: Self.messages(row.messageCount), trailing: .time(row.lastActivity),
                                    emphasized: row.unseen) { open(row) }
                    .accessibilityIdentifier("phoneHub.overview.recent.\(row.id)")
            }
            NavigationLink(value: summary.route) {
                HStack(spacing: 6) {
                    Text(summary.conversationCount.map { String(localized: "Show all \($0.value) \($0.caption)") }
                         ?? String(localized: "Show all conversations"))
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                }
                .font(OverviewStyle.caption.weight(.medium))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(alignment: .top) { Divider() }
            .accessibilityIdentifier("phoneHub.node.\(summary.source.id.uuidString).\(summary.node.id).all")
        }
    }

    private func open(_ row: PhoneHubAgentConversation) {
        onOpen(HubAggregateStore.resumePath(connection: summary.source, nodeID: summary.node.id, number: row.number, id: row.id))
    }

    static func messages(_ count: Int?) -> String? {
        guard let count, count > 0 else { return nil }
        return count == 1 ? String(localized: "1 message") : String(localized: "\(count) messages")
    }
}

// MARK: - Several agents

@MainActor
private struct PhoneHubAgentFleet: View {
    let summaries: [PhoneHubAgentSummary]
    let attention: (PhoneHubAgentSummary) -> [PhoneHubAttention]
    let onOpen: (PhoneHubAgentSummary, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            totals
            // At most two columns within the page's 1040 pt measure; one when narrow.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 14, alignment: .top)],
                      alignment: .leading, spacing: 14) {
                ForEach(summaries) { agent in
                    PhoneHubAgentCard(summary: agent,
                                      highlights: PhoneHubAgentSummary.highlights(node: agent.node, attention: attention(agent),
                                                                                  limit: PhoneHubAgentCard.rowCount),
                                      onOpen: { onOpen(agent, $0) })
                }
            }
        }
    }

    private var totals: some View {
        let online = summaries.filter(\.isOnline).count
        let running = summaries.reduce(0) { $0 + $1.running }
        let needsInput = summaries.reduce(0) { $0 + $1.needsInput }
        let unread = summaries.reduce(0) { $0 + $1.unread }
        return PhoneHubChipFlow {
            Text("\(summaries.count) agents")
                .font(OverviewStyle.cardName)
                .padding(.trailing, 4)
            PhoneHubAgentChip(text: String(localized: "\(online) online"), tint: .green)
            if running > 0 { PhoneHubAgentChip(text: String(localized: "\(running) running"), tint: .accentColor) }
            if needsInput > 0 { PhoneHubAgentChip(text: String(localized: "\(needsInput) need input"), tint: .orange) }
            if unread > 0 { PhoneHubAgentChip(text: String(localized: "\(unread) unread"), tint: .secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("phoneHub.overview.totals")
    }
}

@MainActor
private struct PhoneHubAgentCard: View {
    static let rowCount = 3
    let summary: PhoneHubAgentSummary
    let highlights: [PhoneHubAgentHighlight]
    let onOpen: (String) -> Void
    private var nodeID: String { "phoneHub.node.\(summary.source.id.uuidString).\(summary.node.id)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                PhoneHubAgentAvatar(symbol: summary.symbol, size: 38, online: summary.isOnline)
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.node.name)
                        .font(OverviewStyle.cardName)
                        .lineLimit(1)
                    if let place = summary.place {
                        Text(place).font(OverviewStyle.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .opacity(summary.isOnline ? 1 : 0.55)
                Spacer(minLength: 8)
                if summary.isOnline {
                    Button { onOpen(summary.node.newSessionPath) } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(Color.accentColor.opacity(0.12)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("New conversation with \(summary.node.name)")
                    .accessibilityIdentifier(nodeID + ".new")
                }
            }
            PhoneHubAgentStatusLine(summary: summary, includesPlace: false)
                .padding(.top, 10)
            chips
                .padding(.top, 8)
            Divider().padding(.top, 10)
            rows
            footer
        }
        .padding(.top, 14)
        .padding(.horizontal, 16)
        .background(OverviewStyle.cardFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(OverviewStyle.stroke))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(nodeID + ".card")
    }

    @ViewBuilder private var chips: some View {
        PhoneHubChipFlow(spacing: 6) {
            if !summary.isOnline {
                PhoneHubAgentChip(text: String(localized: "Unavailable"), tint: .secondary)
            } else if summary.isIdle {
                PhoneHubAgentChip(text: String(localized: "Idle"), tint: .secondary)
            } else {
                if summary.running > 0 {
                    PhoneHubAgentChip(text: String(localized: "\(summary.running) running"), tint: .accentColor, spinner: true)
                }
                if summary.needsInput > 0 {
                    PhoneHubAgentChip(text: String(localized: "\(summary.needsInput) needs input"), tint: .orange)
                }
                if summary.unread > 0 {
                    PhoneHubAgentChip(text: String(localized: "\(summary.unread) unread"), tint: .secondary)
                }
            }
        }
    }

    /// Always the same number of slots, so cards in a row line up.
    @ViewBuilder private var rows: some View {
        if summary.isOnline {
            ForEach(highlights) { row in
                PhoneHubOverviewRow(indicator: Self.indicator(row.kind), title: row.title, trailing: .time(row.date),
                                    emphasized: row.kind == .needsInput || row.kind == .unread, inset: 0, divider: false) {
                    onOpen(row.path)
                }
                .accessibilityIdentifier(nodeID + ".session.\(row.sessionID)")
            }
            if highlights.isEmpty {
                PhoneHubOverviewMessage(symbol: nil, text: String(localized: "No conversations yet"), inset: 0)
            }
            ForEach(0..<max(0, Self.rowCount - max(highlights.count, 1)), id: \.self) { _ in
                PhoneHubOverviewRow.placeholder
            }
        } else {
            Text("Conversations are unavailable until it reconnects.")
                .font(OverviewStyle.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: PhoneHubOverviewRow.compactHeight * CGFloat(Self.rowCount), alignment: .leading)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(summary.node.sessions?.countLabel ?? "")
                .font(OverviewStyle.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            NavigationLink(value: summary.route) {
                HStack(spacing: 4) {
                    Text("Open")
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                }
                .font(OverviewStyle.caption.weight(.medium))
                .foregroundStyle(summary.isOnline ? Color.accentColor : Color.secondary)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!summary.isOnline)
            .accessibilityLabel("Open \(summary.node.name)")
            .accessibilityIdentifier(nodeID)
        }
        .overlay(alignment: .top) { Divider() }
    }

    private static func indicator(_ kind: PhoneHubAgentHighlight.Kind) -> PhoneHubOverviewRow.Indicator {
        switch kind {
        case .needsInput: .needsInput
        case .running: .running
        case .unread: .unread
        case .recent: .none
        }
    }
}

// MARK: - Shared pieces

/// Mac text styles have fixed sizes, so the Mac uses explicit ones; iPad
/// follows Dynamic Type.
private enum OverviewStyle {
    static var heroName: Font { AppPlatform.isMac ? .system(size: 17, weight: .semibold) : .title3.weight(.semibold) }
    static var cardName: Font { AppPlatform.isMac ? .system(size: 15, weight: .semibold) : .headline }
    static var rowTitle: Font { AppPlatform.isMac ? .system(size: 13.5) : .body }
    static var caption: Font { AppPlatform.isMac ? .system(size: 12) : .subheadline }
    static var chip: Font { AppPlatform.isMac ? .system(size: 11.5, weight: .semibold) : .caption.weight(.semibold) }
    static var sectionLabel: Font { AppPlatform.isMac ? .system(size: 11, weight: .semibold) : .footnote.weight(.semibold) }
    static var statValue: Font { AppPlatform.isMac ? .system(size: 22, weight: .semibold) : .title2.weight(.semibold) }

    /// The Mac page sits on the plain window: a tinted summary card with
    /// outlined cards and tiles. iPad uses grouped surfaces, like its lists.
    static var heroFill: Color { AppPlatform.isMac ? Color.primary.opacity(0.04) : Color.platformSecondaryGroupedBackground }
    static var cardFill: Color { AppPlatform.isMac ? Color.platformBackground : Color.platformSecondaryGroupedBackground }
    static var tileFill: Color { AppPlatform.isMac ? Color.platformBackground : Color.platformGroupedBackground }
    static var stroke: Color { Color.primary.opacity(AppPlatform.isMac ? 0.09 : 0.06) }
}

private struct PhoneHubAgentAvatar: View {
    let symbol: String
    let size: CGFloat
    let online: Bool

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42))
            .foregroundStyle(online ? Color.accentColor : Color.secondary)
            .frame(width: size, height: size)
            .background(Color.accentColor.opacity(online ? 0.1 : 0.04),
                        in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .accessibilityHidden(true)
    }
}

private struct PhoneHubAgentStatusLine: View {
    let summary: PhoneHubAgentSummary
    let includesPlace: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(summary.isOnline ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(([summary.statusText] + (includesPlace ? [summary.place].compactMap { $0 } : [])).joined(separator: " · "))
                .font(OverviewStyle.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct PhoneHubAgentChip: View {
    let text: String
    let tint: Color
    var spinner = false

    var body: some View {
        HStack(spacing: 5) {
            if spinner { ProgressView().controlSize(.mini) }
            Text(text).lineLimit(1)
        }
        .font(OverviewStyle.chip)
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(0.13), in: Capsule())
    }
}

/// Lays items out left to right, starting a new line when the next one would
/// not fit; each line is centred vertically.
private struct PhoneHubChipFlow: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 6

    private struct Line {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func lines(_ subviews: Subviews, width: CGFloat) -> [Line] {
        var lines: [Line] = []
        var line = Line()
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let needed = line.items.isEmpty ? size.width : line.width + spacing + size.width
            if !line.items.isEmpty && needed > width {
                lines.append(line)
                line = Line()
            }
            line.width = line.items.isEmpty ? size.width : line.width + spacing + size.width
            line.height = max(line.height, size.height)
            line.items.append((index, size))
        }
        if !line.items.isEmpty { lines.append(line) }
        return lines
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = lines(subviews, width: proposal.width ?? .infinity)
        let height = lines.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, lines.count - 1))
        let width = lines.map(\.width).max() ?? 0
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(subviews, width: bounds.width) {
            var x = bounds.minX
            for item in line.items {
                subviews[item.index].place(at: CGPoint(x: x, y: y + (line.height - item.size.height) / 2),
                                           anchor: .topLeading, proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }
}

private struct PhoneHubAgentStat: View {
    enum Indicator { case none, spinner, dot }
    let value: String
    let label: String
    let indicator: Indicator
    var alert = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                switch indicator {
                case .none: EmptyView()
                case .spinner: ProgressView().controlSize(.small)
                case .dot: Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                }
                Text(value)
                    .font(OverviewStyle.statValue)
                    .monospacedDigit()
                    .foregroundStyle(alert ? Color.orange : Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            Text(label)
                .font(OverviewStyle.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(alert ? Color.orange.opacity(0.08) : OverviewStyle.tileFill,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(alert ? Color.orange.opacity(0.4) : OverviewStyle.stroke))
        .accessibilityElement(children: .combine)
    }
}

private struct PhoneHubOverviewCard<Accessory: View, Content: View>: View {
    let title: String
    let count: Int?
    @ViewBuilder let accessory: () -> Accessory
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(title)
                    .font(OverviewStyle.sectionLabel)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .accessibilityAddTraits(.isHeader)
                if let count {
                    Text("\(count)").font(OverviewStyle.sectionLabel).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                accessory()
            }
            .padding(.horizontal, 14)
            .padding(.top, 11)
            .padding(.bottom, 7)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OverviewStyle.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(OverviewStyle.stroke))
    }
}

private struct PhoneHubOverviewMessage: View {
    let symbol: String?
    let text: String
    var loading = false
    var inset: CGFloat = 14

    var body: some View {
        HStack(spacing: 8) {
            if loading { ProgressView().controlSize(.small) }
            if let symbol { Image(systemName: symbol).accessibilityHidden(true) }
            Text(text)
        }
        .font(OverviewStyle.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, inset)
        .frame(maxWidth: .infinity, minHeight: PhoneHubOverviewRow.compactHeight, alignment: .leading)
        .overlay(alignment: .top) { Divider().padding(.leading, inset) }
    }
}

private struct PhoneHubOverviewRow: View {
    enum Indicator { case none, needsInput, done, running, unread, pinned }
    enum Trailing { case time(Date?), review }
    /// Touch targets on iPad; a denser list on Mac.
    static let compactHeight: CGFloat = AppPlatform.isMac ? 34 : 44

    let indicator: Indicator
    let title: String
    var caption: String? = nil
    var captionTint: Color = .secondary
    var trailing: Trailing = .time(nil)
    var emphasized = false
    var inset: CGFloat = 14
    var divider = true
    let action: () -> Void

    /// Holds a row's place in a card that has fewer conversations.
    static var placeholder: some View {
        Color.clear.frame(height: compactHeight).accessibilityHidden(true)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                indicatorView.frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(OverviewStyle.rowTitle.weight(emphasized ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let caption, !caption.isEmpty {
                        Text(caption)
                            .font(OverviewStyle.caption)
                            .foregroundStyle(captionTint)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                trailingView
            }
            .padding(.horizontal, inset)
            .padding(.vertical, caption == nil ? 7 : 9)
            .frame(maxWidth: .infinity, minHeight: Self.compactHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PhoneHubOverviewRowStyle())
        .overlay(alignment: .top) {
            if divider { Divider().padding(.leading, inset) }
        }
    }

    @ViewBuilder private var indicatorView: some View {
        switch indicator {
        case .none: Color.clear.frame(width: 1, height: 1)
        case .needsInput: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
        case .running: ProgressView().controlSize(.small).accessibilityLabel("Running")
        case .unread: Circle().fill(Color.accentColor).frame(width: 8, height: 8).accessibilityLabel("Unread")
        case .pinned: Image(systemName: "pin.fill").font(.caption).foregroundStyle(PhoneHubAgentConversationRow.pinTint)
        }
    }

    @ViewBuilder private var trailingView: some View {
        switch trailing {
        case .time(let date):
            if let date {
                Text(date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
                    .font(OverviewStyle.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        case .review:
            Text("Review")
                .font(OverviewStyle.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Color.orange.opacity(0.13), in: Capsule())
        }
    }
}

/// Quiet hover and press feedback, like Chat's conversation rows.
private struct PhoneHubOverviewRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Highlight(configuration: configuration)
    }

    private struct Highlight: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovered = false

        var body: some View {
            configuration.label
                .background(Color.primary.opacity(configuration.isPressed ? 0.08 : (hovered ? 0.04 : 0)))
                .onHover { hovered = $0 }
        }
    }
}
