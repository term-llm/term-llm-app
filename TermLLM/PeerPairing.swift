import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto  // swift-crypto (Linux test harness); same API surface.
#endif

// MARK: - term-llm pairing wire format v1 (frozen; see peer-contract.md)
//
// Binary values are unpadded base64url.  Ed25519 keys/signatures, HMAC-SHA256
// MACs over explicit length-prefixed transcripts.  SDP strings are signed and
// applied byte-for-byte exactly as received.

enum PeerPairingWire {
    static let version = 1
    static let linkScheme = "term-llm-pair"
    static let sessionIDSize = 16
    static let challengeIDSize = 16
    static let grantIDSize = 16
    static let nonceSize = 32
    static let secretSize = 32
    static let macSize = 32
    static let publicKeySize = 32
    static let signatureSize = 64
    static let maxDeviceNameBytes = 64
    static let maxSDPBytes = 64 << 10
    static let maxMessageBytes = 256 << 10

    static let transcriptDomain = "term-llm/pairing/v1"
    static let macKeyLabel = "term-llm/pairing/v1/mac-key"

    enum Label: String {
        case pairRequest = "pair-request"
        case pairAnswer = "pair-answer"
        case reconnectRequest = "reconnect-request"
        case reconnectAnswer = "reconnect-answer"
    }

    enum MessageType: String, Codable {
        case pairRequest = "pair_request"
        case pairAnswer = "pair_answer"
        case pairReject = "pair_reject"
        case reconnectHello = "reconnect_hello"
        case reconnectChallenge = "reconnect_challenge"
        case reconnectRequest = "reconnect_request"
        case reconnectAnswer = "reconnect_answer"
    }
}

enum PeerPairingError: Error, Equatable, LocalizedError {
    case invalid(String)
    case expired
    case badMAC
    case badSignature
    case hostKeyMismatch
    case rejected(String)
    case timedOut
    case broker(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let m): return "Invalid pairing data: \(m)."
        case .expired: return "This pairing code has expired. Create a new one on the host."
        case .badMAC, .badSignature, .hostKeyMismatch: return "The host could not be verified. Pairing was stopped."
        case .rejected(let reason): return "The host did not approve this device (\(reason))."
        case .timedOut: return "Timed out waiting for the host to approve this device."
        case .broker(let m): return "Pairing relay error: \(m)."
        }
    }
}

// MARK: - base64url (strict, unpadded)

enum PeerBase64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Strict like Go `RawURLEncoding.Strict()`: url alphabet only, no padding,
    /// canonical trailing bits (re-encoding must reproduce the input).
    static func decode(_ string: String) -> Data? {
        guard string.utf8.allSatisfy({ c in
            (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x5F
        }) else { return nil }
        if string.utf8.count % 4 == 1 { return nil }
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.utf8.count % 4 != 0 { s += "=" }
        guard let data = Data(base64Encoded: s), encode(data) == string else { return nil }
        return data
    }
}

/// Codable unpadded-base64url byte field.
struct PeerB64: Codable, Equatable, Sendable {
    var data: Data
    init(_ data: Data) { self.data = data }
    init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let d = PeerBase64URL.decode(s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "base64url"))
        }
        data = d
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(PeerBase64URL.encode(data))
    }
}

// MARK: - Transcript, MAC, signatures

enum PeerTranscript {
    enum Field {
        case string(String)
        case bytes(Data)
        case int(Int64)

        var raw: Data {
            switch self {
            case .string(let s): return Data(s.utf8)
            case .bytes(let d): return d
            case .int(let i): return Data(String(i).utf8)
            }
        }
    }

    static func build(_ label: PeerPairingWire.Label, _ fields: [Field]) -> Data {
        var out = Data()
        func append(_ x: Data) {
            var n = UInt32(x.count).bigEndian
            withUnsafeBytes(of: &n) { out.append(contentsOf: $0) }
            out.append(x)
        }
        append(Data(PeerPairingWire.transcriptDomain.utf8))
        append(Data(label.rawValue.utf8))
        fields.forEach { append($0.raw) }
        return out
    }

    static func macKey(secret: Data) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(PeerPairingWire.macKeyLabel.utf8), using: SymmetricKey(data: secret))
        return Data(mac)
    }

    static func mac(secret: Data, transcript: Data) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: transcript, using: SymmetricKey(data: macKey(secret: secret)))
        return Data(mac)
    }

    /// Constant-time MAC check.
    static func verifyMAC(_ mac: Data, secret: Data, transcript: Data) -> Bool {
        guard mac.count == PeerPairingWire.macSize else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: transcript,
                                                       using: SymmetricKey(data: macKey(secret: secret)))
    }

    static func hash(_ transcript: Data) -> Data { Data(SHA256.hash(data: transcript)) }

    static func verifySignature(_ sig: Data, publicKey: Data, transcript: Data) -> Bool {
        guard sig.count == PeerPairingWire.signatureSize,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return key.isValidSignature(sig, for: transcript)
    }

    static func pairRequest(sid: Data, hostKey: Data, hostNonce: Data, deviceKey: Data, deviceNonce: Data,
                            deviceName: String, offerSDP: String) -> Data {
        build(.pairRequest, [.string("device"), .bytes(sid), .bytes(hostKey), .bytes(hostNonce), .bytes(deviceKey),
                             .bytes(deviceNonce), .string(deviceName), .string(offerSDP)])
    }

    static func pairAnswer(_ a: PeerPairAnswer) -> Data {
        build(.pairAnswer, [.string("host"), .bytes(a.sid.data), .bytes(a.hk.data), .bytes(a.hn.data),
                            .bytes(a.device_key.data), .bytes(a.device_nonce.data), .bytes(a.request_hash.data),
                            .bytes(a.grant_id.data), .int(a.grant_expires_at), .string(a.answer_sdp)])
    }

    static func reconnectRequest(challengeID: Data, hostKey: Data, hostNonce: Data, deviceKey: Data,
                                 deviceNonce: Data, grantID: Data, offerSDP: String) -> Data {
        build(.reconnectRequest, [.string("device"), .bytes(challengeID), .bytes(hostKey), .bytes(hostNonce),
                                  .bytes(deviceKey), .bytes(deviceNonce), .bytes(grantID), .string(offerSDP)])
    }

    static func reconnectAnswer(_ a: PeerReconnectAnswer) -> Data {
        build(.reconnectAnswer, [.string("host"), .bytes(a.challenge_id.data), .bytes(a.hk.data), .bytes(a.hn.data),
                                 .bytes(a.device_key.data), .bytes(a.device_nonce.data), .bytes(a.request_hash.data),
                                 .bytes(a.grant_id.data), .string(a.answer_sdp)])
    }
}

// MARK: - Device identity

/// Device Ed25519 identity.  Persisted by ``PeerIdentityStore`` (keychain).
struct PeerDeviceIdentity: @unchecked Sendable {  // immutable key value
    let privateKey: Curve25519.Signing.PrivateKey

    init() { privateKey = Curve25519.Signing.PrivateKey() }
    init(seed: Data) throws { privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed) }

    var publicKey: Data { privateKey.publicKey.rawRepresentation }
    var seed: Data { privateKey.rawRepresentation }

    /// Short display fingerprint (matches what the host shows for approval
    /// only if the host uses the same rendering; informational).
    var fingerprint: String { PeerBase64URL.encode(Data(SHA256.hash(data: publicKey).prefix(9))) }

    func sign(_ transcript: Data) throws -> Data { try privateKey.signature(for: transcript) }
}

enum PeerRandom {
    static func bytes(_ n: Int) -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<n).map { _ in UInt8.random(in: .min ... .max, using: &g) })
    }
}

// MARK: - Validation helpers

enum PeerPairingValidation {
    /// Normalised DTLS fingerprint (`sha-256 AB:CD:…`); all lines must agree.
    static func sdpFingerprint(_ sdp: String) throws -> String {
        guard !sdp.isEmpty, sdp.utf8.count <= PeerPairingWire.maxSDPBytes else { throw PeerPairingError.invalid("SDP size") }
        guard !sdp.utf8.contains(0) else { throw PeerPairingError.invalid("SDP NUL") }
        let sizes = ["sha-256": 32, "sha-384": 48, "sha-512": 64]
        var found: String?
        // Split on LF *bytes*: Swift treats "\r\n" as ONE Character, so a
        // Character split on "\n" would never separate CRLF lines.
        for rawLine in sdp.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
            var bytes = Array(rawLine)
            if bytes.last == UInt8(ascii: "\r") { bytes.removeLast() }
            let line = String(decoding: bytes, as: UTF8.self)
            guard line.hasPrefix("a=fingerprint:") else { continue }
            let rest = line.dropFirst("a=fingerprint:".count).trimmingCharacters(in: .whitespaces)
            guard let space = rest.firstIndex(of: " ") else { throw PeerPairingError.invalid("fingerprint") }
            let alg = rest[..<space].lowercased()
            guard let size = sizes[alg] else { throw PeerPairingError.invalid("fingerprint hash") }
            let parts = rest[rest.index(after: space)...].trimmingCharacters(in: .whitespaces)
                .split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == size, parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) }) else {
                throw PeerPairingError.invalid("fingerprint value")
            }
            let fp = alg + " " + parts.map { $0.uppercased() }.joined(separator: ":")
            if let found, found != fp { throw PeerPairingError.invalid("conflicting fingerprints") }
            found = fp
        }
        guard let found else { throw PeerPairingError.invalid("no DTLS fingerprint") }
        return found
    }

    static func deviceName(_ name: String) throws {
        guard !name.isEmpty, name.utf8.count <= PeerPairingWire.maxDeviceNameBytes else {
            throw PeerPairingError.invalid("device name length")
        }
        for scalar in name.unicodeScalars {
            let cat = scalar.properties.generalCategory
            if cat == .control || cat == .format { throw PeerPairingError.invalid("device name characters") }
        }
    }

    static func length(_ name: String, _ data: Data, _ n: Int) throws {
        guard data.count == n else { throw PeerPairingError.invalid("\(name) length") }
    }
}

// MARK: - Pairing link (QR)

/// `term-llm-pair://v1?broker=..&sid=..&hk=..&hn=..&exp=..[&name=..]#ps=..&cap=..`
///
/// The pairing secret `ps` and broker device capability `cap` live ONLY in the
/// fragment; a link carrying either in the query is rejected.  `description`
/// redacts both.  Expiry is checked by the caller (``isExpired(at:)``).
struct PeerPairingLink: Equatable, Sendable, CustomStringConvertible {
    let broker: URL
    let sessionID: Data
    let hostKey: Data
    let hostNonce: Data
    let secret: Data
    let deviceCapability: String
    let expiresAt: Date
    let name: String?

    var sessionIDString: String { PeerBase64URL.encode(sessionID) }

    var description: String {
        "PeerPairingLink(broker: \(broker.absoluteString), sid: \(sessionIDString), name: \(name ?? "-"), ps: [REDACTED], cap: [REDACTED])"
    }

    func isExpired(at now: Date = Date()) -> Bool { now >= expiresAt }

    static func parse(_ string: String) throws -> PeerPairingLink {
        guard string.utf8.count <= 4096, let comps = URLComponents(string: string) else {
            throw PeerPairingError.invalid("link")
        }
        guard comps.scheme == PeerPairingWire.linkScheme else { throw PeerPairingError.invalid("link scheme") }
        guard comps.host == "v\(PeerPairingWire.version)" else { throw PeerPairingError.invalid("link version") }
        guard comps.user == nil, comps.password == nil, comps.port == nil, comps.path.isEmpty || comps.path == "/" else {
            throw PeerPairingError.invalid("link form")
        }
        let query = try params(comps.percentEncodedQuery)
        let fragment = try params(comps.percentEncodedFragment)
        if query["ps"] != nil || query["cap"] != nil {
            throw PeerPairingError.invalid("secret in query")  // must never reach logs/servers
        }
        // Fragment is strict (matches core): exactly ps + cap, nothing else.
        guard Set(fragment.keys) == ["ps", "cap"] else { throw PeerPairingError.invalid("fragment fields") }

        func bytes(_ dict: [String: String], _ key: String, _ n: Int) throws -> Data {
            guard let v = dict[key], let d = PeerBase64URL.decode(v), d.count == n else {
                throw PeerPairingError.invalid(key)
            }
            return d
        }

        guard let brokerString = query["broker"], let broker = URL(string: brokerString),
              let scheme = broker.scheme?.lowercased(), let host = broker.host, !host.isEmpty,
              broker.user == nil, broker.password == nil, broker.query == nil, broker.fragment == nil else {
            throw PeerPairingError.invalid("broker")
        }
        guard scheme == "https" || (scheme == "http" && PeerBrokerClient.isLoopbackHost(host)) else {
            throw PeerPairingError.invalid("broker must use https")
        }
        guard let expString = query["exp"], let exp = Int64(expString), exp > 0 else { throw PeerPairingError.invalid("exp") }
        guard let cap = fragment["cap"], (1...128).contains(cap.utf8.count),
              cap.utf8.allSatisfy({ c in (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x5F }) else {
            throw PeerPairingError.invalid("cap")
        }
        let name = query["name"].flatMap { $0.isEmpty ? nil : $0 }
        if let name { try PeerPairingValidation.deviceName(name) }  // shown in UI: same control-char rule
        return PeerPairingLink(
            broker: broker,
            sessionID: try bytes(query, "sid", PeerPairingWire.sessionIDSize),
            hostKey: try bytes(query, "hk", PeerPairingWire.publicKeySize),
            hostNonce: try bytes(query, "hn", PeerPairingWire.nonceSize),
            secret: try bytes(fragment, "ps", PeerPairingWire.secretSize),
            deviceCapability: cap,
            expiresAt: Date(timeIntervalSince1970: TimeInterval(exp)),
            name: name)
    }

    /// `application/x-www-form-urlencoded` pairs; duplicates rejected.
    private static func params(_ encoded: String?) throws -> [String: String] {
        guard let encoded, !encoded.isEmpty else { return [:] }
        var out: [String: String] = [:]
        for pair in encoded.split(separator: "&", omittingEmptySubsequences: true) {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            func decode(_ s: Substring) throws -> String {
                guard let v = String(s).replacingOccurrences(of: "+", with: " ").removingPercentEncoding else {
                    throw PeerPairingError.invalid("link encoding")
                }
                return v
            }
            let key = try decode(kv[0])
            let value = kv.count > 1 ? try decode(kv[1]) : ""
            guard out[key] == nil else { throw PeerPairingError.invalid("duplicate \(key)") }
            out[key] = value
        }
        return out
    }
}

// MARK: - Messages (exact JSON field names)

// swiftlint:disable identifier_name
struct PeerPairRequest: Codable, Equatable, Sendable {
    var v = PeerPairingWire.version
    var type = PeerPairingWire.MessageType.pairRequest
    var sid: PeerB64
    var hn: PeerB64
    var device_key: PeerB64
    var device_nonce: PeerB64
    var device_name: String
    var offer_sdp: String
    var mac: PeerB64
    var sig: PeerB64
}

struct PeerPairAnswer: Codable, Equatable, Sendable {
    var v: Int
    var type: PeerPairingWire.MessageType
    var sid: PeerB64
    var hk: PeerB64
    var hn: PeerB64
    var device_key: PeerB64
    var device_nonce: PeerB64
    var request_hash: PeerB64
    var grant_id: PeerB64
    var grant_expires_at: Int64
    var answer_sdp: String
    var mac: PeerB64
    var sig: PeerB64
}

struct PeerPairReject: Codable, Equatable, Sendable {
    var v: Int
    var type: PeerPairingWire.MessageType
    var sid: PeerB64?
    var reason: String
}

struct PeerReconnectHello: Codable, Equatable, Sendable {
    var v = PeerPairingWire.version
    var type = PeerPairingWire.MessageType.reconnectHello
    var device_key: PeerB64
    var grant_id: PeerB64
}

struct PeerReconnectChallenge: Codable, Equatable, Sendable {
    var v: Int
    var type: PeerPairingWire.MessageType
    var challenge_id: PeerB64
    var hk: PeerB64
    var hn: PeerB64
    var expires_at: Int64
}

struct PeerReconnectRequest: Codable, Equatable, Sendable {
    var v = PeerPairingWire.version
    var type = PeerPairingWire.MessageType.reconnectRequest
    var challenge_id: PeerB64
    var hn: PeerB64
    var device_key: PeerB64
    var device_nonce: PeerB64
    var grant_id: PeerB64
    var offer_sdp: String
    var sig: PeerB64
}

struct PeerReconnectAnswer: Codable, Equatable, Sendable {
    var v: Int
    var type: PeerPairingWire.MessageType
    var challenge_id: PeerB64
    var hk: PeerB64
    var hn: PeerB64
    var device_key: PeerB64
    var device_nonce: PeerB64
    var request_hash: PeerB64
    var grant_id: PeerB64
    var answer_sdp: String
    var sig: PeerB64
}
// swiftlint:enable identifier_name

enum PeerPairingMessage: Equatable, Sendable {
    case pairAnswer(PeerPairAnswer)
    case pairReject(PeerPairReject)
    case reconnectChallenge(PeerReconnectChallenge)
    case reconnectAnswer(PeerReconnectAnswer)
    /// Device-originated or unknown types are never acted on by the device.
    case ignored(String)

    /// Mirrors Go `DecodeMessage`: size bound, v==1, known type.
    static func decode(_ data: Data) throws -> PeerPairingMessage {
        guard data.count <= PeerPairingWire.maxMessageBytes else { throw PeerPairingError.invalid("message size") }
        struct Head: Decodable { let v: Int; let type: String }
        guard let head = try? JSONDecoder().decode(Head.self, from: data) else { throw PeerPairingError.invalid("message") }
        guard head.v == PeerPairingWire.version else { throw PeerPairingError.invalid("message version") }
        let d = JSONDecoder()
        do {
            switch PeerPairingWire.MessageType(rawValue: head.type) {
            case .pairAnswer?: return .pairAnswer(try d.decode(PeerPairAnswer.self, from: data))
            case .pairReject?: return .pairReject(try d.decode(PeerPairReject.self, from: data))
            case .reconnectChallenge?: return .reconnectChallenge(try d.decode(PeerReconnectChallenge.self, from: data))
            case .reconnectAnswer?: return .reconnectAnswer(try d.decode(PeerReconnectAnswer.self, from: data))
            case .pairRequest?, .reconnectHello?, .reconnectRequest?: return .ignored(head.type)
            case nil: throw PeerPairingError.invalid("message type")
            }
        } catch let e as PeerPairingError {
            throw e
        } catch {
            throw PeerPairingError.invalid("message fields")
        }
    }

    static func encode<T: Encodable>(_ message: T) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return try e.encode(message)
    }
}

// MARK: - Verified results

/// Result of a verified pair answer; persist via ``PeerIdentityStore``.
struct PeerVerifiedPairing: Equatable, Sendable {
    let hostKey: Data
    let grantID: Data
    /// nil = host granted no expiry (pilot hosts set a finite 24 h grant).
    let grantExpiresAt: Date?
    let answerSDP: String
    let answerFingerprint: String
}

// MARK: - Device-side attempts

/// One initial pairing.  Send ``request`` to the broker mailbox; apply an
/// answer to WebRTC ONLY after ``verify(_:)`` succeeds.
struct PeerPairingAttempt: Sendable {
    let link: PeerPairingLink
    let request: PeerPairRequest
    let requestHash: Data

    init(link: PeerPairingLink, identity: PeerDeviceIdentity, deviceName: String, offerSDP: String,
         now: Date = Date(), deviceNonce: Data? = nil) throws {
        guard !link.isExpired(at: now) else { throw PeerPairingError.expired }
        try PeerPairingValidation.deviceName(deviceName)
        _ = try PeerPairingValidation.sdpFingerprint(offerSDP)
        let nonce = deviceNonce ?? PeerRandom.bytes(PeerPairingWire.nonceSize)
        try PeerPairingValidation.length("device_nonce", nonce, PeerPairingWire.nonceSize)
        let t = PeerTranscript.pairRequest(sid: link.sessionID, hostKey: link.hostKey, hostNonce: link.hostNonce,
                                           deviceKey: identity.publicKey, deviceNonce: nonce,
                                           deviceName: deviceName, offerSDP: offerSDP)
        self.link = link
        self.request = PeerPairRequest(
            sid: PeerB64(link.sessionID), hn: PeerB64(link.hostNonce), device_key: PeerB64(identity.publicKey),
            device_nonce: PeerB64(nonce), device_name: deviceName, offer_sdp: offerSDP,
            mac: PeerB64(PeerTranscript.mac(secret: link.secret, transcript: t)),
            sig: PeerB64(try identity.sign(t)))
        self.requestHash = PeerTranscript.hash(t)
    }

    func verify(_ a: PeerPairAnswer) throws -> PeerVerifiedPairing {
        guard a.v == PeerPairingWire.version, a.type == .pairAnswer else { throw PeerPairingError.invalid("answer header") }
        guard a.hk.data == link.hostKey else { throw PeerPairingError.hostKeyMismatch }
        guard a.sid == request.sid, a.hn == request.hn, a.device_key == request.device_key,
              a.device_nonce == request.device_nonce, a.request_hash.data == requestHash else {
            throw PeerPairingError.invalid("answer does not match request")
        }
        try PeerPairingValidation.length("grant_id", a.grant_id.data, PeerPairingWire.grantIDSize)
        // Pilot grants must be finite (host default 24 h).
        guard a.grant_expires_at > 0 else { throw PeerPairingError.invalid("grant expiry required") }
        let t = PeerTranscript.pairAnswer(a)
        guard PeerTranscript.verifyMAC(a.mac.data, secret: link.secret, transcript: t) else { throw PeerPairingError.badMAC }
        guard PeerTranscript.verifySignature(a.sig.data, publicKey: link.hostKey, transcript: t) else {
            throw PeerPairingError.badSignature
        }
        let fp = try PeerPairingValidation.sdpFingerprint(a.answer_sdp)
        return PeerVerifiedPairing(
            hostKey: link.hostKey, grantID: a.grant_id.data,
            grantExpiresAt: Date(timeIntervalSince1970: TimeInterval(a.grant_expires_at)),
            answerSDP: a.answer_sdp, answerFingerprint: fp)
    }
}

/// One reconnect (signatures only; no pairing secret).
struct PeerReconnectAttempt: Sendable {
    let pinnedHostKey: Data
    let request: PeerReconnectRequest
    let requestHash: Data

    static func hello(identity: PeerDeviceIdentity, grantID: Data) -> PeerReconnectHello {
        PeerReconnectHello(device_key: PeerB64(identity.publicKey), grant_id: PeerB64(grantID))
    }

    init(challenge c: PeerReconnectChallenge, pinnedHostKey: Data, identity: PeerDeviceIdentity, grantID: Data,
         offerSDP: String, now: Date = Date(), deviceNonce: Data? = nil) throws {
        guard c.v == PeerPairingWire.version, c.type == .reconnectChallenge else { throw PeerPairingError.invalid("challenge header") }
        guard c.hk.data == pinnedHostKey else { throw PeerPairingError.hostKeyMismatch }
        try PeerPairingValidation.length("challenge_id", c.challenge_id.data, PeerPairingWire.challengeIDSize)
        try PeerPairingValidation.length("hn", c.hn.data, PeerPairingWire.nonceSize)
        guard Int64(now.timeIntervalSince1970) < c.expires_at else { throw PeerPairingError.expired }
        _ = try PeerPairingValidation.sdpFingerprint(offerSDP)
        let nonce = deviceNonce ?? PeerRandom.bytes(PeerPairingWire.nonceSize)
        try PeerPairingValidation.length("device_nonce", nonce, PeerPairingWire.nonceSize)
        let t = PeerTranscript.reconnectRequest(challengeID: c.challenge_id.data, hostKey: pinnedHostKey,
                                                hostNonce: c.hn.data, deviceKey: identity.publicKey,
                                                deviceNonce: nonce, grantID: grantID, offerSDP: offerSDP)
        self.pinnedHostKey = pinnedHostKey
        self.request = PeerReconnectRequest(
            challenge_id: c.challenge_id, hn: c.hn, device_key: PeerB64(identity.publicKey),
            device_nonce: PeerB64(nonce), grant_id: PeerB64(grantID), offer_sdp: offerSDP,
            sig: PeerB64(try identity.sign(t)))
        self.requestHash = PeerTranscript.hash(t)
    }

    /// Returns the answer SDP (exact bytes) to apply.
    func verify(_ a: PeerReconnectAnswer) throws -> String {
        guard a.v == PeerPairingWire.version, a.type == .reconnectAnswer else { throw PeerPairingError.invalid("answer header") }
        guard a.hk.data == pinnedHostKey else { throw PeerPairingError.hostKeyMismatch }
        guard a.challenge_id == request.challenge_id, a.hn == request.hn, a.device_key == request.device_key,
              a.device_nonce == request.device_nonce, a.grant_id == request.grant_id,
              a.request_hash.data == requestHash else {
            throw PeerPairingError.invalid("answer does not match request")
        }
        guard PeerTranscript.verifySignature(a.sig.data, publicKey: pinnedHostKey,
                                             transcript: PeerTranscript.reconnectAnswer(a)) else {
            throw PeerPairingError.badSignature
        }
        _ = try PeerPairingValidation.sdpFingerprint(a.answer_sdp)
        return a.answer_sdp
    }
}
