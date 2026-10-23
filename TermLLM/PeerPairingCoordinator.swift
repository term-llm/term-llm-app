import Foundation

/// Produces the complete (non-trickle, ICE-gathered) local offer SDP.
/// Implemented by the libwebrtc session; tests inject fixed SDP.
protocol PeerOffering: AnyObject, Sendable {
    func makeOffer() async throws -> String
}

/// Outcome of a verified pairing or reconnect.  `authorization` exists ONLY
/// here: it is minted after MAC/signature/pinned-host-key verification.
struct PeerPairingOutcome: Sendable {
    let host: PeerPairedHost
    /// Exact verified answer SDP to hand to WebRTC.
    let answerSDP: String
    let authorization: PeerAuthorization
}

/// Device-side signalling over the authenticated broker mailbox.
///
/// * Initial pairing: QR link (secret + device capability in fragment) →
///   MACed+signed `pair_request` → wait for host terminal approval →
///   verify `pair_answer` → persist `{hk, grant_id}` → outcome.
/// * Reconnect (PILOT): only while a broker mailbox for this host is alive
///   (≤ 30 min); there is no fresh authenticated discovery yet, so the caller
///   must supply a live mailbox.  Signatures only, no pairing secret.
final class PeerPairingCoordinator: @unchecked Sendable {
    private let store: PeerIdentityStore
    private let brokerFactory: @Sendable (URL) throws -> PeerBrokerClient
    private let clock: @Sendable () -> Date
    /// Upper bound of one connected session's authorization (always also
    /// bounded by the grant expiry).
    let sessionLifetime: TimeInterval
    let pollWait: TimeInterval
    static let maxMessagesPerExchange = 32

    init(store: PeerIdentityStore,
         brokerFactory: @escaping @Sendable (URL) throws -> PeerBrokerClient = { try PeerBrokerClient(baseURL: $0) },
         clock: @escaping @Sendable () -> Date = { Date() },
         sessionLifetime: TimeInterval = 12 * 3600,
         pollWait: TimeInterval = 25) {
        self.store = store
        self.brokerFactory = brokerFactory
        self.clock = clock
        self.sessionLifetime = sessionLifetime
        self.pollWait = pollWait
    }

    // MARK: Initial pairing

    func pair(link: PeerPairingLink, deviceName: String, offering: PeerOffering,
              approvalTimeout: TimeInterval = 300) async throws -> PeerPairingOutcome {
        guard !link.isExpired(at: clock()) else { throw PeerPairingError.expired }
        let identity = try store.deviceIdentity()
        let broker = try brokerFactory(link.broker)
        let mailbox = PeerBrokerClient.Mailbox(sessionID: link.sessionIDString, capability: link.deviceCapability)

        let offer = try await offering.makeOffer()
        let attempt = try PeerPairingAttempt(link: link, identity: identity, deviceName: deviceName,
                                             offerSDP: offer, now: clock())
        try await mapBroker(link: link) { _ = try await broker.send(mailbox, body: try PeerPairingMessage.encode(attempt.request)) }

        let deadline = clock().addingTimeInterval(approvalTimeout)
        let verified: PeerVerifiedPairing = try await mapBroker(link: link) {
            try await self.await(broker, mailbox, deadline: deadline) { message in
                switch message {
                case .pairAnswer(let answer): return try attempt.verify(answer)  // fail closed on any mismatch
                case .pairReject(let reject): throw PeerPairingError.rejected(Self.safeReason(reject.reason))
                default: return nil
                }
            }
        }
        // Do NOT delete the broker session: the PSK is one-use, but the shared
        // rendezvous stays alive (until expiry/owner close) for host
        // signalling and same-live-mailbox reconnect.

        let now = clock()
        let host = PeerPairedHost(hostKey: verified.hostKey, grantID: verified.grantID,
                                  grantExpiresAt: verified.grantExpiresAt, brokerURL: link.broker.absoluteString,
                                  name: link.name, pairedAt: now)
        if host.isExpired(at: now) { throw PeerPairingError.expired }
        try store.save(host)
        return PeerPairingOutcome(host: host, answerSDP: verified.answerSDP, authorization: authorization(for: host, now: now))
    }

    // MARK: Reconnect (pilot: live mailbox only)

    func reconnect(host: PeerPairedHost, mailbox: PeerBrokerClient.Mailbox, offering: PeerOffering,
                   timeout: TimeInterval = 60) async throws -> PeerPairingOutcome {
        guard !host.isExpired(at: clock()) else { throw PeerPairingError.expired }
        guard let brokerURL = URL(string: host.brokerURL) else { throw PeerPairingError.broker("broker URL") }
        let identity = try store.deviceIdentity()
        let broker = try brokerFactory(brokerURL)
        // Gather first: challenges are short-lived.
        let offer = try await offering.makeOffer()
        let deadline = clock().addingTimeInterval(timeout)

        _ = try await broker.send(mailbox, body: try PeerPairingMessage.encode(
            PeerReconnectAttempt.hello(identity: identity, grantID: host.grantID)))
        let challenge: PeerReconnectChallenge = try await self.await(broker, mailbox, deadline: deadline) { message in
            if case .reconnectChallenge(let c) = message { return c }
            return nil
        }
        let attempt = try PeerReconnectAttempt(challenge: challenge, pinnedHostKey: host.hostKey, identity: identity,
                                               grantID: host.grantID, offerSDP: offer, now: clock())
        _ = try await broker.send(mailbox, body: try PeerPairingMessage.encode(attempt.request))
        let answerSDP: String = try await self.await(broker, mailbox, deadline: deadline) { message in
            if case .reconnectAnswer(let a) = message { return try attempt.verify(a) }
            return nil
        }
        return PeerPairingOutcome(host: host, answerSDP: answerSDP, authorization: authorization(for: host, now: clock()))
    }

    // MARK: Internals

    private func authorization(for host: PeerPairedHost, now: Date) -> PeerAuthorization {
        var expiry = now.addingTimeInterval(sessionLifetime)
        if let grant = host.grantExpiresAt { expiry = min(expiry, grant) }
        return PeerAuthorization(peerID: host.id, sessionID: PeerBase64URL.encode(PeerRandom.bytes(16)),
                                 expiresAt: expiry, scopePrefix: "/")
    }

    /// Long-polls until `handle` returns a value, acking as it goes.
    private func await<T>(_ broker: PeerBrokerClient, _ mailbox: PeerBrokerClient.Mailbox, deadline: Date,
                          _ handle: (PeerPairingMessage) throws -> T?) async throws -> T {
        var after: UInt64 = 0
        var seen = 0
        while true {
            try Task.checkCancellation()
            let remaining = deadline.timeIntervalSince(clock())
            guard remaining > 0 else { throw PeerPairingError.timedOut }
            let messages = try await broker.receive(mailbox, after: after, wait: min(pollWait, remaining))
            for m in messages.sorted(by: { $0.seq < $1.seq }) where m.seq > after {  // broker seq starts at 1
                after = max(after, m.seq)
                seen += 1
                guard seen <= Self.maxMessagesPerExchange else { throw PeerPairingError.invalid("too many messages") }
                if let value = try handle(try PeerPairingMessage.decode(m.body)) { return value }
            }
        }
    }

    private func mapBroker<T>(link: PeerPairingLink, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch PeerBrokerClient.Failure.unauthorized, PeerBrokerClient.Failure.closed {
            // Expired/consumed rendezvous looks identical to a bad capability.
            throw link.isExpired(at: clock()) ? PeerPairingError.expired : PeerPairingError.broker("pairing session is no longer available")
        }
    }

    /// The reject reason is unauthenticated: only known tokens are shown.
    static func safeReason(_ reason: String) -> String {
        ["denied", "expired", "invalid"].contains(reason) ? reason : "invalid"
    }
}
