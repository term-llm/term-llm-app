import Foundation
import WebKit

/// Exposes native push to the term-llm web UI as `window.__termLLMNativePush`.
/// WKWebView has no service workers or Push API, so the web UI's notification
/// controller uses this object instead (term-llm frontend/src/platform/notifications.ts).
///
/// Every method takes the controller's `scope` (its `config.prefix`): a hub
/// serves several nodes from one origin and each enrolls separately. The page
/// still registers the returned subscription with its own node, so completion
/// pushes keep working exactly as in a browser.
///
/// Only the configured server's origin in the main frame is answered.
final class NativePushBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let handlerName = "termllmPush"
    static let changeEvent = "termllm-native-push-change"

    let serverURL: URL
    let center: PushCenter
    private(set) var userScript: WKUserScript
    /// Weak: the controller retains its message handlers (this bridge).
    private weak var installedController: WKUserContentController?
    private(set) var documentGeneration: UInt64 = 0
    private var boundWindowID: String?

    @MainActor
    func documentCommitted(windowID: String? = nil) {
        documentGeneration &+= 1
        if let owner = windowID ?? boundWindowID { center.windows.invalidate(windowID: owner) }
    }

    @MainActor
    init(serverURL: URL, center: PushCenter) {
        self.serverURL = serverURL
        self.center = center
        userScript = WKUserScript(source: Self.script(origin: NativeLogin.origin(for: serverURL)),
                                  injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)
    }

    var expectedOrigin: String { NativeLogin.origin(for: serverURL) }

    /// Idempotent. Applies to documents loaded after installation.
    func install(into controller: WKUserContentController) {
        guard installedController !== controller else { return }
        controller.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: .page)
        controller.addUserScript(userScript)
        controller.addScriptMessageHandler(self, contentWorld: .page, name: Self.handlerName)
        installedController = controller
    }

    func uninstall() {
        guard let controller = installedController else { return }
        controller.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: .page)
        controller.removeUserScript(userScript)
        installedController = nil
    }

    /// Asks the page to re-read permission and enrollment.
    static let changeScript = "window.dispatchEvent(new Event(\(String(decoding: JSONValue.string(changeEvent).encoded(), as: UTF8.self))))"

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        let origin = message.frameInfo.securityOrigin
        let frameOrigin = WebMCPBridge.originString(scheme: origin.protocol, host: origin.host, port: origin.port)
        let body = message.body
        let isMainFrame = message.frameInfo.isMainFrame
        let expected = expectedOrigin
        let center = center
        weak var webView = message.webView
        Task { @MainActor in
            let generation = self.documentGeneration
            let object = body as? [String: Any]
            let method = object?["method"] as? String ?? ""
            let documentID = object?["document_id"] as? String
            var currentDocument = false
            if isMainFrame, frameOrigin == expected, let webView, let documentID {
                // Check the LIVE document, not merely its URL. A queued message
                // from a navigated-away document cannot rebind the owner scene.
                let live = try? await webView.evaluateJavaScript("window.__termLLMNativePushDocumentID")
                currentDocument = live as? String == documentID && generation == self.documentGeneration
            }
            if method.hasPrefix("notification"), !currentDocument {
                replyHandler(nil, "Stale notification document")
                return
            }
            let owner: String?
            if let scene = webView?.window?.windowScene {
                let id = PushCenter.windowID(for: scene)
                center.registerWindow(id, scene: scene)
                self.boundWindowID = id
                owner = id
            } else { owner = nil }
            switch await Self.handle(body: body, frameOrigin: frameOrigin, isMainFrame: isMainFrame,
                                     expectedOrigin: expected, center: center, windowID: owner,
                                     documentID: currentDocument ? documentID : nil, documentURL: webView?.url) {
            case .success(let value): replyHandler(value, nil)
            case .failure(let error): replyHandler(nil, error.message)
            }
        }
    }

    struct BridgeError: Error, Equatable {
        let message: String
    }

    static func validScope(_ scope: String) -> Bool { PushMetadata.validScope(scope) }

    static func scope(_ scope: String, contains url: URL) -> Bool {
        let path = url.path
        let decoded = scope.removingPercentEncoding ?? scope
        let root = decoded.hasSuffix("/") ? String(decoded.dropLast()) : decoded
        return root.isEmpty || path == root || path.hasPrefix(root + "/")
    }

    @MainActor
    static func handle(body: Any, frameOrigin: String, isMainFrame: Bool, expectedOrigin: String,
                       center: PushCenter, windowID: String? = nil, documentID: String? = nil,
                       documentURL: URL? = nil) async -> Result<Any, BridgeError> {
        guard isMainFrame, frameOrigin == expectedOrigin else {
            return .failure(BridgeError(message: "Notifications are not available to this page"))
        }
        guard let object = body as? [String: Any], let method = object["method"] as? String,
              let scope = object["scope"] as? String, validScope(scope) else {
            return .failure(BridgeError(message: "Malformed notification request"))
        }
        if let documentURL, method != "notificationCapabilities",
           !center.scopeMatchesDocument(origin: frameOrigin, scope: scope, url: documentURL) {
            return .failure(BridgeError(message: "Notification scope does not match this page"))
        }
        let nodeBasePath = (object["nodeBasePath"] as? String).flatMap { Self.validScope($0) ? $0 : nil }
        if method.hasPrefix("notification") {
            return await handleNotification(method: method, object: object, scope: scope, origin: frameOrigin,
                                            windowID: windowID, documentID: documentID, center: center)
        }
        switch method {
        case "permission":
            await center.refreshAuthorization()
            return .success(center.permission(origin: frameOrigin, scope: scope).rawValue)
        case "requestPermission":
            return .success(await center.requestPermission(origin: frameOrigin, scope: scope).rawValue)
        case "getSubscription":
            return .success(center.subscription(origin: frameOrigin, scope: scope, label: object["label"] as? String, nodeBasePath: nodeBasePath)?.bridgeValue ?? NSNull())
        case "subscribe":
            guard let key = object["applicationServerKey"] as? String else {
                return .failure(BridgeError(message: "Malformed notification request"))
            }
            do {
                return .success(try await center.subscribe(origin: frameOrigin, scope: scope, applicationServerKey: key,
                                                           label: object["label"] as? String, nodeBasePath: nodeBasePath).bridgeValue)
            } catch {
                return .failure(BridgeError(message: error.localizedDescription))
            }
        case "unsubscribe":
            guard center.unsubscribe(origin: frameOrigin, scope: scope) else {
                return .failure(BridgeError(message: "Notification cleanup could not be persisted; retry is required"))
            }
            return .success(true)
        case "disable":
            guard center.disable(origin: frameOrigin, scope: scope) else {
                return .failure(BridgeError(message: "Notification off/cleanup could not be fully persisted; retry is required"))
            }
            return .success(true)
        default:
            return .failure(BridgeError(message: "Unknown notification request: \(method)"))
        }
    }

    static func script(origin: String) -> String {
        func literal(_ value: String) -> String { String(decoding: JSONValue.string(value).encoded(), as: UTF8.self) }
        return """
        (() => {
          'use strict';
          if (location.origin !== \(literal(origin))) return;
          const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[\(literal(handlerName))];
          if (!handler) return;
          const documentID = crypto.randomUUID();
          Object.defineProperty(window, '__termLLMNativePushDocumentID', { value: documentID });
          const call = (method, scope, extra) => {
            const label = [window.TERM_LLM_UI_TITLE, window.TERM_LLM_HUB?.nodeName, window.TERM_LLM_HUB?.nodeId]
              .find(value => typeof value === 'string' && value.trim()) || null;
            const nodeBasePath = window.TERM_LLM_HUB?.nodeBasePath ?? null;
            return handler.postMessage({ method, scope: String(scope ?? ''), label, nodeBasePath,
              ...(extra || {}), document_id: documentID });
          };
          Object.defineProperty(window, '__termLLMNativePush', {
            value: Object.freeze({
              version: 1,
              permission: (scope) => call('permission', scope),
              requestPermission: (scope) => call('requestPermission', scope),
              getSubscription: (scope) => call('getSubscription', scope),
              subscribe: (scope, applicationServerKey) =>
                call('subscribe', scope, { applicationServerKey: String(applicationServerKey ?? '') }),
              unsubscribe: (scope) => call('unsubscribe', scope),
              disable: (scope) => call('disable', scope),
              notificationCapabilities: () => call('notificationCapabilities', ''),
              notificationPresence: (payload) => call('notificationPresence', payload?.source, { payload }),
              notificationRead: (payload) => call('notificationRead', payload?.source, { payload }),
              notificationEnrollment: (payload) => call('notificationEnrollment', payload?.source, { payload }),
              notificationPendingCleanup: (payload) => call('notificationPendingCleanup', payload?.source, { payload }),
              notificationCleanupAcknowledged: (payload) => call('notificationCleanupAcknowledged', payload?.source, { payload }),
            }),
            configurable: true,
          });
        })();
        """
    }
}

extension WKUserContentController {
    /// WebKit can only remove all user scripts; re-add the others.
    func removeUserScript(_ script: WKUserScript) {
        let kept = userScripts.filter { $0 !== script && $0.source != script.source }
        removeAllUserScripts()
        kept.forEach(addUserScript)
    }
}
