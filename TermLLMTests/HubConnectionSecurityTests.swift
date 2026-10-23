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

    func testLegacyCookieConsumersResolveTheSameSourceStore() async throws {
        let aConnection = connection("/"), bConnection = connection("/nested/")
        let a = HubConnectionSecurity(connection: aConnection, bearerStorage: HubMemoryBearerStorage(), dataStore: .nonPersistent())
        let b = HubConnectionSecurity(connection: bConnection, bearerStorage: HubMemoryBearerStorage(), dataStore: .nonPersistent())
        let registry = HubCookieScopeRegistry.shared
        registry.register(a, kind: .directNode)
        registry.register(b, kind: .directNode)
        defer { registry.unregister(a); registry.unregister(b); registry.selectedID = nil }
        await a.saveCookies([try cookie(aConnection, value: "root")], epoch: a.epoch)
        await b.saveCookies([try cookie(bConnection, value: "nested")], epoch: b.epoch)
        registry.selectedID = b.id
        XCTAssertTrue(registry.dataStore(for: URL(string: "https://example.com/nested/file.mp3")!) === b.dataStore)
        let cookies = await WebKitCookieJar().cookies(for: URL(string: "https://example.com/nested/file.mp3")!)
        XCTAssertEqual(cookies.map(\.value), ["nested"])
        registry.selectedID = a.id
        XCTAssertTrue(registry.dataStore(for: URL(string: "https://example.com/nested/file.mp3")!) === a.dataStore)
        a.dispose(removeCredentials: true)
        b.dispose(removeCredentials: true)
    }
}
