import ApplicationServices
import ComputerUseCore
import XCTest
@testable import ComputerUseSystem

final class AXTests: XCTestCase {
    func testBatchedReadHasNilPlaceholderAndNeverRetriesSingles() throws {
        var calls = SystemAX.Calls(), asked = 0
        var error = AXError.attributeUnsupported
        let placeholder = AXValueCreate(.axError, &error)!
        calls.getMany = { _, names in asked += 1; XCTAssertEqual(names, ["AXRole", "AXHelp", "AXTitle"]); return (0, ["AXButton", placeholder, "OK"]) }
        calls.get = { _, _ in XCTFail("No single fallback"); return (0, nil) }
        let ax = SystemAX(calls: calls), el = ax.app(pid: 7)
        let read = try ax.getMany(el, ["AXRole", "AXHelp", "AXTitle"])
        XCTAssertEqual(read[0] as? String, "AXButton"); XCTAssertNil(read[1]); XCTAssertEqual(read[2] as? String, "OK"); XCTAssertEqual(asked, 1)
    }
    func testWholeBatchFailureIsNotRetried() {
        var calls = SystemAX.Calls(), asked = 0
        calls.getMany = { _, _ in asked += 1; return (AX.cannotComplete, []) }
        calls.get = { _, _ in XCTFail("No retry"); return (0, nil) }
        let ax = SystemAX(calls: calls)
        assertHarnessError("An accessibility request to the app failed (AXError.cannotComplete). Call `get_app_state` again; if it fails again, click by pixel or tell the user.") { _ = try ax.getMany(ax.app(pid: 7), ["AXRole", "AXTitle"]) }
        XCTAssertEqual(asked, 1)
    }
    func testEveryMissingCodeReturnsNilAndEveryOtherFailureThrows() throws {
        for code in AX.missing {
            var calls = SystemAX.Calls(); calls.get = { _, _ in (code, "ignored") }
            let ax = SystemAX(calls: calls); XCTAssertNil(try ax.get(ax.app(pid: 7), "AXRole"))
        }
        for code: Int32 in [AX.invalidElement, AX.cannotComplete, -25211] {
            var calls = SystemAX.Calls(); calls.get = { _, _ in (code, nil) }
            let ax = SystemAX(calls: calls)
            XCTAssertThrowsError(try ax.get(ax.app(pid: 7), "AXRole")) { XCTAssertEqual(($0 as? HarnessError)?.message, AX.failure(code).message) }
        }
    }
    func testDefaultTimeoutIsUntouchedAndOptionalTimeoutIsApplied() throws {
        var calls = SystemAX.Calls(), timeouts: [Float] = []
        calls.timeout = { _, timeout in timeouts.append(timeout) }; calls.get = { _, _ in (0, "AXGroup") }
        let ax = SystemAX(calls: calls); _ = try ax.get(ax.app(pid: 7), "AXRole"); XCTAssertTrue(timeouts.isEmpty)
        let limited = SystemAX(messagingTimeout: 0.2, calls: calls); _ = try limited.get(limited.app(pid: 7), "AXRole")
        XCTAssertEqual(timeouts, [0.2])
    }
    func testErrorNames() {
        XCTAssertEqual(AX.errorName(-25204), "AXError.cannotComplete"); XCTAssertEqual(AX.errorName(-25202), "AXError.invalidUIElement")
        XCTAssertEqual(AX.errorName(-25212), "AXError.noValue"); XCTAssertEqual(AX.errorName(-1), "(undocumented AXError)")
    }
    func testSetSettablePerformAndParam() throws {
        var calls = SystemAX.Calls(), saved: String?, performed: String?
        calls.set = { _, name, value in XCTAssertEqual(name, "AXValue"); saved = value as? String; return 0 }
        calls.settable = { _, name in name == "AXValue" }
        calls.perform = { _, name in performed = name; return 0 }
        calls.param = { _, name, value in XCTAssertEqual(name, "AXStringForRange"); XCTAssertEqual(AXValueGetType(unsafeBitCast(value, to: AXValue.self)), .cfRange); return "xy" }
        let ax = SystemAX(calls: calls), el = ax.app(pid: 7)
        try ax.set(el, "AXValue", "x"); try ax.perform(el, "AXPress")
        XCTAssertEqual(saved, "x"); XCTAssertEqual(performed, "AXPress"); XCTAssertTrue(ax.settable(el, "AXValue")); XCTAssertFalse(ax.settable(el, "AXTitle"))
        XCTAssertEqual(ax.param(el, "AXStringForRange", NSRange(location: 0, length: 2)) as? String, "xy")
    }
    func testSetPerformFailuresAndParamNil() {
        var calls = SystemAX.Calls()
        calls.set = { _, _, _ in AX.invalidElement }; calls.perform = { _, _ in AX.invalidElement }; calls.param = { _, _, _ in nil }
        let ax = SystemAX(calls: calls), el = ax.app(pid: 7)
        XCTAssertThrowsError(try ax.set(el, "AXValue", "y")); XCTAssertThrowsError(try ax.perform(el, "AXPress")); XCTAssertNil(ax.param(el, "AXX", 1))
    }
    func testActionDescriptionsAreLazyAndCachedOnlyWhenAsked() {
        var calls = SystemAX.Calls(), described: [String] = []
        calls.actionNames = { _ in ["AXPress", "AXZoomWindow"] }
        calls.actionDescription = { _, name in described.append(name); return name == "AXPress" ? "press" : "zoom the window" }
        let ax = SystemAX(calls: calls), found = ax.actions(ax.app(pid: 7))
        XCTAssertEqual(found.names, ["AXPress", "AXZoomWindow"]); XCTAssertTrue(found.names.contains("AXPress")); XCTAssertTrue(described.isEmpty)
        XCTAssertEqual(found["AXZoomWindow"], "zoom the window"); XCTAssertEqual(found["AXZoomWindow"], "zoom the window")
        XCTAssertEqual(described, ["AXZoomWindow"]); XCTAssertNil(found["AXNope"])
        XCTAssertEqual(found["AXPress"], "press")
    }
    func testNamesSameAlivePIDAndHitTest() throws {
        var calls = SystemAX.Calls(), code: Int32 = 0
        let raw = AXUIElementCreateApplication(42)
        calls.names = { _ in ["AXRole", "AXTitle"] }; calls.get = { _, _ in (code, nil) }; calls.pid = { _ in (0, 42) }
        calls.at = { _, x, y in XCTAssertEqual(x, 3); XCTAssertEqual(y, 4); return raw }
        let ax = SystemAX(calls: calls), el = ax.app(pid: 42)
        XCTAssertEqual(ax.names(el), ["AXRole", "AXTitle"]); XCTAssertTrue(AX.same(el, ax.app(pid: 42))); XCTAssertFalse(AX.same(el, nil))
        XCTAssertTrue(ax.alive(el)); code = AX.cannotComplete; XCTAssertTrue(ax.alive(el)); code = AX.invalidElement; XCTAssertFalse(ax.alive(el))
        XCTAssertEqual(try ax.pid(el), 42); XCTAssertTrue(AX.same(ax.at(nil, x: 3, y: 4), UIElementRef(raw)))
    }
    func testUnknownWindowAndMissingHit() {
        var calls = SystemAX.Calls(); calls.windowID = { _ in 0 }; calls.at = { _, _, _ in nil }
        let ax = SystemAX(calls: calls), el = ax.app(pid: 7)
        XCTAssertEqual(ax.windowID(el), 0); XCTAssertNil(ax.at(el, x: 0, y: 0))
    }
    func testFrameFromOneBatchAndMissingSize() {
        var calls = SystemAX.Calls(), complete = true
        var point = CGPoint(x: 60, y: 58), size = CGSize(width: 560, height: 592)
        let p = AXValueCreate(.cgPoint, &point)!, s = AXValueCreate(.cgSize, &size)!
        calls.getMany = { _, names in XCTAssertEqual(names, ["AXPosition", "AXSize"]); return (0, [p, complete ? s as Any : NSNull()]) }
        let ax = SystemAX(calls: calls), el = ax.app(pid: 7)
        XCTAssertEqual(ax.frame(el), CGRect(origin: point, size: size)); complete = false; XCTAssertNil(ax.frame(el))
    }
    func testAllSeamValueTypesAndRecursiveCollections() throws {
        let raw = AXUIElementCreateApplication(42), url = URL(fileURLWithPath: "/tmp/test")
        let rich = NSAttributedString(string: "rich")
        let converted = SystemAX.value(["el": raw, "bool": kCFBooleanTrue!, "int": NSNumber(value: 3), "float": NSNumber(value: 1.5), "url": url as CFURL, "rich": rich, "array": [raw, kCFBooleanFalse!] as [Any]]) as! [String: Any]
        XCTAssertNotNil(converted["el"] as? UIElementRef)
        XCTAssertTrue(type(of: converted["bool"]!) == Bool.self); XCTAssertEqual(converted["bool"] as? Bool, true)
        XCTAssertTrue(type(of: converted["int"]!) == Int.self); XCTAssertEqual(converted["int"] as? Int, 3)
        XCTAssertTrue(type(of: converted["float"]!) == Double.self); XCTAssertEqual(converted["float"] as? Double, 1.5)
        XCTAssertEqual(converted["url"] as? URL, url); XCTAssertEqual(converted["rich"] as? NSAttributedString, rich)
        let array = converted["array"] as! [Any]; XCTAssertNotNil(array[0] as? UIElementRef); XCTAssertTrue(type(of: array[1]) == Bool.self)
        XCTAssertNil(SystemAX.value(nil)); XCTAssertEqual(SystemAX.value("text") as? String, "text")
        XCTAssertTrue(type(of: SystemAX.value("cf text" as CFString)!) == String.self)
        var failure = AXError.noValue
        let placeholder = AXValueCreate(.axError, &failure)!
        XCTAssertEqual((SystemAX.value(["kept", placeholder]) as? [String]), ["kept"])
        XCTAssertEqual((SystemAX.value(["missing": placeholder, "kept": "ok"]) as? [String: String]), ["kept": "ok"])
    }
    func testAXGeometryRoundTripsAcrossSeam() {
        let point = CGPoint(x: -20, y: 4), size = CGSize(width: 10, height: 30), rect = CGRect(x: -3, y: 1, width: 10, height: 4), range = NSRange(location: 2, length: 7)
        XCTAssertEqual(SystemAX.value(SystemAX.argument(point)) as? CGPoint, point)
        XCTAssertEqual(SystemAX.value(SystemAX.argument(size)) as? CGSize, size)
        XCTAssertEqual(SystemAX.value(SystemAX.argument(rect)) as? CGRect, rect)
        XCTAssertEqual(SystemAX.value(SystemAX.argument(range)) as? NSRange, range)
        let el = UIElementRef(AXUIElementCreateApplication(42))
        let array = SystemAX.argument([el]) as! [Any]
        XCTAssertEqual(CFGetTypeID(array[0] as CFTypeRef), AXUIElementGetTypeID())
    }
    func testObserveSkipsUnsupportedDeliveryAndStopsOnce() throws {
        var calls = SystemAX.ObserverCalls(), log: [String] = [], heard: [String] = []
        var callback: ((String, UIElementRef) -> Void)?
        calls.create = { pid, cb in XCTAssertEqual(pid, 7); callback = cb; return NSObject() }
        calls.add = { _, _, name in log.append("add \(name)"); return name == "AXMenuOpened" ? AX.cannotComplete : 0 }
        calls.remove = { _, _, name in log.append("remove \(name)") }; calls.install = { _ in log.append("install") }; calls.uninstall = { _ in log.append("uninstall") }
        let ax = SystemAX(observerCalls: calls), el = ax.app(pid: 7)
        let observation = try ax.observe(pid: 7, element: el, names: ["AXCreated", "AXMenuOpened"]) { name, element in heard.append(name); XCTAssertTrue(AX.same(el, element)) }
        callback?("AXCreated", el); observation.stop(); observation.stop()
        XCTAssertEqual(heard, ["AXCreated"])
        XCTAssertEqual(log, ["add AXCreated", "add AXMenuOpened", "install", "remove AXCreated", "uninstall"])
    }
    func testObserverFailureCleansPartialRegistrations() {
        var calls = SystemAX.ObserverCalls(), log: [String] = []
        calls.create = { _, _ in NSObject() }; calls.add = { _, _, name in name == "bad" ? AX.invalidElement : 0 }
        calls.remove = { _, _, name in log.append(name) }; calls.install = { _ in XCTFail("Must not install") }; calls.uninstall = { _ in }
        let ax = SystemAX(observerCalls: calls)
        XCTAssertThrowsError(try ax.observe(pid: 7, element: ax.app(pid: 7), names: ["good", "bad"], callback: { _, _ in }))
        XCTAssertEqual(log, ["good"])
    }
}
