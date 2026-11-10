import XCTest
@testable import TermLLM

// MARK: - Passkey ceremony tests

final class HubPasskeyTests: XCTestCase {

    private func makeClient(
        handler: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    ) -> (HubClient, MockTransport) {
        let transport = MockTransport(handler: handler)
        let client = HubClient(
            baseURL: URL(string: "https://hub.example.com/")!,
            cookieSource: { [] },
            transport: transport
        )
        return (client, transport)
    }

    func testBeginLoginSendsCorrectPath() async throws {
        let (client, transport) = makeClient { _ in
            jsonResponse("{\"publicKey\":{\"challenge\":\"abc\"}}")
        }
        let data = try await client.beginLogin(returnPath: "/dashboard")
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
        let response = try await client.finishLogin(credential: credentialJSON)
        XCTAssertEqual(transport.requests[0].url.path, "/api/auth/login/finish")
        XCTAssertEqual(transport.requests[0].method, "POST")
        XCTAssertEqual(transport.requests[0].body, credentialJSON)
        XCTAssertEqual(response.redirect, "/hub/")
    }

    func testBeginReauthenticationPath() async throws {
        let (client, transport) = makeClient { _ in
            jsonResponse("{\"publicKey\":{\"challenge\":\"xyz\"}}")
        }
        _ = try await client.beginReauthentication()
        XCTAssertEqual(transport.requests[0].url.path, "/api/auth/reauth/begin")
        XCTAssertEqual(transport.requests[0].method, "POST")
    }

    func testFinishReauthenticationReturnsOk() async throws {
        let (client, _) = makeClient { _ in
            jsonResponse("{\"ok\":true}")
        }
        let result = try await client.finishReauthentication(credential: Data("{}".utf8))
        XCTAssertTrue(result.ok)
    }

    func testBeginAdditionalRegistrationPath() async throws {
        let (client, transport) = makeClient { _ in
            jsonResponse("{\"publicKey\":{\"challenge\":\"def\"}}")
        }
        _ = try await client.beginAdditionalRegistration(displayName: "My Passkey")
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
        let cred = try await client.finishAdditionalRegistration(credential: Data("{}".utf8))
        XCTAssertEqual(transport.requests[0].url.path, "/api/auth/credentials/register/finish")
        XCTAssertEqual(cred.recordID, "new-cred")
        XCTAssertEqual(cred.displayName, "My Passkey")
        XCTAssertEqual(cred.transports, ["internal"])
    }

    // MARK: Grant registration

    func testVerifyGrantBootstrapPath() async throws {
        let (client, transport) = makeClient { _ in jsonResponse("{\"ok\":true}") }
        _ = try await client.verifyGrant(prefix: .bootstrap, code: "123456")
        XCTAssertEqual(transport.requests[0].url.path, "/api/auth/bootstrap/verify")
    }

    func testVerifyGrantRecoveryPath() async throws {
        let (client, transport) = makeClient { _ in jsonResponse("{\"ok\":true}") }
        _ = try await client.verifyGrant(prefix: .recovery, code: "654321")
        XCTAssertEqual(transport.requests[0].url.path, "/api/auth/recovery/verify")
    }

    func testBeginGrantRegistrationPath() async throws {
        let (client, transport) = makeClient { _ in jsonResponse("{\"publicKey\":{}}") }
        _ = try await client.beginGrantRegistration(prefix: .bootstrap, displayName: "Key")
        XCTAssertEqual(transport.requests[0].url.path, "/api/auth/bootstrap/register/begin")
    }

    func testFinishGrantRegistrationWithReturnPath() async throws {
        let (client, transport) = makeClient { _ in jsonResponse("{\"redirect\":\"/hub/\"}") }
        _ = try await client.finishGrantRegistration(
            prefix: .recovery, credential: Data("{}".utf8), returnPath: "/dashboard"
        )
        XCTAssertEqual(transport.requests[0].url.path, "/api/auth/recovery/register/finish")
        XCTAssertTrue(transport.requests[0].url.query?.contains("return=") == true)
    }

    func testFinishGrantRegistrationEmptyReturnPath() async throws {
        let (client, transport) = makeClient { _ in jsonResponse("{\"redirect\":\"/hub/\"}") }
        _ = try await client.finishGrantRegistration(
            prefix: .bootstrap, credential: Data("{}".utf8), returnPath: ""
        )
        XCTAssertNil(transport.requests[0].url.query)
    }

    // MARK: Other auth endpoints

    func testNativeAuthorizePath() async throws {
        let (client, transport) = makeClient { _ in
            jsonResponse("{\"redirect\":\"/hub/\"}")
        }
        _ = try await client.authorizeNative(challenge: "challenge123")
        XCTAssertEqual(transport.requests[0].url.path, "/api/auth/native/authorize")
        XCTAssertEqual(transport.requests[0].method, "POST")
    }

    func testRenameCredentialPath() async throws {
        let credJSON = """
        {"record_id":"r1","display_name":"Renamed","transports":null,
         "created_at":"2025-01-01","last_used_at":"2025-06-01"}
        """
        let (client, transport) = makeClient { _ in jsonResponse(credJSON) }
        let cred = try await client.renameCredential(recordID: "r1", displayName: "Renamed")
        XCTAssertEqual(transport.requests[0].url.path, "/api/auth/credentials/r1")
        XCTAssertEqual(transport.requests[0].method, "PATCH")
        XCTAssertEqual(cred.displayName, "Renamed")
    }

    func testRemoveCredentialPath() async throws {
        let (client, transport) = makeClient { _ in jsonResponse("{\"ok\":true}") }
        _ = try await client.removeCredential(recordID: "r1")
        XCTAssertEqual(transport.requests[0].url.path, "/api/auth/credentials/r1")
        XCTAssertEqual(transport.requests[0].method, "DELETE")
    }

    func testRevokeOtherSessionsPath() async throws {
        let (client, transport) = makeClient { _ in jsonResponse("{\"revoked\":3}") }
        let result = try await client.revokeOtherSessions()
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
        XCTAssertFalse(result.recentlyAuthenticated)
    }

    func testHealthzPath() async throws {
        let (client, transport) = makeClient { _ in jsonResponse("{\"status\":\"ok\"}") }
        let result = try await client.healthz()
        XCTAssertEqual(transport.requests[0].url.path, "/healthz")
        XCTAssertEqual(result.status, "ok")
    }
}
