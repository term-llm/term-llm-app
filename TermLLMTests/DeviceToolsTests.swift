import XCTest
@testable import TermLLM

@MainActor
final class DeviceToolsTests: XCTestCase {
    func testSharingIsGlobalOptInAndPersisted() {
        let defaults = UserDefaults(suiteName: "DeviceToolsTests-\(UUID().uuidString)")!
        let settings = DeviceToolsSettings(defaults: defaults)
        XCTAssertFalse(settings.isEnabled, "off by default")
        settings.isEnabled = true
        XCTAssertTrue(DeviceToolsSettings(defaults: defaults).isEnabled)
        settings.isEnabled = false
        XCTAssertFalse(DeviceToolsSettings(defaults: defaults).isEnabled)
    }

    func testLegacyPerServerOptInMigratesToGlobalSwitch() {
        for (servers, expected) in [(["https://jarvis.example/ui/"], true), ([], false)] {
            let defaults = UserDefaults(suiteName: "DeviceToolsTests-\(UUID().uuidString)")!
            defaults.set(servers, forKey: DeviceToolsSettings.legacyServersKey)
            XCTAssertEqual(DeviceToolsSettings(defaults: defaults).isEnabled, expected)
            XCTAssertNil(defaults.object(forKey: DeviceToolsSettings.legacyServersKey))
        }
    }

    func testStandardRegistry() {
        let registry = BuiltInDeviceTools.standardRegistry()
        XCTAssertEqual(registry.tools.map(\.name), ["ping", "device_info"])
        XCTAssertTrue(registry.tools.allSatisfy(\.readOnly))
        XCTAssertNotNil(registry.tool(named: "ping"))
        XCTAssertNil(registry.tool(named: "nope"))
    }

    func testPingEchoesAndValidatesItsArgument() async throws {
        let ping = BuiltInDeviceTools.ping(platform: .iPhone, now: { Date(timeIntervalSince1970: 0) })
        XCTAssertEqual(ping.title, "Ping iPhone")
        XCTAssertEqual(ping.description, "Check that the term-llm iPhone app is reachable. Optionally echoes a message.")
        let echoed = try await ping.call(["message": "hi"])
        XCTAssertEqual(echoed.text, "pong from term-llm iPhone app at 1970-01-01T00:00:00Z\necho: hi")
        do {
            _ = try await ping.call(["message": 3])
            XCTFail("expected a validation error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "message must be a string")
        }
    }

    func testDeviceInfoTool() async throws {
        let snapshot = DeviceInfoSnapshot(model: "iPhone", systemName: "iOS", systemVersion: "27.0", appVersion: "0.1.0",
                                          batteryLevel: 0.456, batteryState: "charging", lowPowerMode: false, appState: "active")
        let tool = BuiltInDeviceTools.deviceInfo(platform: .iPhone) { snapshot }
        XCTAssertEqual(tool.title, "iPhone status")
        XCTAssertEqual(tool.description, "Report this iPhone's model, iOS version, battery level and charging state, Low Power Mode, and whether the term-llm app is in the foreground.")
        let result = try await tool.call([:])
        XCTAssertFalse(result.isError)
        let json = try JSONValue.decode(Data(result.text.utf8))
        XCTAssertEqual(json["battery_percent"], 46)
        XCTAssertEqual(json["system"], "iOS 27.0")
        XCTAssertEqual(json["app_state"], "active")
    }

    func testMacToolsUseMacCopyWithoutChangingSchemasOrSnapshot() async throws {
        let macPing = BuiltInDeviceTools.ping(platform: .mac, now: { Date(timeIntervalSince1970: 0) })
        let phonePing = BuiltInDeviceTools.ping(platform: .iPhone)
        XCTAssertEqual(macPing.title, "Ping Mac")
        XCTAssertEqual(macPing.description, "Check that the term-llm Mac app is reachable. Optionally echoes a message.")
        XCTAssertEqual(macPing.inputSchema, phonePing.inputSchema)
        XCTAssertTrue(macPing.readOnly)
        XCTAssertFalse(macPing.consequential)
        let echoed = try await macPing.call(["message": "hi"])
        XCTAssertEqual(echoed.text, "pong from term-llm Mac app at 1970-01-01T00:00:00Z\necho: hi")
        let empty = try await macPing.call([:])
        XCTAssertEqual(empty.text, "pong from term-llm Mac app at 1970-01-01T00:00:00Z")
        do {
            _ = try await macPing.call(["message": 3])
            XCTFail("expected a validation error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "message must be a string")
        }

        // Do not synthesize macOS hardware/version data from UIKit's snapshot.
        let snapshot = DeviceInfoSnapshot(model: "iPad", systemName: "iPadOS", systemVersion: "27.0", appVersion: "0.1.0",
                                          batteryLevel: nil, batteryState: "unknown", lowPowerMode: false, appState: "active")
        let info = BuiltInDeviceTools.deviceInfo(platform: .mac) { snapshot }
        XCTAssertEqual(info.title, "Mac status")
        XCTAssertEqual(info.description, "Report this Mac's model, system version, battery level and charging state, Low Power Mode, and whether the term-llm app is in the foreground.")
        XCTAssertTrue(info.readOnly)
        XCTAssertFalse(info.consequential)
        let result = try await info.call([:])
        XCTAssertFalse(result.isError)
        XCTAssertEqual(try JSONValue.decode(Data(result.text.utf8)), snapshot.json)
    }

    func testRuntimePlatformDrivesDefaultToolCopy() {
        let expected: DeviceToolPlatform = ProcessInfo.processInfo.isiOSAppOnMac ? .mac : .iPhone
        XCTAssertEqual(DeviceToolPlatform.current, expected)
        XCTAssertEqual(BuiltInDeviceTools.ping().title, "Ping \(expected.name)")
        XCTAssertEqual(BuiltInDeviceTools.standardRegistry().tool(named: "device_info")?.title, "\(expected.name) status")
    }

    func testDeviceToolsSettingsCopyMatchesHostAndPreservesPhoneModel() {
        let mac = DeviceToolsInfoView(platform: .mac, deviceModel: "iPad")
        XCTAssertEqual(mac.statusTitle, "Mac status")
        XCTAssertEqual(mac.statusSummary, "Battery, system version and whether the app is open.")
        XCTAssertEqual(mac.platform.symbol, "desktopcomputer")
        for model in ["iPhone", "iPad"] {
            let phone = DeviceToolsInfoView(platform: .iPhone, deviceModel: model)
            XCTAssertEqual(phone.statusTitle, "\(model) status")
            XCTAssertEqual(phone.statusSummary, "Battery, iOS version and whether the app is open.")
            XCTAssertEqual(phone.platform.symbol, "iphone")
        }
    }

    func testJSONValueRoundTripKeepsIntegers() throws {
        let value = try JSONValue.decode(Data(#"{"a":1,"b":1.5,"c":[true,null,"x"],"d":{}}"#.utf8))
        XCTAssertEqual(value, ["a": 1, "b": .double(1.5), "c": [true, nil, "x"], "d": [:]])
        XCTAssertEqual(String(decoding: value.encoded(), as: UTF8.self), #"{"a":1,"b":1.5,"c":[true,null,"x"],"d":{}}"#)
    }
}
