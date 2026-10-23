import Foundation

// MARK: - term-llm-http-v1 wire protocol
//
// One UTF-8 JSON object per DataChannel message on the reliable, ordered
// channel labelled `term-llm-http-v1`.  Shape agreed with the core peer
// worker (Go `http.Header` style headers: canonical name -> [String]):
//
//     {"version":1,"type":"request","id":"r1","method":"GET","path":"/chat/?a=b",
//      "header":{"Accept":["text/html"]},"body":"<base64>"}
//     {"version":1,"type":"response_start","id":"r1","status":200,"header":{...}}
//     {"version":1,"type":"response_body","id":"r1","body":"<base64>"}
//     {"version":1,"type":"response_end","id":"r1"}            // success
//     {"version":1,"type":"response_end","id":"r1","error":"…"} // aborted
//     {"version":1,"type":"cancel","id":"r1"}                   // either direction
//
// Request bodies travel inline in the `request` frame (no request_body type
// exists in v1), so they are bounded by ``PeerWireLimits/maxRequestBodyBytes``.

enum PeerWire {
    static let version = 1
    static let channelLabel = "term-llm-http-v1"
}

enum PeerFrameType: String, Codable, Sendable, Equatable {
    case request
    case responseStart = "response_start"
    case responseBody = "response_body"
    case responseEnd = "response_end"
    case cancel
}

/// Go `http.Header` compatible header map.  Keys are canonicalised on encode
/// (`content-type` -> `Content-Type`); lookups are case-insensitive.
struct PeerHeader: Equatable, Sendable, Codable {
    private(set) var storage: [String: [String]] = [:]

    init() {}

    init(_ values: [String: [String]]) {
        for (name, list) in values { for value in list { add(name, value) } }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode([String: [String]].self)
        self.init(raw)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storage)
    }

    static func canonical(_ name: String) -> String {
        var upper = true
        var out = ""
        out.reserveCapacity(name.count)
        for ch in name {
            if upper { out += ch.uppercased() } else { out += ch.lowercased() }
            upper = (ch == "-")
        }
        return out
    }

    /// RFC 9110 token characters only; rejects CR/LF/colon/space injection.
    static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 256 else { return false }
        let allowed = Set("!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8)
        return name.utf8.allSatisfy { allowed.contains($0) }
    }

    static func isValidValue(_ value: String) -> Bool {
        value.utf8.allSatisfy { $0 == 0x09 || ($0 >= 0x20 && $0 != 0x7F) }
    }

    mutating func add(_ name: String, _ value: String) {
        storage[Self.canonical(name), default: []].append(value)
    }

    mutating func set(_ name: String, _ value: String) {
        storage[Self.canonical(name)] = [value]
    }

    mutating func remove(_ name: String) {
        storage.removeValue(forKey: Self.canonical(name))
    }

    func values(_ name: String) -> [String] { storage[Self.canonical(name)] ?? [] }
    func first(_ name: String) -> String? { values(name).first }
    var names: [String] { storage.keys.sorted() }
    var isEmpty: Bool { storage.isEmpty }

    var isWellFormed: Bool {
        storage.allSatisfy { name, values in
            Self.isValidName(name) && values.allSatisfy(Self.isValidValue)
        }
    }
}

struct PeerFrame: Codable, Equatable, Sendable {
    var version: Int
    var type: PeerFrameType
    var id: String
    var method: String?
    var path: String?
    var header: PeerHeader?
    var body: String?
    var status: Int?
    var error: String?

    init(type: PeerFrameType, id: String, method: String? = nil, path: String? = nil,
         header: PeerHeader? = nil, body: Data? = nil, status: Int? = nil, error: String? = nil) {
        self.version = PeerWire.version
        self.type = type
        self.id = id
        self.method = method
        self.path = path
        self.header = header
        self.body = body.flatMap { $0.isEmpty ? nil : $0.base64EncodedString() }
        self.status = status
        self.error = error
    }

    var bodyData: Data? {
        guard let body else { return Data() }
        return Data(base64Encoded: body)
    }
}

struct PeerWireLimits: Sendable, Equatable {
    /// Largest encoded JSON frame accepted or produced (well under the SCTP
    /// max-message-size negotiated by libwebrtc and pion).
    var maxFrameBytes = 64 * 1024
    /// Raw bytes per response_body frame (base64 expands 4/3).
    var maxBodyChunkBytes = 16 * 1024
    /// Inline request body ceiling (request frame must fit maxFrameBytes).
    var maxRequestBodyBytes = 40 * 1024
    var maxIDLength = 64
    var maxPathBytes = 8 * 1024
    /// Concurrent open request streams per channel.
    var maxConcurrentStreams = 32
    /// Unconsumed response body bytes buffered per stream before the stream
    /// is cancelled (the peer cannot be back-pressured on an ordered channel).
    var maxBufferedResponseBytes = 4 * 1024 * 1024
    /// DataChannel bufferedAmount high-water mark for outbound frames.
    var sendHighWaterBytes: UInt64 = 1024 * 1024

    static let `default` = PeerWireLimits()
}

enum PeerWireError: Error, Equatable, Sendable, LocalizedError {
    case frameTooLarge(Int)
    case malformedFrame(String)
    case unsupportedVersion(Int)
    case invalidRequest(String)
    case requestBodyTooLarge(Int)
    case channelClosed
    case tooManyStreams
    case protocolViolation(String)
    case remoteError(String)
    case cancelled
    case responseBufferOverflow
    case timedOut
    case unauthorized(String)

    var errorDescription: String? {
        switch self {
        case .frameTooLarge(let n): return "Peer frame too large (\(n) bytes)."
        case .malformedFrame(let m): return "Malformed peer frame: \(m)"
        case .unsupportedVersion(let v): return "Unsupported peer protocol version \(v)."
        case .invalidRequest(let m): return "Invalid peer request: \(m)"
        case .requestBodyTooLarge(let n): return "Request body too large for peer channel (\(n) bytes)."
        case .channelClosed: return "Peer channel closed."
        case .tooManyStreams: return "Too many concurrent peer requests."
        case .protocolViolation(let m): return "Peer protocol violation: \(m)"
        case .remoteError(let m): return "Peer error: \(m)"
        case .cancelled: return "Peer request cancelled."
        case .responseBufferOverflow: return "Peer response exceeded the local buffer."
        case .timedOut: return "Peer request timed out."
        case .unauthorized(let m): return "Peer session not authorized: \(m)"
        }
    }
}

enum PeerFrameCodec {
    static func encode(_ frame: PeerFrame, limits: PeerWireLimits = .default) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(frame)
        guard data.count <= limits.maxFrameBytes else { throw PeerWireError.frameTooLarge(data.count) }
        return data
    }

    /// Strict decode: size, version, id, per-type required fields, header
    /// well-formedness and base64 validity are all enforced.
    static func decode(_ data: Data, limits: PeerWireLimits = .default) throws -> PeerFrame {
        guard data.count <= limits.maxFrameBytes else { throw PeerWireError.frameTooLarge(data.count) }
        let frame: PeerFrame
        do {
            frame = try JSONDecoder().decode(PeerFrame.self, from: data)
        } catch {
            throw PeerWireError.malformedFrame("not a v1 JSON frame")
        }
        guard frame.version == PeerWire.version else { throw PeerWireError.unsupportedVersion(frame.version) }
        guard !frame.id.isEmpty, frame.id.utf8.count <= limits.maxIDLength,
              frame.id.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7F }) else {
            throw PeerWireError.malformedFrame("bad id")
        }
        if let header = frame.header, !header.isWellFormed {
            throw PeerWireError.malformedFrame("bad header")
        }
        if frame.body != nil, frame.bodyData == nil {
            throw PeerWireError.malformedFrame("bad base64 body")
        }
        switch frame.type {
        case .request:
            guard let method = frame.method, PeerHeader.isValidName(method),
                  let path = frame.path, PeerHTTPRequest.isValidPath(path, limits: limits) else {
                throw PeerWireError.malformedFrame("request needs method and path")
            }
        case .responseStart:
            guard let status = frame.status, (100...999).contains(status) else {
                throw PeerWireError.malformedFrame("response_start needs status")
            }
        case .responseBody, .responseEnd, .cancel:
            break
        }
        return frame
    }
}

// MARK: - Request / response values

struct PeerHTTPRequest: Sendable, Equatable {
    var method: String
    /// Origin-relative path including query (`/chat/api?x=1`).  Never a URL.
    var path: String
    var header: PeerHeader
    var body: Data

    init(method: String, path: String, header: PeerHeader = PeerHeader(), body: Data = Data()) {
        self.method = method.uppercased()
        self.path = path
        self.header = header
        self.body = body
    }

    static func isValidPath(_ path: String, limits: PeerWireLimits = .default) -> Bool {
        guard path.hasPrefix("/"), !path.hasPrefix("//"), path.utf8.count <= limits.maxPathBytes else { return false }
        // Visible ASCII only: rejects CR/LF, spaces, controls and raw UTF-8.
        return path.utf8.allSatisfy { $0 > 0x20 && $0 < 0x7F && $0 != UInt8(ascii: "#") }
    }

    func validate(limits: PeerWireLimits) throws {
        guard PeerHeader.isValidName(method) else { throw PeerWireError.invalidRequest("method") }
        guard Self.isValidPath(path, limits: limits) else { throw PeerWireError.invalidRequest("path") }
        guard header.isWellFormed else { throw PeerWireError.invalidRequest("header") }
        guard body.count <= limits.maxRequestBodyBytes else { throw PeerWireError.requestBodyTooLarge(body.count) }
    }
}

/// Streaming response.  `body` yields raw chunks in order and finishes after
/// `response_end`; it throws on `response_end` with error, cancel, channel
/// loss or local buffer overflow.  Dropping/terminating iteration early
/// cancels the remote request.
struct PeerHTTPResponse: Sendable {
    let status: Int
    let header: PeerHeader
    let body: PeerBodyStream
    let cancel: @Sendable () -> Void

    /// Collect the whole body, failing above `limit` bytes (cancels remote).
    func collect(limit: Int) async throws -> Data {
        var out = Data()
        for try await chunk in body {
            if out.count + chunk.count > limit {
                cancel()
                throw PeerWireError.responseBufferOverflow
            }
            out.append(chunk)
        }
        // A cancelled consumer sees the stream end early; never report a
        // truncated body as success.
        try Task.checkCancellation()
        return out
    }
}

/// Anything that can forward one HTTP request to the remote node.
protocol PeerHTTPForwarding: AnyObject, Sendable {
    func forward(_ request: PeerHTTPRequest, headTimeout: TimeInterval?) async throws -> PeerHTTPResponse
}
