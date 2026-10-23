import XCTest
@testable import TermLLM

// MARK: - Cookie recorder

/// Thread-safe cookie recorder that replaces UnsafeMutablePointer<[[HTTPCookie]]>
/// for capturing sunk cookies.  The reference is captured by the sink closure,
/// which may outlive the test method frame — unlike a stack pointer.
private final class CookieRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _batches: [[HTTPCookie]] = []

    var batches: [[HTTPCookie]] {
        lock.lock()
        defer { lock.unlock() }
        return _batches
    }

    var count: Int { batches.count }

    func append(_ cookies: [HTTPCookie]) {
        lock.lock()
        _batches.append(cookies)
        lock.unlock()
    }
}

// Mutable state shared with Foundation/Network delegate queues in tests.
private final class HubTestBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
    func set(_ value: Value) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}

private actor HubRequestGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

// MARK: - Mock transport

/// Closure-based mock transport that records requests and returns canned responses.
/// No URLProtocol — tests are deterministic and exercise the real HubClient logic.
private final class MockTransport: HubTransport, @unchecked Sendable {
    struct RecordedRequest: @unchecked Sendable {
        let url: URL
        let method: String
        let headers: [String: String]
        let body: Data?
    }
    var requests: [RecordedRequest] = []
    var handler: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    init(handler: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)) {
        self.handler = handler
    }

    func execute(
        _ request: URLRequest,
        onUnauthorized: (@Sendable () async -> Void)?
    ) async throws -> (Data, HTTPURLResponse) {
        let headers = request.allHTTPHeaderFields ?? [:]
        requests.append(RecordedRequest(
            url: request.url!, method: request.httpMethod ?? "GET",
            headers: headers, body: request.httpBody
        ))
        let (data, response) = try await handler(request)
        // Replicate real transport's unauthorized callback
        if response.statusCode == 401 || response.statusCode == 403 {
            await onUnauthorized?()
        }
        return (data, response)
    }
}

private func jsonResponse(
    _ json: String,
    url: URL = URL(string: "https://hub.example.com/")!,
    status: Int = 200,
    headers: [String: String] = [:]
) -> (Data, HTTPURLResponse) {
    var allHeaders = ["Content-Type": "application/json"]
    for (k, v) in headers { allHeaders[k] = v }
    let http = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: allHeaders)!
    return (Data(json.utf8), http)
}

private func htmlResponse(
    _ html: String,
    url: URL = URL(string: "https://hub.example.com/")!,
    status: Int = 200,
    headers: [String: String] = [:]
) -> (Data, HTTPURLResponse) {
    var allHeaders = ["Content-Type": "text/html"]
    for (k, v) in headers { allHeaders[k] = v }
    let http = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: allHeaders)!
    return (Data(html.utf8), http)
}

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
        XCTAssertEqual(resp.resolver_error, "timeout")
    }

    func testNodesResponseNilResolverError() throws {
        let json = """
        {"nodes":[]}
        """
        XCTAssertNil(try JSONDecoder().decode(NodesResponse.self, from: Data(json.utf8)).resolver_error)
    }

    func testAttentionResponseDecodes() throws {
        let json = """
        {"total_running":3,"total_input_required":1,"total_unseen":5,
         "nodes":[],"input_required":[],"inbox":[],"has_more":false}
        """
        let resp = try JSONDecoder().decode(AttentionResponse.self, from: Data(json.utf8))
        XCTAssertEqual(resp.total_running, 3)
        XCTAssertFalse(resp.has_more)
    }

    func testHubDelegationDecodes() throws {
        let json = """
        {"id":"d1","origin_node":"n1","target_node":"n2","status":"running",
         "depth":0,"created_at":"2025-01-01T00:00:00Z","updated_at":"2025-01-01T00:00:00Z"}
        """
        let d = try JSONDecoder().decode(HubDelegation.self, from: Data(json.utf8))
        XCTAssertEqual(d.id, "d1")
        XCTAssertNil(d.agent_name)
    }

    func testRegistrationInfoResponseDecodes() throws {
        let json = """
        {"enabled":true,"token_configured":true,"can_persist_nodes":false,"registration_token":"abc"}
        """
        let resp = try JSONDecoder().decode(RegistrationInfoResponse.self, from: Data(json.utf8))
        XCTAssertTrue(resp.enabled)
        XCTAssertEqual(resp.registration_token, "abc")
    }

    func testRegistrationInfoMinimalDecodes() throws {
        let resp = try JSONDecoder().decode(RegistrationInfoResponse.self, from: Data("{\"enabled\":false}".utf8))
        XCTAssertFalse(resp.enabled)
        XCTAssertNil(resp.token_configured)
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
        XCTAssertEqual(node.status.latency_ms, 12)
        XCTAssertNil(node.sessions)
    }

    func testGrantPrefixRawValues() {
        XCTAssertEqual(GrantPrefix.bootstrap.rawValue, "/api/auth/bootstrap")
        XCTAssertEqual(GrantPrefix.recovery.rawValue, "/api/auth/recovery")
    }
}

// MARK: - HTML parsing tests

final class HubClientHTMLParsingTests: XCTestCase {

    func testParseDashboardConfig() throws {
        let html = """
        <div id="root" data-hub-config="{&#34;page&#34;:&#34;dashboard&#34;,&#34;authMode&#34;:&#34;none&#34;,&#34;canAddNodes&#34;:true,&#34;passkeyAuth&#34;:false}"></div>
        """
        let config = try HubClient.parseDataHubConfig(html: html)
        XCTAssertEqual(config.page, "dashboard")
        XCTAssertEqual(config.authMode, "none")
        XCTAssertTrue(config.canAddNodes)
    }

    func testParseBearerLoginConfig() throws {
        let html = """
        <div id="root" data-hub-config="{&#34;page&#34;:&#34;bearer-login&#34;,&#34;authMode&#34;:&#34;bearer&#34;,&#34;basePath&#34;:&#34;/hub&#34;,&#34;invalidToken&#34;:true,&#34;formAction&#34;:&#34;/hub/&#34;}"></div>
        """
        let config = try HubClient.parseDataHubConfig(html: html)
        XCTAssertEqual(config.page, "bearer-login")
        XCTAssertEqual(config.invalidToken, true)
        XCTAssertFalse(config.canAddNodes)
        XCTAssertFalse(config.passkeyAuth)
    }

    func testParseWithQuotEntity() throws {
        let html = """
        <div id="root" data-hub-config="{&quot;page&quot;:&quot;dashboard&quot;,&quot;authMode&quot;:&quot;passkey&quot;}"></div>
        """
        XCTAssertEqual(try HubClient.parseDataHubConfig(html: html).authMode, "passkey")
    }

    func testParseWithAmpEntity() throws {
        let html = """
        <div id="root" data-hub-config="{&#34;page&#34;:&#34;dashboard&#34;,&#34;authMode&#34;:&#34;none&#34;,&#34;basePath&#34;:&#34;/a&amp;b&#34;}"></div>
        """
        XCTAssertEqual(try HubClient.parseDataHubConfig(html: html).basePath, "/a&b")
    }

    func testParseMissingAttributeThrows() {
        XCTAssertThrowsError(try HubClient.parseDataHubConfig(html: "<div id=\"root\"></div>")) { error in
            XCTAssertTrue((error as? HubAPIError)?.message.contains("does not contain") == true)
        }
    }

    func testParseMalformedJSONThrows() {
        let html = "<div data-hub-config=\"{not valid}\"></div>"
        XCTAssertThrowsError(try HubClient.parseDataHubConfig(html: html)) { error in
            XCTAssertTrue((error as? HubAPIError)?.message.contains("malformed") == true)
        }
    }

    func testParseNoClosingQuoteThrows() {
        XCTAssertThrowsError(try HubClient.parseDataHubConfig(html: "data-hub-config=\"{&#34;page&#34;")) { error in
            XCTAssertTrue((error as? HubAPIError)?.message.contains("closing quote") == true)
        }
    }
}

// MARK: - Cookie filtering tests

final class HubClientCookieFilterTests: XCTestCase {

    private func client(base: String = "https://hub.example.com/") -> HubClient {
        HubClient(base_url: URL(string: base)!, cookie_source: { [] })
    }

    private func cookie(
        name: String = "test", value: String = "v",
        domain: String = "hub.example.com", path: String = "/",
        secure: Bool = false, expires: Date? = Date(timeIntervalSinceNow: 3600)
    ) -> HTTPCookie {
        var props: [HTTPCookiePropertyKey: Any] = [
            .name: name, .value: value, .domain: domain, .path: path,
        ]
        if secure { props[.secure] = true }
        if let expires { props[.expires] = expires }
        return HTTPCookie(properties: props)!
    }

    func testExactHostAccepted() {
        let c = client()
        let url = URL(string: "https://hub.example.com/api/nodes")!
        XCTAssertEqual(c.filteredCookies([cookie()], for: url).count, 1)
    }

    func testDomainCookieRejected() {
        let c = client()
        let url = URL(string: "https://hub.example.com/api/nodes")!
        XCTAssertEqual(c.filteredCookies([cookie(domain: ".example.com")], for: url).count, 0)
    }

    func testWrongHostRejected() {
        XCTAssertEqual(client().filteredCookies(
            [cookie(domain: "other.example.com")],
            for: URL(string: "https://hub.example.com/api")!
        ).count, 0)
    }

    func testWebSessionCookieRejected() {
        XCTAssertEqual(client().filteredCookies(
            [cookie(name: "term_llm_web_session")],
            for: URL(string: "https://hub.example.com/api")!
        ).count, 0)
    }

    func testExpiredCookieRejected() {
        XCTAssertEqual(client().filteredCookies(
            [cookie(expires: Date(timeIntervalSinceNow: -1))],
            for: URL(string: "https://hub.example.com/api")!
        ).count, 0)
    }

    func testSessionCookieNoExpiryAccepted() {
        XCTAssertEqual(client().filteredCookies(
            [cookie(expires: nil)],
            for: URL(string: "https://hub.example.com/api")!
        ).count, 1)
    }

    func testSecureCookieRejectedOnHTTP() {
        let c = client(base: "http://localhost:8080/")
        XCTAssertEqual(c.filteredCookies(
            [cookie(domain: "localhost", secure: true)],
            for: URL(string: "http://localhost:8080/api")!
        ).count, 0)
    }

    // Auth cookie isolation

    func testRootAuthCookieNotSentToNestedHub() {
        let c = client(base: "https://hub.example.com/nested/")
        XCTAssertEqual(c.filteredCookies(
            [cookie(name: "term_llm_hub_token", path: "/")],
            for: URL(string: "https://hub.example.com/nested/api/nodes")!
        ).count, 0)
    }

    func testNestedAuthCookieNotSentToRootHub() {
        let c = client(base: "https://hub.example.com/")
        XCTAssertEqual(c.filteredCookies(
            [cookie(name: "term_llm_hub_token", path: "/nested/")],
            for: URL(string: "https://hub.example.com/api/nodes")!
        ).count, 0)
    }

    func testAuthCookieAtCorrectMountAccepted() {
        let c = client(base: "https://hub.example.com/hub/")
        XCTAssertEqual(c.filteredCookies(
            [cookie(name: "term_llm_hub_token", path: "/hub/")],
            for: URL(string: "https://hub.example.com/hub/api/nodes")!
        ).count, 1)
    }

    func testRootAuthCookieAcceptedForRootHub() {
        let c = client(base: "https://hub.example.com/")
        XCTAssertEqual(c.filteredCookies(
            [cookie(name: "term_llm_hub_token", path: "/")],
            for: URL(string: "https://hub.example.com/api/nodes")!
        ).count, 1)
    }

    func testSessionCookieIsolatedSameAsToken() {
        let c = client(base: "https://hub.example.com/nested/")
        XCTAssertEqual(c.filteredCookies(
            [cookie(name: "term_llm_hub_session", path: "/")],
            for: URL(string: "https://hub.example.com/nested/api/auth/session")!
        ).count, 0)
    }

    func testCeremonyCookiesIsolated() {
        let c = client(base: "https://hub.example.com/nested/")
        for name in ["term_llm_hub_login", "term_llm_hub_bootstrap", "term_llm_hub_recovery",
                      "term_llm_hub_reauth", "term_llm_hub_registration"] {
            XCTAssertEqual(c.filteredCookies(
                [cookie(name: name, path: "/")],
                for: URL(string: "https://hub.example.com/nested/api")!
            ).count, 0, "\(name) leaked from root to nested")
        }
    }

    // RFC path boundary

    func testRFCPathBoundarySlash() {
        let c = client()
        XCTAssertEqual(c.filteredCookies(
            [cookie(name: "other", path: "/foo")],
            for: URL(string: "https://hub.example.com/foo/bar")!
        ).count, 1)
        XCTAssertEqual(c.filteredCookies(
            [cookie(name: "other", path: "/foo")],
            for: URL(string: "https://hub.example.com/foobar")!
        ).count, 0, "/foo must not match /foobar")
    }

    func testRFCPathExactMatch() {
        XCTAssertEqual(client().filteredCookies(
            [cookie(name: "other", path: "/api/nodes")],
            for: URL(string: "https://hub.example.com/api/nodes")!
        ).count, 1)
    }

    func testRFCPathTrailingSlash() {
        XCTAssertEqual(client().filteredCookies(
            [cookie(name: "other", path: "/hub/")],
            for: URL(string: "https://hub.example.com/hub/api")!
        ).count, 1)
    }
}

// MARK: - makeAuthCookie tests

final class HubClientAuthCookieTests: XCTestCase {

    func testMakeAuthCookieHTTPS() {
        let c = HubClient.makeAuthCookie(name: "term_llm_hub_token", value: "secret",
                                          host: "hub.example.com", path: "/", secure: true)
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.name, "term_llm_hub_token")
        XCTAssertEqual(c?.value, "secret")
        XCTAssertTrue(c?.isSecure == true)
        XCTAssertTrue(c?.isHTTPOnly == true)
    }

    func testMakeAuthCookieHTTP() {
        let c = HubClient.makeAuthCookie(name: "term_llm_hub_token", value: "tok",
                                          host: "localhost", path: "/hub/", secure: false)
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.path, "/hub/")
        XCTAssertFalse(c?.isSecure ?? true)
        XCTAssertTrue(c?.isHTTPOnly == true)
    }

    func testMakeAuthCookieScopedToMountPath() {
        let c = HubClient.makeAuthCookie(name: "term_llm_hub_token", value: "tok",
                                          host: "hub.example.com", path: "/nested/", secure: true)
        XCTAssertEqual(c?.path, "/nested/")
    }
}

// MARK: - Transport-level tests

final class HubClientTests: XCTestCase {

    /// Creates a HubClient backed by MockTransport for testing request
    /// construction, headers, error handling, etc.
    private func makeClient(
        base: String = "https://hub.example.com/",
        cookies: [HTTPCookie] = [],
        recorder: CookieRecorder? = nil,
        handler: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    ) -> (HubClient, MockTransport) {
        let transport = MockTransport(handler: handler)
        let client = HubClient(
            base_url: URL(string: base)!,
            cookie_source: { cookies },
            cookie_sink: { cookies in recorder?.append(cookies) },
            transport: transport
        )
        return (client, transport)
    }

    // MARK: Request construction

    func testListNodesSendsGETWithAcceptJSON() async throws {
        let nodesJSON = """
        {"nodes":[],"resolver_error":null}
        """
        let (client, transport) = makeClient { _ in
            jsonResponse(nodesJSON)
        }
        _ = try await client.list_nodes()
        XCTAssertEqual(transport.requests.count, 1)
        let req = transport.requests[0]
        XCTAssertEqual(req.method, "GET")
        XCTAssertEqual(req.url.path, "/api/nodes")
        XCTAssertEqual(req.headers["Accept"], "application/json")
        XCTAssertNil(req.headers["Origin"], "GET must not include Origin")
    }

    func testMutationIncludesOriginHeader() async throws {
        let (client, transport) = makeClient { _ in
            jsonResponse("{\"cleared\":5,\"failed\":0}")
        }
        _ = try await client.clear_attention()
        XCTAssertEqual(transport.requests[0].method, "POST")
        XCTAssertEqual(transport.requests[0].headers["Origin"], "https://hub.example.com")
    }

    func testDeleteIncludesOrigin() async throws {
        let (client, transport) = makeClient { _ in
            jsonResponse("{\"removed\":\"n1\"}")
        }
        _ = try await client.remove_node(id: "n1")
        XCTAssertEqual(transport.requests[0].method, "DELETE")
        XCTAssertNotNil(transport.requests[0].headers["Origin"])
    }

    func testPatchIncludesOrigin() async throws {
        let (client, transport) = makeClient { _ in
            jsonResponse("{\"node_ids\":[\"a\",\"b\"]}")
        }
        _ = try await client.reorder_nodes(node_ids: ["a", "b"])
        XCTAssertEqual(transport.requests[0].method, "PATCH")
        XCTAssertNotNil(transport.requests[0].headers["Origin"])
    }

    func testSubpathMountedCorrectly() async throws {
        let (client, transport) = makeClient(base: "https://hub.example.com/ui/") { _ in
            jsonResponse("{\"nodes\":[]}")
        }
        _ = try await client.list_nodes()
        XCTAssertEqual(transport.requests[0].url.path, "/ui/api/nodes")
    }

    func testAttentionLimitQueryParam() async throws {
        let json = """
        {"total_running":0,"total_input_required":0,"total_unseen":0,
         "nodes":[],"input_required":[],"inbox":[],"has_more":false}
        """
        let (client, transport) = makeClient { _ in jsonResponse(json) }
        _ = try await client.list_attention(limit: 50)
        XCTAssertEqual(transport.requests[0].url.query, "limit=50")
    }

    func testAttentionLimitClampedToRange() async throws {
        let json = """
        {"total_running":0,"total_input_required":0,"total_unseen":0,
         "nodes":[],"input_required":[],"inbox":[],"has_more":false}
        """
        let (client, transport) = makeClient { _ in jsonResponse(json) }
        _ = try await client.list_attention(limit: 9999)
        XCTAssertEqual(transport.requests[0].url.query, "limit=500")
    }

    func testAttentionNoLimitOmitsQuery() async throws {
        let json = """
        {"total_running":0,"total_input_required":0,"total_unseen":0,
         "nodes":[],"input_required":[],"inbox":[],"has_more":false}
        """
        let (client, transport) = makeClient { _ in jsonResponse(json) }
        _ = try await client.list_attention(limit: nil)
        XCTAssertNil(transport.requests[0].url.query)
    }

    // MARK: Error handling

    func testNon2xxThrowsHubAPIError() async throws {
        let (client, _) = makeClient { _ in
            jsonResponse("{\"error\":{\"message\":\"Forbidden\",\"type\":\"auth\"}}", status: 403)
        }
        do {
            _ = try await client.list_nodes()
            XCTFail("Expected error")
        } catch let error as HubAPIError {
            XCTAssertEqual(error.status, 403)
            XCTAssertEqual(error.message, "Forbidden")
            XCTAssertEqual(error.type, "auth")
        }
    }

    func testPlainTextErrorFallback() async throws {
        let (client, _) = makeClient { _ in
            let http = HTTPURLResponse(url: URL(string: "https://hub.example.com/api/nodes")!,
                                        statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (Data("Internal Server Error".utf8), http)
        }
        do {
            _ = try await client.list_nodes()
            XCTFail("Expected error")
        } catch let error as HubAPIError {
            XCTAssertEqual(error.status, 500)
            XCTAssertEqual(error.message, "Internal Server Error")
        }
    }

    func testEmptyResponseThrows() async throws {
        let (client, _) = makeClient { _ in
            let http = HTTPURLResponse(url: URL(string: "https://hub.example.com/api/nodes")!,
                                        statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(), http)
        }
        do {
            _ = try await client.list_nodes()
            XCTFail("Expected error")
        } catch let error as HubAPIError {
            XCTAssertTrue(error.message.contains("empty"))
        }
    }

    // MARK: Unauthorized callback

    func testUnauthorizedCallbackFiredOn401() async {
        var callbackFired = false
        let (client, _) = makeClient { _ in
            jsonResponse("{\"error\":{\"message\":\"Unauthorized\"}}", status: 401)
        }
        client.on_unauthorized = { callbackFired = true }
        do {
            _ = try await client.list_nodes()
            XCTFail("Expected error")
        } catch {}
        XCTAssertTrue(callbackFired)
    }

    func testUnauthorizedCallbackFiredOn403() async {
        var callbackFired = false
        let (client, _) = makeClient { _ in
            jsonResponse("{\"error\":{\"message\":\"Forbidden\"}}", status: 403)
        }
        client.on_unauthorized = { callbackFired = true }
        do {
            _ = try await client.list_nodes()
            XCTFail("Expected error")
        } catch {}
        XCTAssertTrue(callbackFired)
    }

    func testUnauthorizedNotFiredOnSuccess() async throws {
        var callbackFired = false
        let (client, _) = makeClient { _ in
            jsonResponse("{\"nodes\":[]}")
        }
        client.on_unauthorized = { callbackFired = true }
        _ = try await client.list_nodes()
        XCTAssertFalse(callbackFired)
    }

    // MARK: Set-Cookie sink

    func testResponseSetCookieSunkForHubAuthCookies() async throws {
        let rec = CookieRecorder()
        let (client, _) = makeClient(recorder: rec) { _ in
            jsonResponse("{\"nodes\":[]}", headers: [
                "Set-Cookie": "term_llm_hub_session=abc123; Path=/; HttpOnly"
            ])
        }
        _ = try await client.list_nodes()
        XCTAssertEqual(rec.count, 1)
        XCTAssertEqual(rec.batches[0].first?.name, "term_llm_hub_session")
    }

    func testResponseSetCookieNotSunkForNonAuthCookies() async throws {
        let rec = CookieRecorder()
        let (client, _) = makeClient(recorder: rec) { _ in
            jsonResponse("{\"nodes\":[]}", headers: [
                "Set-Cookie": "tracking=xyz; Path=/"
            ])
        }
        _ = try await client.list_nodes()
        XCTAssertEqual(rec.count, 0, "Non-auth cookies must not be sunk")
    }

    func testResponseSetCookieNotSunkForWrongPath() async throws {
        let rec = CookieRecorder()
        let transport = MockTransport { _ in
            jsonResponse("{\"nodes\":[]}", headers: [
                "Set-Cookie": "term_llm_hub_session=abc; Path=/other/"
            ])
        }
        let client = HubClient(
            base_url: URL(string: "https://hub.example.com/hub/")!,
            cookie_source: { [] },
            cookie_sink: { cookies in rec.append(cookies) },
            transport: transport
        )
        _ = try await client.list_nodes()
        XCTAssertEqual(rec.count, 0, "Auth cookie at wrong path must not be sunk")
    }

    // MARK: Discover

    func testDiscoverParsesHTMLConfig() async throws {
        let html = """
        <div id="root" data-hub-config="{&#34;page&#34;:&#34;dashboard&#34;,&#34;authMode&#34;:&#34;none&#34;}"></div>
        """
        let (client, _) = makeClient { _ in htmlResponse(html) }
        let result = try await client.discover()
        if case .page(let config) = result {
            XCTAssertEqual(config.page, "dashboard")
        } else {
            XCTFail("Expected .page")
        }
    }

    func testDiscover401BearerLoginPageReturnsPageConfig() async throws {
        let html = """
        <div id="root" data-hub-config="{&#34;page&#34;:&#34;bearer-login&#34;,&#34;authMode&#34;:&#34;bearer&#34;,&#34;formAction&#34;:&#34;/hub/&#34;}"></div>
        """
        var authPurged = false
        let (client, _) = makeClient { _ in htmlResponse(html, status: 401) }
        client.on_unauthorized = { authPurged = true }
        let result = try await client.discover()
        if case .page(let config) = result {
            XCTAssertEqual(config.page, "bearer-login")
            XCTAssertEqual(config.authMode, "bearer")
        } else {
            XCTFail("Expected .page for 401 bearer login")
        }
        XCTAssertTrue(authPurged, "on_unauthorized must fire on 401 discover")
    }

    func testDiscover401WithoutHTMLReturnsRedirect() async throws {
        let (client, _) = makeClient { _ in
            let http = HTTPURLResponse(
                url: URL(string: "https://hub.example.com/")!,
                statusCode: 401, httpVersion: nil,
                headerFields: ["X-Term-LLM-Login-URL": "/auth/login"]
            )!
            return (Data(), http)
        }
        client.on_unauthorized = {}
        let result = try await client.discover()
        if case .redirect(let r) = result {
            XCTAssertEqual(r.status, 401)
            XCTAssertEqual(r.login_url, "/auth/login")
        } else {
            XCTFail("Expected .redirect")
        }
    }

    func testDiscover302ReturnsRedirect() async throws {
        let (client, _) = makeClient { _ in
            let http = HTTPURLResponse(
                url: URL(string: "https://hub.example.com/")!,
                statusCode: 302, httpVersion: nil,
                headerFields: ["Location": "/auth/login"]
            )!
            return (Data(), http)
        }
        let result = try await client.discover()
        if case .redirect(let r) = result {
            XCTAssertEqual(r.status, 302)
            XCTAssertEqual(r.location, "/auth/login")
        } else {
            XCTFail("Expected .redirect")
        }
    }

    func testDiscoverNonHubPageThrows() async throws {
        let (client, _) = makeClient { _ in htmlResponse("<html><body>Not a hub</body></html>") }
        do {
            _ = try await client.discover()
            XCTFail("Expected error for non-Hub page")
        } catch let error as HubAPIError {
            XCTAssertTrue(error.message.contains("does not contain"))
        }
    }

    // MARK: Bearer login

    func testLoginBearerSendsAuthorizationHeader() async throws {
        let (client, transport) = makeClient { _ in
            jsonResponse("{\"nodes\":[]}")
        }
        try await client.login_bearer(token: "my-secret-token")
        XCTAssertEqual(transport.requests[0].headers["Authorization"], "Bearer my-secret-token")
        XCTAssertEqual(transport.requests[0].method, "GET")
    }

    func testLoginBearerRejectsInvalidToken() async throws {
        let (client, _) = makeClient { _ in
            jsonResponse("{\"error\":{\"message\":\"bad token\"}}", status: 401)
        }
        do {
            try await client.login_bearer(token: "wrong")
            XCTFail("Expected error")
        } catch let error as HubAPIError {
            XCTAssertEqual(error.status, 401)
        }
    }

    func testLoginBearerSinksCookie() async throws {
        let rec = CookieRecorder()
        let transport = MockTransport { _ in jsonResponse("{\"nodes\":[]}") }
        let client = HubClient(
            base_url: URL(string: "https://hub.example.com/hub/")!,
            cookie_source: { [] },
            cookie_sink: { cookies in rec.append(cookies) },
            transport: transport
        )
        try await client.login_bearer(token: "tok123")
        XCTAssertEqual(rec.count, 1)
        let cookie = rec.batches[0].first
        XCTAssertEqual(cookie?.name, "term_llm_hub_token")
        XCTAssertEqual(cookie?.value, "tok123")
        XCTAssertEqual(cookie?.path, "/hub/")
        XCTAssertTrue(cookie?.isHTTPOnly == true)
        XCTAssertTrue(cookie?.isSecure == true)
    }
}

// MARK: - Passkey ceremony tests

final class HubPasskeyTests: XCTestCase {

    private func makeClient(
        handler: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    ) -> (HubClient, MockTransport) {
        let transport = MockTransport(handler: handler)
        let client = HubClient(
            base_url: URL(string: "https://hub.example.com/")!,
            cookie_source: { [] },
            transport: transport
        )
        return (client, transport)
    }

    func testBeginLoginSendsCorrectPath() async throws {
        let (client, transport) = makeClient { _ in
            jsonResponse("{\"publicKey\":{\"challenge\":\"abc\"}}")
        }
        let data = try await client.begin_login(return_path: "/dashboard")
        XCTAssertEqual(transport.requests[0].url.path, "/api/auth/login/begin")
        XCTAssertEqual(transport.requests[0].method, "POST")
        // Verify body contains return_path
        let body = try JSONDecoder().decode([String: String].self, from: transport.requests[0].body!)
        XCTAssertEqual(body["return_path"], "/dashboard")
        // Returns raw Data
        XCTAssertFalse(data.isEmpty)
    }

    func testFinishLoginSendsCredentialDataAndReturnsRedirect() async throws {
        let (client, transport) = makeClient { _ in
            jsonResponse("{\"ok\":true,\"redirect\":\"/hub/\"}")
        }
        let credentialJSON = Data("{\"id\":\"cred1\",\"rawId\":\"abc\"}".utf8)
        let response = try await client.finish_login(credential: credentialJSON)
        XCTAssertEqual(transport.requests[0].url.path, "/api/auth/login/finish")
        XCTAssertEqual(transport.requests[0].method, "POST")
        XCTAssertEqual(transport.requests[0].body, credentialJSON)
        XCTAssertEqual(response.redirect, "/hub/")
    }

    func testBeginReauthenticationPath() async throws {
        let (client, transport) = makeClient { _ in
            jsonResponse("{\"publicKey\":{\"challenge\":\"xyz\"}}")
        }
        _ = try await client.begin_reauthentication()
        XCTAssertEqual(transport.requests[0].url.path, "/api/auth/reauth/begin")
        XCTAssertEqual(transport.requests[0].method, "POST")
    }

    func testFinishReauthenticationReturnsOk() async throws {
        let (client, _) = makeClient { _ in
            jsonResponse("{\"ok\":true}")
        }
        let result = try await client.finish_reauthentication(credential: Data("{}".utf8))
        XCTAssertTrue(result.ok)
    }

    func testBeginAdditionalRegistrationPath() async throws {
        let (client, transport) = makeClient { _ in
            jsonResponse("{\"publicKey\":{\"challenge\":\"def\"}}")
        }
        _ = try await client.begin_additional_registration(display_name: "My Passkey")
        XCTAssertEqual(transport.requests[0].url.path, "/api/auth/credentials/register/begin")
        let body = try JSONDecoder().decode([String: String].self, from: transport.requests[0].body!)
        XCTAssertEqual(body["display_name"], "My Passkey")
    }

    /// Server returns HTTP 201 with the newly created HubCredential.
    func testFinishAdditionalRegistrationReturns201Credential() async throws {
        let credJSON = """
        {"record_id":"new-cred","display_name":"My Passkey",
         "transports":["internal"],"created_at":"2025-06-01","last_used_at":"2025-06-01"}
        """
        let (client, transport) = makeClient { _ in
            jsonResponse(credJSON, status: 201)
        }
        let cred = try await client.finish_additional_registration(credential: Data("{}".utf8))
        XCTAssertEqual(transport.requests[0].url.path, "/api/auth/credentials/register/finish")
        XCTAssertEqual(cred.record_id, "new-cred")
        XCTAssertEqual(cred.display_name, "My Passkey")
        XCTAssertEqual(cred.transports, ["internal"])
    }

    // MARK: Grant registration

    func testVerifyGrantBootstrapPath() async throws {
        let (client, transport) = makeClient { _ in jsonResponse("{\"ok\":true}") }
        _ = try await client.verify_grant(prefix: .bootstrap, code: "123456")
        XCTAssertEqual(transport.requests[0].url.path, "/api/auth/bootstrap/verify")
    }

    func testVerifyGrantRecoveryPath() async throws {
        let (client, transport) = makeClient { _ in jsonResponse("{\"ok\":true}") }
        _ = try await client.verify_grant(prefix: .recovery, code: "654321")
        XCTAssertEqual(transport.requests[0].url.path, "/api/auth/recovery/verify")
    }

    func testBeginGrantRegistrationPath() async throws {
        let (client, transport) = makeClient { _ in jsonResponse("{\"publicKey\":{}}") }
        _ = try await client.begin_grant_registration(prefix: .bootstrap, display_name: "Key")
        XCTAssertEqual(transport.requests[0].url.path, "/api/auth/bootstrap/register/begin")
    }

    func testFinishGrantRegistrationWithReturnPath() async throws {
        let (client, transport) = makeClient { _ in jsonResponse("{\"redirect\":\"/hub/\"}") }
        _ = try await client.finish_grant_registration(
            prefix: .recovery, credential: Data("{}".utf8), return_path: "/dashboard"
        )
        XCTAssertEqual(transport.requests[0].url.path, "/api/auth/recovery/register/finish")
        XCTAssertTrue(transport.requests[0].url.query?.contains("return=") == true)
    }

    func testFinishGrantRegistrationEmptyReturnPath() async throws {
        let (client, transport) = makeClient { _ in jsonResponse("{\"redirect\":\"/hub/\"}") }
        _ = try await client.finish_grant_registration(
            prefix: .bootstrap, credential: Data("{}".utf8), return_path: ""
        )
        XCTAssertNil(transport.requests[0].url.query)
    }

    // MARK: Other auth endpoints

    func testNativeAuthorizePath() async throws {
        let (client, transport) = makeClient { _ in
            jsonResponse("{\"redirect\":\"/hub/\"}")
        }
        _ = try await client.authorize_native(challenge: "challenge123")
        XCTAssertEqual(transport.requests[0].url.path, "/api/auth/native/authorize")
        XCTAssertEqual(transport.requests[0].method, "POST")
    }

    func testRenameCredentialPath() async throws {
        let credJSON = """
        {"record_id":"r1","display_name":"Renamed","transports":null,
         "created_at":"2025-01-01","last_used_at":"2025-06-01"}
        """
        let (client, transport) = makeClient { _ in jsonResponse(credJSON) }
        let cred = try await client.rename_credential(record_id: "r1", display_name: "Renamed")
        XCTAssertEqual(transport.requests[0].url.path, "/api/auth/credentials/r1")
        XCTAssertEqual(transport.requests[0].method, "PATCH")
        XCTAssertEqual(cred.display_name, "Renamed")
    }

    func testRemoveCredentialPath() async throws {
        let (client, transport) = makeClient { _ in jsonResponse("{\"ok\":true}") }
        _ = try await client.remove_credential(record_id: "r1")
        XCTAssertEqual(transport.requests[0].url.path, "/api/auth/credentials/r1")
        XCTAssertEqual(transport.requests[0].method, "DELETE")
    }

    func testRevokeOtherSessionsPath() async throws {
        let (client, transport) = makeClient { _ in jsonResponse("{\"revoked\":3}") }
        let result = try await client.revoke_other_sessions()
        XCTAssertEqual(transport.requests[0].url.path, "/api/auth/sessions/revoke-others")
        XCTAssertEqual(result.revoked, 3)
    }

    func testLogoutPath() async throws {
        let (client, transport) = makeClient { _ in
            jsonResponse("{\"redirect\":\"/hub/auth/login\"}")
        }
        let result = try await client.logout()
        XCTAssertEqual(transport.requests[0].url.path, "/api/auth/logout")
        XCTAssertEqual(transport.requests[0].method, "POST")
        XCTAssertEqual(result.redirect, "/hub/auth/login")
    }

    func testSessionPath() async throws {
        let json = """
        {"administrator":"admin","session":{},"recently_authenticated":false,"active_sessions":1}
        """
        let (client, transport) = makeClient { _ in jsonResponse(json) }
        let result = try await client.session()
        XCTAssertEqual(transport.requests[0].url.path, "/api/auth/session")
        XCTAssertEqual(transport.requests[0].method, "GET")
        XCTAssertFalse(result.recently_authenticated)
    }

    func testHealthzPath() async throws {
        let (client, transport) = makeClient { _ in jsonResponse("{\"status\":\"ok\"}") }
        let result = try await client.healthz()
        XCTAssertEqual(transport.requests[0].url.path, "/healthz")
        XCTAssertEqual(result.status, "ok")
    }
}

// MARK: - Mounted path tests

final class HubClientMountedPathTests: XCTestCase {

    func testMountPathRoot() {
        let c = HubClient(base_url: URL(string: "https://hub.example.com/")!, cookie_source: { [] })
        XCTAssertEqual(c.mount_path, "")
        XCTAssertEqual(c.expected_host, "hub.example.com")
    }

    func testMountPathSubpath() {
        let c = HubClient(base_url: URL(string: "https://hub.example.com/ui/")!, cookie_source: { [] })
        XCTAssertEqual(c.mount_path, "/ui")
    }

    func testMountPathNoTrailingSlash() {
        let c = HubClient(base_url: URL(string: "https://hub.example.com/hub")!, cookie_source: { [] })
        XCTAssertEqual(c.mount_path, "/hub")
    }

    func testOriginExcludesDefaultPort() {
        let c = HubClient(base_url: URL(string: "https://hub.example.com:443/")!, cookie_source: { [] })
        XCTAssertEqual(c.origin, "https://hub.example.com")
    }

    func testOriginIncludesNonDefaultPort() {
        let c = HubClient(base_url: URL(string: "https://hub.example.com:8443/")!, cookie_source: { [] })
        XCTAssertEqual(c.origin, "https://hub.example.com:8443")
    }

    func testHTTPOrigin() {
        let c = HubClient(base_url: URL(string: "http://localhost:8080/")!, cookie_source: { [] })
        XCTAssertEqual(c.origin, "http://localhost:8080")
        XCTAssertFalse(c.is_https)
    }
}

// MARK: - Header processing order

extension HubClientTests {
    func testHeaderProcessingWaitsFor401Purge() async {
        await assertHeaderProcessingAwaitsPurge(status: 401)
    }

    func testHeaderProcessingWaitsFor403Purge() async {
        await assertHeaderProcessingAwaitsPurge(status: 403)
    }

    private func assertHeaderProcessingAwaitsPurge(status: Int) async {
        let callbackStarted = expectation(description: "purge started")
        let gate = HubRequestGate()
        let processingFinished = HubTestBox(false)
        let response = HTTPURLResponse(url: URL(string: "https://hub.example.com/api/nodes")!,
                                       statusCode: status, httpVersion: nil, headerFields: nil)!
        let processing = Task {
            await URLSessionHubTransport.processHeaders(response, onUnauthorized: {
                callbackStarted.fulfill()
                await gate.wait()
            })
            processingFinished.set(true)
        }
        await fulfillment(of: [callbackStarted], timeout: 2)
        XCTAssertFalse(processingFinished.value, "Body processing must wait for the purge")
        await gate.release()
        await processing.value
        XCTAssertTrue(processingFinished.value)
    }

    func testSuccessfulHeadersDoNotInvokeUnauthorizedCallback() async {
        let called = HubTestBox(false)
        let response = HTTPURLResponse(url: URL(string: "https://hub.example.com/api/nodes")!,
                                       statusCode: 200, httpVersion: nil, headerFields: nil)!
        await URLSessionHubTransport.processHeaders(response, onUnauthorized: { called.set(true) })
        XCTAssertFalse(called.value)
    }
}

// MARK: - Real transport 401 stalled-body test

/// Exercises URLSessionHubTransport against a real loopback TCP listener that
/// sends HTTP 401 headers with Content-Length but never sends the body.
/// Proves on_unauthorized fires at header time, before the body download
/// would complete (it never will).  Uses Network.framework NWListener on
/// loopback only — no shared service, no external connections.
///
/// **Platform limitation**: Network.framework requires Apple platforms.
/// This test is a no-op on Linux.
#if canImport(Network)
import Network

extension HubClientTests {

    /// Spin up a loopback-only TCP listener that accepts one connection,
    /// sends a minimal HTTP/1.1 401 response with a large Content-Length
    /// but never sends the body, then holds the connection open.
    func testOnUnauthorizedFiresBeforeBodyOnRealTransport() async throws {
        try await assertHeaderTimeRevocation(discovery: false)
    }

    func testDiscoveryPurgesBeforeStalledLoginPageBody() async throws {
        try await assertHeaderTimeRevocation(discovery: true)
    }

    private func assertHeaderTimeRevocation(discovery: Bool) async throws {
        // Set up loopback listener on a random port
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)

        let listenerReady = expectation(description: "listener ready")
        let listenerPort = HubTestBox<UInt16>(0)
        let acceptedConnection = HubTestBox<NWConnection?>(nil)

        listener.stateUpdateHandler = { state in
            if case .ready = state, let port = listener.port {
                listenerPort.set(port.rawValue)
                listenerReady.fulfill()
            }
        }

        // When a connection arrives, send 401 headers then stall
        let connectionReceived = expectation(description: "connection received")
        listener.newConnectionHandler = { conn in
            acceptedConnection.set(conn)
            conn.start(queue: .global())
            // Wait for the request data, then send 401 headers only
            conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
                let headers = [
                    "HTTP/1.1 401 Unauthorized\r\n",
                    "Content-Type: application/json\r\n",
                    "Content-Length: 65536\r\n",  // Claim large body
                    "\r\n",
                    // NO body follows — connection stays open
                ].joined()
                conn.send(content: headers.data(using: .utf8),
                         completion: .contentProcessed({ _ in
                    connectionReceived.fulfill()
                    // Keep conn alive — never close, never send body
                }))
            }
        }

        listener.start(queue: .global())
        await fulfillment(of: [listenerReady], timeout: 5)
        XCTAssertGreaterThan(listenerPort.value, 0)

        defer { acceptedConnection.value?.cancel(); listener.cancel() }

        // localhost is the app's explicit simulator HTTP ATS exception.
        let base = URL(string: "http://localhost:\(listenerPort.value)/")!
        let callbackFired = expectation(description: "on_unauthorized fired")

        let transport = URLSessionHubTransport()
        let client = HubClient(
            base_url: base,
            cookie_source: { [] },
            transport: transport
        )
        client.on_unauthorized = {
            callbackFired.fulfill()
        }

        // Fire the request in a task we can cancel after callback proves the point
        let requestFinished = HubTestBox(false)
        let requestTask = Task {
            do {
                if discovery { _ = try await client.discover() }
                else { _ = try await client.list_nodes() }
            } catch { /* cancellation during cleanup */ }
            requestFinished.set(true)
        }
        defer { requestTask.cancel() }

        // Callback must arrive while the response body is still pending.
        await fulfillment(of: [callbackFired, connectionReceived], timeout: 10)
        XCTAssertFalse(requestFinished.value, "The server has not sent the advertised body")

        requestTask.cancel()
        await requestTask.value
    }
}

#endif

extension HubClientTests {
    @MainActor
    func testDelayedOld401CannotRevokeNewAuthenticationOrReplaceItsCookies() async {
        let gate = HubRequestGate()
        let started = expectation(description: "old request started")
        let cookies = CookieRecorder()
        let transport = MockTransport { request in
            started.fulfill()
            await gate.wait()
            return jsonResponse("{\"error\":{\"message\":\"old session expired\"}}", url: request.url!, status: 401,
                                headers: ["Set-Cookie": "term_llm_hub_session=old; Path=/; Secure; HttpOnly"])
        }
        let client = HubClient(base_url: URL(string: "https://hub.example.com/")!, cookie_source: { [] },
                               cookie_sink: { cookies.append($0) }, transport: transport)
        var revocations = 0
        let workspace = HubWorkspace(client: client, requiresAuthentication: false) { revocations += 1 }
        defer { workspace.dispose() }
        // Also retain the raw callback: it may already be queued on MainActor
        // when a new sign-in succeeds, past the client's first admission check.
        let previouslyAdmitted = client.on_unauthorized
        let request = Task { try? await client.list_nodes() }
        await fulfillment(of: [started], timeout: 2)
        workspace.authenticationSucceeded()
        await gate.release()
        _ = await request.value
        await previouslyAdmitted?()
        XCTAssertFalse(workspace.store.unauthorized)
        XCTAssertEqual(revocations, 0)
        XCTAssertEqual(cookies.count, 0, "An old response must not replace a newer session cookie")
        // Current-session revocation must still work.
        await client.on_unauthorized?()
        XCTAssertTrue(workspace.store.unauthorized)
        XCTAssertEqual(revocations, 1)
    }

    @MainActor
    func testDisposedWorkspaceIgnoresAlreadyQueuedRevocation() async {
        let client = HubClient(base_url: URL(string: "https://hub.example.com/")!, cookie_source: { [] })
        var revocations = 0
        let workspace = HubWorkspace(client: client, requiresAuthentication: false) { revocations += 1 }
        let callback = client.on_unauthorized
        workspace.dispose()
        await callback?()
        XCTAssertEqual(revocations, 0)
        XCTAssertFalse(workspace.store.unauthorized)
    }
}
