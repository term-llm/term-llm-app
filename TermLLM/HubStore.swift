import Combine
import Foundation

// MARK: - HubAuthMode

/// How the Hub authenticates this session. UI skips passkey routes when the
/// mode is `.none` or `.bearer`.
enum HubAuthMode: String, Sendable, Equatable {
    case none
    case bearer
    case passkey
}

// MARK: - HubStore

/// Central state for the native Hub dashboard.
///
/// **Architecture**
///
/// - Three *independent* panel tasks (nodes, attention, delegations) run
///   concurrently. One stalling panel never blocks the others.
/// - An **epoch** counter guards auth purge and disposal. It is bumped *only*
///   on auth purge or dispose — never on routine polls or manual refreshes.
///   Late responses from a previous epoch are silently dropped.
/// - Per-panel **sequence counters** prevent stale overwrites when a refresh
///   cancels an in-flight task and launches a replacement. The old task's
///   response and completion are discarded if its captured seq is outdated.
/// - Polls coalesce: if panel tasks are already running, the poll cycle skips.
///   Manual refresh cancels and replaces each panel task.
/// - Mutations use `defer` for busy-flag cleanup so flags never get stuck,
///   regardless of epoch changes or cancellation mid-flight.
///
/// **Fail-closed**: on any 401/403 (delivered at header-time via
/// `purgeOnUnauthorized()`) the store purges every piece of private data,
/// bumps the epoch, and cancels all tasks.
@MainActor
final class HubStore: ObservableObject {

    // MARK: - Node state

    @Published private(set) var nodes: [HubNode] = []
    @Published private(set) var nodesLoading = false
    @Published private(set) var nodesVerified = false
    @Published private(set) var nodeError: String?
    @Published private(set) var resolverWarning: String?
    @Published private(set) var lastNodesRefresh: Date?

    // MARK: - Attention state

    @Published private(set) var attentionNodes: [HubAttentionNode] = []
    @Published private(set) var inputRequired: [HubInputRequiredItem] = []
    @Published private(set) var inbox: [HubAttentionInboxItem] = []
    @Published private(set) var attentionHasMore = false
    @Published private(set) var totalInputRequired = 0
    @Published private(set) var totalUnseen = 0
    @Published private(set) var attentionLoading = false
    @Published private(set) var attentionVerified = false
    @Published private(set) var attentionError: String?
    @Published private(set) var lastAttentionRefresh: Date?
    @Published private(set) var attentionLimit = HubStore.defaultAttentionLimit

    // MARK: - Clear / Seen

    @Published private(set) var clearingAttention = false
    @Published private(set) var attentionClearStatus: String?
    @Published private(set) var markingSeen: Set<String> = []

    // MARK: - Delegations state

    @Published private(set) var delegations: [HubDelegation] = []
    @Published private(set) var delegationsLoading = false
    @Published private(set) var delegationsVerified = false
    @Published private(set) var delegationError: String?
    @Published private(set) var lastDelegationsRefresh: Date?

    // MARK: - Node operations

    @Published private(set) var nodeOperation: NodeOperation = .idle
    @Published private(set) var nodeOperationResult: String?

    // MARK: - Registration

    @Published private(set) var registrationLoading = false
    @Published private(set) var registrationInfo: RegistrationInfoResponse?
    @Published private(set) var registrationError: String?

    // MARK: - Security / session

    @Published private(set) var credentials: [HubCredential] = []
    @Published private(set) var activeSessions = 0
    @Published private(set) var securityLoading = false
    @Published private(set) var securityOperation: String?
    @Published private(set) var securityStatus: String?
    /// Server requires recent authentication for credential removal. Native
    /// transport cannot perform WebAuthn; UI should present browser fallback.
    /// The 403 is delivered at header-time, triggering a full auth purge.
    /// UI should disable credential deletion proactively when passkey reauth
    /// is unavailable, rather than attempt a doomed operation.
    @Published private(set) var recentAuthRequired = false

    // MARK: - Overall

    @Published private(set) var initialLoading = true
    @Published private(set) var refreshing = false
    @Published private(set) var unauthorized = false
    @Published private(set) var authMode: HubAuthMode

    // MARK: - Computed

    /// Current auth epoch. UI/client may capture this at request start and
    /// compare on completion to detect whether a purge+reauth cycle occurred
    /// while a request was in flight.
    var authEpoch: Int { epoch }

    var activeSessionCount: Int {
        guard nodesVerified else { return 0 }
        return nodes.reduce(0) { $0 + ($1.sessions?.active_count ?? 0) }
    }

    var activeDelegationCount: Int {
        guard delegationsVerified else { return 0 }
        return delegations.filter { !Self.terminalDelegationStatuses.contains($0.status) }.count
    }

    // MARK: - Constants

    static let defaultAttentionLimit = 20
    static let maxAttentionLimit = 500
    static let defaultPollInterval: TimeInterval = 15

    private static let terminalDelegationStatuses: Set<String> = [
        "succeeded", "failed", "cancelled", "timed_out", "error",
    ]

    // MARK: - Private state

    private let client: any HubServing
    private let pollInterval: TimeInterval
    private let clock: () -> Date

    /// Auth/disposal epoch. Bumped **only** on auth purge or dispose — never
    /// on routine poll or manual refresh. Guards late responses.
    private var epoch = 0
    private var disposed = false
    private var pollTask: Task<Void, Never>?

    /// Per-panel retained tasks. Cancelled individually on manual refresh or
    /// collectively on auth purge / dispose.
    private var nodesTask: Task<Void, Never>?
    private var attentionTask: Task<Void, Never>?
    private var delegationsTask: Task<Void, Never>?

    /// Per-panel sequence counters. Bumped on every launch **and** on cancel.
    /// A completed task only writes results / clears refs when its captured
    /// sequence still matches — preventing stale overwrites and ref clearing
    /// after a newer task has been launched.
    private var nodesSeq: UInt64 = 0
    private var attentionSeq: UInt64 = 0
    private var delegationsSeq: UInt64 = 0

    /// Registration load token — bumped on every `loadRegistrationInfo` call
    /// and on `clearRegistrationInfo`. Old load's defer/result is discarded
    /// when its captured token mismatches (e.g. clear + reload within epoch).
    private var registrationToken: UInt64 = 0

    private var orderVersion = 0
    private var orderSaves = 0
    private var orderLock = false

    // MARK: - Init

    /// After init the caller **must** wire the client's header-time callback:
    /// ```swift
    /// client.on_unauthorized = { [weak store] in
    ///     await MainActor.run { store?.purgeOnUnauthorized() }
    /// }
    /// ```
    init(
        client: any HubServing,
        authMode: HubAuthMode = .passkey,
        pollInterval: TimeInterval = HubStore.defaultPollInterval,
        clock: @escaping () -> Date = Date.init
    ) {
        self.client = client
        self.authMode = authMode
        self.pollInterval = pollInterval
        self.clock = clock
    }

    deinit {
        pollTask?.cancel()
        nodesTask?.cancel()
        attentionTask?.cancel()
        delegationsTask?.cancel()
    }

    // MARK: - Lifecycle

    /// Begin polling. Idempotent; no-op after dispose or while unauthorized.
    func start() {
        guard !disposed, !unauthorized, pollTask == nil else { return }
        launchPanelTasks()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64((self?.pollInterval ?? 15) * 1_000_000_000))
                guard let self, !self.disposed, !self.unauthorized else { break }
                self.launchPanelTasksIfIdle()
            }
        }
    }

    /// Manual refresh. Cancels and replaces panel tasks. Does NOT bump epoch.
    func refresh() async {
        guard !disposed, !unauthorized else { return }
        refreshing = true
        launchPanelTasks()
        await awaitPanelTasks()
        if !disposed {
            refreshing = false
            initialLoading = false
        }
    }

    /// Resume after the user re-authenticates. Advances epoch so that any
    /// in-flight tasks or mutation completions from the previous session
    /// cannot write into the new workspace. Resets **all** busy flags since
    /// old defers are now epoch-gated no-ops and will not clean them up.
    func resumeAfterAuthentication() async {
        guard !disposed else { return }
        epoch &+= 1
        cancelPanelTasks()
        pollTask?.cancel()
        pollTask = nil

        // New epoch owns all flags — reset everything old defers will skip.
        unauthorized = false
        recentAuthRequired = false
        nodeError = nil
        attentionError = nil
        delegationError = nil
        resolverWarning = nil
        securityStatus = nil
        nodeOperation = .idle
        nodeOperationResult = nil
        clearingAttention = false
        attentionClearStatus = nil
        markingSeen = []
        securityLoading = false
        securityOperation = nil
        registrationLoading = false
        registrationError = nil
        orderLock = false
        orderSaves = 0
        nodesLoading = false
        attentionLoading = false
        delegationsLoading = false
        refreshing = false
        initialLoading = true
        start()
    }

    func setAuthMode(_ mode: HubAuthMode) {
        authMode = mode
    }

    func dispose() {
        disposed = true
        epoch &+= 1
        pollTask?.cancel()
        pollTask = nil
        cancelPanelTasks()
    }

    // MARK: - Attention mutations

    func clearAttention() async {
        let e = epoch
        guard !disposed, !unauthorized, !clearingAttention, attentionVerified else { return }
        clearingAttention = true
        attentionClearStatus = nil
        defer { if e == epoch { clearingAttention = false } }
        do {
            let result = try await client.clear_attention()
            guard epochCurrent(e) else { return }
            if result.failed > 0 {
                attentionClearStatus = "Cleared \(result.cleared); \(result.failed) could not be cleared. Try Clear all again."
            }
        } catch {
            guard epochCurrent(e) else { return }
            if authPurgeIfNeeded(error) { return }
            if error is CancellationError { return }
            attentionClearStatus = "Could not clear notifications: \(errorMessage(error)). Try Clear all again."
        }
        // Always reconcile — only the server decides which rows remain.
        if epochCurrent(e) {
            launchAttentionTask()
            await attentionTask?.value
        }
    }

    func markInboxItemSeen(_ item: HubAttentionInboxItem) async {
        let key = Self.inboxItemKey(item)
        let e = epoch
        guard !disposed, !unauthorized,
              let storeID = item.store_instance_id,
              !markingSeen.contains(key),
              attentionVerified else { return }
        markingSeen.insert(key)
        attentionClearStatus = nil
        defer { if e == epoch { markingSeen.remove(key) } }
        do {
            _ = try await client.mark_attention_seen(AttentionSeenRequest(
                store_instance_id: storeID,
                session_id: item.session_id,
                attention_seq: item.attention_seq
            ))
        } catch {
            guard epochCurrent(e) else { return }
            if authPurgeIfNeeded(error) { return }
            if !(error is CancellationError) {
                attentionClearStatus = "Could not mark \"\(item.title.isEmpty ? item.session_id : item.title)\" seen: \(errorMessage(error))."
            }
        }
        if epochCurrent(e) {
            launchAttentionTask()
            await attentionTask?.value
        }
    }

    var canLoadMoreAttention: Bool { attentionHasMore && attentionLimit < Self.maxAttentionLimit }

    func loadMoreAttention() async {
        guard !disposed, !unauthorized, attentionHasMore else { return }
        let newLimit = min(attentionLimit * 2, Self.maxAttentionLimit)
        guard newLimit > attentionLimit else { return }
        attentionLimit = newLimit
        launchAttentionTask()
        await attentionTask?.value
    }

    // MARK: - Node mutations

    func testNode(_ form: NodeFormData) async {
        let e = epoch
        guard !disposed, !unauthorized, nodeOperation == .idle else { return }
        nodeOperation = .testing
        nodeOperationResult = "Testing…"
        defer { if e == epoch { nodeOperation = .idle } }
        do {
            let response = try await client.test_node(form)
            guard epochCurrent(e) else { return }
            let s = response.status
            if s.reachable {
                var parts = "✓ Reachable in \(s.latency_ms) ms"
                if let agent = s.agent, !agent.isEmpty { parts += " · agent: \(agent)" }
                if let version = s.version, !version.isEmpty { parts += " · \(version)" }
                nodeOperationResult = parts
            } else {
                nodeOperationResult = "✗ Not reachable: \(s.error ?? s.state)"
            }
        } catch {
            guard epochCurrent(e) else { return }
            if authPurgeIfNeeded(error) { return }
            nodeOperationResult = "✗ \(errorMessage(error))"
        }
    }

    @discardableResult
    func addNode(_ form: NodeFormData) async -> Bool {
        let e = epoch
        guard !disposed, !unauthorized, nodeOperation == .idle else { return false }
        nodeOperation = .adding
        nodeOperationResult = "Adding…"
        defer { if e == epoch { nodeOperation = .idle } }
        let warning: String?
        do {
            let response = try await client.add_node(form)
            guard epochCurrent(e) else { return response.warning == nil }
            warning = response.warning
        } catch {
            guard epochCurrent(e) else { return false }
            if authPurgeIfNeeded(error) { return false }
            nodeOperationResult = "✗ \(errorMessage(error))"
            return false
        }
        if let w = warning, !w.isEmpty {
            nodeOperationResult = "Added with warning: \(w)"
        } else {
            nodeOperationResult = nil
        }
        // Refresh nodes to pick up the new one.
        if epochCurrent(e) {
            launchNodesTask()
            await nodesTask?.value
        }
        return warning == nil || (warning?.isEmpty == true)
    }

    func removeNode(id: String) async {
        let e = epoch
        guard !disposed, !unauthorized, nodeOperation == .idle else { return }
        nodeOperation = .removing
        defer { if e == epoch { nodeOperation = .idle } }
        do {
            _ = try await client.remove_node(id: id)
        } catch {
            guard epochCurrent(e) else { return }
            if authPurgeIfNeeded(error) { return }
            nodeError = "Could not remove node: \(errorMessage(error))"
            return
        }
        if epochCurrent(e) {
            launchNodesTask()
            await nodesTask?.value
        }
    }

    func reorderNodes(orderedIDs: [String]) async throws {
        guard !disposed, !unauthorized else { return }
        let currentIDs = nodes.map(\.id)
        guard !orderedIDs.isEmpty,
              Set(orderedIDs).count == orderedIDs.count,
              Set(orderedIDs) == Set(currentIDs) else { return }
        guard orderedIDs != currentIDs else { return }
        guard !orderLock else { return }
        orderLock = true

        let e = epoch
        let previousIDs = currentIDs

        // Optimistic local update.
        orderVersion += 1
        let rankMap = Dictionary(uniqueKeysWithValues: orderedIDs.enumerated().map { ($1, $0) })
        nodes = nodes.sorted { (rankMap[$0.id] ?? Int.max) < (rankMap[$1.id] ?? Int.max) }

        orderSaves += 1
        defer { if e == epoch { orderLock = false } }

        // Minimal diff against previous order.
        var first = 0
        while first < previousIDs.count, first < orderedIDs.count,
              previousIDs[first] == orderedIDs[first] { first += 1 }
        guard first < orderedIDs.count else {
            if e == epoch { orderSaves = max(orderSaves - 1, 0) }
            return
        }
        var lastPrev = previousIDs.count - 1
        var lastNew = orderedIDs.count - 1
        while lastPrev > first, lastNew > first,
              previousIDs[lastPrev] == orderedIDs[lastNew] { lastPrev -= 1; lastNew -= 1 }
        let moved = Array(orderedIDs[first...lastNew])

        do {
            _ = try await client.reorder_nodes(node_ids: moved)
            // Success: the next routine poll (orderSaves == 0) will accept
            // server order as authoritative.
            if e == epoch { orderSaves = max(orderSaves - 1, 0) }
        } catch {
            guard epochCurrent(e) else { return }
            // Rollback: clear orderSaves BEFORE the reconciliation fetch so
            // showNodes accepts the server's authoritative order instead of
            // re-sorting to match the failed optimistic order.
            if e == epoch { orderSaves = max(orderSaves - 1, 0) }
            if authPurgeIfNeeded(error) {
                throw HubStoreError.reorderFailed("Authorization expired.")
            }
            if epochCurrent(e) {
                launchNodesTask()
                await nodesTask?.value
            }
            if let apiError = error as? HubAPIError, apiError.status == 404 {
                throw HubStoreError.nodesChangedElsewhere
            }
            throw HubStoreError.reorderFailed(errorMessage(error))
        }
    }

    // MARK: - Registration

    func loadRegistrationInfo() async {
        let e = epoch
        guard !disposed, !unauthorized, !registrationLoading else { return }
        registrationToken &+= 1
        let tok = registrationToken
        registrationLoading = true
        registrationError = nil
        defer { if e == epoch, tok == registrationToken { registrationLoading = false } }
        do {
            let info = try await client.registration_info()
            guard epochCurrent(e), tok == registrationToken else { return }
            registrationInfo = info
        } catch {
            guard epochCurrent(e), tok == registrationToken else { return }
            if !(error is CancellationError) {
                registrationError = "Could not load registration settings: \(errorMessage(error))"
            }
        }
    }

    func clearRegistrationInfo() {
        registrationToken &+= 1
        registrationInfo = nil
        registrationError = nil
        registrationLoading = false
    }

    // MARK: - Security / session

    func loadSecurity(preservingStatus: Bool = false) async {
        let e = epoch
        guard !disposed, !unauthorized, !securityLoading else { return }
        securityLoading = true
        if !preservingStatus { securityStatus = nil }
        recentAuthRequired = false
        defer { if e == epoch { securityLoading = false } }
        do {
            let sessResponse: HubSessionResponse
            let credResponse: CredentialsResponse
            if authMode == .passkey {
                async let creds = client.list_credentials()
                async let sess = client.session()
                (credResponse, sessResponse) = try await (creds, sess)
            } else {
                sessResponse = try await client.session()
                credResponse = CredentialsResponse(credentials: [])
            }
            guard epochCurrent(e) else { return }
            credentials = credResponse.credentials
            activeSessions = sessResponse.active_sessions
        } catch {
            guard epochCurrent(e) else { return }
            if authPurgeIfNeeded(error) { return }
            if !(error is CancellationError) {
                securityStatus = errorMessage(error)
            }
        }
    }

    func renameCredential(recordID: String, displayName: String) async {
        let e = epoch
        guard !disposed, !unauthorized, securityOperation == nil else { return }
        securityOperation = "rename"
        securityStatus = nil
        defer { if e == epoch { securityOperation = nil } }
        do {
            _ = try await client.rename_credential(record_id: recordID, display_name: displayName)
            guard epochCurrent(e) else { return }
            securityStatus = "Passkey renamed."
            await loadSecurity(preservingStatus: true)
        } catch {
            guard epochCurrent(e) else { return }
            if authPurgeIfNeeded(error) { return }
            securityStatus = errorMessage(error)
        }
    }

    /// Credential removal requires recent WebAuthn authentication (403).
    /// The 403 is caught at header-time by `on_unauthorized`, triggering a
    /// full auth purge. Native UI should **disable** this button proactively
    /// and show a browser fallback instead of attempting the operation.
    func removeCredential(recordID: String) async {
        let e = epoch
        guard !disposed, !unauthorized, securityOperation == nil else { return }
        securityOperation = "remove"
        securityStatus = nil
        defer { if e == epoch { securityOperation = nil } }
        do {
            _ = try await client.remove_credential(record_id: recordID)
            guard epochCurrent(e) else { return }
            securityStatus = "Passkey removed."
            await loadSecurity(preservingStatus: true)
        } catch {
            guard epochCurrent(e) else { return }
            if isAuthError(error) {
                let needsReauth = (error as? HubAPIError)?.status == 403
                performUnauthorizedPurge()
                if needsReauth {
                    recentAuthRequired = true
                    securityStatus = "Removing a passkey requires recent authentication. Use the browser to complete this action."
                }
                return
            }
            securityStatus = errorMessage(error)
        }
    }

    func revokeOtherSessions() async {
        let e = epoch
        guard !disposed, !unauthorized, securityOperation == nil else { return }
        securityOperation = "revoke"
        securityStatus = nil
        defer { if e == epoch { securityOperation = nil } }
        do {
            let result = try await client.revoke_other_sessions()
            guard epochCurrent(e) else { return }
            securityStatus = "Revoked \(result.revoked) other session\(result.revoked == 1 ? "" : "s")."
            await loadSecurity(preservingStatus: true)
        } catch {
            guard epochCurrent(e) else { return }
            if authPurgeIfNeeded(error) { return }
            securityStatus = errorMessage(error)
        }
    }

    func signOut() async -> String? {
        let e = epoch
        guard !disposed, !unauthorized, securityOperation == nil else { return nil }
        securityOperation = "logout"
        do {
            let result = try await client.logout()
            guard epochCurrent(e) else { return nil }
            performUnauthorizedPurge()
            return result.redirect
        } catch {
            guard epochCurrent(e) else { return nil }
            securityStatus = errorMessage(error)
            securityOperation = nil
            return nil
        }
    }

    // MARK: - Identity key

    static func inboxItemKey(_ item: HubAttentionInboxItem) -> String {
        [item.store_instance_id ?? item.node_id, item.session_id, "\(item.attention_seq)"]
            .joined(separator: "\0")
    }

    // MARK: - Types

    enum NodeOperation: Equatable, Sendable {
        case idle, testing, adding, removing
    }

    // MARK: - Auth purge (public)

    /// Wire to `client.on_unauthorized`. Idempotent.
    func purgeOnUnauthorized() {
        guard !unauthorized else { return }
        performUnauthorizedPurge()
    }

    // MARK: - Private — epoch guards

    private func epochCurrent(_ e: Int) -> Bool {
        !disposed && !unauthorized && e == epoch
    }

    // MARK: - Private — auth purge

    @discardableResult
    private func authPurgeIfNeeded(_ error: Error) -> Bool {
        guard isAuthError(error) else { return false }
        performUnauthorizedPurge()
        return true
    }

    private func performUnauthorizedPurge() {
        epoch &+= 1
        cancelPanelTasks()
        pollTask?.cancel()
        pollTask = nil

        nodes = []
        attentionNodes = []
        inputRequired = []
        inbox = []
        delegations = []
        credentials = []
        totalInputRequired = 0
        totalUnseen = 0
        attentionHasMore = false
        activeSessions = 0

        nodesVerified = false
        attentionVerified = false
        delegationsVerified = false
        nodesLoading = false
        attentionLoading = false
        delegationsLoading = false
        clearingAttention = false
        attentionClearStatus = nil
        markingSeen = []
        securityLoading = false
        securityOperation = nil
        registrationLoading = false
        registrationInfo = nil
        registrationError = nil
        nodeOperation = .idle
        nodeOperationResult = nil
        initialLoading = false
        refreshing = false

        unauthorized = true
        nodeError = "Hub authorization expired. Sign in again."
        attentionError = nil
        delegationError = nil
        resolverWarning = nil
        securityStatus = nil
        recentAuthRequired = false
    }

    private func isAuthError(_ error: Error) -> Bool {
        guard let apiError = error as? HubAPIError else { return false }
        return apiError.status == 401 || apiError.status == 403
    }

    // MARK: - Private — panel task management

    private func cancelPanelTasks() {
        nodesTask?.cancel()
        nodesTask = nil
        nodesSeq &+= 1
        attentionTask?.cancel()
        attentionTask = nil
        attentionSeq &+= 1
        delegationsTask?.cancel()
        delegationsTask = nil
        delegationsSeq &+= 1
    }

    /// Launch all three panel tasks, cancelling any existing ones.
    private func launchPanelTasks() {
        launchNodesTask()
        launchAttentionTask()
        launchDelegationsTask()
    }

    /// Launch panel tasks only if the corresponding task is nil (finished).
    /// Used by poll to coalesce with in-flight reads.
    private func launchPanelTasksIfIdle() {
        if nodesTask == nil { launchNodesTask() }
        if attentionTask == nil { launchAttentionTask() }
        if delegationsTask == nil { launchDelegationsTask() }
    }

    /// Await all current panel tasks (for manual refresh).
    private func awaitPanelTasks() async {
        await nodesTask?.value
        await attentionTask?.value
        await delegationsTask?.value
    }

    private func launchNodesTask() {
        nodesTask?.cancel()
        nodesSeq &+= 1
        let seq = nodesSeq
        let e = epoch
        let orderVer = orderVersion
        nodesLoading = true
        nodesTask = Task { [weak self] in
            guard let self else { return }
            await self.fetchNodes(epoch: e, seq: seq, orderVersion: orderVer)
            guard self.nodesSeq == seq else { return }
            self.nodesTask = nil
            if !self.disposed { self.nodesLoading = false }
        }
    }

    private func launchAttentionTask() {
        attentionTask?.cancel()
        attentionSeq &+= 1
        let seq = attentionSeq
        let e = epoch
        let limit = attentionLimit
        attentionLoading = true
        attentionTask = Task { [weak self] in
            guard let self else { return }
            await self.fetchAttention(epoch: e, seq: seq, limit: limit)
            guard self.attentionSeq == seq else { return }
            self.attentionTask = nil
            if !self.disposed { self.attentionLoading = false }
        }
    }

    private func launchDelegationsTask() {
        delegationsTask?.cancel()
        delegationsSeq &+= 1
        let seq = delegationsSeq
        let e = epoch
        delegationsLoading = true
        delegationsTask = Task { [weak self] in
            guard let self else { return }
            await self.fetchDelegations(epoch: e, seq: seq)
            guard self.delegationsSeq == seq else { return }
            self.delegationsTask = nil
            if !self.disposed { self.delegationsLoading = false }
        }
    }

    // MARK: - Private — per-section fetch

    private func fetchNodes(epoch e: Int, seq: UInt64, orderVersion orderVer: Int) async {
        do {
            let response = try await client.list_nodes()
            guard epochCurrent(e), nodesSeq == seq else { return }
            acceptNodes(response.nodes, resolverError: response.resolver_error, orderVersion: orderVer)
        } catch {
            guard epochCurrent(e), nodesSeq == seq else { return }
            if authPurgeIfNeeded(error) { return }
            if error is CancellationError { return }
            nodeError = "Failed to load nodes: \(errorMessage(error))"
        }
        if epochCurrent(e), nodesSeq == seq { initialLoading = false }
    }

    private func fetchAttention(epoch e: Int, seq: UInt64, limit: Int) async {
        do {
            let data = try await client.list_attention(limit: limit)
            guard epochCurrent(e), attentionSeq == seq else { return }
            if attentionNodes != data.nodes { attentionNodes = data.nodes }
            if inputRequired != data.input_required { inputRequired = data.input_required }
            if inbox != data.inbox { inbox = data.inbox }
            if totalInputRequired != data.total_input_required { totalInputRequired = data.total_input_required }
            if totalUnseen != data.total_unseen { totalUnseen = data.total_unseen }
            if attentionHasMore != data.has_more { attentionHasMore = data.has_more }
            if !attentionVerified { attentionVerified = true }
            if attentionError != nil { attentionError = nil }
            lastAttentionRefresh = clock()
        } catch {
            guard epochCurrent(e), attentionSeq == seq else { return }
            if authPurgeIfNeeded(error) { return }
            if error is CancellationError { return }
            attentionError = errorMessage(error)
        }
    }

    private func fetchDelegations(epoch e: Int, seq: UInt64) async {
        do {
            let data = try await client.list_delegations()
            guard epochCurrent(e), delegationsSeq == seq else { return }
            if delegations != data.delegations { delegations = data.delegations }
            if !delegationsVerified { delegationsVerified = true }
            if delegationError != nil { delegationError = nil }
            lastDelegationsRefresh = clock()
        } catch {
            guard epochCurrent(e), delegationsSeq == seq else { return }
            if authPurgeIfNeeded(error) { return }
            if error is CancellationError { return }
            delegationError = errorMessage(error)
        }
    }

    // MARK: - Private — node helpers

    private func acceptNodes(_ incoming: [HubNode], resolverError: String?, orderVersion orderVer: Int) {
        showNodes(incoming, orderVersion: orderVer)
        if !nodesVerified { nodesVerified = true }
        if resolverWarning != resolverError { resolverWarning = resolverError }
        if nodeError != nil { nodeError = nil }
        lastNodesRefresh = clock()

        let ids = Set(incoming.map(\.id))
        if !attentionVerified {
            let filteredAttentionNodes = attentionNodes.filter { ids.contains($0.node_id) }
            if attentionNodes != filteredAttentionNodes { attentionNodes = filteredAttentionNodes }
            let filteredInputRequired = inputRequired.filter { ids.contains($0.node_id) }
            if inputRequired != filteredInputRequired { inputRequired = filteredInputRequired }
            let filteredInbox = inbox.filter { ids.contains($0.node_id) }
            if inbox != filteredInbox { inbox = filteredInbox }
        }
        if !delegationsVerified {
            let filtered = delegations.filter {
                ids.contains($0.origin_node) && ids.contains($0.target_node)
            }
            if delegations != filtered { delegations = filtered }
        }
    }

    private func showNodes(_ incoming: [HubNode], orderVersion orderVer: Int) {
        var listed = incoming
        if orderVer != orderVersion || orderSaves > 0 {
            let shown = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1.id, $0) })
            listed.sort { (shown[$0.id] ?? shown.count) < (shown[$1.id] ?? shown.count) }
        }
        // Stable row IDs let SwiftUI diff actual additions/removals/changes;
        // an identical poll must not invalidate the collection at all.
        if nodes != listed { nodes = listed }
    }
}

// MARK: - HubStoreError

enum HubStoreError: LocalizedError, Equatable {
    case nodesChangedElsewhere
    case reorderFailed(String)

    var errorDescription: String? {
        switch self {
        case .nodesChangedElsewhere:
            "Nodes changed elsewhere; showing the latest order."
        case .reorderFailed(let detail):
            "Couldn't save the node order: \(detail)"
        }
    }
}

// MARK: - Helpers

private func errorMessage(_ error: Error) -> String {
    if let apiError = error as? HubAPIError { return apiError.message }
    return error.localizedDescription
}
