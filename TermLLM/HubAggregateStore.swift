import Combine
import Foundation
import WebKit

struct PhoneHubIdentity: Hashable, Sendable {
    let sourceID: UUID
    let nodeID: String
    let sessionID: String
    let key: String
}
struct PhoneHubNode: Identifiable {
    let source: HubConnection
    let node: HubNode
    var id: PhoneHubIdentity { PhoneHubIdentity(sourceID: source.id, nodeID: node.id, sessionID: "", key: "node") }
}
struct PhoneHubSession: Identifiable {
    let source: HubConnection
    let node: HubNode
    let session: HubNodeSession
    /// Search-only: matched message excerpt with `**` around matched terms.
    var snippet: String? = nil
    /// Search-only: the node reported unseen attention for this session.
    var unseen: Bool = false
    var id: PhoneHubIdentity { PhoneHubIdentity(sourceID: source.id, nodeID: node.id, sessionID: session.id, key: "session") }
    var displayTitle: String {
        session.short_title.isEmpty ? "Session \(session.number.map(String.init) ?? session.id)" : session.short_title
    }
}

struct PhoneHubSessionKey: Hashable { let sourceID: UUID; let nodeID: String; let sessionID: String }
enum PhoneHubSessionAttention { case inputRequired, unseen }

enum PhoneHubSessionSort: String, CaseIterable, Identifiable {
    case relevance, recent, attention, title, agent
    var id: String { rawValue }
    var label: String {
        switch self {
        case .relevance: "Relevance"
        case .recent: "Recent activity"
        case .attention: "Needs attention first"
        case .title: "Title"
        case .agent: "Agent"
        }
    }
    static let browseOptions: [PhoneHubSessionSort] = [.recent, .attention, .title, .agent]
    static let searchOptions: [PhoneHubSessionSort] = [.relevance, .recent, .attention, .title]

    /// Stable: relevance/agent keep the input order (agent order, then the
    /// node's own ranking). Other sorts break ties by recency, then input order.
    func sorted(_ rows: [PhoneHubSession], flag: (PhoneHubSession) -> PhoneHubSessionAttention?) -> [PhoneHubSession] {
        guard self != .relevance, self != .agent else { return rows }
        func priority(_ row: PhoneHubSession) -> Int {
            switch flag(row) {
            case .inputRequired: 0
            case .unseen: 1
            case nil: row.session.active_run == true ? 2 : 3
            }
        }
        let indexed = rows.enumerated().map { (offset: $0.offset, row: $0.element, priority: self == .attention ? priority($0.element) : 0) }
        return indexed.sorted { a, b in
            if self == .attention, a.priority != b.priority { return a.priority < b.priority }
            if self == .title {
                let order = a.row.displayTitle.localizedStandardCompare(b.row.displayTitle)
                if order != .orderedSame { return order == .orderedAscending }
            }
            let at = a.row.session.last_message_at ?? Int.min, bt = b.row.session.last_message_at ?? Int.min
            if at != bt { return at > bt }
            return a.offset < b.offset
        }.map(\.row)
    }
}

/// One fan-out leg: a single agent on a single source.
struct PhoneHubSearchAgent: Identifiable {
    enum State: Equatable { case searching, done(Int), failed(String) }
    let source: HubConnection
    let node: HubNode
    var state: State
    var id: PhoneHubIdentity { PhoneHubIdentity(sourceID: source.id, nodeID: node.id, sessionID: "", key: "search") }
}
struct PhoneHubAttention: Identifiable {
    let source: HubConnection
    let nodeID: String
    let sessionID: String
    let itemKey: String
    let title: String
    let path: String
    let inputRequired: Bool
    let seenRequest: AttentionSeenRequest?
    var id: PhoneHubIdentity {
        PhoneHubIdentity(sourceID: source.id, nodeID: nodeID, sessionID: sessionID, key: itemKey)
    }
}

@MainActor private final class SourceRevocationRelay {
    weak var owner: HubSourceWorkspace?
    func revoke() { owner?.revokeAuthorization() }
}

/// One native store, transport, protected WebKit jar and auth epoch per saved
/// source. The existing HubStore still owns all polling/panel sequencing.
@MainActor
final class HubSourceWorkspace: ObservableObject, Identifiable {
    private(set) var connection: HubConnection
    nonisolated let id: UUID
    let store: HubStore
    let hubWorkspace: HubWorkspace?
    let directClient: DirectNodeClient?
    let security: HubConnectionSecurity?
    let searcher: (any HubSessionSearching)?
    @Published private(set) var browserRevoked = false
    @Published private(set) var browserIdentity = UUID()
    @Published private(set) var browserReady = false
    @Published var authenticationError: String?
    private var observation: AnyCancellable?
    private var authObservation: AnyCancellable?
    private var active = true
    private var authenticationEpoch: UInt64 = 0
    private var resetTask: Task<Void, Never>?
    private let relay: SourceRevocationRelay?

    init(connection: HubConnection, bearerStorage: any HubBearerStorage = HubKeychainBearerStorage(), dataStore: WKWebsiteDataStore? = nil, transport: (any HubTransport)? = nil) {
        self.connection = connection
        self.id = connection.id
        let security = HubConnectionSecurity(connection: connection, bearerStorage: bearerStorage, dataStore: dataStore)
        self.security = security
        let relay = SourceRevocationRelay()
        self.relay = relay
        if connection.kind == .hub {
            let client = HubClient(base_url: connection.url, cookie_source: { await security.cookies() }, cookie_sink: { _ in }, transport: transport)
            let workspace = HubWorkspace(client: client, requiresAuthentication: false, onAuthorizationRevoked: { relay.revoke() })
            hubWorkspace = workspace
            store = workspace.store
            directClient = nil
            searcher = client
        } else {
            let client = DirectNodeClient(base_url: connection.url, cookie_source: { await security.cookies() }, bearer_source: { await security.bearer }, transport: transport)
            directClient = client
            hubWorkspace = nil
            store = HubStore(client: client)
            searcher = client
        }
        relay.owner = self
        installAuthorizationContext()
        HubCookieScopeRegistry.shared.register(security, kind: connection.kind)
        observation = store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        authObservation = store.$unauthorized.dropFirst().sink { [weak self] unauthorized in
            guard unauthorized, let self else { return }
            let epoch = self.authenticationEpoch
            Task { @MainActor [weak self] in
                guard let self, self.authenticationEpoch == epoch else { return }
                self.revokeAuthorization()
            }
        }
    }

    /// Inject existing HubServing mocks without network, WK or Keychain effects.
    init(connection: HubConnection, store: HubStore, searcher: (any HubSessionSearching)? = nil) {
        self.connection = connection
        self.id = connection.id
        self.store = store
        self.searcher = searcher
        hubWorkspace = nil
        directClient = nil
        security = nil
        relay = nil
        observation = store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        authObservation = store.$unauthorized.dropFirst().sink { [weak self] unauthorized in
            guard unauthorized, let self else { return }
            let epoch = self.authenticationEpoch
            Task { @MainActor [weak self] in
                guard let self, self.authenticationEpoch == epoch else { return }
                self.revokeAuthorization()
            }
        }
    }

    func updateMetadata(_ connection: HubConnection) {
        guard active, self.connection.id == connection.id, self.connection.url == connection.url,
              self.connection.kind == connection.kind, self.connection != connection else { return }
        objectWillChange.send()
        self.connection = connection
    }
    var isActive: Bool { active }
    var authEpoch: UInt64 { authenticationEpoch }
    var error: String? { authenticationError ?? store.nodeError ?? store.attentionError }
    func start() {
        guard active else { return }
        store.start()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.prepareBrowserAuthentication()
            guard self.active, !self.browserRevoked else { return }
            self.browserReady = true
        }
    }

    private func installAuthorizationContext() {
        let expected = authenticationEpoch
        if let client = hubWorkspace?.client, let security {
            hubWorkspace?.authenticationSucceeded()
            let securityEpoch = security.epoch
            client.scoped_cookie_importer = { [weak self] cookies, isCurrent in
                guard let self else { throw CancellationError() }
                try await self.saveTransportCookies(cookies, epoch: expected, securityEpoch: securityEpoch, isCurrent: isCurrent)
            }
        }
        let mobileSharingSource = connection.isMobileSharing
        let sourceID = id
        directClient?.on_unauthorized = { [weak self] in
            if mobileSharingSource {
                await MainActor.run { MobileSharingRuntime.shared.markRevoked(sourceID) }
            }
            await self?.revokeAuthorization(expected: expected)
        }
    }

    /// Mobile Sharing restoration is two-phase: finish any authorization purge
    /// first, then let the runtime reinstall its current bridge capability,
    /// then expose the browser/native workspace again.
    func prepareMobileSharingAuthorizationRestore() async -> UInt64? {
        guard active, connection.isMobileSharing else { return nil }
        await resetTask?.value
        guard active else { return nil }
        authenticationEpoch &+= 1
        security?.nextEpoch()
        security?.authorizeCookieReads()
        installAuthorizationContext()
        return authenticationEpoch
    }

    @discardableResult
    func completeMobileSharingAuthorizationRestore(epoch: UInt64) async -> Bool {
        guard active, connection.isMobileSharing, authenticationEpoch == epoch else { return false }
        browserRevoked = false
        browserReady = true
        browserIdentity = UUID()
        authenticationError = nil
        await store.resumeAfterAuthentication()
        return active && authenticationEpoch == epoch && !store.unauthorized
    }

    func revokeAuthorization(expected: UInt64? = nil) {
        guard expected == nil || expected == authenticationEpoch else { return }
        guard active, !browserRevoked else { return }
        authenticationEpoch &+= 1
        store.purgeOnUnauthorized()
        browserRevoked = true
        browserReady = false
        browserIdentity = UUID()
        guard let security else { return }
        security.nextEpoch()
        installAuthorizationContext()
        let expected = security.epoch
        resetTask = Task { @MainActor in
            guard security.active, security.epoch == expected else { return }
            try? security.setBearer(nil)
            await security.clearData(epoch: expected)
        }
    }

    private func saveTransportCookies(_ cookies: [HTTPCookie], epoch expected: UInt64, securityEpoch: UInt64,
                                      isCurrent: @escaping @Sendable () -> Bool) async throws {
        guard active, expected == authenticationEpoch, isCurrent() else { throw CancellationError() }
        await resetTask?.value
        guard active, expected == authenticationEpoch, let security, isCurrent() else { throw CancellationError() }
        guard await security.saveCookies(cookies, epoch: securityEpoch, isCurrent: isCurrent),
              active, expected == authenticationEpoch, isCurrent() else { throw CancellationError() }
    }

    /// Capture before presenting system sign-in. A removed/edited identity or
    /// an intervening revoke invalidates the handoff, not a different source.
    func nativeCookieSink(epoch: UInt64) -> @MainActor ([HTTPCookie]) async throws -> Void {
        let securityEpoch = security?.epoch
        return { [weak self] cookies in
            guard let self, self.active, self.authenticationEpoch == epoch, let security = self.security else { throw CancellationError() }
            await self.resetTask?.value
            guard self.active, self.authenticationEpoch == epoch else { throw CancellationError() }
            let expectedName = self.connection.kind == .hub ? "term_llm_hub_session" : "term_llm_web_session"
            guard !cookies.isEmpty, cookies.allSatisfy({
                $0.name == expectedName && $0.domain.lowercased() == self.connection.url.host?.lowercased() &&
                    $0.path == self.connection.mountPath &&
                    ($0.isSecure || (self.connection.url.scheme == "http" && ServerAddress.allowsLocalHTTP(host: self.connection.url.host ?? ""))) &&
                    ($0.expiresDate.map { $0 > Date() } ?? true)
            }) else { throw CancellationError() }
            guard let securityEpoch else { throw CancellationError() }
            if self.connection.kind == .directNode {
                try security.setBearer(nil)
                guard await security.clearData(epoch: securityEpoch) else { throw CancellationError() }
            }
            guard self.active, self.authenticationEpoch == epoch,
                  await security.saveCookies(cookies, epoch: securityEpoch),
                  self.active, self.authenticationEpoch == epoch else { throw CancellationError() }
        }
    }

    func prepareAuthentication() async -> UInt64? {
        guard active else { return nil }
        await resetTask?.value
        guard active else { return nil }
        authenticationEpoch &+= 1
        // An explicit identity change closes the old protected document and
        // native cache immediately, even if the new login is later cancelled.
        browserRevoked = true
        browserReady = false
        browserIdentity = UUID()
        store.purgeOnUnauthorized()
        security?.nextEpoch()
        do { try security?.setBearer(nil) }
        catch { authenticationError = error.localizedDescription; return nil }
        installAuthorizationContext()
        let expected = authenticationEpoch
        await security?.waitForCookies()
        guard active, authenticationEpoch == expected else { return nil }
        if let security { guard await security.clearData(epoch: security.epoch) else { return nil } }
        guard active, authenticationEpoch == expected else { return nil }
        return expected
    }

    @discardableResult
    func authenticationSucceeded(epoch: UInt64) async -> Bool {
        guard active, epoch == authenticationEpoch else { return false }
        await security?.waitForCookies()
        guard active, epoch == authenticationEpoch else { return false }
        authenticationEpoch &+= 1
        security?.nextEpoch()
        security?.authorizeCookieReads()
        installAuthorizationContext()
        let current = authenticationEpoch
        browserRevoked = false
        browserReady = true
        browserIdentity = UUID()
        authenticationError = nil
        await store.resumeAfterAuthentication()
        return active && authenticationEpoch == current && !store.unauthorized
    }

    func signInWithBearer(_ token: String) async {
        guard let epoch = await prepareAuthentication(), let directClient, let security else { return }
        do {
            _ = try await directClient.validate_bearer(token: token)
            guard active, epoch == authenticationEpoch else { return }
            try security.setBearer(token)
            await prepareBrowserAuthentication()
            await authenticationSucceeded(epoch: epoch)
        } catch {
            guard active, epoch == authenticationEpoch else { return }
            authenticationError = error.localizedDescription
        }
    }

    func prepareBrowserAuthentication() async {
        guard active, connection.kind == .directNode, let security, let token = security.bearer else { return }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        if let cookie = HTTPCookie(properties: [.name: "term_llm_token", .value: token.addingPercentEncoding(withAllowedCharacters: allowed) ?? "",
                                               .domain: connection.url.host!, .path: connection.mountPath,
                                               .secure: connection.url.scheme == "https" ? "TRUE" : "FALSE"]) {
            await security.saveCookies([cookie], epoch: security.epoch)
        }
    }

    func dispose(removeCredentials: Bool) {
        guard active else { return }
        active = false
        authenticationEpoch &+= 1
        resetTask?.cancel()
        observation = nil
        authObservation = nil
        hubWorkspace?.client.scoped_cookie_importer = nil
        hubWorkspace?.dispose()
        directClient?.on_unauthorized = nil
        store.purgeOnUnauthorized()
        store.dispose()
        if let security { HubCookieScopeRegistry.shared.unregister(security) }
        security?.dispose(removeCredentials: removeCredentials)
        browserRevoked = true
        browserReady = false
        browserIdentity = UUID()
    }
}

/// Computed projections, not another polling framework. Each existing store
/// publishes immediately, without awaiting any sibling source or panel.
@MainActor
final class HubAggregateStore: ObservableObject {
    @Published private(set) var sources: [HubSourceWorkspace] = []
    private var observations: [UUID: AnyCancellable] = [:]
    private let makeSource: @MainActor (HubConnection) -> HubSourceWorkspace

    init(makeSource: @escaping @MainActor (HubConnection) -> HubSourceWorkspace = { connection in
        HubSourceWorkspace(connection: connection,
                           bearerStorage: PhoneHubFixture.isEnabled ? HubMemoryBearerStorage() : HubKeychainBearerStorage(),
                           transport: MobileSharingRuntime.shared.transport(for: connection))
    }) { self.makeSource = makeSource }

    static func shouldRemoveCredentialsWhenReplacing(_ old: HubConnection,
                                                     with replacement: HubConnection?) -> Bool {
        guard let replacement, old.id == replacement.id,
              old.isMobileSharing, replacement.isMobileSharing,
              old.mobileSharingHostKey == replacement.mobileSharingHostKey,
              old.url.scheme?.lowercased() == replacement.url.scheme?.lowercased(),
              old.url.host?.lowercased() == replacement.url.host?.lowercased(),
              old.url.port == replacement.url.port else { return true }
        // A re-pair may update only the signed mount while retaining the same
        // UUID-owned WebKit store and loopback origin. Clearing that store here
        // would race and erase the newly installed capability cookie.
        return false
    }

    func synchronize(_ connections: [HubConnection]) {
        let old = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        for source in sources where !connections.contains(where: { $0.id == source.id && $0.url == source.connection.url && $0.kind == source.connection.kind }) {
            let replacement = connections.first { $0.id == source.id }
            source.dispose(removeCredentials: Self.shouldRemoveCredentialsWhenReplacing(source.connection,
                                                                                         with: replacement))
            observations[source.id] = nil
        }
        let updated = connections.map { connection in
            if let source = old[connection.id], source.isActive {
                source.updateMetadata(connection)
                return source
            }
            let source = makeSource(connection)
            observations[connection.id] = source.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            source.start()
            return source
        }
        if sources.count != updated.count || zip(sources, updated).contains(where: { $0 !== $1 }) {
            sources = updated
        }
    }
    func source(_ id: UUID) -> HubSourceWorkspace? { sources.first { $0.id == id } }
    /// Pause every source's change-feed loop while backgrounded, resume on return.
    func setPollingSuspended(_ suspended: Bool) {
        for source in sources where source.isActive {
            if suspended { source.store.suspendPolling() } else { source.store.resumePolling() }
        }
    }
    func refresh() {
        // Fire independently. A slow/offline source never delays the home UI.
        for source in sources { Task { await source.store.refresh() } }
    }

    /// Keep pull-to-refresh visible until its requests finish. Each source still
    /// publishes results independently, so healthy results appear immediately.
    func refreshAndWait() async {
        let tasks = sources.map { source in Task { await source.store.refresh() } }
        for task in tasks { await task.value }
    }
    var nodes: [PhoneHubNode] {
        sources.flatMap { source in
            guard source.store.nodesVerified, !source.store.unauthorized else { return [PhoneHubNode]() }
            return source.store.nodes.map { PhoneHubNode(source: source.connection, node: $0) }
        }
    }
    /// Rebuilt only when a verified source's connection or node list changes.
    /// HubStore never republishes an equal node array, so the array equality
    /// check normally short-circuits on shared storage.
    var sessions: [PhoneHubSession] {
        let inputs = sources.compactMap { source -> SessionInputs? in
            guard source.store.nodesVerified, !source.store.unauthorized else { return nil }
            return SessionInputs(connection: source.connection, nodes: source.store.nodes)
        }
        if let cache = sessionCache, cache.inputs == inputs { return cache.rows }
        let rows = inputs.flatMap { input in
            input.nodes.flatMap { node in
                HubNavigation.nodeSessions(node).map { PhoneHubSession(source: input.connection, node: node, session: $0) }
            }
        }
        sessionGeneration &+= 1
        sessionCache = (inputs, rows)
        return rows
    }

    private struct SessionInputs: Equatable {
        let connection: HubConnection
        let nodes: [HubNode]
    }
    private var sessionCache: (inputs: [SessionInputs], rows: [PhoneHubSession])?
    private var sessionGeneration: UInt64 = 0

    private struct SortMemo {
        let sort: PhoneHubSessionSort
        let input: UInt64
        let flags: [PhoneHubSessionKey: PhoneHubSessionAttention]?
        let rows: [PhoneHubSession]
    }
    private var browseSortMemo: SortMemo?
    private var searchSortMemo: SortMemo?

    /// `sessions` sorted, reused until the rows, sort or (for the attention
    /// sort only) the attention flags change. `flag` must depend only on the
    /// row and `flags`.
    func sortedSessions(_ sort: PhoneHubSessionSort, flags: [PhoneHubSessionKey: PhoneHubSessionAttention],
                        flag: (PhoneHubSession) -> PhoneHubSessionAttention?) -> [PhoneHubSession] {
        let rows = sessions
        return memoizedSort(&browseSortMemo, rows: rows, input: sessionGeneration, sort: sort, flags: flags, flag: flag)
    }

    /// `searchResults` sorted, with the same reuse rules as `sortedSessions`.
    func sortedSearchResults(_ sort: PhoneHubSessionSort, flags: [PhoneHubSessionKey: PhoneHubSessionAttention],
                             flag: (PhoneHubSession) -> PhoneHubSessionAttention?) -> [PhoneHubSession] {
        let rows = searchResults
        return memoizedSort(&searchSortMemo, rows: rows, input: searchResultsGeneration, sort: sort, flags: flags, flag: flag)
    }

    private func memoizedSort(_ memo: inout SortMemo?, rows: [PhoneHubSession], input: UInt64, sort: PhoneHubSessionSort,
                              flags: [PhoneHubSessionKey: PhoneHubSessionAttention],
                              flag: (PhoneHubSession) -> PhoneHubSessionAttention?) -> [PhoneHubSession] {
        // Only the attention sort reads flags; other sorts ignore them.
        let keyFlags = sort == .attention ? flags : nil
        if let memo, memo.sort == sort, memo.input == input, memo.flags == keyFlags { return memo.rows }
        let sorted = sort.sorted(rows, flag: flag)
        memo = SortMemo(sort: sort, input: input, flags: keyFlags, rows: sorted)
        return sorted
    }
    /// Needs-input plus unseen totals from verified sources, not the loaded
    /// attention window (which may be paginated). Ordinary refreshes retain the
    /// last verified totals. nil means no source has reported a result yet.
    var attentionBadgeCount: Int? {
        guard !sources.isEmpty else { return 0 }
        var hasResult = false
        var count = 0
        for source in sources {
            if source.store.unauthorized {
                hasResult = true
                continue
            }
            guard source.store.attentionVerified else { continue }
            hasResult = true
            for value in [source.store.totalInputRequired, source.store.totalUnseen] {
                let (sum, overflow) = count.addingReportingOverflow(max(0, value))
                count = overflow ? Int.max : sum
            }
        }
        return hasResult ? count : nil
    }

    var attention: [PhoneHubAttention] {
        sources.flatMap { source in
            guard source.store.attentionVerified, !source.store.unauthorized else { return [PhoneHubAttention]() }
            let connection = source.connection
            let required = source.store.inputRequired.map { item in
                PhoneHubAttention(source: connection, nodeID: item.node_id, sessionID: item.session_id,
                                  itemKey: "input", title: item.title, path: item.resume_path, inputRequired: true, seenRequest: nil)
            }
            let unseen = source.store.inbox.map { item in
                PhoneHubAttention(source: connection, nodeID: item.node_id, sessionID: item.session_id,
                                  itemKey: "unseen.\(item.store_instance_id ?? "").\(item.attention_seq)", title: item.title,
                                  path: item.resume_path, inputRequired: false,
                                  seenRequest: item.store_instance_id.map { AttentionSeenRequest(store_instance_id: $0, session_id: item.session_id, attention_seq: item.attention_seq) })
            }
            return required + unseen
        }
    }

    // MARK: Session search

    static let searchLimitPerAgent = 20
    /// What the user typed; filters loaded sessions locally, never the network.
    @Published private(set) var searchQuery = ""
    /// The query the agents were last asked about; nil until the user asks.
    @Published private(set) var agentSearchQuery: String?
    /// One leg per reachable agent, in source then node order.
    @Published private(set) var searchAgents: [PhoneHubSearchAgent] = []
    @Published private var searchHitsByLeg: [Int: [PhoneHubSession]] = [:] {
        didSet { searchHitsGeneration &+= 1 }
    }
    private var searchTask: Task<Void, Never>?
    private var searchGeneration: UInt64 = 0

    private struct SearchLeg {
        let source: HubSourceWorkspace
        let node: HubNode
        let searcher: any HubSessionSearching
        let epoch: UInt64
    }

    /// Typing only changes the local filter. Results from an earlier agent
    /// search no longer answer a changed query, so they are discarded.
    func updateSearchQuery(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query != searchQuery else { return }
        searchQuery = query
        guard agentSearchQuery != nil, agentSearchQuery != query else { return }
        cancelAgentSearch()
    }

    private func cancelAgentSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchGeneration &+= 1
        agentSearchQuery = nil
        searchAgents = []
        searchHitsByLeg = [:]
    }

    private var searchLegs: [SearchLeg] {
        sources.flatMap { source -> [SearchLeg] in
            guard source.isActive, !source.store.unauthorized, source.store.nodesVerified,
                  let searcher = source.searcher else { return [] }
            return source.store.nodes
                .filter { $0.status.reachable && (source.connection.kind == .directNode || SessionSearchQuery.isSafeNodeID($0.id)) }
                .map { SearchLeg(source: source, node: $0, searcher: searcher, epoch: source.authEpoch) }
        }
    }

    /// Agents an explicit search would ask right now.
    var searchableAgentCount: Int { searchLegs.count }

    /// Explicit fan-out: each reachable agent searches its full history, then
    /// reports run/input state for just its matches. A slow, failing or
    /// signed-out agent only affects its own leg; a newer query, auth change
    /// or removed source discards late answers.
    func searchAllAgents() {
        let query = searchQuery
        cancelAgentSearch()
        guard !query.isEmpty else { return }
        let generation = searchGeneration
        agentSearchQuery = query
        let legs = searchLegs
        searchAgents = legs.map { PhoneHubSearchAgent(source: $0.source.connection, node: $0.node, state: .searching) }
        guard !legs.isEmpty else { return }
        let limit = Self.searchLimitPerAgent
        let requests = legs.map { (searcher: $0.searcher, nodeID: $0.node.id) }
        typealias Answer = (search: SessionSearchResponse, status: DirectNodeSessionsStatus?)
        searchTask = Task { @MainActor [weak self] in
            await withTaskGroup(of: (Int, Result<Answer, any Error>).self) { group in
                for (index, request) in requests.enumerated() {
                    group.addTask {
                        do {
                            let found = try await request.searcher.search_sessions(node_id: request.nodeID, query: query, limit: limit)
                            guard !found.sessions.isEmpty else { return (index, .success((found, nil))) }
                            // State is best effort: matches still help without it.
                            let status = try? await request.searcher.sessions_status(node_id: request.nodeID, ids: found.sessions.map(\.id))
                            return (index, .success((found, status)))
                        } catch {
                            return (index, .failure(error))
                        }
                    }
                }
                for await (index, result) in group {
                    guard let self, self.searchGeneration == generation, !Task.isCancelled else {
                        group.cancelAll()
                        return
                    }
                    self.applySearch(result, leg: legs[index], index: index)
                }
            }
        }
    }

    /// Pull-to-refresh repeats an agent search the user already asked for.
    func rerunSearch() {
        guard agentSearchQuery != nil else { return }
        searchAllAgents()
    }

    private func applySearch(_ result: Result<(search: SessionSearchResponse, status: DirectNodeSessionsStatus?), any Error>,
                             leg: SearchLeg, index: Int) {
        guard searchAgents.indices.contains(index) else { return }
        let source = leg.source
        guard source.isActive, source.authEpoch == leg.epoch, !source.store.unauthorized else {
            searchAgents[index].state = .failed("Sign-in changed")
            return
        }
        switch result {
        case .success(let answer):
            let connection = source.connection
            var states: [String: DirectNodeSessionEntry] = [:]
            for entry in answer.status?.sessions ?? [] { states[entry.id] = entry }
            let hits = answer.search.sessions.map { entry in
                let state = states[entry.id]
                return PhoneHubSession(source: connection, node: leg.node,
                                session: HubNodeSession(
                                    id: entry.id, number: entry.number.map(Int.init),
                                    short_title: entry.short_title ?? entry.long_title ?? "",
                                    long_title: entry.long_title, pinned: entry.pinned,
                                    active_run: state?.active_run, interaction_required: state?.interaction_required,
                                    pending_interaction_count: state?.pending_interaction_count,
                                    pending_interaction_kinds: state?.pending_interaction_kinds,
                                    last_message_at: entry.last_message_at.map(Int.init),
                                    message_count: entry.message_count,
                                    resume_path: Self.searchResumePath(connection: connection, nodeID: leg.node.id, entry: entry)),
                                snippet: entry.snippet, unseen: (state?.attention_unseen ?? entry.attention_unseen) == true)
            }
            searchHitsByLeg[index] = hits
            searchAgents[index].state = .done(hits.count)
        case .failure(let error):
            if error is CancellationError { return }
            let message: String
            switch (error as? HubAPIError)?.status {
            case 401, 403: message = "Not authorized"
            case 404, 501: message = "Search not supported"
            default: message = "Couldn’t search"
            }
            searchAgents[index].state = .failed(message)
        }
    }

    /// Mirrors the server's canonical `/chat/<selector>` route; destinations
    /// are still validated by `HubNavigation.chatDestination` before opening.
    static func searchResumePath(connection: HubConnection, nodeID: String, entry: SessionSearchEntry) -> String {
        let selector = (entry.number ?? 0) > 0 ? String(entry.number!) : entry.id
        let root = connection.kind == .hub ? connection.mountPath + "node/" + nodeID + "/" : connection.mountPath
        return root + "chat/" + selector
    }

    /// Loaded sessions whose titles match, plus agent matches (message text)
    /// once the user has asked the agents. Agent matches come first, in agent
    /// then node-rank order, and carry the snippet for duplicates.
    var searchResults: [PhoneHubSession] {
        let live = Set(sources.filter { $0.isActive && !$0.store.unauthorized }.map(\.id))
        let loaded = sessions
        let key = SearchResultsKey(query: searchQuery, hits: searchHitsGeneration, live: live, sessions: sessionGeneration)
        if let cache = searchResultsCache, cache.key == key { return cache.rows }
        let rows = buildSearchResults(live: live, loaded: loaded)
        searchResultsGeneration &+= 1
        searchResultsCache = (key, rows)
        return rows
    }

    private struct SearchResultsKey: Equatable {
        let query: String
        let hits: UInt64
        let live: Set<UUID>
        let sessions: UInt64
    }
    private var searchResultsCache: (key: SearchResultsKey, rows: [PhoneHubSession])?
    private var searchResultsGeneration: UInt64 = 0
    private var searchHitsGeneration: UInt64 = 0

    private func buildSearchResults(live: Set<UUID>, loaded: [PhoneHubSession]) -> [PhoneHubSession] {
        guard !searchQuery.isEmpty else { return [] }
        var seen = Set<PhoneHubIdentity>()
        var out = searchHitsByLeg.keys.sorted().flatMap { searchHitsByLeg[$0] ?? [] }
            .filter { live.contains($0.source.id) && seen.insert($0.id).inserted }
        for row in loaded where row.displayTitle.localizedCaseInsensitiveContains(searchQuery)
            || (row.session.long_title?.localizedCaseInsensitiveContains(searchQuery) ?? false) {
            if seen.insert(row.id).inserted { out.append(row) }
        }
        return out
    }

    func destination(path: String, sourceID: UUID, nodeID: String) -> URL? {
        guard let source = source(sourceID), !source.store.unauthorized, source.isActive else { return nil }
        return HubNavigation.chatDestination(path, server: source.connection.url, nodeID: nodeID, direct: source.connection.kind == .directNode)
    }
}
