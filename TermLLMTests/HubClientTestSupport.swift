import XCTest
@testable import TermLLM

// MARK: - Cookie recorder

/// Thread-safe cookie recorder that replaces UnsafeMutablePointer<[[HTTPCookie]]>
/// for capturing sunk cookies.  The reference is captured by the sink closure,
/// which may outlive the test method frame — unlike a stack pointer.
final class CookieRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _batches: [[HTTPCookie]] = []

    var batches: [[HTTPCookie]] {
        lock.lock()
        defer { lock.unlock() }
        return _batches
    }

    var count: Int { batches.count }

    func append(_ cookies: [HTTPCookie]) {
        lock.lock()
        _batches.append(cookies)
        lock.unlock()
    }
}

// Mutable state shared with Foundation/Network delegate queues in tests.
final class HubTestBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
    func set(_ value: Value) {
        lock.lock()
        stored = value
        lock.unlock()
    }
    func update(_ mutation: (inout Value) -> Void) {
        lock.lock()
        mutation(&stored)
        lock.unlock()
    }
}

actor HubRequestGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

// MARK: - Mock transport

/// Closure-based mock transport that records requests and returns canned responses.
/// No URLProtocol — tests are deterministic and exercise the real HubClient logic.
final class MockTransport: HubTransport, @unchecked Sendable {
    struct RecordedRequest: @unchecked Sendable {
        let url: URL
        let method: String
        let headers: [String: String]
        let body: Data?
    }
    var requests: [RecordedRequest] = []
    var handler: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    init(handler: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)) {
        self.handler = handler
    }

    func execute(
        _ request: URLRequest,
        onUnauthorized: (@Sendable () async -> Void)?
    ) async throws -> (Data, HTTPURLResponse) {
        let headers = request.allHTTPHeaderFields ?? [:]
        requests.append(RecordedRequest(
            url: request.url!, method: request.httpMethod ?? "GET",
            headers: headers, body: request.httpBody
        ))
        let (data, response) = try await handler(request)
        // Replicate real transport's unauthorized callback
        if response.statusCode == 401 || response.statusCode == 403 {
            await onUnauthorized?()
        }
        return (data, response)
    }
}

func jsonResponse(
    _ json: String,
    url: URL = URL(string: "https://hub.example.com/")!,
    status: Int = 200,
    headers: [String: String] = [:]
) -> (Data, HTTPURLResponse) {
    var allHeaders = ["Content-Type": "application/json"]
    for (k, v) in headers { allHeaders[k] = v }
    let http = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: allHeaders)!
    return (Data(json.utf8), http)
}

func htmlResponse(
    _ html: String,
    url: URL = URL(string: "https://hub.example.com/")!,
    status: Int = 200,
    headers: [String: String] = [:]
) -> (Data, HTTPURLResponse) {
    var allHeaders = ["Content-Type": "text/html"]
    for (k, v) in headers { allHeaders[k] = v }
    let http = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: allHeaders)!
    return (Data(html.utf8), http)
}

/// Pins a wire model's JSON keys independently of its Swift property names.
/// `json` must name every stored property with a non-null value; decoding and
/// re-encoding must then reproduce it exactly, so a property that loses its
/// wire key fails in at least one direction.
func assertWireKeysRoundTrip<T: Codable>(_ type: T.Type, _ json: String,
                                         file: StaticString = #filePath, line: UInt = #line) throws {
    let data = Data(json.utf8)
    let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary, file: file, line: line)
    XCTAssertFalse(expected.allValues.contains { $0 is NSNull }, "\(T.self) fixture has a null value", file: file, line: line)
    let value = try JSONDecoder().decode(T.self, from: data)
    XCTAssertEqual(Mirror(reflecting: value).children.count, expected.count,
                   "\(T.self) fixture must name every stored property", file: file, line: line)
    let encoded = try JSONEncoder().encode(value)
    let actual = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? NSDictionary, file: file, line: line)
    XCTAssertEqual(actual, expected, "\(T.self) wire keys changed", file: file, line: line)
}
