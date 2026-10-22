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
        var consentRevision: String?
        var optOuts: Set<String> = []
        var events: [String: Date] = [:]
        var reads: [String: Read] = [:]
        var enrollments: [Enrollment] = []
    }

    struct Read: Codable {
        var sequence: Int64
        var expires: Date
    }

    enum Disposition: String { case allowed, disabled, read, replay, expired, capacity, unavailable }
    enum Failure: Error, Equatable { case unavailable, lock, corrupt, capacity }

    let url: URL?
    let journal: PushConsentJournal?
    let lockAttempts: Int
    var writeData: (Data, URL) throws -> Void = {
        try $0.write(to: $1, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    convenience init() {
        self.init(url: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: PushDeliveryStore.group)?
            .appendingPathComponent("notification-state.json"), journal: PushConsentJournal())
    }

    /// Explicit URL is the isolated test seam; it never uses a live keychain.
    init(url: URL?, journal: PushConsentJournal? = nil, lockAttempts: Int = 40) {
        self.url = url
        self.journal = journal
        self.lockAttempts = max(1, min(lockAttempts, 40))
    }

    var available: Bool { (try? transaction { _ in true }) == true }
    var automaticStateAvailable: Bool { (try? transaction { $0.enabled != nil }) == true }

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
        // Never wait indefinitely on a suspended app that owns this lock.
        // At most 40 nonblocking attempts with 5ms backoff (<200ms waiting).
        var acquired = false
        for attempt in 0..<lockAttempts {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { acquired = true; break }
            if attempt + 1 < lockAttempts { usleep(5_000) }
        }
        guard acquired else { throw Failure.lock }
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
        if let snapshot = try journal?.load() { Self.apply(snapshot, to: &state) }
        let result = try body(&state)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(state)
        if encoded != original {
            try writeData(encoded, url)
        }
        return result
    }

    private static func apply(_ snapshot: PushConsentJournal.Snapshot, to state: inout State) {
        state.enabled = snapshot.enabled
        state.optOuts = snapshot.optOuts
        state.consentRevision = snapshot.revision
        for index in state.enrollments.indices where snapshot.enabled == false ||
            snapshot.optOuts.contains(state.enrollments[index].origin + "|" + state.enrollments[index].scope) {
            state.enrollments[index].pendingCleanup = true
        }
    }

    func migrate(enabled: Bool?, optOuts: Set<String>) throws {
        try transaction { state in
            func importLegacyOff(_ state: inout State) {
                if state.enabled == nil || enabled == false { state.enabled = enabled }
                state.optOuts.formUnion(optOuts) // migration never clears an off
            }
            if let journal {
                if try journal.load() == nil {
                    importLegacyOff(&state)
                    Self.apply(try journal.save(enabled: state.enabled, optOuts: state.optOuts), to: &state)
                }
            } else { importLegacyOff(&state) }
        }
    }

    func consentSnapshot() throws -> PushConsentJournal.Snapshot? { try journal?.load() }

    func isEnabled(origin: String?, scope: String?) throws -> Bool {
        try transaction { state in
            guard state.enabled == true else { return false }
            guard let origin, let scope else { return state.optOuts.isEmpty }
            return !state.optOuts.contains(origin + "|" + scope)
        }
    }

    /// The journal save must succeed first. A later mirror/cleanup failure is
    /// returned, but cannot erase the committed off intent on the next launch.
    func persistConsent(enabled: Bool?, optOuts: Set<String>) throws {
        if let previous = try journal?.load() {
            let clearsPriorOff = (previous.enabled == false && enabled != false) ||
                !previous.optOuts.subtracting(optOuts).isEmpty
            // Do not overwrite an unmirrored off with enable and lose its
            // cleanup handles. A failed enable stays pending/explicitly failed.
            if clearsPriorOff { try reconcilePriorOffMirror() }
        }
        let snapshot = try journal?.save(enabled: enabled, optOuts: optOuts) ??
            PushConsentJournal.Snapshot(enabled: enabled, optOuts: optOuts)
        try transaction { state in Self.apply(snapshot, to: &state) }
    }

    private func reconcilePriorOffMirror() throws { try transaction { _ in () } }

    func setEnabled(_ enabled: Bool, origin: String? = nil, scope: String? = nil) throws {
        let old = try consentSnapshot()
        let current: PushConsentJournal.Snapshot
        if let old { current = old }
        else { current = try transaction { PushConsentJournal.Snapshot(enabled: $0.enabled, optOuts: $0.optOuts) } }
        var optOuts = current.optOuts
        if let origin, let scope {
            if enabled { optOuts.remove(origin + "|" + scope) } else { optOuts.insert(origin + "|" + scope) }
            try persistConsent(enabled: current.enabled, optOuts: optOuts)
        } else { try persistConsent(enabled: enabled, optOuts: optOuts) }
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

    private static func policy(_ message: PushMessage, state: State, now: Date) -> Disposition {
        if state.enabled == false { return .disabled }
        if let origin = message.origin, let scope = message.scope {
            if state.optOuts.contains(origin + "|" + scope) { return .disabled }
        } else if !state.optOuts.isEmpty { return .disabled }
        let metadata = message.metadata
        if let kind = metadata?.kind, kind != "manual" && kind != "completion" { return .unavailable }
        if let expires = metadata?.expiresAt, expires <= now { return .expired }
        if metadata?.kind == "completion" {
            guard state.enabled == true else { return .unavailable }
            if let origin = message.origin, let scope = message.scope, let store = metadata?.storeInstanceID,
               let session = metadata?.sessionID, let sequence = metadata?.attentionSequence,
               let read = state.reads[Self.key(origin, scope, store, session)], read.expires > now, read.sequence >= sequence { return .read }
        }
        return .allowed // unknown consent is manual compatibility, NOT auto consent
    }

    private func unavailablePolicy(_ message: PushMessage, now: Date) -> Disposition {
        guard message.metadata?.kind != "completion" else { return .unavailable }
        do {
            if let snapshot = try consentSnapshot() {
                var state = State(); Self.apply(snapshot, to: &state)
                return Self.policy(message, state: state, now: now)
            }
            // No established shared state (first upgraded NSE run/missing app
            // group) preserves manual compatibility. A locked/corrupt existing
            // file with no readable consent journal is NOT proof of consent.
            if let url, FileManager.default.fileExists(atPath: url.path) { return .unavailable }
            return Self.policy(message, state: State(), now: now)
        } catch { return .unavailable } // unreadable keychain may hide explicit off
        return .unavailable
    }

    func admit(_ message: PushMessage, now: Date = Date()) -> Disposition {
        do { return try receive(message, now: now) }
        catch { return unavailablePolicy(message, now: now) }
    }

    func presentationDisposition(_ message: PushMessage, now: Date = Date()) -> Disposition {
        do { return try transaction { Self.policy(message, state: $0, now: now) } }
        catch { return unavailablePolicy(message, now: now) }
    }

    /// Atomic, bounded arrival admission. NSE cannot cancel an OS remote alert;
    /// unavailable automatic state is quieted, never treated as manual consent.
    func receive(_ message: PushMessage, now: Date = Date()) throws -> Disposition {
        try transaction { state in
            let disposition = Self.policy(message, state: state, now: now)
            guard disposition == .allowed else { return disposition }
            guard let event = message.metadata?.eventID else { return .allowed }
            state.events = state.events.filter { $0.value > now }
            state.reads = state.reads.filter { $0.value.expires > now }
            let key = Self.key(message.origin ?? "", message.scope ?? "", message.sourceID ?? "", event)
            if state.events[key] != nil { return .replay }
            guard state.events.count < Self.capacity else { return .capacity }
            state.events[key] = now.addingTimeInterval(Self.horizon)
            return .allowed
        }
    }
}
