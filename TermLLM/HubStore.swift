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
    @Published private var nodeFailure: PanelFailure?
    var nodeError: String? { nodeFailure?.message }
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
    @Published private var attentionFailure: PanelFailure?
    var attentionError: String? { attentionFailure?.message }

    /// The displayed panel failure, in the same priority order as the connection summary.
    var hasUnreachablePanelFailure: Bool { (nodeFailure ?? attentionFailure) == .unreachable }
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
        return nodes.reduce(0) { $0 + ($1.sessions?.activeCount ?? 0) }
    }

    var activeDelegationCount: Int {
        guard delegationsVerified else { return 0 }
        return delegations.filter { !Self.terminalDelegationStatuses.contains($0.status) }.count
    }

    // MARK: - Constants

    static let defaultAttentionLimit = 20
    static let maxAttentionLimit = 500
    nonisolated static let defaultPollInterval: TimeInterval = 15

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
    /// client.onUnauthorized = { [weak store] in
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
        startPollLoop()
    }

    /// Stop the change-feed loop while the app is backgrounded (background
    /// audio keeps the process alive). Data and epoch are untouched.
    func suspendPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    var isPolling: Bool { pollTask != nil }

    /// Resume after `suspendPolling`. Refetches idle panels, then polls again.
    /// No-op while already polling, disposed or unauthorized.
    func resumePolling() {
        guard !disposed, !unauthorized, pollTask == nil else { return }
        launchPanelTasksIfIdle()
        startPollLoop()
    }

    private func startPollLoop() {
        let client = client
        let interval = pollInterval
        pollTask = Task { [weak self] in
            // Long-poll the Hub change feed: it answers on change or after
            // `interval`, and either way panels refetch. Hubs without the feed
            // (or direct nodes) fall back to sleeping `interval` between polls.
            var since: UInt64?
            var longPoll = true
            while !Task.isCancelled {
                if longPoll {
                    do {
                        let previous = since
                        let began = ContinuousClock.now
                        since = try await client.waitForChanges(
                            since: previous, timeout: max(1, Int(interval.rounded()))).version
                        if Task.isCancelled { break }
                        // First call only records the baseline version.
                        if previous == nil { continue }
                        if since != previous {
                            // Coalesce bursts (one bump per node in a collection round).
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                        } else {
                            // "No change" should only arrive after the long-poll
                            // timeout. A server or proxy that answers early must
                            // not turn this into a busy loop: wait out the rest
                            // of the interval, like plain polling.
                            let remaining = Duration.seconds(interval) - (ContinuousClock.now - began)
                            if remaining > .zero { try? await Task.sleep(for: remaining) }
                        }
                    } catch {
                        if Task.isCancelled { break }
                        if Self.changesUnsupported(error) { longPoll = false }
                        try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    }
                } else {
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                }
                // Suspending cancels the sleeps above: that's no reason to refetch.
                guard !Task.isCancelled, let self, !self.disposed, !self.unauthorized else { break }
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
        nodeFailure = nil
        attentionFailure = nil
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
            let result = try await client.clearAttention()
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
              let storeID = item.storeInstanceID,
              !markingSeen.contains(key),
              attentionVerified else { return }
        markingSeen.insert(key)
        attentionClearStatus = nil
        defer { if e == epoch { markingSeen.remove(key) } }
        do {
            _ = try await client.markAttentionSeen(AttentionSeenRequest(
                storeInstanceID: storeID,
                sessionID: item.sessionID,
                attentionSeq: item.attentionSeq
            ))
        } catch {
            guard epochCurrent(e) else { return }
            if authPurgeIfNeeded(error) { return }
            if !(error is CancellationError) {
                attentionClearStatus = "Could not mark \"\(item.title.isEmpty ? item.sessionID : item.title)\" seen: \(errorMessage(error))."
            }
        }
        if epochCurrent(e) {
            launchAttentionTask()
            await attentionTask?.value
        }
    }

    /// Exact-item acknowledgement for a conversation row outside the loaded
    /// attention window (an agent's history). Throws so the row can restore
    /// its unseen mark; on success the attention panel and badge refresh.
    func markSessionSeen(_ request: AttentionSeenRequest) async throws {
        let e = epoch
        guard !disposed, !unauthorized else { throw CancellationError() }
        do {
            _ = try await client.markAttentionSeen(request)
        } catch {
            if epochCurrent(e) { authPurgeIfNeeded(error) }
            throw error
        }
        guard epochCurrent(e) else { return }
        launchAttentionTask()
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
            let response = try await client.testNode(form)
            guard epochCurrent(e) else { return }
            let s = response.status
            if s.reachable {
                var parts = "✓ Reachable in \(s.latencyMs) ms"
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
            let response = try await client.addNode(form)
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
            _ = try await client.removeNode(id: id)
        } catch {
            guard epochCurrent(e) else { return }
            if authPurgeIfNeeded(error) { return }
            nodeFailure = PanelFailure(error, prefix: "Could not remove node: ")
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
            _ = try await client.reorderNodes(nodeIDs: moved)
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
            let info = try await client.registrationInfo()
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
                async let creds = client.listCredentials()
                async let sess = client.session()
                (credResponse, sessResponse) = try await (creds, sess)
            } else {
                sessResponse = try await client.session()
                credResponse = CredentialsResponse(credentials: [])
            }
            guard epochCurrent(e) else { return }
            credentials = credResponse.credentials
            activeSessions = sessResponse.activeSessions
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
            _ = try await client.renameCredential(recordID: recordID, displayName: displayName)
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
    /// The 403 is caught at header-time by `onUnauthorized`, triggering a
    /// full auth purge. Native UI should **disable** this button proactively
    /// and show a browser fallback instead of attempting the operation.
    func removeCredential(recordID: String) async {
        let e = epoch
        guard !disposed, !unauthorized, securityOperation == nil else { return }
        securityOperation = "remove"
        securityStatus = nil
        defer { if e == epoch { securityOperation = nil } }
        do {
            _ = try await client.removeCredential(recordID: recordID)
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
            let result = try await client.revokeOtherSessions()
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
        [item.storeInstanceID ?? item.nodeID, item.sessionID, "\(item.attentionSeq)"]
            .joined(separator: "\0")
    }

    // MARK: - Types

    enum NodeOperation: Equatable, Sendable {
        case idle, testing, adding, removing
    }

    // MARK: - Auth purge (public)

    /// Wire to `client.onUnauthorized`. Idempotent.
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
        nodeFailure = .other("Hub authorization expired. Sign in again.")
        attentionFailure = nil
        delegationError = nil
        resolverWarning = nil
        securityStatus = nil
        recentAuthRequired = false
    }

    /// Hubs predating /api/changes answer 404/405 (or a non-JSON page).
    private nonisolated static func changesUnsupported(_ error: Error) -> Bool {
        if error is HubChangesUnsupported || error is DecodingError { return true }
        guard let apiError = error as? HubAPIError else { return false }
        return apiError.status == 404 || apiError.status == 405
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
            let response = try await client.listNodes()
            guard epochCurrent(e), nodesSeq == seq else { return }
            acceptNodes(response.nodes, resolverError: response.resolverError, orderVersion: orderVer)
        } catch {
            guard epochCurrent(e), nodesSeq == seq else { return }
            if authPurgeIfNeeded(error) { return }
            if error is CancellationError { return }
            nodeFailure = PanelFailure(error, prefix: "Failed to load nodes: ")
        }
        if epochCurrent(e), nodesSeq == seq { initialLoading = false }
    }

    private func fetchAttention(epoch e: Int, seq: UInt64, limit: Int) async {
        do {
            let data = try await client.listAttention(limit: limit)
            guard epochCurrent(e), attentionSeq == seq else { return }
            if attentionNodes != data.nodes { attentionNodes = data.nodes }
            if inputRequired != data.inputRequired { inputRequired = data.inputRequired }
            if inbox != data.inbox { inbox = data.inbox }
            if totalInputRequired != data.totalInputRequired { totalInputRequired = data.totalInputRequired }
            if totalUnseen != data.totalUnseen { totalUnseen = data.totalUnseen }
            if attentionHasMore != data.hasMore { attentionHasMore = data.hasMore }
            if !attentionVerified { attentionVerified = true }
            if attentionFailure != nil { attentionFailure = nil }
            lastAttentionRefresh = clock()
        } catch {
            guard epochCurrent(e), attentionSeq == seq else { return }
            if authPurgeIfNeeded(error) { return }
            if error is CancellationError { return }
            attentionFailure = PanelFailure(error)
        }
    }

    private func fetchDelegations(epoch e: Int, seq: UInt64) async {
        do {
            let data = try await client.listDelegations()
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
        if nodeFailure != nil { nodeFailure = nil }
        lastNodesRefresh = clock()

        let ids = Set(incoming.map(\.id))
        if !attentionVerified {
            let filteredAttentionNodes = attentionNodes.filter { ids.contains($0.nodeID) }
            if attentionNodes != filteredAttentionNodes { attentionNodes = filteredAttentionNodes }
            let filteredInputRequired = inputRequired.filter { ids.contains($0.nodeID) }
            if inputRequired != filteredInputRequired { inputRequired = filteredInputRequired }
            let filteredInbox = inbox.filter { ids.contains($0.nodeID) }
            if inbox != filteredInbox { inbox = filteredInbox }
        }
        if !delegationsVerified {
            let filtered = delegations.filter {
                ids.contains($0.originNode) && ids.contains($0.targetNode)
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

private enum PanelFailure: Equatable {
    case unreachable
    case other(String)

    init(_ error: Error, prefix: String = "") {
        if let apiError = error as? HubAPIError {
            self = .other(prefix + apiError.message)
            return
        }
        let networkError = error as NSError
        // This does not prove an internet outage or a Local Network permission denial.
        if networkError.domain == NSURLErrorDomain, networkError.code == URLError.notConnectedToInternet.rawValue {
            self = .unreachable
        } else {
            self = .other(prefix + error.localizedDescription)
        }
    }

    var message: String {
        switch self {
        case .unreachable: ServerAddress.unreachableMessage
        case .other(let message): message
        }
    }
}

private func errorMessage(_ error: Error) -> String {
    PanelFailure(error).message
}
