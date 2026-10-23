import Foundation
#if canImport(Security)
import Security
#endif

/// Secret storage seam: keychain in the app, in-memory in tests.
protocol PeerSecureStorage: AnyObject, Sendable {
    func read(account: String) throws -> Data?
    func write(_ data: Data, account: String) throws
    func delete(account: String) throws
}

enum PeerStorageError: Error, Equatable {
    case keychain(Int32)
    case corrupt(String)
}

#if canImport(Security) && !os(Linux)
/// Generic-password keychain items under service `com.termllm.peer`.
/// `AfterFirstUnlockThisDeviceOnly`, never synchronised, never in backups.
/// The device private key never leaves this item and is not derived from
/// any pairing secret, broker capability or Hub token.
final class PeerKeychainStorage: PeerSecureStorage, @unchecked Sendable {
    let service: String

    init(service: String = "com.termllm.peer") { self.service = service }

    private func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: kCFBooleanFalse as Any]
    }

    func read(account: String) throws -> Data? {
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw PeerStorageError.keychain(status) }
        return out as? Data
    }

    func write(_ data: Data, account: String) throws {
        let update: [String: Any] = [kSecValueData as String: data,
                                     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(base(account) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = base(account)
            add.merge(update) { $1 }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw PeerStorageError.keychain(status) }
    }

    func delete(account: String) throws {
        let status = SecItemDelete(base(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw PeerStorageError.keychain(status) }
    }
}
#endif

final class PeerMemoryStorage: PeerSecureStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    init() {}
    func read(account: String) throws -> Data? { lock.withLock { items[account] } }
    func write(_ data: Data, account: String) throws { lock.withLock { items[account] = data } }
    func delete(account: String) throws { lock.withLock { _ = items.removeValue(forKey: account) } }
}

/// A host this device has paired with (verified pair answer).  No pairing
/// secret, broker capability or Hub token is stored.
struct PeerPairedHost: Codable, Equatable, Sendable, Identifiable {
    var hostKey: Data
    var grantID: Data
    /// Finite in the pilot (host default 24 h); nil only if the host granted
    /// no expiry.
    var grantExpiresAt: Date?
    var brokerURL: String
    var name: String?
    var pairedAt: Date

    var id: String { PeerBase64URL.encode(hostKey) }

    func isExpired(at now: Date = Date()) -> Bool { grantExpiresAt.map { now >= $0 } ?? false }
}

/// Persistent device identity + paired-host records.
final class PeerIdentityStore: @unchecked Sendable {
    static let identityAccount = "device-identity-ed25519"
    static let hostsAccount = "paired-hosts-v1"
    static let maxHosts = 16

    private let storage: PeerSecureStorage
    private let lock = NSLock()

    init(storage: PeerSecureStorage) { self.storage = storage }

    #if canImport(Security) && !os(Linux)
    convenience init() { self.init(storage: PeerKeychainStorage()) }
    #endif

    /// Loads the device key, creating and persisting one on first use.
    func deviceIdentity() throws -> PeerDeviceIdentity {
        try lock.withLock {
            if let seed = try storage.read(account: Self.identityAccount) {
                guard seed.count == 32, let id = try? PeerDeviceIdentity(seed: seed) else {
                    throw PeerStorageError.corrupt("device identity")
                }
                return id
            }
            let id = PeerDeviceIdentity()
            try storage.write(id.seed, account: Self.identityAccount)
            return id
        }
    }

    func pairedHosts(now: Date = Date()) throws -> [PeerPairedHost] {
        try lock.withLock { try loadHosts() }
    }

    /// Upserts by host key (re-pairing replaces the grant).
    func save(_ host: PeerPairedHost) throws {
        try lock.withLock {
            var hosts = try loadHosts().filter { $0.hostKey != host.hostKey }
            hosts.append(host)
            if hosts.count > Self.maxHosts { hosts.removeFirst(hosts.count - Self.maxHosts) }
            try storage.write(try JSONEncoder().encode(hosts), account: Self.hostsAccount)
        }
    }

    /// Only for 401 expired/revoked grants or explicit user removal — never
    /// for a 403 scope denial.
    func remove(hostKey: Data) throws {
        try lock.withLock {
            let hosts = try loadHosts().filter { $0.hostKey != hostKey }
            try storage.write(try JSONEncoder().encode(hosts), account: Self.hostsAccount)
        }
    }

    /// Erase identity and every pairing (e.g. "Forget all peer devices").
    func reset() throws {
        try lock.withLock {
            try storage.delete(account: Self.hostsAccount)
            try storage.delete(account: Self.identityAccount)
        }
    }

    private func loadHosts() throws -> [PeerPairedHost] {
        guard let data = try storage.read(account: Self.hostsAccount) else { return [] }
        guard let hosts = try? JSONDecoder().decode([PeerPairedHost].self, from: data) else {
            throw PeerStorageError.corrupt("paired hosts")
        }
        return hosts
    }
}
