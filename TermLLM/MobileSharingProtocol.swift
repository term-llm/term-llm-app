import CryptoKit
import Foundation

// MARK: - Frozen core protocol v2

enum MobileSharingWire {
    static let version = 2
    static let maxLinkBytes = 4096
    static let maxMessageBytes = 256 * 1024
    static let maxBrokerFrameBytes = maxMessageBytes + 512
    static let maxSDPBytes = 64 * 1024
    static let invitationIDBytes = 16
    static let deviceIDBytes = 16
    static let nonceBytes = 32
    static let secretBytes = 32
    static let keyBytes = 32
    static let signatureBytes = 64
    static let maxLabelBytes = 64
    static let maxCapabilityBytes = 128
    static let domain = "term-llm/pairing/v2"
    static let macKeyLabel = "term-llm/pairing/v2/mac-key"
}

enum MobileSharingProtocolError: Error, Equatable, LocalizedError {
    case invalidLink
    case expired
    case invalid(String)
    case badMAC
    case badSignature
    case hostIdentityChanged
    case rejected(String)
    case revoked

    var errorDescription: String? {
        switch self {
        case .invalidLink: "This Mobile Sharing link is not valid."
        case .expired: "This Mobile Sharing invitation has expired. Create a new one on the host."
        case .invalid(_): "The host returned invalid Mobile Sharing data."
        case .badMAC, .badSignature: "The host identity could not be authenticated. Pairing was stopped."
        case .hostIdentityChanged: "The host identity changed. The connection was stopped."
        case .rejected(_): "The host did not approve this device."
        case .revoked: "Access was revoked or the shared target was reset."
        }
    }
}

struct MobileSharingPairingLink: Equatable, Sendable {
    let broker: URL
    let hostKey: Data
    let invitationID: Data
    let expiresAt: Date
    let hostLabel: String?
    let pairingSecret: Data
    let invitationCapability: String?

    var hostID: String { MobileSharingBase64URL.encode(Data(SHA256.hash(data: hostKey))) }
    var invitationIDString: String { MobileSharingBase64URL.encode(invitationID) }
    var hostFingerprint: String {
        let digest = SHA256.hash(data: hostKey)
        return digest.prefix(8).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    func isExpired(at date: Date = Date()) -> Bool { date >= expiresAt }

    static func parse(_ raw: String) throws -> Self {
        guard !raw.isEmpty, raw.utf8.count <= MobileSharingWire.maxLinkBytes,
              let components = URLComponents(string: raw), components.scheme == "termllm",
              components.host == "pair", components.user == nil, components.password == nil,
              components.port == nil, components.path.isEmpty,
              let queryItems = components.queryItems, let fragment = components.fragment else {
            throw MobileSharingProtocolError.invalidLink
        }
        let query = try strict(items: queryItems, required: ["v", "b", "h", "i", "e"], optional: ["n"])
        guard query["v"] == "2" else { throw MobileSharingProtocolError.invalidLink }
        let fragmentItems = try parseFragment(fragment)
        let secrets = try strict(items: fragmentItems, required: ["s"], optional: ["c"])
        guard let brokerRaw = query["b"], let broker = validateBroker(brokerRaw),
              let host = query["h"].flatMap({ MobileSharingBase64URL.decode($0, maximumBytes: 32) }), host.count == 32,
              let invitation = query["i"].flatMap({ MobileSharingBase64URL.decode($0, maximumBytes: 16) }), invitation.count == 16,
              let secret = secrets["s"].flatMap({ MobileSharingBase64URL.decode($0, maximumBytes: 32) }), secret.count == 32,
              let expiryRaw = query["e"], !expiryRaw.hasPrefix("+") && !expiryRaw.hasPrefix("0"),
              let expiry = Int64(expiryRaw), expiry > 0, String(expiry) == expiryRaw else {
            throw MobileSharingProtocolError.invalidLink
        }
        if let label = query["n"] { try validateLabel(label) }
        if let capability = secrets["c"] {
            guard capability.utf8.count <= MobileSharingWire.maxCapabilityBytes,
                  capability.utf8.allSatisfy({ byte in
                      (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) ||
                          (byte >= 0x30 && byte <= 0x39) || byte == 0x2D || byte == 0x5F
                  }) else {
                throw MobileSharingProtocolError.invalidLink
            }
        }
        return Self(broker: broker, hostKey: host, invitationID: invitation,
                    expiresAt: Date(timeIntervalSince1970: TimeInterval(expiry)), hostLabel: query["n"],
                    pairingSecret: secret, invitationCapability: secrets["c"])
    }

    private static func strict(items: [URLQueryItem], required: Set<String>, optional: Set<String>) throws -> [String: String] {
        var values: [String: String] = [:]
        for item in items {
            guard required.contains(item.name) || optional.contains(item.name), values[item.name] == nil,
                  let value = item.value, !value.isEmpty else { throw MobileSharingProtocolError.invalidLink }
            values[item.name] = value
        }
        guard required.isSubset(of: Set(values.keys)) else { throw MobileSharingProtocolError.invalidLink }
        return values
    }

    private static func parseFragment(_ raw: String) throws -> [URLQueryItem] {
        guard !raw.isEmpty, let values = URLComponents(string: "https://fragment.invalid/?" + raw)?.queryItems else {
            throw MobileSharingProtocolError.invalidLink
        }
        return values
    }

    private static func validateBroker(_ raw: String) -> URL? {
        guard var parts = URLComponents(string: raw), let scheme = parts.scheme?.lowercased(),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              scheme == "https" || (scheme == "http" && PeerBrokerAddress.isLoopback(host)) else { return nil }
        parts.scheme = scheme
        parts.host = host
        while parts.path.hasSuffix("/") && parts.path != "/" { parts.path.removeLast() }
        return parts.url
    }

    static func validateLabel(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= MobileSharingWire.maxLabelBytes,
              value.unicodeScalars.allSatisfy({ scalar in
                  scalar.properties.generalCategory != .control && scalar.properties.generalCategory != .format
              }) else {
            throw MobileSharingProtocolError.invalidLink
        }
    }
}

struct MobileSharingB64: Codable, Equatable, Sendable {
    let data: Data
    init(_ data: Data) { self.data = data }
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let decoded = MobileSharingBase64URL.decode(value, maximumBytes: MobileSharingWire.maxMessageBytes) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "base64url"))
        }
        data = decoded
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(MobileSharingBase64URL.encode(data))
    }
}

// swiftlint:disable identifier_name
struct MobileSharingPairRequest: Codable, Equatable, Sendable {
    var v = MobileSharingWire.version
    var type = "pair_request"
    var invitation_id: MobileSharingB64
    var device_key: MobileSharingB64
    var device_nonce: MobileSharingB64
    var device_name: String
    var mac: MobileSharingB64
    var sig: MobileSharingB64
}
struct MobileSharingPairAnswer: Codable, Equatable, Sendable {
    var v: Int; var type: String
    var invitation_id: MobileSharingB64; var host_key: MobileSharingB64
    var device_key: MobileSharingB64; var device_nonce: MobileSharingB64
    var request_hash: MobileSharingB64; var device_id: MobileSharingB64
    var reconnect_capability: MobileSharingB64
    var scope: String; var base_path: String; var host_label: String
    var mac: MobileSharingB64; var sig: MobileSharingB64
}
struct MobileSharingPairReject: Codable, Equatable, Sendable {
    var v: Int; var type: String; var invitation_id: MobileSharingB64; var reason: String
}
struct MobileSharingTransportHello: Codable, Equatable, Sendable {
    var v = MobileSharingWire.version; var type = "transport_hello"
    var device_key: MobileSharingB64; var device_id: MobileSharingB64
    var reconnect_capability: MobileSharingB64; var device_nonce: MobileSharingB64; var sig: MobileSharingB64
}
struct MobileSharingTransportChallenge: Codable, Equatable, Sendable {
    var v: Int; var type: String; var challenge_id: MobileSharingB64
    var host_key: MobileSharingB64; var host_nonce: MobileSharingB64
    var device_key: MobileSharingB64; var device_id: MobileSharingB64
    var expires_at: Int64; var sig: MobileSharingB64
}
struct MobileSharingTransportRequest: Codable, Equatable, Sendable {
    var v = MobileSharingWire.version; var type = "transport_request"
    var challenge_id: MobileSharingB64; var host_nonce: MobileSharingB64
    var device_key: MobileSharingB64; var device_nonce: MobileSharingB64
    var device_id: MobileSharingB64; var offer_sdp: String; var sig: MobileSharingB64
}
struct MobileSharingTransportAnswer: Codable, Equatable, Sendable {
    var v: Int; var type: String; var challenge_id: MobileSharingB64
    var host_key: MobileSharingB64; var host_nonce: MobileSharingB64
    var device_key: MobileSharingB64; var device_nonce: MobileSharingB64
    var request_hash: MobileSharingB64; var device_id: MobileSharingB64
    var answer_sdp: String; var sig: MobileSharingB64
}
// swiftlint:enable identifier_name

enum MobileSharingTranscript {
    static func build(label: String, fields: [Data]) -> Data {
        var output = Data()
        func append(_ field: Data) {
            var length = UInt32(field.count).bigEndian
            withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
            output.append(field)
        }
        append(Data(MobileSharingWire.domain.utf8))
        append(Data(label.utf8))
        fields.forEach(append)
        return output
    }

    static func macKey(_ secret: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(MobileSharingWire.macKeyLabel.utf8), using: SymmetricKey(data: secret)))
    }
    static func mac(secret: Data, transcript: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: transcript, using: SymmetricKey(data: macKey(secret))))
    }
    static func hash(_ transcript: Data) -> Data { Data(SHA256.hash(data: transcript)) }
    static func verify(_ signature: Data, key: Data, transcript: Data) -> Bool {
        guard signature.count == 64, key.count == 32,
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: key) else { return false }
        return publicKey.isValidSignature(signature, for: transcript)
    }

    static func pairRequest(_ request: MobileSharingPairRequest, hostKey: Data) -> Data {
        build(label: "pair-request", fields: [Data("device".utf8), request.invitation_id.data, hostKey,
                                               request.device_key.data, request.device_nonce.data, Data(request.device_name.utf8)])
    }
    static func pairAnswer(_ answer: MobileSharingPairAnswer) -> Data {
        build(label: "pair-answer", fields: [Data("host".utf8), answer.invitation_id.data, answer.host_key.data,
                                              answer.device_key.data, answer.device_nonce.data, answer.request_hash.data,
                                              answer.device_id.data, answer.reconnect_capability.data, Data(answer.scope.utf8),
                                              Data(answer.base_path.utf8), Data(answer.host_label.utf8)])
    }
    static func transportHello(_ hello: MobileSharingTransportHello, hostKey: Data) -> Data {
        build(label: "transport-hello", fields: [Data("device".utf8), hostKey, hello.device_key.data,
                                                  hello.device_id.data, hello.reconnect_capability.data, hello.device_nonce.data])
    }
    static func transportChallenge(_ challenge: MobileSharingTransportChallenge) -> Data {
        build(label: "transport-challenge", fields: [Data("host".utf8), challenge.challenge_id.data,
                                                       challenge.host_key.data, challenge.host_nonce.data,
                                                       challenge.device_key.data, challenge.device_id.data,
                                                       Data(String(challenge.expires_at).utf8)])
    }
    static func transportRequest(_ request: MobileSharingTransportRequest, hostKey: Data) -> Data {
        build(label: "transport-request", fields: [Data("device".utf8), request.challenge_id.data, hostKey,
                                                     request.host_nonce.data, request.device_key.data,
                                                     request.device_nonce.data, request.device_id.data,
                                                     Data(request.offer_sdp.utf8)])
    }
    static func transportAnswer(_ answer: MobileSharingTransportAnswer) -> Data {
        build(label: "transport-answer", fields: [Data("host".utf8), answer.challenge_id.data, answer.host_key.data,
                                                    answer.host_nonce.data, answer.device_key.data,
                                                    answer.device_nonce.data, answer.request_hash.data,
                                                    answer.device_id.data, Data(answer.answer_sdp.utf8)])
    }
    static func sas(secret: Data, invitationID: Data, hostKey: Data, deviceKey: Data) throws -> String {
        guard secret.count == 32, invitationID.count == 16, hostKey.count == 32, deviceKey.count == 32 else {
            throw MobileSharingProtocolError.invalid("SAS inputs")
        }
        let transcript = build(label: "pair-sas", fields: [invitationID, hostKey, deviceKey])
        let bytes = mac(secret: secret, transcript: transcript)
        let value = bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 1_000_000
        return String(format: "%06d", value)
    }
}

struct MobileSharingPairingAttempt: Sendable {
    let link: MobileSharingPairingLink
    let request: MobileSharingPairRequest
    let requestHash: Data
    let sas: String
    private let deviceSeed: Data

    init(link: MobileSharingPairingLink, credential: MobileSharingCredential, deviceName: String,
         now: Date = Date(), nonce: Data? = nil) throws {
        guard !link.isExpired(at: now) else { throw MobileSharingProtocolError.expired }
        try MobileSharingPairingLink.validateLabel(deviceName)
        guard credential.hostKey == link.hostKey,
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: credential.deviceSeed) else {
            throw MobileSharingProtocolError.invalid("device identity")
        }
        let deviceNonce = nonce ?? MobileSharingCrypto.random(32)
        guard deviceNonce.count == 32 else { throw MobileSharingProtocolError.invalid("device nonce") }
        var value = MobileSharingPairRequest(invitation_id: MobileSharingB64(link.invitationID),
                                              device_key: MobileSharingB64(key.publicKey.rawRepresentation),
                                              device_nonce: MobileSharingB64(deviceNonce), device_name: deviceName,
                                              mac: MobileSharingB64(Data()), sig: MobileSharingB64(Data()))
        let transcript = MobileSharingTranscript.pairRequest(value, hostKey: link.hostKey)
        value.mac = MobileSharingB64(MobileSharingTranscript.mac(secret: link.pairingSecret, transcript: transcript))
        value.sig = MobileSharingB64(try key.signature(for: transcript))
        self.link = link
        deviceSeed = credential.deviceSeed
        request = value
        requestHash = MobileSharingTranscript.hash(transcript)
        sas = try MobileSharingTranscript.sas(secret: link.pairingSecret, invitationID: link.invitationID,
                                              hostKey: link.hostKey, deviceKey: key.publicKey.rawRepresentation)
    }

    func verify(_ answer: MobileSharingPairAnswer) throws -> MobileSharingCredential {
        guard answer.v == 2, answer.type == "pair_answer", answer.host_key.data == link.hostKey else {
            throw MobileSharingProtocolError.hostIdentityChanged
        }
        guard answer.invitation_id == request.invitation_id, answer.device_key == request.device_key,
              answer.device_nonce == request.device_nonce, answer.request_hash.data == requestHash,
              answer.device_id.data.count == 16, answer.reconnect_capability.data.count == 32,
              answer.scope == "web-v1", MobileSharingCrypto.validBasePath(answer.base_path) else {
            throw MobileSharingProtocolError.invalid("pair answer binding")
        }
        if !answer.host_label.isEmpty { try MobileSharingPairingLink.validateLabel(answer.host_label) }
        let transcript = MobileSharingTranscript.pairAnswer(answer)
        guard MobileSharingCrypto.constantTimeEqual(answer.mac.data,
              MobileSharingTranscript.mac(secret: link.pairingSecret, transcript: transcript)) else {
            throw MobileSharingProtocolError.badMAC
        }
        guard MobileSharingTranscript.verify(answer.sig.data, key: link.hostKey, transcript: transcript) else {
            throw MobileSharingProtocolError.badSignature
        }
        return MobileSharingCredential(hostKey: link.hostKey, deviceSeed: deviceSeed,
                                       deviceID: MobileSharingBase64URL.encode(answer.device_id.data),
                                       reconnectCapability: answer.reconnect_capability.data, brokerURL: link.broker,
                                       scope: answer.scope, basePath: answer.base_path,
                                       hostLabel: answer.host_label.isEmpty ? link.hostLabel : answer.host_label,
                                       pairedAt: Date())
    }
}

struct MobileSharingTransportAttempt: Sendable {
    let request: MobileSharingTransportRequest
    let requestHash: Data
    private let hostKey: Data

    static func hello(credential: MobileSharingCredential, nonce: Data? = nil) throws -> MobileSharingTransportHello {
        guard let deviceIDRaw = credential.deviceID.flatMap({ MobileSharingBase64URL.decode($0, maximumBytes: 16) }),
              deviceIDRaw.count == 16, let capability = credential.reconnectCapability, capability.count == 32,
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: credential.deviceSeed) else {
            throw MobileSharingProtocolError.invalid("transport credential")
        }
        let deviceNonce = nonce ?? MobileSharingCrypto.random(32)
        guard deviceNonce.count == 32 else { throw MobileSharingProtocolError.invalid("transport nonce") }
        var hello = MobileSharingTransportHello(device_key: MobileSharingB64(key.publicKey.rawRepresentation),
                                                 device_id: MobileSharingB64(deviceIDRaw),
                                                 reconnect_capability: MobileSharingB64(capability),
                                                 device_nonce: MobileSharingB64(deviceNonce), sig: MobileSharingB64(Data()))
        let transcript = MobileSharingTranscript.transportHello(hello, hostKey: credential.hostKey)
        hello.sig = MobileSharingB64(try key.signature(for: transcript))
        return hello
    }

    init(challenge: MobileSharingTransportChallenge, credential: MobileSharingCredential,
         offerSDP: String, now: Date = Date(), nonce: Data? = nil) throws {
        guard challenge.v == 2, challenge.type == "transport_challenge",
              challenge.host_key.data == credential.hostKey else { throw MobileSharingProtocolError.hostIdentityChanged }
        guard let deviceIDRaw = credential.deviceID.flatMap({ MobileSharingBase64URL.decode($0, maximumBytes: 16) }),
              deviceIDRaw.count == 16,
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: credential.deviceSeed),
              challenge.challenge_id.data.count == 16, challenge.host_nonce.data.count == 32,
              challenge.device_key.data == key.publicKey.rawRepresentation,
              challenge.device_id.data == deviceIDRaw,
              Int64(now.timeIntervalSince1970) < challenge.expires_at else {
            throw MobileSharingProtocolError.invalid("transport challenge")
        }
        let challengeTranscript = MobileSharingTranscript.transportChallenge(challenge)
        guard MobileSharingTranscript.verify(challenge.sig.data, key: credential.hostKey,
                                             transcript: challengeTranscript) else {
            throw MobileSharingProtocolError.badSignature
        }
        _ = try MobileSharingCrypto.fingerprint(in: offerSDP)
        let deviceNonce = nonce ?? MobileSharingCrypto.random(32)
        guard deviceNonce.count == 32 else { throw MobileSharingProtocolError.invalid("transport nonce") }
        var value = MobileSharingTransportRequest(challenge_id: challenge.challenge_id,
                                                   host_nonce: challenge.host_nonce,
                                                   device_key: MobileSharingB64(key.publicKey.rawRepresentation),
                                                   device_nonce: MobileSharingB64(deviceNonce),
                                                   device_id: MobileSharingB64(deviceIDRaw), offer_sdp: offerSDP,
                                                   sig: MobileSharingB64(Data()))
        let transcript = MobileSharingTranscript.transportRequest(value, hostKey: credential.hostKey)
        value.sig = MobileSharingB64(try key.signature(for: transcript))
        request = value
        requestHash = MobileSharingTranscript.hash(transcript)
        hostKey = credential.hostKey
    }

    func verify(_ answer: MobileSharingTransportAnswer) throws -> String {
        guard answer.v == 2, answer.type == "transport_answer", answer.host_key.data == hostKey else {
            throw MobileSharingProtocolError.hostIdentityChanged
        }
        guard answer.challenge_id == request.challenge_id, answer.host_nonce == request.host_nonce,
              answer.device_key == request.device_key, answer.device_nonce == request.device_nonce,
              answer.device_id == request.device_id, answer.request_hash.data == requestHash else {
            throw MobileSharingProtocolError.invalid("transport answer binding")
        }
        guard MobileSharingTranscript.verify(answer.sig.data, key: hostKey,
                                             transcript: MobileSharingTranscript.transportAnswer(answer)) else {
            throw MobileSharingProtocolError.badSignature
        }
        _ = try MobileSharingCrypto.fingerprint(in: answer.answer_sdp)
        return answer.answer_sdp
    }
}

enum MobileSharingCrypto {
    static func random(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
    static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        var difference = UInt8(lhs.count == rhs.count ? 0 : 1)
        for index in 0..<max(lhs.count, rhs.count) {
            difference |= (index < lhs.count ? lhs[index] : 0) ^ (index < rhs.count ? rhs[index] : 0)
        }
        return difference == 0
    }
    static func validBasePath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.contains("?") && !path.contains("#") && !path.contains("\\") &&
            !path.contains("\r") && !path.contains("\n") && !path.contains("..")
    }

    static func fingerprint(in sdp: String) throws -> String {
        guard !sdp.isEmpty, sdp.utf8.count <= MobileSharingWire.maxSDPBytes, !sdp.utf8.contains(0) else {
            throw MobileSharingProtocolError.invalid("SDP size")
        }
        let byteCounts = ["sha-256": 32, "sha-384": 48, "sha-512": 64]
        var found: String?
        for raw in sdp.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
            var bytes = Array(raw)
            if bytes.last == UInt8(ascii: "\r") { bytes.removeLast() }
            let line = String(decoding: bytes, as: UTF8.self)
            guard line.hasPrefix("a=fingerprint:") else { continue }
            let value = line.dropFirst("a=fingerprint:".count).trimmingCharacters(in: .whitespaces)
            guard let split = value.firstIndex(of: " ") else { throw MobileSharingProtocolError.invalid("SDP fingerprint") }
            let algorithm = value[..<split].lowercased()
            let hex = value[value.index(after: split)...].trimmingCharacters(in: .whitespaces)
            guard let count = byteCounts[algorithm] else { throw MobileSharingProtocolError.invalid("SDP fingerprint") }
            let pieces = hex.split(separator: ":")
            guard pieces.count == count, pieces.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) }) else {
                throw MobileSharingProtocolError.invalid("SDP fingerprint")
            }
            let normalized = algorithm + " " + pieces.map { $0.uppercased() }.joined(separator: ":")
            guard found == nil || found == normalized else { throw MobileSharingProtocolError.invalid("SDP fingerprints disagree") }
            found = normalized
        }
        guard let found else { throw MobileSharingProtocolError.invalid("SDP fingerprint missing") }
        return found
    }
}

enum MobileSharingMessageCodec {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= MobileSharingWire.maxMessageBytes else { throw MobileSharingProtocolError.invalid("message size") }
        return data
    }

    static func decode<T: Decodable>(_ type: T.Type, data: Data, expectedType: String, fields: Set<String>) throws -> T {
        guard data.count <= MobileSharingWire.maxMessageBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == fields, object["v"] as? Int == 2,
              object["type"] as? String == expectedType else { throw MobileSharingProtocolError.invalid("message shape") }
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw MobileSharingProtocolError.invalid("message fields") }
    }
}
