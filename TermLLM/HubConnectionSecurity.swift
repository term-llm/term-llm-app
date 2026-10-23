import Foundation
import Security
import WebKit

/// Simulator fixture has no production settings, cookies, keychain, push, or tools.
enum PhoneHubFixture {
    static var isEnabled: Bool {
        #if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.environment["TERMLLM_PHONE_HUB_FIXTURE_URL"] == "http://localhost:8767/"
        #else
        false
        #endif
    }
    static let defaults: UserDefaults = {
        guard isEnabled else { return .standard }
        let name = "com.termllm.app.phone-hub-fixture"
        let defaults = UserDefaults(suiteName: name)!
        if ProcessInfo.processInfo.environment["TERMLLM_PHONE_HUB_FIXTURE_RESET"] == "1" {
            defaults.removePersistentDomain(forName: name)
        }
        return defaults
    }()
}

protocol HubBearerStorage {
    func read(id: UUID) throws -> String?
    func write(_ token: String?, id: UUID) throws
}

/// Actual SDK Keychain implementation. UUID scope separates even sibling mounts.
struct HubKeychainBearerStorage: HubBearerStorage {
    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.termllm.app.phoneHub.bearer",
         kSecAttrAccount as String: id.uuidString]
    }
    func read(id: UUID) throws -> String? {
        var query = query(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else { throw StorageError.failed }
        return token
    }
    func write(_ token: String?, id: UUID) throws {
        let query = query(id)
        guard let token else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw StorageError.failed }
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8),
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item.merge(attributes) { _, new in new }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw StorageError.failed }
        } else if status != errSecSuccess { throw StorageError.failed }
    }
    enum StorageError: LocalizedError {
        case failed
        var errorDescription: String? { "Could not access this connection’s protected credential storage." }
    }
}

/// Explicitly used only for tests and simulator protocol fixtures.
final class HubMemoryBearerStorage: HubBearerStorage {
    private var tokens: [UUID: String] = [:]
    func read(id: UUID) throws -> String? { tokens[id] }
    func write(_ token: String?, id: UUID) throws { tokens[id] = token }
}

@MainActor
final class HubConnectionSecurity {
    let id: UUID
    let server: URL
    let dataStore: WKWebsiteDataStore
    private let bearerStorage: any HubBearerStorage
    private(set) var active = true
    private(set) var epoch: UInt64 = 0
    private(set) var bearer: String?

    init(connection: HubConnection, bearerStorage: any HubBearerStorage = HubKeychainBearerStorage(),
         dataStore: WKWebsiteDataStore? = nil) {
        id = connection.id
        server = connection.url
        self.bearerStorage = bearerStorage
        self.dataStore = dataStore ?? (PhoneHubFixture.isEnabled ? .nonPersistent() : WKWebsiteDataStore(forIdentifier: connection.id))
        bearer = try? bearerStorage.read(id: connection.id)
    }

    func cookies() async -> [HTTPCookie] {
        guard active else { return [] }
        return await withCheckedContinuation { continuation in
            dataStore.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
    }
    func saveCookies(_ cookies: [HTTPCookie], epoch expected: UInt64) async {
        guard active, expected == epoch else { return }
        for cookie in cookies {
            guard active, expected == epoch else { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if let expiry = cookie.expiresDate, expiry <= Date() {
                    dataStore.httpCookieStore.delete(cookie) { continuation.resume() }
                } else {
                    dataStore.httpCookieStore.setCookie(cookie) { continuation.resume() }
                }
            }
        }
    }
    func setBearer(_ token: String?) throws {
        guard active else { throw CancellationError() }
        try bearerStorage.write(token, id: id)
        bearer = token
    }

    /// Authentication replaces callbacks, not other connections' credentials.
    func nextEpoch() { epoch &+= 1 }

    func dispose(removeCredentials: Bool) {
        active = false
        epoch &+= 1
        if removeCredentials {
            try? bearerStorage.write(nil, id: id)
            bearer = nil
            // This store is UUID-owned. Never clear the ambient/default jar.
            dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
        }
    }

    /// Frontend verified in platform/storage.ts and platform/browser.ts:
    /// direct token key is term_llm_token; cookie authenticates GET only.
    /// Both are needed: the page reads localStorage to authorize mutations.
    /// Runs only in a main-frame document on the exact origin/mount, never URL
    /// parameters or a global WK cookie jar. Native POST uses the bearer header.
    static func directBearerScript(token: String, server: URL) -> String {
        func json(_ value: String) -> String {
            let data = try! JSONEncoder().encode(value)
            return String(decoding: data, as: UTF8.self)
        }
        let root = server.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let mount = root.isEmpty ? "/" : "/" + root + "/"
        return """
        (() => {
          if (location.origin !== \(json(NativeLogin.origin(for: server)))) return;
          const mount = \(json(mount));
          if (!(location.pathname === mount.slice(0, -1) || location.pathname.startsWith(mount))) return;
          localStorage.setItem('term_llm_token', \(json(token)));
          document.cookie = 'term_llm_token=' + encodeURIComponent(\(json(token))) + '; path=' + mount + '; SameSite=Strict' + (location.protocol === 'https:' ? '; Secure' : '');
        })();
        """
    }
}
