import SwiftUI
import XCTest
@testable import TermLLM
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Agents panel fixtures: one machine with live work, and a small fleet.
@MainActor
private enum OverviewFixture {
    static let nowMS = Int(Date().timeIntervalSince1970 * 1000)

    static func session(_ id: String, _ title: String, minutesAgo: Int, running: Bool = false, input: Bool = false,
                        messages: Int = 12, root: String) -> HubNodeSession {
        HubNodeSession(id: id, number: nil, short_title: title, long_title: nil, pinned: false, active_run: running,
                       interaction_required: input, pending_interaction_count: input ? 1 : nil,
                       pending_interaction_kinds: input ? ["approval"] : nil,
                       last_message_at: nowMS - minutesAgo * 60_000, message_count: messages,
                       resume_path: root + "chat/" + id)
    }

    static func node(id: String, name: String, root: String, reachable: Bool = true, version: String? = "0.9.99",
                     latency: Int = 0, error: String? = nil, countLabel: String, sessions: [HubNodeSession],
                     unseen: Int? = nil) -> HubNode {
        let active = sessions.filter { $0.active_run == true || $0.interaction_required == true }
        return HubNode(id: id, name: name, source: "fixture", connection: "http", url: "http://10.0.0.1/",
                       base_path: root, proxy_path: root, new_session_path: root + "?new=1", has_token: false,
                       status: HubNodeStatus(reachable: reachable, state: reachable ? "ok" : "error", latency_ms: latency,
                                             version: version, agent: nil, capabilities: nil, details: nil, error: error),
                       sessions: HubNodeSessions(count_label: countLabel, has_more: false, active_count: active.count,
                                                 input_required_count: sessions.filter { $0.interaction_required == true }.count,
                                                 unseen_count: unseen, attention_capability: nil, attention_last_success_at: nil,
                                                 active: active, recent: sessions.filter { !active.contains($0) },
                                                 resume_path: root),
                       diagnostics: nil)
    }

    static let macRoot = "/"
    static var macSessions: [HubNodeSession] {
        [
            session("restrict", "Restrict Claude Model Access", minutesAgo: 4, input: true, messages: 33, root: macRoot),
            session("quickjs", "QuickJS Code Mode Plan", minutesAgo: 0, running: true, messages: 41, root: macRoot),
            session("rust", "Porting Discourse to Rust via API Diff Tests", minutesAgo: 1, running: true, messages: 118, root: macRoot),
            session("install", "macOS Clean Install and Auto-Update Test", minutesAgo: 2, messages: 24, root: macRoot),
            session("update", "Updating to v0.9.99, Jobs Held Back", minutesAgo: 18, messages: 17, root: macRoot),
            session("cursor", "Fix sidebar cursor rewind on refresh", minutesAgo: 60, messages: 52, root: macRoot),
            session("miles", "Miles Davis and Modern Covers", minutesAgo: 180, root: macRoot),
            session("sol", "Probe the gpt-6.2-sol API", minutesAgo: 1_500, messages: 26, root: macRoot),
        ]
    }

    static var macAttention: AttentionResponse {
        func inbox(_ id: String, _ title: String, seq: Int) -> HubAttentionInboxItem {
            HubAttentionInboxItem(node_id: "direct-node", node_name: "This Mac", session_id: id, store_instance_id: "store",
                                  session_number: nil, title: title, outcome: "completed", terminal_at: nil,
                                  attention_seq: seq, resume_path: "/chat/" + id)
        }
        return AttentionResponse(
            total_running: 2, total_input_required: 1, total_unseen: 3,
            nodes: [HubAttentionNode(node_id: "direct-node", node_name: "This Mac", capability_state: "ok", stale: false,
                                     last_success_at: nil, last_error: nil, running_count: 2, input_required_count: 1,
                                     unseen_count: 3, has_green_indicator: false)],
            input_required: [HubInputRequiredItem(node_id: "direct-node", node_name: "This Mac", session_id: "restrict",
                                                  session_number: nil, title: "Restrict Claude Model Access",
                                                  pending_interaction_count: 1, pending_interaction_kinds: ["approval"],
                                                  required_since: nil, resume_path: "/chat/restrict", stale: false)],
            inbox: [inbox("install", "macOS Clean Install and Auto-Update Test", seq: 3),
                    inbox("update", "Updating to v0.9.99, Jobs Held Back", seq: 2),
                    inbox("cursor", "Fix sidebar cursor rewind on refresh", seq: 1)],
            has_more: false)
    }

    /// The agent's first history page: pins first, then recent activity.
    static var macHistory: AgentSessionPage {
        func entry(_ id: String, _ title: String, minutesAgo: Int, pin: Int64? = nil, messages: Int = 12) -> AgentSessionEntry {
            AgentSessionEntry(id: id, short_title: title, pinned: pin != nil, pin_order: pin,
                              last_message_at: Int64(nowMS - minutesAgo * 60_000), message_count: messages)
        }
        return AgentSessionPage(sessions: [
            entry("artifacts", "Interactive Conversation Artifacts", minutesAgo: 400, pin: 1, messages: 88),
            entry("flare", "Add 2.6 Flare Support", minutesAgo: 1_600, pin: 2),
            entry("migration", "term-llm migration to rust", minutesAgo: 3_000, pin: 3, messages: 64),
            entry("quickjs", "QuickJS Code Mode Plan", minutesAgo: 0, messages: 41),
            entry("rust", "Porting Discourse to Rust via API Diff Tests", minutesAgo: 1, messages: 118),
            entry("install", "macOS Clean Install and Auto-Update Test", minutesAgo: 2, messages: 24),
            entry("miles", "Miles Davis and Modern Covers", minutesAgo: 180),
            entry("sol", "Probe the gpt-6.2-sol API", minutesAgo: 1_500, messages: 26),
            entry("fable", "Check Fable 5.2 Availability", minutesAgo: 1_550, messages: 9),
            entry("routing", "Debugging 6.1-to-6.2 Routing", minutesAgo: 1_700, messages: 31),
        ])
    }

    static func thisMac() -> HubConnection {
        var connection = HubConnection(id: UUID(), name: "This Mac", kind: .directNode, url: URL(string: "http://127.0.0.1:8789/")!)
        connection.managedLocalService = true
        return connection
    }

    static func hub() -> HubConnection {
        HubConnection(id: UUID(), name: "Home Hub", kind: .hub, url: URL(string: "https://hub.example/")!)
    }

    static var hubNodes: [HubNode] {
        [
            node(id: "jarvis", name: "Jarvis", root: "/node/jarvis/", latency: 41, countLabel: "1284 conversations",
                 sessions: [session("rust", "Porting Discourse to Rust via API Diff Tests", minutesAgo: 1, running: true, root: "/node/jarvis/"),
                            session("update", "Updating to v0.9.99, Jobs Held Back", minutesAgo: 18, root: "/node/jarvis/"),
                            session("miles", "Miles Davis and Modern Covers", minutesAgo: 180, root: "/node/jarvis/")],
                 unseen: 1),
            node(id: "mini", name: "jarvis-mini", root: "/node/mini/", version: "0.9.98", latency: 58, countLabel: "37 conversations",
                 sessions: [session("fable", "Check Fable 5.2 Availability", minutesAgo: 1_500, root: "/node/mini/"),
                            session("routing", "Debugging 6.1-to-6.2 Routing", minutesAgo: 1_560, root: "/node/mini/")]),
            node(id: "build", name: "build-box", root: "/node/build/", reachable: false, error: "connection refused",
                 countLabel: "", sessions: []),
        ]
    }
}

@MainActor
final class PhoneHubAgentsOverviewTests: XCTestCase {
    private func connection(kind: HubConnection.Kind = .hub, name: String = "Home Hub") -> HubConnection {
        HubConnection(id: UUID(), name: name, kind: kind, url: URL(string: "https://hub.example/home/")!)
    }

    private func attentionRow(_ connection: HubConnection, session: String, input: Bool, title: String = "Title",
                              kinds: [String] = [], outcome: String? = nil) -> PhoneHubAttention {
        PhoneHubAttention(source: connection, nodeID: "jarvis", sessionID: session, itemKey: input ? "input" : "unseen.\(session)",
                          title: title, path: "/home/node/jarvis/chat/\(session)", inputRequired: input, seenRequest: nil,
                          kinds: kinds, outcome: outcome)
    }

    func testOneAgentGetsAPageAndSeveralGetCards() {
        XCTAssertNil(PhoneHubAgentsLayout.for(agentCount: 0), "No agents keeps the list's empty and loading states")
        XCTAssertEqual(PhoneHubAgentsLayout.for(agentCount: 1), .home)
        XCTAssertEqual(PhoneHubAgentsLayout.for(agentCount: 2), .fleet)
        XCTAssertEqual(PhoneHubAgentsLayout.for(agentCount: 9), .fleet)
    }

    /// Needs-input and unread agree with the Attention badge once attention
    /// arrives; running always matches the conversations listed as running.
    func testCountsAgreeWithTheBadgeAndTheListedConversations() {
        var sessions = OverviewFixture.macSessions
        // Blocked on an approval: the run is active, but it is waiting on you.
        sessions.append(HubNodeSession(id: "blocked", number: nil, short_title: "Blocked", long_title: nil, pinned: nil,
                                       active_run: true, interaction_required: true, pending_interaction_count: 1,
                                       pending_interaction_kinds: ["approval"], last_message_at: nil, message_count: nil,
                                       resume_path: "/r/chat/blocked"))
        let node = OverviewFixture.node(id: "jarvis", name: "Jarvis", root: "/r/", countLabel: "9 conversations",
                                        sessions: sessions, unseen: 5)
        let fallback = PhoneHubAgentSummary(source: connection(), node: node, attention: nil)
        XCTAssertEqual(fallback.running, 2, "Waiting on you is not running")
        XCTAssertEqual(fallback.needsInput, 2)
        XCTAssertEqual(fallback.unread, 5)
        XCTAssertFalse(fallback.isIdle)
        XCTAssertEqual(PhoneHubAgentSummary.highlights(node: node, attention: []).filter { $0.kind == .running }.count,
                       fallback.running, "The count matches the Running now list")

        let attention = HubAttentionNode(node_id: "jarvis", node_name: "Jarvis", capability_state: "ok", stale: false,
                                         last_success_at: nil, last_error: nil, running_count: 7, input_required_count: 0,
                                         unseen_count: -3, has_green_indicator: false)
        let reported = PhoneHubAgentSummary(source: connection(), node: node, attention: attention)
        XCTAssertEqual([reported.running, reported.needsInput, reported.unread], [2, 0, 0], "Counts are never negative")

        // Attention can say a conversation needs input while the node's
        // listing still shows its run: it is listed, and counted, once.
        let source = connection()
        let asked = [attentionRow(source, session: "quickjs", input: true, kinds: ["approval"])]
        let waiting = PhoneHubAgentSummary(source: source, node: node, attention: attention, waiting: ["quickjs"])
        XCTAssertEqual(waiting.running, 1)
        XCTAssertEqual(PhoneHubAgentSummary.highlights(node: node, attention: asked).filter { $0.kind == .running }.map(\.sessionID),
                       ["rust"])
    }

    func testStatusLeavesOutUnmeasuredLatencyAndSaysWhyItIsOffline() {
        let local = OverviewFixture.node(id: "direct-node", name: "This Mac", root: "/", latency: 0, countLabel: "", sessions: [])
        XCTAssertEqual(PhoneHubAgentSummary(source: connection(), node: local, attention: nil).statusText, "Online · v0.9.99")
        let remote = OverviewFixture.node(id: "jarvis", name: "Jarvis", root: "/", version: "protocol-fixture", latency: 41,
                                          countLabel: "", sessions: [])
        XCTAssertEqual(PhoneHubAgentSummary(source: connection(), node: remote, attention: nil).statusText,
                       "Online · protocol-fixture · 41 ms")
        let down = OverviewFixture.node(id: "build", name: "build-box", root: "/", reachable: false, error: " connection refused ",
                                        countLabel: "", sessions: [])
        XCTAssertEqual(PhoneHubAgentSummary(source: connection(), node: down, attention: nil).statusText, "Offline · connection refused")
        XCTAssertNil(PhoneHubAgentSummary.versionLabel("  "))
    }

    func testPlaceOnlyNamesTheConnectionWhenItAddsSomething() {
        let node = OverviewFixture.node(id: "jarvis", name: "Jarvis", root: "/", countLabel: "", sessions: [])
        XCTAssertEqual(PhoneHubAgentSummary(source: connection(), node: node, attention: nil).place, "via Home Hub")
        XCTAssertNil(PhoneHubAgentSummary(source: connection(kind: .directNode, name: "jarvis"), node: node, attention: nil).place,
                     "A Direct Node saved under its agent's name says nothing new")
        XCTAssertEqual(PhoneHubAgentSummary(source: connection(kind: .directNode, name: "Desk"), node: node, attention: nil).place, "Desk")
        let local = PhoneHubAgentSummary(source: OverviewFixture.thisMac(), node: node, attention: nil)
        XCTAssertEqual(local.place, "Local service")
        XCTAssertEqual(local.symbol, "laptopcomputer")
    }

    func testCountLabelBecomesAStatisticOnlyWhenItLeadsWithANumber() {
        XCTAssertEqual(PhoneHubCountLabel("200 conversations"), PhoneHubCountLabel(value: "200", caption: "conversations"))
        XCTAssertEqual(PhoneHubCountLabel("1,284 sessions"), PhoneHubCountLabel(value: "1,284", caption: "sessions"))
        XCTAssertEqual(PhoneHubCountLabel("12"), PhoneHubCountLabel(value: "12", caption: "conversations"))
        XCTAssertNil(PhoneHubCountLabel("Many conversations"))
        XCTAssertNil(PhoneHubCountLabel(""))
        XCTAssertNil(PhoneHubCountLabel(nil))
    }

    /// Waiting on you first, then running, unread and recent: one row per
    /// conversation, however many places report it.
    func testHighlightsAreMostUrgentFirstAndOncePerConversation() {
        let source = connection()
        let root = "/home/node/jarvis/"
        let node = OverviewFixture.node(id: "jarvis", name: "Jarvis", root: root, countLabel: "", sessions: [
            OverviewFixture.session("old", "Old", minutesAgo: 600, root: root),
            OverviewFixture.session("run", "Running", minutesAgo: 1, running: true, root: root),
            OverviewFixture.session("ask", "Asking", minutesAgo: 9, input: true, root: root),
            OverviewFixture.session("done", "Done", minutesAgo: 30, root: root),
            OverviewFixture.session("new", "Newer", minutesAgo: 20, root: root),
        ])
        let attention = [
            attentionRow(source, session: "done", input: false, title: "Done", outcome: "completed"),
            attentionRow(source, session: "ask", input: true, title: "Asking", kinds: ["approval"]),
        ]
        let rows = PhoneHubAgentSummary.highlights(node: node, attention: attention)
        XCTAssertEqual(rows.map(\.sessionID), ["ask", "run", "done", "new", "old"])
        XCTAssertEqual(rows.map(\.kind), [.needsInput, .running, .unread, .recent, .recent])
        XCTAssertEqual(rows.first?.detail, "Approval requested")
        XCTAssertEqual(rows[2].detail, "Completed")
        XCTAssertEqual(rows[2].messageCount, 12, "Attention rows borrow the node's details for their conversation")
        XCTAssertEqual(rows.first?.path, root + "chat/ask")
        XCTAssertEqual(PhoneHubAgentSummary.highlights(node: node, attention: attention, limit: 3).map(\.sessionID), ["ask", "run", "done"])
    }

    func testHighlightTitlesAndDetailsFallBackGracefully() {
        let source = connection()
        let node = OverviewFixture.node(id: "jarvis", name: "Jarvis", root: "/", countLabel: "", sessions: [
            HubNodeSession(id: "s", number: 4, short_title: " ", long_title: nil, pinned: nil, active_run: nil,
                           interaction_required: true, pending_interaction_count: nil, pending_interaction_kinds: ["question"],
                           last_message_at: nil, message_count: nil, resume_path: "/chat/4"),
        ])
        let rows = PhoneHubAgentSummary.highlights(node: node, attention: [attentionRow(source, session: "x", input: false, title: "", outcome: "ERRORED")])
        XCTAssertEqual(rows.map(\.title), ["Conversation 4", "Untitled conversation"])
        XCTAssertEqual(rows.first?.detail, "Needs your input")
        XCTAssertEqual(rows.last?.detail, "Failed")
        XCTAssertEqual(PhoneHubAgentHighlight.outcomeDetail("cancelled"), "Stopped")
        XCTAssertEqual(PhoneHubAgentHighlight.outcomeDetail("timed out"), "Timed out")
        XCTAssertNil(PhoneHubAgentHighlight.outcomeDetail(" "))
    }

    /// The aggregate keeps what each attention item is waiting for and how a
    /// result ended, which the Agents page shows under its title.
    func testAttentionRowsKeepInputKindsAndOutcomes() async throws {
        let mac = OverviewFixture.thisMac()
        let client = MockHubClient()
        client.attentionResponse = { OverviewFixture.macAttention }
        let aggregate = HubAggregateStore { connection in
            HubSourceWorkspace(connection: connection, store: HubStore(client: client, pollInterval: 999))
        }
        aggregate.synchronize([mac])
        defer { aggregate.synchronize([]) }
        await aggregate.refreshAndWait()
        let rows = aggregate.attention
        XCTAssertEqual(rows.first { $0.inputRequired }?.kinds, ["approval"])
        XCTAssertEqual(rows.filter { !$0.inputRequired }.map(\.outcome), ["completed", "completed", "completed"])
    }
}

/// Renders the real views with fixture data so their layout can be inspected.
/// Set `TERMLLM_AGENTS_SNAPSHOT_DIR` (`TEST_RUNNER_TERMLLM_AGENTS_SNAPSHOT_DIR`
/// through xcodebuild) to write PNGs there; otherwise these tests skip.
@MainActor
final class PhoneHubAgentsOverviewSnapshotTests: XCTestCase {
    private var aggregate: HubAggregateStore?

    override func tearDown() async throws {
        aggregate?.synchronize([])
        aggregate = nil
    }

    private func directory() throws -> URL {
        let path = ProcessInfo.processInfo.environment["TERMLLM_AGENTS_SNAPSHOT_DIR"] ?? ""
        try XCTSkipIf(path.isEmpty, "Set TERMLLM_AGENTS_SNAPSHOT_DIR to render the Agents page")
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func load(fleet: Bool) async throws -> HubAggregateStore {
        let mac = OverviewFixture.thisMac(), hub = OverviewFixture.hub()
        let aggregate = HubAggregateStore { connection in
            let client = MockHubClient()
            if connection.id == mac.id {
                let node = OverviewFixture.node(id: "direct-node", name: "This Mac", root: OverviewFixture.macRoot,
                                                countLabel: "200 conversations", sessions: OverviewFixture.macSessions, unseen: 3)
                client.nodesResponse = { NodesResponse(nodes: [node], resolver_error: nil) }
                client.attentionResponse = { OverviewFixture.macAttention }
            } else {
                client.nodesResponse = { NodesResponse(nodes: OverviewFixture.hubNodes, resolver_error: nil) }
            }
            let history = OverviewFixture.macHistory
            return HubSourceWorkspace(connection: connection, store: HubStore(client: client, pollInterval: 999),
                                      sessions: MockSessionBrowser { _ in history })
        }
        aggregate.synchronize(fleet ? [mac, hub] : [mac])
        await aggregate.refreshAndWait()
        self.aggregate = aggregate
        return aggregate
    }

    private func page(_ aggregate: HubAggregateStore) -> some View {
        NavigationStack {
            PhoneHubAgentsOverview(aggregate: aggregate, nodes: aggregate.nodes, isVisible: true, navigationError: nil,
                                   onOpen: { _, _, _ in }, onShowAttention: {})
        }
    }

    func testRenderOneAgent() async throws {
        let directory = try directory()
        let aggregate = try await load(fleet: false)
        XCTAssertEqual(aggregate.nodes.count, 1)
        for width in Self.widths {
            try await render(page(aggregate), width: width, to: directory.appendingPathComponent("agents-home-\(Int(width)).png"))
        }
    }

    func testRenderSeveralAgents() async throws {
        let directory = try directory()
        let aggregate = try await load(fleet: true)
        XCTAssertEqual(aggregate.nodes.count, 4)
        for width in Self.widths {
            try await render(page(aggregate), width: width, to: directory.appendingPathComponent("agents-fleet-\(Int(width)).png"))
        }
    }

    #if os(macOS)
    private static let widths: [CGFloat] = [820, 1160]

    private func render(_ view: some View, width: CGFloat, to url: URL) async throws {
        let host = NSHostingView(rootView: view.frame(width: width, height: 760)
            .background(Color.white).environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 760), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        // ARC owns it; AppKit's release on close would free it twice.
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = .white
        window.contentView = host
        defer { window.close() }
        // Let the first history page and SwiftUI's layout settle.
        try await Task.sleep(for: .milliseconds(600))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }
    #else
    private static let widths: [CGFloat] = [375, 768, 900]

    private func render(_ view: some View, width: CGFloat, to url: URL) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 1_000)
        let host = UIHostingController(rootView: view)
        host.overrideUserInterfaceStyle = .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(600))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try XCTUnwrap(image.pngData()).write(to: url)
    }
    #endif
}
