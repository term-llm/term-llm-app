import Foundation

/// One authorized peer connection to a paired Hub: the single integration
/// object the app holds.  Everything derived from it (Hub transport, chat
/// bridge) shares its ``PeerAuthorizationState``; ``revoke()`` (or expiry,
/// channel loss, or a 401 from the node) tears all of it down.
final class PeerHubLink: @unchecked Sendable {
    let host: PeerPairedHost
    let authorization: PeerAuthorizationState
    let multiplexer: PeerHTTPMultiplexer
    private let statsProvider: @Sendable () async -> PeerSessionStats
    private let closeTransport: @Sendable () -> Void
    private let lock = NSLock()
    private var bridges: [PeerLoopbackBridge] = []

    /// Fired once on teardown with the reason (UI: show reconnect / re-pair).
    var onTeardown: (@Sendable (PeerWireError) -> Void)?

    init(host: PeerPairedHost, authorization: PeerAuthorizationState, multiplexer: PeerHTTPMultiplexer,
         stats: @escaping @Sendable () async -> PeerSessionStats, closeTransport: @escaping @Sendable () -> Void) {
        self.host = host
        self.authorization = authorization
        self.multiplexer = multiplexer
        self.statsProvider = stats
        self.closeTransport = closeTransport
        authorization.onRevoke { [weak self] in self?.teardown(.unauthorized("revoked")) }
        multiplexer.onClose = { [weak self] error in self?.teardown(error) }
    }

    var isActive: Bool { authorization.check() && !multiplexer.isClosed }

    /// Native Hub API over the peer channel:
    /// `HubClient(base_url: hubBaseURL, cookie_source: { [] }, transport: link.hubTransport(hubBaseURL:))`.
    func hubTransport(hubBaseURL: URL) -> WebRTCHubTransport {
        WebRTCHubTransport(forwarder: multiplexer, authorization: authorization, hubBaseURL: hubBaseURL)
    }

    /// Chat web UI: an owned, pair-only `http://localhost:<port>` bridge.  The
    /// caller installs `endpoint.capabilityCookie` (HttpOnly WK cookie) before
    /// loading `endpoint.url(forPath: <same Hub mount path>)`.
    /// `forwarder` may wrap ``multiplexer`` (DEBUG capture observation only);
    /// it must forward to this link's multiplexer, never another upstream.
    func makeChatBridge(listener: PeerLoopbackListening,
                        forwarder: PeerHTTPForwarding? = nil) throws -> PeerLoopbackBridge {
        guard authorization.check() else { throw PeerLoopbackBridgeError.unauthorized }
        let bridge = PeerLoopbackBridge(forwarder: forwarder ?? multiplexer, authorization: authorization,
                                        listener: listener)
        lock.withLock { bridges.append(bridge) }
        return bridge
    }

    func stats() async -> PeerSessionStats { await statsProvider() }

    func revoke() { authorization.revoke() }

    private func teardown(_ reason: PeerWireError) {
        let victims: [PeerLoopbackBridge]? = lock.withLock {
            if torn { return nil }
            torn = true
            let b = bridges
            bridges.removeAll()
            return b
        }
        guard let victims else { return }
        authorization.revoke()          // idempotent
        victims.forEach { $0.revoke() }
        multiplexer.close(reason)       // idempotent; fails open streams
        closeTransport()
        onTeardown?(reason)
    }

    private var torn = false
}
