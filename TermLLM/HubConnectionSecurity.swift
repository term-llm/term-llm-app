import Foundation
import Security
import WebKit

/// Simulator fixture has no production settings, cookies, keychain, push, or tools.
enum PhoneHubFixture {
    static var isEnabled: Bool {
        // Debug builds on the Simulator or a Mac only; never shipped.
        #if DEBUG && (targetEnvironment(simulator) || os(macOS))
        ProcessInfo.processInfo.environment["TERMLLM_PHONE_HUB_FIXTURE_URL"] == "http://localhost:8767/"
        #else
        false
        #endif
    }
    // Sendability: UserDefaults documents concurrent access as thread-safe.
    // Static initialization publishes this one immutable reference only after
    // fixture reset/seeding; no subsequent mutation of the reference occurs.
    nonisolated(unsafe) static let defaults: UserDefaults = {
        guard isEnabled else { return .standard }
        let name = "com.termllm.app.phone-hub-fixture"
        let defaults = UserDefaults(suiteName: name)!
        let environment = ProcessInfo.processInfo.environment
        if environment["TERMLLM_PHONE_HUB_FIXTURE_RESET"] == "1" {
            defaults.removePersistentDomain(forName: name)
        }
        if let list = environment["TERMLLM_PHONE_HUB_FIXTURE_SEED"] { PhoneHubFixture.seed(list, into: defaults) }
        return defaults
    }()

    /// UI tests preload connections instead of typing them into the editor.
    /// Fixed IDs let tests address rows without reading them back from the UI.
    static let seedSources: [(key: String, name: String, kind: HubConnection.Kind, id: UUID)] = [
        ("work", "Work Hub", .hub, UUID(uuidString: "00000000-0000-4000-8000-000000000001")!),
        ("home", "Home Hub", .hub, UUID(uuidString: "00000000-0000-4000-8000-000000000002")!),
        ("direct", "Laptop", .directNode, UUID(uuidString: "00000000-0000-4000-8000-000000000003")!),
        ("slow", "Slow Hub", .hub, UUID(uuidString: "00000000-0000-4000-8000-000000000004")!),
    ]

    private static func seed(_ list: String, into defaults: UserDefaults) {
        guard let base = environmentURL else { return }
        let connections = list.split(separator: ",").compactMap { key in
            seedSources.first { $0.key == key }.map {
                HubConnection(id: $0.id, name: $0.name, kind: $0.kind, url: base.appendingPathComponent($0.key + "/"))
            }
        }
        let document = HubConnectionStore.Document(connections: connections, selectedID: connections.first?.id)
        if let data = try? JSONEncoder().encode(document) { defaults.set(data, forKey: HubConnectionStore.storageKey) }
        defaults.set(connections.first?.url.absoluteString ?? "", forKey: "serverURL")
    }

    private static var environmentURL: URL? {
        ProcessInfo.processInfo.environment["TERMLLM_PHONE_HUB_FIXTURE_URL"].flatMap(URL.init(string:))
    }
}

protocol HubBearerStorage {
    func read(id: UUID) throws -> String?
    func write(_ token: String?, id: UUID) throws
}

/// Actual SDK Keychain implementation. UUID scope separates even sibling mounts.
struct HubKeychainBearerStorage: HubBearerStorage {
    private func query(_ id: UUID) -> [String: Any] {
        // The data-protection keychain is implicit on iOS; a native Mac app
        // must ask for it, or items land in the legacy login keychain instead.
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.termllm.app.phoneHub.bearer",
         kSecAttrAccount as String: id.uuidString,
         kSecUseDataProtectionKeychain as String: true]
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

/// A UUID-backed WebKit store does not load its on-disk cookies until its
/// network session exists. Until then, after a relaunch, `getAllCookies`
/// returns nothing, so native requests went out unauthenticated, got a 401,
/// and fail-closed revocation then erased the still-valid session. Fetching
/// the store's cookie records first creates the session and loads the jar.
@MainActor
enum PersistentCookieStoreLoader {
    private static var loaded: Set<UUID> = []

    static func load(_ store: WKWebsiteDataStore) async {
        guard store.isPersistent, let id = store.identifier, !loaded.contains(id) else { return }
        _ = await store.dataRecords(ofTypes: [WKWebsiteDataTypeCookies])
        loaded.insert(id)
    }
}

@MainActor
final class HubWebsiteDataBarrier {
    private static var sharedBarriers: [UUID: HubWebsiteDataBarrier] = [:]
    private var tail: Task<Void, Never>?

    static func shared(for id: UUID) -> HubWebsiteDataBarrier {
        if let barrier = sharedBarriers[id] { return barrier }
        let barrier = HubWebsiteDataBarrier()
        sharedBarriers[id] = barrier
        return barrier
    }

    /// Enqueue synchronously on MainActor so a workspace replacement cannot
    /// overtake a purge whose WebKit completion will arrive later.
    @discardableResult
    func enqueue(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            await operation()
        }
        tail = task
        return task
    }

    func perform<Result: Sendable>(_ operation: @escaping @MainActor () async -> Result) async -> Result {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            return await operation()
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    func wait() async { await tail?.value }
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
    private(set) var cookiesReadable = true
    private(set) var bearer: String?
    private let websiteDataBarrier: HubWebsiteDataBarrier
    private let cookieWriter: (@MainActor (HTTPCookie) async -> Void)?
    private let dataPurger: (@MainActor () async -> Void)?
    private let storeLoader: @MainActor (WKWebsiteDataStore) async -> Void

    init(connection: HubConnection, bearerStorage: any HubBearerStorage = HubKeychainBearerStorage(),
         dataStore: WKWebsiteDataStore? = nil,
         websiteDataBarrier: HubWebsiteDataBarrier? = nil,
         cookieWriter: (@MainActor (HTTPCookie) async -> Void)? = nil,
         dataPurger: (@MainActor () async -> Void)? = nil,
         storeLoader: @escaping @MainActor (WKWebsiteDataStore) async -> Void = PersistentCookieStoreLoader.load) {
        self.cookieWriter = cookieWriter
        self.dataPurger = dataPurger
        self.storeLoader = storeLoader
        id = connection.id
        server = connection.url
        self.bearerStorage = bearerStorage
        self.websiteDataBarrier = websiteDataBarrier ?? .shared(for: connection.id)
        self.dataStore = dataStore ?? (PhoneHubFixture.isEnabled ? .nonPersistent() : WKWebsiteDataStore(forIdentifier: connection.id))
        bearer = try? bearerStorage.read(id: connection.id)
    }

    func cookies() async -> [HTTPCookie] {
        guard active, cookiesReadable else { return [] }
        let expected = epoch
        await websiteDataBarrier.wait()
        guard active, cookiesReadable, epoch == expected else { return [] }
        await storeLoader(dataStore)
        guard active, cookiesReadable, epoch == expected else { return [] }
        let cookies = await withCheckedContinuation { continuation in
            dataStore.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        return active && cookiesReadable && epoch == expected ? cookies : []
    }
    /// Serializes WebKit writes/clears across auth generations. A write already
    /// submitted to WebKit cannot be cancelled: a new identity therefore waits
    /// for it to complete before importing its own cookies or restoring chat.
    @discardableResult
    func saveCookies(_ cookies: [HTTPCookie], epoch expected: UInt64,
                     isCurrent: @escaping @Sendable () -> Bool = { true }) async -> Bool {
        await performCookieOperation(epoch: expected, isCurrent: isCurrent) { [self] in
            for cookie in cookies {
                guard active, epoch == expected, isCurrent(), !Task.isCancelled else { return }
                if let cookieWriter { await cookieWriter(cookie) }
                else {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        if let expiry = cookie.expiresDate, expiry <= Date() {
                            dataStore.httpCookieStore.delete(cookie) { continuation.resume() }
                        } else { dataStore.httpCookieStore.setCookie(cookie) { continuation.resume() } }
                    }
                }
            }
        }
    }
    private func purgeWebsiteData() async {
        if let dataPurger { await dataPurger(); return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
                continuation.resume()
            }
        }
    }

    @discardableResult
    func clearData(epoch expected: UInt64) async -> Bool {
        await performCookieOperation(epoch: expected, isCurrent: { true }) { [self] in
            await purgeWebsiteData()
        }
    }
    private func performCookieOperation(epoch expected: UInt64, isCurrent: @escaping @Sendable () -> Bool,
                                         operation: @escaping @MainActor () async -> Void) async -> Bool {
        await websiteDataBarrier.perform { [self] in
            guard active, epoch == expected, isCurrent(), !Task.isCancelled else { return false }
            // Load the persisted jar before writing, so it cannot later
            // resurface over a cookie written or cleared in this process.
            await storeLoader(dataStore)
            guard active, epoch == expected, isCurrent(), !Task.isCancelled else { return false }
            await operation()
            return active && epoch == expected && isCurrent() && !Task.isCancelled
        }
    }
    func waitForCookies() async { await websiteDataBarrier.wait() }
    func setBearer(_ token: String?) throws {
        guard active else { throw CancellationError() }
        try bearerStorage.write(token, id: id)
        bearer = token
    }

    /// Authentication replaces callbacks, not other connections' credentials.
    func nextEpoch() { epoch &+= 1; cookiesReadable = false }
    func authorizeCookieReads() { guard active else { return }; cookiesReadable = true }

    func dispose(removeCredentials: Bool) {
        active = false
        epoch &+= 1
        if removeCredentials {
            try? bearerStorage.write(nil, id: id)
            bearer = nil
            // This store is UUID-owned. Enqueue synchronously so a replacement
            // security object sharing the UUID cannot overtake this purge.
            websiteDataBarrier.enqueue { [self] in
                await purgeWebsiteData()
            }
        }
    }

    /// Frontend verified in platform/storage.ts and platform/browser.ts:
    /// direct token key is term_llm_token; cookie authenticates GET only.
    /// Both are needed: the page reads localStorage to authorize mutations.
    /// Runs only in a main-frame document on the exact origin/mount, never URL
    /// parameters or a global WK cookie jar. Native POST uses the bearer header.
    static func directBearerScript(token: String, server: URL) -> String {
        func json(_ value: String) -> String {
            // A String with the default JSONEncoder has no fallible custom
            // encoding or non-finite numbers; JSON escaping is infallible.
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
