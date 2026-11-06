import AppKit
import SwiftUI
import TermLLMMacKit
import WebKit

/// Embedded chat: the server's own web UI, retained in a WKWebView. The bearer
/// credential is injected as a document-start user script only for this owned
/// loopback page; it never appears in the URL, and navigation away from the
/// owned origin is refused (links open in the user's browser instead).
struct ChatWebView: NSViewRepresentable {
    let endpoint: ManagedLoopbackEndpoint
    let token: String
    @Binding var loadError: String?

    func makeCoordinator() -> Coordinator {
        Coordinator(endpoint: endpoint, loadError: $loadError)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let controller = WKUserContentController()
        let script = """
        (function () {
          try { localStorage.setItem('term_llm_token', \(Self.jsLiteral(token))); } catch (error) {}
        })();
        """
        controller.addUserScript(WKUserScript(source: script,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true))
        configuration.userContentController = controller
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.webView = webView
        ChatReloadBus.shared.register { [weak webView] in webView?.reload() }
        context.coordinator.load(endpoint.chatURL, in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.loadError = $loadError
        context.coordinator.load(endpoint.chatURL, in: webView)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
    }

    private static func jsLiteral(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let array = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(array.dropFirst().dropLast())
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let endpoint: ManagedLoopbackEndpoint
        var loadError: Binding<String?>
        weak var webView: WKWebView?
        private var loadedURL: URL?

        init(endpoint: ManagedLoopbackEndpoint, loadError: Binding<String?>) {
            self.endpoint = endpoint
            self.loadError = loadError
        }

        func load(_ url: URL, in webView: WKWebView) {
            guard loadedURL != url else { return }
            loadedURL = url
            webView.load(URLRequest(url: url))
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if endpoint.allows(url) {
                decisionHandler(.allow)
                return
            }
            // The embedded browser may only show the owned loopback UI. A link
            // to documentation or an external origin goes to the real browser.
            if let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url { NSWorkspace.shared.open(url) }
            return nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            report(nil)
        }

        func webView(_ webView: WKWebView,
                     didFail navigation: WKNavigation!,
                     withError error: Error) {
            report(error)
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            report(error)
        }

        private func report(_ error: Error?) {
            guard let error = error as NSError? else {
                DispatchQueue.main.async { self.loadError.wrappedValue = nil }
                return
            }
            if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled { return }
            DispatchQueue.main.async {
                self.loadError.wrappedValue = "Local chat could not load: \(error.localizedDescription)"
            }
        }
    }
}
