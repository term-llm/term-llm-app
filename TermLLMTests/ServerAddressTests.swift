import XCTest
@testable import TermLLM

final class ServerAddressTests: XCTestCase {
    func testNormalization() {
        XCTAssertEqual(ServerAddress.parse("  example.com  ")?.absoluteString, "https://example.com/")
        XCTAssertEqual(ServerAddress.parse("https://example.com/hub/")?.absoluteString, "https://example.com/hub/")
    }

    @MainActor
    func testPublicDemoAddress() {
        XCTAssertEqual(ServerAddress.parse(ServerAddress.demo)?.absoluteString, ServerAddress.demo)
        XCTAssertEqual(ServerAddress.parse("demo.term-llm.com")?.absoluteString, ServerAddress.demo)
        let settings = DeviceToolsSettings(defaults: isolatedDefaults())
        XCTAssertFalse(settings.isEnabled(for: URL(string: ServerAddress.demo)!))
    }

    func testPKCEChallengeMatchesRFC7636() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(NativeLogin.challenge(for: verifier), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testNativeOriginNormalizesDefaultHTTPSPort() {
        XCTAssertEqual(NativeLogin.origin(for: URL(string: "https://chat.example.com:443/ui/")!), "https://chat.example.com")
        XCTAssertEqual(NativeLogin.origin(for: URL(string: "https://chat.example.com:8443/ui/")!), "https://chat.example.com:8443")
    }

    func testLocalSimulatorServer() {
        #if targetEnvironment(simulator)
        XCTAssertEqual(ServerAddress.parse("http://localhost:8080/ui/")?.absoluteString, "http://localhost:8080/ui/")
        XCTAssertEqual(NativeLogin.origin(for: URL(string: "http://localhost:8080/ui/")!), "http://localhost:8080")
        XCTAssertEqual(NativeLogin.origin(for: URL(string: "http://localhost:80/ui/")!), "http://localhost")
        #else
        XCTAssertNil(ServerAddress.parse("http://localhost:8080/ui/"))
        #endif
    }

    func testBackgroundAudioEnabledForLiveVoice() {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        XCTAssertTrue(modes?.contains("audio") == true)
    }

    func testHTTPRecoveryDistinguishesLoginFromServerFailures() {
        let url = URL(string: "https://example.com/ui/")!
        func response(_ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
            HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
        }
        XCTAssertNil(BrowserView.recovery(for: response(200)))
        XCTAssertNil(BrowserView.recovery(for: response(302)))
        XCTAssertEqual(BrowserView.recovery(for: response(401, headers: ["X-Term-Llm-Login-Url": "/ui/auth/login"])), .signIn)
        XCTAssertEqual(BrowserView.recovery(for: response(401)), .httpError(401))
        XCTAssertEqual(BrowserView.recovery(for: response(404)), .httpError(404))
        XCTAssertEqual(BrowserView.recovery(for: response(503)), .httpError(503))
    }

    func testInvalidAddresses() {
        for value in ["", "file:///tmp/test", "http://example.com", "http://localhost.evil.com/ui/", "http://127.0.0.1:8080/ui/", "https://", "https://user:pass@example.com", "https://example.com/?token=secret"] {
            XCTAssertNil(ServerAddress.parse(value), value)
        }
    }
}
