import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// ``HubTransport`` that carries Hub API requests over an authorized
/// `term-llm-http-v1` peer channel instead of URLSession.
///
/// Preserves ``URLSessionHubTransport`` semantics:
/// * redirects are never followed (3xx is returned to the caller as-is);
/// * `onUnauthorized` is awaited at header time on 401/403, before the body —
///   EXCEPT a structured scope denial (403 + `X-Term-LLM-Peer-Error:
///   scope_denied`), which throws ``PeerScopeDenied`` and never purges;
/// * the request timeout bounds the whole exchange.
/// Additionally only requests for the configured Hub origin are forwarded
/// (origin-relative path + query on the wire, never a URL or host), bodies
/// are bounded, and revocation fails every request closed.
/// A route outside the peer grant (403 + `X-Term-LLM-Peer-Error: scope_denied`
/// from the core peer ingress).  Deliberately NOT a ``HubAPIError`` so existing
/// 401/403 auth-purge paths cannot treat it as revoked identity.
struct PeerScopeDenied: LocalizedError, Equatable, Sendable {
    static let headerName = "X-Term-LLM-Peer-Error"
    static let headerValue = "scope_denied"

    let path: String

    var errorDescription: String? {
        "This action is not available over the paired peer connection. Use the Hub in a browser for it."
    }

    static func matches(status: Int, header: PeerHeader) -> Bool {
        status == 403 && header.values(headerName).count == 1
            && header.first(headerName)?.trimmingCharacters(in: .whitespaces).lowercased() == headerValue
    }
}

final class WebRTCHubTransport: HubTransport, @unchecked Sendable {
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
            // Peer grants are route-scoped: the core ingress answers 403 with
            // `X-Term-LLM-Peer-Error: scope_denied` for routes the grant
            // excludes (security/registration).  That is a per-route error,
            // not identity loss: throw a non-HubAPIError so HubStore's auth
            // purge never sees it, and do not invoke onUnauthorized.  Every
            // other 401/403 keeps normal HubTransport purge semantics.
            if PeerScopeDenied.matches(status: response.status, header: response.header) {
                response.cancel()
                throw PeerScopeDenied(path: peerRequest.path)
            }
            if response.status == 401 || response.status == 403 {
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
        return PeerHTTPRequest(method: request.httpMethod ?? "GET", path: path, header: header,
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

    private struct Unchecked<T>: @unchecked Sendable { let value: T }

    static func withTimeout<T>(_ seconds: TimeInterval, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let boxed = try await withThrowingTaskGroup(of: Unchecked<T>.self) { group -> Unchecked<T> in
            group.addTask { Unchecked(value: try await body()) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                throw PeerWireError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw PeerWireError.timedOut }
            return first
        }
        return boxed.value
    }
}
