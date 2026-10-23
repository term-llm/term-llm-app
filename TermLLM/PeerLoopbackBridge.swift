import Foundation
#if canImport(WebKit)
import WebKit
#endif

/// Accepts loopback TCP connections.  Production: ``PeerNWLoopbackListener``
/// (Network.framework, loopback only: 127.0.0.1 + ::1 on one port).  Tests inject in-memory.
protocol PeerLoopbackListening: AnyObject {
    /// Starts listening on loopback and returns the bound port.
    func start(onConnection: @escaping @Sendable (PeerByteStream) -> Void) async throws -> UInt16
    func stop()
}

/// What the WebView integration needs: the loopback base URL plus the local
/// capability cookie.  The capability is independent of every remote/master
/// token and never appears in a URL.
struct PeerLoopbackEndpoint: Sendable, Equatable {
    let port: UInt16
    let cookieName: String
    let capability: String
    let scopePrefix: String

    var origin: String { "http://\(PeerLoopbackGate.hostname):\(port)" }
    var baseURL: URL { URL(string: origin + "/")! }

    /// Loopback URL for an origin-relative node path (`/chat/?new=1`).
    /// Returns nil for anything that is not a safe in-scope path.
    func url(forPath path: String) -> URL? {
        guard PeerHTTPRequest.isValidPath(path) else { return nil }
        let bare = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        guard PeerLoopbackGate.isWithinScope(bare, scopePrefix) else { return nil }
        return URL(string: origin + path)
    }

    /// True if `url` belongs to this bridge (navigation-policy helper).
    func owns(_ url: URL) -> Bool {
        url.scheme == "http" && url.host?.lowercased() == PeerLoopbackGate.hostname
            && url.port.map(UInt16.init) == port && url.user == nil && url.password == nil
    }
}

enum PeerLoopbackBridgeError: Error, Equatable {
    case unauthorized
    case alreadyStarted
    case revoked
}

/// One loopback HTTP bridge per authorized peer session (scoped: own port,
/// own capability, own path scope).  `revoke()` — or authorization
/// expiry/revocation, or channel loss — stops the listener, closes every
/// connection and cancels in-flight remote streams.
final class PeerLoopbackBridge: @unchecked Sendable {
    private let forwarder: PeerHTTPForwarding
    private let authorization: PeerAuthorizationState
    private let listener: PeerLoopbackListening
    private let cookiePolicy: PeerCookiePolicy
    private let upstreamOrigin: String?
    private let maxConnections: Int
    private let headTimeout: TimeInterval
    private let limits: PeerWireLimits
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: PeerLoopbackConnection] = [:]
    private var endpoint: PeerLoopbackEndpoint?
    private var state: State = .idle
    private var revokeToken: UUID?

    private enum State { case idle, starting, running, revoked }

    /// Fired once after teardown (e.g. remove cookie, show reconnect UI).
    var onTeardown: (@Sendable () -> Void)?

    init(forwarder: PeerHTTPForwarding,
         authorization: PeerAuthorizationState,
         listener: PeerLoopbackListening,
         cookiePolicy: PeerCookiePolicy = .isolate,
         upstreamOrigin: String? = nil,
         maxConnections: Int = 16,
         headTimeout: TimeInterval = 30,
         limits: PeerWireLimits = .default) {
        self.forwarder = forwarder
        self.authorization = authorization
        self.listener = listener
        self.cookiePolicy = cookiePolicy
        self.upstreamOrigin = upstreamOrigin
        self.maxConnections = maxConnections
        self.headTimeout = headTimeout
        self.limits = limits
    }

    var currentEndpoint: PeerLoopbackEndpoint? { lock.withLock { endpoint } }
    var connectionCount: Int { lock.withLock { connections.count } }

    func start() async throws -> PeerLoopbackEndpoint {
        guard authorization.check(), let auth = authorization.current else { throw PeerLoopbackBridgeError.unauthorized }
        try lock.withLock {
            switch state {
            case .idle: state = .starting
            case .revoked: throw PeerLoopbackBridgeError.revoked
            case .starting, .running: throw PeerLoopbackBridgeError.alreadyStarted
            }
        }
        let capability = Self.makeCapability()
        let port: UInt16
        do {
            port = try await listener.start { [weak self] stream in self?.accept(stream) ?? stream.close() }
        } catch {
            lock.withLock { state = .idle }
            throw error
        }
        let ep = PeerLoopbackEndpoint(port: port, cookieName: "\(PeerLoopbackGate.cookiePrefix)\(port)",
                                      capability: capability, scopePrefix: auth.scopePrefix)
        let stillWanted: Bool = lock.withLock {
            guard state == .starting else { return false }
            state = .running
            endpoint = ep
            return true
        }
        guard stillWanted else { listener.stop(); throw PeerLoopbackBridgeError.revoked }
        revokeToken = authorization.onRevoke { [weak self] in self?.revoke() }
        return ep
    }

    func revoke() {
        let victims: [PeerLoopbackConnection]? = lock.withLock {
            if state == .revoked { return nil }
            state = .revoked
            endpoint = nil
            let v = Array(connections.values)
            connections.removeAll()
            return v
        }
        guard let victims else { return }
        listener.stop()
        victims.forEach { $0.close() }
        if let token = revokeToken { authorization.removeHandler(token) }
        onTeardown?()
    }

    private func accept(_ stream: PeerByteStream) {
        let (connection, accepted): (PeerLoopbackConnection?, Bool) = lock.withLock {
            guard state == .running, let ep = endpoint, connections.count < maxConnections else { return (nil, false) }
            let gate = PeerLoopbackGate(port: ep.port, capability: ep.capability, scopePrefix: ep.scopePrefix)
            let config = PeerLoopbackConnection.Configuration(
                gate: gate, cookiePolicy: cookiePolicy, upstreamOrigin: upstreamOrigin,
                headTimeout: headTimeout, limits: limits)
            let authorization = self.authorization
            let c = PeerLoopbackConnection(stream: stream, forwarder: forwarder, configuration: config,
                                           isAuthorized: { authorization.check() })
            connections[ObjectIdentifier(c)] = c
            return (c, true)
        }
        guard accepted, let connection else { stream.close(); return }
        Task { [weak self] in
            await connection.serve()
            _ = self?.lock.withLock { self?.connections.removeValue(forKey: ObjectIdentifier(connection)) }
        }
    }

    /// 256-bit random, base64url (cookie-safe, no padding).
    static func makeCapability() -> String {
        var rng = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max, using: &rng) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

#if canImport(WebKit)
extension PeerLoopbackEndpoint {
    /// Host-only, HttpOnly, SameSite=Strict session cookie for `localhost`.
    /// The capability travels only in this WebKit cookie, never in a URL.
    var capabilityCookie: HTTPCookie? {
        HTTPCookie(properties: [
            .name: cookieName,
            .value: capability,
            .domain: PeerLoopbackGate.hostname,
            .path: "/",
            .discard: "TRUE",
            HTTPCookiePropertyKey("HttpOnly"): "TRUE",
            .sameSitePolicy: HTTPCookieStringPolicy.sameSiteStrict,
        ])
    }

    /// Install the capability before the first navigation to `baseURL`.
    @MainActor
    func installCapability(in store: WKHTTPCookieStore) async {
        guard let cookie = capabilityCookie else { return }
        await store.setCookie(cookie)
    }

    /// Remove this bridge's capability (call on teardown/revoke).
    @MainActor
    func removeCapability(from store: WKHTTPCookieStore) async {
        let cookies = await store.allCookies()
        for cookie in cookies where cookie.domain == PeerLoopbackGate.hostname && cookie.name == cookieName {
            await store.deleteCookie(cookie)
        }
    }
}
#endif
