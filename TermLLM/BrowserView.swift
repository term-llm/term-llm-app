import SwiftUI
import WebKit

struct BrowserView: UIViewRepresentable {
    let url: URL
    @Binding var loading: Bool
    @Binding var canGoBack: Bool
    @Binding var loadError: String?
    let reloadCount: Int
    let backCount: Int
    let authenticatedCount: Int
    let onLoginRequired: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        context.coordinator.backObservation = view.observe(\.canGoBack, options: [.new]) { [weak coordinator = context.coordinator] webView, _ in
            coordinator?.parent.canGoBack = webView.canGoBack
        }
        view.allowsBackForwardNavigationGestures = true
        view.scrollView.contentInsetAdjustmentBehavior = .never
        context.coordinator.loadedURL = url
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if coordinator.loadedURL != url {
            coordinator.loadedURL = url
            view.load(URLRequest(url: url))
        } else if coordinator.reloadCount != reloadCount {
            coordinator.reloadCount = reloadCount
            if view.url == nil { view.load(URLRequest(url: url)) } else { view.reload() }
        }
        if coordinator.authenticatedCount != authenticatedCount {
            coordinator.authenticatedCount = authenticatedCount
            view.load(URLRequest(url: url))
        }
        if coordinator.backCount != backCount {
            coordinator.backCount = backCount
            if view.canGoBack { view.goBack() }
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: BrowserView
        var loadedURL: URL?
        var reloadCount = 0
        var backCount = 0
        var authenticatedCount = 0
        var backObservation: NSKeyValueObservation?

        init(_ parent: BrowserView) { self.parent = parent }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.loading = true
            parent.loadError = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.loading = false
            parent.loadError = nil
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            fail(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            fail(error)
        }

        private func fail(_ error: Error) {
            parent.loading = false
            if (error as NSError).code != NSURLErrorCancelled {
                parent.loadError = error.localizedDescription
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let destination = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if isLoginRoute(destination) {
                decisionHandler(.cancel)
                parent.onLoginRequired()
                return
            }
            if ["http", "https"].contains(destination.scheme?.lowercased() ?? ""),
               destination.host == parent.url.host,
               destination.port == parent.url.port,
               destination.scheme == parent.url.scheme {
                decisionHandler(.allow)
            } else {
                UIApplication.shared.open(destination)
                decisionHandler(.cancel)
            }
        }

        // Sites that open auth links with target=_blank still need a destination.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url {
                if isLoginRoute(url) {
                    parent.onLoginRequired()
                } else if url.scheme == parent.url.scheme, url.host == parent.url.host, url.port == parent.url.port {
                    webView.load(navigationAction.request)
                } else {
                    UIApplication.shared.open(url)
                }
            }
            return nil
        }

        private func isLoginRoute(_ destination: URL) -> Bool {
            let prefix = parent.url.path.hasSuffix("/") ? String(parent.url.path.dropLast()) : parent.url.path
            return destination.scheme == parent.url.scheme && destination.host == parent.url.host &&
                destination.port == parent.url.port &&
                ["/auth/login", "/auth/setup", "/auth/recover"].contains { destination.path == prefix + $0 }
        }
    }
}
