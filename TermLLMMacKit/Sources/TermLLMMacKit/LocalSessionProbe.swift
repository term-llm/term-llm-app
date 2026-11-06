import Foundation

/// Proves the app's local credential is actually accepted by the running
/// service before the UI claims a usable authenticated chat. Uses the real
/// HTTP endpoint with the bearer header; the token never enters a URL.
public enum LocalSessionProbe {
    public enum Outcome: Equatable, Sendable {
        case authenticated
        case unauthorized(Int)
        case unreachable(String)
        case unexpected(Int)

        public var isAuthenticated: Bool { self == .authenticated }

        public var description: String {
            switch self {
            case .authenticated: return "Authentication accepted by the local service."
            case .unauthorized(let status): return "The local service rejected the stored credential (HTTP \(status))."
            case .unreachable(let reason): return "Could not reach the local service: \(reason)"
            case .unexpected(let status): return "The local service returned an unexpected status (HTTP \(status))."
            }
        }
    }

    public static func probe(endpoint: ManagedLoopbackEndpoint,
                             token: String,
                             session: URLSession = .shared) async -> Outcome {
        var request = URLRequest(url: endpoint.baseURL.appendingPathComponent("api/auth/session"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 6
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .unreachable("the response was not HTTP")
            }
            if (200..<300).contains(http.statusCode) {
                _ = data
                return .authenticated
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                return .unauthorized(http.statusCode)
            }
            return .unexpected(http.statusCode)
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }
}
