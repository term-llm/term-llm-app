import XCTest
@testable import TermLLM

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
            baseURL: URL(string: base)!,
            cookieSource: { cookies },
            cookieSink: { cookies in recorder?.append(cookies) },
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
        _ = try await client.listNodes()
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
        _ = try await client.clearAttention()
        XCTAssertEqual(transport.requests[0].method, "POST")
        XCTAssertEqual(transport.requests[0].headers["Origin"], "https://hub.example.com")
    }

    func testDeleteIncludesOrigin() async throws {
        let (client, transport) = makeClient { _ in
            jsonResponse("{\"removed\":\"n1\"}")
        }
        _ = try await client.removeNode(id: "n1")
        XCTAssertEqual(transport.requests[0].method, "DELETE")
        XCTAssertNotNil(transport.requests[0].headers["Origin"])
    }

    func testPatchIncludesOrigin() async throws {
        let (client, transport) = makeClient { _ in
            jsonResponse("{\"node_ids\":[\"a\",\"b\"]}")
        }
        _ = try await client.reorderNodes(nodeIDs: ["a", "b"])
        XCTAssertEqual(transport.requests[0].method, "PATCH")
        XCTAssertNotNil(transport.requests[0].headers["Origin"])
    }

    func testSubpathMountedCorrectly() async throws {
        let (client, transport) = makeClient(base: "https://hub.example.com/ui/") { _ in
            jsonResponse("{\"nodes\":[]}")
        }
        _ = try await client.listNodes()
        XCTAssertEqual(transport.requests[0].url.path, "/ui/api/nodes")
    }

    func testAttentionLimitQueryParam() async throws {
        let json = """
        {"total_running":0,"total_input_required":0,"total_unseen":0,
         "nodes":[],"input_required":[],"inbox":[],"has_more":false}
        """
        let (client, transport) = makeClient { _ in jsonResponse(json) }
        _ = try await client.listAttention(limit: 50)
        XCTAssertEqual(transport.requests[0].url.query, "limit=50")
    }

    func testAttentionLimitClampedToRange() async throws {
        let json = """
        {"total_running":0,"total_input_required":0,"total_unseen":0,
         "nodes":[],"input_required":[],"inbox":[],"has_more":false}
        """
        let (client, transport) = makeClient { _ in jsonResponse(json) }
        _ = try await client.listAttention(limit: 9999)
        XCTAssertEqual(transport.requests[0].url.query, "limit=500")
    }

    func testAttentionNoLimitOmitsQuery() async throws {
        let json = """
        {"total_running":0,"total_input_required":0,"total_unseen":0,
         "nodes":[],"input_required":[],"inbox":[],"has_more":false}
        """
        let (client, transport) = makeClient { _ in jsonResponse(json) }
        _ = try await client.listAttention(limit: nil)
        XCTAssertNil(transport.requests[0].url.query)
    }

    // MARK: Error handling

    func testNon2xxThrowsHubAPIError() async throws {
        let (client, _) = makeClient { _ in
            jsonResponse("{\"error\":{\"message\":\"Forbidden\",\"type\":\"auth\"}}", status: 403)
        }
        do {
            _ = try await client.listNodes()
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
            _ = try await client.listNodes()
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
            _ = try await client.listNodes()
            XCTFail("Expected error")
        } catch let error as HubAPIError {
            XCTAssertTrue(error.message.contains("empty"))
        }
    }

    // MARK: Unauthorized callback

    func testUnauthorizedCallbackFiredOn401() async {
        let callbackFired = HubTestBox(false)
        let (client, _) = makeClient { _ in
            jsonResponse("{\"error\":{\"message\":\"Unauthorized\"}}", status: 401)
        }
        client.onUnauthorized = { callbackFired.set(true) }
        do {
            _ = try await client.listNodes()
            XCTFail("Expected error")
        } catch {}
        XCTAssertTrue(callbackFired.value)
    }

    func testUnauthorizedCallbackFiredOn403() async {
        let callbackFired = HubTestBox(false)
        let (client, _) = makeClient { _ in
            jsonResponse("{\"error\":{\"message\":\"Forbidden\"}}", status: 403)
        }
        client.onUnauthorized = { callbackFired.set(true) }
        do {
            _ = try await client.listNodes()
            XCTFail("Expected error")
        } catch {}
        XCTAssertTrue(callbackFired.value)
    }

    // MARK: Session search

    func testSessionSearchUsesNodeProxyWithStrictQueryEncoding() async throws {
        let (client, transport) = makeClient(base: "https://hub.example.com/hub/") { _ in
            jsonResponse("""
            {"sessions":[{"id":"s1","number":4,"short_title":"Fix relay","snippet":"the **relay** retry",
              "last_message_at":1700000000000,"message_count":3}]}
            """)
        }
        let response = try await client.searchSessions(nodeID: "laptop-1", query: "a+b & c=d%", limit: 500)
        let url = transport.requests[0].url
        XCTAssertEqual(url.path, "/hub/node/laptop-1/v1/sessions/search")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery,
                       "q=a%2Bb%20%26%20c%3Dd%25&limit=50")
        XCTAssertEqual(response.sessions.first?.number, 4)
    }

    func testSessionStatusForIDsUsesNodeProxyWithoutRevokingHub() async throws {
        let callbackFired = HubTestBox(false)
        let (client, transport) = makeClient(base: "https://hub.example.com/hub/") { _ in
            jsonResponse("{\"sessions\":[{\"id\":\"s1\",\"short_title\":\"Fix\",\"active_run\":true,\"interaction_required\":false}]}")
        }
        client.onUnauthorized = { callbackFired.set(true) }
        let status = try await client.sessionsStatus(nodeID: "laptop-1", ids: ["s1", "a,b", "s 2"])
        let url = transport.requests[0].url
        XCTAssertEqual(url.path, "/hub/node/laptop-1/v1/sessions/status")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery, "ids=s1,s%202",
                       "IDs containing the separator are not requested")
        XCTAssertEqual(status.sessions.first?.activeRun, true)
        let empty = try await client.sessionsStatus(nodeID: "laptop-1", ids: [])
        XCTAssertTrue(empty.sessions.isEmpty)
        XCTAssertEqual(transport.requests.count, 1, "No IDs, no request")
        XCTAssertFalse(callbackFired.value)
    }

    func testSessionSearchRejectsUnsafeNodeID() async {
        let (client, transport) = makeClient { _ in jsonResponse("{\"sessions\":[]}") }
        do {
            _ = try await client.searchSessions(nodeID: "../api", query: "x", limit: 5)
            XCTFail("Expected rejection")
        } catch {}
        XCTAssertTrue(transport.requests.isEmpty)
    }

    /// A proxied node can answer 401/403 itself; that must not sign the
    /// whole Hub out.
    func testSessionSearchUnauthorizedDoesNotRevokeHub() async {
        let callbackFired = HubTestBox(false)
        let (client, _) = makeClient { _ in
            jsonResponse("{\"error\":{\"message\":\"Unauthorized\"}}", status: 401)
        }
        client.onUnauthorized = { callbackFired.set(true) }
        do {
            _ = try await client.searchSessions(nodeID: "laptop", query: "x", limit: 5)
            XCTFail("Expected error")
        } catch {
            XCTAssertEqual((error as? HubAPIError)?.status, 401)
        }
        XCTAssertFalse(callbackFired.value)
    }

    func testUnauthorizedNotFiredOnSuccess() async throws {
        let callbackFired = HubTestBox(false)
        let (client, _) = makeClient { _ in
            jsonResponse("{\"nodes\":[]}")
        }
        client.onUnauthorized = { callbackFired.set(true) }
        _ = try await client.listNodes()
        XCTAssertFalse(callbackFired.value)
    }

    // MARK: Set-Cookie sink

    func testResponseSetCookieSunkForHubAuthCookies() async throws {
        let rec = CookieRecorder()
        let (client, _) = makeClient(recorder: rec) { _ in
            jsonResponse("{\"nodes\":[]}", headers: [
                "Set-Cookie": "term_llm_hub_session=abc123; Path=/; HttpOnly"
            ])
        }
        _ = try await client.listNodes()
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
        _ = try await client.listNodes()
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
            baseURL: URL(string: "https://hub.example.com/hub/")!,
            cookieSource: { [] },
            cookieSink: { cookies in rec.append(cookies) },
            transport: transport
        )
        _ = try await client.listNodes()
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
        let authPurged = HubTestBox(false)
        let (client, _) = makeClient { _ in htmlResponse(html, status: 401) }
        client.onUnauthorized = { authPurged.set(true) }
        let result = try await client.discover()
        if case .page(let config) = result {
            XCTAssertEqual(config.page, "bearer-login")
            XCTAssertEqual(config.authMode, "bearer")
        } else {
            XCTFail("Expected .page for 401 bearer login")
        }
        XCTAssertTrue(authPurged.value, "on_unauthorized must fire on 401 discover")
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
        client.onUnauthorized = {}
        let result = try await client.discover()
        if case .redirect(let r) = result {
            XCTAssertEqual(r.status, 401)
            XCTAssertEqual(r.loginURL, "/auth/login")
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
        try await client.loginBearer(token: "my-secret-token")
        XCTAssertEqual(transport.requests[0].headers["Authorization"], "Bearer my-secret-token")
        XCTAssertEqual(transport.requests[0].method, "GET")
    }

    func testLoginBearerRejectsInvalidToken() async throws {
        let (client, _) = makeClient { _ in
            jsonResponse("{\"error\":{\"message\":\"bad token\"}}", status: 401)
        }
        do {
            try await client.loginBearer(token: "wrong")
            XCTFail("Expected error")
        } catch let error as HubAPIError {
            XCTAssertEqual(error.status, 401)
        }
    }

    func testLoginBearerSinksCookie() async throws {
        let rec = CookieRecorder()
        let transport = MockTransport { _ in jsonResponse("{\"nodes\":[]}") }
        let client = HubClient(
            baseURL: URL(string: "https://hub.example.com/hub/")!,
            cookieSource: { [] },
            cookieSink: { cookies in rec.append(cookies) },
            transport: transport
        )
        try await client.loginBearer(token: "tok123")
        XCTAssertEqual(rec.count, 1)
        let cookie = rec.batches[0].first
        XCTAssertEqual(cookie?.name, "term_llm_hub_token")
        XCTAssertEqual(cookie?.value, "tok123")
        XCTAssertEqual(cookie?.path, "/hub/")
        XCTAssertTrue(cookie?.isHTTPOnly == true)
        XCTAssertTrue(cookie?.isSecure == true)
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
/// sends HTTP 401 headers and ONE body byte, then stalls the remaining 65535.
/// Proves revocation occurs before body completion once the SDK exposes the
/// response. The actual SDK matrix below documents that bare headers alone
/// are not exposed on the tested simulator. Loopback only; no shared service.
///
/// **Platform limitation**: Network.framework requires Apple platforms.
/// This test is a no-op on Linux.
#if canImport(Network)
import Network

extension HubClientTests {

    /// Spin up a loopback-only TCP listener that accepts one connection,
    /// sends a minimal HTTP/1.1 401 response advertising a large body, flushes
    /// its first byte, and then holds the incomplete body open indefinitely.
    func testOnUnauthorizedFiresBeforeBodyCompletionOnRealTransport() async throws {
        try await assertRevocationBeforeBodyCompletion(discovery: false)
    }

    func testDiscoveryPurgesBeforeLoginPageBodyCompletes() async throws {
        try await assertRevocationBeforeBodyCompletion(discovery: true)
    }

    private func assertRevocationBeforeBodyCompletion(discovery: Bool) async throws {
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

        // Send headers plus one byte, then stall before body completion
        let connectionReceived = expectation(description: "connection received")
        listener.newConnectionHandler = { conn in
            acceptedConnection.set(conn)
            conn.start(queue: .global())
            // On the tested SDK, a body byte exposes the response (see matrix)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
                let headers = [
                    "HTTP/1.1 401 Unauthorized\r\n",
                    "Content-Type: application/json\r\n",
                    "Content-Length: 65536\r\n",  // Claim large body
                    "\r\n",
                ].joined()
                var partialResponse = Data(headers.utf8)
                partialResponse.append(0x7B) // Exactly ONE JSON-prefix byte: "{"
                conn.send(content: partialResponse,
                         completion: .contentProcessed({ _ in
                    connectionReceived.fulfill()
                    // Keep open; never send the remaining 65535 body bytes
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
        let callbackCount = HubTestBox(0)

        let events = HubTestBox<[String]>([])
        let transport = URLSessionHubTransport(observe: { event in
            let description = String(describing: event)
            events.update { $0.append(description) }
            // Only status codes, byte counts and numeric error codes: no
            // request URL, headers, cookies, realm, credential or body data.
            print("Hub stalled-response callback: \(description)")
        })
        let client = HubClient(
            baseURL: base,
            cookieSource: { [] },
            transport: transport
        )
        client.onUnauthorized = {
            callbackCount.update { $0 += 1 }
            callbackFired.fulfill()
        }

        // Fire the request in a task we can cancel after callback proves the point
        let requestFinished = HubTestBox(false)
        let requestTask = Task {
            do {
                if discovery { _ = try await client.discover() }
                else { _ = try await client.listNodes() }
            } catch { /* cancellation during cleanup */ }
            requestFinished.set(true)
        }
        defer { requestTask.cancel() }

        // Revoke as soon as the SDK exposes the response, without waiting for
        // body completion. Zero-byte behavior remains recorded in the matrix.
        await fulfillment(of: [callbackFired, connectionReceived], timeout: 10)
        XCTAssertTrue(events.value.contains { $0.contains("401") }, "Actual SDK callback events: \(events.value)")
        XCTAssertEqual(callbackCount.value, 1)
        XCTAssertFalse(requestFinished.value, "The remaining 65535 body bytes are still pending; events: \(events.value)")

        requestTask.cancel()
        await requestTask.value
        XCTAssertEqual(callbackCount.value, 1)
    }
}

#endif

extension HubClientTests {
    @MainActor
    func testLateBearerCandidateCannotImportIntoReplacedAuthorizationEpoch() async {
        let gate = HubRequestGate()
        let started = expectation(description: "bearer candidate started")
        let cookies = CookieRecorder()
        let transport = MockTransport { request in
            started.fulfill()
            await gate.wait()
            return jsonResponse("{\"nodes\":[]}", url: request.url!)
        }
        let client = HubClient(baseURL: URL(string: "https://hub.example.com/")!, cookieSource: { [] },
                               cookieSink: { cookies.append($0) }, transport: transport)
        let workspace = HubWorkspace(client: client, requiresAuthentication: false) {}
        defer { workspace.dispose() }
        let login = Task { try await client.loginBearer(token: "candidate") }
        await fulfillment(of: [started], timeout: 2)
        workspace.authenticationSucceeded()
        await gate.release()
        do { try await login.value; XCTFail("Old candidate must not overwrite a new identity") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(cookies.count, 0)
    }

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
        let client = HubClient(baseURL: URL(string: "https://hub.example.com/")!, cookieSource: { [] },
                               cookieSink: { cookies.append($0) }, transport: transport)
        var revocations = 0
        let workspace = HubWorkspace(client: client, requiresAuthentication: false) { revocations += 1 }
        defer { workspace.dispose() }
        // Also retain the raw callback: it may already be queued on MainActor
        // when a new sign-in succeeds, past the client's first admission check.
        let previouslyAdmitted = client.onUnauthorized
        let request = Task { try? await client.listNodes() }
        await fulfillment(of: [started], timeout: 2)
        workspace.authenticationSucceeded()
        await gate.release()
        _ = await request.value
        await previouslyAdmitted?()
        XCTAssertFalse(workspace.store.unauthorized)
        XCTAssertEqual(revocations, 0)
        XCTAssertEqual(cookies.count, 0, "An old response must not replace a newer session cookie")
        // Current-session revocation must still work.
        await client.onUnauthorized?()
        XCTAssertTrue(workspace.store.unauthorized)
        XCTAssertEqual(revocations, 1)
    }

    @MainActor
    func testDisposedWorkspaceIgnoresAlreadyQueuedRevocation() async {
        let client = HubClient(baseURL: URL(string: "https://hub.example.com/")!, cookieSource: { [] })
        var revocations = 0
        let workspace = HubWorkspace(client: client, requiresAuthentication: false) { revocations += 1 }
        let callback = client.onUnauthorized
        workspace.dispose()
        await callback?()
        XCTAssertEqual(revocations, 0)
        XCTAssertFalse(workspace.store.unauthorized)
    }
}

#if canImport(Network)
// Diagnostic controls only: do not assert a hypothesized SDK header-flush
// behavior. The original two stalled-401 invariants remain separate and active.
extension HubClientTests {
    func testSDKStatusAndBodyFlushControlMatrix() async throws {
        var rows: [[String: String]] = []
        for status in [200, 403, 401] {
            for mode in ["headers-only", "partial-body", "complete-body"] {
                rows.append(try await observeSDKResponse(status: status, mode: mode))
            }
        }
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        let text = String(decoding: data, as: UTF8.self)
        print("Hub SDK status/body control matrix:\n\(text)")
        let attachment = XCTAttachment(string: text)
        attachment.name = "Hub SDK status-body-flush controls (no credentials)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func observeSDKResponse(status: Int, mode: String) async throws -> [String: String] {
        let record = HubTestBox<[String: String]>(["status": String(status), "mode": mode])
        let events = HubTestBox<[String]>([])
        let began = Date()
        let milliseconds: @Sendable () -> String = { String(Int(Date().timeIntervalSince(began) * 1000)) }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let port = HubTestBox<UInt16>(0)
        let connection = HubTestBox<NWConnection?>(nil)
        let ready = expectation(description: "control listener ready")
        let sent = expectation(description: "control response send completed")
        listener.stateUpdateHandler = { state in
            if case .ready = state, let value = listener.port {
                port.set(value.rawValue)
                ready.fulfill()
            }
        }

        let reason = status == 200 ? "OK" : (status == 403 ? "Forbidden" : "Unauthorized")
        let completeBody = Data("{}".utf8)
        let contentLength = mode == "complete-body" ? completeBody.count : 65536
        let headers = Data(("HTTP/1.1 \(status) \(reason)\r\n" +
                            "Content-Type: application/json\r\n" +
                            "Content-Length: \(contentLength)\r\n\r\n").utf8)
        let prefix = mode == "partial-body" ? Data("{".utf8) : Data()
        let payload = headers + (mode == "complete-body" ? completeBody : prefix)
        record.update {
            $0["responseHeaderBytes"] = String(headers.count)
            $0["responseBodyBytesSent"] = String(payload.count - headers.count)
            $0["advertisedContentLength"] = String(contentLength)
        }

        // Unlike the original minimal listener, accumulate a whole request
        // header block before replying, ruling out premature-response framing.
        @Sendable func receiveRequest(_ conn: NWConnection, accumulated: Data) {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, complete, error in
                var bytes = accumulated
                if let data { bytes.append(data) }
                if let end = bytes.range(of: Data("\r\n\r\n".utf8)),
                   let firstLineEnd = bytes.range(of: Data("\r\n".utf8)) {
                    let firstLine = String(decoding: bytes[..<firstLineEnd.lowerBound], as: UTF8.self)
                    // Never print the untrusted/raw line or headers. Only
                    // verify our synthetic GET route and protocol version.
                    record.update {
                        $0["requestFirstLineMatchesGETControlHTTP11"] = String(firstLine == "GET /control HTTP/1.1")
                        $0["requestHeaderBytes"] = String(end.upperBound)
                        $0["requestHeadersCompleteMs"] = milliseconds()
                    }
                    conn.send(content: payload, completion: .contentProcessed { error in
                        record.update {
                            $0["sendCompleted"] = "true"
                            $0["sendErrorCode"] = error.map { String(($0 as NSError).code) } ?? "none"
                            $0["sendCompletedMs"] = milliseconds()
                        }
                        sent.fulfill()
                    })
                } else if error != nil || complete || bytes.count > 16384 {
                    record.update {
                        $0["requestReadFailed"] = "true"
                        $0["requestReadErrorCode"] = error.map { String(($0 as NSError).code) } ?? "none"
                    }
                    sent.fulfill()
                } else {
                    receiveRequest(conn, accumulated: bytes)
                }
            }
        }
        listener.newConnectionHandler = { conn in
            connection.set(conn)
            conn.start(queue: .global())
            receiveRequest(conn, accumulated: Data())
        }
        listener.start(queue: .global())
        defer { connection.value?.cancel(); listener.cancel() }
        await fulfillment(of: [ready], timeout: 5)
        guard port.value > 0 else { throw URLError(.cannotConnectToHost) }

        let transport = URLSessionHubTransport(observe: { event in
            let value = "\(milliseconds())ms:\(String(describing: event))"
            events.update { $0.append(value) }
        })
        var request = URLRequest(url: URL(string: "http://localhost:\(port.value)/control")!)
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let finished = HubTestBox(false)
        let task = Task {
            defer { finished.set(true) }
            do {
                let (body, response) = try await transport.execute(request, onUnauthorized: {
                    record.update {
                        $0["unauthorizedCallbacks"] = String((Int($0["unauthorizedCallbacks"] ?? "0") ?? 0) + 1)
                        $0["unauthorizedCallbackMs"] = milliseconds()
                    }
                })
                record.update {
                    $0["resultStatus"] = String(response.statusCode)
                    $0["resultBodyBytes"] = String(body.count)
                }
            } catch {
                record.update { $0["resultErrorCode"] = String((error as NSError).code) }
            }
        }
        await fulfillment(of: [sent], timeout: 5)
        XCTAssertEqual(record.value["requestFirstLineMatchesGETControlHTTP11"], "true")
        XCTAssertEqual(record.value["sendCompleted"], "true")
        XCTAssertEqual(record.value["sendErrorCode"], "none")
        // Bounded observation AFTER the server's successful send callback.
        // No claim about unsupported flush behavior is encoded as an assertion.
        for _ in 0..<20 {
            if finished.value { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        record.update {
            $0["observationWindowMs"] = "2000"
            $0["finishedBeforeCleanup"] = String(finished.value)
            $0["observedEventsBeforeCleanup"] = events.value.joined(separator: " | ")
        }
        task.cancel()
        await task.value
        return record.value
    }

    func testIndependentPythonFixtureResponseControl() async throws {
        let events = HubTestBox<[String]>([])
        let transport = URLSessionHubTransport(observe: { event in
            events.update { $0.append(String(describing: event)) }
        })
        var request = URLRequest(url: URL(string: "http://localhost:8766/__health")!, timeoutInterval: 3)
        request.httpShouldHandleCookies = false
        do {
            let (data, response) = try await transport.execute(request, onUnauthorized: nil)
            guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  body["fixture"] as? Bool == true else {
                throw XCTSkip("Independent control requires the known local native-Hub Python fixture")
            }
            XCTAssertEqual(response.statusCode, 200)
            XCTAssertFalse(events.value.isEmpty)
            // Status + byte count + callback names only, no response payload.
            print("Hub independent Python control: status=\(response.statusCode) bodyBytes=\(data.count) events=\(events.value)")
        } catch let error as URLError where error.code == .cannotConnectToHost || error.code == .cannotFindHost {
            throw XCTSkip("Independent Python fixture is not running on local CI port8766")
        } catch {
            print("Hub independent Python control: errorCode=\((error as NSError).code) events=\(events.value)")
            throw error
        }
    }
}
#endif

extension HubClientTests {
    @MainActor
    func testRequestCookieEpochIsCheckedAfterActorHopIncludingExpiredDeletes() async throws {
        for value in ["old; Path=/; Secure; HttpOnly", "old; Path=/; Secure; HttpOnly; Expires=Thu, 01 Jan 1970 00:00:00 GMT"] {
            let gate = HubRequestGate()
            let admitted = expectation(description: "cookie importer admitted")
            let recorder = CookieRecorder()
            let transport = MockTransport { request in
                jsonResponse("{\"nodes\":[]}", url: request.url!, headers: ["Set-Cookie": "term_llm_hub_session=" + value])
            }
            let client = HubClient(baseURL: URL(string: "https://hub.example/")!, cookieSource: { [] }, transport: transport)
            client.scopedCookieImporter = { cookies, isCurrent in
                admitted.fulfill()
                await gate.wait() // admitted on transport executor, then delayed before MainActor
                try await MainActor.run {
                    guard isCurrent() else { throw CancellationError() }
                    recorder.append(cookies)
                }
            }
            let request = Task { try await client.listNodes() }
            await fulfillment(of: [admitted], timeout: 2)
            client.onUnauthorized = {} // another auth identity wins while actor admission waits
            await gate.release()
            do { _ = try await request.value; XCTFail("Stale import must fail") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(recorder.count, 0, "Neither stale Set-Cookie nor expired-cookie deletion may reach the new identity")
        }
    }

    @MainActor
    func testBearerLoginChecksEpochAgainAfterSuspendedImporterReturns() async throws {
        let gate = HubRequestGate()
        let admitted = expectation(description: "bearer cookie import suspended")
        let client = HubClient(baseURL: URL(string: "https://hub.example/")!, cookieSource: { [] }, transport: MockTransport { request in
            jsonResponse("{\"nodes\":[]}", url: request.url!)
        })
        client.scopedCookieImporter = { _, _ in
            admitted.fulfill()
            await gate.wait() // deliberately returns without checking: client must also reject completion
        }
        let login = Task { try await client.loginBearer(token: "fixture-only") }
        await fulfillment(of: [admitted], timeout: 2)
        client.onUnauthorized = {}
        await gate.release()
        do { try await login.value; XCTFail("A stale login must not report success") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}

extension HubClientTests {
    @MainActor
    func testProductionSourceImporterRejectsOldContextAfterActorAdmissionAndReauth() async throws {
        let gate = HubRequestGate()
        let admitted = expectation(description: "old source importer queued")
        let connection = HubConnection(id: UUID(), name: "Gated Hub", kind: .hub, url: URL(string: "https://hub.example/")!)
        let source = HubSourceWorkspace(connection: connection, bearerStorage: HubMemoryBearerStorage(), dataStore: .nonPersistent(), transport: MockTransport { request in
            jsonResponse("{\"nodes\":[]}", url: request.url!, headers: ["Set-Cookie": "term_llm_hub_session=stale; Path=/; Secure; HttpOnly"])
        })
        defer { source.dispose(removeCredentials: true) }
        let client = try XCTUnwrap(source.hubWorkspace?.client)
        let original = try XCTUnwrap(client.scopedCookieImporter)
        client.scopedCookieImporter = { cookies, isCurrent in
            admitted.fulfill()
            await gate.wait()
            try await original(cookies, isCurrent)
        }
        let request = Task { try await client.listNodes() }
        await fulfillment(of: [admitted], timeout: 2)
        let oldEpoch = source.authEpoch
        _ = await source.prepareAuthentication()
        await gate.release()
        do { _ = try await request.value; XCTFail("Old source importer must fail closed") }
        catch { XCTAssertTrue(error is CancellationError) }
        let cookies = await source.security?.cookies()
        XCTAssertTrue(cookies?.isEmpty == true)
        let accepted = await source.authenticationSucceeded(epoch: oldEpoch)
        XCTAssertFalse(accepted)
        XCTAssertTrue(source.browserRevoked, "A stale detail success must not reopen protected chat")
    }
}

extension HubClientTests {
    @MainActor
    func testOldRequestCannotDispatchUsingCredentialsReadAfterIdentityChanged() async throws {
        let gate = HubRequestGate()
        let reading = expectation(description: "credential read suspended")
        let transport = MockTransport { request in jsonResponse("{\"nodes\":[]}", url: request.url!) }
        let client = HubClient(baseURL: URL(string: "https://hub.example/")!, cookieSource: {
            reading.fulfill()
            await gate.wait()
            return []
        }, transport: transport)
        let request = Task { try await client.listNodes() }
        await fulfillment(of: [reading], timeout: 2)
        client.onUnauthorized = {}
        await gate.release()
        do { _ = try await request.value; XCTFail("Stale request must not dispatch") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(transport.requests.isEmpty)
    }
}
