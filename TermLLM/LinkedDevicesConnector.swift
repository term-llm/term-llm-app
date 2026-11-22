import CryptoKit
import Foundation
#if os(iOS)
import UIKit
#endif

#if canImport(WebRTC)
final class LinkedDevicesConnector: LinkedDevicesSessionConnecting, Sendable {
    struct Paired: Sendable {
        let credential: LinkedDevicesCredential
        let live: LinkedDevicesLiveConnection?
    }

    private let identities: LinkedDevicesIdentityStore
    private let clock: @Sendable () -> Date
    private let diagnostics: LinkedDevicesDiagnostics?

    init(identities: LinkedDevicesIdentityStore, clock: @escaping @Sendable () -> Date = { Date() },
         diagnostics: LinkedDevicesDiagnostics? = nil) {
        self.identities = identities
        self.clock = clock
        self.diagnostics = diagnostics
    }

    func pair(link: LinkedDevicesPairingLink, deviceName: String,
              sasReady: @escaping @Sendable (String) -> Void,
              closed: @escaping @Sendable () -> Void) async throws -> Paired {
        var stage = LinkedDevicesPairingFailure.Stage.preparingIdentity
        do {
            guard !link.isExpired(at: clock()) else { throw LinkedDevicesProtocolError.expired }
            guard let capability = link.invitationCapability else {
                throw LinkedDevicesProtocolError.invalidLink
            }
            let prepared = try await identities.prepareAsync(hostKey: link.hostKey)
            let attempt = try LinkedDevicesPairingAttempt(link: link, credential: prepared,
                                                           deviceName: Self.safeDeviceName(deviceName), now: clock())
            stage = .contactingBroker
            let broker = try LinkedDevicesBrokerClient(baseURL: link.broker)
            let socket = try await broker.dial(hostID: link.hostID, kind: "invitation",
                                               peerID: link.invitationIDString, capability: capability)
            do {
                try await socket.send(attempt.request)
                sasReady(attempt.sas)
                stage = .waitingForApproval
                let answer = try await waitForPairAnswer(socket, invitationID: link.invitationID,
                                                         deadline: link.expiresAt)
                stage = .verifyingHost
                var credential = try attempt.verify(answer)
                // PairingAttempt preserves the identity already durably prepared.
                credential.deviceSeed = prepared.deviceSeed
                stage = .savingIdentity
                try await identities.saveAsync(credential)
                // Pairing is identity-only. The consumed invitation socket never
                // carries SDP; close it, then use the durable device slot for the
                // first signed transport handshake exactly like every reconnect.
                socket.close()
                let live: LinkedDevicesLiveConnection?
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
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LinkedDevicesPairingFailure(stage: stage, error: error)
        }
    }

    func reconnect(credential: LinkedDevicesCredential,
                   closed: @escaping @Sendable () -> Void) async throws -> LinkedDevicesLiveConnection {
        let diagnostic = diagnostics?.connection()
        diagnostic?.emit(.recoveryAttempt)
        guard let brokerURL = credential.brokerURL,
              let deviceID = credential.deviceID,
              let capability = credential.reconnectCapability else {
            diagnostic?.emit(.recoveryFailed(.other))
            throw LinkedDevicesStorageError.corrupt
        }
        let capabilityString = LinkedDevicesBase64URL.encode(capability)
        do {
            let broker = try LinkedDevicesBrokerClient(baseURL: brokerURL)
            let hostID = LinkedDevicesBase64URL.encode(Data(SHA256.hash(data: credential.hostKey)))
            let ice = try await broker.ice(hostID: hostID, kind: "device", peerID: deviceID,
                                           capability: capabilityString)
            let socket = try await broker.dial(hostID: hostID, kind: "device", peerID: deviceID,
                                               capability: capabilityString)
            diagnostic?.emit(.brokerConnected)
            do {
                return try await establish(credential: credential, socket: socket,
                                           ice: ice.iceServers, diagnostic: diagnostic, closed: closed)
            } catch {
                socket.close()
                let reason = Self.diagnosticReason(error)
                diagnostic?.emit(.brokerDisconnected(reason))
                throw error
            }
        } catch LinkedDevicesBrokerError.unauthorized {
            diagnostic?.emit(.recoveryFailed(.revoked))
            // For a previously paired device this frozen broker result means
            // revoked/changed credentials or target reset, never mere offline.
            throw LinkedDevicesProtocolError.revoked
        } catch {
            diagnostic?.emit(.recoveryFailed(Self.diagnosticReason(error)))
            throw error
        }
    }

    private func establish(credential: LinkedDevicesCredential, socket: LinkedDevicesBrokerSocket,
                           ice: [PeerICEServer], diagnostic: LinkedDevicesDiagnosticConnection?,
                           closed: @escaping @Sendable () -> Void) async throws -> LinkedDevicesLiveConnection {
        let hello = try LinkedDevicesTransportAttempt.hello(credential: credential)
        try await socket.send(hello)
        let challenge: LinkedDevicesTransportChallenge = try await waitForSignal(
            socket, expectedType: "transport_challenge",
            fields: ["v", "type", "challenge_id", "host_key", "host_nonce", "device_key", "device_id", "expires_at", "sig"],
            timeout: 30)

        let webRTC = try PeerWebRTCSession(iceServers: ice)
        webRTC.onPhaseChange = { phase in diagnostic?.emit(.peerPhase(.init(phase))) }
        webRTC.onClose = { socket.close(); closed() }
        do {
            let offer = try await webRTC.createOffer()
            let attempt = try LinkedDevicesTransportAttempt(challenge: challenge, credential: credential,
                                                             offerSDP: offer.sdp, now: clock())
            try await socket.send(attempt.request)
            let answer: LinkedDevicesTransportAnswer = try await waitForSignal(
                socket, expectedType: "transport_answer",
                fields: ["v", "type", "challenge_id", "host_key", "host_nonce", "device_key", "device_nonce", "request_hash", "device_id", "answer_sdp", "sig"],
                timeout: 30)
            let verifiedSDP = try attempt.verify(answer)
            diagnostic?.emit(.identityVerified)
            let authorization = PeerAuthorizationState(PeerAuthorization(
                peerID: LinkedDevicesBase64URL.encode(credential.hostKey),
                sessionID: UUID().uuidString, expiresAt: .distantFuture,
                scopePrefix: credential.basePath ?? "/"))
            try await webRTC.acceptVerifiedAnswer(verifiedSDP, authorization: authorization)
            let channel = try await withTimeout(20) { try await webRTC.openChannel() }
            diagnostic?.emit(.dataChannelOpen)
            let multiplexer = PeerHTTPMultiplexer(channel: channel, diagnostics: diagnostic, authorization: authorization)
            socket.close()
            diagnostic?.emit(.brokerDisconnected(.completed))
            return LinkedDevicesLiveConnection(forwarder: multiplexer, authorization: authorization,
                                                diagnostics: diagnostic,
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

    private func waitForPairAnswer(_ socket: LinkedDevicesBrokerSocket, invitationID: Data,
                                   deadline: Date) async throws -> LinkedDevicesPairAnswer {
        var count = 0
        while clock() < deadline {
            let remaining = max(0.1, deadline.timeIntervalSince(clock()))
            let frame = try await withTimeout(remaining) { try await socket.receive() }
            guard frame.type == "signal" else { continue }
            count += 1
            guard count <= 32, let body = frame.body else { throw LinkedDevicesBrokerError.malformed }
            let encoded = body.encoded()
            guard let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
                  let type = object["type"] as? String else { throw LinkedDevicesBrokerError.malformed }
            if type == "pair_reject" {
                let reject = try LinkedDevicesMessageCodec.decode(
                    LinkedDevicesPairReject.self, data: encoded, expectedType: "pair_reject",
                    fields: ["v", "type", "invitation_id", "reason"])
                guard reject.invitationID.data == invitationID else { throw LinkedDevicesProtocolError.invalid("pair rejection") }
                let safe = ["denied", "expired", "invalid"].contains(reject.reason) ? reject.reason : "invalid"
                throw LinkedDevicesProtocolError.rejected(safe)
            }
            if type == "pair_answer" {
                return try LinkedDevicesMessageCodec.decode(
                    LinkedDevicesPairAnswer.self, data: encoded, expectedType: "pair_answer",
                    fields: ["v", "type", "invitation_id", "host_key", "device_key", "device_nonce", "request_hash", "device_id", "reconnect_capability", "scope", "base_path", "host_label", "mac", "sig"])
            }
        }
        throw LinkedDevicesProtocolError.expired
    }

    private func waitForSignal<T: Decodable>(_ socket: LinkedDevicesBrokerSocket,
                                              expectedType: String, fields: Set<String>,
                                              timeout: TimeInterval) async throws -> T {
        let deadline = clock().addingTimeInterval(timeout)
        var count = 0
        while clock() < deadline {
            let frame = try await withTimeout(max(0.1, deadline.timeIntervalSince(clock()))) { try await socket.receive() }
            guard frame.type == "signal", let body = frame.body else { continue }
            count += 1
            guard count <= 32 else { throw LinkedDevicesBrokerError.malformed }
            let encoded = body.encoded()
            guard let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
                  object["type"] as? String == expectedType else { continue }
            return try LinkedDevicesMessageCodec.decode(T.self, data: encoded, expectedType: expectedType, fields: fields)
        }
        throw LinkedDevicesBrokerError.peerOffline
    }

    private func withTimeout<T: Sendable>(_ seconds: TimeInterval,
                                operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0.1, seconds) * 1_000_000_000))
                throw LinkedDevicesBrokerError.peerOffline
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw LinkedDevicesBrokerError.peerOffline }
            return value
        }
    }

    private static func diagnosticReason(_ error: Error) -> LinkedDevicesDiagnosticEvent.Reason {
        switch error {
        case is CancellationError: return .cancelled
        case LinkedDevicesProtocolError.revoked: return .revoked
        case LinkedDevicesProtocolError.hostIdentityChanged, LinkedDevicesProtocolError.badMAC,
             LinkedDevicesProtocolError.badSignature:
            return .identityChanged
        case LinkedDevicesProtocolError.expired, LinkedDevicesBrokerError.peerOffline,
             LinkedDevicesBrokerError.notFound:
            return .networkUnavailable
        case LinkedDevicesBrokerError.unauthorized: return .unauthorized
        default: return .other
        }
    }

    static func safeDeviceName(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.utf8.count <= LinkedDevicesWire.maxLabelBytes,
           (try? LinkedDevicesPairingLink.validateLabel(normalized)) != nil { return normalized }
        return "iPhone"
    }
}
#endif
