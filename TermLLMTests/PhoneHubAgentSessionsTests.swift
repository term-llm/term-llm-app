import XCTest
@testable import TermLLM

/// Closure-backed `HubSessionBrowsing` that records what the page asked for.
final class MockSessionBrowser: HubSessionBrowsing, @unchecked Sendable {
    typealias List = @Sendable (String?) async throws -> AgentSessionPage
    typealias Update = @Sendable (String, AgentSessionPatch) async throws -> AgentSessionPatchResult
    typealias Reorder = @Sendable ([String]) async throws -> PinnedSessionOrder
    private let lock = NSLock()
    private var _cursors: [String?] = []
    private var _patches: [(String, AgentSessionPatch)] = []
    private var _reorders: [[String]] = []
    var list: List
    var update: Update
    var reorder: Reorder

    init(list: @escaping List,
         update: @escaping Update = { id, patch in
             AgentSessionPatchResult(id: id, name: patch.name, shortTitle: patch.name, longTitle: nil,
                                     archived: patch.archived, pinned: patch.pinned, pinOrder: nil)
         },
         reorder: @escaping Reorder = { ids in
             PinnedSessionOrder(pinned: ids.enumerated().map { .init(id: $0.element, pinOrder: Int64($0.offset + 1)) })
         }) {
        self.list = list
        self.update = update
        self.reorder = reorder
    }

    var cursors: [String?] { lock.withLock { _cursors } }
    var patches: [(String, AgentSessionPatch)] { lock.withLock { _patches } }
    var reorders: [[String]] { lock.withLock { _reorders } }

    func listSessions(nodeID: String, limit: Int, cursor: String?) async throws -> AgentSessionPage {
        lock.withLock { _cursors.append(cursor) }
        return try await list(cursor)
    }
    func updateSession(nodeID: String, sessionID: String, patch: AgentSessionPatch) async throws -> AgentSessionPatchResult {
        lock.withLock { _patches.append((sessionID, patch)) }
        return try await update(sessionID, patch)
    }
    func reorderPinnedSessions(nodeID: String, sessionIDs: [String]) async throws -> PinnedSessionOrder {
        lock.withLock { _reorders.append(sessionIDs) }
        return try await reorder(sessionIDs)
    }
}

/// Listing rows for `@Sendable` mock closures (no test-case capture).
private enum Rows {
    static let now = Int64(1_793_270_000_000)

    static func entry(_ id: String, minutesAgo: Int64, pin: Int64? = nil, unseen: Bool = false) -> AgentSessionEntry {
        AgentSessionEntry(id: id, number: nil, shortTitle: id.capitalized, pinned: pin != nil, pinOrder: pin,
                          lastMessageAt: now - minutesAgo * 60_000, messageCount: 4,
                          attentionStoreInstanceID: unseen ? "store-1" : nil, attentionSeq: unseen ? 3 : nil,
                          attentionUnseen: unseen)
    }

    static func entries(_ prefix: String, _ range: Range<Int>) -> [AgentSessionEntry] {
        range.map { entry("\(prefix)\($0)", minutesAgo: Int64($0) * 10) }
    }
}

@MainActor
final class PhoneHubAgentSessionsTests: XCTestCase {
    private let now = Rows.now

    private func connection(linked: Bool = false) -> HubConnection {
        var connection = HubConnection(id: UUID(), name: "Home Hub", kind: .hub, url: URL(string: "https://hub.example/home/")!)
        if linked { connection.linkedDevicesHostKey = "host-key" }
        return connection
    }

    private func cached(_ id: String, running: Bool = false, at: Int) -> HubNodeSession {
        HubNodeSession(id: id, number: nil, shortTitle: id.capitalized, longTitle: nil, pinned: false,
                       activeRun: running, interactionRequired: false, pendingInteractionCount: nil,
                       pendingInteractionKinds: nil, lastMessageAt: at, messageCount: 3,
                       resumePath: "/home/node/jarvis/chat/\(id)")
    }

    private func node(_ sessions: [HubNodeSession], countLabel: String = "214 conversations") -> HubNode {
        HubNode(id: "jarvis", name: "jarvis", source: "fixture", connection: "http", url: "http://10.0.0.1/",
                basePath: "", proxyPath: "/home/node/jarvis/", newSessionPath: "/home/node/jarvis/?new=1",
                hasToken: false,
                status: HubNodeStatus(reachable: true, state: "ok", latencyMs: 1, version: nil, agent: nil,
                                      capabilities: nil, details: nil, error: nil),
                sessions: HubNodeSessions(countLabel: countLabel, hasMore: true, activeCount: nil,
                                          inputRequiredCount: nil, unseenCount: nil, attentionCapability: nil,
                                          attentionLastSuccessAt: nil, active: sessions.filter { $0.activeRun == true },
                                          recent: sessions.filter { $0.activeRun != true }, resumePath: nil),
                diagnostics: nil)
    }

    /// The page holds its source weakly, as the aggregate owns it in the app.
    private var sources: [HubSourceWorkspace] = []

    override func tearDown() async throws {
        sources.forEach { $0.dispose(removeCredentials: false) }
        sources = []
    }

    private func workspace(_ connection: HubConnection, client: MockHubClient = MockHubClient(),
                           browser: MockSessionBrowser, nodes: [HubNode] = []) async -> HubSourceWorkspace {
        let rows = nodes
        client.nodesResponse = { NodesResponse(nodes: rows, resolverError: nil) }
        let store = HubStore(client: client, pollInterval: 999)
        let source = HubSourceWorkspace(connection: connection, store: store, sessions: browser)
        sources.append(source)
        await store.refresh()
        return source
    }

    private func settle(_ condition: @MainActor () -> Bool, timeout: Duration = .seconds(2),
                        file: StaticString = #filePath, line: UInt = #line) async {
        try? await pollUntil(timeout: timeout, interval: .milliseconds(5),
                             file: file, line: line, condition)
    }

    // MARK: Loading

    func testFirstPaintUsesCachedRowsThenTheNodeOrder() async {
        let browser = MockSessionBrowser { _ in
            AgentSessionPage(sessions: [Rows.entry("pinned", minutesAgo: 900, pin: 1), Rows.entry("fresh", minutesAgo: 1),
                                        Rows.entry("cached", minutesAgo: 30)], nextCursor: nil)
        }
        let source = await workspace(connection(), browser: browser,
                                     nodes: [node([cached("cached", at: Int(now) - 1_800_000), cached("busy", running: true, at: Int(now))])])
        let model = PhoneHubAgentSessions(source: source, nodeID: "jarvis")
        XCTAssertEqual(Set(model.conversations.map(\.id)), ["cached", "busy"], "opens instantly from the dashboard rows")
        XCTAssertTrue(model.conversations.first { $0.id == "busy" }?.running == true)

        model.appeared()
        await settle { model.hasLoadedFirstPage }
        XCTAssertEqual(model.pinned.map(\.id), ["pinned"])
        XCTAssertEqual(model.history.map(\.id), ["fresh", "cached"], "the node's listing replaces the cached window")
        XCTAssertEqual(model.paging, .complete)
    }

    func testInfiniteScrollPrefetchesAppendsAndDedupes() async {
        let browser = MockSessionBrowser { cursor in
            cursor == nil
                ? AgentSessionPage(sessions: Rows.entries("a", 0..<30), nextCursor: "c+1/=")
                : AgentSessionPage(sessions: [Rows.entry("a29", minutesAgo: 290)] + Rows.entries("b", 30..<40), nextCursor: nil)
        }
        let model = PhoneHubAgentSessions(source: await workspace(connection(), browser: browser), nodeID: "jarvis")
        model.appeared()
        await settle { model.hasLoadedFirstPage }
        XCTAssertEqual(model.paging, .idle)

        model.rowAppeared("a15")
        XCTAssertEqual(browser.cursors, [nil], "no fetch while plenty of rows remain")
        model.rowAppeared("a21")
        await settle { model.paging == .complete }
        XCTAssertEqual(browser.cursors, [nil, "c+1/="])
        XCTAssertEqual(model.conversations.count, 40, "a row repeated across pages appears once")
        model.loadMore()
        XCTAssertEqual(browser.cursors.count, 2, "nothing more to ask for")
    }

    func testFailedPageOffersRetry() async {
        let attempts = Counter()
        let browser = MockSessionBrowser { cursor in
            guard cursor != nil else { return AgentSessionPage(sessions: Rows.entries("a", 0..<30), nextCursor: "next") }
            if attempts.increment() == 1 { throw HubAPIError(status: 503, message: "Node unavailable") }
            return AgentSessionPage(sessions: Rows.entries("b", 30..<35))
        }
        let model = PhoneHubAgentSessions(source: await workspace(connection(), browser: browser), nodeID: "jarvis")
        model.appeared()
        await settle { model.hasLoadedFirstPage }
        model.loadMore()
        await settle { model.paging == .failed("Node unavailable") }
        XCTAssertEqual(model.conversations.count, 30, "loaded rows stay put")
        model.retry()
        await settle { model.paging == .complete }
        XCTAssertEqual(model.conversations.count, 35)
    }

    func testSignOutDiscardsHistoryAndLateAnswers() async {
        let gate = AsyncGate()
        let browser = MockSessionBrowser { _ in
            await gate.wait()
            return AgentSessionPage(sessions: Rows.entries("secret", 0..<3))
        }
        let source = await workspace(connection(), browser: browser, nodes: [node([cached("cached", at: Int(now))])])
        let model = PhoneHubAgentSessions(source: source, nodeID: "jarvis")
        XCTAssertFalse(model.conversations.isEmpty)
        model.appeared()
        source.store.purgeOnUnauthorized()
        await settle { model.signedOut }
        XCTAssertTrue(model.conversations.isEmpty, "a 401 purges private history")
        await gate.open()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(model.conversations.isEmpty, "a response from the old sign-in is discarded")
    }

    func testHeadRefreshKeepsOlderPagesAndDropsRowsGoneFromTheHead() async {
        let generation = Counter()
        let browser = MockSessionBrowser { cursor in
            if cursor == "older" { return AgentSessionPage(sessions: Rows.entries("old", 100..<103)) }
            if generation.increment() == 1 {
                return AgentSessionPage(sessions: [Rows.entry("keep", minutesAgo: 5), Rows.entry("gone", minutesAgo: 6),
                                                   Rows.entry("tail", minutesAgo: 7)], nextCursor: "older")
            }
            // "gone" was archived elsewhere; "new" just started.
            return AgentSessionPage(sessions: [Rows.entry("new", minutesAgo: 0), Rows.entry("keep", minutesAgo: 5),
                                               Rows.entry("tail", minutesAgo: 7)], nextCursor: "older")
        }
        let model = PhoneHubAgentSessions(source: await workspace(connection(), browser: browser), nodeID: "jarvis")
        model.appeared()
        await settle { model.hasLoadedFirstPage }
        model.loadMore()
        await settle { model.paging == .complete }
        model.nodeChanged(node([cached("new", at: Int(now))]))
        await settle { model.conversations.first?.id == "new" }
        XCTAssertEqual(model.conversations.map(\.id), ["new", "keep", "tail", "old100", "old101", "old102"],
                       "older pages stay loaded; a row missing from inside the fresh head is dropped")
    }

    // MARK: Edits

    func testPinIsImmediateThenTakesTheNodesRank() async {
        let browser = MockSessionBrowser(list: { _ in
            AgentSessionPage(sessions: [Rows.entry("p", minutesAgo: 50, pin: 4), Rows.entry("x", minutesAgo: 1)])
        }, update: { id, patch in
            AgentSessionPatchResult(id: id, name: nil, shortTitle: nil, longTitle: nil, archived: false,
                                    pinned: patch.pinned, pinOrder: 9)
        })
        let model = PhoneHubAgentSessions(source: await workspace(connection(), browser: browser), nodeID: "jarvis")
        model.appeared()
        await settle { model.hasLoadedFirstPage }

        model.setPinned("x", true)
        XCTAssertEqual(model.pinned.map(\.id), ["p", "x"], "a new pin goes after the existing ones at once")
        XCTAssertEqual(model.pinFeedback, 1)
        await settle { model.pinned.last?.pinOrder == 9 }
        XCTAssertEqual(browser.patches.map(\.0), ["x"])
        XCTAssertEqual(browser.patches.first?.1, AgentSessionPatch(pinned: true))
    }

    func testRefusedPinRollsBackAndExplains() async {
        let browser = MockSessionBrowser(list: { _ in AgentSessionPage(sessions: [Rows.entry("x", minutesAgo: 1)]) },
                                         update: { _, _ in throw HubAPIError(status: 500, message: "boom") })
        let model = PhoneHubAgentSessions(source: await workspace(connection(), browser: browser), nodeID: "jarvis")
        model.appeared()
        await settle { model.hasLoadedFirstPage }
        model.setPinned("x", true)
        XCTAssertEqual(model.pinned.map(\.id), ["x"])
        await settle { model.notice != nil }
        XCTAssertTrue(model.pinned.isEmpty, "the row returns to its place")
        XCTAssertNil(model.notice?.undo)
    }

    func testArchiveHidesTheRowAndUndoBringsItBack() async {
        let browser = MockSessionBrowser { _ in
            AgentSessionPage(sessions: [Rows.entry("x", minutesAgo: 1), Rows.entry("y", minutesAgo: 2)])
        }
        let model = PhoneHubAgentSessions(source: await workspace(connection(), browser: browser), nodeID: "jarvis")
        model.appeared()
        await settle { model.hasLoadedFirstPage }

        model.archive("x")
        XCTAssertEqual(model.conversations.map(\.id), ["y"])
        let undo = try? XCTUnwrap(model.notice?.undo)
        XCTAssertEqual(undo?.id, "x")
        await settle { browser.patches.count == 1 }
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(model.conversations.map(\.id), ["y"], "stays archived once the node agrees")

        if let undo { model.undoArchive(undo) }
        XCTAssertEqual(model.conversations.map(\.id), ["x", "y"])
        await settle { browser.patches.count == 2 }
        XCTAssertEqual(browser.patches.map(\.1), [AgentSessionPatch(archived: true), AgentSessionPatch(archived: false)])
    }

    func testRenameShowsTheNewTitleEverywhere() async {
        let browser = MockSessionBrowser { _ in AgentSessionPage(sessions: [Rows.entry("x", minutesAgo: 1)]) }
        let model = PhoneHubAgentSessions(source: await workspace(connection(), browser: browser), nodeID: "jarvis")
        model.appeared()
        await settle { model.hasLoadedFirstPage }
        model.rename("x", to: "  Kyoto day plan  ")
        XCTAssertEqual(model.conversations.first?.title, "Kyoto day plan")
        await settle { browser.patches.count == 1 }
        XCTAssertEqual(browser.patches.first?.1, AgentSessionPatch(name: "Kyoto day plan"))
    }

    func testDraggedPinsKeepTheRanksTheyAlreadyHold() async {
        let browser = MockSessionBrowser(list: { _ in
            AgentSessionPage(sessions: [Rows.entry("a", minutesAgo: 1, pin: 1), Rows.entry("b", minutesAgo: 2, pin: 2),
                                        Rows.entry("c", minutesAgo: 3, pin: 5)])
        }, reorder: { ids in
            PinnedSessionOrder(pinned: zip(ids, [1, 2, 5] as [Int64]).map { .init(id: $0.0, pinOrder: $0.1) })
        })
        let model = PhoneHubAgentSessions(source: await workspace(connection(), browser: browser), nodeID: "jarvis")
        model.appeared()
        await settle { model.hasLoadedFirstPage }

        model.movePins(fromOffsets: [2], toOffset: 0)
        XCTAssertEqual(model.pinned.map(\.id), ["c", "a", "b"])
        XCTAssertEqual(model.pinned.map(\.pinOrder), [1, 2, 5])
        await settle { browser.reorders.count == 1 }
        XCTAssertEqual(browser.reorders.first, ["c", "a", "b"])
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(model.pinned.map(\.id), ["c", "a", "b"])
    }

    func testMarkSeenAcknowledgesTheExactItem() async {
        let client = MockHubClient()
        let browser = MockSessionBrowser { _ in AgentSessionPage(sessions: [Rows.entry("x", minutesAgo: 1, unseen: true)]) }
        let model = PhoneHubAgentSessions(source: await workspace(connection(), client: client, browser: browser), nodeID: "jarvis")
        model.appeared()
        await settle { model.hasLoadedFirstPage }
        XCTAssertTrue(model.conversations.first?.unseen == true)

        model.markSeen("x")
        XCTAssertFalse(model.conversations.first?.unseen ?? true)
        await settle { !client.markSeenCalls.isEmpty }
        XCTAssertEqual(client.markSeenCalls.first, AttentionSeenRequest(storeInstanceID: "store-1", sessionID: "x", attentionSeq: 3))
    }

    func testLinkedDevicesCannotEditMetadata() async {
        let browser = MockSessionBrowser { _ in AgentSessionPage(sessions: [Rows.entry("x", minutesAgo: 1)]) }
        let model = PhoneHubAgentSessions(source: await workspace(connection(linked: true), browser: browser), nodeID: "jarvis")
        model.appeared()
        await settle { model.hasLoadedFirstPage }
        XCTAssertFalse(model.canEdit)
        model.setPinned("x", true)
        model.archive("x")
        XCTAssertTrue(model.pinned.isEmpty)
        XCTAssertEqual(model.conversations.count, 1)
        XCTAssertTrue(browser.patches.isEmpty, "the host does not expose metadata edits to linked devices")
    }

    // MARK: Pure helpers

    func testDateGroupsAndRowTimes() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Australia/Sydney"))
        calendar.locale = Locale(identifier: "en_AU")
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 22)))
        func ago(days: Int, hour: Int = 10) -> Date {
            let day = calendar.date(byAdding: .day, value: -days, to: now)!
            return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
        }
        typealias Group = PhoneHubAgentDateGroup
        XCTAssertEqual(Group.of(ago(days: 0), now: now, calendar: calendar), .today)
        XCTAssertEqual(Group.of(ago(days: 1, hour: 23), now: now, calendar: calendar), .yesterday)
        XCTAssertEqual(Group.of(ago(days: 6), now: now, calendar: calendar), .previousWeek)
        XCTAssertEqual(Group.of(ago(days: 20), now: now, calendar: calendar), .previousMonth)
        XCTAssertEqual(Group.of(ago(days: 45), now: now, calendar: calendar), .month(year: 2026, month: 9))
        XCTAssertEqual(Group.month(year: 2026, month: 9).title(now: now, calendar: calendar), "September")
        XCTAssertEqual(Group.month(year: 2025, month: 12).title(now: now, calendar: calendar), "December 2025")
        XCTAssertEqual(Group.of(nil, now: now, calendar: calendar), .undated)

        XCTAssertEqual(Group.timeLabel(ago(days: 1), now: now, calendar: calendar), "Yesterday")
        XCTAssertFalse(Group.timeLabel(ago(days: 3), now: now, calendar: calendar).isEmpty)
        XCTAssertTrue(Group.timeLabel(ago(days: 400), now: now, calendar: calendar).contains("2025"))

        let rows = [PhoneHubAgentConversation(id: "a", title: "A", lastActivity: ago(days: 0)),
                    PhoneHubAgentConversation(id: "b", title: "B", lastActivity: ago(days: 0, hour: 9)),
                    PhoneHubAgentConversation(id: "c", title: "C", lastActivity: ago(days: 45))]
        XCTAssertEqual(Group.sections(rows, now: now, calendar: calendar).map { $0.rows.map(\.id) }, [["a", "b"], ["c"]])
    }

    func testMovedFollowsListOnMoveSemantics() {
        XCTAssertEqual(PhoneHubAgentSessions.moved(["a", "b", "c", "d"], fromOffsets: [0], toOffset: 3), ["b", "c", "a", "d"])
        XCTAssertEqual(PhoneHubAgentSessions.moved(["a", "b", "c", "d"], fromOffsets: [3], toOffset: 0), ["d", "a", "b", "c"])
        XCTAssertEqual(PhoneHubAgentSessions.moved(["a", "b", "c"], fromOffsets: [0, 1], toOffset: 3), ["c", "a", "b"])
    }

    func testListingOrderIsPinsByRankThenActivity() {
        let older = Date(timeIntervalSince1970: 1_000), newer = Date(timeIntervalSince1970: 2_000)
        let rows = [PhoneHubAgentConversation(id: "old", title: "", lastActivity: older),
                    PhoneHubAgentConversation(id: "pin2", title: "", pinned: true, pinOrder: 2, lastActivity: newer),
                    PhoneHubAgentConversation(id: "new", title: "", lastActivity: newer),
                    PhoneHubAgentConversation(id: "pin1", title: "", pinned: true, pinOrder: 1, lastActivity: older)]
        XCTAssertEqual(rows.sorted(by: PhoneHubAgentConversation.precedes).map(\.id), ["pin1", "pin2", "new", "old"])
    }

    func testEntryTitlesFallBackAndSeenNeedsAnAttentionItem() {
        let named = PhoneHubAgentConversation(entry: AgentSessionEntry(id: "1", number: 12, shortTitle: " ", longTitle: "Long"))
        XCTAssertEqual(named.title, "Long")
        let untitled = PhoneHubAgentConversation(entry: AgentSessionEntry(id: "2", number: 12))
        XCTAssertEqual(untitled.title, "Conversation 12")
        XCTAssertNil(untitled.seenRequest)
    }
}

// MARK: - Client wire format

final class HubSessionBrowsingClientTests: XCTestCase {
    private final class Transport: HubTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [URLRequest] = []
        let body: String
        init(body: String) { self.body = body }
        var requests: [URLRequest] { lock.withLock { _requests } }
        func execute(_ request: URLRequest, onUnauthorized: (@Sendable () async -> Void)?) async throws -> (Data, HTTPURLResponse) {
            lock.withLock { _requests.append(request) }
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                                     headerFields: ["Content-Type": "application/json"])!)
        }
    }

    private func hub(_ transport: Transport) -> HubClient {
        HubClient(baseURL: URL(string: "https://hub.example/home/")!, cookieSource: { [] }, transport: transport)
    }

    private func direct(_ transport: Transport) -> DirectNodeClient {
        DirectNodeClient(baseURL: URL(string: "https://node.example/ui/")!, cookieSource: { [] },
                         bearerSource: { nil }, transport: transport)
    }

    func testHubListsThroughTheNodeProxyWithAStrictlyEncodedCursor() async throws {
        let transport = Transport(body: #"{"sessions":[{"id":"s1","short_title":"Kyoto","pinned":true,"pin_order":2}],"next_cursor":"n2"}"#)
        let page = try await hub(transport).listSessions(nodeID: "jarvis", limit: 500, cursor: "a+b/c=")
        let url = try XCTUnwrap(transport.requests.first?.url)
        XCTAssertEqual(url.path, "/home/node/jarvis/v1/sessions")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery,
                       "scope=all&limit=100&cursor=a%2Bb%2Fc%3D")
        XCTAssertEqual(page.sessions.first?.pinOrder, 2)
        XCTAssertEqual(page.nextCursor, "n2")
    }

    func testHubPatchSendsOriginAndOnlyTheChangedField() async throws {
        let transport = Transport(body: #"{"id":"20260101-120000-ab","pinned":true,"pin_order":3}"#)
        let result = try await hub(transport).updateSession(nodeID: "jarvis", sessionID: "20260101-120000-ab",
                                                             patch: AgentSessionPatch(pinned: true))
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.url?.path, "/home/node/jarvis/v1/sessions/20260101-120000-ab")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://hub.example")
        let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Bool]
        XCTAssertEqual(body, ["pinned": true])
        XCTAssertEqual(result.pinOrder, 3)
    }

    func testDirectNodeReordersPinsAtItsOwnMount() async throws {
        let transport = Transport(body: #"{"pinned":[{"id":"b","pin_order":1},{"id":"a","pin_order":2}]}"#)
        let order = try await direct(transport).reorderPinnedSessions(nodeID: "direct-node", sessionIDs: ["b", "a"])
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.url?.path, "/ui/v1/sessions/pinned-order")
        let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: [String]]
        XCTAssertEqual(body, ["session_ids": ["b", "a"]])
        XCTAssertEqual(order.pinned.map(\.id), ["b", "a"])
    }

    func testDirectNodeListsEveryProjectWithoutACursorOnTheFirstPage() async throws {
        let transport = Transport(body: #"{"sessions":[]}"#)
        _ = try await direct(transport).listSessions(nodeID: "direct-node", limit: 30, cursor: nil)
        let url = try XCTUnwrap(transport.requests.first?.url)
        XCTAssertEqual(url.path, "/ui/v1/sessions")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery, "scope=all&limit=30")
    }

    func testUnsafeSessionIdentifiersNeverReachTheNetwork() async {
        let transport = Transport(body: "{}")
        for id in ["../x", "a/b", "", "..", "a?b"] {
            do {
                _ = try await hub(transport).updateSession(nodeID: "jarvis", sessionID: id, patch: AgentSessionPatch(archived: true))
                XCTFail("\(id) should be rejected")
            } catch {}
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }
}

/// Thread-safe call counter for `@Sendable` mock closures.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int { lock.withLock { value += 1; return value } }
}
