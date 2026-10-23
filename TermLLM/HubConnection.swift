import Foundation
import WebKit

/// Simulator-only protocol fixture. Never borrows production cookies or settings.
enum HubFixture {
    static var server: URL? {
        #if DEBUG && targetEnvironment(simulator)
        guard ProcessInfo.processInfo.environment["TERMLLM_NATIVE_HUB_FIXTURE_URL"] == "http://localhost:8766/" else { return nil }
        return URL(string: "http://localhost:8766/")
        #else
        return nil
        #endif
    }

    static var isEnabled: Bool { server != nil }
    static let defaults: UserDefaults = {
        if PhoneHubFixture.isEnabled { return PhoneHubFixture.defaults }
        guard isEnabled else { return .standard }
        let name = "com.termllm.app.native-hub-fixture"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }()
    @MainActor static let websiteDataStore = WKWebsiteDataStore.nonPersistent()
}

/// Untrusted pairing links contain a server address, never a bearer token. Import
/// only fills a confirmation form; it never signs in or changes the current server.
enum HubConnectionImport {
    static func server(from link: URL) -> URL? {
        guard link.scheme?.lowercased() == "termllm", link.host == "connect",
              link.path.isEmpty || link.path == "/", link.fragment == nil,
              link.user == nil, link.password == nil, link.port == nil,
              let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems,
              items.count == 1, items[0].name == "server", let value = items[0].value,
              let server = ServerAddress.parse(value), server.scheme == "https",
              let host = server.host?.lowercased(), host != "localhost",
              !host.hasSuffix(".localhost"), host != "127.0.0.1", host != "::1" else { return nil }
        return server
    }
}

struct HubBrowserDestination: Equatable {
    let id = UUID()
    let url: URL
    var sourceID: UUID? = nil
}

/// Public, bounded role discovery never treats a timeout/auth failure as a Hub.
/// A failed probe does not replace or interrupt the existing chat workspace.
enum HubServerRole: Equatable {
    case unknown, direct, hub

    static func classify(status: Int, data: Data) -> HubServerRole {
        guard status == 200, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .unknown }
        guard object["status"] as? String == "ok", object["error"] == nil else { return .unknown }
        if object["role"] as? String == "hub" { return .hub }
        guard object["role"] == nil || object["role"] as? String == "node" else { return .unknown }
        return .direct
    }

    static func discover(server: URL) async -> HubServerRole {
        var components = URLComponents(url: server, resolvingAgainstBaseURL: false)
        let prefix = server.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components?.path = (prefix.isEmpty ? "" : "/" + prefix) + "/healthz"
        guard let url = components?.url else { return .unknown }
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 3
        let session = URLSession(configuration: configuration, delegate: HubRoleRedirectBlocker(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            guard !Task.isCancelled, let http = response as? HTTPURLResponse, http.url == url else { return .unknown }
            return classify(status: http.statusCode, data: data)
        } catch { return .unknown }
    }
}

private final class HubRoleRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
