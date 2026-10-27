import CryptoKit
import Foundation
import Network

// MARK: - Frozen core protocol v2

enum LinkedDevicesWire {
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

/// User-visible pairing diagnostics deliberately exclude arbitrary server text,
/// NSError userInfo and URLs: all can contain invitation or reconnect secrets.
struct LinkedDevicesPairingFailure: LocalizedError {
    enum Stage: String {
        case openingInvitation = "opening-invitation"
        case preparingIdentity = "preparing-identity"
        case contactingBroker = "contacting-rendezvous"
        case waitingForApproval = "waiting-for-approval"
        case verifyingHost = "verifying-host"
        case savingIdentity = "saving-identity"
        case savingConnection = "saving-connection"
        case startingLocalBridge = "starting-local-chat-bridge"
        case activatingLocalBridge = "activating-local-chat-bridge"
        case savingCatalog = "saving-connections-list"

        var isEnrollment: Bool {
            switch self {
            case .savingConnection, .startingLocalBridge, .activatingLocalBridge, .savingCatalog: true
            default: false
            }
        }

        var summary: String {
            switch self {
            case .openingInvitation: "Could not open the pairing invitation."
            case .preparingIdentity: "Could not prepare this iPhone’s secure device identity."
            case .contactingBroker: "Could not contact the pairing rendezvous service."
            case .waitingForApproval: "The iPhone did not receive a complete approval response from the host."
            case .verifyingHost: "The host’s approval response could not be verified."
            case .savingIdentity: "The host’s approval was verified, but its credentials could not be saved on this iPhone."
            case .savingConnection: "The host’s approval and credentials were saved, but the local connection could not be set up."
            case .startingLocalBridge: "The host approved this iPhone, but its local chat listener could not start."
            case .activatingLocalBridge: "The host approved this iPhone, but its local chat bridge could not be activated."
            case .savingCatalog: "The host approved this iPhone, but it could not be added to Connections."
            }
        }
    }

    let stage: Stage
    let reason: String
    let recovery: String
    let enrollmentRolledBack: Bool

    init(stage: Stage, error: Error, enrollmentRolledBack: Bool = false) {
        self.enrollmentRolledBack = enrollmentRolledBack
        self.stage = stage
        switch error {
        case let value as LinkedDevicesStorageError:
            if case .unavailable(let status) = value {
                reason = "Secure storage failed (Keychain status \(status))."
            } else {
                reason = value.localizedDescription
            }
            recovery = "Unlock the iPhone and try again. If the host already lists this device, remove that incomplete link there before creating a new QR code."
        case LinkedDevicesProtocolError.invalid:
            reason = "The host returned data that does not match Linked devices protocol v2."
            recovery = "Check that the app and term-llm host are up to date, then create a new QR code."
        case let value as LinkedDevicesProtocolError:
            reason = value.localizedDescription
            recovery = "Confirm you are linking to the intended host, then create a new QR code in its Linked devices settings."
        case LinkedDevicesBrokerError.closed(let code, _):
            reason = "The rendezvous WebSocket closed (code \(code)). Approval may not have reached this iPhone."
            recovery = "Keep term-llm running and both devices online. Check Linked devices on the host before creating a new QR code."
        case LinkedDevicesBrokerError.unauthorized:
            reason = "The rendezvous service did not accept this invitation. It may have expired or already been used."
            recovery = "Create a new QR code in the host’s Linked devices settings."
        case LinkedDevicesBrokerError.peerOffline where stage == .waitingForApproval:
            reason = "Timed out waiting for the host’s approval response. This does not confirm whether the host saved the device."
            recovery = "Check Linked devices on the host. Keep both devices online and create a new QR code if necessary."
        case let value as LinkedDevicesBrokerError:
            reason = value.localizedDescription
            recovery = "Keep term-llm running, check the iPhone’s network connection, and create a new QR code if the invitation expired."
        case let value as NWError:
            switch value {
            case .posix(let code):
                reason = code == .EADDRINUSE
                    ? "The iPhone’s local chat connection could not start because its port is already in use (POSIX \(code.rawValue))."
                    : "The network connection failed (POSIX \(code.rawValue))."
            case .dns(let code): reason = "The network connection failed (DNS \(code))."
            case .tls(let code): reason = "The secure network connection failed (TLS \(code))."
            @unknown default: reason = "The network connection failed."
            }
            recovery = "Close this sheet and try again. If this repeats, report the error code and diagnostic stage below."
        case let value as HubConnectionStore.ValidationError:
            reason = value.localizedDescription
            recovery = "Check the saved Connections list before trying to link again."
        case let value as URLError:
            reason = "A network request failed (URL error \(value.code.rawValue))."
            recovery = "Check the iPhone’s internet connection and that the rendezvous service is reachable, then try a new QR code."
        default:
            reason = "An unexpected local error prevented linking."
            recovery = "Try again. If this repeats, report the diagnostic stage below."
        }
    }

    var errorDescription: String? {
        let summary = enrollmentRolledBack
            ? "The host approved this iPhone, but local connection setup failed. No connection was added."
            : stage.summary
        let guidance = enrollmentRolledBack
            ? "Revoke this incomplete device link in the host’s Linked devices settings before scanning a new QR code. If this repeats, report the error code and diagnostic stage below."
            : stage.isEnrollment
                ? "Close this sheet and check Connections. If the host is missing there, try linking again; do not clear the app’s data."
                : recovery
        return "\(summary)\n\n\(reason)\n\n\(guidance)\n\nDiagnostic stage: \(stage.rawValue)"
    }
}

enum LinkedDevicesProtocolError: Error, Equatable, LocalizedError {
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
        case .invalidLink: "This pairing link is not valid."
        case .expired: "This invitation has expired. Create a new one on the host."
        case .invalid(_): "The host returned invalid Linked devices data."
        case .badMAC, .badSignature: "The host identity could not be authenticated. Pairing was stopped."
        case .hostIdentityChanged: "The host identity changed. The connection was stopped."
        case .rejected(_): "The host did not approve this device."
        case .revoked: "Access was revoked or the shared target was reset."
        }
    }
}

struct LinkedDevicesPairingLink: Equatable, Sendable {
    let broker: URL
    let hostKey: Data
    let invitationID: Data
    let expiresAt: Date
    let hostLabel: String?
    let pairingSecret: Data
    let invitationCapability: String?

    var hostID: String { LinkedDevicesBase64URL.encode(Data(SHA256.hash(data: hostKey))) }
    var invitationIDString: String { LinkedDevicesBase64URL.encode(invitationID) }
    var hostFingerprint: String {
        let digest = SHA256.hash(data: hostKey)
        return digest.prefix(8).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    func isExpired(at date: Date = Date()) -> Bool { date >= expiresAt }

    static func parse(_ raw: String) throws -> Self {
        guard !raw.isEmpty, raw.utf8.count <= LinkedDevicesWire.maxLinkBytes,
              let components = URLComponents(string: raw), components.scheme == "termllm",
              components.host == "pair", components.user == nil, components.password == nil,
              components.port == nil, components.path.isEmpty,
              let encodedQuery = components.percentEncodedQuery,
              let encodedFragment = components.percentEncodedFragment else {
            throw LinkedDevicesProtocolError.invalidLink
        }
        let query = try strict(raw: encodedQuery, required: ["v", "b", "h", "i", "e"], optional: ["n"])
        guard query["v"] == "2" else { throw LinkedDevicesProtocolError.invalidLink }
        let secrets = try strict(raw: encodedFragment, required: ["s"], optional: ["c"])
        guard let brokerRaw = query["b"], let broker = validateBroker(brokerRaw),
              let host = query["h"].flatMap({ LinkedDevicesBase64URL.decode($0, maximumBytes: 32) }), host.count == 32,
              let invitation = query["i"].flatMap({ LinkedDevicesBase64URL.decode($0, maximumBytes: 16) }), invitation.count == 16,
              let secret = secrets["s"].flatMap({ LinkedDevicesBase64URL.decode($0, maximumBytes: 32) }), secret.count == 32,
              let expiryRaw = query["e"], !expiryRaw.hasPrefix("+") && !expiryRaw.hasPrefix("0"),
              let expiry = Int64(expiryRaw), expiry > 0, String(expiry) == expiryRaw else {
            throw LinkedDevicesProtocolError.invalidLink
        }
        if let label = query["n"] { try validateLabel(label) }
        if let capability = secrets["c"] {
            guard capability.utf8.count <= LinkedDevicesWire.maxCapabilityBytes,
                  capability.utf8.allSatisfy({ byte in
                      (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) ||
                          (byte >= 0x30 && byte <= 0x39) || byte == 0x2D || byte == 0x5F
                  }) else {
                throw LinkedDevicesProtocolError.invalidLink
            }
        }
        return Self(broker: broker, hostKey: host, invitationID: invitation,
                    expiresAt: Date(timeIntervalSince1970: TimeInterval(expiry)), hostLabel: query["n"],
                    pairingSecret: secret, invitationCapability: secrets["c"])
    }

    private static func strict(raw: String, required: Set<String>, optional: Set<String>) throws -> [String: String] {
        guard !raw.isEmpty else { throw LinkedDevicesProtocolError.invalidLink }
        var values: [String: String] = [:]
        for field in raw.split(separator: "&", omittingEmptySubsequences: false) {
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2,
                  let name = formDecode(String(pair[0])), let value = formDecode(String(pair[1])),
                  required.contains(name) || optional.contains(name), values[name] == nil,
                  !value.isEmpty else { throw LinkedDevicesProtocolError.invalidLink }
            values[name] = value
        }
        guard required.isSubset(of: Set(values.keys)) else { throw LinkedDevicesProtocolError.invalidLink }
        return values
    }

    /// Core uses Go's QueryEscape/QueryUnescape contract, where `+` means a
    /// space and a literal plus must be `%2B`.
    private static func formDecode(_ value: String) -> String? {
        value.replacingOccurrences(of: "+", with: "%20").removingPercentEncoding
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
        guard !value.isEmpty, value.utf8.count <= LinkedDevicesWire.maxLabelBytes,
              value.unicodeScalars.allSatisfy({ scalar in
                  scalar.properties.generalCategory != .control && scalar.properties.generalCategory != .format
              }) else {
            throw LinkedDevicesProtocolError.invalidLink
        }
    }
}

struct LinkedDevicesB64: Codable, Equatable, Sendable {
    let data: Data
    init(_ data: Data) { self.data = data }
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let decoded = LinkedDevicesBase64URL.decode(value, maximumBytes: LinkedDevicesWire.maxMessageBytes) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "base64url"))
        }
        data = decoded
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(LinkedDevicesBase64URL.encode(data))
    }
}

// swiftlint:disable identifier_name
struct LinkedDevicesPairRequest: Codable, Equatable, Sendable {
    var v = LinkedDevicesWire.version
    var type = "pair_request"
    var invitation_id: LinkedDevicesB64
    var device_key: LinkedDevicesB64
    var device_nonce: LinkedDevicesB64
    var device_name: String
    var mac: LinkedDevicesB64
    var sig: LinkedDevicesB64
}
struct LinkedDevicesPairAnswer: Codable, Equatable, Sendable {
    var v: Int; var type: String
    var invitation_id: LinkedDevicesB64; var host_key: LinkedDevicesB64
    var device_key: LinkedDevicesB64; var device_nonce: LinkedDevicesB64
    var request_hash: LinkedDevicesB64; var device_id: LinkedDevicesB64
    var reconnect_capability: LinkedDevicesB64
    var scope: String; var base_path: String; var host_label: String
    var mac: LinkedDevicesB64; var sig: LinkedDevicesB64
}
struct LinkedDevicesPairReject: Codable, Equatable, Sendable {
    var v: Int; var type: String; var invitation_id: LinkedDevicesB64; var reason: String
}
struct LinkedDevicesTransportHello: Codable, Equatable, Sendable {
    var v = LinkedDevicesWire.version; var type = "transport_hello"
    var device_key: LinkedDevicesB64; var device_id: LinkedDevicesB64
    var reconnect_capability: LinkedDevicesB64; var device_nonce: LinkedDevicesB64; var sig: LinkedDevicesB64
}
struct LinkedDevicesTransportChallenge: Codable, Equatable, Sendable {
    var v: Int; var type: String; var challenge_id: LinkedDevicesB64
    var host_key: LinkedDevicesB64; var host_nonce: LinkedDevicesB64
    var device_key: LinkedDevicesB64; var device_id: LinkedDevicesB64
    var expires_at: Int64; var sig: LinkedDevicesB64
}
struct LinkedDevicesTransportRequest: Codable, Equatable, Sendable {
    var v = LinkedDevicesWire.version; var type = "transport_request"
    var challenge_id: LinkedDevicesB64; var host_nonce: LinkedDevicesB64
    var device_key: LinkedDevicesB64; var device_nonce: LinkedDevicesB64
    var device_id: LinkedDevicesB64; var offer_sdp: String; var sig: LinkedDevicesB64
}
struct LinkedDevicesTransportAnswer: Codable, Equatable, Sendable {
    var v: Int; var type: String; var challenge_id: LinkedDevicesB64
    var host_key: LinkedDevicesB64; var host_nonce: LinkedDevicesB64
    var device_key: LinkedDevicesB64; var device_nonce: LinkedDevicesB64
    var request_hash: LinkedDevicesB64; var device_id: LinkedDevicesB64
    var answer_sdp: String; var sig: LinkedDevicesB64
}
// swiftlint:enable identifier_name

enum LinkedDevicesTranscript {
    static func build(label: String, fields: [Data]) -> Data {
        var output = Data()
        func append(_ field: Data) {
            var length = UInt32(field.count).bigEndian
            withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
            output.append(field)
        }
        append(Data(LinkedDevicesWire.domain.utf8))
        append(Data(label.utf8))
        fields.forEach(append)
        return output
    }

    static func macKey(_ secret: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(LinkedDevicesWire.macKeyLabel.utf8), using: SymmetricKey(data: secret)))
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

    static func pairRequest(_ request: LinkedDevicesPairRequest, hostKey: Data) -> Data {
        build(label: "pair-request", fields: [Data("device".utf8), request.invitation_id.data, hostKey,
                                               request.device_key.data, request.device_nonce.data, Data(request.device_name.utf8)])
    }
    static func pairAnswer(_ answer: LinkedDevicesPairAnswer) -> Data {
        build(label: "pair-answer", fields: [Data("host".utf8), answer.invitation_id.data, answer.host_key.data,
                                              answer.device_key.data, answer.device_nonce.data, answer.request_hash.data,
                                              answer.device_id.data, answer.reconnect_capability.data, Data(answer.scope.utf8),
                                              Data(answer.base_path.utf8), Data(answer.host_label.utf8)])
    }
    static func transportHello(_ hello: LinkedDevicesTransportHello, hostKey: Data) -> Data {
        build(label: "transport-hello", fields: [Data("device".utf8), hostKey, hello.device_key.data,
                                                  hello.device_id.data, hello.reconnect_capability.data, hello.device_nonce.data])
    }
    static func transportChallenge(_ challenge: LinkedDevicesTransportChallenge) -> Data {
        build(label: "transport-challenge", fields: [Data("host".utf8), challenge.challenge_id.data,
                                                       challenge.host_key.data, challenge.host_nonce.data,
                                                       challenge.device_key.data, challenge.device_id.data,
                                                       Data(String(challenge.expires_at).utf8)])
    }
    static func transportRequest(_ request: LinkedDevicesTransportRequest, hostKey: Data) -> Data {
        build(label: "transport-request", fields: [Data("device".utf8), request.challenge_id.data, hostKey,
                                                     request.host_nonce.data, request.device_key.data,
                                                     request.device_nonce.data, request.device_id.data,
                                                     Data(request.offer_sdp.utf8)])
    }
    static func transportAnswer(_ answer: LinkedDevicesTransportAnswer) -> Data {
        build(label: "transport-answer", fields: [Data("host".utf8), answer.challenge_id.data, answer.host_key.data,
                                                    answer.host_nonce.data, answer.device_key.data,
                                                    answer.device_nonce.data, answer.request_hash.data,
                                                    answer.device_id.data, Data(answer.answer_sdp.utf8)])
    }
    static func sas(secret: Data, invitationID: Data, hostKey: Data, deviceKey: Data) throws -> String {
        guard secret.count == 32, invitationID.count == 16, hostKey.count == 32, deviceKey.count == 32 else {
            throw LinkedDevicesProtocolError.invalid("SAS inputs")
        }
        let transcript = build(label: "pair-sas", fields: [invitationID, hostKey, deviceKey])
        let bytes = mac(secret: secret, transcript: transcript)
        let value = bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 1_000_000
        return String(format: "%06d", value)
    }
}

struct LinkedDevicesPairingAttempt: Sendable {
    let link: LinkedDevicesPairingLink
    let request: LinkedDevicesPairRequest
    let requestHash: Data
    let sas: String
    private let deviceSeed: Data

    init(link: LinkedDevicesPairingLink, credential: LinkedDevicesCredential, deviceName: String,
         now: Date = Date(), nonce: Data? = nil) throws {
        guard !link.isExpired(at: now) else { throw LinkedDevicesProtocolError.expired }
        try LinkedDevicesPairingLink.validateLabel(deviceName)
        guard credential.hostKey == link.hostKey,
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: credential.deviceSeed) else {
            throw LinkedDevicesProtocolError.invalid("device identity")
        }
        let deviceNonce = nonce ?? LinkedDevicesCrypto.random(32)
        guard deviceNonce.count == 32 else { throw LinkedDevicesProtocolError.invalid("device nonce") }
        var value = LinkedDevicesPairRequest(invitation_id: LinkedDevicesB64(link.invitationID),
                                              device_key: LinkedDevicesB64(key.publicKey.rawRepresentation),
                                              device_nonce: LinkedDevicesB64(deviceNonce), device_name: deviceName,
                                              mac: LinkedDevicesB64(Data()), sig: LinkedDevicesB64(Data()))
        let transcript = LinkedDevicesTranscript.pairRequest(value, hostKey: link.hostKey)
        value.mac = LinkedDevicesB64(LinkedDevicesTranscript.mac(secret: link.pairingSecret, transcript: transcript))
        value.sig = LinkedDevicesB64(try key.signature(for: transcript))
        self.link = link
        deviceSeed = credential.deviceSeed
        request = value
        requestHash = LinkedDevicesTranscript.hash(transcript)
        sas = try LinkedDevicesTranscript.sas(secret: link.pairingSecret, invitationID: link.invitationID,
                                              hostKey: link.hostKey, deviceKey: key.publicKey.rawRepresentation)
    }

    func verify(_ answer: LinkedDevicesPairAnswer) throws -> LinkedDevicesCredential {
        guard answer.v == 2, answer.type == "pair_answer", answer.host_key.data == link.hostKey else {
            throw LinkedDevicesProtocolError.hostIdentityChanged
        }
        guard answer.invitation_id == request.invitation_id, answer.device_key == request.device_key,
              answer.device_nonce == request.device_nonce, answer.request_hash.data == requestHash,
              answer.device_id.data.count == 16, answer.reconnect_capability.data.count == 32,
              answer.scope == "web-v1", LinkedDevicesCrypto.validBasePath(answer.base_path) else {
            throw LinkedDevicesProtocolError.invalid("pair answer binding")
        }
        if !answer.host_label.isEmpty { try LinkedDevicesPairingLink.validateLabel(answer.host_label) }
        let transcript = LinkedDevicesTranscript.pairAnswer(answer)
        guard LinkedDevicesCrypto.constantTimeEqual(answer.mac.data,
              LinkedDevicesTranscript.mac(secret: link.pairingSecret, transcript: transcript)) else {
            throw LinkedDevicesProtocolError.badMAC
        }
        guard LinkedDevicesTranscript.verify(answer.sig.data, key: link.hostKey, transcript: transcript) else {
            throw LinkedDevicesProtocolError.badSignature
        }
        return LinkedDevicesCredential(hostKey: link.hostKey, deviceSeed: deviceSeed,
                                       deviceID: LinkedDevicesBase64URL.encode(answer.device_id.data),
                                       reconnectCapability: answer.reconnect_capability.data, brokerURL: link.broker,
                                       scope: answer.scope, basePath: answer.base_path,
                                       hostLabel: answer.host_label.isEmpty ? link.hostLabel : answer.host_label,
                                       pairedAt: Date())
    }
}

struct LinkedDevicesTransportAttempt: Sendable {
    let request: LinkedDevicesTransportRequest
    let requestHash: Data
    private let hostKey: Data

    static func hello(credential: LinkedDevicesCredential, nonce: Data? = nil) throws -> LinkedDevicesTransportHello {
        guard let deviceIDRaw = credential.deviceID.flatMap({ LinkedDevicesBase64URL.decode($0, maximumBytes: 16) }),
              deviceIDRaw.count == 16, let capability = credential.reconnectCapability, capability.count == 32,
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: credential.deviceSeed) else {
            throw LinkedDevicesProtocolError.invalid("transport credential")
        }
        let deviceNonce = nonce ?? LinkedDevicesCrypto.random(32)
        guard deviceNonce.count == 32 else { throw LinkedDevicesProtocolError.invalid("transport nonce") }
        var hello = LinkedDevicesTransportHello(device_key: LinkedDevicesB64(key.publicKey.rawRepresentation),
                                                 device_id: LinkedDevicesB64(deviceIDRaw),
                                                 reconnect_capability: LinkedDevicesB64(capability),
                                                 device_nonce: LinkedDevicesB64(deviceNonce), sig: LinkedDevicesB64(Data()))
        let transcript = LinkedDevicesTranscript.transportHello(hello, hostKey: credential.hostKey)
        hello.sig = LinkedDevicesB64(try key.signature(for: transcript))
        return hello
    }

    init(challenge: LinkedDevicesTransportChallenge, credential: LinkedDevicesCredential,
         offerSDP: String, now: Date = Date(), nonce: Data? = nil) throws {
        guard challenge.v == 2, challenge.type == "transport_challenge",
              challenge.host_key.data == credential.hostKey else { throw LinkedDevicesProtocolError.hostIdentityChanged }
        guard let deviceIDRaw = credential.deviceID.flatMap({ LinkedDevicesBase64URL.decode($0, maximumBytes: 16) }),
              deviceIDRaw.count == 16,
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: credential.deviceSeed),
              challenge.challenge_id.data.count == 16, challenge.host_nonce.data.count == 32,
               challenge.device_key.data == key.publicKey.rawRepresentation,
               challenge.device_id.data == deviceIDRaw,
               Int64(now.timeIntervalSince1970) - 30 < challenge.expires_at else {
            throw LinkedDevicesProtocolError.invalid("transport challenge")
        }
        let challengeTranscript = LinkedDevicesTranscript.transportChallenge(challenge)
        guard LinkedDevicesTranscript.verify(challenge.sig.data, key: credential.hostKey,
                                             transcript: challengeTranscript) else {
            throw LinkedDevicesProtocolError.badSignature
        }
        _ = try LinkedDevicesCrypto.fingerprint(in: offerSDP)
        let deviceNonce = nonce ?? LinkedDevicesCrypto.random(32)
        guard deviceNonce.count == 32 else { throw LinkedDevicesProtocolError.invalid("transport nonce") }
        var value = LinkedDevicesTransportRequest(challenge_id: challenge.challenge_id,
                                                   host_nonce: challenge.host_nonce,
                                                   device_key: LinkedDevicesB64(key.publicKey.rawRepresentation),
                                                   device_nonce: LinkedDevicesB64(deviceNonce),
                                                   device_id: LinkedDevicesB64(deviceIDRaw), offer_sdp: offerSDP,
                                                   sig: LinkedDevicesB64(Data()))
        let transcript = LinkedDevicesTranscript.transportRequest(value, hostKey: credential.hostKey)
        value.sig = LinkedDevicesB64(try key.signature(for: transcript))
        request = value
        requestHash = LinkedDevicesTranscript.hash(transcript)
        hostKey = credential.hostKey
    }

    func verify(_ answer: LinkedDevicesTransportAnswer) throws -> String {
        guard answer.v == 2, answer.type == "transport_answer", answer.host_key.data == hostKey else {
            throw LinkedDevicesProtocolError.hostIdentityChanged
        }
        guard answer.challenge_id == request.challenge_id, answer.host_nonce == request.host_nonce,
              answer.device_key == request.device_key, answer.device_nonce == request.device_nonce,
              answer.device_id == request.device_id, answer.request_hash.data == requestHash else {
            throw LinkedDevicesProtocolError.invalid("transport answer binding")
        }
        guard LinkedDevicesTranscript.verify(answer.sig.data, key: hostKey,
                                             transcript: LinkedDevicesTranscript.transportAnswer(answer)) else {
            throw LinkedDevicesProtocolError.badSignature
        }
        _ = try LinkedDevicesCrypto.fingerprint(in: answer.answer_sdp)
        return answer.answer_sdp
    }
}

enum LinkedDevicesCrypto {
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
        guard !sdp.isEmpty, sdp.utf8.count <= LinkedDevicesWire.maxSDPBytes, !sdp.utf8.contains(0) else {
            throw LinkedDevicesProtocolError.invalid("SDP size")
        }
        let byteCounts = ["sha-256": 32, "sha-384": 48, "sha-512": 64]
        var found: String?
        for raw in sdp.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
            var bytes = Array(raw)
            if bytes.last == UInt8(ascii: "\r") { bytes.removeLast() }
            let line = String(decoding: bytes, as: UTF8.self)
            guard line.hasPrefix("a=fingerprint:") else { continue }
            let value = line.dropFirst("a=fingerprint:".count).trimmingCharacters(in: .whitespaces)
            guard let split = value.firstIndex(of: " ") else { throw LinkedDevicesProtocolError.invalid("SDP fingerprint") }
            let algorithm = value[..<split].lowercased()
            let hex = value[value.index(after: split)...].trimmingCharacters(in: .whitespaces)
            guard let count = byteCounts[algorithm] else { throw LinkedDevicesProtocolError.invalid("SDP fingerprint") }
            let pieces = hex.split(separator: ":")
            guard pieces.count == count, pieces.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) }) else {
                throw LinkedDevicesProtocolError.invalid("SDP fingerprint")
            }
            let normalized = algorithm + " " + pieces.map { $0.uppercased() }.joined(separator: ":")
            guard found == nil || found == normalized else { throw LinkedDevicesProtocolError.invalid("SDP fingerprints disagree") }
            found = normalized
        }
        guard let found else { throw LinkedDevicesProtocolError.invalid("SDP fingerprint missing") }
        return found
    }
}

enum LinkedDevicesMessageCodec {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= LinkedDevicesWire.maxMessageBytes else { throw LinkedDevicesProtocolError.invalid("message size") }
        return data
    }

    static func decode<T: Decodable>(_ type: T.Type, data: Data, expectedType: String, fields: Set<String>) throws -> T {
        guard data.count <= LinkedDevicesWire.maxMessageBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == fields, object["v"] as? Int == 2,
              object["type"] as? String == expectedType else { throw LinkedDevicesProtocolError.invalid("message shape") }
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw LinkedDevicesProtocolError.invalid("message fields") }
    }
}
