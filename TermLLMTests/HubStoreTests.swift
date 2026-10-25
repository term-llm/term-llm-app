import Combine
import Foundation
import XCTest
@testable import TermLLM

// MARK: - MockHubClient

/// `@MainActor` mock satisfying `HubServing`. Swift allows a `@MainActor async`
/// method to satisfy a plain `async` protocol requirement, so no `nonisolated`
/// + `MainActor.run` dance is needed — stubs are called directly on the main
/// actor where the test already runs.
@MainActor
final class MockHubClient: HubServing, @unchecked Sendable {

    // ── Call counts ─────────────────────────────────────────────
    var listNodesCalls = 0
    var listAttentionCalls = 0
    var listAttentionLimits: [Int?] = []
    var listDelegationsCalls = 0
    var clearAttentionCalls = 0
    var markSeenCalls: [AttentionSeenRequest] = []
    var testNodeCalls: [NodeFormData] = []
    var addNodeCalls: [NodeFormData] = []
    var removeNodeCalls: [String] = []
    var reorderNodesCalls: [[String]] = []
    var registrationInfoCalls = 0
    var listCredentialsCalls = 0
    var sessionCalls = 0
    var renameCredentialCalls: [(String, String)] = []
    var removeCredentialCalls: [String] = []
    var revokeSessionsCalls = 0
    var logoutCalls = 0

    // ── Stubs (async throws closures called from @MainActor) ────
    var nodesResponse: @MainActor () async throws -> NodesResponse = {
        NodesResponse(nodes: [], resolver_error: nil)
    }
    var attentionResponse: @MainActor () async throws -> AttentionResponse = {
        AttentionResponse(total_running: 0, total_input_required: 0, total_unseen: 0,
                          nodes: [], input_required: [], inbox: [], has_more: false)
    }
    var delegationsResponse: @MainActor () async throws -> DelegationsResponse = {
        DelegationsResponse(delegations: [])
    }
    var clearAttentionResponse: @MainActor () async throws -> ClearAttentionResponse = {
        ClearAttentionResponse(cleared: 0, failed: 0)
    }
    var markSeenResponse: @MainActor () async throws -> SeenAttentionResponse = {
        SeenAttentionResponse(cleared: 1)
    }
    var testNodeResponse: @MainActor () async throws -> TestNodeResponse = {
        TestNodeResponse(status: HubNodeStatus(
            reachable: true, state: "ok", latency_ms: 42, version: "1.0",
            agent: "test", capabilities: nil, details: nil, error: nil))
    }
    var addNodeResponse: @MainActor () async throws -> AddNodeResponse = {
        AddNodeResponse(id: "new-1", warning: nil)
    }
    var removeNodeResponse: @MainActor () async throws -> RemovedNodeResponse = {
        RemovedNodeResponse(removed: "node-1")
    }
    var reorderNodesResponse: @MainActor () async throws -> NodeOrderResponse = {
        NodeOrderResponse(node_ids: [])
    }
    var registrationInfoResponse: @MainActor () async throws -> RegistrationInfoResponse = {
        RegistrationInfoResponse(enabled: true, token_configured: true,
                                 can_persist_nodes: true, registration_token: "tok-123")
    }
    var listCredentialsResponse: @MainActor () async throws -> CredentialsResponse = {
        CredentialsResponse(credentials: [])
    }
    var sessionResponse: @MainActor () async throws -> HubSessionResponse = {
        HubSessionResponse(administrator: "admin", session: [:],
                           recently_authenticated: true, active_sessions: 2)
    }
    var renameCredentialResponse: @MainActor () async throws -> HubCredential = {
        HubCredential(record_id: "r1", display_name: "Renamed",
                      transports: nil, created_at: "2024-01-01", last_used_at: "2024-01-01")
    }
    var removeCredentialResponse: @MainActor () async throws -> OkResponse = { OkResponse(ok: true) }
    var revokeSessionsResponse: @MainActor () async throws -> RevokeSessionsResponse = {
        RevokeSessionsResponse(revoked: 3)
    }
    var logoutResponse: @MainActor () async throws -> RedirectResponse = {
        RedirectResponse(ok: true, redirect: "/login")
    }

    // ── Protocol conformance ────────────────────────────────────

    func list_nodes() async throws -> NodesResponse {
        listNodesCalls += 1
        return try await nodesResponse()
    }
    func list_attention(limit: Int?) async throws -> AttentionResponse {
        listAttentionCalls += 1
        listAttentionLimits.append(limit)
        return try await attentionResponse()
    }
    func list_delegations() async throws -> DelegationsResponse {
        listDelegationsCalls += 1
        return try await delegationsResponse()
    }
    /// nil = Hub without /api/changes (store falls back to plain polling).
    var changesResponse: (@MainActor (UInt64?) async throws -> HubChangesResponse)?
    func wait_for_changes(since: UInt64?, timeout: Int) async throws -> HubChangesResponse {
        guard let changesResponse else { throw HubChangesUnsupported() }
        return try await changesResponse(since)
    }
    func clear_attention() async throws -> ClearAttentionResponse {
        clearAttentionCalls += 1
        return try await clearAttentionResponse()
    }
    func mark_attention_seen(_ item: AttentionSeenRequest) async throws -> SeenAttentionResponse {
        markSeenCalls.append(item)
        return try await markSeenResponse()
    }
    func test_node(_ form: NodeFormData) async throws -> TestNodeResponse {
        testNodeCalls.append(form)
        return try await testNodeResponse()
    }
    func add_node(_ form: NodeFormData) async throws -> AddNodeResponse {
        addNodeCalls.append(form)
        return try await addNodeResponse()
    }
    func remove_node(id: String) async throws -> RemovedNodeResponse {
        removeNodeCalls.append(id)
        return try await removeNodeResponse()
    }
    func reorder_nodes(node_ids: [String]) async throws -> NodeOrderResponse {
        reorderNodesCalls.append(node_ids)
        return try await reorderNodesResponse()
    }
    func registration_info() async throws -> RegistrationInfoResponse {
        registrationInfoCalls += 1
        return try await registrationInfoResponse()
    }
    func list_credentials() async throws -> CredentialsResponse {
        listCredentialsCalls += 1
        return try await listCredentialsResponse()
    }
    func session() async throws -> HubSessionResponse {
        sessionCalls += 1
        return try await sessionResponse()
    }
    func rename_credential(record_id: String, display_name: String) async throws -> HubCredential {
        renameCredentialCalls.append((record_id, display_name))
        return try await renameCredentialResponse()
    }
    func remove_credential(record_id: String) async throws -> OkResponse {
        removeCredentialCalls.append(record_id)
        return try await removeCredentialResponse()
    }
    func revoke_other_sessions() async throws -> RevokeSessionsResponse {
        revokeSessionsCalls += 1
        return try await revokeSessionsResponse()
    }
    func logout() async throws -> RedirectResponse {
        logoutCalls += 1
        return try await logoutResponse()
    }

    // ── Ceremony / grant stubs (not exercised by HubStore) ──────

    func begin_login(return_path: String) async throws -> Data { Data() }
    func finish_login(credential: Data) async throws -> RedirectResponse { RedirectResponse(ok: true, redirect: "/") }
    func begin_reauthentication() async throws -> Data { Data() }
    func finish_reauthentication(credential: Data) async throws -> OkResponse { OkResponse(ok: true) }
    func begin_additional_registration(display_name: String) async throws -> Data { Data() }
    func finish_additional_registration(credential: Data) async throws -> HubCredential {
        HubCredential(record_id: "new", display_name: "New Key",
                      transports: nil, created_at: "2024-01-01", last_used_at: "2024-01-01")
    }
    func verify_grant(prefix: GrantPrefix, code: String) async throws -> OkResponse { OkResponse(ok: true) }
    func begin_grant_registration(prefix: GrantPrefix, display_name: String) async throws -> Data { Data() }
    func finish_grant_registration(prefix: GrantPrefix, credential: Data, return_path: String) async throws -> RedirectResponse {
        RedirectResponse(ok: true, redirect: "/")
    }
    func authorize_native(challenge: String) async throws -> RedirectResponse { RedirectResponse(ok: true, redirect: "/") }
    func healthz() async throws -> HealthResponse { HealthResponse(status: "ok") }
}

// MARK: - Factories

private func makeNode(id: String = "node-1", name: String = "Test Node", activeSessions: Int = 1) -> HubNode {
    HubNode(
        id: id, name: name, source: "manual", connection: "direct",
        url: "https://example.com", base_path: "/", proxy_path: "/proxy/\(id)",
        new_session_path: "/new", has_token: true,
        status: HubNodeStatus(reachable: true, state: "ok", latency_ms: 10, version: "1.0",
                               agent: "test", capabilities: nil, details: nil, error: nil),
        sessions: HubNodeSessions(
            count_label: "\(activeSessions)", has_more: false, active_count: activeSessions,
            input_required_count: 0, unseen_count: 0, attention_capability: nil,
            attention_last_success_at: nil, active: [], recent: [], resume_path: nil),
        diagnostics: nil)
}

private func makeAttentionNode(nodeID: String = "node-1") -> HubAttentionNode {
    HubAttentionNode(node_id: nodeID, node_name: "Test Node", capability_state: "ok",
                     stale: false, last_success_at: "2024-01-01", last_error: nil,
                     running_count: 1, input_required_count: 0, unseen_count: 0,
                     has_green_indicator: true)
}

private func makeInboxItem(nodeID: String = "node-1", sessionID: String = "sess-1",
                           storeInstanceID: String? = "store-1", seq: Int = 1,
                           title: String = "Done") -> HubAttentionInboxItem {
    HubAttentionInboxItem(node_id: nodeID, node_name: "Test Node", session_id: sessionID,
                          store_instance_id: storeInstanceID, session_number: 1, title: title,
                          outcome: "completed", terminal_at: "2024-01-01T00:00:00Z",
                          attention_seq: seq, resume_path: "/resume")
}

private func makeInputRequired(nodeID: String = "node-1", sessionID: String = "sess-1") -> HubInputRequiredItem {
    HubInputRequiredItem(node_id: nodeID, node_name: "Test Node", session_id: sessionID,
                         session_number: 1, title: "Waiting", pending_interaction_count: 1,
                         pending_interaction_kinds: ["approval"],
                         required_since: "2024-01-01T00:00:00Z", resume_path: "/resume", stale: nil)
}

private func makeDelegation(id: String = "del-1", origin: String = "node-1",
                            target: String = "node-2", status: String = "running") -> HubDelegation {
    HubDelegation(id: id, origin_node: origin, target_node: target,
                  agent_name: "agent", prompt: "do stuff", model: nil, cwd: nil,
                  job_id: nil, run_id: nil, status: status, depth: 0, chain: nil,
                  parent_delegation_id: nil, response: nil, error: nil,
                  created_at: "2024-01-01", updated_at: "2024-01-01")
}

private func authError(_ status: Int = 401) -> HubAPIError {
    HubAPIError(status: status, message: "Unauthorized", type: "")
}

private func serverError(_ msg: String = "Internal error") -> HubAPIError {
    HubAPIError(status: 500, message: msg, type: "")
}

// MARK: - Tests

@MainActor
final class HubStoreTests: XCTestCase {

    private var client: MockHubClient!
    private var store: HubStore!

    override func setUp() async throws {
        try await super.setUp()
        client = MockHubClient()
        store = HubStore(client: client, pollInterval: 999)
    }

    override func tearDown() async throws {
        store.dispose()
        store = nil
        client = nil
        try await super.tearDown()
    }

    // MARK: - Initial state

    func testInitialState() {
        XCTAssertTrue(store.initialLoading)
        XCTAssertFalse(store.nodesVerified)
        XCTAssertFalse(store.attentionVerified)
        XCTAssertFalse(store.delegationsVerified)
        XCTAssertTrue(store.nodes.isEmpty)
        XCTAssertTrue(store.attentionNodes.isEmpty)
        XCTAssertTrue(store.delegations.isEmpty)
        XCTAssertFalse(store.unauthorized)
        XCTAssertEqual(store.nodeOperation, .idle)
        XCTAssertEqual(store.attentionLimit, HubStore.defaultAttentionLimit)
        XCTAssertEqual(store.authMode, .passkey)
    }

    func testIdenticalRefreshDoesNotRepublishCollections() async {
        client.nodesResponse = { NodesResponse(nodes: [makeNode()], resolver_error: nil) }
        client.attentionResponse = {
            AttentionResponse(total_running: 1, total_input_required: 1, total_unseen: 1,
                              nodes: [makeAttentionNode()], input_required: [makeInputRequired()],
                              inbox: [makeInboxItem()], has_more: false)
        }
        client.delegationsResponse = { DelegationsResponse(delegations: [makeDelegation()]) }
        await store.refresh()
        var publications = 0
        let observations = [
            store.$nodes.dropFirst().sink { _ in publications += 1 },
            store.$attentionNodes.dropFirst().sink { _ in publications += 1 },
            store.$inputRequired.dropFirst().sink { _ in publications += 1 },
            store.$inbox.dropFirst().sink { _ in publications += 1 },
            store.$delegations.dropFirst().sink { _ in publications += 1 }
        ]
        await store.refresh()
        XCTAssertEqual(publications, 0, "Unchanged snapshots should not invalidate existing rows")
        withExtendedLifetime(observations) {}
    }

    func testNodeDeltasPreserveIDsAndAcceptEditsAddsRemovalsAndServerOrder() async {
        let a = makeNode(id: "a"), b = makeNode(id: "b")
        client.nodesResponse = { NodesResponse(nodes: [a, b], resolver_error: nil) }
        await store.refresh()
        var publications = 0
        let observation = store.$nodes.dropFirst().sink { _ in publications += 1 }
        let renamed = makeNode(id: "a", name: "Updated")
        client.nodesResponse = { NodesResponse(nodes: [renamed, b], resolver_error: nil) }
        await store.refresh()
        XCTAssertEqual(store.nodes.map(\.id), ["a", "b"])
        XCTAssertEqual(store.nodes.first?.name, "Updated")
        XCTAssertEqual(publications, 1)
        let c = makeNode(id: "c")
        client.nodesResponse = { NodesResponse(nodes: [c, renamed], resolver_error: nil) }
        await store.refresh()
        XCTAssertEqual(store.nodes.map(\.id), ["c", "a"])
        XCTAssertEqual(publications, 2)
        await store.refresh()
        XCTAssertEqual(publications, 2)
        withExtendedLifetime(observation) {}
    }

    // MARK: - Refresh populates all sections

    func testRefreshPopulatesAllSections() async {
        client.nodesResponse = { NodesResponse(nodes: [makeNode()], resolver_error: nil) }
        client.attentionResponse = {
            AttentionResponse(total_running: 1, total_input_required: 2, total_unseen: 3,
                              nodes: [makeAttentionNode()],
                              input_required: [makeInputRequired()],
                              inbox: [makeInboxItem()], has_more: true)
        }
        client.delegationsResponse = { DelegationsResponse(delegations: [makeDelegation()]) }

        await store.refresh()

        XCTAssertTrue(store.nodesVerified)
        XCTAssertEqual(store.nodes.count, 1)
        XCTAssertEqual(store.attentionNodes.count, 1)
        XCTAssertEqual(store.inputRequired.count, 1)
        XCTAssertEqual(store.inbox.count, 1)
        XCTAssertTrue(store.attentionHasMore)
        XCTAssertEqual(store.totalInputRequired, 2)
        XCTAssertEqual(store.totalUnseen, 3)
        XCTAssertTrue(store.attentionVerified)
        XCTAssertTrue(store.delegationsVerified)
        XCTAssertFalse(store.initialLoading)
    }

    // MARK: - Independent section errors

    func testNodeErrorDoesNotBlockAttention() async {
        client.nodesResponse = { throw serverError("nodes down") }
        client.attentionResponse = {
            AttentionResponse(total_running: 0, total_input_required: 0, total_unseen: 0,
                              nodes: [], input_required: [], inbox: [makeInboxItem()], has_more: false)
        }
        client.delegationsResponse = { DelegationsResponse(delegations: [makeDelegation()]) }
        await store.refresh()
        XCTAssertNotNil(store.nodeError)
        XCTAssertFalse(store.nodesVerified)
        XCTAssertTrue(store.attentionVerified)
        XCTAssertTrue(store.delegationsVerified)
    }

    func testAttentionErrorDoesNotBlockNodes() async {
        client.nodesResponse = { NodesResponse(nodes: [makeNode()], resolver_error: nil) }
        client.attentionResponse = { throw serverError("attention down") }
        await store.refresh()
        XCTAssertTrue(store.nodesVerified)
        XCTAssertFalse(store.attentionVerified)
        XCTAssertNotNil(store.attentionError)
    }

    // MARK: - Auth purge

    func testAuthPurgeClearsAllPrivateState() async {
        client.nodesResponse = { NodesResponse(nodes: [makeNode()], resolver_error: nil) }
        client.attentionResponse = {
            AttentionResponse(total_running: 1, total_input_required: 1, total_unseen: 1,
                              nodes: [makeAttentionNode()],
                              input_required: [makeInputRequired()],
                              inbox: [makeInboxItem()], has_more: false)
        }
        client.delegationsResponse = { DelegationsResponse(delegations: [makeDelegation()]) }
        await store.refresh()
        XCTAssertEqual(store.nodes.count, 1)

        client.nodesResponse = { throw authError() }
        await store.refresh()

        XCTAssertTrue(store.unauthorized)
        XCTAssertTrue(store.nodes.isEmpty)
        XCTAssertTrue(store.attentionNodes.isEmpty)
        XCTAssertTrue(store.delegations.isEmpty)
        XCTAssertFalse(store.nodesVerified)
        XCTAssertTrue(store.nodeError!.contains("authorization expired"))
    }

    func test403AlsoPurges() async {
        client.nodesResponse = { NodesResponse(nodes: [makeNode()], resolver_error: nil) }
        await store.refresh()
        client.attentionResponse = { throw authError(403) }
        await store.refresh()
        XCTAssertTrue(store.unauthorized)
    }

    func testPurgeOnUnauthorizedIsIdempotent() {
        store.purgeOnUnauthorized()
        XCTAssertTrue(store.unauthorized)
        store.purgeOnUnauthorized() // no-op
        XCTAssertTrue(store.unauthorized)
    }

    func testAuthPurgePreventsSubsequentRefresh() async {
        client.nodesResponse = { throw authError() }
        await store.refresh()
        client.listNodesCalls = 0
        await store.refresh()
        XCTAssertEqual(client.listNodesCalls, 0)
    }

    // MARK: - resumeAfterAuthentication

    func testResumeRestoresPolling() async {
        client.nodesResponse = { throw authError() }
        await store.refresh()
        XCTAssertTrue(store.unauthorized)

        client.nodesResponse = { NodesResponse(nodes: [makeNode()], resolver_error: nil) }
        await store.resumeAfterAuthentication()
        XCTAssertFalse(store.unauthorized)
        // start() fires panel tasks; let them settle.
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertGreaterThanOrEqual(client.listNodesCalls, 2)
    }

    func testResumeClearsRecentAuthRequired() async {
        client.removeCredentialResponse = { throw authError(403) }
        await store.removeCredential(recordID: "r1")
        XCTAssertTrue(store.recentAuthRequired)
        client.nodesResponse = { NodesResponse(nodes: [], resolver_error: nil) }
        await store.resumeAfterAuthentication()
        XCTAssertFalse(store.recentAuthRequired)
    }

    // MARK: - Epoch does NOT invalidate mutations

    func testMutationSurvivesPollCycle() async {
        // A poll launching new panel tasks must not invalidate an in-flight mutation.
        client.nodesResponse = { NodesResponse(nodes: [makeNode()], resolver_error: nil) }
        await store.refresh()

        // Simulate a slow clear that outlasts a poll.
        var clearReturned = false
        client.clearAttentionResponse = {
            try? await Task.sleep(nanoseconds: 50_000_000)
            clearReturned = true
            return ClearAttentionResponse(cleared: 1, failed: 0)
        }
        client.attentionResponse = {
            AttentionResponse(total_running: 0, total_input_required: 0, total_unseen: 0,
                              nodes: [], input_required: [], inbox: [], has_more: false)
        }

        await store.clearAttention()
        // clearAttention should have completed and cleaned up, not been
        // abandoned by a generation bump.
        XCTAssertTrue(clearReturned)
        XCTAssertFalse(store.clearingAttention, "defer cleanup must run")
    }

    func testNodeOperationDeferCleansUpAfterAuthPurge() async {
        // If auth purge happens during a mutation, purge resets busy flag.
        // Defer skips (epoch changed) but purge already set .idle.
        client.testNodeResponse = {
            throw authError()
        }
        await store.testNode(NodeFormData(name: "X", url: "https://x.test", token: "t"))
        XCTAssertTrue(store.unauthorized)
        XCTAssertEqual(store.nodeOperation, .idle, "purge must reset to idle")
    }

    func testDelayedLogoutAfterReauthDoesNotPurgeNewSession() async {
        // Scenario: signOut starts (slow logout), user reauths quickly on
        // another path, old logout response arrives — must NOT purge new session.
        client.nodesResponse = { NodesResponse(nodes: [makeNode()], resolver_error: nil) }
        await store.refresh()

        // Slow logout that completes after reauth.
        client.logoutResponse = {
            try? await Task.sleep(nanoseconds: 200_000_000)
            return RedirectResponse(ok: true, redirect: "/login")
        }

        let logoutTask = Task { await self.store.signOut() }
        // Give logout time to start the network call.
        try? await Task.sleep(nanoseconds: 50_000_000)

        // User reauths — this advances epoch.
        client.nodesResponse = { NodesResponse(nodes: [makeNode(id: "fresh")], resolver_error: nil) }
        await store.resumeAfterAuthentication()
        // Let the new session populate.
        try? await Task.sleep(nanoseconds: 50_000_000)

        // Old logout completes.
        _ = await logoutTask.value
        store.dispose()

        // New session must NOT have been purged by the old logout.
        XCTAssertFalse(store.unauthorized,
                       "Delayed old logout must not purge new session after reauth")
    }

    func testOldMutationDeferCannotClearNewOperation() async {
        // Old testNode in-flight during purge+reauth. NEW testNode blocks
        // (via gate) so it's still .testing when OLD completes. Old defer
        // must NOT reset .idle — it's a different epoch.
        let okStatus = HubNodeStatus(
            reachable: true, state: "ok", latency_ms: 1, version: "1",
            agent: "a", capabilities: nil, details: nil, error: nil)

        // Gate: new testNode blocks here until we release it.
        var releaseNew: CheckedContinuation<Void, Never>?

        client.testNodeResponse = {
            // OLD call — slow.
            try? await Task.sleep(nanoseconds: 200_000_000)
            return TestNodeResponse(status: okStatus)
        }

        // Start old testNode.
        let oldTest = Task { await self.store.testNode(
            NodeFormData(name: "Old", url: "https://old.test", token: "t")) }
        try? await Task.sleep(nanoseconds: 50_000_000)

        // Purge + reauth (advances epoch, resets nodeOperation).
        store.purgeOnUnauthorized()
        client.nodesResponse = { NodesResponse(nodes: [], resolver_error: nil) }
        await store.resumeAfterAuthentication()
        try? await Task.sleep(nanoseconds: 50_000_000)

        // New testNode: blocks on gate so it stays .testing.
        client.testNodeResponse = {
            await withCheckedContinuation { cont in
                releaseNew = cont
            }
            return TestNodeResponse(status: okStatus)
        }
        let newTest = Task { await self.store.testNode(
            NodeFormData(name: "New", url: "https://new.test", token: "t")) }
        try? await Task.sleep(nanoseconds: 50_000_000)

        // Wait for old to finish — its defer fires now.
        await oldTest.value

        // New is still in-flight (.testing). Old defer must NOT have reset it.
        XCTAssertEqual(store.nodeOperation, .testing,
                       "Old defer must not clear new operation to .idle")

        // Release new testNode to complete.
        releaseNew?.resume()
        await newTest.value
        XCTAssertEqual(store.nodeOperation, .idle)
    }

    func testResumeResetsBusyFlagsForNewOperations() async {
        // If an operation was in-flight when resume happens (without prior
        // purge), resume must reset busy flags so new operations aren't blocked.
        client.testNodeResponse = {
            try? await Task.sleep(nanoseconds: 300_000_000)
            return TestNodeResponse(status: HubNodeStatus(
                reachable: true, state: "ok", latency_ms: 1, version: "1",
                agent: "a", capabilities: nil, details: nil, error: nil))
        }

        // Start a slow testNode.
        let oldOp = Task { await self.store.testNode(
            NodeFormData(name: "Slow", url: "https://slow.test", token: "t")) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.nodeOperation, .testing)

        // Resume (no prior purge) — resets all busy flags.
        client.nodesResponse = { NodesResponse(nodes: [], resolver_error: nil) }
        await store.resumeAfterAuthentication()
        XCTAssertEqual(store.nodeOperation, .idle,
                       "resume must reset nodeOperation so new ops can start")
        XCTAssertFalse(store.securityLoading)
        XCTAssertNil(store.securityOperation)
        XCTAssertFalse(store.clearingAttention)

        // New operation must be able to start.
        client.testNodeResponse = {
            TestNodeResponse(status: HubNodeStatus(
                reachable: true, state: "ok", latency_ms: 1, version: "1",
                agent: "a", capabilities: nil, details: nil, error: nil))
        }
        await store.testNode(NodeFormData(name: "New", url: "https://new.test", token: "t"))
        XCTAssertEqual(store.nodeOperation, .idle)
        XCTAssertTrue(store.nodeOperationResult!.contains("✓"))

        await oldOp.value
        store.dispose()
    }

    // MARK: - authEpoch exposure

    func testAuthEpochAdvancesOnPurge() {
        let before = store.authEpoch
        store.purgeOnUnauthorized()
        XCTAssertGreaterThan(store.authEpoch, before)
    }

    func testAuthEpochAdvancesOnResume() async {
        store.purgeOnUnauthorized()
        let afterPurge = store.authEpoch
        client.nodesResponse = { NodesResponse(nodes: [], resolver_error: nil) }
        await store.resumeAfterAuthentication()
        XCTAssertGreaterThan(store.authEpoch, afterPurge)
    }

    // MARK: - Attention limit sent to client

    func testRefreshSendsAttentionLimit() async {
        await store.refresh()
        XCTAssertEqual(client.listAttentionLimits.last, HubStore.defaultAttentionLimit)
    }

    func testLoadMoreDoublesLimitAndSendsIt() async {
        client.attentionResponse = {
            AttentionResponse(total_running: 0, total_input_required: 0, total_unseen: 50,
                              nodes: [], input_required: [], inbox: [], has_more: true)
        }
        await store.refresh()
        XCTAssertEqual(client.listAttentionLimits.last, 20)

        await store.loadMoreAttention()
        XCTAssertEqual(store.attentionLimit, 40)
        XCTAssertEqual(client.listAttentionLimits.last, 40)
    }

    func testLoadMoreClampsAtMax() async {
        client.attentionResponse = {
            AttentionResponse(total_running: 0, total_input_required: 0, total_unseen: 0,
                              nodes: [], input_required: [], inbox: [], has_more: true)
        }
        for _ in 0..<20 {
            await store.refresh()
            await store.loadMoreAttention()
        }
        XCTAssertLessThanOrEqual(store.attentionLimit, HubStore.maxAttentionLimit)
    }

    // MARK: - Delayed read > poll coalesce

    func testSlowPanelDoesNotBlockOthers() async {
        // Nodes takes 200ms; attention and delegations return instantly.
        // All three should complete; nodes being slow doesn't block the others.
        client.nodesResponse = {
            try? await Task.sleep(nanoseconds: 200_000_000)
            return NodesResponse(nodes: [makeNode()], resolver_error: nil)
        }
        client.attentionResponse = {
            AttentionResponse(total_running: 0, total_input_required: 0, total_unseen: 1,
                              nodes: [], input_required: [], inbox: [makeInboxItem()], has_more: false)
        }
        client.delegationsResponse = { DelegationsResponse(delegations: [makeDelegation()]) }

        await store.refresh()

        XCTAssertTrue(store.nodesVerified)
        XCTAssertTrue(store.attentionVerified)
        XCTAssertTrue(store.delegationsVerified)
    }

    func testLongPollChangeTriggersRefresh() async {
        let refreshed = expectation(description: "change-driven refresh")
        var released = false
        client.changesResponse = { since in
            switch since {
            case nil: return HubChangesResponse(version: 0)
            case 0?: return HubChangesResponse(version: 1)
            default:
                // Park until the store is disposed.
                while !Task.isCancelled { try? await Task.sleep(nanoseconds: 10_000_000) }
                throw CancellationError()
            }
        }
        client.attentionResponse = {
            if self.client.listAttentionCalls == 2, !released { released = true; refreshed.fulfill() }
            return AttentionResponse(total_running: 0, total_input_required: 0, total_unseen: 0,
                                     nodes: [], input_required: [], inbox: [], has_more: false)
        }
        store.start()
        defer { store.dispose() }
        // pollInterval is 999s: only the change feed can cause the second fetch.
        await fulfillment(of: [refreshed], timeout: 5)
    }

    func testEarlyUnchangedLongPollDoesNotSpin() async {
        // A server/proxy that answers "no change" instantly must not busy-loop.
        var changesCalls = 0
        client.changesResponse = { _ in
            changesCalls += 1
            return HubChangesResponse(version: 7)
        }
        store = HubStore(client: client, pollInterval: 0.2)
        store.start()
        defer { store.dispose() }
        try? await Task.sleep(nanoseconds: 500_000_000)
        // Baseline + about one call per 0.2s interval; a spin would be thousands.
        XCTAssertLessThanOrEqual(changesCalls, 6)
        XCTAssertGreaterThanOrEqual(changesCalls, 2)
    }

    func testSuspendPollingStopsAndResumeRestarts() async {
        var changesCalls = 0
        client.changesResponse = { _ in
            changesCalls += 1
            return HubChangesResponse(version: 1)
        }
        store = HubStore(client: client, pollInterval: 0.05)
        store.start()
        defer { store.dispose() }
        try? await Task.sleep(nanoseconds: 200_000_000)
        store.suspendPolling()
        try? await Task.sleep(nanoseconds: 50_000_000)
        let suspendedAt = changesCalls
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(changesCalls, suspendedAt, "No polling while suspended")
        store.resumePolling()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertGreaterThan(changesCalls, suspendedAt, "Polling resumes")
    }

    func testPollCoalescesWithInFlightRead() async {
        let started = expectation(description: "initial nodes request started")
        var nodesFetchCount = 0
        var releases: [CheckedContinuation<Void, Never>] = []
        client.nodesResponse = {
            nodesFetchCount += 1
            if nodesFetchCount == 1 { started.fulfill() }
            // Hold every request until cleanup: elapsed wall time must never
            // accidentally finish the initial request and permit a valid poll.
            await withCheckedContinuation { releases.append($0) }
            return NodesResponse(nodes: [makeNode()], resolver_error: nil)
        }
        store = HubStore(client: client, pollInterval: 0.05)
        defer {
            store.dispose()
            for release in releases { release.resume() }
        }
        store.start()
        await fulfillment(of: [started], timeout: 2)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertGreaterThan(client.listAttentionCalls, 1, "Other panels must continue polling")
        XCTAssertTrue(store.nodesLoading, "The initial nodes request is still held open")
        XCTAssertEqual(nodesFetchCount, 1, "Poll should coalesce with in-flight read")
    }

    // MARK: - Panel task race regression

    func testRefreshDoesNotOverwriteWithStaleData() async {
        // Scenario: slow first fetch completes after refresh() launches a fast
        // second fetch. The old task's stale response must be discarded.
        var callCount = 0
        client.nodesResponse = {
            callCount += 1
            if callCount == 1 {
                // Slow first call — delays, then returns stale data.
                try? await Task.sleep(nanoseconds: 300_000_000)
                return NodesResponse(nodes: [makeNode(id: "stale")], resolver_error: nil)
            } else {
                // Fast second call — returns fresh data immediately.
                return NodesResponse(nodes: [makeNode(id: "fresh")], resolver_error: nil)
            }
        }

        // Launch first fetch via start().
        store.start()
        // Give it time to begin the slow call.
        try? await Task.sleep(nanoseconds: 50_000_000)
        // Manual refresh cancels old task and launches a new one.
        await store.refresh()

        // Fresh data must win; stale must be discarded.
        XCTAssertEqual(store.nodes.first?.id, "fresh",
                       "Stale response from cancelled task must not overwrite fresh data")
    }

    func testCancelledTaskDoesNotClearNewTaskRefs() async {
        // The old task's completion block must not nil out nodesTask or clear
        // nodesLoading when a newer task is in flight.
        var callCount = 0
        client.nodesResponse = {
            callCount += 1
            if callCount == 1 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                return NodesResponse(nodes: [makeNode(id: "old")], resolver_error: nil)
            } else {
                // Second call also takes time — we check state while it's running.
                try? await Task.sleep(nanoseconds: 200_000_000)
                return NodesResponse(nodes: [makeNode(id: "new")], resolver_error: nil)
            }
        }

        store.start()
        try? await Task.sleep(nanoseconds: 50_000_000)

        // Refresh replaces the panel tasks.
        // Don't await — we want to inspect state while the new task is in flight.
        let refreshTask = Task { await self.store.refresh() }
        try? await Task.sleep(nanoseconds: 50_000_000)

        // The new task should still be in-flight; nodesLoading must remain true.
        XCTAssertTrue(store.nodesLoading,
                      "Old cancelled task must not clear nodesLoading for the new task")

        await refreshTask.value
        store.dispose()
    }

    // MARK: - Clear attention

    func testClearAttentionSuccess() async {
        client.attentionResponse = {
            AttentionResponse(total_running: 0, total_input_required: 0, total_unseen: 1,
                              nodes: [], input_required: [], inbox: [makeInboxItem()], has_more: false)
        }
        await store.refresh()

        client.clearAttentionResponse = { ClearAttentionResponse(cleared: 1, failed: 0) }
        client.attentionResponse = {
            AttentionResponse(total_running: 0, total_input_required: 0, total_unseen: 0,
                              nodes: [], input_required: [], inbox: [], has_more: false)
        }
        await store.clearAttention()
        XCTAssertFalse(store.clearingAttention)
        XCTAssertTrue(store.inbox.isEmpty)
    }

    func testClearAttentionPartialFailure() async {
        client.attentionResponse = {
            AttentionResponse(total_running: 0, total_input_required: 0, total_unseen: 2,
                              nodes: [], input_required: [],
                              inbox: [makeInboxItem(), makeInboxItem(sessionID: "s2", seq: 2)],
                              has_more: false)
        }
        await store.refresh()
        client.clearAttentionResponse = { ClearAttentionResponse(cleared: 1, failed: 1) }
        await store.clearAttention()
        XCTAssertTrue(store.attentionClearStatus!.contains("1 could not be cleared"))
    }

    func testClearAttentionRequiresVerified() async {
        await store.clearAttention()
        XCTAssertEqual(client.clearAttentionCalls, 0)
    }

    // MARK: - Mark seen

    func testMarkSeenSuccess() async {
        let item = makeInboxItem()
        client.attentionResponse = {
            AttentionResponse(total_running: 0, total_input_required: 0, total_unseen: 1,
                              nodes: [], input_required: [], inbox: [item], has_more: false)
        }
        await store.refresh()
        client.attentionResponse = {
            AttentionResponse(total_running: 0, total_input_required: 0, total_unseen: 0,
                              nodes: [], input_required: [], inbox: [], has_more: false)
        }
        await store.markInboxItemSeen(item)
        XCTAssertEqual(client.markSeenCalls.count, 1)
        XCTAssertTrue(store.markingSeen.isEmpty)
    }

    func testMarkSeenRequiresStoreInstanceID() async {
        await store.refresh()
        await store.markInboxItemSeen(makeInboxItem(storeInstanceID: nil))
        XCTAssertEqual(client.markSeenCalls.count, 0)
    }

    // MARK: - Inbox item key

    func testInboxItemKey() {
        let item = makeInboxItem(nodeID: "n1", sessionID: "s1", storeInstanceID: "si1", seq: 42)
        XCTAssertEqual(HubStore.inboxItemKey(item), "si1\0s1\042")
        let noStore = makeInboxItem(nodeID: "n1", sessionID: "s1", storeInstanceID: nil, seq: 1)
        XCTAssertTrue(HubStore.inboxItemKey(noStore).hasPrefix("n1\0"))
    }

    // MARK: - Node operations

    func testTestNodeSuccess() async {
        await store.testNode(NodeFormData(name: "N", url: "https://n.test", token: "t"))
        XCTAssertTrue(store.nodeOperationResult!.contains("✓ Reachable"))
        XCTAssertEqual(store.nodeOperation, .idle)
    }

    func testTestNodeUnreachable() async {
        client.testNodeResponse = {
            TestNodeResponse(status: HubNodeStatus(
                reachable: false, state: "unreachable", latency_ms: 0, version: nil,
                agent: nil, capabilities: nil, details: nil, error: "connection refused"))
        }
        await store.testNode(NodeFormData(name: "Bad", url: "https://bad.test", token: "t"))
        XCTAssertTrue(store.nodeOperationResult!.contains("✗"))
    }

    func testAddNodeClean() async {
        client.nodesResponse = { NodesResponse(nodes: [makeNode()], resolver_error: nil) }
        let clean = await store.addNode(NodeFormData(name: "New", url: "https://new.test", token: "t"))
        XCTAssertTrue(clean)
        XCTAssertEqual(store.nodeOperation, .idle)
    }

    func testAddNodeWithWarning() async {
        client.addNodeResponse = { AddNodeResponse(id: "new-1", warning: "duplicate") }
        client.nodesResponse = { NodesResponse(nodes: [makeNode()], resolver_error: nil) }
        let clean = await store.addNode(NodeFormData(name: "D", url: "https://d.test", token: "t"))
        XCTAssertFalse(clean)
        XCTAssertTrue(store.nodeOperationResult!.contains("warning"))
    }

    func testRemoveNodeSuccess() async {
        client.nodesResponse = { NodesResponse(nodes: [], resolver_error: nil) }
        await store.removeNode(id: "node-1")
        XCTAssertEqual(client.removeNodeCalls, ["node-1"])
        XCTAssertEqual(store.nodeOperation, .idle)
    }

    func testRemoveNodeError() async {
        client.removeNodeResponse = { throw serverError("not found") }
        await store.removeNode(id: "gone")
        XCTAssertTrue(store.nodeError!.contains("Could not remove"))
        XCTAssertEqual(store.nodeOperation, .idle)
    }

    // MARK: - Reorder nodes

    func testReorderAppliesOptimisticallyAndSaves() async throws {
        client.nodesResponse = {
            NodesResponse(nodes: [makeNode(id: "a"), makeNode(id: "b"), makeNode(id: "c")],
                          resolver_error: nil)
        }
        await store.refresh()
        try await store.reorderNodes(orderedIDs: ["c", "a", "b"])
        XCTAssertEqual(client.reorderNodesCalls.count, 1)
        XCTAssertEqual(store.nodes.map(\.id), ["c", "a", "b"])
    }

    func testReorderEmptyNoop() async throws {
        client.nodesResponse = { NodesResponse(nodes: [makeNode(id: "a")], resolver_error: nil) }
        await store.refresh()
        try await store.reorderNodes(orderedIDs: [])
        XCTAssertEqual(client.reorderNodesCalls.count, 0)
    }

    func testReorderUnchangedNoop() async throws {
        client.nodesResponse = {
            NodesResponse(nodes: [makeNode(id: "a"), makeNode(id: "b")], resolver_error: nil)
        }
        await store.refresh()
        try await store.reorderNodes(orderedIDs: ["a", "b"])
        XCTAssertEqual(client.reorderNodesCalls.count, 0)
    }

    func testReorderDuplicateIDsRejected() async throws {
        client.nodesResponse = {
            NodesResponse(nodes: [makeNode(id: "a"), makeNode(id: "b")], resolver_error: nil)
        }
        await store.refresh()
        try await store.reorderNodes(orderedIDs: ["a", "a"])
        XCTAssertEqual(client.reorderNodesCalls.count, 0)
    }

    func testReorderMismatchedSetRejected() async throws {
        client.nodesResponse = {
            NodesResponse(nodes: [makeNode(id: "a"), makeNode(id: "b")], resolver_error: nil)
        }
        await store.refresh()
        try await store.reorderNodes(orderedIDs: ["a", "c"])
        XCTAssertEqual(client.reorderNodesCalls.count, 0)
    }

    func testReorderSendsMinimalDiff() async throws {
        client.nodesResponse = {
            NodesResponse(nodes: ["a", "b", "c", "d"].map { makeNode(id: $0) }, resolver_error: nil)
        }
        await store.refresh()
        try await store.reorderNodes(orderedIDs: ["a", "c", "b", "d"])
        XCTAssertEqual(client.reorderNodesCalls.first, ["c", "b"])
    }

    func testReorder404ThrowsChangedElsewhere() async throws {
        client.nodesResponse = {
            NodesResponse(nodes: [makeNode(id: "a"), makeNode(id: "b")], resolver_error: nil)
        }
        await store.refresh()
        client.reorderNodesResponse = { throw HubAPIError(status: 404, message: "not found", type: "") }
        do {
            try await store.reorderNodes(orderedIDs: ["b", "a"])
            XCTFail("Expected error")
        } catch let error as HubStoreError {
            XCTAssertEqual(error, .nodesChangedElsewhere)
        }
    }

    func testReorderSerialized() async throws {
        client.nodesResponse = {
            NodesResponse(nodes: [makeNode(id: "a"), makeNode(id: "b"), makeNode(id: "c")],
                          resolver_error: nil)
        }
        await store.refresh()
        try await store.reorderNodes(orderedIDs: ["c", "b", "a"])
        XCTAssertEqual(client.reorderNodesCalls.count, 1)
    }

    func testReorderRollbackRestoresServerOrder() async {
        // Server has [a, b, c]. We optimistically reorder to [c, b, a] but
        // the server rejects it. The rollback fetch must show [a, b, c] —
        // NOT preserve the failed optimistic [c, b, a].
        let serverOrder = ["a", "b", "c"]
        client.nodesResponse = {
            NodesResponse(nodes: serverOrder.map { makeNode(id: $0) }, resolver_error: nil)
        }
        await store.refresh()
        XCTAssertEqual(store.nodes.map(\.id), ["a", "b", "c"])

        client.reorderNodesResponse = { throw serverError("conflict") }
        // The rollback fetch returns the original server order.
        // (nodesResponse already returns [a, b, c].)

        do {
            try await store.reorderNodes(orderedIDs: ["c", "b", "a"])
            XCTFail("Expected reorderFailed error")
        } catch {
            // Expected.
        }
        // After rollback fetch, nodes must be in the server's authoritative
        // order, not the failed optimistic order.
        XCTAssertEqual(store.nodes.map(\.id), ["a", "b", "c"],
                       "Rollback must restore server order, not preserve failed optimistic order")
    }

    // MARK: - Registration

    func testLoadRegistrationInfo() async {
        await store.loadRegistrationInfo()
        XCTAssertEqual(store.registrationInfo?.enabled, true)
        XCTAssertEqual(store.registrationInfo?.token_configured, true)
        XCTAssertEqual(store.registrationInfo?.can_persist_nodes, true)
        XCTAssertFalse(store.registrationLoading)
    }

    func testClearRegistrationInfo() async {
        await store.loadRegistrationInfo()
        store.clearRegistrationInfo()
        XCTAssertNil(store.registrationInfo)
    }

    func testOldRegistrationLoadDoesNotStompNewLoad() async {
        // Scenario: slow load in-flight, clearRegistrationInfo called,
        // new load starts. Old defer/result must not overwrite new state.
        var callCount = 0
        client.registrationInfoResponse = {
            callCount += 1
            if callCount == 1 {
                // Old load — slow, returns stale info.
                try? await Task.sleep(nanoseconds: 200_000_000)
                return RegistrationInfoResponse(enabled: false, token_configured: nil,
                                                can_persist_nodes: nil, registration_token: nil)
            } else {
                // New load — fast, returns fresh info.
                return RegistrationInfoResponse(enabled: true, token_configured: true,
                                                can_persist_nodes: true, registration_token: "fresh")
            }
        }

        // Start slow old load.
        let oldLoad = Task { await self.store.loadRegistrationInfo() }
        try? await Task.sleep(nanoseconds: 50_000_000)

        // Clear + new load (bumps registration token).
        store.clearRegistrationInfo()
        await store.loadRegistrationInfo()

        // New load completed with fresh data.
        XCTAssertEqual(store.registrationInfo?.registration_token, "fresh")
        XCTAssertFalse(store.registrationLoading)

        // Old load finishes — must not overwrite.
        await oldLoad.value
        XCTAssertEqual(store.registrationInfo?.registration_token, "fresh",
                       "Old load must not overwrite new registration info")
        XCTAssertFalse(store.registrationLoading,
                       "Old defer must not stomp new registrationLoading")
    }

    // MARK: - Security / session

    func testAttentionLoadMoreStopsAtMaximumWithExplicitState() async {
        client.attentionResponse = { AttentionResponse(total_running: 0, total_input_required: 0, total_unseen: 600, nodes: [], input_required: [], inbox: [], has_more: true) }
        await store.refresh()
        for _ in 0..<6 { await store.loadMoreAttention() }
        XCTAssertEqual(store.attentionLimit, 500)
        XCTAssertTrue(store.attentionHasMore)
        XCTAssertFalse(store.canLoadMoreAttention)
        let calls = client.listAttentionCalls
        await store.loadMoreAttention()
        XCTAssertEqual(client.listAttentionCalls, calls)
    }

    func testLoadSecurity() async {
        client.listCredentialsResponse = {
            CredentialsResponse(credentials: [
                HubCredential(record_id: "r1", display_name: "Key 1", transports: ["usb"],
                              created_at: "2024-01-01", last_used_at: "2024-06-01")
            ])
        }
        client.sessionResponse = {
            HubSessionResponse(administrator: "admin", session: [:],
                                recently_authenticated: true, active_sessions: 3)
        }
        await store.loadSecurity()
        XCTAssertEqual(store.credentials.count, 1)
        XCTAssertEqual(store.activeSessions, 3)
        XCTAssertFalse(store.securityLoading)
    }

    func testLoadSecurityBearerSkipsCredentials() async {
        store.setAuthMode(.bearer)
        await store.loadSecurity()
        XCTAssertEqual(client.listCredentialsCalls, 0)
        XCTAssertEqual(client.sessionCalls, 1)
    }

    func testLoadSecurityNoneSkipsCredentials() async {
        store.setAuthMode(.none)
        client.sessionResponse = {
            HubSessionResponse(administrator: "admin", session: [:],
                                recently_authenticated: false, active_sessions: 0)
        }
        await store.loadSecurity()
        XCTAssertEqual(client.listCredentialsCalls, 0)
    }

    func testRenameCredential() async {
        await store.renameCredential(recordID: "r1", displayName: "New")
        XCTAssertEqual(store.securityStatus, "Passkey renamed.")
        XCTAssertNil(store.securityOperation)
    }

    func testSecurityMutationRefreshFailureIsNotHiddenBySuccess() async {
        client.sessionResponse = { throw serverError("Security refresh unavailable") }
        await store.renameCredential(recordID: "r1", displayName: "New")
        XCTAssertEqual(store.securityStatus, "Security refresh unavailable")
        XCTAssertNil(store.securityOperation)
        XCTAssertEqual(client.sessionCalls, 1)
    }

    func testExplicitSecurityRefreshClearsPreviousSuccess() async {
        await store.renameCredential(recordID: "r1", displayName: "New")
        XCTAssertEqual(store.securityStatus, "Passkey renamed.")
        await store.loadSecurity()
        XCTAssertNil(store.securityStatus)
    }

    func testRemoveCredentialSuccess() async {
        await store.removeCredential(recordID: "r1")
        XCTAssertEqual(store.securityStatus, "Passkey removed.")
        XCTAssertFalse(store.recentAuthRequired)
    }

    func testRemoveCredential403PurgesAndSetsRecentAuth() async {
        client.removeCredentialResponse = {
            throw HubAPIError(status: 403, message: "recent auth required", type: "recent_auth_required")
        }
        await store.removeCredential(recordID: "r1")
        XCTAssertTrue(store.unauthorized)
        XCTAssertTrue(store.recentAuthRequired)
        XCTAssertTrue(store.securityStatus!.contains("browser"))
    }

    func testRemoveCredential401PurgesWithoutRecentAuth() async {
        client.removeCredentialResponse = { throw authError(401) }
        await store.removeCredential(recordID: "r1")
        XCTAssertTrue(store.unauthorized)
        XCTAssertFalse(store.recentAuthRequired)
    }

    func testRevokeOtherSessions() async {
        await store.revokeOtherSessions()
        XCTAssertEqual(store.securityStatus, "Revoked 3 other sessions.")
    }

    func testSignOut() async {
        let redirect = await store.signOut()
        XCTAssertEqual(redirect, "/login")
        XCTAssertTrue(store.unauthorized)
    }

    func testSignOutError() async {
        client.logoutResponse = { throw serverError("network") }
        let redirect = await store.signOut()
        XCTAssertNil(redirect)
        XCTAssertNotNil(store.securityStatus)
    }

    // MARK: - Auth mode

    func testSetAuthMode() {
        XCTAssertEqual(store.authMode, .passkey)
        store.setAuthMode(.bearer)
        XCTAssertEqual(store.authMode, .bearer)
    }

    // MARK: - Computed

    func testActiveSessionCount() async {
        client.nodesResponse = {
            NodesResponse(nodes: [makeNode(id: "a", activeSessions: 3),
                                  makeNode(id: "b", activeSessions: 2)], resolver_error: nil)
        }
        await store.refresh()
        XCTAssertEqual(store.activeSessionCount, 5)
    }

    func testActiveDelegationCount() async {
        client.delegationsResponse = {
            DelegationsResponse(delegations: [
                makeDelegation(id: "d1", status: "running"),
                makeDelegation(id: "d2", status: "succeeded"),
                makeDelegation(id: "d3", status: "pending"),
            ])
        }
        await store.refresh()
        XCTAssertEqual(store.activeDelegationCount, 2)
    }

    // MARK: - Lifecycle

    func testStartIsIdempotent() {
        store.start()
        store.start()
        store.dispose()
    }

    func testStartAfterDispose() {
        store.dispose()
        store.start()
        XCTAssertEqual(client.listNodesCalls, 0)
    }

    func testStartGuardedByUnauthorized() {
        store.purgeOnUnauthorized()
        store.start()
        XCTAssertEqual(client.listNodesCalls, 0)
    }

    func testDisposeStopsUpdates() async {
        store.dispose()
        await store.refresh()
        XCTAssertTrue(store.nodes.isEmpty)
    }
}
