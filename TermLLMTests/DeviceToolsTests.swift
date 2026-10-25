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
        let ping = BuiltInDeviceTools.ping(now: { Date(timeIntervalSince1970: 0) })
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
        let result = try await BuiltInDeviceTools.deviceInfo { snapshot }.call([:])
        XCTAssertFalse(result.isError)
        let json = try JSONValue.decode(Data(result.text.utf8))
        XCTAssertEqual(json["battery_percent"], 46)
        XCTAssertEqual(json["system"], "iOS 27.0")
        XCTAssertEqual(json["app_state"], "active")
    }

    func testJSONValueRoundTripKeepsIntegers() throws {
        let value = try JSONValue.decode(Data(#"{"a":1,"b":1.5,"c":[true,null,"x"],"d":{}}"#.utf8))
        XCTAssertEqual(value, ["a": 1, "b": .double(1.5), "c": [true, nil, "x"], "d": [:]])
        XCTAssertEqual(String(decoding: value.encoded(), as: UTF8.self), #"{"a":1,"b":1.5,"c":[true,null,"x"],"d":{}}"#)
    }
}
