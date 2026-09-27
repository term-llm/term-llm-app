import Foundation
import WebKit

/// Exposes device tools to the term-llm web UI as WebMCP tools
/// (`document.modelContext.registerTool`). WebKit has no WebMCP yet, so the
/// injected script installs a minimal `document.modelContext` when missing.
/// Tool calls travel page → native through a reply-capable message handler
/// that only answers the configured server's origin in the main frame.
final class WebMCPBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let handlerName = "termllmDeviceTools"

    let serverURL: URL
    let registry: DeviceToolRegistry
    /// Shown by the web UI as where the tools run, e.g. "iPhone".
    let device: String
    /// Weak: the controller retains its message handlers (this bridge).
    private weak var installedController: WKUserContentController?

    init(serverURL: URL, registry: DeviceToolRegistry, device: String) {
        self.serverURL = serverURL
        self.registry = registry
        self.device = device
    }

    var expectedOrigin: String { NativeLogin.origin(for: serverURL) }

    /// Idempotent. The page picks it up on the next navigation or reload.
    func install(into controller: WKUserContentController) {
        guard installedController !== controller else { return }
        controller.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: .page)
        controller.addUserScript(WKUserScript(source: Self.script(origin: expectedOrigin, tools: registry.tools, device: device),
                                              injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        controller.addScriptMessageHandler(self, contentWorld: .page, name: Self.handlerName)
        installedController = controller
    }

    /// Removes the handler and all user scripts (this app injects no others).
    func uninstall() {
        guard let controller = installedController else { return }
        controller.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: .page)
        controller.removeAllUserScripts()
        installedController = nil
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        let origin = message.frameInfo.securityOrigin
        let frameOrigin = Self.originString(scheme: origin.protocol, host: origin.host, port: origin.port)
        let body = message.body
        let isMainFrame = message.frameInfo.isMainFrame
        let registry = registry
        let expected = expectedOrigin
        Task { @MainActor in
            switch await Self.handle(body: body, frameOrigin: frameOrigin, isMainFrame: isMainFrame,
                                     expectedOrigin: expected, registry: registry) {
            case .success(let text): replyHandler(text, nil)
            case .failure(let error): replyHandler(nil, error.message)
            }
        }
    }

    struct BridgeError: Error, Equatable {
        let message: String
    }

    /// Validates the caller and runs the tool. Rejections become JS promise
    /// rejections, which `executeTool` surfaces to the agent as tool errors.
    static func handle(body: Any, frameOrigin: String, isMainFrame: Bool, expectedOrigin: String,
                       registry: DeviceToolRegistry) async -> Result<String, BridgeError> {
        guard isMainFrame, frameOrigin == expectedOrigin else {
            return .failure(BridgeError(message: "Device tools are not available to this page"))
        }
        guard let object = body as? [String: Any], let name = object["name"] as? String else {
            return .failure(BridgeError(message: "Malformed device tool call"))
        }
        guard let tool = registry.tool(named: name) else {
            return .failure(BridgeError(message: "Unknown device tool: \(name)"))
        }
        var arguments: [String: JSONValue] = [:]
        if let raw = object["arguments"] as? String, !raw.isEmpty {
            switch try? JSONValue.decode(Data(raw.utf8)) {
            case .object(let value)?: arguments = value
            case .null?: break
            default: return .failure(BridgeError(message: "Tool arguments must be an object"))
            }
        }
        do {
            let result = try await tool.call(arguments)
            return result.isError ? .failure(BridgeError(message: result.text)) : .success(result.text)
        } catch {
            return .failure(BridgeError(message: error.localizedDescription))
        }
    }

    /// Serializes an origin the way `location.origin` does (default ports omitted).
    static func originString(scheme: String, host: String, port: Int) -> String {
        let scheme = scheme.lowercased()
        let defaultPort = scheme == "https" ? 443 : scheme == "http" ? 80 : 0
        let portSuffix = port == 0 || port == defaultPort ? "" : ":\(port)"
        return "\(scheme)://\(host.lowercased())\(portSuffix)"
    }

    static func toolSpecs(_ tools: [DeviceTool]) -> JSONValue {
        .array(tools.map { tool in
            var spec: [String: JSONValue] = [
                "name": .string(tool.name),
                "description": .string(tool.description),
                "inputSchema": tool.inputSchema,
                "annotations": ["readOnlyHint": .bool(tool.readOnly), "consequentialHint": .bool(tool.consequential)],
            ]
            if let title = tool.title { spec["title"] = .string(title) }
            return .object(spec)
        })
    }

    static func script(origin: String, tools: [DeviceTool], device: String) -> String {
        func literal(_ value: JSONValue) -> String { String(decoding: value.encoded(), as: UTF8.self) }
        let originLiteral = literal(.string(origin))
        let handlerLiteral = literal(.string(handlerName))
        let deviceLiteral = literal(.string(device))
        let toolsLiteral = literal(toolSpecs(tools))
        return """
        (() => {
          'use strict';
          const ORIGIN = \(originLiteral);
          if (location.origin !== ORIGIN) return;
          const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[\(handlerLiteral)];
          if (!handler) return;
          const specs = \(toolsLiteral);

          // Minimal WebMCP (document.modelContext) for WebKit, which has none.
          let context = document.modelContext || navigator.modelContext;
          if (!context) {
            const tools = new Map();
            const events = new EventTarget();
            const changed = () => events.dispatchEvent(new Event('toolchange'));
            context = {
              async registerTool(tool, options = {}) {
                if (!tool || typeof tool.name !== 'string' || !tool.name || typeof tool.execute !== 'function') {
                  throw new TypeError('registerTool requires a name and an execute function');
                }
                if (tools.has(tool.name)) throw new DOMException(`Tool "${tool.name}" is already registered`, 'InvalidStateError');
                const signal = options && options.signal;
                if (signal && signal.aborted) return;
                tools.set(tool.name, tool);
                changed();
                if (signal) signal.addEventListener('abort', () => {
                  if (tools.get(tool.name) === tool) { tools.delete(tool.name); changed(); }
                }, { once: true });
              },
              async getTools() {
                return [...tools.values()]
                  .map((tool) => ({
                    name: tool.name,
                    title: tool.title || '',
                    description: tool.description || '',
                    inputSchema: tool.inputSchema || { type: 'object', properties: {} },
                    annotations: { ...(tool.annotations || {}) },
                    origin: location.origin,
                  }))
                  .sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
              },
              async executeTool(tool, input = {}, options = {}) {
                const name = typeof tool === 'string' ? tool : tool && tool.name;
                const registered = tools.get(name);
                if (!registered) throw new DOMException(`Unknown tool "${name}"`, 'NotFoundError');
                const signal = (options && options.signal) || new AbortController().signal;
                return await registered.execute(input || {}, { signal });
              },
              addEventListener: (...args) => events.addEventListener(...args),
              removeEventListener: (...args) => events.removeEventListener(...args),
              dispatchEvent: (event) => events.dispatchEvent(event),
            };
            Object.defineProperty(document, 'modelContext', { value: context, configurable: true });
          }

          // Tells the web UI where these tools run, for labels and tool descriptions.
          Object.defineProperty(window, '__termLLMDeviceTools', {
            value: Object.freeze({
              version: 1,
              app: 'term-llm iOS',
              device: \(deviceLiteral),
              tools: Object.freeze(specs.map((spec) => spec.name)),
            }),
            configurable: true,
          });

          for (const spec of specs) {
            context.registerTool({
              ...spec,
              execute: (input) => handler.postMessage({ name: spec.name, arguments: JSON.stringify(input ?? {}) }),
            }).catch(() => {});
          }
        })();
        """
    }
}
