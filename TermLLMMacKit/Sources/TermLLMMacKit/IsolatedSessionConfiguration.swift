import Foundation

/// Transport-independent isolation for native management requests. Redirect
/// policy belongs to each transport, not to this configuration factory.
enum IsolatedSessionConfiguration {
    /// Defaults to an ephemeral configuration. Always copy injected configurations
    /// before removing ambient state; preserve timeouts and URLProtocol test seams.
    static func make(copying configuration: URLSessionConfiguration = .ephemeral) -> URLSessionConfiguration {
        let isolated = configuration.copy() as! URLSessionConfiguration
        isolated.httpCookieStorage = nil
        isolated.httpShouldSetCookies = false
        isolated.httpCookieAcceptPolicy = .never
        isolated.urlCredentialStorage = nil
        isolated.urlCache = nil
        isolated.requestCachePolicy = .reloadIgnoringLocalCacheData
        return isolated
    }
}

/// Credentialed loopback requests must not follow even a same-origin redirect.
/// GitHub's credential-free HTTPS/CDN transport deliberately uses another delegate.
final class RejectRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
