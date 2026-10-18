import Foundation
import UIKit

/// Result of a device tool call. `isError` maps to MCP `isError`, so the agent
/// sees a tool failure rather than a protocol error.
struct DeviceToolResult: Equatable, Sendable {
    var text: String
    var isError = false

    static func error(_ message: String) -> DeviceToolResult {
        DeviceToolResult(text: message, isError: true)
    }
}

struct DeviceToolError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// A capability this device offers the agent (exposed to the web page as a
/// WebMCP tool). Providers (music, reminders, …) contribute tools to a
/// `DeviceToolRegistry`.
struct DeviceTool: Sendable {
    let name: String
    var title: String?
    let description: String
    var inputSchema: JSONValue = ["type": "object", "properties": [:], "additionalProperties": false]
    var readOnly = false
    /// Hard-to-undo actions (e.g. deleting); hosts may ask the user to confirm.
    var consequential = false
    let call: @Sendable (_ arguments: [String: JSONValue]) async throws -> DeviceToolResult
}

final class DeviceToolRegistry: Sendable {
    let tools: [DeviceTool]

    init(tools: [DeviceTool]) {
        precondition(Set(tools.map(\.name)).count == tools.count, "Device tool names must be unique")
        self.tools = tools
    }

    func tool(named name: String) -> DeviceTool? {
        tools.first { $0.name == name }
    }
}

/// Snapshot of device state for `device_info`, captured on the main actor.
struct DeviceInfoSnapshot: Equatable, Sendable {
    var model: String
    var systemName: String
    var systemVersion: String
    var appVersion: String
    var batteryLevel: Float?
    var batteryState: String
    var lowPowerMode: Bool
    var appState: String

    var json: JSONValue {
        var object: [String: JSONValue] = [
            "model": .string(model),
            "system": .string("\(systemName) \(systemVersion)"),
            "app_version": .string(appVersion),
            "battery_state": .string(batteryState),
            "low_power_mode": .bool(lowPowerMode),
            "app_state": .string(appState),
        ]
        if let batteryLevel { object["battery_percent"] = .int(Int((batteryLevel * 100).rounded())) }
        return .object(object)
    }

    @MainActor
    static func current() -> DeviceInfoSnapshot {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let batteryState: String
        switch device.batteryState {
        case .charging: batteryState = "charging"
        case .full: batteryState = "full"
        case .unplugged: batteryState = "unplugged"
        default: batteryState = "unknown"
        }
        let appState: String
        switch UIApplication.shared.applicationState {
        case .active: appState = "active"
        case .inactive: appState = "inactive"
        default: appState = "background"
        }
        return DeviceInfoSnapshot(
            model: device.model,
            systemName: device.systemName,
            systemVersion: device.systemVersion,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            batteryLevel: device.batteryLevel >= 0 ? device.batteryLevel : nil,
            batteryState: batteryState,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            appState: appState
        )
    }
}

enum BuiltInDeviceTools {
    static func ping(now: @escaping @Sendable () -> Date = { Date() }) -> DeviceTool {
        DeviceTool(
            name: "ping",
            title: "Ping iPhone",
            description: "Check that the term-llm iPhone app is reachable. Optionally echoes a message.",
            inputSchema: [
                "type": "object",
                "properties": ["message": ["type": "string", "description": "Optional text to echo back."]],
                "additionalProperties": false,
            ],
            readOnly: true
        ) { arguments in
            if let value = arguments["message"], value.stringValue == nil, value != .null {
                throw DeviceToolError(message: "message must be a string")
            }
            var text = "pong from term-llm iPhone app at \(ISO8601DateFormatter().string(from: now()))"
            if let message = arguments["message"]?.stringValue, !message.isEmpty {
                text += "\necho: \(message)"
            }
            return DeviceToolResult(text: text)
        }
    }

    static func deviceInfo(snapshot: @escaping @Sendable () async -> DeviceInfoSnapshot) -> DeviceTool {
        DeviceTool(
            name: "device_info",
            title: "iPhone status",
            description: "Report this iPhone's model, iOS version, battery level and charging state, Low Power Mode, and whether the term-llm app is in the foreground.",
            readOnly: true
        ) { _ in
            let info = await snapshot()
            return DeviceToolResult(text: String(decoding: info.json.encoded(pretty: true), as: UTF8.self))
        }
    }

    static var standard: [DeviceTool] {
        [ping(), deviceInfo { await MainActor.run { DeviceInfoSnapshot.current() } }]
    }

    static func standardRegistry() -> DeviceToolRegistry {
        DeviceToolRegistry(tools: standard)
    }
}
