import Foundation

// MARK: - Authorization
//
// There is deliberately NO default/unauthenticated authorizer.  A
// `PeerAuthorization` must be produced by the pairing layer (pair crypto +
// signalling, integrated later) after it has authenticated the remote node.
// Every peer session, bridge and Hub transport requires one and re-checks it
// on each request; expiry or `revoke()` tears everything down.

struct PeerAuthorization: Sendable, Equatable {
    /// Stable identifier of the authenticated remote node (e.g. key fingerprint).
    let peerID: String
    /// Unique per pairing session; scopes loopback bridges and transports.
    let sessionID: String
    let expiresAt: Date
    /// Path prefix this session may reach on the node (`/` for everything,
    /// `/chat/` for chat only).
    let scopePrefix: String

    init(peerID: String, sessionID: String, expiresAt: Date, scopePrefix: String = "/") {
        self.peerID = peerID
        self.sessionID = sessionID
        self.expiresAt = expiresAt
        self.scopePrefix = scopePrefix.hasPrefix("/") ? scopePrefix : "/" + scopePrefix
    }

    func isValid(at now: Date = Date()) -> Bool {
        !peerID.isEmpty && !sessionID.isEmpty && now < expiresAt
    }
}

/// Implemented by the pairing layer.  No implementation ships here.
protocol PeerAuthorizing: AnyObject {
    /// Authenticate the remote node over the established session and return
    /// a scoped authorization, or throw.  Must never succeed without proof.
    func authorize(remoteFingerprint: String?) async throws -> PeerAuthorization
}

/// Shared, revocable authorization state.  Thread-safe.
// Sendability: lock protects authorization/handler registry. Handlers are
// @Sendable snapshots removed under lock and invoked outside it; clock must
// be thread-safe and non-reentrant because check() calls it under lock.
final class PeerAuthorizationState: @unchecked Sendable {
    private let lock = NSLock()
    private var authorization: PeerAuthorization?
    private var revokeHandlers: [UUID: @Sendable () -> Void] = [:]
    private let clock: @Sendable () -> Date

    init(_ authorization: PeerAuthorization, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.authorization = authorization
        self.clock = clock
    }

    var current: PeerAuthorization? { lock.withLock { authorization } }

    /// True while authorized and unexpired.  Expiry triggers revoke.
    func check() -> Bool {
        let (valid, expired): (Bool, Bool) = lock.withLock {
            guard let a = authorization else { return (false, false) }
            return a.isValid(at: clock()) ? (true, false) : (false, true)
        }
        if expired { revoke() }
        return valid
    }

    @discardableResult
    func onRevoke(_ handler: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        let fire: Bool = lock.withLock {
            if authorization == nil { return true }
            revokeHandlers[id] = handler
            return false
        }
        if fire { handler() }
        return id
    }

    func removeHandler(_ id: UUID) { lock.withLock { _ = revokeHandlers.removeValue(forKey: id) } }

    func revoke() {
        let handlers: [@Sendable () -> Void] = lock.withLock {
            guard authorization != nil else { return [] }
            authorization = nil
            let h = Array(revokeHandlers.values)
            revokeHandlers.removeAll()
            return h
        }
        handlers.forEach { $0() }
    }
}

// MARK: - Signalling values (transport-neutral)

struct PeerSessionDescription: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case offer, answer }
    let type: Kind
    let sdp: String
}

struct PeerICECandidate: Codable, Sendable, Equatable {
    let candidate: String
    let sdpMid: String?
    let sdpMLineIndex: Int32
}

/// Implemented by the (later) authenticated signalling layer.
protocol PeerSignaling: AnyObject {
    func sendLocalCandidate(_ candidate: PeerICECandidate)
}

enum PeerConnectionPhase: String, Sendable, Equatable {
    case new, connecting, connected, disconnected, failed, closed
}

// MARK: - Stats

/// Flattened `RTCStatisticsReport` entry (kept WebRTC-free for testing).
struct PeerStatsEntry {
    let id: String
    let type: String
    let values: [String: Any]

    init(id: String, type: String, values: [String: Any]) {
        self.id = id
        self.type = type
        self.values = values
    }
}

struct PeerSessionStats: Sendable, Equatable {
    var selectedPairID: String?
    var localCandidateType: String?
    var remoteCandidateType: String?
    var localProtocol: String?
    /// As reported by libwebrtc for the selected pair (nil when absent);
    /// never defaulted, so evidence validators can fail on missing data.
    var selectedPairState: String?
    var selectedPairNominated: Bool?
    /// RTCIceCandidateStats.relayProtocol (relay candidates only).
    var localRelayProtocol: String?
    var remoteRelayProtocol: String?
    /// Seconds (RTCIceCandidatePairStats.currentRoundTripTime).
    var currentRoundTripTime: Double?
    var availableOutgoingBitrate: Double?
    var bytesSent: UInt64 = 0
    var bytesReceived: UInt64 = 0
    var dataChannelMessagesSent: UInt64 = 0
    var dataChannelMessagesReceived: UInt64 = 0
    var dataChannelBytesSent: UInt64 = 0
    var dataChannelBytesReceived: UInt64 = 0

    /// True when traffic traverses a TURN relay (privacy/cost signal for UI).
    var isRelayed: Bool { localCandidateType == "relay" || remoteCandidateType == "relay" }

    static func parse(_ entries: [PeerStatsEntry]) -> PeerSessionStats {
        var stats = PeerSessionStats()
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Prefer transport.selectedCandidatePairId; fall back to the
        // nominated, succeeded pair.
        var pair: PeerStatsEntry?
        if let transport = entries.first(where: { $0.type == "transport" }),
           let pid = transport.values["selectedCandidatePairId"] as? String {
            pair = byID[pid]
        }
        if pair == nil {
            pair = entries.first {
                $0.type == "candidate-pair" && ($0.values["state"] as? String) == "succeeded"
                    && (bool($0.values["nominated"]) ?? false)
            }
        }
        if let pair {
            stats.selectedPairID = pair.id
            stats.selectedPairState = pair.values["state"] as? String
            stats.selectedPairNominated = bool(pair.values["nominated"])
            stats.currentRoundTripTime = double(pair.values["currentRoundTripTime"])
            stats.availableOutgoingBitrate = double(pair.values["availableOutgoingBitrate"])
            stats.bytesSent = uint(pair.values["bytesSent"])
            stats.bytesReceived = uint(pair.values["bytesReceived"])
            if let l = pair.values["localCandidateId"] as? String, let local = byID[l] {
                stats.localCandidateType = local.values["candidateType"] as? String
                stats.localProtocol = local.values["protocol"] as? String
                stats.localRelayProtocol = local.values["relayProtocol"] as? String
            }
            if let r = pair.values["remoteCandidateId"] as? String, let remote = byID[r] {
                stats.remoteCandidateType = remote.values["candidateType"] as? String
                stats.remoteRelayProtocol = remote.values["relayProtocol"] as? String
            }
        }
        for dc in entries where dc.type == "data-channel" {
            stats.dataChannelMessagesSent += uint(dc.values["messagesSent"])
            stats.dataChannelMessagesReceived += uint(dc.values["messagesReceived"])
            stats.dataChannelBytesSent += uint(dc.values["bytesSent"])
            stats.dataChannelBytesReceived += uint(dc.values["bytesReceived"])
        }
        return stats
    }

    private static func double(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let n = v as? NSNumber { return n.doubleValue }
        if let i = v as? Int { return Double(i) }
        return nil
    }

    private static func uint(_ v: Any?) -> UInt64 {
        if let n = v as? NSNumber { return n.uint64Value }
        if let u = v as? UInt64 { return u }
        if let i = v as? Int, i >= 0 { return UInt64(i) }
        if let d = v as? Double, d >= 0 { return UInt64(d) }
        return 0
    }

    private static func bool(_ v: Any?) -> Bool? {
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        return nil
    }
}
