import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Shared app/NSE state. Every read-modify-write locks a separate, stable inode;
/// atomic replacement of the data file never replaces the lock. No user content,
/// credentials or device token is stored here. Missing entitlement is NOT v2.
final class PushDeliveryStore {
    static let group = "group.com.termllm.app.shared"
    static let horizon: TimeInterval = 24 * 60 * 60
    static let capacity = 4096

    struct Enrollment: Codable, Equatable {
        var origin: String
        var scope: String
        var endpoint: String
        var subscriptionID: String?
        var pendingCleanup: Bool
    }

    struct State: Codable {
        var enabled: Bool?
        var optOuts: Set<String> = []
        var events: [String: Date] = [:]
        var reads: [String: Read] = [:]
        var enrollments: [Enrollment] = []
    }

    struct Read: Codable {
        var sequence: Int64
        var expires: Date
    }

    enum Disposition: String { case allowed, disabled, read, replay, expired, capacity }
    enum Failure: Error { case unavailable, lock, corrupt, capacity }

    let url: URL?

    init(url: URL? = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: PushDeliveryStore.group)?
        .appendingPathComponent("notification-state.json")) {
        self.url = url
    }

    var available: Bool { (try? transaction { _ in true }) == true }

    static func key(_ parts: String...) -> String {
        // JSON framing prevents ambiguous origin/scope/session separators.
        (try! JSONEncoder().encode(parts)).base64EncodedString()
    }

    @discardableResult
    func transaction<T>(_ body: (inout State) throws -> T) throws -> T {
        guard let url else { throw Failure.unavailable }
        let lockURL = url.appendingPathExtension("lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw Failure.lock }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw Failure.lock }
        defer { flock(fd, LOCK_UN) }
        let original: Data?
        var state = State()
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                state = try JSONDecoder().decode(State.self, from: data)
                original = data
            } catch { throw Failure.corrupt } // never reset replay/off state silently
        } else { original = nil }
        let result = try body(&state)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(state)
        if encoded != original {
            try encoded.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        return result
    }

    func migrate(enabled: Bool, optOuts: Set<String>) throws {
        try transaction { state in
            guard state.enabled == nil else { return }
            state.enabled = enabled
            state.optOuts = optOuts
        }
    }

    func isEnabled(origin: String?, scope: String?) throws -> Bool {
        try transaction { state in
            guard state.enabled == true else { return false }
            guard let origin, let scope else { return state.optOuts.isEmpty }
            return !state.optOuts.contains(origin + "|" + scope)
        }
    }

    func setEnabled(_ enabled: Bool, origin: String? = nil, scope: String? = nil) throws {
        try transaction { state in
            if let origin, let scope {
                let key = origin + "|" + scope
                if enabled { state.optOuts.remove(key) } else { state.optOuts.insert(key) }
            } else { state.enabled = enabled }
            if !enabled {
                for index in state.enrollments.indices where origin == nil ||
                    (state.enrollments[index].origin == origin && state.enrollments[index].scope == scope) {
                    state.enrollments[index].pendingCleanup = true
                }
            }
        }
    }

    func remember(origin: String, scope: String, endpoint: String, subscriptionID: String? = nil) throws {
        try transaction { state in
            let pending = state.enabled != true || state.optOuts.contains(origin + "|" + scope)
            if let index = state.enrollments.firstIndex(where: {
                $0.origin == origin && $0.scope == scope && $0.endpoint == endpoint &&
                    ($0.subscriptionID == subscriptionID || $0.subscriptionID == nil)
            }) {
                // A retired enrollment is never reactivated by a late callback.
                state.enrollments[index].subscriptionID = subscriptionID ?? state.enrollments[index].subscriptionID
                state.enrollments[index].pendingCleanup = state.enrollments[index].pendingCleanup || pending
            } else {
                guard state.enrollments.count < Self.capacity else { throw Failure.capacity }
                state.enrollments.append(Enrollment(origin: origin, scope: scope, endpoint: endpoint,
                                                   subscriptionID: subscriptionID, pendingCleanup: pending))
            }
        }
    }

    func retire(origin: String, scope: String) throws {
        try transaction { state in
            for index in state.enrollments.indices where state.enrollments[index].origin == origin && state.enrollments[index].scope == scope {
                state.enrollments[index].pendingCleanup = true
            }
        }
    }

    func pending(origin: String? = nil, scope: String? = nil) throws -> [Enrollment] {
        try transaction { state in
            state.enrollments.filter { $0.pendingCleanup && (origin == nil || ($0.origin == origin && $0.scope == scope)) }
        }
    }

    func acknowledgeCleanup(origin: String, scope: String, subscriptionID: String) throws {
        try transaction { state in
            state.enrollments.removeAll { $0.origin == origin && $0.scope == scope &&
                $0.subscriptionID == subscriptionID }
        }
    }

    func acknowledgeRead(origin: String, scope: String, store: String, session: String, sequence: Int64, now: Date = Date()) throws {
        try transaction { state in
            state.reads = state.reads.filter { $0.value.expires > now }
            let key = Self.key(origin, scope, store, session)
            guard state.reads[key] != nil || state.reads.count < Self.capacity else { throw Failure.capacity }
            state.reads[key] = Read(sequence: max(sequence, state.reads[key]?.sequence ?? 0),
                                    expires: now.addingTimeInterval(Self.horizon))
        }
    }

    func hasRead(_ message: PushMessage, now: Date = Date()) throws -> Bool {
        try transaction { state in
            guard let origin = message.origin, let scope = message.scope, let metadata = message.metadata,
                  metadata.kind == "completion", let store = metadata.storeInstanceID,
                  let session = metadata.sessionID, let sequence = metadata.attentionSequence,
                  let read = state.reads[Self.key(origin, scope, store, session)] else { return false }
            return read.expires > now && read.sequence >= sequence
        }
    }

    /// Atomic arrival admission shared by app and extension. At capacity do not
    /// evict an unexpired event and falsely promise a 24h replay horizon.
    func receive(_ message: PushMessage, now: Date = Date()) throws -> Disposition {
        try transaction { state in
            guard state.enabled == true else { return .disabled }
            if let origin = message.origin, let scope = message.scope {
                if state.optOuts.contains(origin + "|" + scope) { return .disabled }
            } else if !state.optOuts.isEmpty { return .disabled } // ambiguous legacy source
            let metadata = message.metadata
            if let expires = metadata?.expiresAt, expires <= now { return .expired }
            state.reads = state.reads.filter { $0.value.expires > now }
            if let origin = message.origin, let scope = message.scope, let metadata,
               metadata.kind == "completion", let store = metadata.storeInstanceID,
               let session = metadata.sessionID, let sequence = metadata.attentionSequence,
               let read = state.reads[Self.key(origin, scope, store, session)], read.sequence >= sequence { return .read }
            guard let event = metadata?.eventID else { return .allowed } // legacy manual
            state.events = state.events.filter { $0.value > now }
            let key = Self.key(message.origin ?? "", message.scope ?? "", message.sourceID ?? "", event)
            if state.events[key] != nil { return .replay }
            guard state.events.count < Self.capacity else { return .capacity }
            state.events[key] = now.addingTimeInterval(Self.horizon)
            return .allowed
        }
    }
}
