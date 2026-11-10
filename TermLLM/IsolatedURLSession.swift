import Foundation

/// Native HTTP never borrows ambient authentication or cached responses. Start
/// fresh on every call; customize transport settings, not credential ownership.
enum IsolatedURLSession {
    static func configuration(
        _ customize: (URLSessionConfiguration) -> Void = { _ in }
    ) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        customize(configuration)
        // Apply the boundary last so caller timeouts/protocolClasses survive,
        // but customization cannot accidentally reintroduce shared stores.
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }
}

/// Stateless reject-all backstop. Media and credential-aware transfer delegates
/// retain their own specialized redirect policies.
final class RejectAllRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
