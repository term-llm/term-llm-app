#if canImport(WebRTC)
import Foundation
import WebRTC

/// ``PeerOffering`` backed by a native libwebrtc session (offerer role).
final class PeerWebRTCOffering: PeerOffering, @unchecked Sendable {
    let session: PeerWebRTCSession
    init(session: PeerWebRTCSession) { self.session = session }
    func makeOffer() async throws -> String { try await session.createOffer().sdp }
}

/// Entry points the app calls.  No path here yields a link without a
/// verified pair/reconnect answer: the ``PeerAuthorizationState`` is created
/// from ``PeerPairingOutcome`` only.
enum PeerHubConnector {
    /// Public STUN for direct/reflexive candidates when the broker cannot
    /// mint TURN.  Relay needs broker-minted (e.g. Cloudflare) TURN.
    static let defaultICEServers = [PeerICEServer(urls: ["stun:stun.cloudflare.com:3478"])]

    struct Options: Sendable {
        /// nil: ask the broker to mint TURN, falling back to STUN only.
        var iceServers: [PeerICEServer]?
        /// Force TURN relay (test forced-relay path; requires TURN servers).
        var relayOnly = false
        var channelOpenTimeout: TimeInterval = 20
        var limits: PeerWireLimits = .default
        init(iceServers: [PeerICEServer]? = nil, relayOnly: Bool = false) {
            self.iceServers = iceServers
            self.relayOnly = relayOnly
        }
    }

    /// QR pairing: requires terminal approval on the host.
    static func pair(link: PeerPairingLink, deviceName: String, store: PeerIdentityStore,
                     options: Options = Options()) async throws -> PeerHubLink {
        guard !link.isExpired() else { throw PeerPairingError.expired }
        let broker = try PeerBrokerClient(baseURL: link.broker)
        let mailbox = PeerBrokerClient.Mailbox(sessionID: link.sessionIDString, capability: link.deviceCapability)
        let ice = try await iceServers(options, broker: broker, mailbox: mailbox)
        let session = try PeerWebRTCSession(iceServers: ice, relayOnly: options.relayOnly)
        do {
            let outcome = try await PeerPairingCoordinator(store: store)
                .pair(link: link, deviceName: deviceName, offering: PeerWebRTCOffering(session: session))
            return try await connect(session: session, outcome: outcome, options: options)
        } catch {
            session.close()
            throw error
        }
    }

    /// PILOT reconnect: only while a broker mailbox for this host is alive
    /// (≤ 30 min).  `mailbox` must come from an authenticated source; there
    /// is no fresh discovery yet.
    static func reconnect(host: PeerPairedHost, mailbox: PeerBrokerClient.Mailbox, store: PeerIdentityStore,
                          options: Options = Options()) async throws -> PeerHubLink {
        guard let url = URL(string: host.brokerURL) else { throw PeerPairingError.broker("broker URL") }
        let broker = try PeerBrokerClient(baseURL: url)
        let ice = try await iceServers(options, broker: broker, mailbox: mailbox)
        let session = try PeerWebRTCSession(iceServers: ice, relayOnly: options.relayOnly)
        do {
            let outcome = try await PeerPairingCoordinator(store: store)
                .reconnect(host: host, mailbox: mailbox, offering: PeerWebRTCOffering(session: session))
            return try await connect(session: session, outcome: outcome, options: options)
        } catch {
            session.close()
            throw error
        }
    }

    private static func iceServers(_ options: Options, broker: PeerBrokerClient,
                                   mailbox: PeerBrokerClient.Mailbox) async throws -> [PeerICEServer] {
        if let explicit = options.iceServers { return explicit }
        if let minted = try? await broker.mintICEServers(mailbox) { return minted }
        if options.relayOnly { throw PeerBrokerClient.Failure.turnUnavailable }
        return defaultICEServers
    }

    private static func connect(session: PeerWebRTCSession, outcome: PeerPairingOutcome,
                                options: Options) async throws -> PeerHubLink {
        let authorization = PeerAuthorizationState(outcome.authorization)
        try await session.acceptVerifiedAnswer(outcome.answerSDP, authorization: authorization)
        let channel = try await WebRTCHubTransport.withTimeout(options.channelOpenTimeout) {
            Unchecked(try await session.openChannel())
        }.value
        let mux = PeerHTTPMultiplexer(channel: channel, limits: options.limits)
        let link = PeerHubLink(host: outcome.host, authorization: authorization, multiplexer: mux,
                               stats: { await session.stats() }, closeTransport: { session.close() })
        session.onClose = { [weak link] in link?.revoke() }
        return link
    }

    private struct Unchecked<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }
}
#endif
