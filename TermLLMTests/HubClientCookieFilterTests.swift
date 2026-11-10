import XCTest
@testable import TermLLM

// MARK: - Cookie filtering tests

final class HubClientCookieFilterTests: XCTestCase {

    private func client(base: String = "https://hub.example.com/") -> HubClient {
        HubClient(baseURL: URL(string: base)!, cookieSource: { [] })
    }

    private func cookie(
        name: String = "test", value: String = "v",
        domain: String = "hub.example.com", path: String = "/",
        secure: Bool = false, expires: Date? = Date(timeIntervalSinceNow: 3600)
    ) -> HTTPCookie {
        var props: [HTTPCookiePropertyKey: Any] = [
            .name: name, .value: value, .domain: domain, .path: path,
        ]
        if secure { props[.secure] = "TRUE" }
        if let expires { props[.expires] = expires }
        return HTTPCookie(properties: props)!
    }

    func testExactHostAccepted() {
        let c = client()
        let url = URL(string: "https://hub.example.com/api/nodes")!
        XCTAssertEqual(c.filteredCookies([cookie()], for: url).count, 1)
    }

    func testDomainCookieRejected() {
        let c = client()
        let url = URL(string: "https://hub.example.com/api/nodes")!
        XCTAssertEqual(c.filteredCookies([cookie(domain: ".example.com")], for: url).count, 0)
    }

    func testWrongHostRejected() {
        XCTAssertEqual(client().filteredCookies(
            [cookie(domain: "other.example.com")],
            for: URL(string: "https://hub.example.com/api")!
        ).count, 0)
    }

    func testWebSessionCookieRejected() {
        XCTAssertEqual(client().filteredCookies(
            [cookie(name: "term_llm_web_session")],
            for: URL(string: "https://hub.example.com/api")!
        ).count, 0)
    }

    func testExpiredCookieRejected() {
        XCTAssertEqual(client().filteredCookies(
            [cookie(expires: Date(timeIntervalSinceNow: -1))],
            for: URL(string: "https://hub.example.com/api")!
        ).count, 0)
    }

    func testSessionCookieNoExpiryAccepted() {
        XCTAssertEqual(client().filteredCookies(
            [cookie(expires: nil)],
            for: URL(string: "https://hub.example.com/api")!
        ).count, 1)
    }

    func testSecureCookieRejectedOnHTTP() {
        let c = client(base: "http://localhost:8080/")
        XCTAssertEqual(c.filteredCookies(
            [cookie(domain: "localhost", secure: true)],
            for: URL(string: "http://localhost:8080/api")!
        ).count, 0)
    }

    // Auth cookie isolation

    func testRootAuthCookieNotSentToNestedHub() {
        let c = client(base: "https://hub.example.com/nested/")
        XCTAssertEqual(c.filteredCookies(
            [cookie(name: "term_llm_hub_token", path: "/")],
            for: URL(string: "https://hub.example.com/nested/api/nodes")!
        ).count, 0)
    }

    func testNestedAuthCookieNotSentToRootHub() {
        let c = client(base: "https://hub.example.com/")
        XCTAssertEqual(c.filteredCookies(
            [cookie(name: "term_llm_hub_token", path: "/nested/")],
            for: URL(string: "https://hub.example.com/api/nodes")!
        ).count, 0)
    }

    func testAuthCookieAtCorrectMountAccepted() {
        let c = client(base: "https://hub.example.com/hub/")
        XCTAssertEqual(c.filteredCookies(
            [cookie(name: "term_llm_hub_token", path: "/hub/")],
            for: URL(string: "https://hub.example.com/hub/api/nodes")!
        ).count, 1)
    }

    func testRootAuthCookieAcceptedForRootHub() {
        let c = client(base: "https://hub.example.com/")
        XCTAssertEqual(c.filteredCookies(
            [cookie(name: "term_llm_hub_token", path: "/")],
            for: URL(string: "https://hub.example.com/api/nodes")!
        ).count, 1)
    }

    func testSessionCookieIsolatedSameAsToken() {
        let c = client(base: "https://hub.example.com/nested/")
        XCTAssertEqual(c.filteredCookies(
            [cookie(name: "term_llm_hub_session", path: "/")],
            for: URL(string: "https://hub.example.com/nested/api/auth/session")!
        ).count, 0)
    }

    func testCeremonyCookiesIsolated() {
        let c = client(base: "https://hub.example.com/nested/")
        for name in ["term_llm_hub_login", "term_llm_hub_bootstrap", "term_llm_hub_recovery",
                      "term_llm_hub_reauth", "term_llm_hub_registration"] {
            XCTAssertEqual(c.filteredCookies(
                [cookie(name: name, path: "/")],
                for: URL(string: "https://hub.example.com/nested/api")!
            ).count, 0, "\(name) leaked from root to nested")
        }
    }

    // RFC path boundary

    func testRFCPathBoundarySlash() {
        let c = client()
        XCTAssertEqual(c.filteredCookies(
            [cookie(name: "other", path: "/foo")],
            for: URL(string: "https://hub.example.com/foo/bar")!
        ).count, 1)
        XCTAssertEqual(c.filteredCookies(
            [cookie(name: "other", path: "/foo")],
            for: URL(string: "https://hub.example.com/foobar")!
        ).count, 0, "/foo must not match /foobar")
    }

    func testRFCPathExactMatch() {
        XCTAssertEqual(client().filteredCookies(
            [cookie(name: "other", path: "/api/nodes")],
            for: URL(string: "https://hub.example.com/api/nodes")!
        ).count, 1)
    }

    func testRFCPathTrailingSlash() {
        XCTAssertEqual(client().filteredCookies(
            [cookie(name: "other", path: "/hub/")],
            for: URL(string: "https://hub.example.com/hub/api")!
        ).count, 1)
    }
}
