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
        let downloader = ListenDownloader(store: library, cookies: jar, server: { ListenServer(base: root.url, sourceID: root.id) }, directory: directory, fetch: { request, _ in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "term_llm_web_session=nested", "Download must use the saved item owner, not the newly selected root")
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("owned-media-\(UUID())")
            try Data([1, 2, 3]).write(to: temporary)
            return (temporary, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "audio/mpeg"])!)
        })
        catalog.select(root.id); registry.selectedID = root.id
        let stream = await downloader.source(for: item)
        XCTAssertEqual(stream.cookies.map(\.value), ["nested"], "Selection must not rebind an old media item")
        XCTAssertNil(registry.unambiguousSourceID(for: url), "Root/child URLs without operation ownership are ambiguous")
        let unbound = await jar.cookies(for: url)
        XCTAssertTrue(unbound.isEmpty)
        downloader.download(item.id)
        for _ in 0..<50 where library.item(item.id)?.download != .downloaded {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(library.item(item.id)?.download, .downloaded)
        downloader.deleteFile(item.id)
        b.nextEpoch() // revoke/reauth starts before asynchronous WebKit clear finishes
        let revoked = await downloader.source(for: item)
        XCTAssertTrue(revoked.cookies.isEmpty, "Revocation blocks media reads immediately, not only after WebKit deletion")
        catalog.remove(nested.id)
        let removed = await downloader.source(for: item)
        XCTAssertTrue(removed.cookies.isEmpty, "Removed UUID must never fall back to root credentials")
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
        let admitted = source.directClient?.on_unauthorized
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

private actor CookieWriteGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { if !released { await withCheckedContinuation { continuation = $0 } } }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
