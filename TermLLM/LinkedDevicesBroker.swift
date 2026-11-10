import Foundation

struct PeerICEServer: Codable, Sendable, Equatable, CustomStringConvertible {
    let urls: [String]
    let username: String?
    let credential: String?
    var description: String { "PeerICEServer(urls: \(urls), credential: \(credential == nil ? "none" : "[REDACTED]"))" }
}

struct LinkedDevicesICECredentials: Codable, Sendable, Equatable {
    let iceServers: [PeerICEServer]
    let expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case iceServers = "ice_servers"
        case expiresAt = "expires_at"
    }
}

enum PeerBrokerAddress {
    static func isLoopback(_ rawHost: String) -> Bool {
        var host = rawHost.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host == "localhost" { return true }
        if host == "::1" { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let first = Int(parts[0]), first == 127,
              parts.allSatisfy({ value in
                  guard value.count == 1 || value.first != "0", let number = Int(value) else { return false }
                  return (0...255).contains(number)
              }) else { return false }
        return true
    }
}

enum LinkedDevicesBrokerError: Error, Equatable, LocalizedError {
    case invalidAddress
    case unauthorized
    case notFound
    case expired
    case peerOffline
    case superseded
    case brokerClosed
    case rateLimited
    case quotaExceeded
    case badRequest
    case tooLarge
    case malformed
    case closed(Int, String)
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidAddress: "The rendezvous address is invalid."
        case .unauthorized: "Access was revoked or the linked target was reset."
        case .notFound, .peerOffline: "The linked host is offline."
        case .expired: "The host rendezvous lease or invitation expired."
        case .superseded: "A newer connection replaced this one."
        case .brokerClosed: "The rendezvous service is temporarily unavailable."
        case .rateLimited: "The rendezvous service rate limit was reached."
        case .quotaExceeded: "The rendezvous service quota was reached."
        case .badRequest: "The rendezvous request was rejected."
        case .tooLarge: "The rendezvous message was too large."
        case .malformed: "The rendezvous service returned invalid data."
        case .closed(_, _): "The rendezvous connection closed."
        case .http(let status, _): "The rendezvous service returned HTTP \(status)."
        }
    }
}

struct LinkedDevicesBrokerFrame: Codable, Equatable, Sendable {
    let type: String
    var peerID: String?
    var peerKind: String?
    var body: JSONValue?
    var role: String?
    var peerConnected: Bool?
    var leaseExpiresAt: String?
    var error: String?

    enum CodingKeys: String, CodingKey {
        case type
        case peerID = "peer_id"
        case peerKind = "peer_kind"
        case body, role
        case peerConnected = "peer_connected"
        case leaseExpiresAt = "lease_expires_at"
        case error
    }

    static func signal<T: Encodable>(_ value: T) throws -> Self {
        let data = try LinkedDevicesMessageCodec.encode(value)
        return Self(type: "signal", body: try JSONValue.decode(data))
    }

    func decodeBody<T: Decodable>(_ type: T.Type, expectedType: String, fields: Set<String>) throws -> T {
        guard self.type == "signal", let body else { throw LinkedDevicesBrokerError.malformed }
        return try LinkedDevicesMessageCodec.decode(type, data: body.encoded(), expectedType: expectedType, fields: fields)
    }
}

final class LinkedDevicesBrokerClient: Sendable {
    static let maxResponseBytes = 1 * 1024 * 1024
    let baseURL: URL
    private let session: URLSession

    init(baseURL: URL) throws {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), let host = components.host?.lowercased(),
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              scheme == "https" || (scheme == "http" && PeerBrokerAddress.isLoopback(host)) else {
            throw LinkedDevicesBrokerError.invalidAddress
        }
        components.scheme = scheme
        components.host = host
        while components.path.hasSuffix("/") { components.path.removeLast() }
        guard let normalized = components.url else { throw LinkedDevicesBrokerError.invalidAddress }
        self.baseURL = normalized
        let configuration = IsolatedURLSession.configuration {
            $0.timeoutIntervalForRequest = 20
            $0.timeoutIntervalForResource = 25
        }
        session = URLSession(configuration: configuration, delegate: RejectAllRedirects(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func ice(hostID: String, kind: String, peerID: String, capability: String) async throws -> LinkedDevicesICECredentials {
        var query = URLComponents()
        query.queryItems = [URLQueryItem(name: kind, value: peerID)]
        let suffix = "/v2/hosts/\(hostID)/ice?" + (query.percentEncodedQuery ?? "")
        let data = try await get(suffix, capability: capability)
        do {
            let value = try JSONDecoder().decode(LinkedDevicesICECredentials.self, from: data)
            return try Self.validateICE(value)
        } catch let error as LinkedDevicesBrokerError { throw error }
        catch { throw LinkedDevicesBrokerError.malformed }
    }

    static func validateICE(_ value: LinkedDevicesICECredentials) throws -> LinkedDevicesICECredentials {
        guard value.iceServers.count <= 16,
              value.iceServers.allSatisfy({ !$0.urls.isEmpty && $0.urls.count <= 8 }) else {
            throw LinkedDevicesBrokerError.malformed
        }
        return value
    }

    func dial(hostID: String, kind: String, peerID: String, capability: String) async throws -> LinkedDevicesBrokerSocket {
        guard hostID.utf8.count == 43, !peerID.isEmpty, peerID.utf8.count <= 64,
              ["invitation", "device"].contains(kind) else { throw LinkedDevicesBrokerError.invalidAddress }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path += "/v2/hosts/\(hostID)/ws"
        components.queryItems = [URLQueryItem(name: kind, value: peerID)]
        guard let url = components.url else { throw LinkedDevicesBrokerError.invalidAddress }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Bearer \(capability)", forHTTPHeaderField: "Authorization")
        request.setValue("peerbroker.v2", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        request.httpShouldHandleCookies = false
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = LinkedDevicesWire.maxBrokerFrameBytes
        task.resume()
        let socket = LinkedDevicesBrokerSocket(task: task)
        let ready = try await socket.receive()
        guard ready.type == "ready", ready.role == kind, ready.peerID == peerID,
              ready.peerKind == kind else {
            socket.close()
            throw LinkedDevicesBrokerError.malformed
        }
        return socket
    }

    private func get(_ suffix: String, capability: String) async throws -> Data {
        guard let url = URL(string: baseURL.absoluteString + suffix) else { throw LinkedDevicesBrokerError.invalidAddress }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Bearer \(capability)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.url == url else { throw LinkedDevicesBrokerError.malformed }
        guard data.count <= Self.maxResponseBytes else { throw LinkedDevicesBrokerError.tooLarge }
        guard http.statusCode == 200 else { throw Self.apiError(status: http.statusCode, data: data) }
        return data
    }

    static func apiError(status: Int, data: Data) -> LinkedDevicesBrokerError {
        let value = (try? JSONValue.decode(Data(data.prefix(4096))))?.objectValue
        let code = value?["error"]?.stringValue ?? "http_\(status)"
        switch code {
        case "unauthorized": return .unauthorized
        case "not_found": return .notFound
        case "expired": return .expired
        case "peer_offline": return .peerOffline
        case "rate_limited", "queue_full": return .rateLimited
        case "quota_exceeded": return .quotaExceeded
        case "bad_request": return .badRequest
        case "too_large": return .tooLarge
        default: return .http(status, String(code.prefix(64)))
        }
    }
}

// Sendability: URLSessionWebSocketTask supplies thread-safe I/O/cancellation;
// lock protects our close-once flag. Callers use one receive loop per socket;
// frames/encoders are local values and no mutable message state is shared.
final class LinkedDevicesBrokerSocket: @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let lock = NSLock()
    private var isClosed = false

    init(task: URLSessionWebSocketTask) { self.task = task }

    func send<T: Encodable>(_ value: T) async throws {
        let frame = try LinkedDevicesBrokerFrame.signal(value)
        let data = try JSONEncoder().encode(frame)
        guard data.count <= LinkedDevicesWire.maxBrokerFrameBytes else { throw LinkedDevicesBrokerError.tooLarge }
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    func receive() async throws -> LinkedDevicesBrokerFrame {
        let message: URLSessionWebSocketTask.Message
        do {
            message = try await withTaskCancellationHandler(operation: {
                try await task.receive()
            }, onCancel: { [task] in
                task.cancel(with: .goingAway, reason: nil)
            })
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            let code = task.closeCode.rawValue
            let reason = task.closeReason.map { String(decoding: $0.prefix(128), as: UTF8.self) } ?? ""
            switch code {
            case 4001: throw LinkedDevicesBrokerError.superseded
            case 4002: throw LinkedDevicesBrokerError.expired
            case 4003: throw LinkedDevicesBrokerError.brokerClosed
            case 4004: throw LinkedDevicesBrokerError.rateLimited
            case 4005: throw LinkedDevicesBrokerError.quotaExceeded
            case 4006: throw LinkedDevicesBrokerError.badRequest
            case 1009: throw LinkedDevicesBrokerError.tooLarge
            default: throw LinkedDevicesBrokerError.closed(code, reason)
            }
        }
        let data: Data
        switch message {
        case .data(let value): data = value
        case .string(let value): data = Data(value.utf8)
        @unknown default: throw LinkedDevicesBrokerError.malformed
        }
        guard data.count <= LinkedDevicesWire.maxBrokerFrameBytes,
              let frame = try? JSONDecoder().decode(LinkedDevicesBrokerFrame.self, from: data) else {
            throw LinkedDevicesBrokerError.malformed
        }
        if frame.type == "error" { throw LinkedDevicesBrokerClient.apiError(status: 0, data: data) }
        return frame
    }

    func close() {
        let close = lock.withLock { if isClosed { return false }; isClosed = true; return true }
        if close { task.cancel(with: .normalClosure, reason: nil) }
    }

    deinit { close() }
}
