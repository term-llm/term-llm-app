#if canImport(Network)
import Foundation
import Network

/// An exclusive localhost listener reservation. On device one dual-stack
/// listener is restricted to the loopback interface: separate family listeners
/// compete for iOS NECP's port reservation. Simulator lacks NECP local-only
/// acceptance, so it uses explicit loopback-address binds for both families.
/// Remote-endpoint checks provide defense in depth on both platforms.
// Sendability: lock protects the listener reservation array. Network.framework
// owns listener callbacks on queue and supports cross-thread start/cancel. The
// bridge serializes start attempts; stop may race a pending start and is repeated
// by the bridge if that reservation is no longer wanted.
final class PeerNWLoopbackListener: PeerLoopbackListening, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.termllm.peer.loopback")
    private let lock = NSLock()
    private var listeners: [NWListener] = []
    private let maxAttempts = 8

    init() {}

    func start(port preferredPort: UInt16?, onConnection: @escaping @Sendable (PeerByteStream) -> Void) async throws -> UInt16 {
        var lastError: Error = PeerWireError.channelClosed
        let attempts = maxAttempts
        for attempt in 0..<attempts {
            try Task.checkCancellation()
            let requested = preferredPort.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any
            #if targetEnvironment(simulator)
            let host: NWEndpoint.Host? = .ipv4(.loopback)
            #else
            let host: NWEndpoint.Host? = nil
            #endif
            let listener = try makeListener(host: host, port: requested, onConnection: onConnection)
            do {
                let port = try await Self.ready(listener, queue: queue)
                var reserved = [listener]
                #if targetEnvironment(simulator)
                guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw PeerWireError.channelClosed }
                let v6 = try makeListener(host: .ipv6(.loopback), port: nwPort,
                                          onConnection: onConnection)
                do {
                    _ = try await Self.ready(v6, queue: queue)
                    reserved.append(v6)
                } catch {
                    v6.cancel()
                    // If IPv6 is unavailable there is no ::1 origin to occupy.
                    guard let networkError = error as? NWError,
                          case .posix(let code) = networkError,
                          code == .EADDRNOTAVAIL || code == .EAFNOSUPPORT else { throw error }
                }
                #endif
                lock.withLock { listeners = reserved }
                return port
            } catch {
                listener.cancel()
                lastError = error
            }
            if preferredPort != nil, attempt < attempts - 1 {
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        throw lastError
    }

    private func makeListener(host: NWEndpoint.Host?, port: NWEndpoint.Port,
                              onConnection: @escaping @Sendable (PeerByteStream) -> Void) throws -> NWListener {
        let parameters = NWParameters.tcp
        if let host {
            // Simulator lacks device NECP interface enforcement. Bind literal
            // loopback addresses there rather than allowing a wildcard socket.
            parameters.requiredLocalEndpoint = .hostPort(host: host, port: port)
        } else {
            // On device reserve both address families in one listener, without
            // exposing the wildcard socket on Wi-Fi/cellular interfaces.
            parameters.requiredInterfaceType = .loopback
        }
        #if !targetEnvironment(simulator)
        // Simulator has no NECP listener attribution; this option rejects even
        // loopback clients there. Its explicit loopback binds enforce locality.
        parameters.acceptLocalOnly = true
        #endif
        // Never enable port sharing: this origin carries a capability cookie.
        parameters.allowLocalEndpointReuse = false
        let listener: NWListener
        if host != nil {
            listener = try NWListener(using: parameters)
        } else {
            listener = try NWListener(using: parameters, on: port)
        }
        listener.newConnectionHandler = { connection in
            guard Self.isLoopback(connection.endpoint) else {
                connection.cancel()
                return
            }
            let stream = PeerNWByteStream(connection: connection)
            connection.start(queue: DispatchQueue(label: "com.termllm.peer.loopback.conn"))
            onConnection(stream)
        }
        return listener
    }

    private static func ready(_ listener: NWListener, queue: DispatchQueue) async throws -> UInt16 {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
                let once = PeerOnce()
                listener.stateUpdateHandler = { [weak listener] state in
                    switch state {
                    case .ready:
                        if let port = listener?.port?.rawValue, port != 0 {
                            once.run { cont.resume(returning: port) }
                        }
                    case .failed(let error), .waiting(let error):
                        once.run { cont.resume(throwing: error) }
                    case .cancelled:
                        once.run { cont.resume(throwing: CancellationError()) }
                    default:
                        break
                    }
                }
                if Task.isCancelled {
                    once.run { cont.resume(throwing: CancellationError()) }
                } else {
                    listener.start(queue: queue)
                }
            }
        }, onCancel: {
            listener.cancel()
        })
    }

    func stop() {
        let ls: [NWListener] = lock.withLock { let l = listeners; listeners = []; return l }
        ls.forEach { $0.cancel() }
    }

    static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return address == .loopback
        case .ipv6(let address):
            // A dual-stack listener can report an IPv4 client as a mapped
            // IPv6 address. Only accept mapped 127.0.0.1.
            return address == .loopback || (address.isIPv4Mapped && address.asIPv4 == IPv4Address.loopback)
        default: return false
        }
    }
}

// Sendability: lock claims done once; only the winner invokes its local body.
final class PeerOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        let first: Bool = lock.withLock { if done { return false }; done = true; return true }
        if first { body() }
    }
}

final class PeerNWByteStream: PeerByteStream, Sendable {
    private let connection: NWConnection

    init(connection: NWConnection) { self.connection = connection }

    func read(maxLength: Int) async throws -> Data? {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data?, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maxLength) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    cont.resume(returning: data)
                } else if let error {
                    cont.resume(throwing: error)
                } else if isComplete {
                    cont.resume(returning: nil)
                } else {
                    cont.resume(returning: Data())
                }
            }
        }
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    func close() { connection.cancel() }
}
#endif
