import Combine
import Foundation

/// The agent page's route on the Agents stack. Source-qualified, so two Hubs
/// may both expose a node called `dev`.
struct PhoneHubAgentRoute: Hashable {
    let sourceID: UUID
    let nodeID: String
}

/// One conversation as the agent page shows it: from the node's listing, the
/// dashboard's cached rows (first paint) or a search hit.
struct PhoneHubAgentConversation: Identifiable, Equatable, Sendable {
    let id: String
    var number: Int64?
    var title: String
    var projectName: String?
    var pinned: Bool
    var pinOrder: Int64?
    var lastActivity: Date?
    var messageCount: Int?
    var unseen: Bool
    var seenRequest: AttentionSeenRequest?
    var running = false
    var needsInput = false
    var snippet: String?

    init(id: String, number: Int64? = nil, title: String, projectName: String? = nil, pinned: Bool = false,
         pinOrder: Int64? = nil, lastActivity: Date? = nil, messageCount: Int? = nil, unseen: Bool = false,
         seenRequest: AttentionSeenRequest? = nil, running: Bool = false, needsInput: Bool = false, snippet: String? = nil) {
        self.id = id; self.number = number; self.title = title; self.projectName = projectName
        self.pinned = pinned; self.pinOrder = pinOrder; self.lastActivity = lastActivity
        self.messageCount = messageCount; self.unseen = unseen; self.seenRequest = seenRequest
        self.running = running; self.needsInput = needsInput; self.snippet = snippet
    }

    init(entry: AgentSessionEntry) {
        let pinned = entry.pinned == true
        let seen = entry.attentionStoreInstanceID.flatMap { store -> AttentionSeenRequest? in
            guard !store.isEmpty, let seq = entry.attentionSeq, seq > 0 else { return nil }
            return AttentionSeenRequest(storeInstanceID: store, sessionID: entry.id, attentionSeq: Int(seq))
        }
        self.init(id: entry.id, number: entry.number,
                  title: Self.title(entry.shortTitle, entry.name, entry.longTitle, number: entry.number),
                  projectName: entry.projectName.flatMap { $0.isEmpty ? nil : $0 },
                  pinned: pinned, pinOrder: pinned ? entry.pinOrder.flatMap { $0 > 0 ? $0 : nil } : nil,
                  lastActivity: Self.date(entry.lastMessageAt ?? entry.createdAt),
                  messageCount: entry.messageCount, unseen: entry.attentionUnseen == true, seenRequest: seen)
    }

    init(cached session: HubNodeSession) {
        self.init(id: session.id, number: session.number.map(Int64.init),
                  title: Self.title(session.shortTitle, nil, session.longTitle, number: session.number.map(Int64.init)),
                  pinned: session.pinned == true, lastActivity: Self.date(session.lastMessageAt.map(Int64.init)),
                  messageCount: session.messageCount, running: session.activeRun == true,
                  needsInput: session.interactionRequired == true)
    }

    init(hit: SessionSearchEntry) {
        self.init(id: hit.id, number: hit.number,
                  title: Self.title(hit.shortTitle, nil, hit.longTitle, number: hit.number),
                  pinned: hit.pinned == true, lastActivity: Self.date(hit.lastMessageAt),
                  messageCount: hit.messageCount, unseen: hit.attentionUnseen == true, snippet: hit.snippet)
    }

    private static func title(_ short: String?, _ name: String?, _ long: String?, number: Int64?) -> String {
        for candidate in [short, name, long] {
            if let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { return text }
        }
        return number.map { "Conversation \($0)" } ?? "Untitled conversation"
    }

    private static func date(_ milliseconds: Int64?) -> Date? {
        guard let milliseconds, milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
    }

    /// The node's listing order: pins first in their saved rank, then the
    /// most recent activity. Number and ID only break ties.
    static func precedes(_ a: Self, _ b: Self) -> Bool {
        if a.pinned != b.pinned { return a.pinned }
        if a.pinned {
            let ar = a.pinOrder ?? .max, br = b.pinOrder ?? .max
            if ar != br { return ar < br }
        }
        let at = a.lastActivity ?? .distantPast, bt = b.lastActivity ?? .distantPast
        if at != bt { return at > bt }
        let an = a.number ?? 0, bn = b.number ?? 0
        if an != bn { return an > bn }
        return a.id > b.id
    }
}

struct PhoneHubAgentDateSection: Identifiable, Equatable {
    let group: PhoneHubAgentDateGroup
    let rows: [PhoneHubAgentConversation]
    var id: String { group.key }
}

/// Mail/Notes-style date sections for the unpinned history.
enum PhoneHubAgentDateGroup: Hashable, Sendable {
    case today, yesterday, previousWeek, previousMonth, month(year: Int, month: Int), undated

    static func of(_ date: Date?, now: Date, calendar: Calendar) -> Self {
        guard let date else { return .undated }
        let today = calendar.startOfDay(for: now)
        if date >= today { return .today }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: today).day ?? 0
        if days <= 1 { return .yesterday }
        if days <= 7 { return .previousWeek }
        if days <= 30 { return .previousMonth }
        let parts = calendar.dateComponents([.year, .month], from: date)
        return .month(year: parts.year ?? 0, month: parts.month ?? 0)
    }

    func title(now: Date, calendar: Calendar) -> String {
        switch self {
        case .today: return String(localized: "Today")
        case .yesterday: return String(localized: "Yesterday")
        case .previousWeek: return String(localized: "Previous 7 Days")
        case .previousMonth: return String(localized: "Previous 30 Days")
        case .undated: return String(localized: "Earlier")
        case .month(let year, let month):
            var format = Date.FormatStyle.dateTime.month(.wide)
            format.calendar = calendar
            format.timeZone = calendar.timeZone
            let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? now
            return year == calendar.component(.year, from: now)
                ? first.formatted(format) : first.formatted(format.year())
        }
    }

    var key: String {
        switch self {
        case .today: "today"
        case .yesterday: "yesterday"
        case .previousWeek: "week"
        case .previousMonth: "month"
        case .undated: "undated"
        case .month(let year, let month): "\(year)-\(month)"
        }
    }

    /// Groups rows already in activity order; a group never appears twice.
    static func sections(_ rows: [PhoneHubAgentConversation], now: Date,
                         calendar: Calendar) -> [PhoneHubAgentDateSection] {
        var order: [Self] = []
        var grouped: [Self: [PhoneHubAgentConversation]] = [:]
        for row in rows {
            let group = of(row.lastActivity, now: now, calendar: calendar)
            if grouped[group] == nil { order.append(group) }
            grouped[group, default: []].append(row)
        }
        return order.map { PhoneHubAgentDateSection(group: $0, rows: grouped[$0] ?? []) }
    }

    /// Trailing row time: clock time today, then Yesterday, a weekday this
    /// week, a short date this year, and a full date before that.
    static func timeLabel(_ date: Date?, now: Date, calendar: Calendar) -> String {
        guard let date else { return "" }
        func style(_ base: Date.FormatStyle) -> Date.FormatStyle {
            var format = base
            format.calendar = calendar
            format.timeZone = calendar.timeZone
            return format
        }
        let today = calendar.startOfDay(for: now)
        if date >= today { return date.formatted(style(.dateTime.hour().minute())) }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: today).day ?? 0
        if days <= 1 { return String(localized: "Yesterday") }
        if days < 7 { return date.formatted(style(.dateTime.weekday(.wide))) }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(style(.dateTime.day().month(.abbreviated)))
        }
        return date.formatted(style(.dateTime.day().month(.abbreviated).year()))
    }
}

/// One agent's conversation history: instant first paint from the dashboard's
/// cached rows, then the node's listing 30 at a time. Edits are optimistic and
/// roll back when the node refuses them. Results from an older sign-in,
/// a removed source or a superseded load are discarded.
@MainActor
final class PhoneHubAgentSessions: ObservableObject {
    enum Paging: Equatable { case idle, loading, failed(String), complete }
    enum SearchState: Equatable { case idle, searching, done, failed(String) }

    struct Notice: Identifiable, Equatable {
        let id = UUID()
        let message: String
        /// Present for an archive the user can still undo.
        let undo: PhoneHubAgentConversation?
    }

    nonisolated static let pageSize = 30
    nonisolated static let prefetchDistance = 10
    nonisolated static let searchLimit = 30

    let sourceID: UUID
    let nodeID: String
    @Published private(set) var conversations: [PhoneHubAgentConversation] = []
    @Published private(set) var paging: Paging = .idle
    @Published private(set) var hasLoadedFirstPage = false
    @Published private(set) var signedOut = false
    @Published private(set) var notice: Notice?
    /// Bumped for every pin change the user makes; drives a haptic.
    @Published private(set) var pinFeedback = 0
    @Published private(set) var searchResults: [PhoneHubAgentConversation] = []
    @Published private(set) var searchState: SearchState = .idle

    private weak var source: HubSourceWorkspace?
    private let browser: (any HubSessionBrowsing)?
    private let searcher: (any HubSessionSearching)?
    /// Latest server truth, by ID; `conversations` adds pending edits on top.
    private var base: [String: PhoneHubAgentConversation] = [:]
    private var hits: [PhoneHubAgentConversation] = []
    private var overrides: [String: Override] = [:]
    private var runStates: [String: RunState] = [:]
    private var index: [String: Int] = [:]
    private var nextCursor: String?
    private var pagesLoaded = 0
    private var generation: UInt64 = 0
    private var epoch: UInt64
    private var loadTask: Task<Void, Never>?
    private var headTask: Task<Void, Never>?
    private var lastHeadLoad: Date?
    private var nodeSignature: [String] = []
    private var observation: AnyCancellable?

    private struct RunState: Equatable { var running: Bool; var needsInput: Bool }
    private struct PinState: Equatable { var pinned: Bool; var order: Int64? }
    private struct Override: Equatable {
        var pin: PinState?
        var title: String?
        var unseen: Bool?
        var archived: Bool?
        var isEmpty: Bool { pin == nil && title == nil && unseen == nil && archived == nil }
    }

    init(source: HubSourceWorkspace?, nodeID: String) {
        sourceID = source?.id ?? UUID()
        self.nodeID = nodeID
        self.source = source
        browser = source?.sessions
        searcher = source?.searcher
        epoch = source?.authEpoch ?? 0
        signedOut = source.map { !$0.isActive || $0.store.unauthorized } ?? true
        if let node = source?.store.nodes.first(where: { $0.id == nodeID }), !signedOut {
            // A Direct Node's dashboard can carry its whole status list; the
            // first paint only needs what the first page would show.
            let cached = HubNavigation.nodeSessions(node).map(PhoneHubAgentConversation.init(cached:))
                .sorted(by: PhoneHubAgentConversation.precedes).prefix(Self.pageSize)
            for row in cached { base[row.id] = row }
            runStates = Self.runStates(node)
            nodeSignature = Self.signature(node)
            publish()
        }
        // The source republishes every store change; check once it has landed.
        observation = source?.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.sourceChanged() }
    }

    deinit {
        loadTask?.cancel()
        headTask?.cancel()
    }

    /// Pins, renames and archive need the node's metadata API, which linked
    /// devices do not expose to this phone.
    var canEdit: Bool { browser != nil && source?.connection.isLinkedDevices == false }
    var pinned: [PhoneHubAgentConversation] { conversations.filter(\.pinned) }
    var history: [PhoneHubAgentConversation] { conversations.filter { !$0.pinned } }

    // MARK: Loading

    /// Loads the first page once; later appearances refresh the head quietly
    /// so a conversation read in Chat drops its unseen mark.
    func appeared() {
        guard !refreshSignInState() else { return }
        if !hasLoadedFirstPage {
            if loadTask == nil { load(cursor: nil, mode: .replace) }
        } else if lastHeadLoad.map({ Date().timeIntervalSince($0) > 3 }) ?? true {
            refreshHead()
        }
    }

    /// Pull to refresh: the first page replaces the window.
    func refresh() async {
        guard !refreshSignInState() else { return }
        load(cursor: nil, mode: .replace)
        await loadTask?.value
    }

    func retry() {
        if hasLoadedFirstPage {
            paging = .idle
            loadMore()
        } else {
            load(cursor: nil, mode: .replace)
        }
    }

    /// Infinite scroll: ask for the next page while `prefetchDistance` rows
    /// remain, so it usually lands before the user reaches the end.
    func rowAppeared(_ id: String) {
        guard let position = index[id], position >= conversations.count - Self.prefetchDistance else { return }
        loadMore()
    }

    func loadMore() {
        guard hasLoadedFirstPage, paging == .idle, loadTask == nil, let cursor = nextCursor else { return }
        load(cursor: cursor, mode: .append)
    }

    private enum LoadMode { case replace, append, head }

    private func load(cursor: String?, mode: LoadMode) {
        if mode != .head {
            loadTask?.cancel()
            headTask?.cancel()
            headTask = nil
            generation &+= 1
            paging = .loading
        }
        let gen = generation
        let task = Task { [weak self] in
            guard let self else { return }
            await self.fetch(cursor: cursor, mode: mode, generation: gen)
        }
        if mode == .head { headTask = task } else { loadTask = task }
    }

    private func fetch(cursor: String?, mode: LoadMode, generation gen: UInt64) async {
        defer {
            if gen == generation {
                if mode == .head { headTask = nil } else { loadTask = nil }
            }
        }
        guard let browser, let source, source.isActive, !source.store.unauthorized else {
            purge()
            return
        }
        let epoch = self.epoch
        do {
            let page = try await browser.listSessions(nodeID: nodeID, limit: Self.pageSize, cursor: cursor)
            guard gen == generation, !Task.isCancelled, current(source, epoch: epoch) else { return }
            apply(page, mode: mode)
        } catch {
            guard gen == generation, !(error is CancellationError), current(source, epoch: epoch) else { return }
            if mode == .head { return }
            paging = .failed(Self.message(error))
        }
    }

    private func apply(_ page: AgentSessionPage, mode: LoadMode) {
        let rows = page.sessions
            .filter { $0.archived != true && $0.parentSessionID == nil }
            .map(PhoneHubAgentConversation.init(entry:))
        let cursor = page.nextCursor.flatMap { $0.isEmpty ? nil : $0 }
        switch mode {
        case .replace:
            base = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            nextCursor = cursor
            pagesLoaded = 1
        case .append:
            for row in rows { base[row.id] = row }
            nextCursor = cursor
            pagesLoaded += 1
        case .head:
            // Keep everything older than this page's last row; anything inside
            // its window that the node no longer lists was archived or deleted.
            let fresh = Set(rows.map(\.id))
            if let boundary = rows.sorted(by: PhoneHubAgentConversation.precedes).last, cursor != nil {
                base = base.filter { !fresh.contains($0.key) && PhoneHubAgentConversation.precedes(boundary, $0.value) }
            } else {
                base = [:]
            }
            for row in rows { base[row.id] = row }
            if pagesLoaded <= 1 || cursor == nil { nextCursor = cursor }
            pagesLoaded = max(pagesLoaded, 1)
        }
        lastHeadLoad = mode == .append ? lastHeadLoad : Date()
        hasLoadedFirstPage = true
        paging = nextCursor == nil ? .complete : .idle
        publish()
    }

    private func refreshHead() {
        guard hasLoadedFirstPage, headTask == nil, loadTask == nil else { return }
        load(cursor: nil, mode: .head)
    }

    private func sourceChanged() {
        guard let source else { return }
        if !source.isActive || source.store.unauthorized {
            if !signedOut { purge() }
            return
        }
        if signedOut || source.authEpoch != epoch {
            refreshSignInState()
            return
        }
        nodeChanged(source.store.nodes.first { $0.id == nodeID })
    }

    /// Dashboard polling keeps run/input state live; a change in the node's
    /// recent window also means the head of the list moved.
    func nodeChanged(_ node: HubNode?) {
        guard let node else { return }
        let states = Self.runStates(node)
        if states != runStates {
            runStates = states
            publish()
        }
        let signature = Self.signature(node)
        guard signature != nodeSignature else { return }
        nodeSignature = signature
        refreshHead()
    }

    // MARK: Sign-in and removal

    /// Signed-out or removed sources must not keep showing private history.
    /// Returns true while the source is unavailable.
    @discardableResult
    func refreshSignInState() -> Bool {
        guard let source, source.isActive, !source.store.unauthorized else {
            purge()
            return true
        }
        if source.authEpoch != epoch {
            // A new sign-in is a new identity: start over.
            epoch = source.authEpoch
            purge()
            signedOut = false
            load(cursor: nil, mode: .replace)
            return false
        }
        if signedOut {
            signedOut = false
            load(cursor: nil, mode: .replace)
        }
        return false
    }

    private func purge() {
        loadTask?.cancel()
        headTask?.cancel()
        loadTask = nil
        headTask = nil
        generation &+= 1
        base = [:]
        hits = []
        overrides = [:]
        runStates = [:]
        nextCursor = nil
        pagesLoaded = 0
        hasLoadedFirstPage = false
        paging = .idle
        notice = nil
        searchResults = []
        searchState = .idle
        signedOut = true
        publish()
    }

    private func current(_ source: HubSourceWorkspace, epoch: UInt64) -> Bool {
        source.isActive && !source.store.unauthorized && source.authEpoch == epoch && self.epoch == epoch
    }

    // MARK: Search

    /// Full-text search of this agent's whole history (the node ranks it).
    func search(_ text: String) async {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            hits = []
            searchState = .idle
            publish()
            return
        }
        guard let searcher, let source, current(source, epoch: epoch) else { return }
        let epoch = self.epoch
        searchState = .searching
        do {
            let found = try await searcher.searchSessions(nodeID: nodeID, query: query,
                                                           limit: min(Self.searchLimit, SessionSearchQuery.maximumLimit))
            guard !Task.isCancelled, current(source, epoch: epoch) else { return }
            hits = found.sessions.map(PhoneHubAgentConversation.init(hit:))
            searchState = .done
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            hits = []
            switch (error as? HubAPIError)?.status {
            case 404, 501: searchState = .failed(String(localized: "This agent can’t search its history."))
            default: searchState = .failed(Self.message(error))
            }
        }
        publish()
    }

    func endSearch() {
        hits = []
        searchState = .idle
        publish()
    }

    // MARK: Edits

    func setPinned(_ id: String, _ pinned: Bool) {
        guard canEdit, let browser, let row = row(id), row.pinned != pinned else { return }
        let next = (conversations + searchResults).filter(\.pinned).compactMap(\.pinOrder).max().map { $0 + 1 } ?? 1
        edit(id) { $0.pin = PinState(pinned: pinned, order: pinned ? next : nil) }
        pinFeedback &+= 1
        let title = row.title, nodeID = self.nodeID
        mutate(id, clear: { $0.pin = nil }, failure: pinned ? "Couldn’t pin “\(title)”." : "Couldn’t unpin “\(title)”.") {
            try await browser.updateSession(nodeID: nodeID, sessionID: id, patch: AgentSessionPatch(pinned: pinned))
        } applied: { result, row in
            row.pinned = result.pinned ?? pinned
            row.pinOrder = row.pinned ? (result.pinOrder.flatMap { $0 > 0 ? $0 : nil } ?? next) : nil
        }
    }

    func rename(_ id: String, to name: String) {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canEdit, let browser, let row = row(id), !title.isEmpty, title != row.title else { return }
        edit(id) { $0.title = title }
        let nodeID = self.nodeID
        mutate(id, clear: { $0.title = nil }, failure: "Couldn’t rename “\(row.title)”.") {
            try await browser.updateSession(nodeID: nodeID, sessionID: id, patch: AgentSessionPatch(name: title))
        } applied: { result, row in
            let returned = result.shortTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            row.title = returned.isEmpty ? title : returned
        }
    }

    /// Hidden at once; the notice offers Undo until it times out.
    func archive(_ id: String) {
        guard canEdit, let browser, let row = row(id) else { return }
        edit(id) { $0.archived = true }
        notice = Notice(message: "Archived “\(row.title)”", undo: row)
        let nodeID = self.nodeID
        mutate(id, clear: { $0.archived = nil }, failure: "Couldn’t archive “\(row.title)”.") {
            try await browser.updateSession(nodeID: nodeID, sessionID: id, patch: AgentSessionPatch(archived: true))
        } applied: { _, _ in } removed: { [weak self] in
            self?.base[id] = nil
            self?.hits.removeAll { $0.id == id }
        }
    }

    func undoArchive(_ row: PhoneHubAgentConversation) {
        guard canEdit, let browser else { return }
        if notice?.undo?.id == row.id { notice = nil }
        let id = row.id, nodeID = self.nodeID
        if base[id] == nil { base[id] = row }
        edit(id) { $0.archived = false }
        mutate(id, clear: { $0.archived = nil }, failure: "Couldn’t restore “\(row.title)”.") {
            try await browser.updateSession(nodeID: nodeID, sessionID: id, patch: AgentSessionPatch(archived: false))
        } applied: { _, _ in }
    }

    /// Exact-item acknowledgement; the Attention badge refreshes with it.
    func markSeen(_ id: String) {
        guard let source, let row = row(id), row.unseen, let request = row.seenRequest else { return }
        edit(id) { $0.unseen = false }
        let store = source.store
        mutate(id, clear: { $0.unseen = nil }, failure: "Couldn’t mark “\(row.title)” as seen.") {
            try await store.markSessionSeen(request)
            return nil
        } applied: { _, row in row.unseen = false }
    }

    /// Drag-reordered pins take the ranks the moved pins already hold, which
    /// is exactly what the node commits.
    func movePins(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        guard canEdit, let browser else { return }
        let ids = Self.moved(pinned.map(\.id), fromOffsets: offsets, toOffset: destination)
        guard ids != pinned.map(\.id) else { return }
        let ranks = pinned.compactMap(\.pinOrder).sorted()
        for (position, id) in ids.enumerated() {
            let rank = ranks.count == ids.count ? ranks[position] : Int64(position + 1)
            edit(id) { $0.pin = PinState(pinned: true, order: rank) }
        }
        pinFeedback &+= 1
        let epoch = self.epoch, nodeID = self.nodeID
        Task { [weak self] in
            do {
                let order = try await browser.reorderPinnedSessions(nodeID: nodeID, sessionIDs: ids)
                guard let self, let source = self.source, self.current(source, epoch: epoch) else { return }
                for position in order.pinned where self.base[position.id] != nil {
                    self.base[position.id]?.pinned = true
                    self.base[position.id]?.pinOrder = position.pinOrder
                }
                self.clear(ids) { $0.pin = nil }
            } catch {
                guard let self, let source = self.source, self.current(source, epoch: epoch) else { return }
                self.clear(ids) { $0.pin = nil }
                self.notice = Notice(message: String(localized: "Couldn’t save the pinned order."), undo: nil)
            }
        }
    }

    func dismissNotice(_ id: UUID) {
        if notice?.id == id { notice = nil }
    }

    /// `List.onMove` semantics: `destination` indexes the list before removal.
    nonisolated static func moved<T>(_ items: [T], fromOffsets offsets: IndexSet, toOffset destination: Int) -> [T] {
        let valid = offsets.filter { items.indices.contains($0) }
        let moving = valid.map { items[$0] }
        var rest = items
        for offset in valid.sorted(by: >) { rest.remove(at: offset) }
        let target = min(max(0, destination - valid.filter { $0 < destination }.count), rest.count)
        rest.insert(contentsOf: moving, at: target)
        return rest
    }

    // MARK: Internals

    private func row(_ id: String) -> PhoneHubAgentConversation? {
        if let position = index[id], conversations.indices.contains(position) { return conversations[position] }
        return searchResults.first { $0.id == id }
    }

    private func edit(_ id: String, _ change: (inout Override) -> Void) {
        var value = overrides[id] ?? Override()
        change(&value)
        overrides[id] = value
        publish()
    }

    private func clear(_ ids: [String], _ change: (inout Override) -> Void) {
        for id in ids {
            guard var value = overrides[id] else { continue }
            change(&value)
            overrides[id] = value.isEmpty ? nil : value
        }
        publish()
    }

    /// Runs one edit. Success folds the node's answer into server truth and
    /// drops the pending override; failure just drops it, restoring the row.
    private func mutate(_ id: String, clear: @escaping (inout Override) -> Void, failure: String,
                        _ request: @escaping @MainActor () async throws -> AgentSessionPatchResult?,
                        applied: @escaping (AgentSessionPatchResult, inout PhoneHubAgentConversation) -> Void,
                        removed: (@MainActor () -> Void)? = nil) {
        let epoch = self.epoch
        Task { [weak self] in
            do {
                let result = try await request()
                guard let self, let source = self.source, self.current(source, epoch: epoch) else { return }
                if let removed {
                    removed()
                } else {
                    let answer = result ?? AgentSessionPatchResult(id: id, name: nil, shortTitle: nil, longTitle: nil,
                                                                   archived: nil, pinned: nil, pinOrder: nil)
                    if var row = self.base[id] {
                        applied(answer, &row)
                        self.base[id] = row
                    }
                    if let hit = self.hits.firstIndex(where: { $0.id == id }) {
                        applied(answer, &self.hits[hit])
                        // Pins always lead the listing, so a pinned search hit
                        // belongs in the loaded history even before paging.
                        if self.base[id] == nil, self.hits[hit].pinned { self.base[id] = self.hits[hit] }
                    }
                }
                self.clear([id], clear)
            } catch {
                guard let self, let source = self.source, self.current(source, epoch: epoch) else { return }
                self.clear([id], clear)
                if self.notice?.undo?.id == id { self.notice = nil }
                self.notice = Notice(message: failure + " " + String(localized: "Try again."), undo: nil)
            }
        }
    }

    private func decorate(_ row: PhoneHubAgentConversation) -> PhoneHubAgentConversation? {
        var row = row
        if let edit = overrides[row.id] {
            if edit.archived == true { return nil }
            if let pin = edit.pin {
                row.pinned = pin.pinned
                row.pinOrder = pin.order
            }
            if let title = edit.title { row.title = title }
            if let unseen = edit.unseen { row.unseen = unseen }
        }
        let state = runStates[row.id]
        row.running = state?.running ?? false
        row.needsInput = state?.needsInput ?? false
        return row
    }

    private func publish() {
        let rows = base.values.compactMap(decorate).sorted(by: PhoneHubAgentConversation.precedes)
        if rows != conversations {
            conversations = rows
            index = Dictionary(rows.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        }
        let found = hits.compactMap(decorate)
        if found != searchResults { searchResults = found }
    }

    private static func runStates(_ node: HubNode) -> [String: RunState] {
        var states: [String: RunState] = [:]
        for session in HubNavigation.nodeSessions(node) where session.activeRun == true || session.interactionRequired == true {
            states[session.id] = RunState(running: session.activeRun == true, needsInput: session.interactionRequired == true)
        }
        return states
    }

    private static func signature(_ node: HubNode) -> [String] {
        HubNavigation.nodeSessions(node).map { "\($0.id):\($0.lastMessageAt ?? 0):\($0.messageCount ?? 0):\($0.pinned == true)" }
            + [node.sessions?.countLabel ?? ""]
    }

    private static func message(_ error: Error) -> String {
        if let error = error as? HubAPIError, !error.message.isEmpty { return error.message }
        return error.localizedDescription
    }
}
