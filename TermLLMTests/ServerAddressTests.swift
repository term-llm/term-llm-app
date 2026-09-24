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

    func testInvalidAddresses() {
        for value in ["", "file:///tmp/test", "http://localhost:8080", "https://", "https://user:pass@example.com", "https://example.com/?token=secret"] {
            XCTAssertNil(ServerAddress.parse(value), value)
        }
    }
}
