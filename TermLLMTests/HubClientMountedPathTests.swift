import XCTest
@testable import TermLLM

// MARK: - Mounted path tests

final class HubClientMountedPathTests: XCTestCase {

    func testMountPathRoot() {
        let c = HubClient(baseURL: URL(string: "https://hub.example.com/")!, cookieSource: { [] })
        XCTAssertEqual(c.mountPath, "")
        XCTAssertEqual(c.expectedHost, "hub.example.com")
    }

    func testMountPathSubpath() {
        let c = HubClient(baseURL: URL(string: "https://hub.example.com/ui/")!, cookieSource: { [] })
        XCTAssertEqual(c.mountPath, "/ui")
    }

    func testMountPathNoTrailingSlash() {
        let c = HubClient(baseURL: URL(string: "https://hub.example.com/hub")!, cookieSource: { [] })
        XCTAssertEqual(c.mountPath, "/hub")
    }

    func testOriginExcludesDefaultPort() {
        let c = HubClient(baseURL: URL(string: "https://hub.example.com:443/")!, cookieSource: { [] })
        XCTAssertEqual(c.origin, "https://hub.example.com")
    }

    func testOriginIncludesNonDefaultPort() {
        let c = HubClient(baseURL: URL(string: "https://hub.example.com:8443/")!, cookieSource: { [] })
        XCTAssertEqual(c.origin, "https://hub.example.com:8443")
    }

    func testHTTPOrigin() {
        let c = HubClient(baseURL: URL(string: "http://localhost:8080/")!, cookieSource: { [] })
        XCTAssertEqual(c.origin, "http://localhost:8080")
        XCTAssertFalse(c.isHTTPS)
    }
}
