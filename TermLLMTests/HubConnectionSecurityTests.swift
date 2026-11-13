import JavaScriptCore
import WebKit
import XCTest
@testable import TermLLM

@MainActor
final class HubConnectionSecurityTests: XCTestCase {
    private func connection(_ mount: String, id: UUID = UUID()) -> HubConnection {
        HubConnection(id: id, name: mount, kind: .directNode, url: URL(string: "https://example.com\(mount)")!)
    }
    private func cookie(_ source: HubConnection, value: String) throws -> HTTPCookie {
        try XCTUnwrap(HTTPCookie(properties: [.name: "term_llm_web_session", .value: value,
                                            .domain: "example.com", .path: source.mountPath, .secure: "TRUE"]))
    }
    func testSiblingAndAncestorConnectionsHaveSeparateWKCookieJars() async throws {
        let root = connection("/"), nested = connection("/a/b/")
        let a = HubConnectionSecurity(connection: root, bearerStorage: HubMemoryBearerStorage(), dataStore: .nonPersistent())
        let b = HubConnectionSecurity(connection: nested, bearerStorage: HubMemoryBearerStorage(), dataStore: .nonPersistent())
        await a.saveCookies([try cookie(root, value: "root-session")], epoch: a.epoch)
        await b.saveCookies([try cookie(nested, value: "nested-session")], epoch: b.epoch)
        let first = await a.cookies(), second = await b.cookies()
        XCTAssertEqual(first.map(\.value), ["root-session"])
        XCTAssertEqual(second.map(\.value), ["nested-session"])
        XCTAssertFalse(a.dataStore === b.dataStore)
        a.dispose(removeCredentials: true)
        let remaining = await b.cookies()
        XCTAssertEqual(remaining.map(\.value), ["nested-session"])
        b.dispose(removeCredentials: true)
    }
    func testStaleCookieSinkCannotWriteAfterConnectionRemoval() async throws {
        let source = connection("/old/")
        let security = HubConnectionSecurity(connection: source, bearerStorage: HubMemoryBearerStorage(), dataStore: .nonPersistent())
        let epoch = security.epoch
        security.dispose(removeCredentials: true)
        await security.saveCookies([try cookie(source, value: "late")], epoch: epoch)
        let cookies = await security.cookies()
        XCTAssertTrue(cookies.isEmpty)
    }
    /// After relaunch a UUID store reports no cookies until its persisted jar
    /// is loaded; an early empty read caused a 401 that erased a valid session.
    func testPersistedJarLoadsBeforeAnyCookieReadOrWrite() async throws {
        let source = connection("/relaunch/")
        final class Events { var log: [String] = [] }
        let events = Events()
        let gate = CookieWriteGate()
        let security = HubConnectionSecurity(connection: source, bearerStorage: HubMemoryBearerStorage(),
                                             dataStore: .nonPersistent(),
                                             cookieWriter: { _ in events.log.append("write") },
                                             storeLoader: { _ in events.log.append("load"); await gate.wait() })
        let read = Task { @MainActor in
            let cookies = await security.cookies()
            events.log.append("read")
            return cookies
        }
        while events.log.isEmpty { await Task.yield() }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(events.log, ["load"], "cookies must not be read before the persisted jar loads")
        await gate.release()
        _ = await read.value
        XCTAssertEqual(events.log, ["load", "read"])
        await security.saveCookies([try cookie(source, value: "session")], epoch: security.epoch)
        XCTAssertEqual(events.log, ["load", "read", "load", "write"])
    }
    func testCredentialIdentityIsUUIDScopedAndTrustRealmChangeStartsEmpty() throws {
        let storage = HubMemoryBearerStorage()
        let oldConnection = connection("/old/")
        let newConnection = connection("/new/")
        let old = HubConnectionSecurity(connection: oldConnection, bearerStorage: storage, dataStore: .nonPersistent())
        try old.setBearer("old-secret")
        let new = HubConnectionSecurity(connection: newConnection, bearerStorage: storage, dataStore: .nonPersistent())
        XCTAssertNil(new.bearer)
        XCTAssertNil(try storage.read(id: newConnection.id))
        old.dispose(removeCredentials: true)
        XCTAssertNil(try storage.read(id: oldConnection.id))
        XCTAssertNil(new.bearer)
        XCTAssertTrue(new.active)
        new.dispose(removeCredentials: true)
    }
    func testMainFrameBearerHandoffSeedsActualFrontendStorageBeforeModules() throws {
        let server = URL(string: "https://example.com/a/")!
        let token = "secret+ /'\"\\value"
        let script = HubConnectionSecurity.directBearerScript(token: token, server: server)
        for (origin, path, allowed) in [("https://example.com", "/a/", true), ("https://example.com", "/a/chat/7", true),
                                        ("https://evil.example", "/a/", false), ("https://example.com:444", "/a/", false),
                                        ("http://example.com", "/a/", false), ("https://example.com", "/ab/chat/7", false),
                                        ("https://example.com", "/", false)] {
            let context = try XCTUnwrap(JSContext())
            let config = try JSONSerialization.data(withJSONObject: ["origin": origin, "pathname": path, "protocol": origin.hasPrefix("https:") ? "https:" : "http:"])
            context.evaluateScript("var location = \(String(decoding: config, as: UTF8.self)); var document = {cookie: ''}; var values = {}; var localStorage = {setItem: (k,v) => values[k] = v};")
            context.evaluateScript(script)
            XCTAssertNil(context.exception, context.exception?.toString() ?? "")
            let stored = context.evaluateScript("values.term_llm_token")
            if allowed {
                XCTAssertEqual(stored?.toString(), token)
                let writtenCookie = context.evaluateScript("document.cookie")?.toString() ?? ""
                XCTAssertTrue(writtenCookie.contains("path=/a/"))
            } else {
                XCTAssertTrue(stored?.isUndefined == true)
                XCTAssertEqual(context.evaluateScript("document.cookie")?.toString(), "")
            }
        }
        // Script is passed to WKUserScript, never the address/navigation.
        XCTAssertFalse(server.absoluteString.contains(token))
    }
    func testNativePasskeyCookieSinkRequiresExactOriginMountAndCurrentEpoch() async throws {
        let sourceConnection = connection("/direct/")
        let source = HubSourceWorkspace(connection: sourceConnection, bearerStorage: HubMemoryBearerStorage(), dataStore: .nonPersistent())
        defer { source.dispose(removeCredentials: true) }
        let sink = source.nativeCookieSink(epoch: source.authEpoch)
        for (host, path, name) in [("example.com", "/", "term_llm_web_session"),
                                   ("example.com", "/direct-other/", "term_llm_web_session"),
                                   ("evil.example", "/direct/", "term_llm_web_session"),
                                   ("example.com", "/direct/", "term_llm_hub_session")] {
            let invalid = try XCTUnwrap(HTTPCookie(properties: [.name: name, .value: "invalid", .domain: host, .path: path, .secure: "TRUE"]))
            do { try await sink([invalid]); XCTFail("Invalid cookie accepted") } catch {}
        }
        try await sink([try cookie(sourceConnection, value: "valid-passkey")])
        let imported = await source.security?.cookies()
        XCTAssertEqual(imported?.map(\.value), ["valid-passkey"])
        source.revokeAuthorization()
        do { try await sink([try cookie(sourceConnection, value: "stale")]); XCTFail("Stale native callback accepted") } catch {}
    }

    func testMediaOperationsRemainBoundToOriginatingUUIDAcrossSelectionChanges() async throws {
        let defaults = UserDefaults(suiteName: "media-scope-\(UUID())")!
        let catalog = HubConnectionStore(defaults: defaults)
        let root = try catalog.save(name: "Root", kind: .directNode, address: "https://example.com/")
        let nested = try catalog.save(name: "Nested", kind: .directNode, address: "https://example.com/nested/")
        let a = HubConnectionSecurity(connection: root, bearerStorage: HubMemoryBearerStorage(), dataStore: .nonPersistent())
        let b = HubConnectionSecurity(connection: nested, bearerStorage: HubMemoryBearerStorage(), dataStore: .nonPersistent())
        let registry = HubCookieScopeRegistry(defaults: defaults)
        registry.register(a, kind: .directNode); registry.register(b, kind: .directNode)
        defer { a.dispose(removeCredentials: true); b.dispose(removeCredentials: true) }
        await a.saveCookies([try cookie(root, value: "root")], epoch: a.epoch)
        await b.saveCookies([try cookie(nested, value: "nested")], epoch: b.epoch)
        let jar = WebKitCookieJar(registry: registry)
        let url = URL(string: "https://example.com/nested/file.mp3")!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("media-scope-\(UUID())")
        let library = ListenStore(fileURL: directory.appendingPathComponent("library.json"))
        let item = try XCTUnwrap(library.add([ListenDraft(url: url, sourceID: nested.id)], placement: .end).first)
        let media = FakeMediaServer()
        media.serve(url, .init(body: Data([1, 2, 3])))
        let downloader = ListenDownloader(store: library, cookies: jar, server: { ListenServer(base: root.url, sourceID: root.id) }, directory: directory, fetching: media)
        catalog.select(root.id); registry.selectedID = root.id
        let stream = await downloader.request(for: item)
        XCTAssertEqual(stream.value(forHTTPHeaderField: "Cookie"), "term_llm_web_session=nested", "Selection must not rebind an old media item")
        XCTAssertNil(registry.unambiguousSourceID(for: url), "Root/child URLs without operation ownership are ambiguous")
        let unbound = await jar.cookies(for: url)
        XCTAssertTrue(unbound.isEmpty)
        downloader.download(item.id)
        for _ in 0..<50 where library.item(item.id)?.download != .downloaded {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(library.item(item.id)?.download, .downloaded)
        XCTAssertEqual(media.requests.map { $0.value(forHTTPHeaderField: "Cookie") }, ["term_llm_web_session=nested"],
                       "Download must use the saved item owner, not the newly selected root")
        downloader.deleteFile(item.id)
        b.nextEpoch() // revoke/reauth starts before asynchronous WebKit clear finishes
        let revoked = await downloader.request(for: item)
        XCTAssertNil(revoked.value(forHTTPHeaderField: "Cookie"), "Revocation blocks media reads immediately, not only after WebKit deletion")
        catalog.remove(nested.id)
        let removed = await downloader.request(for: item)
        XCTAssertNil(removed.value(forHTTPHeaderField: "Cookie"), "Removed UUID must never fall back to root credentials")
        try? FileManager.default.removeItem(at: directory)
    }

    func testMissingCorruptDuplicateOrUnmatchedCatalogNeverBorrowsAmbientCookies() async throws {
        let defaults = UserDefaults(suiteName: "catalog-scope-\(UUID())")!
        let registry = HubCookieScopeRegistry(defaults: defaults)
        let ambient = WKWebsiteDataStore.default()
        let cookie = try cookie(connection("/"), value: "ambient-must-not-leak")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            ambient.httpCookieStore.setCookie(cookie) { continuation.resume() }
        }
        defer { ambient.httpCookieStore.delete(cookie) {} }
        let url = URL(string: "https://example.com/media.mp3")!
        for raw: Any? in [nil, "wrong type", Data("bad json".utf8)] {
            defaults.set(raw, forKey: HubConnectionStore.storageKey)
            XCTAssertNil(registry.unambiguousSourceID(for: url))
            XCTAssertFalse(registry.dataStore(for: url) === ambient)
            let cookies = await registry.cookies(for: url, sourceID: UUID())
            XCTAssertTrue(cookies.isEmpty)
        }
        let catalog = HubConnectionStore(defaults: UserDefaults(suiteName: "valid-scope-\(UUID())")!)
        let source = try catalog.save(name: "Other", kind: .hub, address: "https://other.example/")
        let duplicate = HubConnectionStore.Document(connections: [source, source], selectedID: source.id)
        defaults.set(try JSONEncoder().encode(duplicate), forKey: HubConnectionStore.storageKey)
        XCTAssertNil(registry.connection(source.id))
        defaults.set(try JSONEncoder().encode(HubConnectionStore.Document(connections: [source], selectedID: source.id)), forKey: HubConnectionStore.storageKey)
        let unmatched = await registry.cookies(for: url, sourceID: source.id)
        XCTAssertTrue(unmatched.isEmpty)
    }

    func testCookieWriteCompletionCannotOvertakeNewAuthentication() async throws {
        let source = connection("/serial/")
        let gate = CookieWriteGate()
        let started = expectation(description: "old cookie submitted")
        var writes: [String] = []
        let security = HubConnectionSecurity(connection: source, bearerStorage: HubMemoryBearerStorage(), dataStore: .nonPersistent(), cookieWriter: { cookie in
            if cookie.value == "old" { started.fulfill(); await gate.wait() }
            writes.append(cookie.value)
        })
        let oldEpoch = security.epoch
        let old = Task { await security.saveCookies([try self.cookie(source, value: "old")], epoch: oldEpoch) }
        await fulfillment(of: [started], timeout: 2)
        security.nextEpoch()
        let newEpoch = security.epoch
        let new = Task { await security.saveCookies([try self.cookie(source, value: "new")], epoch: newEpoch) }
        await Task.yield()
        XCTAssertTrue(writes.isEmpty)
        await gate.release()
        let oldAccepted = try await old.value
        let newAccepted = try await new.value
        XCTAssertFalse(oldAccepted)
        XCTAssertTrue(newAccepted)
        XCTAssertEqual(writes, ["old", "new"], "A submitted stale write completes before, never after, the new cookie")
        security.dispose(removeCredentials: true)
    }

    func testDirectAlreadyAdmittedCallbackCannotRevokeNewSourceEpoch() async throws {
        let source = HubSourceWorkspace(connection: connection("/direct/"), bearerStorage: HubMemoryBearerStorage(), dataStore: .nonPersistent())
        defer { source.dispose(removeCredentials: true) }
        let admitted = source.directClient?.onUnauthorized
        let old = source.authEpoch
        let prepared = await source.prepareAuthentication()
        let current = try XCTUnwrap(prepared)
        XCTAssertNotEqual(old, current)
        let identity = source.browserIdentity
        let nativeEpoch = source.store.authEpoch
        await admitted?()
        XCTAssertEqual(source.store.authEpoch, nativeEpoch)
        XCTAssertEqual(source.browserIdentity, identity, "Admitted old callback cannot revoke the pending new identity")
        XCTAssertTrue(source.browserRevoked, "Explicit reauthentication keeps old chat closed until success")
        let restoredOld = await source.authenticationSucceeded(epoch: old)
        XCTAssertFalse(restoredOld, "Old detail/sign-in success cannot restore a newer source identity")
    }
}

/// Scoped to the app-managed This Mac handoff; ordinary sign-in remains an
/// identity reset. These run in both the iOS and Mac unit-test targets.
@MainActor
final class ManagedLocalAuthenticationTests: XCTestCase {
    private func connection(managed: Bool = true) -> HubConnection {
        HubConnection(id: UUID(), name: "This Mac", kind: .directNode,
                      url: URL(string: "http://127.0.0.1:8767/ui/")!, managedLocalService: managed)
    }

    func testSameCredentialRetainsIdentityAndPreparesBrowserWithoutStart() async throws {
        let connection = connection()
        let storage = HubMemoryBearerStorage()
        try storage.write("saved-token", id: connection.id)
        var purges = 0
        let requests = HubTestBox<[URLRequest]>([])
        let source = HubSourceWorkspace(connection: connection, bearerStorage: storage, dataStore: .nonPersistent(),
                                        transport: ManagedLocalAuthTransport { request in
            requests.update { $0.append(request) }
            return managedLocalAuthResponse(request)
        }, dataPurger: { purges += 1 })
        defer { source.dispose(removeCredentials: false) }
        let identity = source.browserIdentity, epoch = source.authEpoch
        let security = try XCTUnwrap(source.security)
        let securityEpoch = security.epoch
        XCTAssertFalse(source.browserReady, "The handoff must not depend on start()'s task winning a race")
        source.authenticationError = "An earlier attempt failed"

        let first = await source.authenticateManagedLocalService("saved-token")
        let second = await source.authenticateManagedLocalService("saved-token")

        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertTrue(source.browserReady)
        XCTAssertFalse(source.browserRevoked)
        XCTAssertNil(source.authenticationError)
        XCTAssertEqual(source.browserIdentity, identity)
        XCTAssertEqual(source.authEpoch, epoch)
        XCTAssertEqual(security.epoch, securityEpoch)
        XCTAssertEqual(purges, 0)
        XCTAssertEqual(try storage.read(id: connection.id), "saved-token")
        let cookies = await security.cookies()
        XCTAssertTrue(cookies.contains { $0.name == "term_llm_token" && $0.value == "saved-token" && $0.path == "/ui/" })
        XCTAssertEqual(requests.value.count, 2, "Every handoff freshly validates the bearer")
        for request in requests.value {
            XCTAssertEqual(request.url?.path, "/ui/healthz")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer saved-token")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertFalse(request.httpShouldHandleCookies)
            XCTAssertNil(request.url?.query)
        }
    }

    func testReconstructedWorkspaceRetainsRealWebKitMCPTrueAndFalsePreferences() async throws {
        for defaultEnabled in [true, false] {
            let connection = connection()
            let storage = HubMemoryBearerStorage()
            try storage.write("saved-token", id: connection.id)
            let dataStore = WKWebsiteDataStore.nonPersistent()
            let unavailable = HubTestBox(false)
            var purges = 0
            func makeSource() -> HubSourceWorkspace {
                HubSourceWorkspace(connection: connection, bearerStorage: storage, dataStore: dataStore,
                                   transport: ManagedLocalAuthTransport { request in
                    if unavailable.value { return jsonResponse("{}", url: request.url!, status: 503) }
                    return managedLocalAuthResponse(request)
                }, dataPurger: {
                    purges += 1
                    await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
                })
            }
            let previous = makeSource()
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = dataStore
            let webView = WKWebView(frame: .zero, configuration: configuration)
            let navigation = ManagedLocalNavigationWaiter()
            webView.navigationDelegate = navigation
            defer {
                webView.stopLoading()
                webView.navigationDelegate = nil
            }
            webView.loadHTMLString("<!doctype html><body>Local MCP preference fixture</body>", baseURL: connection.url)
            try await navigation.wait()
            // Match the frontend: one boolean default and serialized Map entries
            // for per-session choices, including an explicit false override.
            _ = try await webView.callAsyncJavaScript("""
                localStorage.setItem('term_llm_webmcp_default', JSON.stringify(defaultEnabled));
                localStorage.setItem('term_llm_webmcp_sessions', JSON.stringify([['on', true], ['off', false]]));
                window.retainedDocument = 'original';
                """, arguments: ["defaultEnabled": defaultEnabled], contentWorld: .page)
            previous.dispose(removeCredentials: false)
            // Reconstruct the native workspace with the same credential and jar,
            // as on launch. This is not a process/disk-persistence test.
            let source = makeSource()
            defer { source.dispose(removeCredentials: true) }
            let identity = source.browserIdentity
            let accepted = await source.authenticateManagedLocalService("saved-token")
            XCTAssertTrue(accepted)
            XCTAssertEqual(source.browserIdentity, identity)
            XCTAssertEqual(purges, 0)
            unavailable.set(true)
            let offline = await source.authenticateManagedLocalService("saved-token")
            XCTAssertFalse(offline)
            XCTAssertEqual(purges, 0, "A transient 503 must not clear actual WebKit storage")
            XCTAssertEqual(source.browserIdentity, identity)
            XCTAssertTrue(source.browserReady)
            XCTAssertFalse(source.browserRevoked)
            XCTAssertEqual(try storage.read(id: connection.id), "saved-token")
            let actual = try await webView.callAsyncJavaScript("""
                const entries = JSON.parse(localStorage.getItem('term_llm_webmcp_sessions'));
                const sessions = new Map(entries);
                return {
                    defaultEnabled: JSON.parse(localStorage.getItem('term_llm_webmcp_default')),
                    entries: JSON.stringify(entries),
                    sessionOn: sessions.get('on'),
                    sessionOff: sessions.get('off'),
                    document: window.retainedDocument
                };
                """, contentWorld: .page) as? [String: Any]
            let result = try XCTUnwrap(actual)
            XCTAssertEqual(result["defaultEnabled"] as? Bool, defaultEnabled)
            XCTAssertEqual(result["entries"] as? String, #"[["on",true],["off",false]]"#)
            XCTAssertEqual(result["sessionOn"] as? Bool, true)
            XCTAssertEqual(result["sessionOff"] as? Bool, false)
            XCTAssertEqual(result["document"] as? String, "original")
            unavailable.set(false)
            let retry = await source.authenticateManagedLocalService("saved-token")
            XCTAssertTrue(retry)
            XCTAssertNil(source.authenticationError)
            XCTAssertEqual(source.browserIdentity, identity)

            let rotated = await source.authenticateManagedLocalService("rotated-token")
            XCTAssertTrue(rotated)
            XCTAssertEqual(purges, 1, "A token rotation remains a full trust-identity reset")
            XCTAssertNotEqual(source.browserIdentity, identity)
            let cleared = try await webView.callAsyncJavaScript("""
                return localStorage.getItem('term_llm_webmcp_default') === null &&
                    localStorage.getItem('term_llm_webmcp_sessions') === null;
                """, contentWorld: .page) as? Bool
            XCTAssertEqual(cleared, true, "Website preferences must not cross a credential change")
        }
    }

    func testChangedMissingRevokedUnauthorizedAndNonmanagedIdentitiesStillReset() async throws {
        for scenario in ["changed", "missing", "revoked", "unauthorized", "nonmanaged"] {
            let connection = connection(managed: scenario != "nonmanaged")
            let storage = HubMemoryBearerStorage()
            if scenario != "missing" { try storage.write(scenario == "changed" ? "old-token" : "token", id: connection.id) }
            var purges = 0
            let source = HubSourceWorkspace(connection: connection, bearerStorage: storage, dataStore: .nonPersistent(),
                                            transport: ManagedLocalAuthTransport(handler: managedLocalAuthResponse),
                                            dataPurger: { purges += 1 })
            if scenario == "revoked" { source.revokeAuthorization() }
            if scenario == "unauthorized" { source.store.purgeOnUnauthorized() }
            let identity = source.browserIdentity, epoch = source.authEpoch

            let accepted = await source.authenticateManagedLocalService("token")

            XCTAssertTrue(accepted, scenario)
            XCTAssertGreaterThan(purges, 0, scenario)
            XCTAssertNotEqual(source.browserIdentity, identity, scenario)
            XCTAssertGreaterThan(source.authEpoch, epoch, scenario)
            XCTAssertEqual(source.security?.bearer, "token", scenario)
            XCTAssertTrue(source.browserReady, scenario)
            XCTAssertFalse(source.browserRevoked, scenario)
            source.dispose(removeCredentials: false)
        }
    }

    func testExplicitSameCredentialSignInStillPurges() async throws {
        let connection = connection()
        let storage = HubMemoryBearerStorage()
        try storage.write("token", id: connection.id)
        var purges = 0
        let source = HubSourceWorkspace(connection: connection, bearerStorage: storage, dataStore: .nonPersistent(),
                                        transport: ManagedLocalAuthTransport(handler: managedLocalAuthResponse),
                                        dataPurger: { purges += 1 })
        defer { source.dispose(removeCredentials: false) }
        let identity = source.browserIdentity
        let accepted = await source.signInWithBearer("token")
        XCTAssertTrue(accepted)
        XCTAssertEqual(purges, 1)
        XCTAssertNotEqual(source.browserIdentity, identity)
    }

    func testTransientSameCredentialFailuresPreserveIdentityAndReadinessThenRetry() async throws {
        for initiallyReady in [true, false] {
            for failure in ["timeout", "connection-refused", "503"] {
                let connection = connection()
                let storage = HubMemoryBearerStorage()
                try storage.write("token", id: connection.id)
                let failing = HubTestBox(false)
                var purges = 0
                let source = HubSourceWorkspace(connection: connection, bearerStorage: storage, dataStore: .nonPersistent(),
                                                transport: ManagedLocalAuthTransport { request in
                    if failing.value {
                        switch failure {
                        case "timeout": throw URLError(.timedOut)
                        case "connection-refused": throw URLError(.cannotConnectToHost)
                        default: return jsonResponse("{}", url: request.url!, status: 503)
                        }
                    }
                    return managedLocalAuthResponse(request)
                }, dataPurger: { purges += 1 })
                defer { source.dispose(removeCredentials: false) }
                if initiallyReady {
                    let ready = await source.authenticateManagedLocalService("token")
                    XCTAssertTrue(ready)
                }
                let security = try XCTUnwrap(source.security)
                let identity = source.browserIdentity, epoch = source.authEpoch, securityEpoch = security.epoch
                failing.set(true)

                let accepted = await source.authenticateManagedLocalService("token")

                XCTAssertFalse(accepted, failure)
                XCTAssertNotNil(source.authenticationError, failure)
                XCTAssertEqual(source.browserReady, initiallyReady, failure)
                XCTAssertFalse(source.browserRevoked, failure)
                XCTAssertFalse(source.store.unauthorized, failure)
                XCTAssertEqual(source.browserIdentity, identity, failure)
                XCTAssertEqual(source.authEpoch, epoch, failure)
                XCTAssertEqual(security.epoch, securityEpoch, failure)
                XCTAssertEqual(security.bearer, "token", failure)
                XCTAssertEqual(try storage.read(id: connection.id), "token", failure)
                XCTAssertEqual(purges, 0, failure)

                failing.set(false)
                let retry = await source.authenticateManagedLocalService("token")
                XCTAssertTrue(retry, failure)
                XCTAssertNil(source.authenticationError, failure)
                XCTAssertTrue(source.browserReady, failure)
                XCTAssertEqual(source.browserIdentity, identity, failure)
                XCTAssertEqual(source.authEpoch, epoch, failure)
                XCTAssertEqual(purges, 0, failure)
            }
        }
    }

    func testCancellationErrorsDoNotRevokeSameCredentialIdentity() async throws {
        for initiallyReady in [true, false] {
            for urlCancellation in [true, false] {
                let connection = connection()
                let storage = HubMemoryBearerStorage()
                try storage.write("token", id: connection.id)
                let cancelling = HubTestBox(false)
                var purges = 0
                let source = HubSourceWorkspace(connection: connection, bearerStorage: storage, dataStore: .nonPersistent(),
                                                transport: ManagedLocalAuthTransport { request in
                    if cancelling.value {
                        if urlCancellation { throw URLError(.cancelled) }
                        throw CancellationError()
                    }
                    return managedLocalAuthResponse(request)
                }, dataPurger: { purges += 1 })
                defer { source.dispose(removeCredentials: false) }
                if initiallyReady {
                    let ready = await source.authenticateManagedLocalService("token")
                    XCTAssertTrue(ready)
                }
                let identity = source.browserIdentity, epoch = source.authEpoch
                cancelling.set(true)
                let accepted = await source.authenticateManagedLocalService("token")
                XCTAssertFalse(accepted)
                XCTAssertNil(source.authenticationError)
                XCTAssertEqual(source.browserReady, initiallyReady)
                XCTAssertFalse(source.browserRevoked)
                XCTAssertFalse(source.store.unauthorized)
                XCTAssertEqual(source.browserIdentity, identity)
                XCTAssertEqual(source.authEpoch, epoch)
                XCTAssertEqual(try storage.read(id: connection.id), "token")
                XCTAssertEqual(purges, 0)
            }
        }
    }

    func testFailedSameCredentialValidationRevokesInsteadOfReusingBrowser() async throws {
        for initiallyReady in [true, false] {
            for (status, body) in [(401, "{}"), (403, "{}"), (200, #"{"status":"ok"}"#)] {
                let connection = connection()
                let storage = HubMemoryBearerStorage()
                try storage.write("token", id: connection.id)
                let failing = HubTestBox(false)
                let purged = expectation(description: "rejected identity website data cleared")
                let source = HubSourceWorkspace(connection: connection, bearerStorage: storage, dataStore: .nonPersistent(),
                                                transport: ManagedLocalAuthTransport { request in
                    if failing.value { return jsonResponse(body, url: request.url!, status: status) }
                    return managedLocalAuthResponse(request)
                }, dataPurger: { purged.fulfill() })
                defer { source.dispose(removeCredentials: false) }
                if initiallyReady {
                    let ready = await source.authenticateManagedLocalService("token")
                    XCTAssertTrue(ready)
                }
                let identity = source.browserIdentity
                failing.set(true)
                let accepted = await source.authenticateManagedLocalService("token")
                XCTAssertFalse(accepted)
                XCTAssertTrue(source.browserRevoked)
                XCTAssertFalse(source.browserReady)
                XCTAssertTrue(source.store.unauthorized)
                XCTAssertNotEqual(source.browserIdentity, identity)
                XCTAssertNotNil(source.authenticationError)
                await fulfillment(of: [purged], timeout: 2)
                XCTAssertNil(source.security?.bearer)
                XCTAssertNil(try storage.read(id: connection.id))
            }
        }
    }

    func testLateValidationCannotRestoreRevokedDisposedChangedOrCancelledWorkspace() async throws {
        for scenario in ["revoked", "disposed", "changed", "cancelled"] {
            let connection = connection()
            let storage = HubMemoryBearerStorage()
            try storage.write("token", id: connection.id)
            let gate = CookieWriteGate()
            let started = expectation(description: "validation started: \(scenario)")
            let source = HubSourceWorkspace(connection: connection, bearerStorage: storage, dataStore: .nonPersistent(),
                                            transport: ManagedLocalAuthTransport { request in
                started.fulfill()
                await gate.wait()
                return managedLocalAuthResponse(request)
            }, dataPurger: {})
            let task = Task { await source.authenticateManagedLocalService("token") }
            await fulfillment(of: [started], timeout: 2)
            switch scenario {
            case "revoked": source.revokeAuthorization()
            case "disposed": source.dispose(removeCredentials: false)
            case "changed": _ = await source.prepareAuthentication()
            default: task.cancel()
            }
            let identity = source.browserIdentity, epoch = source.authEpoch
            await gate.release()
            let accepted = await task.value
            XCTAssertFalse(accepted, scenario)
            XCTAssertFalse(source.browserReady, scenario)
            XCTAssertEqual(source.browserIdentity, identity, scenario)
            XCTAssertEqual(source.authEpoch, epoch, scenario)
            source.dispose(removeCredentials: false)
        }
    }

    func testRevocationDuringBrowserCookiePreparationCannotRestoreWorkspace() async throws {
        let connection = connection()
        let storage = HubMemoryBearerStorage()
        try storage.write("token", id: connection.id)
        let gate = CookieWriteGate()
        let clearing = expectation(description: "website operation blocks the cookie barrier")
        let validated = expectation(description: "bearer validated")
        var didBlock = false
        let source = HubSourceWorkspace(connection: connection, bearerStorage: storage, dataStore: .nonPersistent(),
                                        transport: ManagedLocalAuthTransport { request in
            validated.fulfill()
            return managedLocalAuthResponse(request)
        }, dataPurger: {
            guard !didBlock else { return }
            didBlock = true
            clearing.fulfill()
            await gate.wait()
        })
        defer { source.dispose(removeCredentials: false) }
        let security = try XCTUnwrap(source.security)
        let blocking = Task { await security.clearData(epoch: security.epoch) }
        await fulfillment(of: [clearing], timeout: 2)
        let handoff = Task { await source.authenticateManagedLocalService("token") }
        await fulfillment(of: [validated], timeout: 2)
        for _ in 0..<10 { await Task.yield() }
        source.revokeAuthorization()
        let identity = source.browserIdentity
        await gate.release()
        _ = await blocking.value
        let accepted = await handoff.value
        XCTAssertFalse(accepted)
        XCTAssertTrue(source.browserRevoked)
        XCTAssertFalse(source.browserReady)
        XCTAssertEqual(source.browserIdentity, identity)
    }
}

private struct ManagedLocalAuthTransport: HubTransport {
    let handler: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    func execute(_ request: URLRequest, onUnauthorized: (@Sendable () async -> Void)?) async throws -> (Data, HTTPURLResponse) {
        let response = try await handler(request)
        if response.1.statusCode == 401 || response.1.statusCode == 403 { await onUnauthorized?() }
        return response
    }
}

private func managedLocalAuthResponse(_ request: URLRequest) -> (Data, HTTPURLResponse) {
    let body: String
    if request.url?.path.hasSuffix("/healthz") == true {
        body = #"{"status":"ok","version":"1.0","capabilities":["api"]}"#
    } else if request.url?.path.hasSuffix("/sessions/status") == true {
        body = #"{"sessions":[]}"#
    } else {
        body = #"{"protocol_version":2,"store_instance_id":"fixture","snapshot_version":1,"items":[],"has_more":false}"#
    }
    return jsonResponse(body, url: request.url!)
}

@MainActor
private final class ManagedLocalNavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?
    private var deadline: Task<Void, Never>?
    func wait() async throws {
        if let result { return try result.get() }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            deadline = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                self?.finish(.failure(NSError(domain: "ManagedLocalNavigationWaiter", code: 1,
                                             userInfo: [NSLocalizedDescriptionKey: "Timed out loading the local MCP preference fixture"])))
            }
        }
    }
    private func finish(_ result: Result<Void, Error>) {
        guard self.result == nil else { return }
        self.result = result
        deadline?.cancel()
        deadline = nil
        continuation?.resume(with: result)
        continuation = nil
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(.success(())) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
}

private actor CookieWriteGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { if !released { await withCheckedContinuation { continuation = $0 } } }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
