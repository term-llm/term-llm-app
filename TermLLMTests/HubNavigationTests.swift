import XCTest
@testable import TermLLM

final class HubNavigationTests: XCTestCase {
    func testFileDocumentsAreSeparatedFromChatRoutes() throws {
        let hub = try XCTUnwrap(URL(string: "https://hub.samsaffron.com/"))
        let file = try XCTUnwrap(URL(string: "https://hub.samsaffron.com/node/jarvis/files/term-llm-proxy-generic-review.md"))
        XCTAssertTrue(HubNavigation.isFileDocument(file, server: hub))
        let mounted = try XCTUnwrap(URL(string: "https://hub.example/work/"))
        for path in ["/work/node/jarvis/files/report.md", "/work/node/jarvis/files/report.html?preview=1", "/work/files/report.pdf"] {
            XCTAssertTrue(HubNavigation.isFileDocument(try XCTUnwrap(URL(string: path, relativeTo: mounted)?.absoluteURL), server: mounted), path)
        }
        for path in ["/work/", "/work/node/jarvis/?new=1", "/work/node/jarvis/chat/files",
                     "/work/node/files/chat/123", "/work/api/files/report.md", "/other/files/report.md"] {
            XCTAssertFalse(HubNavigation.isFileDocument(try XCTUnwrap(URL(string: path, relativeTo: mounted)?.absoluteURL), server: mounted), path)
        }
        XCTAssertFalse(HubNavigation.isFileDocument(file, server: mounted))
        let direct = try XCTUnwrap(URL(string: "https://node.example/ui/"))
        XCTAssertTrue(HubNavigation.isFileDocument(try XCTUnwrap(URL(string: "files/report.md", relativeTo: direct)?.absoluteURL), server: direct))
    }

    func testMountedPathsAreNotDoublePrefixed() throws {
        let server = try XCTUnwrap(URL(string: "https://hub.example/prefix/"))
        XCTAssertEqual(HubNavigation.destination("/prefix/node/dev/chat/7?new=1", server: server)?.absoluteString,
                       "https://hub.example/prefix/node/dev/chat/7?new=1")
        XCTAssertNil(HubNavigation.destination("/node/dev/", server: server))
        XCTAssertNil(HubNavigation.destination("/prefix-other/node/dev/", server: server))
    }

    func testUntrustedHubNavigationCannotEscapeOriginOrMount() throws {
        let server = try XCTUnwrap(URL(string: "https://hub.example/prefix/"))
        for path in ["//evil.example/", "https://evil.example/", "javascript:alert(1)",
                     "/prefix/../secret", "/prefix/%2e%2e/secret", "/prefix/node\\evil", "/prefix/node%5cevil",
                     "/prefix/\nnode/dev", "/prefix/%2f%2fevil.example/"] {
            XCTAssertNil(HubNavigation.destination(path, server: server), path)
        }
    }

    func testConnectionImportRequiresExplicitCredentialFreeHTTPSRoot() throws {
        let link = try XCTUnwrap(URL(string: "termllm://connect?server=https%3A%2F%2Fhub.example%2Fprefix%2F"))
        XCTAssertEqual(HubConnectionImport.server(from: link)?.absoluteString, "https://hub.example/prefix/")
        for raw in ["termllm://connect?server=http%3A%2F%2Flocalhost%3A8080%2F",
                    "termllm://connect?server=https%3A%2F%2Flocalhost%2F",
                    "termllm://connect?server=https%3A%2F%2F127.0.0.1%2F",
                    "termllm://connect?server=https%3A%2F%2Fu%3Ap%40hub.example%2F",
                    "termllm://connect?server=https%3A%2F%2Fhub.example%2F%3Ftoken%3Dsecret",
                    "termllm://connect?server=https%3A%2F%2Fhub.example%2F&token=secret",
                    "termllm://connect?server=https%3A%2F%2Fhub.example%2F&server=https%3A%2F%2Fevil.example%2F",
                    "https://hub.example/connect?server=https%3A%2F%2Fhub.example%2F"] {
            let url = try XCTUnwrap(URL(string: raw))
            XCTAssertNil(HubConnectionImport.server(from: url), raw)
        }
    }

    func testRoleDiscoveryDoesNotMisclassifyAuthOutagesOrDirectServers() {
        XCTAssertEqual(HubServerRole.classify(status: 200, data: Data(#"{"status":"ok","role":"hub"}"#.utf8)), .hub)
        XCTAssertEqual(HubServerRole.classify(status: 200, data: Data(#"{"status":"ok"}"#.utf8)), .direct)
        for status in [401, 403, 404, 500, 503] {
            XCTAssertEqual(HubServerRole.classify(status: status, data: Data(#"{"role":"hub"}"#.utf8)), .unknown)
        }
        XCTAssertEqual(HubServerRole.classify(status: 200, data: Data("not JSON".utf8)), .unknown)
    }

    func testLegacyDiscoveryRequiresHealthyRecognizedDirectShape() {
        for json in ["{}", "{\"error\":\"offline\"}", "{\"status\":\"failed\"}", "{\"status\":\"ok\",\"role\":\"other\"}"] {
            XCTAssertEqual(HubServerRole.classify(status: 200, data: Data(json.utf8)), .unknown, json)
        }
        XCTAssertEqual(HubServerRole.classify(status: 200, data: Data(#"{"status":"ok"}"#.utf8)), .direct)
    }
    func testNodeActionCannotNavigateToAnotherKnownNode() {
        let server = URL(string: "https://example.com/work/")!
        for path in ["/work/node/B/?new=1", "/work/node/B/chat/7", "/work/node/B/"] {
            XCTAssertNil(HubNavigation.chatDestination(path, server: server, nodeID: "A", direct: false))
        }
    }
    func testPrepopulatedPendingNavigationWaitsForOwningWindowAndMount() {
        let server = URL(string: "https://example.com/work/")!
        var pending = PushNavigation(id: UUID(), url: URL(string: "https://example.com/work/node/A/chat/7")!, windowID: "owner")
        XCTAssertFalse(pending.canPresent(in: nil, server: server))
        XCTAssertFalse(pending.canPresent(in: "sibling", server: server))
        XCTAssertTrue(pending.canPresent(in: "owner", server: server), "Attaching the owning window must reveal an already pending event")
        pending.windowID = "reassigned"
        XCTAssertFalse(pending.canPresent(in: "owner", server: server))
        XCTAssertTrue(pending.canPresent(in: "reassigned", server: server))
        XCTAssertFalse(pending.canPresent(in: "reassigned", server: URL(string: "https://example.com/home/")!))
    }

    func testFixtureCannotBeEnabledForArbitraryRemoteServer() {
        // The test runner never needs private credentials or a public service.
        if let fixture = HubFixture.server {
            XCTAssertEqual(fixture.absoluteString, "http://localhost:8766/")
        }
    }
}

/// Protocol fixture only: this does not exercise a real VPN, DNS or TLS handshake.
final class TailnetDiscoveryTests: XCTestCase, @unchecked Sendable {
    private func configuration() -> URLSessionConfiguration {
        let configuration = HubServerRole.discoveryConfiguration()
        configuration.protocolClasses = [TailnetHealthProtocol.self]
        return configuration
    }

    func testDiscoveryKeepsCredentialFreeBoundedSessionWithLongerVPNBudget() {
        let configuration = configuration()
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 15)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 15)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.urlCache)
    }

    func testMountedTailnetHealthProbeAcceptsHealthyResponse() async throws {
        let server = URL(string: "https://healthy.tail123.ts.net/hub/")!
        let role = try await HubServerRole.detect(server: server, configuration: configuration())
        XCTAssertEqual(role, .hub)
    }

    func testDNSAndTLSFailuresRemainFailuresWithSafeActionableMessages() async throws {
        for (host, code, guidance) in [
            ("dns.tail123.ts.net", URLError.cannotFindHost, "MagicDNS"),
            ("tls.tail123.ts.net", URLError.serverCertificateUntrusted, "certificate"),
            ("timeout.tail123.ts.net", URLError.timedOut, "15 seconds"),
            ("offline.tail123.ts.net", URLError.cannotConnectToHost, "Tailscale")
        ] {
            do {
                _ = try await HubServerRole.detect(server: URL(string: "https://\(host)/hub/")!, configuration: configuration())
                XCTFail("Failed connection must not be classified as a server")
            } catch {
                XCTAssertEqual(error as? HubServerRole.DiscoveryFailure, .network(code: code.rawValue, tailnet: true))
                XCTAssertTrue(error.localizedDescription.contains(guidance), error.localizedDescription)
                XCTAssertFalse(error.localizedDescription.contains("private-detail"))
                XCTAssertFalse(error.localizedDescription.contains(host))
            }
        }
    }

    func testUnhealthyOrRedirectResponsesDoNotBecomeDirectNodes() async throws {
        for (host, status) in [("auth", 401), ("redirect", 302), ("unavailable", 503)] {
            do {
                _ = try await HubServerRole.detect(server: URL(string: "https://\(host).tail123.ts.net/hub/")!, configuration: configuration())
                XCTFail("HTTP \(status) must not be classified as a server")
            } catch {
                XCTAssertEqual(error as? HubServerRole.DiscoveryFailure, .http(status))
            }
        }
        let unknown = try await HubServerRole.detect(server: URL(string: "https://malformed.tail123.ts.net/hub/")!, configuration: configuration())
        XCTAssertEqual(unknown, .unknown)
    }

    func testUnreachableServerDoesNotClaimAnInternetOutage() {
        let code = URLError.notConnectedToInternet.rawValue
        let local = HubServerRole.DiscoveryFailure.network(code: code, tailnet: false).localizedDescription
        let tailnet = HubServerRole.DiscoveryFailure.network(code: code, tailnet: true).localizedDescription
        XCTAssertEqual(local, ServerAddress.unreachableMessage)
        XCTAssertTrue(tailnet.hasPrefix("Couldn’t reach this server."))
        XCTAssertTrue(tailnet.contains("Tailscale"))
        XCTAssertFalse(local.localizedCaseInsensitiveContains("offline"))
        XCTAssertFalse(tailnet.localizedCaseInsensitiveContains("offline"))
    }

    func testOrdinaryDNSFailureDoesNotSuggestAnUnrelatedVPN() {
        let error = HubServerRole.DiscoveryFailure.network(code: URLError.cannotFindHost.rawValue, tailnet: false)
        XCTAssertFalse(error.localizedDescription.contains("Tailscale"))
        XCTAssertFalse(error.localizedDescription.contains("MagicDNS"))
    }
}

private final class TailnetHealthProtocol: ScriptedURLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func response(for request: URLRequest) throws -> Response {
        let url = request.url!
        let errors: [String: URLError.Code] = ["dns": .cannotFindHost, "tls": .serverCertificateUntrusted,
                                               "timeout": .timedOut, "offline": .cannotConnectToHost]
        let host = url.host?.components(separatedBy: ".").first ?? ""
        if let code = errors[host] {
            throw NSError(domain: NSURLErrorDomain, code: code.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "private-detail", NSURLErrorFailingURLStringErrorKey: url.absoluteString])
        }
        // The fixture accepts only the requested mount and credential-free probe.
        let validRequest = url.path == "/hub/healthz" && request.timeoutInterval == 15
            && !request.httpShouldHandleCookies && request.value(forHTTPHeaderField: "Authorization") == nil
            && request.value(forHTTPHeaderField: "Cookie") == nil
        let statuses = ["auth": 401, "redirect": 302, "unavailable": 503]
        let status = validRequest ? (statuses[host] ?? 200) : 400
        return Response(status: status, headers: ["Content-Type": "application/json"],
                        body: Data((host == "malformed" ? "not JSON" : #"{"status":"ok","role":"hub"}"#).utf8))
    }
}
