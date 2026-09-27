import XCTest
@testable import TermLLM

@MainActor
final class DeviceToolsTests: XCTestCase {
    func testSharingIsOptInPerServerAndPersisted() {
        let defaults = UserDefaults(suiteName: "DeviceToolsTests-\(UUID().uuidString)")!
        let hub = URL(string: "https://jarvis.example/ui/")!
        let devBox = URL(string: "https://devbox.example/")!
        let settings = DeviceToolsSettings(defaults: defaults)
        XCTAssertFalse(settings.isEnabled(for: hub), "off by default")

        settings.setEnabled(true, for: hub)
        XCTAssertTrue(settings.isEnabled(for: hub))
        XCTAssertFalse(settings.isEnabled(for: devBox))
        XCTAssertFalse(settings.isEnabled(for: URL(string: "https://jarvis.example/other/")!), "base path matters")

        let reloaded = DeviceToolsSettings(defaults: defaults)
        XCTAssertTrue(reloaded.isEnabled(for: hub))
        reloaded.setEnabled(false, for: hub)
        XCTAssertFalse(DeviceToolsSettings(defaults: defaults).isEnabled(for: hub))
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
