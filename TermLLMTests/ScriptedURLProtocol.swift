import Foundation

/// Common synchronous URLProtocol plumbing. Subclasses script a response from
/// the request itself; no process-wide handler or catch-all registry can leak a
/// test's script into another session. Request matching and any URL-keyed logs
/// remain owned by the individual fixture.
class ScriptedURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
    }

    override class func canInit(with request: URLRequest) -> Bool { false }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    class func response(for request: URLRequest) throws -> Response {
        preconditionFailure("Subclasses must script their response")
    }

    override func startLoading() {
        guard let url = request.url else { return }
        do {
            let script = try Self.response(for: request)
            let response = HTTPURLResponse(url: url, statusCode: script.status, httpVersion: nil,
                                           headerFields: script.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: script.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
