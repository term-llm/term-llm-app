import Foundation

/// One app writer, app/NSE readers. This authoritative consent snapshot is
/// committed to the existing shared keychain BEFORE the app-group file mirror.
/// It deliberately survives mirror failure/restart; it is not a transient flag
/// that can be overwritten by an older still-enabled shared file.
final class PushConsentJournal {
    struct Snapshot: Codable, Equatable {
        var enabled: Bool?
        var optOuts: Set<String>
        var revision: String = UUID().uuidString
    }

    private let storage: PushSecretStorage
    private let lock = NSLock()

    init(storage: PushSecretStorage = KeychainPushStorage(account: "consent-journal", allowDefaultGroup: false)) {
        self.storage = storage
    }

    func load() throws -> Snapshot? {
        try lock.withLock {
            guard let data = try storage.read() else { return nil }
            return try JSONDecoder().decode(Snapshot.self, from: data)
        }
    }

    func save(enabled: Bool?, optOuts: Set<String>) throws -> Snapshot {
        try lock.withLock {
            let snapshot = Snapshot(enabled: enabled, optOuts: optOuts)
            try storage.write(JSONEncoder().encode(snapshot))
            return snapshot
        }
    }
}
