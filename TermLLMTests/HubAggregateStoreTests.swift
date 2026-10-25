import Combine
import XCTest
@testable import TermLLM

@MainActor
final class HubAggregateStoreTests: XCTestCase {
    private func connection(_ name: String, kind: HubConnection.Kind = .hub) -> HubConnection {
        HubConnection(id: UUID(), name: name, kind: kind, url: URL(string: "https://example.com/\(name)/")!)
    }
    private func nodes(_ connection: HubConnection) -> NodesResponse {
        let root = connection.mountPath + (connection.kind == .hub ? "node/shared/" : "")
        let session = HubNodeSession(id: "session-shared", number: 7, short_title: "Shared session", long_title: nil,
                                     pinned: false, active_run: true, interaction_required: false,
                                     pending_interaction_count: nil, pending_interaction_kinds: nil,
                                     last_message_at: nil, message_count: nil, resume_path: root + "chat/7")
        let sessions = HubNodeSessions(count_label: "1 active", has_more: false, active_count: 1,
                                       input_required_count: 0, unseen_count: 1, attention_capability: nil,
                                       attention_last_success_at: nil, active: [session], recent: [session], resume_path: root)
        let node = HubNode(id: "shared", name: "Shared", source: "fixture", connection: "http", url: "http://10.99.0.1/private/",
                           base_path: "", proxy_path: root, new_session_path: root + "?new=1", has_token: false,
                           status: HubNodeStatus(reachable: true, state: "ok", latency_ms: 1, version: nil, agent: nil,
                                                 capabilities: nil, details: nil, error: nil), sessions: sessions, diagnostics: nil)
        return NodesResponse(nodes: [node], resolver_error: nil)
    }
    private func attention(_ connection: HubConnection) -> AttentionResponse {
        let root = connection.mountPath + (connection.kind == .hub ? "node/shared/" : "")
        return AttentionResponse(total_running: 1, total_input_required: 1, total_unseen: 1, nodes: [],
                                 input_required: [HubInputRequiredItem(node_id: "shared", node_name: "Shared", session_id: "session-shared", session_number: 7,
                                                                       title: "Input", pending_interaction_count: 1, pending_interaction_kinds: ["question"],
                                                                       required_since: nil, resume_path: root + "chat/7", stale: false)],
                                 inbox: [HubAttentionInboxItem(node_id: "shared", node_name: "Shared", session_id: "session-shared", store_instance_id: "store-shared",
                                                               session_number: 7, title: "Unseen", outcome: "completed", terminal_at: nil, attention_seq: 1,
                                                               resume_path: root + "chat/7")], has_more: false)
    }
    private func drain() async {
        for _ in 0..<30 { await Task.yield() }
    }
    func testAttentionBadgeUsesServerTotalsNotTheLoadedWindow() async throws {
        let connection = connection("work")
        let client = MockHubClient()
        client.attentionResponse = {
            AttentionResponse(total_running: 12, total_input_required: 3, total_unseen: 50,
                              nodes: [], input_required: [], inbox: [], has_more: true)
        }
        let aggregate = HubAggregateStore { connection in
            HubSourceWorkspace(connection: connection, store: HubStore(client: client, pollInterval: 999))
        }
        aggregate.synchronize([connection])
        XCTAssertNil(aggregate.attentionBadgeCount, "Loading is not evidence for clearing a saved system badge")
        await aggregate.refreshAndWait()
        XCTAssertEqual(aggregate.attentionBadgeCount, 53)
        XCTAssertTrue(aggregate.attention.isEmpty, "The badge uses totals, even when the loaded window differs")
        client.attentionResponse = { throw URLError(.notConnectedToInternet) }
        await aggregate.refreshAndWait()
        XCTAssertEqual(aggregate.attentionBadgeCount, 53, "Offline refresh retains last verified totals")
        try XCTUnwrap(aggregate.sources.first).store.purgeOnUnauthorized()
        XCTAssertEqual(aggregate.attentionBadgeCount, 0, "Revoked sources do not contribute private attention")
        aggregate.synchronize([])
        XCTAssertEqual(aggregate.attentionBadgeCount, 0)
    }

    func testAttentionBadgeAggregatesSourcesAndSafelyBoundsServerCounts() async {
        let work = connection("work"), home = connection("home")
        let aggregate = HubAggregateStore { connection in
            let client = MockHubClient()
            client.attentionResponse = { self.attention(connection) }
            return HubSourceWorkspace(connection: connection, store: HubStore(client: client, pollInterval: 999))
        }
        aggregate.synchronize([work, home])
        await aggregate.refreshAndWait()
        XCTAssertEqual(aggregate.attentionBadgeCount, 4)
        aggregate.source(work.id)?.store.purgeOnUnauthorized()
        XCTAssertEqual(aggregate.attentionBadgeCount, 2)
        aggregate.synchronize([])
        let large = MockHubClient()
        large.attentionResponse = {
            AttentionResponse(total_running: 0, total_input_required: Int.max, total_unseen: Int.max,
                              nodes: [], input_required: [], inbox: [], has_more: false)
        }
        let bounded = HubAggregateStore { connection in
            HubSourceWorkspace(connection: connection, store: HubStore(client: large, pollInterval: 999))
        }
        bounded.synchronize([work])
        await bounded.refreshAndWait()
        XCTAssertEqual(bounded.attentionBadgeCount, Int.max)
        bounded.synchronize([])
    }

    func testChatContextIsSourceAndBrowserIdentityScoped() throws {
        let work = connection("work"), home = connection("home")
        let browserID = UUID()
        let destination = URL(string: "https://example.com/work/node/shared/chat/7")!
        let context = try XCTUnwrap(ChatTabContext.resolve(connection: work, browserIdentity: browserID,
                                                          url: destination, agents: nodes(work).nodes))
        XCTAssertEqual(context.agentID, "shared")
        XCTAssertEqual(context.agentName, "Shared")
        XCTAssertEqual(context.url, destination)
        XCTAssertTrue(context.belongs(to: work, browserIdentity: browserID))
        XCTAssertFalse(context.belongs(to: home, browserIdentity: browserID), "Colliding remote IDs do not share Chat context")
        XCTAssertFalse(context.belongs(to: work, browserIdentity: UUID()), "Revoked browser identities are not resumable")
        let replacement = HubConnection(id: UUID(), name: work.name, kind: work.kind, url: work.url)
        XCTAssertFalse(context.belongs(to: replacement, browserIdentity: browserID))
    }

    func testDirectChatContextAndServerRootDoNotGuessAnotherAgent() throws {
        let direct = connection("direct", kind: .directNode)
        let context = try XCTUnwrap(ChatTabContext.resolve(connection: direct, browserIdentity: UUID(),
                                                          url: direct.url.appendingPathComponent("chat/7"), agents: nodes(direct).nodes))
        XCTAssertEqual(context.agentName, "Shared")
        let hub = connection("work")
        let root = try XCTUnwrap(ChatTabContext.resolve(connection: hub, browserIdentity: UUID(),
                                                       url: hub.url, agents: nodes(hub).nodes))
        XCTAssertNil(root.agentID, "A server root is not permission to pick the first agent")
        XCTAssertEqual(root.agentName, hub.name)
    }

    func testChatContextRejectsForeignAndNonChatDocuments() {
        let work = connection("work")
        for address in ["https://elsewhere.example/work/node/shared/chat/7", "https://example.com/home/node/shared/chat/7",
                        "https://example.com/work/api/nodes", "https://example.com/work/auth/login", "https://example.com/work/node/shared/chat/7?token=secret"] {
            XCTAssertNil(ChatTabContext.resolve(connection: work, browserIdentity: UUID(),
                                               url: URL(string: address)!, agents: nodes(work).nodes), address)
        }
    }

    func testSynchronizingUnchangedCatalogDoesNotRepublishOrReplaceSources() async throws {
        let connection = connection("work")
        let aggregate = HubAggregateStore { connection in
            HubSourceWorkspace(connection: connection, store: HubStore(client: MockHubClient(), pollInterval: 999))
        }
        aggregate.synchronize([connection])
        await aggregate.refreshAndWait()
        let source = try XCTUnwrap(aggregate.sources.first)
        var publications = 0
        let observation = aggregate.objectWillChange.sink { _ in publications += 1 }
        aggregate.synchronize([connection])
        XCTAssertEqual(publications, 0)
        XCTAssertTrue(aggregate.sources.first === source)
        var renamed = connection
        renamed.name = "Renamed"
        aggregate.synchronize([renamed])
        XCTAssertTrue(aggregate.sources.first === source)
        XCTAssertEqual(source.connection.name, "Renamed")
        XCTAssertEqual(publications, 1)
        withExtendedLifetime(observation) {}
        aggregate.synchronize([])
    }

    func testTwoHubsAndDirectKeepCollidingIdentitiesAndSourceMountsDistinct() async throws {
        let connections = [connection("work"), connection("home"), connection("direct", kind: .directNode)]
        var clients: [UUID: MockHubClient] = [:]
        let aggregate = HubAggregateStore { connection in
            let client = MockHubClient()
            client.nodesResponse = { self.nodes(connection) }
            client.attentionResponse = { self.attention(connection) }
            clients[connection.id] = client
            return HubSourceWorkspace(connection: connection, store: HubStore(client: client))
        }
        aggregate.synchronize(connections)
        await aggregate.refreshAndWait()
        XCTAssertEqual(aggregate.nodes.count, 3)
        XCTAssertEqual(Set(aggregate.nodes.map(\.id)).count, 3)
        XCTAssertEqual(aggregate.sessions.count, 3, "Active/recent dedupe is within one source/node, not global")
        XCTAssertEqual(Set(aggregate.sessions.map(\.id)).count, 3)
        XCTAssertEqual(aggregate.attention.count, 6)
        XCTAssertEqual(Set(aggregate.attention.map(\.id)).count, 6)
        for session in aggregate.sessions {
            let destination = try XCTUnwrap(aggregate.destination(path: session.session.resume_path, sourceID: session.source.id, nodeID: session.node.id))
            XCTAssertTrue(destination.path.hasPrefix(session.source.url.path))
            XCTAssertEqual(destination.host, "example.com")
            XCTAssertFalse(destination.absoluteString.contains("10.99"))
        }
        aggregate.synchronize([])
    }
    func testHealthySourceAndOtherPanelsPublishWhileSlowSourceRemainsBlocked() async throws {
        let healthy = connection("healthy"), slow = connection("slow")
        var release: CheckedContinuation<NodesResponse, Never>?
        let aggregate = HubAggregateStore { connection in
            let client = MockHubClient()
            if connection.id == slow.id {
                client.nodesResponse = { await withCheckedContinuation { release = $0 } }
            } else { client.nodesResponse = { self.nodes(connection) } }
            client.attentionResponse = { self.attention(connection) }
            return HubSourceWorkspace(connection: connection, store: HubStore(client: client))
        }
        aggregate.synchronize([slow, healthy])
        await drain()
        XCTAssertEqual(aggregate.nodes.map(\.source.id), [healthy.id])
        XCTAssertEqual(aggregate.attention.count, 4, "Slow nodes panel does not block even its own attention panel")
        XCTAssertTrue(try XCTUnwrap(aggregate.source(slow.id)).store.nodesLoading)
        release?.resume(returning: nodes(slow))
        await drain()
        XCTAssertEqual(aggregate.nodes.count, 2)
        aggregate.synchronize([])
    }
    func testOneSource401PurgesOnlyItsNativeAndBrowserIdentity() async throws {
        let a = connection("work"), b = connection("home")
        var clients: [UUID: MockHubClient] = [:]
        let aggregate = HubAggregateStore { connection in
            let client = MockHubClient()
            client.nodesResponse = { self.nodes(connection) }
            client.attentionResponse = { self.attention(connection) }
            clients[connection.id] = client
            return HubSourceWorkspace(connection: connection, store: HubStore(client: client))
        }
        aggregate.synchronize([a, b])
        for source in aggregate.sources { await source.store.refresh() }
        let work = try XCTUnwrap(aggregate.source(a.id)), home = try XCTUnwrap(aggregate.source(b.id))
        let homeBrowserID = home.browserIdentity
        clients[a.id]?.nodesResponse = { throw HubAPIError(status: 401, message: "Sign in") }
        await work.store.refresh()
        await drain()
        XCTAssertTrue(work.store.unauthorized)
        XCTAssertTrue(work.browserRevoked)
        XCTAssertEqual(aggregate.nodes.map(\.source.id), [b.id])
        XCTAssertEqual(aggregate.attention.count, 2)
        XCTAssertFalse(home.store.unauthorized)
        XCTAssertFalse(home.browserRevoked)
        XCTAssertEqual(home.browserIdentity, homeBrowserID)
        aggregate.synchronize([])
    }
    func testRemovalAndEndpointEditDiscardLateCompletionAndOldAuthCallbacks() async throws {
        let old = connection("old"), other = connection("other")
        var release: CheckedContinuation<NodesResponse, Never>?
        let aggregate = HubAggregateStore { connection in
            let client = MockHubClient()
            if connection.id == old.id { client.nodesResponse = { await withCheckedContinuation { release = $0 } } }
            else { client.nodesResponse = { self.nodes(connection) } }
            return HubSourceWorkspace(connection: connection, store: HubStore(client: client))
        }
        aggregate.synchronize([old, other])
        await drain()
        let removed = try XCTUnwrap(aggregate.source(old.id))
        let replacement = connection("new")
        aggregate.synchronize([replacement, other])
        await drain()
        release?.resume(returning: nodes(old))
        removed.revokeAuthorization()
        await drain()
        XCTAssertFalse(removed.isActive)
        XCTAssertNil(aggregate.source(old.id))
        XCTAssertEqual(Set(aggregate.nodes.map(\.source.id)), [replacement.id, other.id])
        XCTAssertFalse(try XCTUnwrap(aggregate.source(replacement.id)).store.unauthorized)
        aggregate.synchronize([])
    }
    func testNameOnlyEditReusesSameStoreAndAuthOwner() async throws {
        let source = connection("work")
        let aggregate = HubAggregateStore { connection in HubSourceWorkspace(connection: connection, store: HubStore(client: MockHubClient())) }
        aggregate.synchronize([source])
        let before = try XCTUnwrap(aggregate.source(source.id))
        var renamed = source
        renamed.name = "Renamed"
        aggregate.synchronize([renamed])
        XCTAssertTrue(aggregate.source(source.id) === before)
        XCTAssertEqual(before.connection.name, "Renamed")
        aggregate.synchronize([])
    }
    func testRouteValidationRejectsAPIsAuthPrivateOriginsAndWrongNode() throws {
        let server = URL(string: "https://example.com/work/")!
        for path in ["/home/node/shared/chat/7", "/work/api/nodes", "/work/auth/login", "https://10.0.0.1/chat/7",
                     "/work/node/other/chat/7", "/work/node/shared/chat/../7", "/work/node/shared/chat/%2f7",
                     "/work/node/shared/chat/7?token=secret", "/work/node/shared/?next=https://evil.example/",
                     "/work/node/shared/chat/7#secret"] {
            XCTAssertNil(HubNavigation.chatDestination(path, server: server, nodeID: "shared", direct: false), path)
        }
        XCTAssertNotNil(HubNavigation.chatDestination("/work/node/shared/?new=1", server: server, nodeID: "shared", direct: false))
        XCTAssertNotNil(HubNavigation.chatDestination("/work/node/shared/chat/7", server: server, nodeID: "shared", direct: false))
        XCTAssertNotNil(HubNavigation.chatDestination("/work/node/my.node/chat/7", server: server, nodeID: "my.node", direct: false))
        XCTAssertNotNil(HubNavigation.chatDestination("/work/chat/7", server: server, nodeID: nil, direct: true))
        XCTAssertNil(HubNavigation.chatDestination("/work/node/shared/chat/7", server: server, nodeID: nil, direct: true))
        XCTAssertTrue(HubNavigation.isWithinMount(URL(string: "https://example.com/work/chat/7")!, server: server))
        for raw in ["https://example.com/", "https://example.com/home/", "https://example.com/work-other/", "https://example.com:444/work/", "http://example.com/work/", "https://other.example/work/"] {
            XCTAssertFalse(HubNavigation.isWithinMount(URL(string: raw)!, server: server), raw)
        }
    }

    // MARK: Session search

    nonisolated private static func searchEntry(_ id: String, number: Int64?, at: Int64, snippet: String = "a **hit**") -> SessionSearchEntry {
        SessionSearchEntry(id: id, number: number, short_title: "Title \(id)", long_title: nil, pinned: false,
                           last_message_at: at, message_count: 2, snippet: snippet, attention_unseen: false)
    }

    private func searchAggregate(_ searchers: [UUID: MockSessionSearcher]) -> HubAggregateStore {
        HubAggregateStore { connection in
            let client = MockHubClient()
            client.nodesResponse = { self.nodes(connection) }
            return HubSourceWorkspace(connection: connection, store: HubStore(client: client, pollInterval: 999),
                                      searcher: searchers[connection.id])
        }
    }

    private func waitForSearch(_ aggregate: HubAggregateStore) async {
        for _ in 0..<200 where aggregate.searchAgents.contains(where: { $0.state == .searching }) {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func testTypingFiltersLoadedSessionsWithoutAskingAgents() async throws {
        let work = connection("work")
        let searcher = MockSessionSearcher { _, _ in
            XCTFail("Typing must not fan out")
            return SessionSearchResponse(sessions: [])
        }
        let aggregate = searchAggregate([work.id: searcher])
        aggregate.synchronize([work])
        await aggregate.refreshAndWait()
        aggregate.updateSearchQuery("shared SESSION ")
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(aggregate.searchResults.map(\.session.id), ["session-shared"])
        XCTAssertNil(aggregate.agentSearchQuery)
        XCTAssertTrue(aggregate.searchAgents.isEmpty)
        XCTAssertEqual(aggregate.searchableAgentCount, 1)
        XCTAssertEqual(searcher.searchCount, 0)
        aggregate.synchronize([])
    }

    func testAgentSearchFansOutPerSourceMergesStatusAndIsolatesFailures() async throws {
        let work = connection("work"), home = connection("home"), direct = connection("direct", kind: .directNode)
        let workSearcher = MockSessionSearcher({ nodeID, query in
            XCTAssertEqual(nodeID, "shared")
            XCTAssertEqual(query, "relay")
            return SessionSearchResponse(sessions: [Self.searchEntry("s1", number: 9, at: 1_000)])
        }, status: { _, ids in
            XCTAssertEqual(ids, ["s1"])
            return DirectNodeSessionsStatus(sessions: [Self.statusEntry("s1", running: true)])
        })
        let homeSearcher = MockSessionSearcher { _, _ in throw HubAPIError(status: 404, message: "not found") }
        let directSearcher = MockSessionSearcher({ _, _ in
            SessionSearchResponse(sessions: [Self.searchEntry("s1", number: nil, at: 2_000)])
        }, status: { _, _ in throw HubAPIError(status: 500, message: "status down") })
        let aggregate = searchAggregate([work.id: workSearcher, home.id: homeSearcher, direct.id: directSearcher])
        aggregate.synchronize([work, home, direct])
        await aggregate.refreshAndWait()
        aggregate.updateSearchQuery("  relay ")
        aggregate.searchAllAgents()
        XCTAssertEqual(aggregate.agentSearchQuery, "relay")
        await waitForSearch(aggregate)

        XCTAssertEqual(aggregate.searchAgents.map(\.state), [.done(1), .failed("Search not supported"), .done(1)])
        let results = aggregate.searchResults
        XCTAssertEqual(results.count, 2, "Identical remote IDs from different sources stay distinct")
        XCTAssertEqual(results.map(\.source.id), [work.id, direct.id])
        XCTAssertEqual(results[0].session.active_run, true, "Run state comes from the status lookup")
        XCTAssertNil(results[1].session.active_run, "A failed status lookup still keeps the match")
        XCTAssertEqual(results[0].session.resume_path, "/work/node/shared/chat/9")
        XCTAssertEqual(results[1].session.resume_path, "/direct/chat/s1", "Falls back to the session ID without a number")
        XCTAssertNotNil(aggregate.destination(path: results[0].session.resume_path, sourceID: work.id, nodeID: "shared"))
        XCTAssertNotNil(aggregate.destination(path: results[1].session.resume_path, sourceID: direct.id, nodeID: "shared"))
        XCTAssertEqual(results[0].snippet, "a **hit**")

        aggregate.source(work.id)?.store.purgeOnUnauthorized()
        XCTAssertEqual(aggregate.searchResults.map(\.source.id), [direct.id], "Signed-out sources drop their results")

        aggregate.updateSearchQuery("relay retry")
        XCTAssertNil(aggregate.agentSearchQuery, "Agent results do not answer a changed query")
        XCTAssertTrue(aggregate.searchAgents.isEmpty)
        aggregate.updateSearchQuery("")
        XCTAssertTrue(aggregate.searchResults.isEmpty)
        aggregate.synchronize([])
    }

    func testAgentSearchDiscardsSupersededQueries() async throws {
        let work = connection("work")
        let gate = AsyncGate()
        let searcher = MockSessionSearcher { _, query in
            if query == "old" { await gate.wait() }
            return SessionSearchResponse(sessions: [Self.searchEntry(query, number: 1, at: 1)])
        }
        let aggregate = searchAggregate([work.id: searcher])
        aggregate.synchronize([work])
        await aggregate.refreshAndWait()
        aggregate.updateSearchQuery("old")
        aggregate.searchAllAgents()
        try? await Task.sleep(for: .milliseconds(20))
        aggregate.updateSearchQuery("new")
        aggregate.searchAllAgents()
        await waitForSearch(aggregate)
        await gate.open()
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(aggregate.searchResults.map(\.session.id), ["new"])
        aggregate.synchronize([])
    }

    nonisolated private static func statusEntry(_ id: String, running: Bool) -> DirectNodeSessionEntry {
        DirectNodeSessionEntry(id: id, number: nil, project_id: nil, project_name: nil, short_title: "Title", long_title: nil,
                               pinned: nil, active_run: running, active_response_id: nil, run_epoch: nil, started_rev: nil,
                               started_at: nil, transcript_rev: nil, message_count: nil, last_message_at: nil,
                               attention_store_instance_id: nil, attention_seq: nil, attention_response_id: nil,
                               seen_through_seq: nil, seen_rev: nil, seen_source: nil, attention_unseen: nil,
                               attention_outcome: nil, attention_terminal_at: nil, interaction_required: false,
                               pending_interaction_count: nil, pending_interaction_kinds: nil)
    }

    func testSessionSortOrders() {
        let work = connection("work")
        let node = nodes(work).nodes[0]
        func row(_ id: String, title: String, at: Int?, running: Bool = false, input: Bool = false) -> PhoneHubSession {
            PhoneHubSession(source: work, node: node, session: HubNodeSession(
                id: id, number: nil, short_title: title, long_title: nil, pinned: false, active_run: running,
                interaction_required: input, pending_interaction_count: nil, pending_interaction_kinds: nil,
                last_message_at: at, message_count: nil, resume_path: "/work/node/shared/chat/\(id)"))
        }
        let rows = [row("a", title: "beta", at: 10), row("b", title: "Alpha", at: 30, running: true),
                    row("c", title: "gamma", at: nil, input: true), row("d", title: "delta", at: 20)]
        let unseen: Set<String> = ["d"]
        let flag: (PhoneHubSession) -> PhoneHubSessionAttention? = {
            $0.session.interaction_required == true ? .inputRequired : (unseen.contains($0.session.id) ? .unseen : nil)
        }
        XCTAssertEqual(PhoneHubSessionSort.recent.sorted(rows, flag: flag).map(\.session.id), ["b", "d", "a", "c"])
        XCTAssertEqual(PhoneHubSessionSort.attention.sorted(rows, flag: flag).map(\.session.id), ["c", "d", "b", "a"])
        XCTAssertEqual(PhoneHubSessionSort.title.sorted(rows, flag: flag).map(\.session.id), ["b", "a", "d", "c"])
        XCTAssertEqual(PhoneHubSessionSort.agent.sorted(rows, flag: flag).map(\.session.id), ["a", "b", "c", "d"])
        XCTAssertEqual(PhoneHubSessionSort.relevance.sorted(rows, flag: flag).map(\.session.id), ["a", "b", "c", "d"])
    }
}

final class MockSessionSearcher: HubSessionSearching, @unchecked Sendable {
    typealias Search = @Sendable (String, String) async throws -> SessionSearchResponse
    typealias Status = @Sendable (String, [String]) async throws -> DirectNodeSessionsStatus
    private let lock = NSLock()
    private var _searchCount = 0
    let search: Search
    let status: Status
    init(_ search: @escaping Search, status: @escaping Status = { _, _ in DirectNodeSessionsStatus(sessions: []) }) {
        self.search = search
        self.status = status
    }
    var searchCount: Int { lock.lock(); defer { lock.unlock() }; return _searchCount }
    func search_sessions(node_id: String, query: String, limit: Int) async throws -> SessionSearchResponse {
        lock.withLock { _searchCount += 1 }
        return try await search(node_id, query)
    }
    func sessions_status(node_id: String, ids: [String]) async throws -> DirectNodeSessionsStatus {
        try await status(node_id, ids)
    }
}

actor AsyncGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
