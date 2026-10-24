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
}
