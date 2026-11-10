#if canImport(WebRTC)
import Foundation
import WebRTC

enum PeerWebRTCError: Error, Equatable {
    case unauthorized
    case factoryFailed
    case channelFailed
    case sdp(String)
    case closed
    case gatheringTimedOut
}

/// libwebrtc's Objective-C factory is not annotated Sendable. This wrapper is
/// the sole owner and serializes every factory call; peer connections returned
/// from it retain their own SDK lifetime and are never read through the factory.
private final class PeerWebRTCFactoryStore: @unchecked Sendable {
    private let lock = NSLock()
    private let factory: RTCPeerConnectionFactory

    init() {
        RTCInitializeSSL()
        factory = RTCPeerConnectionFactory()
    }

    func makePeerConnection(configuration: RTCConfiguration,
                            constraints: RTCMediaConstraints,
                            delegate: RTCPeerConnectionDelegate) -> RTCPeerConnection? {
        lock.withLock {
            factory.peerConnection(with: configuration, constraints: constraints, delegate: delegate)
        }
    }
}

/// Native libwebrtc peer session carrying exactly one reliable, ordered
/// `term-llm-http-v1` DataChannel.  Data-only: no audio/video tracks.
///
/// Lifecycle: created UNAUTHORIZED, it may only produce a local offer.  The
/// remote answer is applied solely through ``acceptVerifiedAnswer(_:authorization:)``
/// after pairing/reconnect verification (MAC/signature/pinned host key) has
/// produced a ``PeerAuthorizationState``; the channel is only handed out while
/// that authorization is valid, and revoke closes the connection.
// Sendability: lock protects Swift lifecycle state, callbacks and configuration.
// SDK objects are snapshotted under lock; libwebrtc proxies marshal their own
// calls to SDK threads. This relies on that SDK contract, not on Sendable metadata;
// observers/signaling must support SDK-thread callbacks, invoked outside lock.
final class PeerWebRTCSession: NSObject, @unchecked Sendable {
    private static let factoryStore = PeerWebRTCFactoryStore()

    private var authorization: PeerAuthorizationState?
    private let lock = NSLock()
    private var peerConnection: RTCPeerConnection?
    private var channel: PeerRTCDataChannel?
    private var channelWaiters: [UUID: CheckedContinuation<PeerFrameChannel, Error>] = [:]
    private var gatheringWaiters: [CheckedContinuation<Void, Never>] = []
    private var gatheringComplete = false
    private var revokeToken: UUID?
    private var disconnectWorkItem: DispatchWorkItem?
    private var currentPhase: PeerConnectionPhase = .new
    var phase: PeerConnectionPhase { lock.withLock { currentPhase } }

    private weak var currentSignaling: PeerSignaling?
    var signaling: PeerSignaling? {
        get { lock.withLock { currentSignaling } }
        set { lock.withLock { currentSignaling = newValue } }
    }
    private var phaseCallback: (@Sendable (PeerConnectionPhase) -> Void)?
    var onPhaseChange: (@Sendable (PeerConnectionPhase) -> Void)? {
        get { lock.withLock { phaseCallback } }
        set { lock.withLock { phaseCallback = newValue } }
    }
    /// Fired on loss/failure/close; callers tear down bridges/transports.
    private var closeCallback: (@Sendable () -> Void)?
    var onClose: (@Sendable () -> Void)? {
        get { lock.withLock { closeCallback } }
        set { lock.withLock { closeCallback = newValue } }
    }

    init(iceServers: [PeerICEServer], relayOnly: Bool = false) throws {
        super.init()
        let config = RTCConfiguration()
        config.iceServers = iceServers.map {
            RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential)
        }
        config.sdpSemantics = .unifiedPlan
        // Non-trickle signalling (matches the Pion endpoint): the signed SDP
        // must already contain every candidate, so gathering must complete.
        config.continualGatheringPolicy = .gatherOnce
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        if relayOnly { config.iceTransportPolicy = .relay }
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil,
                                              optionalConstraints: ["DtlsSrtpKeyAgreement": "true"])
        guard let pc = Self.factoryStore.makePeerConnection(configuration: config,
                                                             constraints: constraints,
                                                             delegate: self) else {
            throw PeerWebRTCError.factoryFailed
        }
        lock.withLock { peerConnection = pc }
    }

    private func authorized() -> Bool { lock.withLock { authorization }?.check() ?? false }

    deinit { peerConnection?.close() }

    // MARK: Offerer role (native creates the channel)

    func createOffer() async throws -> PeerSessionDescription {
        guard let pc = lock.withLock({ peerConnection }) else { throw PeerWebRTCError.closed }
        let config = RTCDataChannelConfiguration()
        config.isOrdered = true  // reliable: no maxRetransmits / maxPacketLifeTime
        guard let dc = pc.dataChannel(forLabel: PeerWire.channelLabel, configuration: config) else {
            throw PeerWebRTCError.channelFailed
        }
        adopt(dc)
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let offerSDP: String = try await withCheckedThrowingContinuation { cont in
            pc.offer(for: constraints) { sdp, error in
                if let sdp {
                    let ownedSDP = String(decoding: sdp.sdp.utf8, as: UTF8.self)
                    cont.resume(returning: ownedSDP)
                } else {
                    cont.resume(throwing: PeerWebRTCError.sdp(error?.localizedDescription ?? "offer"))
                }
            }
        }
        try await setLocal(RTCSessionDescription(type: .offer, sdp: offerSDP), on: pc)
        return PeerSessionDescription(type: .offer, sdp: try await gatheredLocalSDP(pc))
    }

    /// Bound on ICE gathering before the complete (non-trickle) SDP is signed.
    private var configuredGatheringTimeout: TimeInterval = 10
    var gatheringTimeout: TimeInterval {
        get { lock.withLock { configuredGatheringTimeout } }
        set { lock.withLock { configuredGatheringTimeout = newValue } }
    }

    /// Waits for ICE gathering to complete (or the timeout, after which the
    /// candidates gathered so far are used if any exist) and returns the
    /// exact local SDP that must be signed and sent.
    private func gatheredLocalSDP(_ pc: RTCPeerConnection) async throws -> String {
        let timeout = gatheringTimeout
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in await self?.waitForGathering() }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
            await group.next()
            group.cancelAll()
            self.releaseGatheringWaiters()
        }
        guard let sdp = pc.localDescription?.sdp, sdp.contains("a=candidate:") else {
            throw PeerWebRTCError.gatheringTimedOut
        }
        return sdp
    }

    private func waitForGathering() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let done: Bool = lock.withLock {
                if gatheringComplete || peerConnection == nil { return true }
                gatheringWaiters.append(c)
                return false
            }
            if done { c.resume() }
        }
    }

    private func releaseGatheringWaiters() {
        let w: [CheckedContinuation<Void, Never>] = lock.withLock { let w = gatheringWaiters; gatheringWaiters.removeAll(); return w }
        w.forEach { $0.resume() }
    }

    /// Apply an answer whose exact SDP bytes were verified by
    /// ``PeerPairingAttempt/verify(_:)`` or ``PeerReconnectAttempt/verify(_:)``.
    func acceptVerifiedAnswer(_ sdp: String, authorization: PeerAuthorizationState) async throws {
        guard authorization.check() else { throw PeerWebRTCError.unauthorized }
        guard let pc = lock.withLock({ peerConnection }) else { throw PeerWebRTCError.closed }
        let bound: Bool = lock.withLock {
            if self.authorization != nil { return false }
            self.authorization = authorization
            return true
        }
        guard bound else { throw PeerWebRTCError.sdp("answer already applied") }
        let token = authorization.onRevoke { [weak self] in self?.close() }
        let keep = lock.withLock {
            guard peerConnection != nil else { return false }
            revokeToken = token
            return true
        }
        if !keep { authorization.removeHandler(token) }
        try await setRemote(RTCSessionDescription(type: .answer, sdp: sdp), on: pc)
    }

    // MARK: Answerer role (node creates the channel)

    func acceptOffer(_ offer: PeerSessionDescription) async throws -> PeerSessionDescription {
        guard offer.type == .offer else { throw PeerWebRTCError.sdp("expected offer") }
        guard authorized(), let pc = lock.withLock({ peerConnection }) else { throw PeerWebRTCError.unauthorized }
        try await setRemote(RTCSessionDescription(type: .offer, sdp: offer.sdp), on: pc)
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let answerSDP: String = try await withCheckedThrowingContinuation { cont in
            pc.answer(for: constraints) { sdp, error in
                if let sdp {
                    let ownedSDP = String(decoding: sdp.sdp.utf8, as: UTF8.self)
                    cont.resume(returning: ownedSDP)
                } else {
                    cont.resume(throwing: PeerWebRTCError.sdp(error?.localizedDescription ?? "answer"))
                }
            }
        }
        try await setLocal(RTCSessionDescription(type: .answer, sdp: answerSDP), on: pc)
        return PeerSessionDescription(type: .answer, sdp: try await gatheredLocalSDP(pc))
    }

    func addRemoteCandidate(_ candidate: PeerICECandidate) async throws {
        guard authorized(), let pc = lock.withLock({ peerConnection }) else { throw PeerWebRTCError.unauthorized }
        let c = RTCIceCandidate(sdp: candidate.candidate, sdpMLineIndex: candidate.sdpMLineIndex, sdpMid: candidate.sdpMid)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pc.add(c) { error in
                if let error { cont.resume(throwing: PeerWebRTCError.sdp(error.localizedDescription)) } else { cont.resume() }
            }
        }
    }

    /// Resolves once the `term-llm-http-v1` channel is open.
    func openChannel() async throws -> PeerFrameChannel {
        guard authorized() else { throw PeerWebRTCError.unauthorized }
        let waiterID = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<PeerFrameChannel, Error>) in
                let ready: PeerFrameChannel?? = lock.withLock {
                    if peerConnection == nil { return .some(nil) }
                    if let channel, channel.isOpen { return .some(channel) }
                    if Task.isCancelled { return .some(nil) }
                    channelWaiters[waiterID] = cont
                    return nil
                }
                switch ready {
                case .some(.some(let channel)): cont.resume(returning: channel)
                case .some(.none): cont.resume(throwing: Task.isCancelled ? CancellationError() : PeerWebRTCError.closed)
                case .none: break
                }
            }
        }, onCancel: { [weak self] in
            self?.cancelChannelWaiter(waiterID)
        })
    }

    private func cancelChannelWaiter(_ id: UUID) {
        let continuation = lock.withLock { channelWaiters.removeValue(forKey: id) }
        continuation?.resume(throwing: CancellationError())
    }

    func stats() async -> PeerSessionStats {
        guard let pc = lock.withLock({ peerConnection }) else { return PeerSessionStats() }
        return await withCheckedContinuation { cont in
            pc.statistics { report in
                // RTCStatisticsReport and its Objective-C values remain on the
                // SDK callback. Only our immutable Sendable snapshot crosses.
                let entries = report.statistics.values.map { statistic in
                    PeerStatsEntry(
                        id: statistic.id,
                        type: statistic.type,
                        values: statistic.values.reduce(into: [String: Any]()) { values, item in
                            values[item.key] = item.value
                        }
                    )
                }
                cont.resume(returning: PeerSessionStats.parse(entries))
            }
        }
    }

    func restartIce() { lock.withLock { peerConnection }?.restartIce() }

    func close() {
        let (pc, ch, waiters, disconnect): (RTCPeerConnection?, PeerRTCDataChannel?, [CheckedContinuation<PeerFrameChannel, Error>], DispatchWorkItem?) = lock.withLock {
            let r = (peerConnection, channel, Array(channelWaiters.values), disconnectWorkItem)
            peerConnection = nil
            channel = nil
            channelWaiters.removeAll()
            disconnectWorkItem = nil
            return r
        }
        disconnect?.cancel()
        waiters.forEach { $0.resume(throwing: PeerWebRTCError.closed) }
        releaseGatheringWaiters()
        guard pc != nil else { return }
        ch?.close()
        pc?.close()
        let (auth, token) = lock.withLock { (authorization, revokeToken) }
        if let auth, let token { auth.removeHandler(token) }
        setPhase(.closed)
        onClose?()
    }

    // MARK: Internals

    private func adopt(_ dc: RTCDataChannel) {
        // Only the agreed label, ordered and reliable, is accepted.
        guard dc.label == PeerWire.channelLabel, dc.isOrdered,
              // libwebrtc reports "unset" (fully reliable) as UInt16.max.
              dc.maxRetransmits == UInt16.max,
              dc.maxPacketLifeTime == UInt16.max else {
            dc.close()
            return
        }
        let wrapper = PeerRTCDataChannel(dc, onOpen: { [weak self] in self?.channelOpened() },
                                         onClosed: { [weak self] in self?.close() })
        let replaced: Bool = lock.withLock {
            if channel != nil || peerConnection == nil { return false }
            channel = wrapper
            return true
        }
        if !replaced { dc.close(); return }
        if wrapper.isOpen { channelOpened() }
    }

    private func channelOpened() {
        let (ch, waiters): (PeerRTCDataChannel?, [CheckedContinuation<PeerFrameChannel, Error>]) = lock.withLock {
            let waiters = Array(channelWaiters.values)
            channelWaiters.removeAll()
            return (channel, waiters)
        }
        guard let ch else { return }
        waiters.forEach { $0.resume(returning: ch) }
    }

    private func setLocal(_ sdp: RTCSessionDescription, on pc: RTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(sdp) { error in
                if let error { cont.resume(throwing: PeerWebRTCError.sdp(error.localizedDescription)) } else { cont.resume() }
            }
        }
    }

    private func setRemote(_ sdp: RTCSessionDescription, on pc: RTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(sdp) { error in
                if let error { cont.resume(throwing: PeerWebRTCError.sdp(error.localizedDescription)) } else { cont.resume() }
            }
        }
    }

    private func scheduleDisconnectClose() {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.lock.withLock({ self.currentPhase == .disconnected }) else { return }
            self.close()
        }
        let previous = lock.withLock { let old = disconnectWorkItem; disconnectWorkItem = work; return old }
        previous?.cancel()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: work)
    }

    private func cancelDisconnectClose() {
        let work = lock.withLock { let old = disconnectWorkItem; disconnectWorkItem = nil; return old }
        work?.cancel()
    }

    private func setPhase(_ p: PeerConnectionPhase) {
        let callback: (@Sendable (PeerConnectionPhase) -> Void)? = lock.withLock {
            guard currentPhase != p else { return nil }
            currentPhase = p
            return phaseCallback
        }
        callback?(p)
    }
}

extension PeerWebRTCSession: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        guard newState == .complete else { return }
        lock.withLock { gatheringComplete = true }
        releaseGatheringWaiters()
    }

    /// Non-trickle pairing ignores this unless an (authenticated) signaller
    /// opts in; candidates are already in the signed SDP.
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        signaling?.sendLocalCandidate(PeerICECandidate(candidate: candidate.sdp, sdpMid: candidate.sdpMid,
                                                       sdpMLineIndex: candidate.sdpMLineIndex))
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        adopt(dataChannel)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        switch newState {
        case .new: setPhase(.new)
        case .connecting: setPhase(.connecting)
        case .connected:
            cancelDisconnectClose()
            setPhase(.connected)
        case .disconnected:
            setPhase(.disconnected)
            scheduleDisconnectClose()
        case .failed:
            setPhase(.failed)
            close()
        case .closed: close()
        @unknown default: break
        }
    }
}

/// Adapts `RTCDataChannel` to ``PeerFrameChannel``.  Text frames only.
// Sendability: lock protects handler slots and closedNotified; immutable open/
// closed callbacks must support SDK-thread invocation. libwebrtc marshals the
// channel operations internally; handler snapshots run outside our lock.
final class PeerRTCDataChannel: NSObject, PeerFrameChannel, RTCDataChannelDelegate, @unchecked Sendable {
    private let channel: RTCDataChannel
    private let lock = NSLock()
    private var onMessage: ((Data) -> Void)?
    private var onClose: (() -> Void)?
    private var onBuffered: (() -> Void)?
    private let onOpen: () -> Void
    private let onClosed: () -> Void
    private var closedNotified = false

    init(_ channel: RTCDataChannel, onOpen: @escaping () -> Void, onClosed: @escaping () -> Void) {
        self.channel = channel
        self.onOpen = onOpen
        self.onClosed = onClosed
        super.init()
        channel.delegate = self
        if channel.readyState == .open { onOpen() }
    }

    var isOpen: Bool { channel.readyState == .open }
    var bufferedAmount: UInt64 { channel.bufferedAmount }

    func send(_ message: Data) -> Bool {
        channel.sendData(RTCDataBuffer(data: message, isBinary: false))
    }

    func close() { channel.close() }

    func setHandlers(onMessage: @escaping (Data) -> Void, onClose: @escaping () -> Void,
                     onBufferedAmountChange: @escaping () -> Void) {
        lock.withLock {
            self.onMessage = onMessage
            self.onClose = onClose
            self.onBuffered = onBufferedAmountChange
        }
    }

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        switch dataChannel.readyState {
        case .open: onOpen()
        case .closing, .closed:
            let (first, handler): (Bool, (() -> Void)?) = lock.withLock {
                if closedNotified { return (false, nil) }
                closedNotified = true
                return (true, onClose)
            }
            if first {
                handler?()
                onClosed()
            }
        default: break
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        // Binary frames are not part of term-llm-http-v1; the decoder rejects
        // non-JSON input and closes the multiplexer.
        let handler = lock.withLock { onMessage }
        handler?(buffer.data)
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didChangeBufferedAmount amount: UInt64) {
        let handler = lock.withLock { onBuffered }
        handler?()
    }
}
#endif
