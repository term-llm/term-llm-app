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
        Task { @MainActor in
            switch await Self.handle(body: body, frameOrigin: frameOrigin, isMainFrame: isMainFrame,
                                     expectedOrigin: expected, center: center) {
            case .success(let value): replyHandler(value, nil)
            case .failure(let error): replyHandler(nil, error.message)
            }
        }
    }

    struct BridgeError: Error, Equatable {
        let message: String
    }

    static func validScope(_ scope: String) -> Bool {
        scope.count <= 512 && (scope.isEmpty || scope.hasPrefix("/")) && !scope.contains(where: { "?#\\".contains($0) })
            && !scope.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    @MainActor
    static func handle(body: Any, frameOrigin: String, isMainFrame: Bool, expectedOrigin: String,
                       center: PushCenter) async -> Result<Any, BridgeError> {
        guard isMainFrame, frameOrigin == expectedOrigin else {
            return .failure(BridgeError(message: "Notifications are not available to this page"))
        }
        guard let object = body as? [String: Any], let method = object["method"] as? String,
              let scope = object["scope"] as? String, validScope(scope) else {
            return .failure(BridgeError(message: "Malformed notification request"))
        }
        let nodeBasePath = (object["nodeBasePath"] as? String).flatMap { Self.validScope($0) ? $0 : nil }
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
            center.unsubscribe(origin: frameOrigin, scope: scope)
            return .success(true)
        case "disable":
            center.disable(origin: frameOrigin, scope: scope)
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
          const call = (method, scope, extra) => {
            const label = [window.TERM_LLM_UI_TITLE, window.TERM_LLM_HUB?.nodeName, window.TERM_LLM_HUB?.nodeId]
              .find(value => typeof value === 'string' && value.trim()) || null;
            const nodeBasePath = window.TERM_LLM_HUB?.nodeBasePath ?? null;
            return handler.postMessage({ method, scope: String(scope ?? ''), label, nodeBasePath, ...(extra || {}) });
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
