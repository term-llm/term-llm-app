import Foundation

// MARK: - Frame channel abstraction
//
// Implemented by the libwebrtc DataChannel adapter (PeerWebRTCSession.swift)
// and by in-memory channels in tests.  Callbacks may arrive on any thread.

protocol PeerFrameChannel: AnyObject, Sendable {
    var isOpen: Bool { get }
    var bufferedAmount: UInt64 { get }
    /// Send one complete message.  Returns false if the channel refused it.
    func send(_ message: Data) -> Bool
    func close()
    /// Installed once by the multiplexer.
    func setHandlers(onMessage: @escaping (Data) -> Void,
                     onClose: @escaping () -> Void,
                     onBufferedAmountChange: @escaping () -> Void)
}

// MARK: - Body stream

/// What a ``PeerBodyStream`` observer sees.  `.end` is reported when the
/// stream finishes without error (including a locally cancelled consumer),
/// so observers must decide completeness from content, not from `.end`.
enum PeerBodyEvent: Sendable {
    case chunk(Data)
    case end
    case failed
}

/// Async sequence of body chunks that reports consumption back to the
/// multiplexer so per-stream buffering stays bounded.
struct PeerBodyStream: AsyncSequence, Sendable {
    typealias Element = Data

    fileprivate let stream: AsyncThrowingStream<Data, Error>
    fileprivate let consumed: @Sendable (Int) -> Void
    fileprivate var observer: (@Sendable (PeerBodyEvent) -> Void)? = nil

    struct AsyncIterator: AsyncIteratorProtocol {
        fileprivate var base: AsyncThrowingStream<Data, Error>.AsyncIterator
        fileprivate let consumed: @Sendable (Int) -> Void
        fileprivate let observer: (@Sendable (PeerBodyEvent) -> Void)?

        mutating func next() async throws -> Data? {
            let chunk: Data?
            do {
                chunk = try await base.next()
            } catch {
                observer?(.failed)
                throw error
            }
            if let chunk {
                consumed(chunk.count)
                observer?(.chunk(chunk))
            } else {
                observer?(.end)
            }
            return chunk
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: stream.makeAsyncIterator(), consumed: consumed, observer: observer)
    }

    /// Same stream, additionally reporting each chunk as the CONSUMER reads
    /// it (no extra buffering, so per-stream bounds are unchanged).  Used only
    /// by the DEBUG capture recorder; observers must not retain raw bytes.
    func observing(_ observe: @escaping @Sendable (PeerBodyEvent) -> Void) -> PeerBodyStream {
        var copy = self
        let previous = observer
        copy.observer = { event in
            previous?(event)
            observe(event)
        }
        return copy
    }

    /// Construct a stream from a prepared list (tests / synthetic responses).
    static func fixed(_ chunks: [Data], error: Error? = nil) -> PeerBodyStream {
        let stream = AsyncThrowingStream<Data, Error> { c in
            for chunk in chunks { c.yield(chunk) }
            c.finish(throwing: error)
        }
        return PeerBodyStream(stream: stream, consumed: { _ in })
    }
}

// MARK: - Multiplexer (client role)

/// Multiplexes HTTP requests over one `term-llm-http-v1` channel.
///
/// * Bounded concurrent streams and bounded unconsumed body per stream; an
///   overflowing stream is cancelled locally and remotely.
/// * Outbound frames wait while `bufferedAmount` exceeds the high-water mark.
/// * Malformed inbound frames tear down the whole channel (fail closed).
/// * `close()` fails every open stream — used by revoke/teardown.
final class PeerHTTPMultiplexer: PeerHTTPForwarding, @unchecked Sendable {
    let limits: PeerWireLimits
    private let channel: PeerFrameChannel
    private let lock = NSLock()
    private var streams: [String: StreamState] = [:]
    private var nextID: UInt64 = 1
    private var closed = false
    private var closeError: PeerWireError = .channelClosed
    private var bufferWaiters: [CheckedContinuation<Void, Error>] = []
    /// Serialises "is this stream still live? -> send request" against
    /// "remove stream -> send cancel", so a cancel can never precede (or be
    /// followed by) its own request on the wire.  Recursive because an
    /// in-process channel may deliver frames re-entrantly from `send`.
    private let sendLock = NSRecursiveLock()

    /// Fired once when the multiplexer closes (channel loss, protocol
    /// violation or explicit close).
    var onClose: (@Sendable (PeerWireError) -> Void)?

    private final class StreamState {
        var headContinuation: CheckedContinuation<PeerHTTPResponse, Error>?
        var bodyContinuation: AsyncThrowingStream<Data, Error>.Continuation?
        var started = false
        var buffered = 0
        var timeoutTask: Task<Void, Never>?
        /// Request send task; retained so cancellation can stop it.
        var sendTask: Task<Void, Never>?
        /// Set (under `lock`, inside `sendLock`) only when the request frame
        /// is actually handed to the channel.  Cancel frames are sent only
        /// for streams whose request was sent.
        var requestSent = false
    }

    init(channel: PeerFrameChannel, limits: PeerWireLimits = .default) {
        self.channel = channel
        self.limits = limits
        channel.setHandlers(
            onMessage: { [weak self] data in self?.receive(data) },
            onClose: { [weak self] in self?.close(.channelClosed, closeChannel: false) },
            onBufferedAmountChange: { [weak self] in self?.wakeBufferWaiters() }
        )
    }

    var openStreamCount: Int { lock.withLock { streams.count } }
    /// Diagnostics/tests: request senders parked on backpressure, and
    /// request-send tasks that have not yet exited.
    var parkedSenderCount: Int { lock.withLock { bufferWaiters.count } }
    var activeSenderCount: Int { lock.withLock { activeSenders } }
    private var activeSenders = 0
    var isClosed: Bool { lock.withLock { closed } }

    // MARK: Forward

    func forward(_ request: PeerHTTPRequest, headTimeout: TimeInterval? = nil) async throws -> PeerHTTPResponse {
        try request.validate(limits: limits)
        let id: String = try lock.withLock {
            if closed { throw closeError }
            guard streams.count < limits.maxConcurrentStreams else { throw PeerWireError.tooManyStreams }
            let id = "r\(String(nextID, radix: 16))"
            nextID += 1
            streams[id] = StreamState()
            return id
        }
        let frame = PeerFrame(type: .request, id: id, method: request.method, path: request.path,
                              header: request.header.isEmpty ? nil : request.header, body: request.body)
        let data: Data
        do {
            data = try PeerFrameCodec.encode(frame, limits: limits)
        } catch {
            _ = lock.withLock { streams.removeValue(forKey: id) }
            throw error
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<PeerHTTPResponse, Error>) in
                let state: StreamState? = lock.withLock {
                    guard let s = streams[id] else { return nil }
                    s.headContinuation = cont
                    return s
                }
                guard let state else { cont.resume(throwing: PeerWireError.cancelled); return }
                if let headTimeout {
                    state.timeoutTask = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: UInt64(max(0, headTimeout) * 1_000_000_000))
                        if Task.isCancelled { return }
                        self?.fail(id: id, error: .timedOut, sendCancel: true)
                    }
                }
                lock.withLock { activeSenders += 1 }
                let task = Task { [weak self] in
                    guard let self else { return }
                    defer { self.lock.withLock { self.activeSenders -= 1 } }
                    do {
                        try await self.sendRequest(data, id: id, owner: state)
                    } catch {
                        self.fail(id: id, error: (error as? PeerWireError) ?? .channelClosed, sendCancel: false)
                    }
                }
                let keep: Bool = lock.withLock {
                    guard streams[id] === state else { return false }
                    state.sendTask = task
                    return true
                }
                if !keep { task.cancel() }
            }
        } onCancel: { [weak self] in
            self?.fail(id: id, error: .cancelled, sendCancel: true)
        }
    }

    // MARK: Close

    func close(_ error: PeerWireError = .channelClosed, closeChannel: Bool = true) {
        let (victims, waiters): ([StreamState], [CheckedContinuation<Void, Error>]) = lock.withLock {
            if closed { return ([], []) }
            closed = true
            closeError = error
            let v = Array(streams.values)
            streams.removeAll()
            let w = bufferWaiters
            bufferWaiters.removeAll()
            return (v, w)
        }
        for s in victims { s.sendTask?.cancel(); Self.finish(s, error: error) }
        for w in waiters { w.resume(throwing: error) }
        if closeChannel { channel.close() }
        onClose?(error)
    }

    // MARK: Inbound

    private func receive(_ data: Data) {
        let frame: PeerFrame
        do {
            frame = try PeerFrameCodec.decode(data, limits: limits)
        } catch {
            close((error as? PeerWireError) ?? .malformedFrame("decode"))
            return
        }
        switch frame.type {
        case .request:
            // Native side is the client; the node never initiates requests.
            close(.protocolViolation("unexpected request frame"))
        case .cancel:
            fail(id: frame.id, error: .cancelled, sendCancel: false)
        case .responseStart:
            handleStart(frame)
        case .responseBody:
            handleBody(frame)
        case .responseEnd:
            handleEnd(frame)
        }
    }

    private func handleStart(_ frame: PeerFrame) {
        let id = frame.id
        let result: (CheckedContinuation<PeerHTTPResponse, Error>, PeerHTTPResponse)?? = lock.withLock {
            guard let s = streams[id] else { return .some(nil) }  // late frame after cancel
            if s.started { return nil }                           // duplicate start
            s.started = true
            s.timeoutTask?.cancel()
            var bodyCont: AsyncThrowingStream<Data, Error>.Continuation!
            let stream = AsyncThrowingStream<Data, Error>(bufferingPolicy: .unbounded) { bodyCont = $0 }
            s.bodyContinuation = bodyCont
            bodyCont.onTermination = { [weak self] termination in
                if case .cancelled = termination { self?.fail(id: id, error: .cancelled, sendCancel: true) }
            }
            let body = PeerBodyStream(stream: stream, consumed: { [weak self] n in self?.consumed(id: id, bytes: n) })
            let response = PeerHTTPResponse(
                status: frame.status ?? 0,
                header: frame.header ?? PeerHeader(),
                body: body,
                cancel: { [weak self] in self?.fail(id: id, error: .cancelled, sendCancel: true) })
            guard let head = s.headContinuation else { return nil }
            s.headContinuation = nil
            return .some((head, response))
        }
        switch result {
        case .none:
            fail(id: id, error: .protocolViolation("duplicate response_start"), sendCancel: true)
        case .some(.none):
            break
        case .some(.some(let (cont, response))):
            cont.resume(returning: response)
        }
    }

    private func handleBody(_ frame: PeerFrame) {
        let id = frame.id
        guard let chunk = frame.bodyData else { return }
        if chunk.count > limits.maxBodyChunkBytes * 2 {
            fail(id: id, error: .protocolViolation("oversized body chunk"), sendCancel: true)
            return
        }
        enum Outcome { case ignore, violation, overflow, deliver(AsyncThrowingStream<Data, Error>.Continuation) }
        let outcome: Outcome = lock.withLock {
            guard let s = streams[id] else { return .ignore }
            guard s.started, let c = s.bodyContinuation else { return .violation }
            if s.buffered + chunk.count > limits.maxBufferedResponseBytes { return .overflow }
            s.buffered += chunk.count
            return .deliver(c)
        }
        switch outcome {
        case .ignore: break
        case .violation: fail(id: id, error: .protocolViolation("body before start"), sendCancel: true)
        case .overflow: fail(id: id, error: .responseBufferOverflow, sendCancel: true)
        case .deliver(let c): if !chunk.isEmpty { c.yield(chunk) }
        }
    }

    private func handleEnd(_ frame: PeerFrame) {
        let state: StreamState? = lock.withLock { streams.removeValue(forKey: frame.id) }
        guard let state else { return }
        if let message = frame.error, !message.isEmpty {
            Self.finish(state, error: .remoteError(message))
        } else if !state.started {
            Self.finish(state, error: .protocolViolation("end before start"))
        } else {
            state.timeoutTask?.cancel()
            state.bodyContinuation?.finish()
        }
    }

    private func consumed(id: String, bytes: Int) {
        lock.withLock { if let s = streams[id] { s.buffered = max(0, s.buffered - bytes) } }
    }

    // MARK: Failure

    private func fail(id: String, error: PeerWireError, sendCancel: Bool) {
        // Taking sendLock first waits out an in-progress request send, so the
        // removal below and the sender's ownership check are totally ordered.
        sendLock.lock()
        defer { sendLock.unlock() }
        let state: StreamState? = lock.withLock { streams.removeValue(forKey: id) }
        guard let state else { return }
        state.sendTask?.cancel()
        // Never announce a cancel for a request the node has not seen.  The
        // cancel is on the wire BEFORE the caller observes the failure.
        if sendCancel, state.requestSent,
           let data = try? PeerFrameCodec.encode(PeerFrame(type: .cancel, id: id), limits: limits) {
            // Best effort, never blocks on buffer: cancel is tiny.
            if channel.isOpen { _ = channel.send(data) }
        }
        Self.finish(state, error: error)
        // A request parked on backpressure must re-check ownership now.
        wakeBufferWaiters()
    }

    private static func finish(_ s: StreamState, error: PeerWireError) {
        s.timeoutTask?.cancel()
        if let head = s.headContinuation {
            s.headContinuation = nil
            head.resume(throwing: error)
        }
        s.bodyContinuation?.finish(throwing: error)
        s.bodyContinuation = nil
    }

    // MARK: Outbound backpressure

    /// Sends a request frame only while `owner` is still the live stream for
    /// `id`.  Ownership is re-checked under `sendLock` immediately before
    /// `channel.send`, after any backpressure wait.
    private func sendRequest(_ data: Data, id: String, owner: StreamState) async throws {
        while true {
            try await waitForBufferSpace(id: id, owner: owner)
            // Synchronous critical section (never held across an await).
            // sendLock is RECURSIVE on purpose: channel.send may synchronously
            // deliver inbound frames (re-entrant SDK/test callbacks) that call
            // fail() -> sendLock on this same thread.
            let verdict: Int = sendLock.withLock {
                let v: Int = lock.withLock {
                    if closed { return 2 }
                    guard streams[id] === owner, !Task.isCancelled else { return 2 }
                    if channel.bufferedAmount > limits.sendHighWaterBytes { return 1 }  // refilled: wait again
                    owner.requestSent = true
                    return 0
                }
                guard v == 0 else { return v }
                return channel.send(data) ? 0 : 3
            }
            switch verdict {
            case 0: return
            case 1: continue
            case 3: throw PeerWireError.channelClosed
            default: throw PeerWireError.cancelled
            }
        }
    }

    private func waitForBufferSpace(id: String, owner: StreamState) async throws {
        while true {
            if lock.withLock({ closed }) { throw closeError }
            guard lock.withLock({ streams[id] === owner }), !Task.isCancelled else { throw PeerWireError.cancelled }
            guard channel.isOpen else { throw PeerWireError.channelClosed }
            if channel.bufferedAmount <= limits.sendHighWaterBytes { break }
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                // Ownership is checked under the same lock as parking, and
                // fail() removes-then-wakes under it: no lost wake-up.
                let parked: Bool = lock.withLock {
                    if closed || streams[id] !== owner { return false }
                    bufferWaiters.append(c)
                    return true
                }
                if !parked { c.resume(throwing: PeerWireError.cancelled) }
                // Re-check: the drain callback may have fired before parking.
                else if channel.bufferedAmount <= limits.sendHighWaterBytes { wakeBufferWaiters() }
            }
        }
    }

    private func wakeBufferWaiters() {
        let waiters: [CheckedContinuation<Void, Error>] = lock.withLock {
            let w = bufferWaiters
            bufferWaiters.removeAll()
            return w
        }
        for w in waiters { w.resume() }
    }
}
