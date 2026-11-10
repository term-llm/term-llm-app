import Foundation
import os
import XCTest
@testable import TermLLMMacKit

final class IsolatedSessionConfigurationTests: XCTestCase {
    override func tearDown() {
        ProbeURLProtocol.reset()
        super.tearDown()
    }

    private func injectedConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = .shared
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        configuration.urlCredentialStorage = URLCredentialStorage()
        configuration.urlCache = URLCache(memoryCapacity: 1024, diskCapacity: 0)
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 23
        configuration.timeoutIntervalForResource = 47
        configuration.protocolClasses = [ProbeURLProtocol.self]
        return configuration
    }

    private func assertIsolated(_ configuration: URLSessionConfiguration,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(configuration.httpCookieStorage, file: file, line: line)
        XCTAssertFalse(configuration.httpShouldSetCookies, file: file, line: line)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never, file: file, line: line)
        XCTAssertNil(configuration.urlCredentialStorage, file: file, line: line)
        XCTAssertNil(configuration.urlCache, file: file, line: line)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData, file: file, line: line)
        XCTAssertNil(configuration.identifier, file: file, line: line)
    }

    func testFactoryDefaultsAndCopiedConfigurationHaveNoAmbientState() {
        assertIsolated(IsolatedSessionConfiguration.make())
        let original = injectedConfiguration()
        let isolated = IsolatedSessionConfiguration.make(copying: original)
        XCTAssertFalse(isolated === original)
        assertIsolated(isolated)
        XCTAssertEqual(isolated.timeoutIntervalForRequest, 23)
        XCTAssertEqual(isolated.timeoutIntervalForResource, 47)
        XCTAssertTrue(isolated.protocolClasses?.first == ProbeURLProtocol.self)
        // Only inspect configuration references; never read/write a real cookie jar.
        XCTAssertNotNil(original.httpCookieStorage)
        XCTAssertTrue(original.httpShouldSetCookies)
        XCTAssertEqual(original.httpCookieAcceptPolicy, .always)
        XCTAssertNotNil(original.urlCredentialStorage)
        XCTAssertNotNil(original.urlCache)
        XCTAssertEqual(original.requestCachePolicy, .returnCacheDataElseLoad)
    }

    func testAllTransportsUseIsolationAndPreserveInjectedTimeoutsAndProtocols() {
        let original = injectedConfiguration()
        let github = GitHubReleaseTransport(configuration: original)
        let checker = HTTPServiceVersionChecker(configuration: original)
        let probe = LocalSessionProbe.makeSession(configuration: original)
        // Initialization must snapshot the caller's configuration, not retain it.
        original.timeoutIntervalForRequest = 99
        original.protocolClasses = []
        let sessions = [github.makeSession(), checker.makeSession(), probe]
        defer { sessions.forEach { $0.invalidateAndCancel() } }
        for session in sessions {
            let configuration = session.configuration
            assertIsolated(configuration)
            XCTAssertEqual(configuration.timeoutIntervalForRequest, 23)
            XCTAssertEqual(configuration.timeoutIntervalForResource, 47)
            XCTAssertTrue(configuration.protocolClasses?.first == ProbeURLProtocol.self)
        }
        XCTAssertTrue(original.httpShouldSetCookies)
        XCTAssertNotNil(original.urlCredentialStorage)
    }

    func testTransportDefaultTimeoutsArePreserved() {
        let github = GitHubReleaseTransport().makeSession()
        let probe = LocalSessionProbe.makeSession()
        let checker = HTTPServiceVersionChecker().makeSession()
        defer { [github, probe, checker].forEach { $0.invalidateAndCancel() } }
        for session in [github, probe, checker] { assertIsolated(session.configuration) }
        XCTAssertEqual(github.configuration.timeoutIntervalForRequest, 30)
        XCTAssertEqual(github.configuration.timeoutIntervalForResource, 180)
        XCTAssertEqual(probe.configuration.timeoutIntervalForRequest, 6)
        XCTAssertEqual(probe.configuration.timeoutIntervalForResource, 10)
        XCTAssertEqual(checker.configuration.timeoutIntervalForRequest, URLSessionConfiguration.ephemeral.timeoutIntervalForRequest)
    }

    func testGitHubFetchUsesInjectedProtocolWithoutAmbientAuthentication() throws {
        let url = URL(string: "https://github.com/samsaffron/term-llm/releases/latest")!
        ProbeURLProtocol.handler = { request in
            XCTAssertEqual(request.url, url)
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "term-llm-mac/test")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("fixture".utf8))
        }
        let transport = GitHubReleaseTransport(appVersion: "test", configuration: injectedConfiguration())
        let response = try transport.fetch(url)
        XCTAssertEqual(response.data, Data("fixture".utf8))
        XCTAssertEqual(response.url, url)
        XCTAssertEqual(ProbeURLProtocol.requests.count, 1)
    }

    func testGitHubHTTPSCDNRedirectPolicyIsDistinctFromLoopbackRejection() throws {
        let github = GitHubReleaseTransport().makeSession()
        let probe = LocalSessionProbe.makeSession()
        let checker = HTTPServiceVersionChecker().makeSession()
        defer { [github, probe, checker].forEach { $0.invalidateAndCancel() } }
        // Invoke delegates directly: URLProtocol stubs returning a 302 do not
        // exercise Foundation's actual redirect callback. No tasks are resumed.
        let origin = URL(string: "https://github.com/samsaffron/term-llm/releases/latest")!
        let cdn = URLRequest(url: URL(string: "https://release-assets.githubusercontent.com/asset")!)
        XCTAssertEqual(try redirect(cdn, from: origin, session: github)?.url, cdn.url)
        XCTAssertNil(try redirect(URLRequest(url: URL(string: "http://example.invalid/asset")!), from: origin, session: github))
        let loopback = URL(string: "http://127.0.0.1:8765/healthz")!
        for session in [probe, checker] {
            XCTAssertTrue(session.delegate is RejectRedirects)
            for destination in [loopback, URL(string: "http://127.0.0.1:8765/other")!, cdn.url!] {
                XCTAssertNil(try redirect(URLRequest(url: destination), from: loopback, session: session))
            }
        }
    }

    private func redirect(_ request: URLRequest, from origin: URL, session: URLSession) throws -> URLRequest? {
        let delegate = try XCTUnwrap(session.delegate as? URLSessionTaskDelegate)
        let task = session.dataTask(with: origin)
        defer { task.cancel() }
        let answer = OSAllocatedUnfairLock<(called: Bool, request: URLRequest?)>(initialState: (false, nil))
        delegate.urlSession?(session, task: task,
                             willPerformHTTPRedirection: HTTPURLResponse(url: origin, statusCode: 302, httpVersion: nil, headerFields: nil)!,
                             newRequest: request) { request in
            answer.withLock { $0 = (true, request) }
        }
        let result = answer.withLock { $0 }
        XCTAssertTrue(result.called)
        return result.request
    }
}
