import XCTest
@testable import TermLLM

// MARK: - Test helpers

private final class DirectMockTransport: HubTransport, @unchecked Sendable {
    struct RecordedRequest: @unchecked Sendable {
        let url: URL
        let method: String
        let headers: [String: String]
        let body: Data?
    }
    private let lock = NSLock()
    private var _requests: [RecordedRequest] = []
    var handler: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    init(handler: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)) {
        self.handler = handler
    }

    var requests: [RecordedRequest] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    func execute(
        _ request: URLRequest,
        onUnauthorized: (@Sendable () async -> Void)?
    ) async throws -> (Data, HTTPURLResponse) {
        record(request)
        let (data, response) = try await handler(request)
        if response.statusCode == 401 || response.statusCode == 403 {
            await onUnauthorized?()
        }
        return (data, response)
    }

    private func record(_ request: URLRequest) {
        lock.lock(); defer { lock.unlock() }
        // Normalize header keys to lowercase for portable, case-insensitive assertions.
        let normalizedHeaders = (request.allHTTPHeaderFields ?? [:])
            .reduce(into: [String: String]()) { $0[$1.key.lowercased()] = $1.value }
        _requests.append(RecordedRequest(
            url: request.url!,
            method: request.httpMethod ?? "GET",
            headers: normalizedHeaders,
            body: request.httpBody
        ))
    }
}

private func jsonHTTP(
    _ json: String,
    url: URL = URL(string: "http://localhost:8767/direct/")!,
    status: Int = 200,
    headers: [String: String] = [:]
) -> (Data, HTTPURLResponse) {
    var h = ["Content-Type": "application/json"]
    for (k, v) in headers { h[k] = v }
    let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: h)!
    return (Data(json.utf8), resp)
}

private func makeClient(
    base: String = "http://localhost:8767/direct/",
    cookies: [HTTPCookie] = [],
    bearer: String? = nil,
    displayNameSource: @escaping @Sendable () async -> String? = { nil },
    handler: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
) -> (DirectNodeClient, DirectMockTransport) {
    let t = DirectMockTransport(handler: handler)
    let c = DirectNodeClient(
        base_url: URL(string: base)!,
        cookie_source: { cookies },
        bearer_source: { bearer },
        transport: t,
        display_name_source: displayNameSource
    )
    return (c, t)
}

private func webSessionCookie(
    host: String = "localhost",
    path: String = "/direct/",
    secure: Bool = false,
    expires: Date? = Date(timeIntervalSinceNow: 3600)
) -> HTTPCookie {
    var props: [HTTPCookiePropertyKey: Any] = [
        .name: "term_llm_web_session", .value: "sess-tok",
        .domain: host, .path: path,
    ]
    // HTTPCookiePropertyKey.secure expects a String ("TRUE"/"FALSE"), not a Bool.
    if secure { props[.secure] = "TRUE" }
    if let expires { props[.expires] = expires }
    return HTTPCookie(properties: props)!
}

// Minimal sessions/status JSON
private let emptyStatusJSON = #"{"sessions":[]}"#

// Minimal attention page JSON
// protocol_version: unseen/running = 1, input_required = 2 (per internal/session/attention.go)
private func attentionPageJSON(
    storeID: String = "store_abc",
    items: String = "[]",
    hasMore: Bool = false,
    version: Int = 1
) -> String {
    """
    {"protocol_version":\(version),"store_instance_id":"\(storeID)","snapshot_version":42,
     "items":\(items),"has_more":\(hasMore ? "true" : "false")}
    """
}

// MARK: - Model decoding tests

final class DirectNodeClientModelTests: XCTestCase {

    func testDirectNodeHealthDecodes() throws {
        let json = """
        {"status":"ok","agent":"direct-node","version":"1.2.3",
         "capabilities":["api","web","attention"]}
        """
        let h = try JSONDecoder().decode(DirectNodeHealth.self, from: Data(json.utf8))
        XCTAssertEqual(h.status, "ok")
        XCTAssertEqual(h.agent, "direct-node")
        XCTAssertEqual(h.version, "1.2.3")
        XCTAssertEqual(h.capabilities, ["api", "web", "attention"])
    }

    func testDirectNodeHealthBare200Decodes() throws {
        // Node without auth returns status only
        let h = try JSONDecoder().decode(DirectNodeHealth.self, from: Data(#"{"status":"ok"}"#.utf8))
        XCTAssertEqual(h.status, "ok")
        XCTAssertNil(h.agent)
        XCTAssertNil(h.version)
        XCTAssertNil(h.capabilities)
    }

    func testDirectAttentionPageDecodes() throws {
        let json = attentionPageJSON(storeID: "store_xyz", hasMore: true)
        let p = try JSONDecoder().decode(DirectAttentionPage.self, from: Data(json.utf8))
        XCTAssertEqual(p.store_instance_id, "store_xyz")
        XCTAssertTrue(p.has_more)
        XCTAssertTrue(p.items.isEmpty)
    }

    func testDirectAttentionItemDecodes() throws {
        let json = """
        {"session_id":"s1","session_number":7,"kind":"unseen","short_title":"My session",
         "attention_seq":42,"outcome":"completed","terminal_at":"2025-10-24T12:00:00Z"}
        """
        let item = try JSONDecoder().decode(DirectAttentionItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.session_id, "s1")
        XCTAssertEqual(item.session_number, 7)
        XCTAssertEqual(item.attention_seq, 42)
        XCTAssertEqual(item.terminal_at, "2025-10-24T12:00:00Z")
    }

    func testDirectNodeSessionsStatusDecodes() throws {
        let json = """
        {"sessions":[{"id":"s1","number":1,"short_title":"Test","active_run":true,
          "attention_unseen":false,"interaction_required":false}]}
        """
        let s = try JSONDecoder().decode(DirectNodeSessionsStatus.self, from: Data(json.utf8))
        XCTAssertEqual(s.sessions.count, 1)
        XCTAssertEqual(s.sessions[0].number, 1)
        XCTAssertEqual(s.sessions[0].active_run, true)
    }

    func testDirectAttentionKindRawValues() {
        XCTAssertEqual(DirectAttentionKind.unseen.rawValue, "unseen")
        XCTAssertEqual(DirectAttentionKind.running.rawValue, "running")
        XCTAssertEqual(DirectAttentionKind.input_required.rawValue, "input_required")
    }

    func testDirectNodeModelsKeepEveryWireKey() throws {
        try assertWireKeysRoundTrip(DirectAttentionPage.self, """
        {"protocol_version":2,"store_instance_id":"store","snapshot_version":42,"items":[],
         "next_cursor":"c2","has_more":true}
        """)
        try assertWireKeysRoundTrip(DirectAttentionItem.self, """
        {"session_id":"s1","session_number":7,"response_id":"r1","kind":"unseen","lifecycle_state":"terminal",
         "attention_seq":42,"short_title":"Short","long_title":"Long","outcome":"completed",
         "terminal_at":"2025-10-24T12:00:00Z","started_at":"2025-10-24T11:00:00Z","interaction_required":true,
         "pending_interaction_count":1,"pending_interaction_kinds":["approval"],
         "interaction_required_since":"2025-10-24T11:30:00Z","seen_through_seq":41,"seen_rev":3}
        """)
        try assertWireKeysRoundTrip(DirectNodeSessionEntry.self, """
        {"id":"s1","number":1,"project_id":"p1","project_name":"proj","short_title":"Short","long_title":"Long",
         "pinned":true,"active_run":true,"active_response_id":"r1","run_epoch":2,"started_rev":3,
         "started_at":1700000000000,"transcript_rev":4,"message_count":9,"last_message_at":1700000001000,
         "attention_store_instance_id":"store","attention_seq":7,"attention_response_id":"r0",
         "seen_through_seq":6,"seen_rev":5,"seen_source":"phone","attention_unseen":true,
         "attention_outcome":"completed","attention_terminal_at":1700000002000,"interaction_required":true,
         "pending_interaction_count":1,"pending_interaction_kinds":["approval"]}
        """)
    }
}

// MARK: - Mount path and resume path tests

final class DirectNodeClientMountTests: XCTestCase {

    func testMountPathRoot() {
        let c = DirectNodeClient(
            base_url: URL(string: "http://localhost:8767/")!,
            cookie_source: { [] }, bearer_source: { nil }
        )
        XCTAssertEqual(c.mount_path, "")
        XCTAssertEqual(c.expected_host, "localhost")
    }

    func testMountPathSubpath() {
        let c = DirectNodeClient(
            base_url: URL(string: "http://localhost:8767/direct/")!,
            cookie_source: { [] }, bearer_source: { nil }
        )
        XCTAssertEqual(c.mount_path, "/direct")
    }

    func testOriginOmitsDefaultHTTPPort() {
        let c = DirectNodeClient(
            base_url: URL(string: "http://localhost:80/")!,
            cookie_source: { [] }, bearer_source: { nil }
        )
        XCTAssertEqual(c.origin, "http://localhost")
    }

    func testOriginIncludesNonDefaultPort() {
        let c = DirectNodeClient(
            base_url: URL(string: "http://localhost:8767/direct/")!,
            cookie_source: { [] }, bearer_source: { nil }
        )
        XCTAssertEqual(c.origin, "http://localhost:8767")
    }

    func testResumePathWithNumber() {
        let c = DirectNodeClient(
            base_url: URL(string: "http://localhost:8767/direct/")!,
            cookie_source: { [] }, bearer_source: { nil }
        )
        XCTAssertEqual(c.resume_path(session_id: "uuid-abc", session_number: 42), "/direct/chat/42")
    }

    func testResumePathWithoutNumber() {
        let c = DirectNodeClient(
            base_url: URL(string: "http://localhost:8767/direct/")!,
            cookie_source: { [] }, bearer_source: { nil }
        )
        XCTAssertEqual(c.resume_path(session_id: "uuid-abc", session_number: nil), "/direct/chat/uuid-abc")
    }

    func testResumePathRootMount() {
        let c = DirectNodeClient(
            base_url: URL(string: "http://localhost:8767/")!,
            cookie_source: { [] }, bearer_source: { nil }
        )
        XCTAssertEqual(c.resume_path(session_id: "uuid-abc", session_number: 5), "/chat/5")
    }

    func testResumePathZeroNumberFallsToID() {
        let c = DirectNodeClient(
            base_url: URL(string: "http://localhost:8767/direct/")!,
            cookie_source: { [] }, bearer_source: { nil }
        )
        XCTAssertEqual(c.resume_path(session_id: "uuid-abc", session_number: 0), "/direct/chat/uuid-abc")
    }
}

// MARK: - Cookie filtering tests

final class DirectNodeClientCookieFilterTests: XCTestCase {

    private func client(base: String = "http://localhost:8767/direct/") -> DirectNodeClient {
        DirectNodeClient(base_url: URL(string: base)!, cookie_source: { [] }, bearer_source: { nil })
    }

    private func cookie(
        name: String = "term_llm_web_session", value: String = "v",
        domain: String = "localhost", path: String = "/direct/",
        secure: Bool = false, expires: Date? = Date(timeIntervalSinceNow: 3600)
    ) -> HTTPCookie {
        var props: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
        // HTTPCookiePropertyKey.secure expects a String ("TRUE"/"FALSE"), not a Bool.
        if secure { props[.secure] = "TRUE" }
        if let e = expires { props[.expires] = e }
        return HTTPCookie(properties: props)!
    }

    func testCorrectCookieAccepted() {
        let c = client()
        let url = URL(string: "http://localhost:8767/direct/v1/sessions/status")!
        XCTAssertEqual(c.filteredCookies([cookie()], for: url).count, 1)
    }

    func testHubTokenCookieRejected() {
        let c = client()
        let url = URL(string: "http://localhost:8767/direct/v1/sessions/status")!
        XCTAssertEqual(c.filteredCookies([cookie(name: "term_llm_hub_token")], for: url).count, 0)
    }

    func testHubSessionCookieRejected() {
        let c = client()
        let url = URL(string: "http://localhost:8767/direct/v1/sessions/status")!
        XCTAssertEqual(c.filteredCookies([cookie(name: "term_llm_hub_session")], for: url).count, 0)
    }

    func testArbitraryCookieNameRejected() {
        let c = client()
        let url = URL(string: "http://localhost:8767/direct/v1/sessions/status")!
        XCTAssertEqual(c.filteredCookies([cookie(name: "other_cookie")], for: url).count, 0)
    }

    func testWrongHostRejected() {
        let c = client()
        let url = URL(string: "http://localhost:8767/direct/v1/sessions/status")!
        XCTAssertEqual(c.filteredCookies([cookie(domain: "evil.example.com")], for: url).count, 0)
    }

    func testDomainCookieRejected() {
        let c = client()
        let url = URL(string: "http://localhost:8767/direct/v1/sessions/status")!
        XCTAssertEqual(c.filteredCookies([cookie(domain: ".localhost")], for: url).count, 0)
    }

    func testWrongPathRejected() {
        let c = client()
        let url = URL(string: "http://localhost:8767/direct/v1/sessions/status")!
        // Cookie at root path should be rejected for a mounted client
        XCTAssertEqual(c.filteredCookies([cookie(path: "/")], for: url).count, 0)
    }

    func testSiblingPathRejected() {
        let c = client()
        let url = URL(string: "http://localhost:8767/direct/v1/sessions/status")!
        // Cookie at /other/ is a sibling and must not leak to /direct/
        XCTAssertEqual(c.filteredCookies([cookie(path: "/other/")], for: url).count, 0)
    }

    func testSecureCookieRejectedOnHTTP() {
        let c = client()  // HTTP
        let url = URL(string: "http://localhost:8767/direct/v1/sessions/status")!
        XCTAssertEqual(c.filteredCookies([cookie(secure: true)], for: url).count, 0)
    }

    func testSecureCookieAcceptedOnHTTPS() {
        let c = client(base: "https://localhost/direct/")
        let url = URL(string: "https://localhost/direct/v1/sessions/status")!
        XCTAssertEqual(
            c.filteredCookies([cookie(domain: "localhost", path: "/direct/", secure: true)], for: url).count, 1
        )
    }

    func testExpiredCookieRejected() {
        let c = client()
        let url = URL(string: "http://localhost:8767/direct/v1/sessions/status")!
        XCTAssertEqual(c.filteredCookies([cookie(expires: Date(timeIntervalSinceNow: -1))], for: url).count, 0)
    }

    func testNonExpiringCookieAccepted() {
        let c = client()
        let url = URL(string: "http://localhost:8767/direct/v1/sessions/status")!
        XCTAssertEqual(c.filteredCookies([cookie(expires: nil)], for: url).count, 1)
    }

    func testRootMountAcceptsRootPath() {
        let c = client(base: "http://localhost:8767/")
        let url = URL(string: "http://localhost:8767/v1/sessions/status")!
        let rootCookie: HTTPCookie = {
            var props: [HTTPCookiePropertyKey: Any] = [
                .name: "term_llm_web_session", .value: "v",
                .domain: "localhost", .path: "/",
            ]
            props[.expires] = Date(timeIntervalSinceNow: 3600)
            return HTTPCookie(properties: props)!
        }()
        XCTAssertEqual(c.filteredCookies([rootCookie], for: url).count, 1)
    }
}

// MARK: - Transport-level tests

final class DirectNodeClientTests: XCTestCase {

    // MARK: Bearer injection

    func testBearerInjectedOnPost() async throws {
        let (client, transport) = makeClient(bearer: "tok-secret") { _ in
            jsonHTTP(#"{"cleared":1}"#)
        }
        _ = try await client.mark_attention_seen(
            AttentionSeenRequest(store_instance_id: "sid", session_id: "abc", attention_seq: 1)
        )
        let req = transport.requests[0]
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.headers["authorization"], "Bearer tok-secret")
    }

    func testSessionSearchHitsNodeWithBearerAndEncodedQuery() async throws {
        let (client, transport) = makeClient(bearer: "tok-secret") { _ in
            jsonHTTP("{\"sessions\":[{\"id\":\"s1\",\"short_title\":\"Hit\",\"snippet\":\"**x**\"}]}")
        }
        let response = try await client.search_sessions(node_id: "ignored", query: "fix ci", limit: 20)
        let req = transport.requests[0]
        XCTAssertEqual(req.url.path, "/direct/v1/sessions/search")
        XCTAssertEqual(URLComponents(url: req.url, resolvingAgainstBaseURL: false)?.percentEncodedQuery, "q=fix%20ci&limit=20")
        XCTAssertEqual(req.headers["authorization"], "Bearer tok-secret")
        XCTAssertEqual(response.sessions.map(\.id), ["s1"])
    }

    func testSessionStatusForIDsHitsNode() async throws {
        let (client, transport) = makeClient(bearer: "tok-secret") { _ in jsonHTTP(emptyStatusJSON) }
        _ = try await client.sessions_status(node_id: "ignored", ids: ["s1", "s2"])
        let req = transport.requests[0]
        XCTAssertEqual(req.url.path, "/direct/v1/sessions/status")
        XCTAssertEqual(URLComponents(url: req.url, resolvingAgainstBaseURL: false)?.percentEncodedQuery, "ids=s1,s2")
        XCTAssertEqual(req.headers["authorization"], "Bearer tok-secret")
    }

    func testBearerInjectedOnGet() async throws {
        let (client, transport) = makeClient(bearer: "tok-secret") { _ in
            jsonHTTP(emptyStatusJSON)
        }
        _ = try await client.sessions_status()
        XCTAssertEqual(transport.requests[0].headers["authorization"], "Bearer tok-secret",
                       "GET /v1/sessions/status must include Authorization: Bearer")
    }

    func testHealthzIncludesBearer() async throws {
        let (client, transport) = makeClient(bearer: "tok-health") { _ in
            jsonHTTP(#"{"status":"ok","agent":"direct-node","version":"1.0","capabilities":["api"]}"#)
        }
        _ = try await client.healthz()
        XCTAssertEqual(transport.requests[0].method, "GET")
        XCTAssertEqual(transport.requests[0].headers["authorization"], "Bearer tok-health")
    }

    func testHealthzNoBearerStillWorks() async throws {
        let (client, _) = makeClient(bearer: nil) { _ in
            jsonHTTP(#"{"status":"ok"}"#)
        }
        let result = try await client.healthz()
        XCTAssertEqual(result.status, "ok")
    }

    // MARK: Cookie forwarded on requests

    func testWebSessionCookieForwardedOnGet() async throws {
        let cookie = webSessionCookie(host: "localhost", path: "/direct/")
        let (client, transport) = makeClient(cookies: [cookie]) { _ in
            jsonHTTP(emptyStatusJSON)
        }
        _ = try await client.sessions_status()
        XCTAssertTrue(
            transport.requests[0].headers["cookie"]?.contains("term_llm_web_session") == true,
            "term_llm_web_session must be forwarded"
        )
    }

    func testHubCookieNotForwardedOnGet() async throws {
        var props: [HTTPCookiePropertyKey: Any] = [
            .name: "term_llm_hub_token", .value: "hub-tok",
            .domain: "localhost", .path: "/direct/",
        ]
        props[.expires] = Date(timeIntervalSinceNow: 3600)
        let hubCookie = HTTPCookie(properties: props)!
        let (client, transport) = makeClient(cookies: [hubCookie]) { _ in jsonHTTP(emptyStatusJSON) }
        _ = try await client.sessions_status()
        XCTAssertFalse(transport.requests[0].headers["cookie"]?.contains("term_llm_hub_token") == true)
    }

    // MARK: Origin on mutations

    func testOriginSetOnPost() async throws {
        let (client, transport) = makeClient { _ in jsonHTTP(#"{"cleared":1}"#) }
        _ = try await client.mark_attention_seen(
            AttentionSeenRequest(store_instance_id: "s", session_id: "id", attention_seq: 1)
        )
        XCTAssertEqual(transport.requests[0].headers["origin"], "http://localhost:8767")
    }

    func testOriginNotSetOnGet() async throws {
        let (client, transport) = makeClient { _ in jsonHTTP(emptyStatusJSON) }
        _ = try await client.sessions_status()
        XCTAssertNil(transport.requests[0].headers["origin"])
    }

    // MARK: Attention source header

    func testMarkSeenSendsAttentionSourceHeader() async throws {
        let (client, transport) = makeClient { _ in jsonHTTP(#"{"cleared":1}"#) }
        _ = try await client.mark_attention_seen(
            AttentionSeenRequest(store_instance_id: "store_x", session_id: "sess-1", attention_seq: 99)
        )
        XCTAssertEqual(transport.requests[0].headers["x-term-llm-attention-source"], "phone")
    }

    func testMarkSeenPostsToCorrectPath() async throws {
        let (client, transport) = makeClient { _ in jsonHTTP(#"{"cleared":1}"#) }
        _ = try await client.mark_attention_seen(
            AttentionSeenRequest(store_instance_id: "s", session_id: "sess-abc", attention_seq: 5)
        )
        XCTAssertEqual(transport.requests[0].url.path, "/direct/v1/sessions/sess-abc/attention/seen")
        XCTAssertEqual(transport.requests[0].method, "POST")
    }

    func testMarkSeenBodyEncodesCorrectFields() async throws {
        let (client, transport) = makeClient { _ in jsonHTTP(#"{"cleared":1}"#) }
        _ = try await client.mark_attention_seen(
            AttentionSeenRequest(store_instance_id: "store_xyz", session_id: "s1", attention_seq: 77)
        )
        let body = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: transport.requests[0].body!
        )
        XCTAssertEqual(body["store_instance_id"], .string("store_xyz"))
        XCTAssertEqual(body["through_seq"], .int(77))
        XCTAssertNil(body["session_id"], "session_id must not appear in body — it is in the path")
    }

    func testMarkSeenReturnsClearedOne() async throws {
        let (client, _) = makeClient { _ in
            jsonHTTP(#"{"store_instance_id":"s","session_id":"s1","latest_attention_seq":5}"#)
        }
        let result = try await client.mark_attention_seen(
            AttentionSeenRequest(store_instance_id: "s", session_id: "s1", attention_seq: 5)
        )
        XCTAssertEqual(result.cleared, 1)
    }

    // MARK: URL-encoded session IDs in path

    func testMarkSeenPathEncodesSessionID() async throws {
        let (client, transport) = makeClient { _ in jsonHTTP(#"{"cleared":1}"#) }
        _ = try await client.mark_attention_seen(
            AttentionSeenRequest(store_instance_id: "s", session_id: "sess/with/slashes", attention_seq: 1)
        )
        // url.path percent-decodes %2F back to '/', so we must check the raw absoluteString
        // to confirm that slashes were encoded as a single path segment.
        let raw = transport.requests[0].url.absoluteString
        XCTAssertFalse(raw.contains("sess/with/slashes"),
                       "Slashes in session ID must not appear unencoded in the URL")
        XCTAssertTrue(raw.contains("sess%2Fwith%2Fslashes"),
                      "Slashes in session ID must be percent-encoded as %2F")
    }

    // MARK: Path-segment percent-encoding

    /// A session ID that already contains a percent sign must not be double-encoded
    /// (%25 → %2525).  directNodePathEncoded uses .urlPathAllowed which does NOT
    /// include '%', so an existing '%' in the input is always encoded once.
    func testMarkSeenPathDoesNotDoubleEncodePercent() async throws {
        let (client, transport) = makeClient { _ in jsonHTTP(#"{"cleared":1}"#) }
        // Session ID contains a literal '%' (unusual but possible in opaque IDs)
        _ = try await client.mark_attention_seen(
            AttentionSeenRequest(store_instance_id: "s", session_id: "id%20weird", attention_seq: 1)
        )
        let raw = transport.requests[0].url.absoluteString
        // The % must appear as %25 (encoded once), not %2525 (double-encoded).
        XCTAssertTrue(raw.contains("id%2520weird"),
                      "Literal '%' in session ID must be encoded once as %25, producing %2520weird in the URL")
        XCTAssertFalse(raw.contains("id%20weird"),
                       "Pre-existing '%XX' in session ID must not pass through unencoded")
    }

    /// A session ID with query-special characters (?, &, =) must be encoded so they
    /// cannot escape the path segment into the query string.
    func testMarkSeenPathEncodesQuerySpecialChars() async throws {
        let (client, transport) = makeClient { _ in jsonHTTP(#"{"cleared":1}"#) }
        _ = try await client.mark_attention_seen(
            AttentionSeenRequest(store_instance_id: "s", session_id: "id?foo=bar&baz", attention_seq: 1)
        )
        let raw = transport.requests[0].url.absoluteString
        // The '?', '=' and '&' must be percent-encoded so they stay inside the path segment.
        XCTAssertFalse(raw.contains("id?foo=bar&baz"),
                       "Query-special chars in session ID must be percent-encoded in the path")
    }

    // MARK: Attention limit clamping

    func testListAttentionLimitClampedHigh() async throws {
        // list_attention makes 3 concurrent attention calls; serve all with empty pages
        let (client, transport) = makeClient { _ in jsonHTTP(attentionPageJSON()) }
        _ = try await client.list_attention(limit: 9999)
        // Both attention calls should have limit=500
        let attentionReqs = transport.requests.filter { $0.url.path.contains("/v1/attention") }
        for req in attentionReqs {
            let query = req.url.query ?? ""
            XCTAssertTrue(query.contains("limit=500"), "limit must be clamped to 500; got \(query)")
        }
    }

    func testListAttentionLimitClampedLow() async throws {
        let (client, transport) = makeClient { _ in jsonHTTP(attentionPageJSON()) }
        _ = try await client.list_attention(limit: 0)
        let attentionReqs = transport.requests.filter { $0.url.path.contains("/v1/attention") }
        for req in attentionReqs {
            let query = req.url.query ?? ""
            XCTAssertTrue(query.contains("limit=1"), "limit must be clamped to 1; got \(query)")
        }
    }

    func testListAttentionNoLimitOmitsLimitParam() async throws {
        let (client, transport) = makeClient { _ in jsonHTTP(attentionPageJSON()) }
        _ = try await client.list_attention(limit: nil)
        let attentionReqs = transport.requests.filter { $0.url.path.contains("/v1/attention") }
        for req in attentionReqs {
            XCTAssertFalse(req.url.query?.contains("limit=") == true,
                           "No limit → no limit param in query")
        }
    }

    // MARK: Attention kinds

    func testListAttentionQueriesUnseenAndInputRequired() async throws {
        let (client, transport) = makeClient { _ in jsonHTTP(attentionPageJSON()) }
        _ = try await client.list_attention(limit: 50)
        let attentionPaths = transport.requests
            .filter { $0.url.path.contains("/v1/attention") }
            .map { $0.url.query ?? "" }
        let hasUnseen = attentionPaths.contains { $0.contains("kind=unseen") }
        let hasInput  = attentionPaths.contains { $0.contains("kind=input_required") }
        XCTAssertTrue(hasUnseen,  "list_attention must query kind=unseen")
        XCTAssertTrue(hasInput,   "list_attention must query kind=input_required")
    }

    func testListNodeAttentionUsesGivenKind() async throws {
        let (client, transport) = makeClient { _ in jsonHTTP(attentionPageJSON()) }
        _ = try await client.list_node_attention(kind: .running, limit: 25)
        let req = transport.requests[0]
        XCTAssertTrue(req.url.query?.contains("kind=running") == true)
        XCTAssertTrue(req.url.query?.contains("limit=25") == true)
    }

    // MARK: 409 bounded retry

    func testListNodeAttentionRetries409UntilSuccess() async throws {
        // Test 409 retry via single-kind list_node_attention (no concurrency complications)
        let callCount = HubTestBox(0)
        let (client, transport) = makeClient { _ in
            callCount.update { $0 += 1 }
            if callCount.value <= 2 {
                return jsonHTTP(#"{"error":{"message":"conflict","type":"conflict_error"}}"#, status: 409)
            }
            return jsonHTTP(attentionPageJSON())
        }
        _ = try await client.list_node_attention(kind: .unseen, limit: nil)
        XCTAssertGreaterThan(transport.requests.count, 2, "should have retried on 409")
    }

    func testListAttentionThrowsAfterMaxRetries() async throws {
        let (client, _) = makeClient { _ in
            jsonHTTP(#"{"error":{"message":"conflict","type":"conflict_error"}}"#, status: 409)
        }
        do {
            _ = try await client.list_attention()
            XCTFail("Expected 409 error after retries exhausted")
        } catch let err as HubAPIError {
            XCTAssertEqual(err.status, 409)
        }
    }

    /// list_node_attention must also exhaust its bounded 409 retry and surface the error,
    /// consistently with list_attention (both use fetchAttentionWithRetry).
    func testListNodeAttentionThrowsAfterMaxRetries() async throws {
        let callCount = HubTestBox(0)
        let (client, transport) = makeClient { _ in
            callCount.update { $0 += 1 }
            return jsonHTTP(#"{"error":{"message":"conflict","type":"conflict_error"}}"#, status: 409)
        }
        do {
            _ = try await client.list_node_attention(kind: .unseen, limit: nil)
            XCTFail("Expected 409 error after retries exhausted")
        } catch let err as HubAPIError {
            XCTAssertEqual(err.status, 409)
        }
        // Must have attempted maxAttempts (3) times, no more.
        XCTAssertEqual(transport.requests.count, 3, "bounded retry must attempt exactly 3 times")
    }

    func test409ThrownByMarkAttentionSeen() async throws {
        let (client, _) = makeClient { _ in
            jsonHTTP(
                #"{"error":{"message":"attention marker changed","type":"conflict_error"}}"#,
                status: 409
            )
        }
        do {
            _ = try await client.mark_attention_seen(
                AttentionSeenRequest(store_instance_id: "s", session_id: "id", attention_seq: 1)
            )
            XCTFail("Expected 409")
        } catch let err as HubAPIError {
            XCTAssertEqual(err.status, 409)
            XCTAssertEqual(err.type, "conflict_error")
        }
    }

    // MARK: 501 for unsupported methods

    func test501ForTestNode() async throws {
        let (client, _) = makeClient { _ in jsonHTTP("{}") }
        await assertThrows501 { _ = try await client.test_node(NodeFormData(name: "", url: "", token: "")) }
    }

    func test501ForAddNode() async throws {
        let (client, _) = makeClient { _ in jsonHTTP("{}") }
        await assertThrows501 { _ = try await client.add_node(NodeFormData(name: "", url: "", token: "")) }
    }

    func test501ForRemoveNode() async throws {
        let (client, _) = makeClient { _ in jsonHTTP("{}") }
        await assertThrows501 { _ = try await client.remove_node(id: "n1") }
    }

    func test501ForReorderNodes() async throws {
        let (client, _) = makeClient { _ in jsonHTTP("{}") }
        await assertThrows501 { _ = try await client.reorder_nodes(node_ids: []) }
    }

    func test501ForClearAttention() async throws {
        let (client, _) = makeClient { _ in jsonHTTP("{}") }
        await assertThrows501 { _ = try await client.clear_attention() }
    }

    func test501ForRegistrationInfo() async throws {
        let (client, _) = makeClient { _ in jsonHTTP("{}") }
        await assertThrows501 { _ = try await client.registration_info() }
    }

    func test501ForSession() async throws {
        let (client, _) = makeClient { _ in jsonHTTP("{}") }
        await assertThrows501 { _ = try await client.session() }
    }

    func test501ForListCredentials() async throws {
        let (client, _) = makeClient { _ in jsonHTTP("{}") }
        await assertThrows501 { _ = try await client.list_credentials() }
    }

    func test501ForLogout() async throws {
        let (client, _) = makeClient { _ in jsonHTTP("{}") }
        await assertThrows501 { _ = try await client.logout() }
    }

    func test501ForBeginLogin() async throws {
        let (client, _) = makeClient { _ in jsonHTTP("{}") }
        await assertThrows501 { _ = try await client.begin_login(return_path: "/") }
    }

    func test501ForFinishLogin() async throws {
        let (client, _) = makeClient { _ in jsonHTTP("{}") }
        await assertThrows501 { _ = try await client.finish_login(credential: Data()) }
    }

    func test501ForVerifyGrant() async throws {
        let (client, _) = makeClient { _ in jsonHTTP("{}") }
        await assertThrows501 { _ = try await client.verify_grant(prefix: .bootstrap, code: "123") }
    }

    func test501ForAuthorizeNative() async throws {
        let (client, _) = makeClient { _ in jsonHTTP("{}") }
        await assertThrows501 { _ = try await client.authorize_native(challenge: "c") }
    }

    // MARK: list_delegations returns empty

    func testListDelegationsEmpty() async throws {
        let (client, transport) = makeClient { _ in jsonHTTP("{}") }
        let result = try await client.list_delegations()
        XCTAssertTrue(result.delegations.isEmpty)
        XCTAssertTrue(transport.requests.isEmpty, "list_delegations must not make any network request")
    }

    // MARK: on_unauthorized

    func testOnUnauthorizedFiresOn401() async {
        let fired = HubTestBox(false)
        let (client, _) = makeClient { _ in
            jsonHTTP(#"{"error":{"message":"Unauthorized"}}"#, status: 401)
        }
        client.on_unauthorized = { fired.set(true) }
        do { _ = try await client.sessions_status() } catch {}
        XCTAssertTrue(fired.value)
    }

    func testOnUnauthorizedFiresOn403() async {
        let fired = HubTestBox(false)
        let (client, _) = makeClient { _ in
            jsonHTTP(#"{"error":{"message":"Forbidden"}}"#, status: 403)
        }
        client.on_unauthorized = { fired.set(true) }
        do { _ = try await client.sessions_status() } catch {}
        XCTAssertTrue(fired.value)
    }

    func testOnUnauthorizedNotFiredOnSuccess() async throws {
        let fired = HubTestBox(false)
        let (client, _) = makeClient { _ in jsonHTTP(emptyStatusJSON) }
        client.on_unauthorized = { fired.set(true) }
        _ = try await client.sessions_status()
        XCTAssertFalse(fired.value)
    }

    func testOnUnauthorizedEpochScoped() async {
        // Set callback, change it before the 401 fires — stale callback must be silenced.
        let firstCallbackFired = HubTestBox(false)
        let secondCallbackFired = HubTestBox(false)

        let gate = DirectGate()
        let (client, _) = makeClient { [gate] _ in
            await gate.wait()   // Pause until we replace the callback
            return jsonHTTP(#"{"error":{"message":"Unauth"}}"#, status: 401)
        }

        client.on_unauthorized = { firstCallbackFired.set(true) }

        let task = Task {
            do { _ = try await client.sessions_status() } catch {}
        }

        // Replace callback before the transport fires 401
        client.on_unauthorized = { secondCallbackFired.set(true) }
        await gate.release()
        await task.value

        XCTAssertFalse(firstCallbackFired.value, "Stale callback must not fire")
        XCTAssertTrue(secondCallbackFired.value, "Current epoch callback must fire")
    }

    // MARK: validate_bearer

    func testValidateBearerRejectsNoIdentityMarkers() async throws {
        // Server is open (no auth required) — returns 200 but no identity
        let (client, _) = makeClient { _ in jsonHTTP(#"{"status":"ok"}"#) }
        do {
            _ = try await client.validate_bearer(token: "bad-token")
            XCTFail("Expected rejection of bare 200 without identity markers")
        } catch let err as HubAPIError {
            XCTAssertEqual(err.status, 401)
        }
    }

    func testValidateBearerAcceptsIdentityResponse() async throws {
        let (client, _) = makeClient { _ in
            jsonHTTP(#"{"status":"ok","agent":"direct-node","version":"1.2","capabilities":["api"]}"#)
        }
        let health = try await client.validate_bearer(token: "good-token")
        XCTAssertEqual(health.agent, "direct-node")
    }

    func testValidateBearerSendsNoCookies() async throws {
        let cookie = webSessionCookie()
        let (client, transport) = makeClient(cookies: [cookie]) { _ in
            jsonHTTP(#"{"status":"ok","version":"1.0","capabilities":["api"]}"#)
        }
        _ = try await client.validate_bearer(token: "tok")
        XCTAssertNil(transport.requests[0].headers["cookie"],
                     "validate_bearer must not inject ambient cookies")
    }

    func testValidateBearerDoesNotFireOnUnauthorized() async {
        let fired = HubTestBox(false)
        let (client, _) = makeClient { _ in
            jsonHTTP(#"{"error":{"message":"Unauthorized"}}"#, status: 401)
        }
        client.on_unauthorized = { fired.set(true) }
        do { _ = try await client.validate_bearer(token: "bad") } catch {}
        XCTAssertFalse(fired.value, "validate_bearer must not fire on_unauthorized on failure")
    }

    func testValidateBearerOnlyVersionMarkerSuffices() async throws {
        let (client, _) = makeClient { _ in
            jsonHTTP(#"{"status":"ok","version":"2.0"}"#)
        }
        let health = try await client.validate_bearer(token: "tok")
        XCTAssertEqual(health.version, "2.0")
    }

    func testValidateBearerOnlyCapabilitiesMarkerSuffices() async throws {
        let (client, _) = makeClient { _ in
            jsonHTTP(#"{"status":"ok","capabilities":["api"]}"#)
        }
        let health = try await client.validate_bearer(token: "tok")
        XCTAssertEqual(health.capabilities, ["api"])
    }

    // MARK: list_nodes adapts sessions_status

    func testListNodesReturnsOneDirectNode() async throws {
        // list_nodes fetches sessions/status (required) + /healthz (best-effort) concurrently
        let (client, _) = makeClient { req in
            if req.url?.path.hasSuffix("/healthz") == true {
                return jsonHTTP(#"{"status":"ok","version":"1.0","agent":"my-agent"}"#)
            }
            return jsonHTTP(emptyStatusJSON)
        }
        let result = try await client.list_nodes()
        XCTAssertEqual(result.nodes.count, 1)
        XCTAssertEqual(result.nodes[0].id, "direct-node")
        XCTAssertEqual(result.nodes[0].status.reachable, true)
    }

    func testListNodesPopulatesActiveSessions() async throws {
        let statusJSON = """
        {"sessions":[
          {"id":"s1","number":1,"short_title":"Active","active_run":true,"interaction_required":false},
          {"id":"s2","number":2,"short_title":"Recent","active_run":false,"interaction_required":false}
        ]}
        """
        let (client, _) = makeClient { req in
            if req.url?.path.hasSuffix("/healthz") == true {
                return jsonHTTP(#"{"status":"ok"}"#, status: 401)
            }
            return jsonHTTP(statusJSON)
        }
        let result = try await client.list_nodes()
        let sessions = result.nodes[0].sessions
        XCTAssertEqual(sessions?.active_count, 1)
        XCTAssertEqual(sessions?.active?.count, 1)
        XCTAssertEqual(sessions?.active?[0].id, "s1")
        XCTAssertEqual(sessions?.recent?.count, 1)
        XCTAssertEqual(sessions?.recent?[0].id, "s2")
    }

    func testListNodesSessionResumePath() async throws {
        let statusJSON = """
        {"sessions":[{"id":"uuid-x","number":42,"short_title":"T","active_run":false,"interaction_required":false}]}
        """
        let (client, _) = makeClient { req in
            if req.url?.path.hasSuffix("/healthz") == true {
                return jsonHTTP(#"{"status":"ok"}"#, status: 401)
            }
            return jsonHTTP(statusJSON)
        }
        let result = try await client.list_nodes()
        let session = result.nodes[0].sessions?.recent?[0]
        XCTAssertEqual(session?.resume_path, "/direct/chat/42")
    }

    func testListNodesNewSessionPath() async throws {
        // list_nodes makes 2 concurrent requests: sessions/status + /healthz
        // health can fail (returns 401) without failing list_nodes
        let (client, _) = makeClient { req in
            if req.url?.path.hasSuffix("/healthz") == true {
                return jsonHTTP(#"{"status":"ok"}"#, status: 401)
            }
            return jsonHTTP(emptyStatusJSON)
        }
        let result = try await client.list_nodes()
        XCTAssertEqual(result.nodes[0].new_session_path, "/direct/?new=1")
    }

    func testListNodesUnseenCount() async throws {
        let statusJSON = """
        {"sessions":[
          {"id":"s1","short_title":"A","active_run":false,"interaction_required":false,"attention_unseen":true},
          {"id":"s2","short_title":"B","active_run":false,"interaction_required":false,"attention_unseen":false}
        ]}
        """
        let (client, _) = makeClient { req in
            if req.url?.path.hasSuffix("/healthz") == true {
                return jsonHTTP(#"{"status":"ok"}"#, status: 401)
            }
            return jsonHTTP(statusJSON)
        }
        let result = try await client.list_nodes()
        XCTAssertEqual(result.nodes[0].sessions?.unseen_count, 1)
    }

    func testListNodesHealthIdentityUsedAsName() async throws {
        // When /healthz returns identity markers, node name = health.agent
        let (client, _) = makeClient(displayNameSource: { "Saved connection" }) { req in
            if req.url?.path.hasSuffix("/healthz") == true {
                return jsonHTTP(#"{"status":"ok","version":"2.1","agent":"my-server","capabilities":["api"]}"#)
            }
            return jsonHTTP(emptyStatusJSON)
        }
        let result = try await client.list_nodes()
        XCTAssertEqual(result.nodes[0].name, "my-server")
        XCTAssertEqual(result.nodes[0].status.agent, "my-server")
        XCTAssertEqual(result.nodes[0].status.version, "2.1")
        XCTAssertEqual(result.nodes[0].status.capabilities, ["api"])
    }

    func testListNodesHealthFailureFallbackToSentinel() async throws {
        // A health failure must not fail list_nodes; sentinel "direct-node" is used
        let (client, _) = makeClient { req in
            if req.url?.path.hasSuffix("/healthz") == true {
                return jsonHTTP(#"{"status":"ok"}"#, status: 401)
            }
            return jsonHTTP(emptyStatusJSON)
        }
        let result = try await client.list_nodes()
        XCTAssertEqual(result.nodes[0].name, "direct-node")
        XCTAssertEqual(result.nodes[0].status.agent, "direct-node")
    }

    func testListNodesBlankOrMissingHealthAgentUsesSavedDisplayName() async throws {
        let healthResponses: [(String, Int)] = [
            (#"{"status":"ok","agent":"","version":"2.1","capabilities":["api"]}"#, 200),
            (#"{"status":"ok","agent":" \t\n ","version":"2.1"}"#, 200),
            (#"{"status":"ok"}"#, 200),
            (#"{"status":"ok","agent":null}"#, 200),
            (#"{"message":"Unavailable"}"#, 503),
        ]
        for (healthJSON, statusCode) in healthResponses {
            let (client, _) = makeClient(displayNameSource: { "  Saved laptop \n" }) { req in
                if req.url?.path.hasSuffix("/healthz") == true {
                    return jsonHTTP(healthJSON, status: statusCode)
                }
                return jsonHTTP(emptyStatusJSON)
            }
            let result = try await client.list_nodes()
            XCTAssertEqual(result.nodes[0].name, "Saved laptop", healthJSON)
            XCTAssertEqual(result.nodes[0].status.agent, "Saved laptop", healthJSON)
            XCTAssertEqual(result.nodes[0].id, "direct-node")
        }
    }

    func testListNodesHealthTransportFailureUsesSavedDisplayName() async throws {
        let (client, _) = makeClient(displayNameSource: { "Saved laptop" }) { req in
            if req.url?.path.hasSuffix("/healthz") == true {
                throw URLError(.timedOut)
            }
            return jsonHTTP(emptyStatusJSON)
        }
        let result = try await client.list_nodes()
        XCTAssertEqual(result.nodes[0].name, "Saved laptop")
        XCTAssertEqual(result.nodes[0].status.agent, "Saved laptop")
    }

    func testListNodesBlankNamesFallBackToSentinel() async throws {
        let displayNames: [String?] = [nil, "", " \t\n "]
        for displayName in displayNames {
            let (client, _) = makeClient(displayNameSource: { displayName }) { req in
                if req.url?.path.hasSuffix("/healthz") == true {
                    return jsonHTTP(#"{"status":"ok","agent":" \t\n "}"#)
                }
                return jsonHTTP(emptyStatusJSON)
            }
            let result = try await client.list_nodes()
            XCTAssertEqual(result.nodes[0].name, "direct-node")
            XCTAssertEqual(result.nodes[0].status.agent, "direct-node")
        }
    }

    func testListNodesTrimsValidHealthAgentAndRetainsNumericName() async throws {
        for agent in ["  my-agent \n", "200"] {
            let healthData = try JSONEncoder().encode(DirectNodeHealth(
                status: "ok", agent: agent, version: "2.1", capabilities: nil
            ))
            let healthJSON = String(decoding: healthData, as: UTF8.self)
            let (client, _) = makeClient(displayNameSource: { "Saved laptop" }) { req in
                if req.url?.path.hasSuffix("/healthz") == true {
                    return jsonHTTP(healthJSON)
                }
                return jsonHTTP(emptyStatusJSON)
            }
            let result = try await client.list_nodes()
            let expected = agent.trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(result.nodes[0].name, expected)
            XCTAssertEqual(result.nodes[0].status.agent, expected)
        }
    }

    @MainActor
    func testListNodesUsesLiveWorkspaceDisplayNameAfterMetadataRename() async throws {
        var connection = HubConnection(id: UUID(), name: "Original laptop", kind: .directNode,
                                       url: URL(string: "https://direct.example/")!)
        let transport = DirectMockTransport { req in
            if req.url?.path.hasSuffix("/healthz") == true {
                return jsonHTTP(#"{"status":"ok","agent":"","version":"2.1"}"#)
            }
            return jsonHTTP(emptyStatusJSON)
        }
        let source = HubSourceWorkspace(connection: connection, bearerStorage: HubMemoryBearerStorage(),
                                        dataStore: .nonPersistent(), transport: transport)
        defer { source.dispose(removeCredentials: true) }
        let client = try XCTUnwrap(source.directClient)
        let initial = try await client.list_nodes()
        XCTAssertEqual(initial.nodes[0].name, "Original laptop")

        connection.name = "Renamed laptop"
        source.updateMetadata(connection)
        let renamed = try await client.list_nodes()
        XCTAssertEqual(renamed.nodes[0].name, "Renamed laptop")
        XCTAssertEqual(renamed.nodes[0].status.agent, "Renamed laptop")
    }

    func testListNodesConversationCountLabels() async throws {
        for count in [0, 1, 2, 200] {
            let sessions = (0..<count).map { #"{"id":"s\#($0)","short_title":"Session"}"# }
            let statusJSON = "{\"sessions\":[\(sessions.joined(separator: ","))]}"
            let (client, _) = makeClient { req in
                if req.url?.path.hasSuffix("/healthz") == true {
                    return jsonHTTP(#"{"status":"ok"}"#)
                }
                return jsonHTTP(statusJSON)
            }
            let result = try await client.list_nodes()
            let expected = count == 1 ? "1 conversation" : "\(count) conversations"
            XCTAssertEqual(result.nodes[0].sessions?.count_label, expected)
        }
    }

    // MARK: list_attention aggregates

    func testListAttentionBuildsInboxFromUnseen() async throws {
        let itemJSON = """
        {"session_id":"sess-1","session_number":3,"short_title":"My work",
         "attention_seq":77,"outcome":"completed","terminal_at":"2025-10-24T00:00:00Z"}
        """
        let unseenPage = attentionPageJSON(storeID: "store_u", items: "[\(itemJSON)]")
        let inputPage  = attentionPageJSON(storeID: "store_i")
        let (client, _) = makeClient { req in
            let query = req.url?.query ?? ""
            if query.contains("kind=unseen") { return jsonHTTP(unseenPage) }
            return jsonHTTP(inputPage) // input_required and running both return empty
        }
        let result = try await client.list_attention()
        XCTAssertEqual(result.inbox.count, 1)
        let item = result.inbox[0]
        XCTAssertEqual(item.node_id, "direct-node")
        XCTAssertEqual(item.session_id, "sess-1")
        XCTAssertEqual(item.session_number, 3)
        XCTAssertEqual(item.attention_seq, 77)
        XCTAssertEqual(item.resume_path, "/direct/chat/3")
        XCTAssertEqual(item.store_instance_id, "store_u")
    }

    func testListAttentionBuildsInputRequired() async throws {
        let itemJSON = """
        {"session_id":"sess-2","session_number":null,"short_title":"Needs input",
         "pending_interaction_count":2,"pending_interaction_kinds":["ask_user","approval"]}
        """
        let unseenPage = attentionPageJSON()
        // input_required uses protocol_version=2 per server (internal/session/attention.go)
        let inputPage  = attentionPageJSON(storeID: "store_i", items: "[\(itemJSON)]", version: 2)
        let (client, _) = makeClient { req in
            let query = req.url?.query ?? ""
            if query.contains("kind=input_required") { return jsonHTTP(inputPage) }
            return jsonHTTP(unseenPage) // unseen and running both return empty
        }
        let result = try await client.list_attention()
        XCTAssertEqual(result.input_required.count, 1)
        let ir = result.input_required[0]
        XCTAssertEqual(ir.session_id, "sess-2")
        XCTAssertEqual(ir.pending_interaction_count, 2)
        XCTAssertEqual(ir.pending_interaction_kinds, ["ask_user", "approval"])
        XCTAssertEqual(ir.resume_path, "/direct/chat/sess-2")
    }

    func testListAttentionRunningCountFromRunningKind() async throws {
        // Running count comes from concurrent kind=running attention call (not sessions/status)
        let runningItemJSON = """
        {"session_id":"s1","short_title":"A","attention_seq":1}
        """
        let runningPage = attentionPageJSON(items: "[\(runningItemJSON)]")
        let (client, _) = makeClient { req in
            let query = req.url?.query ?? ""
            if query.contains("kind=running") { return jsonHTTP(runningPage) }
            return jsonHTTP(attentionPageJSON()) // unseen + input_required empty
        }
        let result = try await client.list_attention()
        XCTAssertEqual(result.total_running, 1)
    }

    func testListAttentionHasMorePropagated() async throws {
        let unseenPage = attentionPageJSON(hasMore: true)
        let inputPage  = attentionPageJSON(hasMore: false)
        let (client, _) = makeClient { req in
            let query = req.url?.query ?? ""
            if query.contains("kind=unseen") { return jsonHTTP(unseenPage) }
            return jsonHTTP(inputPage) // input_required and running
        }
        let result = try await client.list_attention()
        XCTAssertTrue(result.has_more)
    }

    func testListAttentionSyntheticNodePresent() async throws {
        let (client, _) = makeClient { _ in jsonHTTP(attentionPageJSON()) }
        let result = try await client.list_attention()
        XCTAssertEqual(result.nodes.count, 1)
        XCTAssertEqual(result.nodes[0].node_id, "direct-node")
    }

    // MARK: sessions_status path

    func testSessionsStatusPath() async throws {
        let (client, transport) = makeClient { _ in jsonHTTP(emptyStatusJSON) }
        _ = try await client.sessions_status()
        XCTAssertEqual(transport.requests[0].url.path, "/direct/v1/sessions/status")
        XCTAssertEqual(transport.requests[0].method, "GET")
    }

    // MARK: node_health

    func testNodeHealthReturnsFullPayload() async throws {
        let (client, _) = makeClient { _ in
            jsonHTTP(#"{"status":"ok","agent":"direct-node","version":"2.1","capabilities":["api","web"]}"#)
        }
        let h = try await client.node_health()
        XCTAssertEqual(h.agent, "direct-node")
        XCTAssertEqual(h.version, "2.1")
    }

    // MARK: Mounted path routing

    func testMountedAttentionPath() async throws {
        // list_attention makes 3 concurrent attention calls; serve all with empty pages
        let (client, transport) = makeClient(base: "http://localhost:8767/work/") { _ in
            jsonHTTP(attentionPageJSON())
        }
        _ = try await client.list_attention()
        let paths = transport.requests.map(\.url.path)
        XCTAssertTrue(paths.contains { $0.hasPrefix("/work/v1/attention") })
    }

    func testMountedMarkSeenPath() async throws {
        let (client, transport) = makeClient(base: "http://localhost:8767/home/") { _ in
            jsonHTTP(#"{"cleared":1}"#)
        }
        _ = try await client.mark_attention_seen(
            AttentionSeenRequest(store_instance_id: "s", session_id: "abc", attention_seq: 1)
        )
        XCTAssertEqual(
            transport.requests[0].url.path,
            "/home/v1/sessions/abc/attention/seen"
        )
    }

    // MARK: Error handling

    func testNon2xxThrowsHubAPIError() async throws {
        let (client, _) = makeClient { _ in
            jsonHTTP(#"{"error":{"message":"Not found","type":"not_found"}}"#, status: 404)
        }
        do {
            _ = try await client.sessions_status()
            XCTFail("Expected error")
        } catch let err as HubAPIError {
            XCTAssertEqual(err.status, 404)
            XCTAssertEqual(err.message, "Not found")
            XCTAssertEqual(err.type, "not_found")
        }
    }

    func testEmptyResponseThrows() async throws {
        let (client, _) = makeClient { req in
            let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(), http)
        }
        do {
            _ = try await client.sessions_status()
            XCTFail("Expected empty-response error")
        } catch let err as HubAPIError {
            XCTAssertTrue(err.message.contains("empty"))
        }
    }

    // MARK: Private helper

    private func assertThrows501(
        _ block: @escaping () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await block()
            XCTFail("Expected HubAPIError(status: 501)", file: file, line: line)
        } catch let err as HubAPIError {
            XCTAssertEqual(err.status, 501, file: file, line: line)
        } catch {
            XCTFail("Expected HubAPIError, got \(error)", file: file, line: line)
        }
    }
}

// MARK: - Concurrency gate for epoch test

private actor DirectGate {
    private var released = false
    private var cont: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { cont = $0 }
    }

    func release() {
        released = true
        cont?.resume()
        cont = nil
    }
}

extension DirectNodeClientTests {
    func testMarkSeenRejectsEmptyAndDotPathSegmentsWithoutDispatch() async throws {
        let (client, transport) = makeClient { _ in jsonHTTP(#"{"cleared":1}"#) }
        for id in ["", ".", ".."] {
            do {
                _ = try await client.mark_attention_seen(AttentionSeenRequest(store_instance_id: "s", session_id: id, attention_seq: 1))
                XCTFail("Ambiguous session segment accepted")
            } catch let error as HubAPIError { XCTAssertEqual(error.status, 0) }
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testCredentialReadCannotMoveOldRequestIntoNewAuthEpoch() async throws {
        for health in [false, true] {
            let gate = DirectCredentialGate()
            let reading = expectation(description: "direct credential read suspended")
            let transport = DirectMockTransport { request in jsonHTTP(emptyStatusJSON, url: request.url!) }
            let client = DirectNodeClient(base_url: URL(string: "https://node.example/direct/")!, cookie_source: {
                reading.fulfill()
                await gate.wait()
                return []
            }, bearer_source: { "fixture-token" }, transport: transport)
            let request = Task {
                if health { _ = try await client.node_health() }
                else { _ = try await client.sessions_status() }
            }
            await fulfillment(of: [reading], timeout: 2)
            client.on_unauthorized = {}
            await gate.release()
            do { try await request.value; XCTFail("Old direct request must not dispatch") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertTrue(transport.requests.isEmpty)
        }
    }
}
private actor DirectCredentialGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { if !released { await withCheckedContinuation { continuation = $0 } } }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
