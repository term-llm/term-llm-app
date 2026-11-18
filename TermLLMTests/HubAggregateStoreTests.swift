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
        let session = HubNodeSession(id: "session-shared", number: 7, shortTitle: "Shared session", longTitle: nil,
                                     pinned: false, activeRun: true, interactionRequired: false,
                                     pendingInteractionCount: nil, pendingInteractionKinds: nil,
                                     lastMessageAt: nil, messageCount: nil, resumePath: root + "chat/7")
        let sessions = HubNodeSessions(countLabel: "1 active", hasMore: false, activeCount: 1,
                                       inputRequiredCount: 0, unseenCount: 1, attentionCapability: nil,
                                       attentionLastSuccessAt: nil, active: [session], recent: [session], resumePath: root)
        let node = HubNode(id: "shared", name: "Shared", source: "fixture", connection: "http", url: "http://10.99.0.1/private/",
                           basePath: "", proxyPath: root, newSessionPath: root + "?new=1", hasToken: false,
                           status: HubNodeStatus(reachable: true, state: "ok", latencyMs: 1, version: nil, agent: nil,
                                                 capabilities: nil, details: nil, error: nil), sessions: sessions, diagnostics: nil)
        return NodesResponse(nodes: [node], resolverError: nil)
    }
    private func attention(_ connection: HubConnection) -> AttentionResponse {
        let root = connection.mountPath + (connection.kind == .hub ? "node/shared/" : "")
        return AttentionResponse(totalRunning: 1, totalInputRequired: 1, totalUnseen: 1, nodes: [],
                                 inputRequired: [HubInputRequiredItem(nodeID: "shared", nodeName: "Shared", sessionID: "session-shared", sessionNumber: 7,
                                                                       title: "Input", pendingInteractionCount: 1, pendingInteractionKinds: ["question"],
                                                                       requiredSince: nil, resumePath: root + "chat/7", stale: false)],
                                 inbox: [HubAttentionInboxItem(nodeID: "shared", nodeName: "Shared", sessionID: "session-shared", storeInstanceID: "store-shared",
                                                               sessionNumber: 7, title: "Unseen", outcome: "completed", terminalAt: nil, attentionSeq: 1,
                                                               resumePath: root + "chat/7")], hasMore: false)
    }
    private func drain() async {
        for _ in 0..<30 { await Task.yield() }
    }
    func testSavedHubAndDirectNodeOfferLocalNetworkSettingsForReachabilityFailures() async {
        for kind in HubConnection.Kind.allCases {
            let connection = connection("work", kind: kind)
            let client = MockHubClient()
            let store = HubStore(client: client, pollInterval: 999)
            let source = HubSourceWorkspace(connection: connection, store: store)
            defer { store.dispose() }
            XCTAssertFalse(source.offersLocalNetworkSettings)

            client.nodesResponse = { throw URLError(.notConnectedToInternet) }
            await store.refresh()
            XCTAssertTrue(source.offersLocalNetworkSettings, kind.rawValue)

            client.nodesResponse = { self.nodes(connection) }
            client.attentionResponse = { throw URLError(.notConnectedToInternet) }
            await store.refresh()
            XCTAssertTrue(source.offersLocalNetworkSettings, "\(kind.rawValue) attention failure")

            client.attentionResponse = { self.attention(connection) }
            await store.refresh()
            XCTAssertFalse(source.offersLocalNetworkSettings, "\(kind.rawValue) recovered")
        }
    }

    func testLinkedDevicesAndManagedLocalServiceDoNotOfferLocalNetworkSettings() async {
        let key = LinkedDevicesBase64URL.encode(Data(repeating: 1, count: 32))
        let excluded = [
            HubConnection(id: UUID(), name: "Linked", kind: .directNode,
                          url: URL(string: "http://localhost:8767/ui/")!, linkedDevicesHostKey: key),
            HubConnection(id: UUID(), name: "This Mac", kind: .directNode,
                          url: URL(string: "http://127.0.0.1:8737/")!, managedLocalService: true),
        ]
        for connection in excluded {
            let client = MockHubClient()
            client.nodesResponse = { throw URLError(.notConnectedToInternet) }
            client.attentionResponse = { throw URLError(.notConnectedToInternet) }
            let store = HubStore(client: client, pollInterval: 999)
            let source = HubSourceWorkspace(connection: connection, store: store)
            defer { store.dispose() }
            await store.refresh()
            XCTAssertNotNil(source.error)
            XCTAssertFalse(source.offersLocalNetworkSettings, connection.name)
        }
    }

    func testResumingPollingCanLeaveChosenSourcesPaused() throws {
        let work = connection("work"), desk = connection("desk", kind: .directNode)
        let aggregate = HubAggregateStore { connection in
            HubSourceWorkspace(connection: connection, store: HubStore(client: MockHubClient(), pollInterval: 999))
        }
        aggregate.synchronize([work, desk])
        defer { aggregate.synchronize([]) }
        let workStore = try XCTUnwrap(aggregate.source(work.id)).store
        let deskStore = try XCTUnwrap(aggregate.source(desk.id)).store
        aggregate.setPollingSuspended(true)
        XCTAssertTrue(aggregate.isPollingSuspended)
        XCTAssertFalse(workStore.isPolling)
        // A linked device that is still reconnecting waits for its connection.
        aggregate.setPollingSuspended(false) { $0.id == desk.id }
        XCTAssertFalse(aggregate.isPollingSuspended)
        XCTAssertTrue(workStore.isPolling)
        XCTAssertFalse(deskStore.isPolling)
    }

    /// Sources poll only while Agents is on screen. A quick look at another
    /// tab costs nothing; coming back after a while refetches at once.
    func testPollingRunsOnlyWhileAgentsIsOnScreen() async throws {
        let client = MockHubClient()
        let work = connection("work")
        let aggregate = HubAggregateStore(agentsLeaveGrace: .milliseconds(50)) { connection in
            HubSourceWorkspace(connection: connection, store: HubStore(client: client, pollInterval: 999))
        }
        aggregate.synchronize([work])
        defer { aggregate.synchronize([]) }
        let store = try XCTUnwrap(aggregate.source(work.id)).store
        await drain()
        let loads = client.listNodesCalls
        XCTAssertTrue(store.isPolling)

        aggregate.setAgentsVisible(false)
        aggregate.setAgentsVisible(true)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(store.isPolling)
        XCTAssertEqual(client.listNodesCalls, loads, "a quick switch doesn't refetch")

        aggregate.setAgentsVisible(false)
        XCTAssertTrue(store.isPolling, "not straight away")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(aggregate.isPollingSuspended)
        XCTAssertFalse(store.isPolling)

        aggregate.setAgentsVisible(true)
        XCTAssertTrue(store.isPolling)
        await drain()
        XCTAssertEqual(client.listNodesCalls, loads + 1, "coming back refetches at once")
    }

    func testAgentsAndTheAppMustBothBeOnScreenToPoll() async throws {
        let client = MockHubClient()
        let work = connection("work"), home = connection("home")
        let aggregate = HubAggregateStore(agentsLeaveGrace: .milliseconds(20)) { connection in
            HubSourceWorkspace(connection: connection, store: HubStore(client: client, pollInterval: 999))
        }
        aggregate.synchronize([work])
        defer { aggregate.synchronize([]) }
        aggregate.setAgentsVisible(false)
        // Wait for the observed grace transition, not a fixed wall-clock delay:
        // Catalyst/WebKit startup can delay the child task under test-runner load.
        for _ in 0..<200 {
            if aggregate.isPollingSuspended { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(aggregate.isPollingSuspended, "leaving Agents must expire its polling grace")
        aggregate.setPollingSuspended(true)
        aggregate.setPollingSuspended(false)
        XCTAssertTrue(aggregate.isPollingSuspended, "returning to the app on another tab doesn't poll")
        // A connection added meanwhile loads once but doesn't poll.
        aggregate.synchronize([work, home])
        let added = try XCTUnwrap(aggregate.source(home.id)).store
        XCTAssertFalse(added.isPolling)

        aggregate.setPollingSuspended(true)
        aggregate.setAgentsVisible(true)
        XCTAssertTrue(aggregate.isPollingSuspended, "still in the background")
        aggregate.setPollingSuspended(false)
        XCTAssertTrue(try XCTUnwrap(aggregate.source(work.id)).store.isPolling)
        XCTAssertTrue(added.isPolling)
    }

    func testAttentionBadgeUsesServerTotalsNotTheLoadedWindow() async throws {
        let connection = connection("work")
        let client = MockHubClient()
        client.attentionResponse = {
            AttentionResponse(totalRunning: 12, totalInputRequired: 3, totalUnseen: 50,
                              nodes: [], inputRequired: [], inbox: [], hasMore: true)
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
            AttentionResponse(totalRunning: 0, totalInputRequired: Int.max, totalUnseen: Int.max,
                              nodes: [], inputRequired: [], inbox: [], hasMore: false)
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
            let destination = try XCTUnwrap(aggregate.destination(path: session.session.resumePath, sourceID: session.source.id, nodeID: session.node.id))
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
        SessionSearchEntry(id: id, number: number, shortTitle: "Title \(id)", longTitle: nil, pinned: false,
                           lastMessageAt: at, messageCount: 2, snippet: snippet, attentionUnseen: false)
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
        XCTAssertEqual(results[0].session.activeRun, true, "Run state comes from the status lookup")
        XCTAssertNil(results[1].session.activeRun, "A failed status lookup still keeps the match")
        XCTAssertEqual(results[0].session.resumePath, "/work/node/shared/chat/9")
        XCTAssertEqual(results[1].session.resumePath, "/direct/chat/s1", "Falls back to the session ID without a number")
        XCTAssertNotNil(aggregate.destination(path: results[0].session.resumePath, sourceID: work.id, nodeID: "shared"))
        XCTAssertNotNil(aggregate.destination(path: results[1].session.resumePath, sourceID: direct.id, nodeID: "shared"))
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
        DirectNodeSessionEntry(id: id, number: nil, projectID: nil, projectName: nil, shortTitle: "Title", longTitle: nil,
                               pinned: nil, activeRun: running, activeResponseID: nil, runEpoch: nil, startedRev: nil,
                               startedAt: nil, transcriptRev: nil, messageCount: nil, lastMessageAt: nil,
                               attentionStoreInstanceID: nil, attentionSeq: nil, attentionResponseID: nil,
                               seenThroughSeq: nil, seenRev: nil, seenSource: nil, attentionUnseen: nil,
                               attentionOutcome: nil, attentionTerminalAt: nil, interactionRequired: false,
                               pendingInteractionCount: nil, pendingInteractionKinds: nil)
    }

    func testSessionSortOrders() {
        let work = connection("work")
        let node = nodes(work).nodes[0]
        func row(_ id: String, title: String, at: Int?, running: Bool = false, input: Bool = false) -> PhoneHubSession {
            PhoneHubSession(source: work, node: node, session: HubNodeSession(
                id: id, number: nil, shortTitle: title, longTitle: nil, pinned: false, activeRun: running,
                interactionRequired: input, pendingInteractionCount: nil, pendingInteractionKinds: nil,
                lastMessageAt: at, messageCount: nil, resumePath: "/work/node/shared/chat/\(id)"))
        }
        let rows = [row("a", title: "beta", at: 10), row("b", title: "Alpha", at: 30, running: true),
                    row("c", title: "gamma", at: nil, input: true), row("d", title: "delta", at: 20)]
        let unseen: Set<String> = ["d"]
        let flag: (PhoneHubSession) -> PhoneHubSessionAttention? = {
            $0.session.interactionRequired == true ? .inputRequired : (unseen.contains($0.session.id) ? .unseen : nil)
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
    func searchSessions(nodeID: String, query: String, limit: Int) async throws -> SessionSearchResponse {
        lock.withLock { _searchCount += 1 }
        return try await search(nodeID, query)
    }
    func sessionsStatus(nodeID: String, ids: [String]) async throws -> DirectNodeSessionsStatus {
        try await status(nodeID, ids)
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
