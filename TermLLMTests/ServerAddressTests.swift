import XCTest
@testable import TermLLM

final class ServerAddressTests: XCTestCase {
    func testNormalization() {
        XCTAssertEqual(ServerAddress.parse("  example.com  ")?.absoluteString, "https://example.com/")
        XCTAssertEqual(ServerAddress.parse("https://example.com/hub/")?.absoluteString, "https://example.com/hub/")
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

    func testInvalidAddresses() {
        for value in ["", "file:///tmp/test", "http://example.com", "http://localhost.evil.com/ui/", "http://127.0.0.1:8080/ui/", "https://", "https://user:pass@example.com", "https://example.com/?token=secret"] {
            XCTAssertNil(ServerAddress.parse(value), value)
        }
    }
}
