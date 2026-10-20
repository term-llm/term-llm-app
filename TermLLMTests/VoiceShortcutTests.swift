import XCTest
@testable import TermLLM

@MainActor
final class VoiceShortcutTests: XCTestCase {
    private let server = URL(string: "https://example.com/hub/")!

    private func defaults() -> UserDefaults {
        let name = "VoiceShortcutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func settings(defaults: UserDefaults? = nil, health: String = "{\"role\":\"hub\"}",
                          nodes: String = "{\"nodes\":[{\"id\":\"jarvis\",\"name\":\"Jarvis\",\"proxy_path\":\"/hub/node/jarvis/\"}]}",
                          status: Int = 200) -> VoiceShortcutSettings {
        VoiceShortcutSettings(defaults: defaults ?? self.defaults(), cookies: EmptyCookies()) { request in
            let body = request.url!.path.hasSuffix("/healthz") ? health : nodes
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status,
                                                   httpVersion: nil, headerFields: nil)!)
        }
    }

    func testUnknownAndUnselectedHubCannotLaunch() async throws {
        let settings = settings()
        XCTAssertThrowsError(try settings.destination(for: server))
        await settings.discover(server: server)
        XCTAssertEqual(settings.mode(for: server), .hub)
        XCTAssertEqual(settings.nodes(for: server).map(\.name), ["Jarvis"])
        XCTAssertThrowsError(try settings.destination(for: server))
        settings.selectNode("missing", for: server)
        XCTAssertNil(settings.selectedNodeID(for: server))
        settings.selectNode("jarvis", for: server)
        XCTAssertEqual(try settings.destination(for: server).absoluteString,
                       "https://example.com/hub/node/jarvis/?new=1")
    }

    func testDirectPreservesQueryReplacesNewAndRemovesFragment() async throws {
        let server = URL(string: "https://example.com/ui/?theme=dark&new=0&new=2#chat")!
        let settings = settings(health: "{\"status\":\"ok\"}")
        await settings.discover(server: server)
        XCTAssertEqual(settings.mode(for: server), .direct)
        XCTAssertEqual(try settings.destination(for: server).absoluteString,
                       "https://example.com/ui/?theme=dark&new=1")
    }

    func testDirectBaseHealthSucceedsAfterRoot404OrUnrelatedResponse() async throws {
        let server = URL(string: "https://example.com/ui/?new=0#old")!
        for (rootStatus, rootBody) in [(404, "Not found"), (200, "<html>Other site</html>"),
                                       (200, "{}"), (200, "{\"status\":\"ok\"}")] {
            var paths: [String] = []
            let settings = VoiceShortcutSettings(defaults: defaults(), cookies: EmptyCookies()) { request in
                let path = request.url!.path
                paths.append(path)
                let isRoot = path == "/healthz"
                let body = isRoot ? rootBody : "{\"status\":\"ok\"}"
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: isRoot ? rootStatus : 200,
                                                       httpVersion: nil, headerFields: nil)!)
            }
            await settings.discover(server: server)
            XCTAssertEqual(paths, ["/healthz", "/ui/healthz"])
            XCTAssertNil(settings.error(for: server))
            XCTAssertEqual(settings.mode(for: server), .direct)
            XCTAssertEqual(try settings.destination(for: server).absoluteString, "https://example.com/ui/?new=1")
        }
    }

    func testUnrelatedRootHealthDoesNotValidateDirectBase() async {
        let server = URL(string: "https://example.com/ui/")!
        var paths: [String] = []
        let settings = VoiceShortcutSettings(defaults: defaults(), cookies: EmptyCookies()) { request in
            paths.append(request.url!.path)
            let isRoot = request.url!.path == "/healthz"
            return (Data((isRoot ? "{\"status\":\"ok\"}" : "Not found").utf8),
                    HTTPURLResponse(url: request.url!, statusCode: isRoot ? 200 : 404,
                                    httpVersion: nil, headerFields: nil)!)
        }
        await settings.discover(server: server)
        XCTAssertEqual(paths, ["/healthz", "/ui/healthz"])
        XCTAssertEqual(settings.mode(for: server), .unknown)
        XCTAssertNotNil(settings.error(for: server))
        XCTAssertThrowsError(try settings.destination(for: server))
    }

    func testRootDirectHealthIsNotRequestedTwice() async {
        let server = URL(string: "https://example.com/")!
        var paths: [String] = []
        let settings = VoiceShortcutSettings(defaults: defaults(), cookies: EmptyCookies()) { request in
            paths.append(request.url!.path)
            return (Data("{\"status\":\"ok\"}".utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        await settings.discover(server: server)
        XCTAssertEqual(paths, ["/healthz"])
        XCTAssertEqual(settings.mode(for: server), .direct)
    }

    func testRootTransportFailureDoesNotRepeatRequestAtBase() async {
        let server = URL(string: "https://example.com/ui/")!
        var paths: [String] = []
        let settings = VoiceShortcutSettings(defaults: defaults(), cookies: EmptyCookies()) { request in
            paths.append(request.url!.path)
            throw URLError(.notConnectedToInternet)
        }
        await settings.discover(server: server)
        XCTAssertEqual(paths, ["/healthz"])
        XCTAssertEqual(settings.mode(for: server), .unknown)
        XCTAssertNotNil(settings.error(for: server))
    }

    func testPersistenceIsCanonicalAndIsolatedByServerMountAndOrigin() async throws {
        let defaults = defaults()
        let settings = settings(defaults: defaults)
        await settings.discover(server: server)
        settings.selectNode("jarvis", for: server)
        let restored = VoiceShortcutSettings(defaults: defaults, cookies: EmptyCookies())
        let equivalent = URL(string: "https://EXAMPLE.com:443/hub#ignored")!
        XCTAssertEqual(restored.mode(for: equivalent), .hub)
        XCTAssertEqual(restored.selectedNodeID(for: equivalent), "jarvis")
        XCTAssertEqual(restored.nodes(for: equivalent).count, 1)
        XCTAssertEqual(try restored.destination(for: equivalent).absoluteString,
                       "https://example.com/hub/node/jarvis/?new=1")
        for other in ["https://example.com/other/", "https://other.example.com/hub/", "https://example.com:444/hub/"] {
            XCTAssertEqual(restored.mode(for: URL(string: other)!), .unknown)
            XCTAssertThrowsError(try restored.destination(for: URL(string: other)!))
        }
    }

    func testHubDiscoveryUsesRootHealthAndMountedNodesFromNodeURL() async throws {
        for (serverPath, basePath) in [("/node/jarvis/", ""), ("/hub/node/jarvis/", "/hub"), ("/hub/", "/hub"), ("/ui/", "/ui"), ("/hub/ui/", "/hub/ui")] {
            let server = URL(string: "https://example.com\(serverPath)")!
            var requests: [URLRequest] = []
            let settings = VoiceShortcutSettings(defaults: defaults(), cookies: EmptyCookies()) { request in
                requests.append(request)
                let json = requests.count == 1 ? "{\"role\":\"hub\"}" :
                    "[{\"id\":\"jarvis\",\"name\":\"Jarvis\",\"proxy_path\":\"\(basePath)/node/jarvis/\"}]"
                return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                                                       httpVersion: nil, headerFields: nil)!)
            }
            await settings.discover(server: server)
            XCTAssertNil(settings.error(for: server))
            XCTAssertEqual(requests.map { $0.url!.absoluteString },
                           ["https://example.com/healthz", "https://example.com\(basePath)/api/nodes?view=sidebar"])
            settings.selectNode("jarvis", for: server)
            XCTAssertEqual(try settings.destination(for: server).path, "\(basePath)/node/jarvis")
        }
    }

    func testInvalidDiscoveryNeverAssumesDirect() async {
        for health in ["<html>Sign in</html>", "[]", "null", "{}", "{\"arbitrary\":true}", "{\"role\":\"agent\"}", "{\"role\":42}"] {
            let settings = settings(health: health)
            await settings.discover(server: server)
            XCTAssertEqual(settings.mode(for: server), .unknown, health)
            XCTAssertNotNil(settings.error(for: server))
            XCTAssertThrowsError(try settings.destination(for: server))
        }
        for status in [302, 401, 500] {
            let settings = settings(health: "{\"status\":\"ok\"}", status: status)
            await settings.discover(server: server)
            XCTAssertEqual(settings.mode(for: server), .unknown)
            XCTAssertNotNil(settings.error(for: server))
        }
        let settings = VoiceShortcutSettings(defaults: defaults(), cookies: EmptyCookies()) { _ in
            throw URLError(.notConnectedToInternet)
        }
        await settings.discover(server: server)
        XCTAssertEqual(settings.mode(for: server), .unknown)
        XCTAssertThrowsError(try settings.destination(for: server))
    }

    func testMalformedNodesLeaveHubUnresolved() async {
        for nodes in ["{}", "{\"nodes\":[{}]}", "[{\"id\":\"jarvis\",\"name\":\"Jarvis\",\"proxy_path\":\"https://evil.example/node/jarvis/\"}]"] {
            let settings = settings(nodes: nodes)
            await settings.discover(server: server)
            XCTAssertEqual(settings.mode(for: server), .hub)
            XCTAssertNotNil(settings.error(for: server))
            XCTAssertThrowsError(try settings.destination(for: server))
        }
    }

    func testNodeURLRejectsOffOriginCredentialsAndMountEscapes() throws {
        for path in ["https://evil.example/hub/node/jarvis/", "//evil.example/hub/node/jarvis/",
                     "https://user:pass@example.com/hub/node/jarvis/", "http://example.com/hub/node/jarvis/",
                     "https://example.com:444/hub/node/jarvis/", "/node/jarvis/", "/hub/node/other/",
                     "/hub/node/jarvis/evil", "/hub/node/jarvis/?token=secret", "/hub/node/jarvis/#secret",
                     "/hub/node/../node/jarvis/", "/hub/node/%6aarvis/", "/hub/node/jarvis%2f/",
                     "/hub/node/jarvis\\evil/"] {
            let node = VoiceShortcutNode(id: "jarvis", name: "Jarvis", proxyPath: path)
            XCTAssertThrowsError(try VoiceShortcutSettings.nodeURL(node, server: server), path)
        }
        for path in ["/hub/node/jarvis/", "https://example.com:443/hub/node/jarvis/"] {
            XCTAssertNoThrow(try VoiceShortcutSettings.nodeURL(
                VoiceShortcutNode(id: "jarvis", name: "Jarvis", proxyPath: path), server: server))
        }
        for id in ["..", ".", "a/b", "", "a?b"] {
            XCTAssertThrowsError(try VoiceShortcutSettings.nodeURL(
                VoiceShortcutNode(id: id, name: id, proxyPath: "/hub/node/\(id)/"), server: server))
        }
    }

    func testDecodesSidebarEnvelopeAndArray() throws {
        let json = "[{\"id\":\"jarvis\",\"name\":\"Jarvis\",\"proxy_path\":\"/node/jarvis/\"}]"
        let nodes = try VoiceShortcutSettings.decodeNodes(Data(json.utf8))
        XCTAssertEqual(nodes, try VoiceShortcutSettings.decodeNodes(Data("{\"nodes\":\(json)}".utf8)))
        XCTAssertEqual(nodes.first?.proxyPath, "/node/jarvis/")
    }

    func testRemovedSelectionIsNotSilentlyReplaced() async {
        let defaults = defaults()
        let original = settings(defaults: defaults)
        await original.discover(server: server)
        original.selectNode("jarvis", for: server)
        let refreshed = settings(defaults: defaults, nodes: "[]")
        await refreshed.discover(server: server)
        XCTAssertNil(refreshed.selectedNodeID(for: server))
        XCTAssertThrowsError(try refreshed.destination(for: server))
    }

    func testCookieReuseOnlyUsesJarForEachExactEndpoint() async {
        let jar = RecordingCookies()
        var requests: [URLRequest] = []
        let settings = VoiceShortcutSettings(defaults: defaults(), cookies: jar) { request in
            requests.append(request)
            let json = request.url!.path == "/healthz" ? "{\"role\":\"hub\"}" : "[]"
            return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                                                   httpVersion: nil, headerFields: nil)!)
        }
        await settings.discover(server: server)
        XCTAssertEqual(jar.urls.map(\.path), ["/healthz", "/hub/api/nodes"])
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Cookie"), "session=secret")
    }

    func testRedirectDelegateRejectsEvenSameOriginRedirect() {
        let blocker = VoiceShortcutRedirectBlocker()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: server)
        let response = HTTPURLResponse(url: server, statusCode: 302, httpVersion: nil, headerFields: nil)!
        for destination in [server, URL(string: "https://evil.example/")!] {
            var called = false
            blocker.urlSession(session, task: task, willPerformHTTPRedirection: response,
                               newRequest: URLRequest(url: destination)) { request in
                called = true
                XCTAssertNil(request)
            }
            XCTAssertTrue(called)
        }
    }

    func testTransientFailurePreservesSavedHubSelectionAndDirectMode() async throws {
        for hub in [true, false] {
            let defaults = defaults()
            let original = settings(defaults: defaults, health: hub ? "{\"role\":\"hub\"}" : "{\"status\":\"ok\"}")
            await original.discover(server: server)
            if hub { original.selectNode("jarvis", for: server) }
            let destination = try original.destination(for: server)
            let offline = VoiceShortcutSettings(defaults: defaults, cookies: EmptyCookies()) { _ in
                throw URLError(.notConnectedToInternet)
            }
            await offline.discover(server: server)
            XCTAssertNotNil(offline.error(for: server))
            XCTAssertEqual(offline.mode(for: server), hub ? .hub : .direct)
            XCTAssertEqual(try offline.destination(for: server), destination)
            if hub {
                XCTAssertEqual(offline.selectedNodeID(for: server), "jarvis")
                XCTAssertEqual(offline.nodes(for: server).count, 1)
                let invalidRefresh = settings(defaults: defaults, nodes: "{}")
                await invalidRefresh.discover(server: server)
                XCTAssertNotNil(invalidRefresh.error(for: server))
                XCTAssertEqual(try invalidRefresh.destination(for: server), destination)
            }
            let restored = VoiceShortcutSettings(defaults: defaults, cookies: EmptyCookies())
            XCTAssertEqual(try restored.destination(for: server), destination)
        }
    }

    func testLaunchRequestsCoalesceUntilFinished() {
        let center = VoiceLaunchCenter()
        XCTAssertNil(center.request)
        center.requestLaunch()
        let first = center.request
        XCTAssertNotNil(first)
        center.requestLaunch()
        XCTAssertEqual(center.request, first)
        center.finish()
        XCTAssertNil(center.request)
        center.requestLaunch()
        XCTAssertNotEqual(center.request, first)
    }

    func testIntentQueuesTheSharedLaunchMechanism() async throws {
        let center = VoiceLaunchCenter.shared
        center.finish()
        defer { center.finish() }
        _ = try await StartLiveConversationIntent().perform()
        XCTAssertNotNil(center.request)
        let request = center.request
        _ = try await StartLiveConversationIntent().perform()
        XCTAssertEqual(center.request, request)
        XCTAssertTrue(StartLiveConversationIntent.openAppWhenRun)
    }
}

@MainActor
private struct EmptyCookies: ListenCookieJar {
    func cookies(for url: URL) async -> [HTTPCookie] { [] }
}

@MainActor
private final class RecordingCookies: ListenCookieJar {
    var urls: [URL] = []
    func cookies(for url: URL) async -> [HTTPCookie] {
        urls.append(url)
        guard url.path.hasPrefix("/hub/") else { return [] }
        return [HTTPCookie(properties: [.domain: "example.com", .path: "/hub/", .name: "session", .value: "secret"])!]
    }
}
