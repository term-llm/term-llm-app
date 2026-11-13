import XCTest
@testable import TermLLM

@MainActor
final class DeviceToolsTests: XCTestCase {
    func testSharingDefaultsMatchPlatformWithoutPersistingFallback() {
        for platform in [DeviceToolPlatform.mac, .iPhone] {
            let defaults = UserDefaults(suiteName: "DeviceToolsTests-\(UUID().uuidString)")!
            XCTAssertEqual(DeviceToolsSettings(defaults: defaults, platform: platform).isEnabled, platform == .mac)
            XCTAssertNil(defaults.object(forKey: DeviceToolsSettings.enabledKey))
            XCTAssertEqual(DeviceToolsSettings(defaults: defaults, platform: platform).isEnabled, platform == .mac)
            XCTAssertNil(defaults.object(forKey: DeviceToolsSettings.enabledKey))
        }
        let defaults = UserDefaults(suiteName: "DeviceToolsTests-\(UUID().uuidString)")!
        XCTAssertEqual(DeviceToolsSettings(defaults: defaults).isEnabled, DeviceToolPlatform.current == .mac)
        XCTAssertNil(defaults.object(forKey: DeviceToolsSettings.enabledKey))
    }

    func testGlobalSharingPreferencePersistsAcrossReinitialization() {
        for platform in [DeviceToolPlatform.mac, .iPhone] {
            let defaults = UserDefaults(suiteName: "DeviceToolsTests-\(UUID().uuidString)")!
            let settings = DeviceToolsSettings(defaults: defaults, platform: platform)
            for enabled in [false, true] {
                settings.isEnabled = enabled
                XCTAssertEqual(defaults.object(forKey: DeviceToolsSettings.enabledKey) as? Bool, enabled)
                XCTAssertEqual(DeviceToolsSettings(defaults: defaults, platform: platform).isEnabled, enabled)
                // Also exercise the runtime default, including Mac's default-on host.
                XCTAssertEqual(DeviceToolsSettings(defaults: defaults).isEnabled, enabled)
            }
        }
    }

    func testLegacyPerServerOptInMigratesToGlobalSwitch() {
        for platform in [DeviceToolPlatform.mac, .iPhone] {
            for (servers, expected) in [(["https://jarvis.example/ui/"], true), ([], false)] {
                let defaults = UserDefaults(suiteName: "DeviceToolsTests-\(UUID().uuidString)")!
                defaults.set(servers, forKey: DeviceToolsSettings.legacyServersKey)
                XCTAssertEqual(DeviceToolsSettings(defaults: defaults, platform: platform).isEnabled, expected)
                XCTAssertEqual(defaults.object(forKey: DeviceToolsSettings.enabledKey) as? Bool, expected)
                XCTAssertNil(defaults.object(forKey: DeviceToolsSettings.legacyServersKey))
                XCTAssertEqual(DeviceToolsSettings(defaults: defaults).isEnabled, expected)
            }
        }
    }

    func testSavedSharingPreferenceWinsOverLegacyMigrationAndHostDefault() {
        for platform in [DeviceToolPlatform.mac, .iPhone] {
            for enabled in [false, true] {
                for servers in [[], ["https://jarvis.example/ui/"]] {
                    let defaults = UserDefaults(suiteName: "DeviceToolsTests-\(UUID().uuidString)")!
                    defaults.set(enabled, forKey: DeviceToolsSettings.enabledKey)
                    defaults.set(servers, forKey: DeviceToolsSettings.legacyServersKey)
                    XCTAssertEqual(DeviceToolsSettings(defaults: defaults, platform: platform).isEnabled, enabled)
                    XCTAssertEqual(defaults.object(forKey: DeviceToolsSettings.enabledKey) as? Bool, enabled)
                    XCTAssertNil(defaults.object(forKey: DeviceToolsSettings.legacyServersKey))
                    XCTAssertEqual(DeviceToolsSettings(defaults: defaults).isEnabled, enabled)
                }
            }
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
        let expected: DeviceToolPlatform = AppPlatform.isMac ? .mac : .iPhone
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

    func testStandardToolsComposeLazilyInPhoneOrder() {
        func stub(_ name: String) -> DeviceTool {
            DeviceTool(name: name, description: name) { _ in DeviceToolResult(text: "ok") }
        }
        for platform in [DeviceToolPlatform.iPhone, .mac] {
            var invoked: [String] = []
            let tools = DeviceToolsSettings.standardTools(
                platform: platform,
                builtIns: { host in
                    XCTAssertEqual(host, platform)
                    invoked.append("builtIns")
                    return [stub("ping"), stub("device_info")]
                },
                music: { invoked.append("music"); return [stub("music_play")] },
                navigation: { invoked.append("navigation"); return [stub("location_current")] },
                media: { invoked.append("media"); return [stub("media_list")] })
            XCTAssertEqual(platform.offersNavigation, platform == .iPhone)
            XCTAssertEqual(invoked, platform == .iPhone
                           ? ["builtIns", "music", "navigation", "media"] : ["builtIns", "music", "media"])
            XCTAssertEqual(tools.map(\.name), platform == .iPhone
                           ? ["ping", "device_info", "music_play", "location_current", "media_list"]
                           : ["ping", "device_info", "music_play", "media_list"])
        }
    }

    func testStandardToolsDefaultToCurrentHostWithoutTouchingSharedProviders() {
        var navigationCalls = 0
        let tools = DeviceToolsSettings.standardTools(
            music: { [] }, navigation: { navigationCalls += 1; return [] }, media: { [] })
        XCTAssertEqual(tools.map(\.name), ["ping", "device_info"])
        XCTAssertEqual(tools.first?.title, "Ping \(DeviceToolPlatform.current.name)")
        XCTAssertEqual(navigationCalls, DeviceToolPlatform.current.offersNavigation ? 1 : 0)
    }

    func testWhatsSharedGroupsMatchPlatformCapabilities() {
        XCTAssertEqual(DeviceToolsInfoView(platform: .mac).groupTitles,
                       ["Mac status", "Music", "Podcasts & audio"])
        XCTAssertEqual(DeviceToolsInfoView(platform: .iPhone, deviceModel: "iPad").groupTitles,
                       ["iPad status", "Location & directions", "Music", "Podcasts & audio"])
        let current = DeviceToolsInfoView()
        XCTAssertEqual(current.groupTitles.contains("Location & directions"), DeviceToolPlatform.current.offersNavigation)
    }

    func testDiagnosticErrorMetadataKeepsCodesButOmitsPrivateErrorDetails() {
        let secret = "SECRET-token https://private.example/media/song?token=SECRET-token"
        let transport = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet,
                                userInfo: [NSLocalizedDescriptionKey: secret, NSURLErrorFailingURLStringErrorKey: secret])
        let underlying = NSError(domain: "AMSErrorDomain", code: 17,
                                 userInfo: [NSUnderlyingErrorKey: transport, NSLocalizedFailureReasonErrorKey: secret])
        let error = NSError(domain: "MusicKit.MusicError", code: 42,
                            userInfo: [NSUnderlyingErrorKey: underlying, NSLocalizedDescriptionKey: secret,
                                       NSDebugDescriptionErrorKey: secret, "query": secret])
        XCTAssertEqual(DeviceToolDiagnostics.errorMetadata(error),
                       "error_chain=[MusicKit.MusicError:42,AMSErrorDomain:17,NSURLErrorDomain:-1009] chain_truncated=false cancelled=false")
        for domain in [secret, "bad\ndomain", String(repeating: "x", count: 129)] {
            let safe = DeviceToolDiagnostics.errorMetadata(NSError(domain: domain, code: 7))
            XCTAssertEqual(safe, "error_chain=[redacted-domain:7] chain_truncated=false cancelled=false")
            XCTAssertFalse(safe.contains("SECRET"))
        }
    }

    func testDiagnosticErrorMetadataBoundsDepthCyclesAndDetectsCancellation() {
        var error = NSError(domain: "hidden.deep", code: 4)
        for code in (1...3).reversed() {
            error = NSError(domain: "layer\(code)", code: code, userInfo: [NSUnderlyingErrorKey: error])
        }
        XCTAssertEqual(DeviceToolDiagnostics.errorMetadata(error),
                       "error_chain=[layer1:1,layer2:2,layer3:3] chain_truncated=true cancelled=false")
        XCTAssertEqual(DeviceToolDiagnostics.errorMetadata(CyclicDiagnosticError(domain: "cycle", code: 9)),
                       "error_chain=[cycle:9] chain_truncated=true cancelled=false")
        XCTAssertTrue(DeviceToolDiagnostics.errorMetadata(CancellationError()).hasSuffix("cancelled=true"))
        let cancelled = NSError(domain: "MusicKit.MusicError", code: 1,
                                userInfo: [NSUnderlyingErrorKey: URLError(.cancelled)])
        XCTAssertTrue(DeviceToolDiagnostics.errorMetadata(cancelled).hasSuffix("cancelled=true"))
    }

    func testDiagnosticLifecycleUsesNativeInvocationAndMonotonicElapsedTime() async throws {
        let outside = DeviceToolDiagnostics(operation: "fixture")
        XCTAssertNil(outside.callID)
        XCTAssertEqual(outside.event("start", now: outside.started),
                       "operation=fixture stage=start call_id=none elapsed_ms=0")
        let tool = DeviceTool(name: "diagnostic_fixture", description: "Fixture") { _ in
            let diagnostic = DeviceToolDiagnostics(operation: "catalog.fixture")
            let result: JSONValue = [
                "invocation": .string(WebMCPBridge.currentInvocation?.callID.uuidString ?? "none"),
                "span": .string(diagnostic.callID?.uuidString ?? "none"),
                "start": .string(diagnostic.event("start", now: diagnostic.started)),
                "finish": .string(diagnostic.event("failure", now: diagnostic.started.advanced(by: .milliseconds(125)))),
            ]
            return DeviceToolResult(text: String(decoding: result.encoded(), as: UTF8.self))
        }
        let bridge = WebMCPBridge(serverURL: URL(string: "https://fixture.example/")!,
                                  registry: DeviceToolRegistry(tools: [tool]), device: "Mac")
        var reply: String?
        let call = bridge.startCall(body: ["name": tool.name], frameOrigin: bridge.expectedOrigin, isMainFrame: true) { text, error in
            XCTAssertNil(error)
            reply = text as? String
        }
        await call.value
        let result = try JSONValue.decode(Data(try XCTUnwrap(reply).utf8))
        let id = try XCTUnwrap(result["invocation"]?.stringValue)
        XCTAssertNotNil(UUID(uuidString: id))
        XCTAssertEqual(result["span"], .string(id))
        XCTAssertEqual(result["start"], .string("operation=catalog.fixture stage=start call_id=\(id) elapsed_ms=0"))
        XCTAssertEqual(result["finish"], .string("operation=catalog.fixture stage=failure call_id=\(id) elapsed_ms=125"))
        XCTAssertNil(WebMCPBridge.currentInvocation)
    }

    func testJSONValueRoundTripKeepsIntegers() throws {
        let value = try JSONValue.decode(Data(#"{"a":1,"b":1.5,"c":[true,null,"x"],"d":{}}"#.utf8))
        XCTAssertEqual(value, ["a": 1, "b": .double(1.5), "c": [true, nil, "x"], "d": [:]])
        XCTAssertEqual(String(decoding: value.encoded(), as: UTF8.self), #"{"a":1,"b":1.5,"c":[true,null,"x"],"d":{}}"#)
    }
}

private final class CyclicDiagnosticError: NSError, @unchecked Sendable {
    override var userInfo: [String: Any] { [NSUnderlyingErrorKey: self] }
}
