import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// An agent's page on the Agents stack: start a new conversation, or pick up
/// a pinned or recent one. History loads 30 at a time as you scroll.
@MainActor
struct PhoneHubAgentView: View {
    let route: PhoneHubAgentRoute
    @ObservedObject var aggregate: HubAggregateStore
    let isVisible: Bool
    let onOpenChat: (UUID, URL) -> Void
    let onSettings: () -> Void
    @StateObject private var model: PhoneHubAgentSessions
    @AppStorage("phoneHub.agent.pinnedExpanded", store: PhoneHubFixture.defaults) private var pinnedExpanded = true
    @State private var composeInToolbar = false
    @State private var editMode: PlatformEditMode = .inactive
    @State private var renaming: PhoneHubAgentConversation?
    @State private var renameText = ""
    @State private var searchText = ""
    @State private var navigationError: String?
    @State private var now = Date()

    init(route: PhoneHubAgentRoute, aggregate: HubAggregateStore, isVisible: Bool,
         onOpenChat: @escaping (UUID, URL) -> Void, onSettings: @escaping () -> Void) {
        self.route = route
        self.aggregate = aggregate
        self.isVisible = isVisible
        self.onOpenChat = onOpenChat
        self.onSettings = onSettings
        _model = StateObject(wrappedValue: PhoneHubAgentSessions(source: aggregate.source(route.sourceID), nodeID: route.nodeID))
    }

    private var source: HubSourceWorkspace? { aggregate.source(route.sourceID) }
    private var node: HubNode? { source?.store.nodes.first { $0.id == route.nodeID } }
    private var agentName: String { node?.name ?? "Agent" }
    private var query: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Where the agent lives, unless that only repeats its name (a Direct
    /// Node is usually saved under its agent's name), and how much history.
    private var subtitle: String {
        let sourceName = source?.connection.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = sourceName.flatMap { $0.caseInsensitiveCompare(agentName) == .orderedSame ? nil : $0 }
        return [place, node?.sessions?.count_label].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        List {
            if model.signedOut {
                unavailable
            } else if !query.isEmpty {
                searchResults
            } else {
                newConversationSection
                if let navigationError {
                    Section { Text(navigationError).foregroundStyle(.orange) }
                }
                pinnedSection
                historySections
                footer
            }
        }
        .platformInsetGroupedListStyle()
        .platformEditMode($editMode)
        // Once New conversation scrolls away, it moves into the toolbar.
        .modifier(ScrolledPast(distance: 90) { past in
            guard past != composeInToolbar else { return }
            withAnimation(.snappy) { composeInToolbar = past }
        })
        .accessibilityIdentifier("phoneHub.agent")
        #if os(macOS)
        // The header below has the Back button; none in the window toolbar.
        .navigationBarBackButtonHidden(true)
        .workspaceTopBar {
            PushedPageHeader(title: agentName, subtitle: subtitle) {
                if composeInToolbar && !model.signedOut && query.isEmpty { toolbarCompose }
                PushedPageSearchField(text: $searchText, prompt: "Search \(agentName)")
            }
        }
        #else
        .navigationTitle(agentName)
        // Inline like the Agents root: more conversations fit on screen.
        .inlineNavigationTitle()
        .modifier(AgentSubtitle(text: subtitle))
        .navigationBarVisibility(isVisible ? .visible : .hidden)
        .toolbar {
            if composeInToolbar && !model.signedOut && query.isEmpty {
                ToolbarItem(placement: .platformTrailing) { toolbarCompose }
            }
        }
        .searchable(text: $searchText, placement: .platformAlwaysVisible, prompt: Text("Search \(agentName)"))
        #endif
        .task(id: query) {
            guard !query.isEmpty else {
                model.endSearch()
                return
            }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await model.search(query)
        }
        .refreshable {
            now = Date()
            await model.refresh()
        }
        .onAppear {
            now = Date()
            model.appeared()
        }
        .onChange(of: isVisible) { _, visible in
            guard visible else { return }
            now = Date()
            model.appeared()
        }
        .overlay(alignment: .bottom) { noticeBanner }
        .animation(.snappy, value: model.notice)
        .sensoryFeedback(.impact(weight: .light), trigger: model.pinFeedback)
        .sensoryFeedback(trigger: model.notice) { _, notice in
            guard let notice else { return nil }
            return notice.undo == nil ? .error : .success
        }
        .alert("Rename Conversation", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
                .accessibilityIdentifier("phoneHub.agent.renameField")
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                if let row = renaming { withAnimation(.snappy) { model.rename(row.id, to: renameText) } }
                renaming = nil
            }
        } message: {
            Text("The new title shows everywhere \(agentName) is open.")
        }
    }

    private var toolbarCompose: some View {
        Button(action: newConversation) {
            Image(systemName: "square.and.pencil")
        }
        .accessibilityLabel("New conversation")
        .accessibilityIdentifier("phoneHub.agent.newToolbar")
    }

    // MARK: Sections

    private var newConversationSection: some View {
        Section {
            if showsInlineSubtitle {
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 4, trailing: 4))
            }
            Button(action: newConversation) {
                Label("New conversation", systemImage: "square.and.pencil")
                    .labelStyle(.titleAndIcon)
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .accessibilityIdentifier("phoneHub.agent.new")
            .modifier(LegacyVisibility { visible in composeInToolbar = !visible })
            if model.hasLoadedFirstPage && model.conversations.isEmpty {
                ContentUnavailableView("No conversations yet", systemImage: "bubble.left.and.bubble.right",
                                       description: Text("Start one with \(agentName) and it will appear here."))
                    .accessibilityIdentifier("phoneHub.agent.empty")
            }
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
        .listRowSeparator(.hidden)
    }

    @ViewBuilder private var pinnedSection: some View {
        let pins = model.pinned
        if !pins.isEmpty {
            Section {
                if pinnedExpanded {
                    ForEach(pins) { row in conversationRow(row, inPinned: true) }
                        .onMove(perform: model.canEdit ? { offsets, destination in
                            withAnimation(.snappy) { model.movePins(fromOffsets: offsets, toOffset: destination) }
                        } : nil)
                }
            } header: {
                HStack(spacing: 6) {
                    Button {
                        withAnimation(.snappy) {
                            pinnedExpanded.toggle()
                            if !pinnedExpanded { editMode = .inactive }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "pin.fill").foregroundStyle(PhoneHubAgentConversationRow.pinTint)
                                .font(.subheadline)
                            Text("Pinned").foregroundStyle(.primary)
                            Image(systemName: "chevron.down")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Color.accentColor)
                                .rotationEffect(.degrees(pinnedExpanded ? 0 : -90))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(pinnedExpanded ? "Pinned, expanded" : "Pinned, collapsed")
                    .accessibilityHint("Shows or hides pinned conversations")
                    .accessibilityIdentifier("phoneHub.agent.pinnedToggle")
                    Spacer(minLength: 0)
                    // Mac lists reorder by dragging; there is no edit mode to enter.
                    if model.canEdit && pins.count > 1 && pinnedExpanded && !AppPlatform.isMac {
                        Button(editMode.isEditing ? "Done" : "Edit") {
                            withAnimation(.snappy) { editMode = editMode.isEditing ? .inactive : .active }
                        }
                        .font(.body.weight(editMode.isEditing ? .semibold : .regular))
                        .accessibilityIdentifier("phoneHub.agent.editPins")
                    }
                }
                .textCase(nil)
            }
            .headerProminence(.increased)
        }
    }

    @ViewBuilder private var historySections: some View {
        let sections = PhoneHubAgentDateGroup.sections(model.history, now: now, calendar: .current)
        let loadingFirstPage = !model.hasLoadedFirstPage && !pagingFailed
        let loadingMore = model.hasLoadedFirstPage && model.paging == .loading
        ForEach(sections) { section in
            Section {
                ForEach(section.rows) { row in conversationRow(row, inPinned: false) }
                if section.id == sections.last?.id && (loadingFirstPage || loadingMore) {
                    PhoneHubAgentSkeletonRow(titleWidth: 0.62, captionWidth: 0.34)
                    PhoneHubAgentSkeletonRow(titleWidth: 0.48, captionWidth: 0.26)
                }
            } header: {
                Text(section.group.title(now: now, calendar: .current))
                    .textCase(nil)
            }
            .headerProminence(.increased)
        }
        if sections.isEmpty && loadingFirstPage {
            Section {
                PhoneHubAgentSkeletonRow(titleWidth: 0.62, captionWidth: 0.34)
                PhoneHubAgentSkeletonRow(titleWidth: 0.5, captionWidth: 0.28)
                PhoneHubAgentSkeletonRow(titleWidth: 0.56, captionWidth: 0.22)
            }
        }
    }

    @ViewBuilder private var footer: some View {
        switch model.paging {
        case .failed(let message):
            Section {
                VStack(spacing: 8) {
                    Label("Couldn’t load \(model.hasLoadedFirstPage ? "older " : "")conversations", systemImage: "wifi.exclamationmark")
                        .font(.subheadline.weight(.semibold))
                        .accessibilityIdentifier("phoneHub.agent.loadFailed")
                    Text(message).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                    Button("Try Again") { model.retry() }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("phoneHub.agent.retry")
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .listRowBackground(Color.clear)
        case .complete:
            if !model.conversations.isEmpty {
                Section {
                    Text(endSummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("phoneHub.agent.end")
                }
                .listRowBackground(Color.clear)
            }
        case .idle, .loading:
            if model.hasLoadedFirstPage {
                Section {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Loading older conversations…")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    // Reaching the end before the prefetch landed asks now.
                    .onAppear { model.loadMore() }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("phoneHub.agent.loadingMore")
                }
                .listRowBackground(Color.clear)
            }
        }
    }

    private var pagingFailed: Bool {
        if case .failed = model.paging { return true }
        return false
    }

    /// iOS 26 shows the subtitle under the title; earlier systems get a line.
    private var showsInlineSubtitle: Bool {
        if #available(iOS 26.0, *) { return false }
        return !subtitle.isEmpty
    }

    private var endSummary: String {
        let count = model.conversations.count
        let noun = count == 1 ? "conversation" : "conversations"
        guard let oldest = model.conversations.compactMap(\.lastActivity).min() else { return "That’s all \(count) \(noun)." }
        return "That’s all \(count) \(noun), back to \(oldest.formatted(.dateTime.month(.wide).year()))."
    }

    @ViewBuilder private var searchResults: some View {
        let hits = model.searchResults
        let found = Set(hits.map(\.id))
        let local = model.conversations.filter { !found.contains($0.id) && $0.title.localizedCaseInsensitiveContains(query) }
        let rows = hits + local
        Section {
            ForEach(rows) { row in conversationRow(row, inPinned: false) }
            if rows.isEmpty {
                switch model.searchState {
                case .searching, .idle:
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Searching \(agentName)…")
                    }
                    .foregroundStyle(.secondary)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                case .done:
                    ContentUnavailableView.search(text: query)
                }
            }
        } header: {
            HStack(spacing: 6) {
                Text(rows.isEmpty ? "Results" : "\(rows.count) result\(rows.count == 1 ? "" : "s")")
                if model.searchState == .searching && !rows.isEmpty { ProgressView().controlSize(.mini) }
            }
            .textCase(nil)
            .accessibilityIdentifier("phoneHub.agent.searchResults")
        }
    }

    @ViewBuilder private var unavailable: some View {
        Section {
            ContentUnavailableView {
                Label(source == nil ? "Connection removed" : "Sign in to see conversations", systemImage: "lock")
            } description: {
                Text(source.map { "\($0.connection.name) needs you to sign in again." }
                     ?? "This agent’s connection is no longer saved.")
            } actions: {
                Button("Open Settings", action: onSettings)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("phoneHub.agent.signedOut")
            }
        }
        .listRowBackground(Color.clear)
    }

    // MARK: Rows

    private func conversationRow(_ row: PhoneHubAgentConversation, inPinned: Bool) -> some View {
        Button { open(row) } label: {
            PhoneHubAgentConversationRow(conversation: row, now: now, showsPin: !inPinned && row.pinned)
        }
        .tint(.primary)
        .accessibilityValue(PhoneHubAgentConversationRow.accessibilityState(row))
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if model.canEdit {
                Button {
                    withAnimation(.snappy) { model.setPinned(row.id, !row.pinned) }
                } label: {
                    Label(row.pinned ? "Unpin" : "Pin", systemImage: row.pinned ? "pin.slash.fill" : "pin.fill")
                }
                .tint(PhoneHubAgentConversationRow.pinTint)
                .accessibilityIdentifier("phoneHub.agent.pin.\(row.id)")
            }
            if row.unseen && row.seenRequest != nil {
                Button { withAnimation(.snappy) { model.markSeen(row.id) } } label: {
                    Label("Seen", systemImage: "eye.fill")
                }
                .tint(.blue)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if model.canEdit {
                Button { withAnimation(.snappy) { model.archive(row.id) } } label: {
                    Label("Archive", systemImage: "archivebox.fill")
                }
                .tint(.indigo)
                .accessibilityIdentifier("phoneHub.agent.archive.\(row.id)")
            }
        }
        .contextMenu { menu(for: row) }
        .onAppear { model.rowAppeared(row.id) }
        .accessibilityIdentifier("phoneHub.agent.session.\(row.id)")
    }

    @ViewBuilder private func menu(for row: PhoneHubAgentConversation) -> some View {
        Button { open(row) } label: { Label("Open", systemImage: "bubble.left.and.text.bubble.right") }
        if model.canEdit {
            Button { withAnimation(.snappy) { model.setPinned(row.id, !row.pinned) } } label: {
                Label(row.pinned ? "Unpin" : "Pin", systemImage: row.pinned ? "pin.slash" : "pin")
            }
            Button {
                renameText = row.title
                renaming = row
            } label: { Label("Rename…", systemImage: "pencil") }
        }
        if row.unseen && row.seenRequest != nil {
            Button { withAnimation(.snappy) { model.markSeen(row.id) } } label: { Label("Mark as Seen", systemImage: "eye") }
        }
        if let url = destination(for: row) {
            Button { NativeApp.copy(url) } label: { Label("Copy Link", systemImage: "link") }
        }
        if model.canEdit {
            Divider()
            Button { withAnimation(.snappy) { model.archive(row.id) } } label: { Label("Archive", systemImage: "archivebox") }
        }
    }

    @ViewBuilder private var noticeBanner: some View {
        if let notice = model.notice {
            HStack(spacing: 12) {
                Image(systemName: notice.undo == nil ? "exclamationmark.triangle.fill" : "archivebox.fill")
                    .foregroundStyle(notice.undo == nil ? Color.orange : Color.indigo)
                Text(notice.message)
                    .font(.subheadline)
                    .lineLimit(2)
                Spacer(minLength: 0)
                if let row = notice.undo {
                    Button("Undo") { withAnimation(.snappy) { model.undoArchive(row) } }
                        .buttonStyle(.plain)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityIdentifier("phoneHub.agent.undo")
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            .modifier(GlassCapsule())
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: notice.id) {
                try? await Task.sleep(for: .seconds(notice.undo == nil ? 3 : 5))
                model.dismissNotice(notice.id)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("phoneHub.agent.notice")
        }
    }

    // MARK: Navigation

    private func destination(for row: PhoneHubAgentConversation) -> URL? {
        guard let source else { return nil }
        let path = HubAggregateStore.resumePath(connection: source.connection, nodeID: route.nodeID, number: row.number, id: row.id)
        return aggregate.destination(path: path, sourceID: route.sourceID, nodeID: route.nodeID)
    }

    private func open(_ row: PhoneHubAgentConversation) {
        guard let url = destination(for: row) else {
            navigationError = "The source supplied an unsafe chat path. Navigation blocked."
            return
        }
        navigationError = nil
        onOpenChat(route.sourceID, url)
    }

    private func newConversation() {
        guard let node, let url = aggregate.destination(path: node.new_session_path, sourceID: route.sourceID, nodeID: route.nodeID) else {
            navigationError = "This agent didn’t supply a safe new-conversation route."
            return
        }
        navigationError = nil
        onOpenChat(route.sourceID, url)
    }
}

/// One conversation: attention dot, title, time; then what's happening or
/// where it lives.
struct PhoneHubAgentConversationRow: View {
    static let pinTint = Color(red: 1, green: 0.71, blue: 0)
    let conversation: PhoneHubAgentConversation
    let now: Date
    var showsPin = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var attention: Bool { conversation.needsInput || conversation.unseen }
    private var caption: String {
        if conversation.needsInput { return String(localized: "Needs your input") }
        if conversation.running { return String(localized: "Running…") }
        var parts: [String] = []
        if let project = conversation.projectName { parts.append(project) }
        if let count = conversation.messageCount, count > 0 {
            parts.append(count == 1 ? String(localized: "1 message") : String(localized: "\(count) messages"))
        }
        return parts.joined(separator: " · ")
    }
    private var captionColor: Color {
        conversation.needsInput ? .orange : (conversation.running ? .accentColor : .secondary)
    }
    /// The time's cap height, from its exact font: `@ScaledMetric` drifts
    /// from the real text size at accessibility sizes.
    private var timeCapHeight: CGFloat {
        #if os(iOS)
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
        return UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traits).capHeight
        #else
        // Mac text styles have fixed sizes.
        return NSFont.preferredFont(forTextStyle: .subheadline).capHeight
        #endif
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(conversation.needsInput ? Color.orange : Color.accentColor)
                .frame(width: 10, height: 10)
                .opacity(attention ? 1 : 0)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if showsPin {
                        Image(systemName: "pin.fill")
                            .font(.caption)
                            .foregroundStyle(Self.pinTint)
                    }
                    Text(conversation.title)
                        .font(.body.weight(attention ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    // Waiting on you is not work in progress.
                    if conversation.running && !conversation.needsInput {
                        let capHeight = timeCapHeight
                        ProgressView()
                            .controlSize(.mini)
                            // Its own baseline is its top edge, which hung it
                            // below the line; centre it on the time instead.
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + capHeight / 2 }
                    }
                    Text(PhoneHubAgentDateGroup.timeLabel(conversation.lastActivity, now: now, calendar: .current))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                if !caption.isEmpty {
                    Text(caption)
                        .font(.subheadline)
                        .foregroundStyle(captionColor)
                        .lineLimit(1)
                }
                if let snippet = conversation.snippet, !snippet.isEmpty {
                    Text(PhoneHubView.highlighted(snippet))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    static func accessibilityState(_ conversation: PhoneHubAgentConversation) -> String {
        [
            conversation.pinned ? "Pinned" : nil,
            conversation.needsInput ? "Needs input" : nil,
            conversation.unseen ? "Unseen" : nil,
            conversation.running ? "Running" : nil,
        ].compactMap { $0 }.joined(separator: ", ")
    }
}

/// Placeholder while the next page is on its way: the rows hold their place.
struct PhoneHubAgentSkeletonRow: View {
    let titleWidth: CGFloat
    let captionWidth: CGFloat
    @State private var dim = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Color.clear.frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 9) {
                GeometryReader { geometry in
                    HStack {
                        Capsule().frame(width: geometry.size.width * titleWidth, height: 12)
                        Spacer(minLength: 8)
                        Capsule().frame(width: 44, height: 12)
                    }
                }
                .frame(height: 14)
                GeometryReader { geometry in
                    Capsule().frame(width: geometry.size.width * captionWidth, height: 10)
                }
                .frame(height: 12)
            }
        }
        .foregroundStyle(Color.platformGray5)
        .padding(.vertical, 6)
        .opacity(dim ? 0.45 : 1)
        .animation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true), value: dim)
        .onAppear { dim = true }
        .accessibilityHidden(true)
    }
}

// MARK: - Modifiers

private struct AgentSubtitle: ViewModifier {
    let text: String
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), !text.isEmpty {
            content.navigationSubtitle(text)
        } else {
            content
        }
    }
}

private struct GlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        }
    }
}

/// Reports whether the list has scrolled further than `distance` from its top.
private struct ScrolledPast: ViewModifier {
    let distance: CGFloat
    let changed: (Bool) -> Void
    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            content.onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > distance
            } action: { _, past in
                changed(past)
            }
        } else {
            content
        }
    }
}

/// iOS 17 has no scroll geometry: fall back to the row leaving the list.
private struct LegacyVisibility: ViewModifier {
    let changed: (Bool) -> Void
    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            content
        } else {
            content
                .onAppear { changed(true) }
                .onDisappear { changed(false) }
        }
    }
}
