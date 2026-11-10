import Foundation
import Network
import WebKit
import XCTest
@testable import TermLLM

/// Owns every real stream so the deadline can unblock receives/sends, not just
/// cancel their Swift tasks (PeerByteStream I/O is callback-backed).
private final class RealLoopbackTestResources: @unchecked Sendable {
    let listener = PeerNWLoopbackListener()
    let competingListener = PeerNWLoopbackListener()
    let accepted: AsyncStream<PeerByteStream>
    private let acceptance: AsyncStream<PeerByteStream>.Continuation
    private let lock = NSLock()
    private var streams: [PeerByteStream] = []
    private var closed = false

    init() {
        (accepted, acceptance) = AsyncStream<PeerByteStream>.makeStream()
    }

    func track(_ stream: PeerByteStream) {
        let shouldClose = lock.withLock {
            if closed { return true }
            streams.append(stream)
            return false
        }
        if shouldClose { stream.close() }
    }

    func accept(_ stream: PeerByteStream) {
        track(stream)
        acceptance.yield(stream)
    }

    func close() {
        let pending: [PeerByteStream] = lock.withLock {
            closed = true
            let pending = streams
            streams.removeAll()
            return pending
        }
        acceptance.finish()
        pending.forEach { $0.close() }
        listener.stop()
        competingListener.stop()
    }
}

final class PeerNWLoopbackListenerTests: XCTestCase {
    func testIsLoopbackAcceptsOnlyLiteralIPv4AndIPv6LoopbackEndpoints() throws {
        // Network normalizes IPv4-mapped loopback to the IPv4 loopback host.
        for host in ["127.0.0.1", "::1", "::ffff:127.0.0.1"] {
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: 43210)
            XCTAssertTrue(PeerNWLoopbackListener.isLoopback(endpoint), "Must accept \(host)")
        }
        // Accepted connections can retain the mapped IPv6 representation,
        // unlike NWEndpoint.Host(String), which normalizes it to IPv4.
        let mappedLoopback = try XCTUnwrap(IPv6Address("::ffff:127.0.0.1"))
        XCTAssertTrue(PeerNWLoopbackListener.isLoopback(
            .hostPort(host: .ipv6(mappedLoopback), port: 43210)))
        let mappedRemote = try XCTUnwrap(IPv6Address("::ffff:192.0.2.1"))
        XCTAssertFalse(PeerNWLoopbackListener.isLoopback(
            .hostPort(host: .ipv6(mappedRemote), port: 43210)))
        for host in ["127.0.0.2", "0.0.0.0", "192.0.2.1", "::", "2001:db8::1",
                     "::ffff:192.0.2.1", "localhost"] {
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: 43210)
            XCTAssertFalse(PeerNWLoopbackListener.isLoopback(endpoint), "Must reject \(host)")
        }
    }

    func testRealListenerExchangesBytesOverIPv4AndIPv6OnSamePort() async throws {
        try await withRealLoopbackDeadline { resources in
            let port = try await resources.listener.start(port: nil) { resources.accept($0) }
            XCTAssertNotEqual(port, 0)
            let endpointPort = try XCTUnwrap(NWEndpoint.Port(rawValue: port))
            var accepted = resources.accepted.makeAsyncIterator()

            // Literal addresses prevent hostname resolution/fallback from hiding
            // a broken family. Both connections stay open until the test ends.
            for host in ["127.0.0.1", "::1"] {
                let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
                let client = PeerNWByteStream(connection: connection)
                resources.track(client)
                connection.start(queue: DispatchQueue(label: "com.termllm.tests.loopback.client"))

                let request = Data("loopback request \(host)".utf8)
                try await client.write(request)
                let next = await accepted.next()
                let server = try XCTUnwrap(next, "Listener must accept \(host) on the same port")
                let received = try await readLoopbackBytes(request.count, from: server)
                XCTAssertEqual(received, request, "Client-to-listener bytes over \(host)")

                let response = Data("loopback response \(host)".utf8)
                try await server.write(response)
                let returned = try await readLoopbackBytes(response.count, from: client)
                XCTAssertEqual(returned, response, "Listener-to-client bytes over \(host)")
            }
        }
    }

    func testRealListenerRejectsSecondListenerOnReservedPort() async throws {
        try await withRealLoopbackDeadline { resources in
            let port = try await resources.listener.start(port: nil) { resources.accept($0) }
            XCTAssertNotEqual(port, 0)
            do {
                // Use the production listener for both reservations: enabling
                // SO_REUSEPORT on that path must not make this test pass.
                _ = try await resources.competingListener.start(port: port) { $0.close() }
                XCTFail("A second listener must not share the reserved loopback port")
            } catch let error as NWError {
                XCTAssertEqual(error, .posix(.EADDRINUSE),
                               "Only an address-in-use failure proves exclusive reservation")
            }
        }
    }
}

private func readLoopbackBytes(_ count: Int, from stream: PeerByteStream) async throws -> Data {
    var result = Data()
    // TCP may split a write across multiple receives, even on loopback.
    while result.count < count {
        try Task.checkCancellation()
        guard let chunk = try await stream.read(maxLength: count - result.count) else {
            throw RealLoopbackTestError.unexpectedEOF
        }
        result.append(chunk)
    }
    return result
}

private func withRealLoopbackDeadline(
    _ operation: @escaping @Sendable (RealLoopbackTestResources) async throws -> Void
) async throws {
    let resources = RealLoopbackTestResources()
    // Stop again after the group drains in case cancellation raced listener ready.
    defer { resources.close() }
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await operation(resources) }
        group.addTask {
            // Preferred-port conflicts currently retry for 3.5 seconds. Leave
            // headroom on physical devices, while bounding all real network I/O.
            try await Task.sleep(nanoseconds: 15_000_000_000)
            throw RealLoopbackTestError.timedOut
        }
        defer {
            resources.close() // Also finishes accepted.next() and closes pending I/O.
            group.cancelAll()
        }
        _ = try await group.next()
    }
}
