import Network
import WebKit
import XCTest
@testable import TermLLM

@MainActor
final class LiveHangUpTests: XCTestCase {
    private func makeWebView() async throws -> WKWebView {
        let server = try LoopbackServer()
        addTeardownBlock { server.stop() }
        let url = try await server.start()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(WKUserScript(
            source: LiveHangUp.userScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: configuration)
        let waiter = HangUpNavigationWaiter()
        view.navigationDelegate = waiter
        view.load(URLRequest(url: url))
        try await waiter.wait()
        return view
    }

    private func js(_ view: WKWebView, _ body: String) async throws -> Any? {
        try await view.callAsyncJavaScript(body, contentWorld: .page)
    }

    private func clicks(_ view: WKWebView) async throws -> Int? {
        try await js(view, "return window.clicks") as? Int
    }

    func testStopsAnActiveCallAndIgnoresAPageWithoutOne() async throws {
        let view = try await makeWebView()
        let result = try await js(view, "return window.__termLLMLiveHangUp.request(false)") as? String
        XCTAssertEqual(result, "stopped")
        let clicked = try await clicks(view)
        XCTAssertEqual(clicked, 1)

        _ = try await js(view, "document.querySelector('section').remove()")
        let idle = try await js(view, "return window.__termLLMLiveHangUp.request(false)") as? String
        XCTAssertEqual(idle, "idle")
        let composer = try await js(view, """
            document.body.insertAdjacentHTML('beforeend', '<button aria-label="Stop live voice">■</button>');
            document.querySelector('[aria-label="Stop live voice"]').onclick = () => window.clicks++;
            return window.__termLLMLiveHangUp.request(false);
            """) as? String
        XCTAssertEqual(composer, "stopped", "falls back to the composer's live button")
        let total = try await clicks(view)
        XCTAssertEqual(total, 2)
    }

    func testDeferredHangUpWaitsForTheToolResultUpload() async throws {
        let view = try await makeWebView()
        let pending = try await js(view, "return window.__termLLMLiveHangUp.request(true)") as? String
        XCTAssertEqual(pending, "pending")
        _ = try await js(view, "await fetch('/v1/live/sessions/live-1/events', { method: 'POST' })")
        try await Task.sleep(for: .milliseconds(300))
        let early = try await clicks(view)
        XCTAssertEqual(early, 0, "unrelated requests must not end the call")

        _ = try await js(view, "await fetch('/v1/live/sessions/live-1/tool_calls/req-1/result', { method: 'POST' })")
        for _ in 0..<50 {
            if try await clicks(view) == 1 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let clicked = try await clicks(view)
        XCTAssertEqual(clicked, 1)
        let flushed = try await js(view, "return window.__termLLMLiveHangUp.flush()") as? String
        XCTAssertEqual(flushed, "idle", "already stopped")
    }

    func testFlushEndsACallWhoseResultNeverArrived() async throws {
        let view = try await makeWebView()
        let idle = try await js(view, "return window.__termLLMLiveHangUp.flush()") as? String
        XCTAssertEqual(idle, "idle", "nothing pending")
        let none = try await clicks(view)
        XCTAssertEqual(none, 0)
        _ = try await js(view, "return window.__termLLMLiveHangUp.request(true)")
        let flushed = try await js(view, "return window.__termLLMLiveHangUp.flush()") as? String
        XCTAssertEqual(flushed, "stopped")
        let clicked = try await clicks(view)
        XCTAssertEqual(clicked, 1)
    }

    func testStartingMusicOrAPodcastAnnouncesPlayback() async throws {
        let center = NotificationCenter()
        var posts = 0
        let token = center.addObserver(forName: .appWillStartPlayback, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { posts += 1 }
        }
        defer { center.removeObserver(token) }
        let engine = FakeListenEngine()
        let music = MusicPlayer(engine: FakeEngine(), defaults: isolatedDefaults())
        let listen = makeListen(engine: engine)
        Listen.connectToMusic(music, listen: listen, notificationCenter: center)
        try await music.play([track("1")])
        XCTAssertEqual(posts, 1)
        let items = try await listen.add([draft("a")], placement: .end, download: .never)
        try await listen.player.play(items[0].id)
        XCTAssertEqual(posts, 2)
    }
}

/// In-process loopback HTTP server: serves the page and answers every other
/// request with an empty 200. Real HTTP, because WebKit records resource
/// timing (which the hang-up script watches) only for network loads.
private final class LoopbackServer: @unchecked Sendable {
    static let page = """
    <!doctype html><html><body>
    <section aria-label="Live voice" class="live-status live-status-listening">
      <button type="button" class="btn live-status-stop">Stop</button>
    </section>
    <script>
    window.clicks = 0;
    document.querySelector('.live-status-stop').onclick = () => window.clicks++;
    </script>
    </body></html>
    """

    private let listener: NWListener
    private let queue = DispatchQueue(label: "LiveHangUpTests.LoopbackServer")

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    /// Returns the page's URL once listening.
    func start() async throws -> URL {
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let resumed = HubTestBox(false)
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    guard !resumed.value else { return }
                    resumed.set(true)
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    guard !resumed.value else { return }
                    resumed.set(true)
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [queue] connection in
                connection.start(queue: queue)
                Self.receive(connection, accumulated: Data())
            }
            listener.start(queue: queue)
        }
        return URL(string: "http://localhost:\(port)/ui/")!
    }

    func stop() { listener.cancel() }

    private static func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, complete, error in
            var bytes = accumulated
            if let data { bytes.append(data) }
            guard let end = bytes.range(of: Data("\r\n\r\n".utf8)) else {
                if error == nil, !complete { receive(connection, accumulated: bytes) } else { connection.cancel() }
                return
            }
            let line = String(decoding: bytes[..<end.lowerBound], as: UTF8.self).split(separator: " ")
            let isPage = line.count > 1 && line[1].hasPrefix("/ui")
            let body = Data((isPage ? page : "{}").utf8)
            let head = "HTTP/1.1 200 OK\r\nContent-Type: \(isPage ? "text/html" : "application/json")\r\n" +
                "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

private final class HangUpNavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    func wait() async throws {
        if let result { return try result.get() }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        if let continuation {
            self.continuation = nil
            continuation.resume(with: result)
        } else {
            self.result = result
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(.success(())) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }
}
