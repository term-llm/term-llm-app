import CryptoKit
import Foundation
import UIKit

#if canImport(WebRTC)
final class MobileSharingConnector: MobileSharingSessionConnecting, @unchecked Sendable {
    struct Paired: @unchecked Sendable {
        let credential: MobileSharingCredential
        let live: MobileSharingLiveConnection?
    }

    private let identities: MobileSharingIdentityStore
    private let clock: @Sendable () -> Date

    init(identities: MobileSharingIdentityStore, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.identities = identities
        self.clock = clock
    }

    func pair(link: MobileSharingPairingLink, deviceName: String,
              sasReady: @escaping @Sendable (String) -> Void,
              closed: @escaping @Sendable () -> Void) async throws -> Paired {
        guard !link.isExpired(at: clock()) else { throw MobileSharingProtocolError.expired }
        guard let capability = link.invitationCapability else {
            throw MobileSharingProtocolError.invalidLink
        }
        let prepared = try identities.prepare(hostKey: link.hostKey)
        let attempt = try MobileSharingPairingAttempt(link: link, credential: prepared,
                                                       deviceName: Self.safeDeviceName(deviceName), now: clock())
        let broker = try MobileSharingBrokerClient(baseURL: link.broker)
        let socket = try await broker.dial(hostID: link.hostID, kind: "invitation",
                                           peerID: link.invitationIDString, capability: capability)
        do {
            try await socket.send(attempt.request)
            sasReady(attempt.sas)
            let answer = try await waitForPairAnswer(socket, invitationID: link.invitationID,
                                                     deadline: link.expiresAt)
            var credential = try attempt.verify(answer)
            // PairingAttempt preserves the identity already durably prepared.
            credential.deviceSeed = prepared.deviceSeed
            try identities.save(credential)
            // Pairing is identity-only. The consumed invitation socket never
            // carries SDP; close it, then use the durable device slot for the
            // first signed transport handshake exactly like every reconnect.
            socket.close()
            let live: MobileSharingLiveConnection?
            do {
                live = try await reconnect(credential: credential, closed: closed)
            } catch {
                // Approval is durable and revocation-only. Preserve the source
                // even when this first transport attempt is cancelled/offline;
                // the runtime will expose it and reconnect without another QR.
                live = nil
            }
            return Paired(credential: credential, live: live)
        } catch {
            socket.close()
            throw error
        }
    }

    func reconnect(credential: MobileSharingCredential,
                   closed: @escaping @Sendable () -> Void) async throws -> MobileSharingLiveConnection {
        guard let brokerURL = credential.brokerURL,
              let deviceID = credential.deviceID,
              let capability = credential.reconnectCapability else {
            throw MobileSharingStorageError.corrupt
        }
        let capabilityString = MobileSharingBase64URL.encode(capability)
        do {
            let broker = try MobileSharingBrokerClient(baseURL: brokerURL)
            let hostID = MobileSharingBase64URL.encode(Data(SHA256.hash(data: credential.hostKey)))
            let ice = try await broker.ice(hostID: hostID, kind: "device", peerID: deviceID,
                                           capability: capabilityString)
            let socket = try await broker.dial(hostID: hostID, kind: "device", peerID: deviceID,
                                               capability: capabilityString)
            do {
                return try await establish(credential: credential, socket: socket,
                                           ice: ice.ice_servers, closed: closed)
            } catch {
                socket.close()
                throw error
            }
        } catch MobileSharingBrokerError.unauthorized {
            // For a previously paired device this frozen broker result means
            // revoked/changed credentials or target reset, never mere offline.
            throw MobileSharingProtocolError.revoked
        }
    }

    private func establish(credential: MobileSharingCredential, socket: MobileSharingBrokerSocket, ice: [PeerICEServer],
                           closed: @escaping @Sendable () -> Void) async throws -> MobileSharingLiveConnection {
        let hello = try MobileSharingTransportAttempt.hello(credential: credential)
        try await socket.send(hello)
        let challenge: MobileSharingTransportChallenge = try await waitForSignal(
            socket, expectedType: "transport_challenge",
            fields: ["v", "type", "challenge_id", "host_key", "host_nonce", "device_key", "device_id", "expires_at", "sig"],
            timeout: 30)

        let webRTC = try PeerWebRTCSession(iceServers: ice)
        webRTC.onClose = { socket.close(); closed() }
        do {
            let offer = try await webRTC.createOffer()
            let attempt = try MobileSharingTransportAttempt(challenge: challenge, credential: credential,
                                                             offerSDP: offer.sdp, now: clock())
            try await socket.send(attempt.request)
            let answer: MobileSharingTransportAnswer = try await waitForSignal(
                socket, expectedType: "transport_answer",
                fields: ["v", "type", "challenge_id", "host_key", "host_nonce", "device_key", "device_nonce", "request_hash", "device_id", "answer_sdp", "sig"],
                timeout: 30)
            let verifiedSDP = try attempt.verify(answer)
            let authorization = PeerAuthorizationState(PeerAuthorization(
                peerID: MobileSharingBase64URL.encode(credential.hostKey),
                sessionID: UUID().uuidString, expiresAt: .distantFuture,
                scopePrefix: credential.basePath ?? "/"))
            try await webRTC.acceptVerifiedAnswer(verifiedSDP, authorization: authorization)
            let channel = try await withTimeout(20) { try await webRTC.openChannel() }
            let multiplexer = PeerHTTPMultiplexer(channel: channel)
            socket.close()
            return MobileSharingLiveConnection(forwarder: multiplexer, authorization: authorization,
                                                stats: { await webRTC.stats() }, close: {
                multiplexer.close()
                authorization.revoke()
                webRTC.close()
                socket.close()
            })
        } catch {
            webRTC.close()
            throw error
        }
    }

    private func waitForPairAnswer(_ socket: MobileSharingBrokerSocket, invitationID: Data,
                                   deadline: Date) async throws -> MobileSharingPairAnswer {
        var count = 0
        while clock() < deadline {
            let remaining = max(0.1, deadline.timeIntervalSince(clock()))
            let frame = try await withTimeout(remaining) { try await socket.receive() }
            guard frame.type == "signal" else { continue }
            count += 1
            guard count <= 32, let body = frame.body else { throw MobileSharingBrokerError.malformed }
            let encoded = body.encoded()
            guard let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
                  let type = object["type"] as? String else { throw MobileSharingBrokerError.malformed }
            if type == "pair_reject" {
                let reject = try MobileSharingMessageCodec.decode(
                    MobileSharingPairReject.self, data: encoded, expectedType: "pair_reject",
                    fields: ["v", "type", "invitation_id", "reason"])
                guard reject.invitation_id.data == invitationID else { throw MobileSharingProtocolError.invalid("pair rejection") }
                let safe = ["denied", "expired", "invalid"].contains(reject.reason) ? reject.reason : "invalid"
                throw MobileSharingProtocolError.rejected(safe)
            }
            if type == "pair_answer" {
                return try MobileSharingMessageCodec.decode(
                    MobileSharingPairAnswer.self, data: encoded, expectedType: "pair_answer",
                    fields: ["v", "type", "invitation_id", "host_key", "device_key", "device_nonce", "request_hash", "device_id", "reconnect_capability", "scope", "base_path", "host_label", "mac", "sig"])
            }
        }
        throw MobileSharingProtocolError.expired
    }

    private func waitForSignal<T: Decodable>(_ socket: MobileSharingBrokerSocket,
                                              expectedType: String, fields: Set<String>,
                                              timeout: TimeInterval) async throws -> T {
        let deadline = clock().addingTimeInterval(timeout)
        var count = 0
        while clock() < deadline {
            let frame = try await withTimeout(max(0.1, deadline.timeIntervalSince(clock()))) { try await socket.receive() }
            guard frame.type == "signal", let body = frame.body else { continue }
            count += 1
            guard count <= 32 else { throw MobileSharingBrokerError.malformed }
            let encoded = body.encoded()
            guard let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
                  object["type"] as? String == expectedType else { continue }
            return try MobileSharingMessageCodec.decode(T.self, data: encoded, expectedType: expectedType, fields: fields)
        }
        throw MobileSharingBrokerError.peerOffline
    }

    private func withTimeout<T: Sendable>(_ seconds: TimeInterval,
                                operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0.1, seconds) * 1_000_000_000))
                throw MobileSharingBrokerError.peerOffline
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw MobileSharingBrokerError.peerOffline }
            return value
        }
    }

    static func safeDeviceName(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.utf8.count <= MobileSharingWire.maxLabelBytes,
           (try? MobileSharingPairingLink.validateLabel(normalized)) != nil { return normalized }
        return "iPhone"
    }
}
#endif
