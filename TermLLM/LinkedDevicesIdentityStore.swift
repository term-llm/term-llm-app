import CryptoKit
import Foundation
#if canImport(Security)
import Security
#endif

/// Strict, unpadded base64url shared by linked-devices links, keys and
/// capabilities. Re-encoding rejects non-canonical trailing bits.
enum LinkedDevicesBase64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ value: String, maximumBytes: Int = 4096) -> Data? {
        guard !value.isEmpty, value.utf8.count <= maximumBytes * 2,
              value.utf8.allSatisfy({ byte in
                  (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) ||
                      (byte >= 0x30 && byte <= 0x39) || byte == 0x2D || byte == 0x5F
              }), value.utf8.count % 4 != 1 else { return nil }
        var padded = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while padded.utf8.count % 4 != 0 { padded += "=" }
        guard let data = Data(base64Encoded: padded), data.count <= maximumBytes,
              encode(data) == value else { return nil }
        return data
    }
}

enum LinkedDevicesStorageError: Error, Equatable, LocalizedError {
    case unavailable(Int32)
    case corrupt
    case missing
    case hostMismatch

    var errorDescription: String? {
        switch self {
        case .unavailable(_): "The device identity could not be loaded or saved securely."
        case .corrupt: "Saved Linked devices credentials are unreadable. Forget the connection and pair again."
        case .missing: "This linked device connection no longer has credentials. Pair it again."
        case .hostMismatch: "The host identity changed. The connection was stopped."
        }
    }
}

protocol LinkedDevicesSecureStorage: Sendable {
    func read(account: String) throws -> Data?
    func write(_ data: Data, account: String) throws
    func delete(account: String) throws
}

#if canImport(Security)
struct LinkedDevicesKeychainStorage: LinkedDevicesSecureStorage {
    private let service = "com.termllm.app.linked-devices.v2"

    private func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            // Implicit on iOS; required for the native Mac app (see HubKeychainBearerStorage).
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    func read(account: String) throws -> Data? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw LinkedDevicesStorageError.unavailable(status)
        }
        return data
    }

    func write(_ data: Data, account: String) throws {
        let base = query(account)
        let updates: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(base as CFDictionary, updates as CFDictionary)
        if status == errSecItemNotFound {
            var item = base
            item.merge(updates) { _, new in new }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw LinkedDevicesStorageError.unavailable(status) }
    }

    func delete(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw LinkedDevicesStorageError.unavailable(status)
        }
    }
}
#endif

/// Test-only storage. Production construction always uses Keychain.
// Sendability: every access to values is under lock; reads return Data values.
final class LinkedDevicesMemoryStorage: LinkedDevicesSecureStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(account: String) throws -> Data? { lock.withLock { values[account] } }
    func write(_ data: Data, account: String) throws { lock.withLock { values[account] = data } }
    func delete(account: String) throws { lock.withLock { _ = values.removeValue(forKey: account) } }
}

/// Secret state for exactly one enrolled host. The metadata catalog stores a
/// host key and local bridge URL, but never this document or its capabilities.
struct LinkedDevicesCredential: Codable, Equatable, Sendable {
    static let currentVersion = 2
    var version = Self.currentVersion
    var hostKey: Data
    var deviceSeed: Data
    var deviceID: String?
    var reconnectCapability: Data?
    var brokerURL: URL?
    var scope: String?
    var basePath: String?
    var hostLabel: String?
    var pairedAt: Date?

    var devicePublicKey: Data {
        (try? Curve25519.Signing.PrivateKey(rawRepresentation: deviceSeed).publicKey.rawRepresentation) ?? Data()
    }
}

/// Per-host Ed25519 identities. Preparing a pairing persists its identity
/// before any request is sent, so approval can never create an unreconnectable
/// source. There is deliberately no production memory fallback.
// Sendability: lock serializes complete read/modify/write storage transactions.
// The injected storage also conforms to Sendable; encoded documents are local.
final class LinkedDevicesIdentityStore: @unchecked Sendable {
    private let storage: any LinkedDevicesSecureStorage
    private let lock = NSLock()

    #if canImport(Security)
    convenience init() { self.init(storage: LinkedDevicesKeychainStorage()) }
    #endif

    init(storage: any LinkedDevicesSecureStorage) { self.storage = storage }

    static func account(hostKey: Data) -> String {
        "host-" + LinkedDevicesBase64URL.encode(Data(SHA256.hash(data: hostKey)))
    }

    func prepare(hostKey: Data) throws -> LinkedDevicesCredential {
        guard hostKey.count == 32 else { throw LinkedDevicesStorageError.corrupt }
        return try lock.withLock {
            let account = Self.account(hostKey: hostKey)
            if let existing = try storage.read(account: account) {
                let credential = try decode(existing)
                guard credential.hostKey == hostKey else { throw LinkedDevicesStorageError.hostMismatch }
                return credential
            }
            let key = Curve25519.Signing.PrivateKey()
            let credential = LinkedDevicesCredential(hostKey: hostKey, deviceSeed: key.rawRepresentation)
            try storage.write(try encode(credential), account: account)
            return credential
        }
    }

    func load(hostKey: Data) throws -> LinkedDevicesCredential {
        try lock.withLock {
            guard let data = try storage.read(account: Self.account(hostKey: hostKey)) else {
                throw LinkedDevicesStorageError.missing
            }
            let credential = try decode(data)
            guard credential.hostKey == hostKey else { throw LinkedDevicesStorageError.hostMismatch }
            return credential
        }
    }

    func save(_ credential: LinkedDevicesCredential) throws {
        guard credential.hostKey.count == 32, credential.deviceSeed.count == 32,
              credential.version == LinkedDevicesCredential.currentVersion else { throw LinkedDevicesStorageError.corrupt }
        try lock.withLock {
            try storage.write(try encode(credential), account: Self.account(hostKey: credential.hostKey))
        }
    }

    func remove(hostKey: Data) throws {
        try lock.withLock { try storage.delete(account: Self.account(hostKey: hostKey)) }
    }

    private func decode(_ data: Data) throws -> LinkedDevicesCredential {
        guard data.count <= 16 * 1024,
              let value = try? JSONDecoder().decode(LinkedDevicesCredential.self, from: data),
              value.version == LinkedDevicesCredential.currentVersion,
              value.hostKey.count == 32, value.deviceSeed.count == 32,
              value.devicePublicKey.count == 32 else { throw LinkedDevicesStorageError.corrupt }
        return value
    }

    private func encode(_ value: LinkedDevicesCredential) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}
