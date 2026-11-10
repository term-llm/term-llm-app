import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A peer route-scope denial. Core's peer bridge reserves 401 for the live
/// session gate (expired/revoked grant) and 403 for per-route authorization,
/// so a 403 must never purge the paired identity.
struct PeerScopeDenied: LocalizedError, Equatable, Sendable {
    static let headerName = "X-Term-LLM-Peer-Error"
    static let headerValue = "scope_denied"
    let path: String

    var errorDescription: String? {
        "This action is not available for a linked device. Manage it from the host's own browser."
    }
}

struct PeerAuthorizationLoss: Sendable {
    static let headerName = "X-Term-LLM-Peer-Error"
    static let headerValue = "authorization_revoked"
}

/// Carries native API requests over an authenticated `term-llm-http-v1`
/// DataChannel. Only the configured stable loopback origin is accepted; the
/// wire sees an origin-relative path, never a URL, cookie or owner token.
final class WebRTCHubTransport: HubTransport, Sendable {
    private let forwarder: PeerHTTPForwarding
    private let authorization: PeerAuthorizationState
    private let hubBaseURL: URL
    private let maxResponseBytes: Int

    init(forwarder: PeerHTTPForwarding, authorization: PeerAuthorizationState, hubBaseURL: URL,
         maxResponseBytes: Int = 8 * 1024 * 1024) {
        self.forwarder = forwarder
        self.authorization = authorization
        self.hubBaseURL = hubBaseURL
        self.maxResponseBytes = maxResponseBytes
    }

    func execute(
        _ request: URLRequest,
        onUnauthorized: (@Sendable () async -> Void)?
    ) async throws -> (Data, HTTPURLResponse) {
        guard authorization.check() else { throw PeerWireError.unauthorized("peer session revoked") }
        guard let url = request.url, Self.sameOrigin(url, hubBaseURL) else {
            throw PeerWireError.invalidRequest("request is not for the paired Hub origin")
        }
        guard request.httpBodyStream == nil else { throw PeerWireError.invalidRequest("streamed request bodies unsupported") }
        let peerRequest = try Self.peerRequest(from: request, url: url)
        let timeout = request.timeoutInterval > 0 ? request.timeoutInterval : HubClient.defaultTimeout
        let maxBytes = maxResponseBytes

        return try await Self.withTimeout(timeout) { [forwarder, authorization] in
            let response = try await forwarder.forward(peerRequest, headTimeout: timeout)
            let http = try Self.httpResponse(url: url, response: response)
            // Core's peer bridge reserves 401 for SessionGate (grant gone)
            // and 403 for Authorize (route outside web-v1). A denied route is
            // not identity loss and must not trigger HubStore's auth purge.
            if response.status == 403 {
                response.cancel()
                throw PeerScopeDenied(path: peerRequest.path)
            }
            if response.status == 401 {
                await onUnauthorized?()
            }
            guard response.status == 401 else {
                return (try await response.collect(limit: maxBytes), http)
            }
            // The peer ingress answers 401 only for an expired/revoked grant:
            // after handing HubClient the small error body, tear down the
            // whole link (bridges, streams).  Revoke even if the body fails.
            defer { authorization.revoke() }
            let data = (try? await response.collect(limit: 64 * 1024)) ?? Data()
            return (data, http)
        }
    }

    // MARK: Helpers (internal for tests)

    static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        func port(_ u: URL) -> Int? { u.port ?? (u.scheme?.lowercased() == "http" ? 80 : u.scheme?.lowercased() == "https" ? 443 : nil) }
        return a.scheme?.lowercased() == b.scheme?.lowercased()
            && a.host?.lowercased() == b.host?.lowercased()
            && port(a) == port(b) && port(a) != nil
            && a.user == nil && a.password == nil
    }

    static func peerRequest(from request: URLRequest, url: URL) throws -> PeerHTTPRequest {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw PeerWireError.invalidRequest("url")
        }
        var path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if let query = components.percentEncodedQuery { path += "?" + query }
        var header = PeerHeader()
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            let canonical = PeerHeader.canonical(name)
            if PeerHeaderFilter.hopByHop.contains(canonical) || canonical == "Host" || canonical == "Content-Length" { continue }
            header.add(name, value)
        }
        let sanitized = PeerHeaderFilter.outbound(header, policy: .isolate, upstreamOrigin: nil)
        return PeerHTTPRequest(method: request.httpMethod ?? "GET", path: path, header: sanitized,
                               body: request.httpBody ?? Data())
    }

    static func httpResponse(url: URL, response: PeerHTTPResponse) throws -> HTTPURLResponse {
        var fields: [String: String] = [:]
        for name in response.header.names {
            // Same folding Foundation applies to repeated headers.
            fields[name] = response.header.values(name).joined(separator: ", ")
        }
        guard let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: fields) else {
            throw HubAPIError(status: 0, message: "Hub returned a non-HTTP response.")
        }
        return http
    }

    static func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                throw PeerWireError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw PeerWireError.timedOut }
            return first
        }
    }
}
