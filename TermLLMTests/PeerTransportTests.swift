import Foundation
import Network
import WebKit
import XCTest
@testable import TermLLM

final class PeerTransportTests: XCTestCase {
    func testOptInTimelineUsesActualMultiplexerEventsAndRedactsAdversarialInput() async throws {
        let clock = DiagnosticTestClock()
        let collector = DiagnosticTestCollector()
        let diagnostics = LinkedDevicesDiagnostics(clock: { clock.now() }, sink: { collector.append($0) })
        let connection = diagnostics.connection()

        let channel = ControlledRuntimeTestChannel()
        let multiplexer = PeerHTTPMultiplexer(channel: channel, diagnostics: connection)
        var header = PeerHeader()
        header.set("X-Secret", "HEADER-SECRET")
        let requestValue = PeerHTTPRequest(
            method: "TRACESECRET", path: "/chat/v1/responses/RAW-ID/events?token=QUERY-SECRET",
            header: header, body: Data("BODY-SECRET".utf8))
        let task = Task {
            try await multiplexer.forward(requestValue)
        }
        await channel.waitForSentFrames(1)
        let id = try XCTUnwrap(channel.sentFrames.first?.id)
        clock.advance(milliseconds: 4)
        try channel.deliver(PeerFrame(type: .responseStart, id: id, status: 206))
        clock.advance(milliseconds: 3)
        let body = Data("partial".utf8)
        try channel.deliver(PeerFrame(type: .responseBody, id: id, body: body))
        clock.advance(milliseconds: 5)
        try channel.deliver(PeerFrame(type: .responseEnd, id: id))
        let response = try await task.value
        let collected = try await response.collect(limit: 100)
        XCTAssertEqual(collected, body)

        XCTAssertEqual(collector.records.map(\.stage), [
            .requestStarted, .responseHeaders, .requestTerminal,
        ])
        XCTAssertEqual(collector.records.map(\.elapsedMilliseconds),
                       collector.records.map(\.elapsedMilliseconds).sorted())
        let request = try XCTUnwrap(collector.records.first { $0.stage == .requestStarted })
        XCTAssertEqual(request.method, .other)
        XCTAssertEqual(request.route, .responseEvents)
        let headers = try XCTUnwrap(collector.records.first { $0.stage == .responseHeaders })
        XCTAssertEqual(headers.status, 206)
        let terminal = try XCTUnwrap(collector.records.first { $0.stage == .requestTerminal })
        XCTAssertEqual(terminal.durationMilliseconds, 12)
        XCTAssertEqual(terminal.bytes, body.count)
        XCTAssertEqual(terminal.outcome, .finished)

        let rendered = collector.records.map(LinkedDevicesDiagnostics.format).joined(separator: "\n")
        for secret in ["TRACESECRET", "RAW-ID", "QUERY-SECRET", "HEADER-SECRET", "BODY-SECRET"] {
            XCTAssertFalse(rendered.contains(secret), "rendered timeline leaked \(secret)")
        }
        XCTAssertTrue(rendered.contains("method=other"))
        XCTAssertTrue(rendered.contains("route=response_events"))
        multiplexer.close()
    }

    func testConcurrentCloseQueuesTerminalUntilDiagnosticStartWithoutDeadlockOrOrphan() async throws {
        let clock = PausingDiagnosticTestClock()
        let collector = DiagnosticTestCollector()
        let diagnostics = LinkedDevicesDiagnostics(clock: { clock.now() }, sink: { collector.append($0) })
        let channel = ControlledRuntimeTestChannel()
        let multiplexer = PeerHTTPMultiplexer(channel: channel, diagnostics: diagnostics.connection())
        let task = Task.detached {
            try await multiplexer.forward(PeerHTTPRequest(method: "GET", path: "/chat/v1/sessions"))
        }

        await clock.waitForStart()
        defer { clock.resumeStart() }

        // close() runs while requestStarted is paused before the recorder's
        // active-request insertion. It must return without waiting on the
        // recorder callback, while its terminal remains causally queued.
        multiplexer.close()
        XCTAssertTrue(collector.records.isEmpty)
        XCTAssertEqual(multiplexer.openStreamCount, 0)

        clock.resumeStart()
        await XCTAssertThrowsErrorAsync(try await task.value)
        await XCTAssertPeerSendersDrained(multiplexer)

        let records = collector.records
        XCTAssertEqual(records.map(\.stage), [.requestStarted, .requestTerminal])
        XCTAssertEqual(records.filter { $0.stage == .requestStarted }.count, 1)
        XCTAssertEqual(records.filter { $0.stage == .requestTerminal }.count, 1)
        XCTAssertEqual(records.last?.outcome, .failed)
        XCTAssertEqual(records.last?.reason, .channelClosed)
        XCTAssertTrue(channel.sentFrames.isEmpty,
                      "closing during start recording must not send after channel retirement")
    }

    func testArbitraryRemoteErrorMapsToFixedReasonWithoutLeak() async throws {
        let collector = DiagnosticTestCollector()
        let diagnostics = LinkedDevicesDiagnostics(sink: { collector.append($0) })
        let channel = ControlledRuntimeTestChannel()
        let multiplexer = PeerHTTPMultiplexer(channel: channel, diagnostics: diagnostics.connection())
        let task = Task {
            try await multiplexer.forward(PeerHTTPRequest(method: "GET", path: "/private/RAW-PATH"))
        }
        await channel.waitForSentFrames(1)
        let id = try XCTUnwrap(channel.sentFrames.first?.id)
        try channel.deliver(PeerFrame(type: .responseStart, id: id, status: 502))
        let response = try await task.value
        try channel.deliver(PeerFrame(type: .responseEnd, id: id, error: "ERROR-SECRET localized host.example"))
        await XCTAssertThrowsErrorAsync(try await response.collect(limit: 100))

        let terminal = try XCTUnwrap(collector.records.first { $0.stage == .requestTerminal })
        XCTAssertEqual(terminal.outcome, .truncated)
        XCTAssertEqual(terminal.reason, .remoteFailure)
        let rendered = collector.records.map(LinkedDevicesDiagnostics.format).joined(separator: "\n")
        XCTAssertFalse(rendered.contains("ERROR-SECRET"))
        XCTAssertFalse(rendered.contains("host.example"))
        XCTAssertFalse(rendered.contains("RAW-PATH"))
        multiplexer.close()
    }

    func testOversizedRequestsDoNotPoisonChannelAndSmallRequestStillSucceeds() async throws {
        var limits = PeerWireLimits.default
        limits.maxFrameBytes = 512
        limits.maxRequestBodyBytes = 256
        let channel = ControlledRuntimeTestChannel()
        let multiplexer = PeerHTTPMultiplexer(channel: channel, limits: limits)

        do {
            _ = try await multiplexer.forward(PeerHTTPRequest(
                method: "POST", path: "/chat/v1/responses", body: Data(repeating: 0x61, count: 257)))
            XCTFail("Body above the normalized request limit must be rejected before dispatch")
        } catch {
            XCTAssertEqual(error as? PeerWireError, .requestBodyTooLarge(257))
        }

        var largeHeader = PeerHeader()
        largeHeader.set("X-Padding", String(repeating: "h", count: 300))
        do {
            _ = try await multiplexer.forward(PeerHTTPRequest(
                method: "POST", path: "/chat/v1/responses", header: largeHeader,
                body: Data(repeating: 0x62, count: limits.maxRequestBodyBytes)))
            XCTFail("Encoded request plus header/base64 overhead must respect the frame limit")
        } catch {
            guard case .frameTooLarge(let size)? = error as? PeerWireError else {
                return XCTFail("Expected frameTooLarge, got \(error)")
            }
            XCTAssertGreaterThan(size, limits.maxFrameBytes)
        }
        XCTAssertTrue(channel.sentFrames.isEmpty)
        XCTAssertEqual(multiplexer.openStreamCount, 0)
        XCTAssertFalse(multiplexer.isClosed)

        let small = Task {
            try await multiplexer.forward(PeerHTTPRequest(
                method: "POST", path: "/chat/v1/responses", body: Data("ok".utf8)))
        }
        await channel.waitForSentFrames(1)
        let id = try XCTUnwrap(channel.sentFrames.first?.id)
        try channel.deliver(PeerFrame(type: .responseStart, id: id, status: 200), limits: limits)
        try channel.deliver(PeerFrame(type: .responseEnd, id: id), limits: limits)
        let response = try await small.value
        XCTAssertEqual(response.status, 200)
        let collected = try await response.collect(limit: 16)
        XCTAssertEqual(collected, Data())
        XCTAssertEqual(channel.sentFrames.filter { $0.type == .request }.count, 1)
        XCTAssertEqual(multiplexer.openStreamCount, 0)
        await XCTAssertPeerSendersDrained(multiplexer)
        XCTAssertFalse(multiplexer.isClosed)
        multiplexer.close()
    }

    func testChannelDropBeforeHeadersFailsPendingRequestAndDrainsStream() async throws {
        let channel = ControlledRuntimeTestChannel()
        let multiplexer = PeerHTTPMultiplexer(channel: channel)
        let task = Task {
            try await multiplexer.forward(PeerHTTPRequest(method: "GET", path: "/chat/v1/sessions"))
        }
        await channel.waitForSentFrames(1)

        channel.remoteClose()
        do {
            _ = try await task.value
            XCTFail("A dropped channel must not invent response headers")
        } catch {
            XCTAssertEqual(error as? PeerWireError, .channelClosed)
        }
        XCTAssertEqual(multiplexer.openStreamCount, 0)
        await XCTAssertPeerSendersDrained(multiplexer)
        XCTAssertTrue(multiplexer.isClosed)
    }

    func testChannelDropMidFiniteBodyAndMidSSEFailsWithoutSuccessfulEnd() async throws {
        let cases = [
            ("application/json", Data("{\"partial\":".utf8)),
            ("text/event-stream", Data("event: response.output_text.delta\ndata: {\"delta\":\"part\"}\n\n".utf8)),
        ]
        for (contentType, partial) in cases {
            let collector = DiagnosticTestCollector()
            let diagnostics = LinkedDevicesDiagnostics(sink: { collector.append($0) })
            let channel = ControlledRuntimeTestChannel()
            let multiplexer = PeerHTTPMultiplexer(channel: channel, diagnostics: diagnostics.connection())
            let task = Task {
                try await multiplexer.forward(PeerHTTPRequest(method: "GET", path: "/chat/v1/stream"))
            }
            await channel.waitForSentFrames(1)
            let id = try XCTUnwrap(channel.sentFrames.first?.id)
            var header = PeerHeader()
            header.set("Content-Type", contentType)
            try channel.deliver(PeerFrame(type: .responseStart, id: id, header: header, status: 200))
            let response = try await task.value
            try channel.deliver(PeerFrame(type: .responseBody, id: id, body: partial))
            var iterator = response.body.makeAsyncIterator()
            let first = try await iterator.next()
            XCTAssertEqual(first, partial)

            channel.remoteClose()
            do {
                _ = try await iterator.next()
                XCTFail("A truncated \(contentType) response must fail, not report a successful end")
            } catch {
                XCTAssertEqual(error as? PeerWireError, .channelClosed)
            }
            XCTAssertEqual(multiplexer.openStreamCount, 0)
            await XCTAssertPeerSendersDrained(multiplexer)
            multiplexer.close()
            let terminals = collector.records.filter { $0.stage == .requestTerminal }
            XCTAssertEqual(terminals.count, 1)
            XCTAssertEqual(terminals.first?.outcome, .truncated)
            XCTAssertEqual(terminals.first?.reason, .channelClosed)
            XCTAssertTrue(multiplexer.isClosed)
        }
    }

    func testCancellationAfterRequestSendEmitsOneCancelAndIgnoresLateResponse() async throws {
        let collector = DiagnosticTestCollector()
        let diagnostics = LinkedDevicesDiagnostics(sink: { collector.append($0) })
        let diagnostic = diagnostics.connection()
        let channel = ControlledRuntimeTestChannel()
        let multiplexer = PeerHTTPMultiplexer(channel: channel, diagnostics: diagnostic)
        let task = Task {
            try await multiplexer.forward(PeerHTTPRequest(
                method: "POST", path: "/chat/v1/responses", body: Data("mutation".utf8)))
        }
        await channel.waitForSentFrames(1)
        let id = try XCTUnwrap(channel.sentFrames.first?.id)

        task.cancel()
        await XCTAssertThrowsErrorAsync(try await task.value)
        await channel.waitForSentFrames(2)
        XCTAssertEqual(channel.sentFrames.map(\.type), [.request, .cancel])
        XCTAssertEqual(channel.sentFrames.map(\.id), [id, id])
        XCTAssertEqual(multiplexer.openStreamCount, 0)
        await XCTAssertPeerSendersDrained(multiplexer)

        try channel.deliver(PeerFrame(type: .responseStart, id: id, status: 200))
        try channel.deliver(PeerFrame(type: .responseEnd, id: id))
        XCTAssertEqual(channel.sentFrames.map(\.type), [.request, .cancel],
                       "late response frames must not resurrect or re-cancel a retired request")
        let terminals = collector.records.filter { $0.stage == .requestTerminal }
        XCTAssertEqual(terminals.count, 1)
        XCTAssertEqual(terminals.first?.outcome, .cancelled)
        XCTAssertEqual(terminals.first?.reason, .cancelled)
        XCTAssertEqual(multiplexer.openStreamCount, 0)
        multiplexer.close()
    }

    func testCancellingBackpressuredSenderReleasesTaskWithoutSending() async throws {
        let channel = BackpressuredRuntimeTestChannel()
        let multiplexer = PeerHTTPMultiplexer(channel: channel)
        let task = Task {
            try await multiplexer.forward(PeerHTTPRequest(method: "POST", path: "/chat/v1/responses",
                                                            header: PeerHeader(), body: Data("body".utf8)),
                                          headTimeout: nil)
        }
        for _ in 0..<100 where multiplexer.parkedSenderCount == 0 {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(multiplexer.parkedSenderCount, 1)
        XCTAssertEqual(multiplexer.activeSenderCount, 1)

        task.cancel()
        await XCTAssertThrowsErrorAsync(try await task.value)
        for _ in 0..<100 where multiplexer.activeSenderCount != 0 {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(multiplexer.parkedSenderCount, 0)
        XCTAssertEqual(multiplexer.activeSenderCount, 0)
        XCTAssertEqual(channel.sendCount, 0, "cancelled parked owner must never send its request")
        XCTAssertEqual(multiplexer.openStreamCount, 0)
        multiplexer.close()
    }

    func testCancelledPendingPeerRequestReleasesContinuationAndStream() async throws {
        let multiplexer = PeerHTTPMultiplexer(channel: RuntimeTestChannel())
        let task = Task {
            try await multiplexer.forward(PeerHTTPRequest(method: "GET", path: "/chat/v1/sessions",
                                                            header: PeerHeader(), body: Data()), headTimeout: nil)
        }
        for _ in 0..<100 where multiplexer.openStreamCount == 0 { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertEqual(multiplexer.openStreamCount, 1)
        task.cancel()
        await XCTAssertThrowsErrorAsync(try await task.value)
        XCTAssertEqual(multiplexer.openStreamCount, 0)
        multiplexer.close()
    }

    func testBridgeCancellationReleasesLateListenerAndNeverActivates() async throws {
        let listener = ControlledLoopbackListener()
        let authorization = PeerAuthorizationState(PeerAuthorization(peerID: "host", sessionID: "session",
                                                                      expiresAt: .distantFuture))
        let bridge = PeerLoopbackBridge(forwarder: LinkedDevicesForwarder(), authorization: authorization,
                                        listener: listener)
        let task = Task { try await bridge.startPaused() }
        for _ in 0..<100 where !listener.started { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertTrue(listener.started)
        task.cancel()
        listener.resume(port: 43220)
        await XCTAssertThrowsErrorAsync(try await task.value)
        XCTAssertTrue(listener.stopped)
        XCTAssertNil(bridge.currentEndpoint)
    }

    func testFrameCodecIsStrictAndBounded() throws {
        var header = PeerHeader()
        header.set("accept", "application/json")
        let frame = PeerFrame(type: .request, id: "1", method: "GET", path: "/v1/sessions", header: header)
        XCTAssertEqual(try PeerFrameCodec.decode(PeerFrameCodec.encode(frame)), frame)
        XCTAssertThrowsError(try PeerFrameCodec.decode(Data(repeating: 0x20, count: PeerWireLimits.default.maxFrameBytes + 1)))
        XCTAssertThrowsError(try PeerFrameCodec.decode(Data("{\"version\":2,\"type\":\"request\",\"id\":\"1\",\"method\":\"GET\",\"path\":\"/\"}".utf8)))
    }

    func testLoopbackGateRequiresExactHostCapabilityAndScope() {
        let gate = PeerLoopbackGate(port: 43212, capability: "secret", scopePrefix: "/")
        func request(host: String, cookie: String?) -> PeerLoopbackRequest {
            var header = PeerHeader(); header.set("Host", host)
            if let cookie { header.set("Cookie", cookie) }
            return PeerLoopbackRequest(method: "GET", target: "/chat/1", version: "HTTP/1.1", header: header, body: Data())
        }
        XCTAssertEqual(gate.evaluate(request(host: "localhost:43212", cookie: "termllm_peer_43212=secret")), .allow)
        if case .allow = gate.evaluate(request(host: "127.0.0.1:43212", cookie: "termllm_peer_43212=secret")) {
            XCTFail("numeric-host rebinding bypassed exact localhost gate")
        }
        if case .allow = gate.evaluate(request(host: "localhost:43212", cookie: "termllm_peer_43212=wrong")) {
            XCTFail("wrong capability was accepted")
        }
    }

    func testEmptyICEConfigurationIsValidForHostCandidates() throws {
        let value = LinkedDevicesICECredentials(iceServers: [], expiresAt: nil)
        XCTAssertEqual(try LinkedDevicesBrokerClient.validateICE(value), value)
        XCTAssertThrowsError(try LinkedDevicesBrokerClient.validateICE(.init(
            iceServers: [PeerICEServer(urls: [], username: nil, credential: nil)], expiresAt: nil)))
    }

    func testNativePeerPreservesSignedBasePathAndQueryExactly() throws {
        let base = try XCTUnwrap(URL(string: "http://localhost:43215/chat/"))
        let url = try XCTUnwrap(URL(string: "http://localhost:43215/chat/v1/sessions?limit=20"))
        XCTAssertTrue(WebRTCHubTransport.sameOrigin(url, base))
        let peer = try WebRTCHubTransport.peerRequest(from: URLRequest(url: url), url: url)
        XCTAssertEqual(peer.path, "/chat/v1/sessions?limit=20")
        let gate = PeerLoopbackGate(port: 43215, capability: "secret", scopePrefix: "/chat")
        var header = PeerHeader(); header.set("Host", "localhost:43215"); header.set("Cookie", "termllm_peer_43215=secret")
        XCTAssertEqual(gate.evaluate(.init(method: "GET", target: peer.path, version: "HTTP/1.1", header: header, body: Data())), .allow)
        if case .allow = gate.evaluate(.init(method: "GET", target: "/v1/sessions", version: "HTTP/1.1", header: header, body: Data())) {
            XCTFail("request escaped the signed base path")
        }
    }

    func testLoopbackStreamsChunksWithoutStrippingSignedBasePath() async throws {
        let port: UInt16 = 43215
        let capability = "secret"
        let target = "/chat/v1/responses?stream=1%2B2"
        let request = Data([
            "GET \(target) HTTP/1.1\r\n",
            "Host: localhost:\(port)\r\n",
            "Cookie: termllm_peer_\(port)=\(capability)\r\n",
            "Connection: close\r\n",
            "\r\n",
        ].joined().utf8)
        XCTAssertEqual(Data(request.suffix(4)), Data([0x0D, 0x0A, 0x0D, 0x0A]))
        let stream = MemoryPeerByteStream(input: request)
        let forwarder = LinkedDevicesForwarder(chunks: [Data("one".utf8), Data("two".utf8)])
        let configuration = PeerLoopbackConnection.Configuration(
            gate: PeerLoopbackGate(port: port, capability: capability, scopePrefix: "/chat"))
        let connection = PeerLoopbackConnection(stream: stream, forwarder: forwarder,
                                                configuration: configuration, isAuthorized: { true })

        await connection.serve()

        XCTAssertEqual(forwarder.paths, [target], "the signed mount and encoded query must cross unchanged")
        let response = try XCTUnwrap(String(data: stream.written, encoding: .utf8))
        XCTAssertTrue(response.contains("Transfer-Encoding: chunked\r\n"))
        let expectedSuffix = Data("3\r\none\r\n3\r\ntwo\r\n0\r\n\r\n".utf8)
        XCTAssertEqual(Data(stream.written.suffix(expectedSuffix.count)), expectedSuffix,
                       "the loopback bridge must preserve streaming chunk boundaries and termination")
        XCTAssertTrue(stream.closed)
    }

    func testLoopbackAbortsFiniteAndSSEWithoutSuccessTerminatorAfterBodyFailure() async throws {
        let cases = [
            ("application/json", Data("{\"partial\":".utf8)),
            ("text/event-stream", Data("event: response.output_text.delta\ndata: {\"delta\":\"part\"}\n\n".utf8)),
        ]
        for (contentType, partial) in cases {
            let port: UInt16 = 43226
            let capability = "secret"
            let request = Data([
                "GET /chat/v1/stream HTTP/1.1\r\n",
                "Host: localhost:\(port)\r\n",
                "Cookie: termllm_peer_\(port)=\(capability)\r\n",
                "Connection: close\r\n",
                "\r\n",
            ].joined().utf8)
            let stream = MemoryPeerByteStream(input: request)
            let forwarder = LinkedDevicesForwarder(
                chunks: [partial], bodyError: PeerWireError.channelClosed, contentType: contentType)
            let connection = PeerLoopbackConnection(
                stream: stream, forwarder: forwarder,
                configuration: .init(gate: PeerLoopbackGate(
                    port: port, capability: capability, scopePrefix: "/chat")),
                isAuthorized: { true })

            await connection.serve()

            var chunk = Data("\(String(partial.count, radix: 16))\r\n".utf8)
            chunk.append(partial)
            chunk.append(Data("\r\n".utf8))
            XCTAssertEqual(Data(stream.written.suffix(chunk.count)), chunk)
            XCTAssertNil(stream.written.range(of: Data("0\r\n\r\n".utf8)),
                         "A failed \(contentType) stream must remain observably truncated")
            XCTAssertTrue(stream.closed)
        }
    }

    func testPeerBrowserRevokesOnlyTaggedRemoteAuthorizationLoss() throws {
        let url = try XCTUnwrap(URL(string: "http://localhost:43212/chat/"))
        func response(_ status: Int, _ fields: [String: String] = [:]) throws -> HTTPURLResponse {
            try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: fields))
        }
        XCTAssertFalse(BrowserView.shouldRevokeAuthorization(for: try response(403), isLinkedDevices: true))
        XCTAssertFalse(BrowserView.shouldRevokeAuthorization(for: try response(401), isLinkedDevices: true))
        XCTAssertTrue(BrowserView.shouldRevokeAuthorization(for: try response(401, [
            PeerAuthorizationLoss.headerName: PeerAuthorizationLoss.headerValue,
        ]), isLinkedDevices: true))
        XCTAssertTrue(BrowserView.shouldRevokeAuthorization(for: try response(403), isLinkedDevices: false))
    }

    func testNativePeerRequestStripsCredentialsAndProxyMetadata() throws {
        var request = URLRequest(url: URL(string: "http://localhost:43215/v1/sessions")!)
        request.setValue("Bearer owner", forHTTPHeaderField: "Authorization")
        request.setValue("session=owner", forHTTPHeaderField: "Cookie")
        request.setValue("https://owner.example", forHTTPHeaderField: "Origin")
        request.setValue("10.0.0.1", forHTTPHeaderField: "X-Forwarded-For")
        request.setValue("kept", forHTTPHeaderField: "X-Custom")
        let peer = try WebRTCHubTransport.peerRequest(from: request, url: request.url!)
        XCTAssertNil(peer.header.first("Authorization"))
        XCTAssertNil(peer.header.first("Cookie"))
        XCTAssertNil(peer.header.first("Origin"))
        XCTAssertNil(peer.header.first("X-Forwarded-For"))
        XCTAssertEqual(peer.header.first("X-Custom"), "kept")
    }

    func testRouteForbiddenDoesNotRevokePeerIdentity() async throws {
        let forwarder = LinkedDevicesForwarder(status: 403)
        let authorization = PeerAuthorizationState(PeerAuthorization(peerID: "host", sessionID: "session", expiresAt: .distantFuture))
        let transport = WebRTCHubTransport(forwarder: forwarder, authorization: authorization,
                                            hubBaseURL: URL(string: "http://localhost:43215/")!)
        let request = URLRequest(url: URL(string: "http://localhost:43215/v1/linked-devices")!)
        let callback = RuntimeLockedFlag()
        await XCTAssertThrowsErrorAsync(try await transport.execute(request, onUnauthorized: { callback.set() }))
        XCTAssertFalse(callback.value)
        XCTAssertTrue(authorization.check())
    }

    func testPendingRequestDropThenReplacementReadSucceedsWithoutReplay() async throws {
        let source = LinkedDevicesSourceTransport()
        let base = try XCTUnwrap(URL(string: "http://localhost:43227/"))
        let request = URLRequest(url: try XCTUnwrap(URL(string: "http://localhost:43227/v1/sessions")))

        let oldChannel = ControlledRuntimeTestChannel()
        let oldMultiplexer = PeerHTTPMultiplexer(channel: oldChannel)
        let oldAuthorization = PeerAuthorizationState(PeerAuthorization(
            peerID: "host", sessionID: "old", expiresAt: .distantFuture))
        source.install(WebRTCHubTransport(forwarder: oldMultiplexer, authorization: oldAuthorization,
                                          hubBaseURL: base))
        let dropped = Task { try await source.execute(request, onUnauthorized: nil) }
        await oldChannel.waitForSentFrames(1)
        oldChannel.remoteClose()
        await XCTAssertThrowsErrorAsync(try await dropped.value)
        XCTAssertEqual(oldChannel.sentFrames.filter { $0.type == .request }.count, 1)
        XCTAssertEqual(oldMultiplexer.openStreamCount, 0)

        let newChannel = ControlledRuntimeTestChannel()
        let newMultiplexer = PeerHTTPMultiplexer(channel: newChannel)
        let newAuthorization = PeerAuthorizationState(PeerAuthorization(
            peerID: "host", sessionID: "new", expiresAt: .distantFuture))
        source.install(WebRTCHubTransport(forwarder: newMultiplexer, authorization: newAuthorization,
                                          hubBaseURL: base))
        let recovered = Task { try await source.execute(request, onUnauthorized: nil) }
        await newChannel.waitForSentFrames(1)
        let id = try XCTUnwrap(newChannel.sentFrames.first?.id)
        var header = PeerHeader()
        header.set("Content-Type", "application/json")
        try newChannel.deliver(PeerFrame(type: .responseStart, id: id, header: header, status: 200))
        try newChannel.deliver(PeerFrame(type: .responseBody, id: id, body: Data("{}".utf8)))
        try newChannel.deliver(PeerFrame(type: .responseEnd, id: id))

        let (data, response) = try await recovered.value
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(data, Data("{}".utf8))
        XCTAssertEqual(newChannel.sentFrames.filter { $0.type == .request }.count, 1)
        XCTAssertEqual(oldChannel.sentFrames.filter { $0.type == .request }.count, 1,
                       "recovery must not replay the dropped request")
        newMultiplexer.close()
    }

    func testConcurrentOldGenerationResultsCannotPublishOrReplayAfterRecovery() async throws {
        let source = LinkedDevicesSourceTransport()
        let base = try XCTUnwrap(URL(string: "http://localhost:43217/"))
        let oldForwarder = ConcurrentDelayedLinkedDevicesForwarder()
        let oldAuthorization = PeerAuthorizationState(PeerAuthorization(
            peerID: "host", sessionID: "old", expiresAt: .distantFuture))
        source.install(WebRTCHubTransport(forwarder: oldForwarder, authorization: oldAuthorization,
                                          hubBaseURL: base))

        let readURL = try XCTUnwrap(URL(string: "http://localhost:43217/v1/sessions"))
        let mutationURL = try XCTUnwrap(URL(string: "http://localhost:43217/v1/responses"))
        var mutation = URLRequest(url: mutationURL)
        mutation.httpMethod = "POST"
        mutation.httpBody = Data("{}".utf8)
        let oldRead = Task { try await source.execute(URLRequest(url: readURL), onUnauthorized: nil) }
        let oldMutation = Task { [mutation] in try await source.execute(mutation, onUnauthorized: nil) }
        await oldForwarder.waitForDispatches(2)

        let replacement = LinkedDevicesForwarder()
        let replacementAuthorization = PeerAuthorizationState(PeerAuthorization(
            peerID: "host", sessionID: "new", expiresAt: .distantFuture))
        source.install(WebRTCHubTransport(forwarder: replacement, authorization: replacementAuthorization,
                                          hubBaseURL: base))
        oldForwarder.finishAll()

        do {
            _ = try await oldRead.value
            XCTFail("An old-generation read must not publish after replacement")
        } catch {
            XCTAssertTrue(error is LinkedDevicesUnavailable)
        }
        do {
            _ = try await oldMutation.value
            XCTFail("An uncertain mutation must not publish or replay after replacement")
        } catch {
            XCTAssertTrue(error is LinkedDevicesUnavailable)
        }
        XCTAssertEqual(oldForwarder.dispatchCount, 2)
        XCTAssertEqual(oldForwarder.methods.sorted(), ["GET", "POST"])
        XCTAssertTrue(replacement.paths.isEmpty, "replacement transport must not replay old work")

        let (data, response) = try await source.execute(URLRequest(url: readURL), onUnauthorized: nil)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(data, Data("{\"ok\":true}".utf8))
        XCTAssertEqual(replacement.paths, ["/v1/sessions"], "a new read should dispatch once on the live generation")
        XCTAssertEqual(oldForwarder.dispatchCount, 2)
    }

    func testStaleUnauthorizedGETCannotRevokeReplacementGeneration() async throws {
        let source = LinkedDevicesSourceTransport()
        let url = try XCTUnwrap(URL(string: "http://localhost:43217/v1/sessions"))
        let forwarder = DelayedLinkedDevicesForwarder(status: 401)
        let oldAuthorization = PeerAuthorizationState(PeerAuthorization(peerID: "host", sessionID: "old",
                                                                         expiresAt: .distantFuture))
        source.install(WebRTCHubTransport(forwarder: forwarder, authorization: oldAuthorization,
                                          hubBaseURL: URL(string: "http://localhost:43217/")!))
        let callback = RuntimeLockedFlag()
        let task = Task {
            try await source.execute(URLRequest(url: url), onUnauthorized: { callback.set() })
        }
        for _ in 0..<100 where !forwarder.started { try await Task.sleep(nanoseconds: 2_000_000) }
        let replacementAuthorization = PeerAuthorizationState(PeerAuthorization(
            peerID: "host", sessionID: "new", expiresAt: .distantFuture))
        source.install(WebRTCHubTransport(forwarder: LinkedDevicesForwarder(),
                                          authorization: replacementAuthorization,
                                          hubBaseURL: URL(string: "http://localhost:43217/")!))
        forwarder.finish()

        await XCTAssertThrowsErrorAsync(try await task.value)
        XCTAssertFalse(callback.value, "an old generation must not purge the replacement workspace")
        XCTAssertTrue(replacementAuthorization.check())
    }

    @MainActor
    func testStaleUnauthorizedGETCannotPurgeProductionDirectWorkspace() async throws {
        let id = UUID()
        let hostKey = LinkedDevicesBase64URL.encode(Data(repeating: 0x44, count: 32))
        let baseURL = try XCTUnwrap(URL(string: "http://localhost:43224/chat/"))
        let connection = HubConnection(id: id, name: "Desk", kind: .directNode, url: baseURL,
                                       needsKindReview: nil, linkedDevicesHostKey: hostKey)
        let sourceTransport = LinkedDevicesSourceTransport()
        let forwarder = ProductionStaleAuthorizationForwarder()
        let oldAuthorization = PeerAuthorizationState(PeerAuthorization(
            peerID: hostKey, sessionID: "old", expiresAt: .distantFuture, scopePrefix: "/chat"))
        sourceTransport.install(WebRTCHubTransport(forwarder: forwarder, authorization: oldAuthorization,
                                                    hubBaseURL: baseURL))
        let workspace = HubSourceWorkspace(connection: connection, bearerStorage: HubMemoryBearerStorage(),
                                           dataStore: .nonPersistent(), transport: sourceTransport)
        defer { workspace.dispose(removeCredentials: true) }
        let browserIdentity = workspace.browserIdentity
        let workspaceEpoch = workspace.authEpoch
        let storeEpoch = workspace.store.authEpoch
        let refresh = Task { @MainActor in await workspace.store.refresh() }
        for _ in 0..<100 where !forwarder.started { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertTrue(forwarder.started)

        let replacementAuthorization = PeerAuthorizationState(PeerAuthorization(
            peerID: hostKey, sessionID: "new", expiresAt: .distantFuture, scopePrefix: "/chat"))
        sourceTransport.install(WebRTCHubTransport(forwarder: LinkedDevicesForwarder(),
                                                    authorization: replacementAuthorization,
                                                    hubBaseURL: baseURL))
        forwarder.finishUnauthorized()
        await refresh.value
        for _ in 0..<10 { await Task.yield() }

        XCTAssertFalse(workspace.store.unauthorized)
        XCTAssertFalse(workspace.browserRevoked)
        XCTAssertEqual(workspace.authEpoch, workspaceEpoch)
        XCTAssertEqual(workspace.store.authEpoch, storeEpoch)
        XCTAssertEqual(workspace.browserIdentity, browserIdentity)
        XCTAssertTrue(replacementAuthorization.check())
    }

    func testSourceTransportNeverRetriesAcrossConnections() async throws {
        let source = LinkedDevicesSourceTransport()
        let url = try XCTUnwrap(URL(string: "http://localhost:43213/v1/sessions"))
        let request = URLRequest(url: url)
        await XCTAssertThrowsErrorAsync(try await source.execute(request, onUnauthorized: nil))

        let forwarder = LinkedDevicesForwarder()
        let authorization = PeerAuthorizationState(PeerAuthorization(peerID: "host", sessionID: "session", expiresAt: .distantFuture))
        source.install(WebRTCHubTransport(forwarder: forwarder, authorization: authorization,
                                          hubBaseURL: URL(string: "http://localhost:43213/")!))
        let (data, response) = try await source.execute(request, onUnauthorized: nil)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(data, Data("{\"ok\":true}".utf8))
        XCTAssertEqual(forwarder.paths, ["/v1/sessions"])
        source.disconnect()
        await XCTAssertThrowsErrorAsync(try await source.execute(request, onUnauthorized: nil))
        XCTAssertEqual(forwarder.paths, ["/v1/sessions"], "offline execution must not replay on an old transport")
    }
}


private func XCTAssertPeerSendersDrained(_ multiplexer: PeerHTTPMultiplexer,
                                         file: StaticString = #filePath, line: UInt = #line) async {
    for _ in 0..<1_000 where multiplexer.activeSenderCount != 0 { await Task.yield() }
    XCTAssertEqual(multiplexer.activeSenderCount, 0, "request sender slot did not drain", file: file, line: line)
    XCTAssertEqual(multiplexer.parkedSenderCount, 0, "parked sender slot did not drain", file: file, line: line)
}

private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T,
                                          file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}
