import CryptoKit
import Foundation
import Security

/// The device's Web Push identity, shared by the app and its Notification
/// Service Extension through a keychain access group.
///
/// One key pair and auth secret serve every server and hub node: they only
/// let this device decrypt. `routes` maps each server's source tag (see
/// `WebPushCrypto.sourceTag`) to the origin it was registered for, so a push
/// can be attributed and its tap routed without trusting the payload's URL.
struct PushIdentity: Codable, Equatable {
    var privateKey: Data // P256.KeyAgreement raw representation (32 bytes)
    var authSecret: Data // 16 bytes
    var routes: [String: String] = [:]

    static func generate() -> PushIdentity {
        var secret = Data(count: 16)
        let status = secret.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return PushIdentity(privateKey: P256.KeyAgreement.PrivateKey().rawRepresentation, authSecret: secret)
    }

    func agreementKey() throws -> P256.KeyAgreement.PrivateKey {
        try P256.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
    }

    /// Uncompressed public key, base64url: the subscription's `p256dh`.
    func publicKeyBase64URL() throws -> String {
        try agreementKey().publicKey.x963Representation.base64URLEncodedString()
    }
}

protocol PushSecretStorage {
    func read() throws -> Data?
    func write(_ data: Data) throws
}

enum PushStorageError: Error, Equatable {
    case keychain(OSStatus)
}

/// Generic-password item readable after first unlock (the extension runs
/// while the phone is locked) and never migrated to another device.
struct KeychainPushStorage: PushSecretStorage {
    static let service = "com.termllm.app.push"
    static let account = "identity"

    /// `TermLLMKeychainAccessGroup` from Info.plist, shared with the extension.
    /// Unsigned builds have no access-group entitlement; fall back to the
    /// default group so simulator tests still work.
    let accessGroup: String?

    init(accessGroup: String? = Bundle.main.object(forInfoDictionaryKey: "TermLLMKeychainAccessGroup") as? String) {
        let group = accessGroup?.trimmingCharacters(in: .whitespaces) ?? ""
        // An unexpanded or empty $(AppIdentifierPrefix) leaves a bare bundle-style group.
        self.accessGroup = group.isEmpty || group.hasPrefix(".") || group.contains("$(") ? nil : group
    }

    private func query(group: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let group { query[kSecAttrAccessGroup as String] = group }
        return query
    }

    func read() throws -> Data? {
        for group in candidateGroups {
            var item = query(group: group)
            item[kSecReturnData as String] = true
            item[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(item as CFDictionary, &result)
            switch status {
            case errSecSuccess: return result as? Data
            case errSecItemNotFound: return nil
            case errSecMissingEntitlement where group != nil: continue
            default: throw PushStorageError.keychain(status)
            }
        }
        return nil
    }

    func write(_ data: Data) throws {
        for group in candidateGroups {
            let base = query(group: group)
            let update: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            var status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
            if status == errSecItemNotFound {
                status = SecItemAdd(base.merging(update) { $1 } as CFDictionary, nil)
            }
            if status == errSecMissingEntitlement, group != nil { continue }
            guard status == errSecSuccess else { throw PushStorageError.keychain(status) }
            return
        }
    }

    private var candidateGroups: [String?] { accessGroup.map { [$0, nil] } ?? [nil] }
}

final class InMemoryPushStorage: PushSecretStorage {
    var data: Data?
    init(_ data: Data? = nil) { self.data = data }
    func read() throws -> Data? { data }
    func write(_ data: Data) throws { self.data = data }
}

final class PushIdentityStore {
    private let storage: PushSecretStorage
    private let lock = NSLock()

    init(storage: PushSecretStorage = KeychainPushStorage()) {
        self.storage = storage
    }

    /// Existing identity, or nil. The extension only ever reads.
    func load() throws -> PushIdentity? {
        try lock.withLock {
            try storage.read().flatMap { try? JSONDecoder().decode(PushIdentity.self, from: $0) }
        }
    }

    /// Loads the identity, creating and persisting one on first use.
    func loadOrCreate() throws -> PushIdentity {
        try lock.withLock {
            if let data = try storage.read(), let identity = try? JSONDecoder().decode(PushIdentity.self, from: data) {
                return identity
            }
            let identity = PushIdentity.generate()
            try storage.write(JSONEncoder().encode(identity))
            return identity
        }
    }

    func setRoute(tag: String, origin: String) throws {
        try lock.withLock {
            guard let data = try storage.read(), var identity = try? JSONDecoder().decode(PushIdentity.self, from: data) else {
                return
            }
            guard identity.routes[tag] != origin else { return }
            identity.routes[tag] = origin
            try storage.write(JSONEncoder().encode(identity))
        }
    }
}
