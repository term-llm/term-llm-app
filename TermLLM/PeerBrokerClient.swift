import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// ICE/TURN server (RTCIceServer dictionary).  Short-lived TURN credentials
/// come from the authenticated broker; never logged.
struct PeerICEServer: Codable, Sendable, Equatable, CustomStringConvertible {
    var urls: [String]
    var username: String?
    var credential: String?

    var description: String { "PeerICEServer(urls: \(urls), credential: \(credential == nil ? "none" : "[REDACTED]"))" }
}

struct PeerBrokerMessage: Codable, Equatable, Sendable {
    let seq: UInt64
    /// Opaque JSON body exactly as relayed.
    let body: Data

    init(seq: UInt64, body: Data) {
        self.seq = seq
        self.body = body
    }
}

/// Minimal HTTP seam so tests can exercise the client without a network.
protocol PeerBrokerHTTP: Sendable {
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Ephemeral, cookie-free, credential-cache-free URLSession; redirects refused.
struct PeerURLSessionBrokerHTTP: PeerBrokerHTTP {
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PeerPairingError.broker("non-HTTP response") }
        return (data, http)
    }
}

/// Client for the term-llm peer broker (`internal/peerbroker`):
///
///     POST   /v1/sessions/{id}/messages        {"body": <json>} -> {"seq":N}
///     GET    /v1/sessions/{id}/messages?after=N&wait=S -> {"messages":[{"seq","body"}]}
///     DELETE /v1/sessions/{id}
///     POST   /v1/sessions/{id}/turn            -> {"ice_servers":[...],"expires_at":..}
///
/// The capability is sent only as `Authorization: Bearer`, never in a URL.
/// The broker sees opaque, already-authenticated pairing messages only.
final class PeerBrokerClient: @unchecked Sendable {
    struct Mailbox: Sendable, Equatable, CustomStringConvertible {
        let sessionID: String
        let capability: String
        var description: String { "Mailbox(\(sessionID), cap: [REDACTED])" }
    }

    enum Failure: Error, Equatable {
        /// Unknown/expired/closed session or bad capability (401) / closed (410).
        case unauthorized
        case closed
        case rateLimited
        case tooLarge
        case turnUnavailable
        case http(Int, String)
    }

    let baseURL: URL
    private let http: PeerBrokerHTTP
    static let maxResponseBytes = 1 << 20

    init(baseURL: URL, http: PeerBrokerHTTP = PeerURLSessionBrokerHTTP()) throws {
        guard let scheme = baseURL.scheme?.lowercased(), let host = baseURL.host,
              baseURL.user == nil, baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil,
              scheme == "https" || (scheme == "http" && Self.isLoopbackHost(host)) else {
            throw PeerPairingError.broker("broker URL must be https (http only for loopback)")
        }
        var s = baseURL.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        guard let normalized = URL(string: s) else { throw PeerPairingError.broker("broker URL") }
        self.baseURL = normalized
        self.http = http
    }

    /// Matches Go `peerbroker.isLoopbackHost`: exactly `localhost`
    /// (ASCII case-insensitive) or a host that PARSES as a loopback IP
    /// (127.0.0.0/8, ::1, ::ffff:127.0.0.0/104).  Never a lexical prefix test:
    /// `127.attacker.example`, `127.0.0.1.evil`, `localhost.evil`, Unicode
    /// look-alikes, zone IDs and leading-zero/short IPv4 forms are rejected.
    static func isLoopbackHost(_ host: String) -> Bool {
        var h = host
        if h.hasPrefix("["), h.hasSuffix("]"), h.count >= 2 { h = String(h.dropFirst().dropLast()) }
        guard !h.isEmpty, h.utf8.allSatisfy({ $0 < 0x80 }) else { return false }
        if h.utf8.count == 9, h.lowercased() == "localhost" { return true }
        if let v4 = parseIPv4(h) { return v4[0] == 127 }
        if let v6 = parseIPv6(h) {
            if v6 == [UInt8](repeating: 0, count: 15) + [1] { return true }
            // IPv4-mapped loopback (Go's IsLoopback uses To4()).
            if v6[0..<10].allSatisfy({ $0 == 0 }), v6[10] == 0xFF, v6[11] == 0xFF { return v6[12] == 127 }
        }
        return false
    }

    /// Strict dotted quad like Go `net.ParseIP`: exactly 4 decimal octets,
    /// 0–255, no leading zeros.
    static func parseIPv4(_ s: String) -> [UInt8]? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out: [UInt8] = []
        for p in parts {
            guard (1...3).contains(p.count), p.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
                  !(p.count > 1 && p.first == "0"), let n = Int(p), n <= 255 else { return nil }
            out.append(UInt8(n))
        }
        return out
    }

    /// IPv6 literal (no zone).  Embedded dotted IPv4 tail is supported.
    static func parseIPv6(_ s: String) -> [UInt8]? {
        guard s.contains(":"), !s.contains("%") else { return nil }
        var text = s
        var tail: [UInt8] = []
        if let lastColon = text.lastIndex(of: ":"), text[text.index(after: lastColon)...].contains(".") {
            guard let v4 = parseIPv4(String(text[text.index(after: lastColon)...])) else { return nil }
            tail = v4
            text = String(text[...lastColon]) + "0:0"   // placeholder groups, replaced below
        }
        let halves = text.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }
        func groups(_ part: String) -> [UInt16]? {
            if part.isEmpty { return [] }
            var out: [UInt16] = []
            for g in part.split(separator: ":", omittingEmptySubsequences: false) {
                guard (1...4).contains(g.count), g.allSatisfy(\.isHexDigit), let v = UInt16(g, radix: 16) else { return nil }
                out.append(v)
            }
            return out
        }
        guard let head = groups(halves[0]) else { return nil }
        var all: [UInt16]
        if halves.count == 2 {
            guard let back = groups(halves[1]), head.count + back.count <= 7 else { return nil }
            all = head + [UInt16](repeating: 0, count: 8 - head.count - back.count) + back
        } else {
            guard head.count == 8 else { return nil }
            all = head
        }
        var bytes = all.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
        if !tail.isEmpty { bytes.replaceSubrange(12..<16, with: tail) }
        return bytes
    }

    func send(_ mailbox: Mailbox, body: Data) async throws -> UInt64 {
        guard (try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed])) != nil else {
            throw PeerPairingError.broker("body must be JSON")
        }
        var payload = Data(#"{"body":"#.utf8)
        payload.append(body)
        payload.append(Data("}".utf8))
        let (data, status) = try await call("POST", mailbox, suffix: "/messages", query: nil, body: payload)
        guard status == 201 else { throw Self.failure(status, data) }
        struct R: Decodable { let seq: UInt64 }
        guard let r = try? JSONDecoder().decode(R.self, from: data) else { throw PeerPairingError.broker("send response") }
        return r.seq
    }

    /// Acknowledges seq <= `after` and long-polls up to `wait` seconds.
    func receive(_ mailbox: Mailbox, after: UInt64, wait: TimeInterval) async throws -> [PeerBrokerMessage] {
        let w = String(format: "%.3f", max(0, min(wait, 60)))
        let (data, status) = try await call("GET", mailbox, suffix: "/messages",
                                            query: [URLQueryItem(name: "after", value: String(after)),
                                                    URLQueryItem(name: "wait", value: w)],
                                            body: nil, timeout: wait + 15)
        guard status == 200 else { throw Self.failure(status, data) }
        // Keep each body's raw bytes (opaque JSON) rather than re-serialising.
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["messages"] as? [[String: Any]]? else {
            throw PeerPairingError.broker("receive response")
        }
        return try (list ?? []).map { item in
            guard let seqNumber = item["seq"] as? NSNumber, let body = item["body"] else {
                throw PeerPairingError.broker("receive message")
            }
            let raw = try JSONSerialization.data(withJSONObject: body, options: [.fragmentsAllowed, .withoutEscapingSlashes])
            return PeerBrokerMessage(seq: seqNumber.uint64Value, body: raw)
        }
    }

    func mintICEServers(_ mailbox: Mailbox) async throws -> [PeerICEServer] {
        let (data, status) = try await call("POST", mailbox, suffix: "/turn", query: nil, body: nil)
        guard status == 200 else { throw Self.failure(status, data) }
        struct R: Decodable { let ice_servers: [PeerICEServer] }  // swiftlint:disable:this identifier_name
        guard let r = try? JSONDecoder().decode(R.self, from: data), !r.ice_servers.isEmpty else {
            throw PeerPairingError.broker("turn response")
        }
        return r.ice_servers
    }

    func close(_ mailbox: Mailbox) async {
        _ = try? await call("DELETE", mailbox, suffix: "", query: nil, body: nil)
    }

    // MARK: Internals

    private func call(_ method: String, _ mailbox: Mailbox, suffix: String, query: [URLQueryItem]?, body: Data?,
                      timeout: TimeInterval = 20) async throws -> (Data, Int) {
        guard !mailbox.sessionID.isEmpty, mailbox.sessionID.utf8.count <= 64,
              mailbox.sessionID.utf8.allSatisfy({ c in (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x5F }),
              !mailbox.capability.isEmpty, mailbox.capability.utf8.count <= 128 else {
            throw PeerPairingError.broker("mailbox")
        }
        guard var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { throw PeerPairingError.broker("url") }
        comps.percentEncodedPath = comps.percentEncodedPath + "/v1/sessions/" + mailbox.sessionID + suffix
        comps.queryItems = query
        guard let url = comps.url else { throw PeerPairingError.broker("url") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(mailbox.capability)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await http.perform(request)
        guard data.count <= Self.maxResponseBytes else { throw PeerPairingError.broker("response too large") }
        return (data, response.statusCode)
    }

    private static func failure(_ status: Int, _ data: Data) -> Error {
        struct E: Decodable { let error: String }
        let code = (try? JSONDecoder().decode(E.self, from: data))?.error ?? ""
        switch (status, code) {
        case (401, _): return Failure.unauthorized
        case (410, _): return Failure.closed
        case (413, _), (_, "too_large"): return Failure.tooLarge
        case (429, _): return Failure.rateLimited
        case (_, "turn_unavailable"): return Failure.turnUnavailable
        default: return Failure.http(status, code)
        }
    }
}
