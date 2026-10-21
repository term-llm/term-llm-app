import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit
import WebKit

/// Authenticates in the system browser, then imports only the newly issued
/// same-origin session cookie into WebKit. Passkey material never reaches the app.
@MainActor
final class NativeLogin: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private let callbackScheme = "termllm-auth"

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) ?? UIWindow()
    }

    func signIn(to server: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        guard session == nil else { return }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            completion(.failure(LoginError.invalidResponse))
            return
        }
        let verifier = Data(bytes).base64URLEncodedString()
        let state = Self.challenge(for: verifier)
        let start = endpoint(server, "auth/native/\(state)")
        let session = ASWebAuthenticationSession(url: start, callbackURLScheme: callbackScheme) { [weak self] callback, error in
            Task { @MainActor in
                guard let self else { return }
                self.session = nil
                if let error {
                    completion(.failure(error))
                    return
                }
                guard let callback, callback.scheme == self.callbackScheme,
                      callback.host == "callback", callback.path.isEmpty,
                      let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems,
                      items.count == 2,
                      items.first(where: { $0.name == "state" })?.value == state,
                      let code = items.first(where: { $0.name == "code" })?.value,
                      Data(base64URLEncoded: code)?.count == 32 else {
                    completion(.failure(LoginError.invalidResponse))
                    return
                }
                do {
                    try await self.redeem(code, verifier: verifier, server: server)
                    completion(.success(()))
                } catch {
                    completion(.failure(error))
                }
            }
        }
        self.session = session
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        if !session.start() {
            self.session = nil
            completion(.failure(LoginError.unavailable))
        }
    }

    nonisolated static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }

    nonisolated static func origin(for server: URL) -> String {
        let defaultPort = server.scheme == "http" ? 80 : 443
        let port = server.port == defaultPort ? "" : server.port.map { ":\($0)" } ?? ""
        return "\(server.scheme!)://\(server.host!)\(port)"
    }

    private func endpoint(_ server: URL, _ suffix: String) -> URL {
        var components = URLComponents(url: server, resolvingAgainstBaseURL: false)!
        let prefix = server.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + (prefix.isEmpty ? "" : prefix + "/") + suffix
        return components.url!
    }

    private func redeem(_ code: String, verifier: String, server: URL) async throws {
        let url = endpoint(server, "api/auth/native/redeem")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.origin(for: server), forHTTPHeaderField: "Origin")
        request.httpBody = try JSONEncoder().encode(["code": code, "code_verifier": verifier])
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        let (data, response) = try await URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil).data(for: request)
        guard let http = response as? HTTPURLResponse, http.url == url, http.statusCode == 200,
              let body = try? JSONDecoder().decode(Redemption.self, from: data), body.ok else {
            throw LoginError.redemptionFailed
        }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { output, item in
            if let key = item.key as? String, let value = item.value as? String { output[key] = value }
        }
        guard let cookie = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url).first(where: {
            ["term_llm_web_session", "term_llm_hub_session"].contains($0.name) &&
                $0.domain == server.host && $0.isHTTPOnly &&
                ($0.isSecure || (server.scheme == "http" && ServerAddress.allowsLocalHTTP(host: server.host!)))
        }) else {
            throw LoginError.invalidResponse
        }
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.setCookie(cookie) {
                continuation.resume()
            }
        }
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private struct Redemption: Decodable { let ok: Bool }

private enum LoginError: LocalizedError {
    case unavailable, invalidResponse, redemptionFailed

    var errorDescription: String? {
        switch self {
        case .unavailable: "Couldn't open the system sign-in window."
        case .invalidResponse: "The server returned an invalid native login response. Update term-llm and retry."
        case .redemptionFailed: "The sign-in code expired or couldn't be redeemed. Retry sign-in."
        }
    }
}
