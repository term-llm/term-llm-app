import XCTest
@testable import TermLLM

// MARK: - Model Codable tests

final class HubClientModelTests: XCTestCase {

    func testPageConfigurationDecodesFullJSON() throws {
        let json = """
        {"page":"dashboard","authMode":"passkey","basePath":"/hub","canAddNodes":true,
         "passkeyAuth":true,"invalidToken":false,"formAction":"/hub/",
         "cacheScope":"abc123def456789012345678","cacheDisplayAllowed":true}
        """
        let config = try JSONDecoder().decode(HubPageConfiguration.self, from: Data(json.utf8))
        XCTAssertEqual(config.page, "dashboard")
        XCTAssertEqual(config.authMode, "passkey")
        XCTAssertEqual(config.basePath, "/hub")
        XCTAssertTrue(config.canAddNodes)
        XCTAssertTrue(config.passkeyAuth)
        XCTAssertEqual(config.invalidToken, false)
        XCTAssertEqual(config.formAction, "/hub/")
        XCTAssertEqual(config.cacheScope, "abc123def456789012345678")
        XCTAssertEqual(config.cacheDisplayAllowed, true)
    }

    func testPageConfigurationDefaultsFalseForMissingBooleans() throws {
        let json = """
        {"page":"bearer-login","authMode":"bearer"}
        """
        let config = try JSONDecoder().decode(HubPageConfiguration.self, from: Data(json.utf8))
        XCTAssertFalse(config.canAddNodes)
        XCTAssertFalse(config.passkeyAuth)
        XCTAssertEqual(config.basePath, "")
        XCTAssertNil(config.invalidToken)
        XCTAssertNil(config.formAction)
    }

    func testPageConfigurationMissingRequiredFieldThrows() {
        let json = """
        {"authMode":"none"}
        """
        XCTAssertThrowsError(try JSONDecoder().decode(HubPageConfiguration.self, from: Data(json.utf8)))
    }

    func testPageConfigurationRoundTrips() throws {
        let original = HubPageConfiguration(
            page: "security", authMode: "passkey", basePath: "/ui",
            canAddNodes: true, passkeyAuth: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HubPageConfiguration.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testNodesResponseDecodes() throws {
        let json = """
        {"nodes":[],"resolver_error":"timeout"}
        """
        let resp = try JSONDecoder().decode(NodesResponse.self, from: Data(json.utf8))
        XCTAssertEqual(resp.resolverError, "timeout")
    }

    func testNodesResponseNilResolverError() throws {
        let json = """
        {"nodes":[]}
        """
        XCTAssertNil(try JSONDecoder().decode(NodesResponse.self, from: Data(json.utf8)).resolverError)
    }

    func testAttentionResponseDecodes() throws {
        let json = """
        {"total_running":3,"total_input_required":1,"total_unseen":5,
         "nodes":[],"input_required":[],"inbox":[],"has_more":false}
        """
        let resp = try JSONDecoder().decode(AttentionResponse.self, from: Data(json.utf8))
        XCTAssertEqual(resp.totalRunning, 3)
        XCTAssertFalse(resp.hasMore)
    }

    func testHubDelegationDecodes() throws {
        let json = """
        {"id":"d1","origin_node":"n1","target_node":"n2","status":"running",
         "depth":0,"created_at":"2025-01-01T00:00:00Z","updated_at":"2025-01-01T00:00:00Z"}
        """
        let d = try JSONDecoder().decode(HubDelegation.self, from: Data(json.utf8))
        XCTAssertEqual(d.id, "d1")
        XCTAssertNil(d.agentName)
    }

    func testRegistrationInfoResponseDecodes() throws {
        let json = """
        {"enabled":true,"token_configured":true,"can_persist_nodes":false,"registration_token":"abc"}
        """
        let resp = try JSONDecoder().decode(RegistrationInfoResponse.self, from: Data(json.utf8))
        XCTAssertTrue(resp.enabled)
        XCTAssertEqual(resp.registrationToken, "abc")
    }

    func testRegistrationInfoMinimalDecodes() throws {
        let resp = try JSONDecoder().decode(RegistrationInfoResponse.self, from: Data("{\"enabled\":false}".utf8))
        XCTAssertFalse(resp.enabled)
        XCTAssertNil(resp.tokenConfigured)
    }

    func testHubSessionResponseDecodes() throws {
        let json = """
        {"administrator":"admin","session":{"key":"value"},"recently_authenticated":true,"active_sessions":2}
        """
        let resp = try JSONDecoder().decode(HubSessionResponse.self, from: Data(json.utf8))
        XCTAssertEqual(resp.administrator, "admin")
        XCTAssertEqual(resp.session["key"], .string("value"))
    }

    func testHubCredentialDecodes() throws {
        let json = """
        {"record_id":"r1","display_name":"My Key","transports":["usb","ble"],
         "created_at":"2025-01-01","last_used_at":"2025-06-01"}
        """
        let cred = try JSONDecoder().decode(HubCredential.self, from: Data(json.utf8))
        XCTAssertEqual(cred.transports, ["usb", "ble"])
    }

    func testHubCredentialNullTransports() throws {
        let json = """
        {"record_id":"r2","display_name":"Key","transports":null,
         "created_at":"2025-01-01","last_used_at":"2025-06-01"}
        """
        XCTAssertNil(try JSONDecoder().decode(HubCredential.self, from: Data(json.utf8)).transports)
    }

    func testRedirectResponseDecodesWithoutOk() throws {
        let resp = try JSONDecoder().decode(RedirectResponse.self, from: Data("{\"redirect\":\"/hub/\"}".utf8))
        XCTAssertNil(resp.ok)
        XCTAssertEqual(resp.redirect, "/hub/")
    }

    func testHubNodeFullDecodes() throws {
        let json = """
        {"id":"n1","name":"Local","source":"config","connection":"direct",
         "url":"http://localhost:3000","base_path":"","proxy_path":"/node/n1/",
         "new_session_path":"/hub/node/n1/chat/","has_token":true,
         "status":{"reachable":true,"state":"ok","latency_ms":12}}
        """
        let node = try JSONDecoder().decode(HubNode.self, from: Data(json.utf8))
        XCTAssertTrue(node.status.reachable)
        XCTAssertEqual(node.status.latencyMs, 12)
        XCTAssertNil(node.sessions)
    }

    func testGrantPrefixRawValues() {
        XCTAssertEqual(GrantPrefix.bootstrap.rawValue, "/api/auth/bootstrap")
        XCTAssertEqual(GrantPrefix.recovery.rawValue, "/api/auth/recovery")
    }

    func testHubModelsKeepEveryWireKey() throws {
        try assertWireKeysRoundTrip(NodesResponse.self, #"{"nodes":[],"resolver_error":"timeout"}"#)
        try assertWireKeysRoundTrip(NodeOrderResponse.self, #"{"node_ids":["a","b"]}"#)
        try assertWireKeysRoundTrip(HubNode.self, """
        {"id":"n1","name":"Local","source":"config","connection":"direct","url":"http://localhost:3000",
         "base_path":"/","proxy_path":"/node/n1/","new_session_path":"/node/n1/?new=1","has_token":true,
         "status":{"reachable":true,"state":"ok","latency_ms":12},"sessions":{"count_label":"1 conversation"},
         "diagnostics":[{"severity":"warning","code":"stale","message":"Stale"}]}
        """)
        try assertWireKeysRoundTrip(HubNodeStatus.self, """
        {"reachable":true,"state":"ok","latency_ms":12,"version":"1.2.3","agent":"desk",
         "capabilities":["api"],"details":{"mode":"direct"},"error":"none"}
        """)
        try assertWireKeysRoundTrip(HubNodeSessions.self, """
        {"count_label":"2 conversations","has_more":true,"active_count":1,"input_required_count":1,
         "unseen_count":3,"attention_capability":"ok","attention_last_success_at":1700000000000,
         "active":[],"recent":[],"resume_path":"/node/n1/"}
        """)
        try assertWireKeysRoundTrip(HubNodeSession.self, """
        {"id":"s1","number":4,"short_title":"Short","long_title":"Long","pinned":true,"active_run":true,
         "interaction_required":true,"pending_interaction_count":2,"pending_interaction_kinds":["approval"],
         "last_message_at":1700000000000,"message_count":9,"resume_path":"/node/n1/chat/4"}
        """)
        try assertWireKeysRoundTrip(AttentionResponse.self, """
        {"total_running":3,"total_input_required":1,"total_unseen":5,
         "nodes":[],"input_required":[],"inbox":[],"has_more":true}
        """)
        try assertWireKeysRoundTrip(HubAttentionNode.self, """
        {"node_id":"n1","node_name":"Local","capability_state":"ok","stale":false,
         "last_success_at":"2025-01-01T00:00:00Z","last_error":"none","running_count":3,
         "input_required_count":1,"unseen_count":5,"has_green_indicator":false}
        """)
        try assertWireKeysRoundTrip(HubInputRequiredItem.self, """
        {"node_id":"n1","node_name":"Local","session_id":"s1","session_number":4,"title":"Title",
         "pending_interaction_count":1,"pending_interaction_kinds":["approval"],
         "required_since":"2025-01-01T00:00:00Z","resume_path":"/node/n1/chat/4","stale":false}
        """)
        try assertWireKeysRoundTrip(HubAttentionInboxItem.self, """
        {"node_id":"n1","node_name":"Local","session_id":"s2","store_instance_id":"store","session_number":5,
         "title":"Title","outcome":"completed","terminal_at":"2025-01-01T00:00:00Z","attention_seq":7,
         "resume_path":"/node/n1/chat/5"}
        """)
        try assertWireKeysRoundTrip(AttentionSeenRequest.self,
                                    #"{"store_instance_id":"store","session_id":"s1","attention_seq":7}"#)
        try assertWireKeysRoundTrip(HubDelegation.self, """
        {"id":"d1","origin_node":"n1","target_node":"n2","agent_name":"coder","prompt":"Prompt","model":"m",
         "cwd":"/tmp","job_id":"j1","run_id":"r1","status":"running","depth":1,"chain":["n1","n2"],
         "parent_delegation_id":"d0","response":"done","error":"none",
         "created_at":"2025-01-01T00:00:00Z","updated_at":"2025-01-02T00:00:00Z"}
        """)
        try assertWireKeysRoundTrip(RegistrationInfoResponse.self, """
        {"enabled":true,"token_configured":true,"can_persist_nodes":false,"registration_token":"abc"}
        """)
        try assertWireKeysRoundTrip(HubSessionResponse.self, """
        {"administrator":"admin","session":{"key":"value"},"recently_authenticated":true,"active_sessions":2}
        """)
        try assertWireKeysRoundTrip(HubCredential.self, """
        {"record_id":"r1","display_name":"My Key","transports":["usb"],
         "created_at":"2025-01-01","last_used_at":"2025-06-01"}
        """)
        try assertWireKeysRoundTrip(SessionSearchEntry.self, """
        {"id":"s1","number":4,"short_title":"Short","long_title":"Long","pinned":true,
         "last_message_at":1700000000000,"message_count":9,"snippet":"hit","attention_unseen":true}
        """)
    }

    func testSessionBrowsingModelsKeepEveryWireKey() throws {
        try assertWireKeysRoundTrip(AgentSessionPage.self, #"{"sessions":[],"next_cursor":"c2"}"#)
        try assertWireKeysRoundTrip(AgentSessionEntry.self, """
        {"id":"s1","number":4,"name":"Named","short_title":"Short","long_title":"Long","project_name":"proj",
         "archived":false,"pinned":true,"pin_order":2,"created_at":1700000000000,"last_message_at":1700000001000,
         "message_count":9,"attention_store_instance_id":"store","attention_seq":7,"attention_unseen":true,
         "parent_session_id":"s0"}
        """)
        try assertWireKeysRoundTrip(AgentSessionPatchResult.self, """
        {"id":"s1","name":"Named","short_title":"Short","long_title":"Long","archived":true,"pinned":false,"pin_order":3}
        """)
        try assertWireKeysRoundTrip(PinnedSessionOrder.Position.self, #"{"id":"s1","pin_order":1}"#)
    }
}
