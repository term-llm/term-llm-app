import XCTest
@testable import TermLLMMacKit

/// Deterministic HTTP tests for the credential probe. The HTML case is the
/// regression that the previous `/api/auth/session` + any-2xx probe missed.
final class LocalSessionProbeTests: XCTestCase {
    private func endpoint() throws -> ManagedLoopbackEndpoint {
        let status = ServiceStatus(kind: "web", installed: true, managed: true, registered: true,
                                   state: .ready, running: true, autostart: false,
                                   url: "http://127.0.0.1:8765/ui/", host: "127.0.0.1",
                                   port: 8765, basePath: "/ui", auth: "bearer",
                                   enrollment: .notRequired, healthy: true)
        return try ManagedLoopbackEndpoint.make(from: status).get()
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProbeURLProtocol.self]
        return LocalSessionProbe.makeSession(configuration: configuration)
    }

    override func tearDown() {
        ProbeURLProtocol.reset()
        super.tearDown()
    }

    func testValidBearerReturnsAuthenticatedWithProtectedJSONEndpoint() async throws {
        ProbeURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString,
                           "http://127.0.0.1:8765/ui/v1/capabilities")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok_valid")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
            let body = #"{"projects":{"enabled":true},"shell":{"version":1},"live":{"enabled":false}}"#
            return (Self.response(request, status: 200, contentType: "application/json"), Data(body.utf8))
        }
        let outcome = await LocalSessionProbe.probe(endpoint: try endpoint(),
                                                    token: "tok_valid",
                                                    session: session())
        XCTAssertEqual(outcome, .authenticated)
        XCTAssertEqual(outcome.description, "Authentication accepted by the local service.")
    }

    func testHTMLSPAShellIsRejected() async throws {
        // This is exactly what bearer-mode `/api/auth/session` returns: a 200
        // text/html SPA shell. A 2xx-only probe called that authenticated.
        ProbeURLProtocol.handler = { request in
            (Self.response(request, status: 200, contentType: "text/html; charset=utf-8"),
             Data("<!doctype html><title>term-llm</title>".utf8))
        }
        let outcome = await LocalSessionProbe.probe(endpoint: try endpoint(),
                                                    token: "tok_valid",
                                                    session: session())
        guard case .invalidResponse(let reason) = outcome else {
            return XCTFail("HTML 200 must not be accepted: \(outcome)")
        }
        XCTAssertTrue(reason.contains("text/html"))
    }

    func testJSONWithWrongShapeIsRejected() async throws {
        ProbeURLProtocol.handler = { request in
            (Self.response(request, status: 200, contentType: "application/json"),
             Data(#"{"ok":true}"#.utf8))
        }
        let outcome = await LocalSessionProbe.probe(endpoint: try endpoint(),
                                                    token: "tok_valid",
                                                    session: session())
        guard case .invalidResponse = outcome else {
            return XCTFail("unexpected shape must fail closed: \(outcome)")
        }
    }

    func testMissingOrInvalidCredentialIsUnauthorized() async throws {
        ProbeURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok_bad")
            return (Self.response(request, status: 401, contentType: "application/json"),
                    Data(#"{"error":{"message":"invalid authentication credentials"}}"#.utf8))
        }
        let outcome = await LocalSessionProbe.probe(endpoint: try endpoint(),
                                                    token: "tok_bad",
                                                    session: session())
        XCTAssertEqual(outcome, .unauthorized(401))
    }

    func testRedirectIsRejectedAndNotFollowed() async throws {
        ProbeURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1",
                             headerFields: ["Content-Type": "application/json",
                                            "Location": "http://evil.example/steal"])!, Data())
        }
        let outcome = await LocalSessionProbe.probe(endpoint: try endpoint(),
                                                    token: "tok_valid",
                                                    session: session())
        XCTAssertEqual(outcome, .redirected(302))
        XCTAssertEqual(ProbeURLProtocol.requests.count, 1,
                       "a redirect must not generate a second credentialed request")
    }

    func testRedirectToAnotherPathOnSameOriginIsAlsoRejected() async throws {
        ProbeURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 307, httpVersion: "HTTP/1.1",
                             headerFields: ["Location": "/ui/v1/models"])!, Data())
        }
        let outcome = await LocalSessionProbe.probe(endpoint: try endpoint(),
                                                    token: "tok_valid",
                                                    session: session())
        XCTAssertEqual(outcome, .redirected(307))
        XCTAssertEqual(ProbeURLProtocol.requests.count, 1)
    }

    func testServerErrorIsNotAuthenticated() async throws {
        ProbeURLProtocol.handler = { request in
            (Self.response(request, status: 500, contentType: "application/json"), Data("{}".utf8))
        }
        let outcome = await LocalSessionProbe.probe(endpoint: try endpoint(),
                                                    token: "tok_valid",
                                                    session: session())
        XCTAssertEqual(outcome, .unexpected(500))
    }

    func testProbeUsesDocumentedProtectedPath() {
        XCTAssertEqual(LocalSessionProbe.protectedPath, "v1/capabilities")
        XCTAssertFalse(LocalSessionProbe.protectedPath.contains("api/auth/session"))
    }

    private static func response(_ request: URLRequest, status: Int,
                                 contentType: String) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": contentType])!
    }
}

final class ProbeURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    static var requests: [URLRequest] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock()
        handler = nil
        requests = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let handler = Self.handler
        Self.lock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
