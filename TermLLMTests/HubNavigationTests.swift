import XCTest
@testable import TermLLM

final class HubNavigationTests: XCTestCase {
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

    func testFixtureCannotBeEnabledForArbitraryRemoteServer() {
        // The test runner never needs private credentials or a public service.
        if let fixture = HubFixture.server {
            XCTAssertEqual(fixture.absoluteString, "http://localhost:8766/")
        }
    }
}
