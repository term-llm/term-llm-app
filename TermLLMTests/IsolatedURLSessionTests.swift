import Foundation
import XCTest
#if os(macOS)
@testable import TermLLMMac
#else
@testable import TermLLM
#endif

@MainActor
final class IsolatedURLSessionTests: XCTestCase {
    private func assertIsolated(_ configuration: URLSessionConfiguration,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(configuration.identifier, file: file, line: line)
        XCTAssertFalse(configuration.httpShouldSetCookies, file: file, line: line)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never, file: file, line: line)
        XCTAssertNil(configuration.httpCookieStorage, file: file, line: line)
        XCTAssertNil(configuration.urlCredentialStorage, file: file, line: line)
        XCTAssertNil(configuration.urlCache, file: file, line: line)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData, file: file, line: line)
    }

    func testConfigurationEnforcesBoundaryAfterCustomization() {
        let configuration = IsolatedURLSession.configuration {
            $0.timeoutIntervalForRequest = 7
            $0.timeoutIntervalForResource = 19
            $0.protocolClasses = [IsolatedSessionProtocol.self]
            $0.httpShouldSetCookies = true
            $0.httpCookieAcceptPolicy = .always
            $0.httpCookieStorage = .shared
            $0.urlCredentialStorage = .shared
            $0.urlCache = .shared
            $0.requestCachePolicy = .returnCacheDataElseLoad
        }
        assertIsolated(configuration)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 7)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 19)
        XCTAssertTrue(configuration.protocolClasses?.first === IsolatedSessionProtocol.self)
        let another = IsolatedURLSession.configuration()
        XCTAssertFalse(configuration === another)
        assertIsolated(another)
    }

    func testProductionSessionConfigurationsPreserveTransportSettings() {
        let hub = HubClient.ephemeralSession(delegate: RejectAllRedirects())
        let media = ListenMediaSession.makeSession(protocolClasses: [IsolatedSessionProtocol.self])
        defer { hub.invalidateAndCancel(); media.invalidateAndCancel() }
        assertIsolated(hub.configuration)
        XCTAssertEqual(hub.configuration.timeoutIntervalForRequest, HubClient.defaultTimeout)
        XCTAssertEqual(hub.configuration.timeoutIntervalForResource, HubClient.defaultTimeout)
        let discovery = HubServerRole.discoveryConfiguration()
        assertIsolated(discovery)
        XCTAssertEqual(discovery.timeoutIntervalForRequest, HubServerRole.discoveryTimeout)
        XCTAssertEqual(discovery.timeoutIntervalForResource, HubServerRole.discoveryTimeout)
        assertIsolated(media.configuration)
        XCTAssertTrue(media.configuration.protocolClasses?.first === IsolatedSessionProtocol.self)
        let defaults = URLSessionConfiguration.ephemeral
        XCTAssertEqual(media.configuration.timeoutIntervalForRequest, defaults.timeoutIntervalForRequest)
        XCTAssertEqual(media.configuration.timeoutIntervalForResource, defaults.timeoutIntervalForResource)
    }

    func testSessionsDoNotBorrowAmbientStateOrRetainResponseCookiesAndCache() async throws {
        // A unique domain keeps this fixture out of other tests' credentials and
        // removes exactly the entries it installs, never clearing global stores.
        let host = "isolated-\(UUID().uuidString.lowercased()).invalid"
        let url = URL(string: "https://\(host)/media")!
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: host, .path: "/", .name: "ambient", .value: "secret"]))
        let protection = URLProtectionSpace(host: host, port: 443, protocol: "https", realm: "isolated", authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        let credential = URLCredential(user: "ambient", password: "secret", persistence: .forSession)
        HTTPCookieStorage.shared.setCookie(cookie)
        URLCredentialStorage.shared.setDefaultCredential(credential, for: protection)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Cache-Control": "max-age=3600"])!
        URLCache.shared.storeCachedResponse(CachedURLResponse(response: response, data: Data("ambient cache".utf8)),
                                           for: URLRequest(url: url))
        defer {
            HTTPCookieStorage.shared.deleteCookie(cookie)
            URLCredentialStorage.shared.remove(credential, for: protection)
            URLCache.shared.removeCachedResponse(for: URLRequest(url: url))
        }
        let first = ListenMediaSession.makeSession(protocolClasses: [IsolatedSessionProtocol.self])
        let second = URLSession(configuration: IsolatedURLSession.configuration {
            $0.protocolClasses = [IsolatedSessionProtocol.self]
        })
        defer { first.invalidateAndCancel(); second.invalidateAndCancel() }
        var replies: Set<Data> = []
        for session in [first, first, second] {
            let (data, _) = try await session.data(from: url)
            let body = try JSONDecoder().decode([String: String].self, from: data)
            XCTAssertEqual(body["cookie"], "")
            XCTAssertEqual(body["authorization"], "")
            replies.insert(data)
        }
        XCTAssertEqual(replies.count, 3, "Each request must reach the protocol, not a response cache")
        var scoped = URLRequest(url: url)
        scoped.setValue("Bearer scoped", forHTTPHeaderField: "Authorization")
        scoped.setValue("owner=scoped", forHTTPHeaderField: "Cookie")
        let (data, _) = try await first.data(for: scoped)
        let body = try JSONDecoder().decode([String: String].self, from: data)
        XCTAssertEqual(body["authorization"], "Bearer scoped")
        XCTAssertEqual(body["cookie"], "owner=scoped", "Explicit per-owner credentials must still work")
    }

    func testMediaRedirectPolicyStillFollowsPublicRedirectWithoutScopedCredentials() async throws {
        let session = ListenMediaSession.makeSession()
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://isolated.invalid/start")!
        let destination = URL(string: "https://other.invalid/audio")!
        let task = session.dataTask(with: url)
        let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil)!
        var request = URLRequest(url: destination)
        request.setValue("Bearer scoped", forHTTPHeaderField: "Authorization")
        request.setValue("owner=scoped", forHTTPHeaderField: "Cookie")
        let redirected: URLRequest? = await withCheckedContinuation { continuation in
            ListenMediaSession.Delegate().urlSession(session, task: task, willPerformHTTPRedirection: response,
                                                     newRequest: request) { continuation.resume(returning: $0) }
        }
        let followed = try XCTUnwrap(redirected)
        XCTAssertEqual(followed.url, destination)
        XCTAssertFalse(followed.httpShouldHandleCookies)
        XCTAssertNil(followed.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(followed.value(forHTTPHeaderField: "Cookie"))
    }

    func testSharedRejectAllDelegateDoesNotFollowEvenSameOriginRedirects() async {
        let session = URLSession(configuration: IsolatedURLSession.configuration())
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://isolated.invalid/start")!
        let task = session.dataTask(with: url)
        let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil)!
        let redirected: URLRequest? = await withCheckedContinuation { continuation in
            RejectAllRedirects().urlSession(session, task: task, willPerformHTTPRedirection: response,
                                           newRequest: URLRequest(url: url.appendingPathComponent("next"))) {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertNil(redirected)
    }
}

// URLProtocol requires subclasses to restate its unchecked conformance. This
// fixture adds no shared state; each synchronous callback uses its own request.
private final class IsolatedSessionProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = ["cookie": request.value(forHTTPHeaderField: "Cookie") ?? "",
                    "authorization": request.value(forHTTPHeaderField: "Authorization") ?? "",
                    "nonce": UUID().uuidString]
        do {
            let data = try JSONEncoder().encode(body)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                           headerFields: ["Set-Cookie": "response=secret; Path=/; Secure", "Cache-Control": "max-age=3600"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
