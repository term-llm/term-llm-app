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
        for source in aggregate.sources { await source.store.refresh() }
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
