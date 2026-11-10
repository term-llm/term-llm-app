import XCTest
@testable import TermLLM

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
