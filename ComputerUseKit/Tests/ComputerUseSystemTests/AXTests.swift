import ApplicationServices
import ComputerUseCore
import XCTest
import os
@testable import ComputerUseSystem

final class AXTests: XCTestCase {
    func testBatchedReadHasNilPlaceholderAndNeverRetriesSingles() throws {
        var calls = SystemAX.Calls(); let asked = AXTestValue(0)
        calls.getMany = { _, names in
            asked.update { $0 += 1 }
            XCTAssertEqual(names, ["AXRole", "AXHelp", "AXTitle"])
            var error = AXError.attributeUnsupported
            return (0, ["AXButton", AXValueCreate(.axError, &error)!, "OK"])
        }
        calls.get = { _, _ in XCTFail("No single fallback"); return (0, nil) }
        let ax = SystemAX(calls: calls), el = ax.app(pid: 7)
        let read = try ax.getMany(el, ["AXRole", "AXHelp", "AXTitle"])
        XCTAssertEqual(read[0] as? String, "AXButton"); XCTAssertNil(read[1]); XCTAssertEqual(read[2] as? String, "OK"); XCTAssertEqual(asked.value, 1)
    }
    func testWholeBatchFailureIsNotRetried() {
        var calls = SystemAX.Calls(); let asked = AXTestValue(0)
        calls.getMany = { _, _ in asked.update { $0 += 1 }; return (AX.cannotComplete, []) }
        calls.get = { _, _ in XCTFail("No retry"); return (0, nil) }
        let ax = SystemAX(calls: calls)
        assertHarnessError("An accessibility request to the app failed (AXError.cannotComplete). Call `get_app_state` again; if it fails again, click by pixel or tell the user.") { _ = try ax.getMany(ax.app(pid: 7), ["AXRole", "AXTitle"]) }
        XCTAssertEqual(asked.value, 1)
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
        var calls = SystemAX.Calls(); let timeouts = AXTestValue<[Float]>([])
        calls.timeout = { _, timeout in timeouts.update { $0.append(timeout) } }; calls.get = { _, _ in (0, "AXGroup") }
        let ax = SystemAX(calls: calls); _ = try ax.get(ax.app(pid: 7), "AXRole"); XCTAssertTrue(timeouts.value.isEmpty)
        let limited = SystemAX(messagingTimeout: 0.2, calls: calls); _ = try limited.get(limited.app(pid: 7), "AXRole")
        XCTAssertEqual(timeouts.value, [0.2])
    }
    func testErrorNames() {
        XCTAssertEqual(AX.errorName(-25204), "AXError.cannotComplete"); XCTAssertEqual(AX.errorName(-25202), "AXError.invalidUIElement")
        XCTAssertEqual(AX.errorName(-25212), "AXError.noValue"); XCTAssertEqual(AX.errorName(-1), "(undocumented AXError)")
    }
    func testSetSettablePerformAndParam() throws {
        var calls = SystemAX.Calls(); let saved = AXTestValue<String?>(nil), performed = AXTestValue<String?>(nil)
        calls.set = { _, name, value in XCTAssertEqual(name, "AXValue"); saved.value = value as? String; return 0 }
        calls.settable = { _, name in name == "AXValue" }
        calls.perform = { _, name in performed.value = name; return 0 }
        calls.param = { _, name, value in XCTAssertEqual(name, "AXStringForRange"); XCTAssertEqual(AXValueGetType(unsafeDowncast(value, to: AXValue.self)), .cfRange); return "xy" }
        let ax = SystemAX(calls: calls), el = ax.app(pid: 7)
        try ax.set(el, "AXValue", "x"); try ax.perform(el, "AXPress")
        XCTAssertEqual(saved.value, "x"); XCTAssertEqual(performed.value, "AXPress"); XCTAssertTrue(ax.settable(el, "AXValue")); XCTAssertFalse(ax.settable(el, "AXTitle"))
        XCTAssertEqual(ax.param(el, "AXStringForRange", NSRange(location: 0, length: 2)) as? String, "xy")
    }
    func testSetPerformFailuresAndParamNil() {
        var calls = SystemAX.Calls()
        calls.set = { _, _, _ in AX.invalidElement }; calls.perform = { _, _ in AX.invalidElement }; calls.param = { _, _, _ in nil }
        let ax = SystemAX(calls: calls), el = ax.app(pid: 7)
        XCTAssertThrowsError(try ax.set(el, "AXValue", "y")); XCTAssertThrowsError(try ax.perform(el, "AXPress")); XCTAssertNil(ax.param(el, "AXX", 1))
    }
    func testActionDescriptionsAreLazyAndCachedOnlyWhenAsked() {
        var calls = SystemAX.Calls(); let described = AXTestValue<[String]>([])
        calls.actionNames = { _ in ["AXPress", "AXZoomWindow"] }
        calls.actionDescription = { _, name in described.update { $0.append(name) }; return name == "AXPress" ? "press" : "zoom the window" }
        let ax = SystemAX(calls: calls), found = ax.actions(ax.app(pid: 7))
        XCTAssertEqual(found.names, ["AXPress", "AXZoomWindow"]); XCTAssertTrue(found.names.contains("AXPress")); XCTAssertTrue(described.value.isEmpty)
        XCTAssertEqual(found["AXZoomWindow"], "zoom the window"); XCTAssertEqual(found["AXZoomWindow"], "zoom the window")
        XCTAssertEqual(described.value, ["AXZoomWindow"]); XCTAssertNil(found["AXNope"])
        XCTAssertEqual(found["AXPress"], "press")
    }
    func testNamesSameAlivePIDAndHitTest() throws {
        var calls = SystemAX.Calls(); let code = AXTestValue<Int32>(0)
        let raw = UIElementRef(AXUIElementCreateApplication(42))
        calls.names = { _ in ["AXRole", "AXTitle"] }; calls.get = { _, _ in (code.value, nil) }; calls.pid = { _ in (0, 42) }
        calls.at = { _, x, y in XCTAssertEqual(x, 3); XCTAssertEqual(y, 4); return unsafeDowncast(raw.object, to: AXUIElement.self) }
        let ax = SystemAX(calls: calls), el = ax.app(pid: 42)
        XCTAssertEqual(ax.names(el), ["AXRole", "AXTitle"]); XCTAssertTrue(AX.same(el, ax.app(pid: 42))); XCTAssertFalse(AX.same(el, nil))
        XCTAssertTrue(ax.alive(el)); code.value = AX.cannotComplete; XCTAssertTrue(ax.alive(el)); code.value = AX.invalidElement; XCTAssertFalse(ax.alive(el))
        XCTAssertEqual(try ax.pid(el), 42); XCTAssertTrue(AX.same(ax.at(nil, x: 3, y: 4), raw))
    }
    func testUnknownWindowAndMissingHit() {
        var calls = SystemAX.Calls(); calls.windowID = { _ in 0 }; calls.at = { _, _, _ in nil }
        let ax = SystemAX(calls: calls), el = ax.app(pid: 7)
        XCTAssertEqual(ax.windowID(el), 0); XCTAssertNil(ax.at(el, x: 0, y: 0))
    }
    func testFrameFromOneBatchAndMissingSize() {
        var calls = SystemAX.Calls(); let complete = AXTestValue(true)
        let point = CGPoint(x: 60, y: 58), size = CGSize(width: 560, height: 592)
        calls.getMany = { _, names in
            XCTAssertEqual(names, ["AXPosition", "AXSize"])
            var p = point, s = size
            return (0, [AXValueCreate(.cgPoint, &p)!, complete.value ? AXValueCreate(.cgSize, &s)! as Any : NSNull()])
        }
        let ax = SystemAX(calls: calls), el = ax.app(pid: 7)
        XCTAssertEqual(ax.frame(el), CGRect(origin: point, size: size)); complete.value = false; XCTAssertNil(ax.frame(el))
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
        var calls = SystemAX.ObserverCalls()
        let log = AXTestValue<[String]>([]), heard = AXTestValue<[String]>([])
        let callback = AXTestValue<(@Sendable (String, UIElementRef) -> Void)?>(nil)
        calls.create = { pid, cb in XCTAssertEqual(pid, 7); callback.value = cb; return 0 }
        calls.add = { _, _, name in log.update { $0.append("add \(name)") }; return name == "AXMenuOpened" ? AX.cannotComplete : 0 }
        calls.remove = { _, _, name in log.update { $0.append("remove \(name)") } }; calls.install = { _ in log.update { $0.append("install") } }; calls.uninstall = { _ in log.update { $0.append("uninstall") } }
        let ax = SystemAX(observerCalls: calls), el = ax.app(pid: 7)
        let observation = try ax.observe(pid: 7, element: el, names: ["AXCreated", "AXMenuOpened"]) { name, element in heard.update { $0.append(name) }; XCTAssertTrue(AX.same(el, element)) }
        callback.value?("AXCreated", el); observation.stop(); observation.stop()
        callback.value?("AXCreated", el) // delivery retained by the fake SDK is gated after stop
        XCTAssertEqual(heard.value, ["AXCreated"])
        XCTAssertEqual(log.value, ["add AXCreated", "add AXMenuOpened", "install", "uninstall", "remove AXCreated"])
    }
    func testObserverFailureCleansPartialRegistrations() {
        var calls = SystemAX.ObserverCalls(); let log = AXTestValue<[String]>([])
        calls.create = { _, _ in 0 }; calls.add = { _, _, name in name == "bad" ? AX.invalidElement : 0 }
        calls.remove = { _, _, name in log.update { $0.append(name) } }; calls.install = { _ in XCTFail("Must not install") }; calls.uninstall = { _ in }
        let ax = SystemAX(observerCalls: calls)
        XCTAssertThrowsError(try ax.observe(pid: 7, element: ax.app(pid: 7), names: ["good", "bad"], callback: { _, _ in }))
        XCTAssertEqual(log.value, ["good"])
    }
    func testReentrantCallbackStopAndTeardownCallbacksAreGated() throws {
        let driver = AXObserverDriver()
        let slot = AXTestValue<(any AXObservation)?>(nil)
        let heard = AXTestValue(0)
        let ax = SystemAX(observerCalls: driver.calls), element = ax.app(pid: 7)
        var calls = driver.calls
        calls.remove = { _, _, _ in
            slot.value?.stop() // the teardown claim lock must already be released
            driver.fire("during-remove", element)
            driver.log.update { $0.append("remove") }
        }
        calls.uninstall = { _ in
            slot.value?.stop() // no claim lock may span the main hop either
            driver.fire("during-uninstall", element)
            driver.log.update { $0.append("uninstall") }
        }
        let backend = SystemAX(observerCalls: calls)
        let observation = try backend.observe(pid: 7, element: element, names: ["created"]) { _, _ in
            heard.update { $0 += 1 }
            slot.value?.stop()
        }
        slot.value = observation
        driver.fire("created", element)
        driver.fire("after-stop", element)
        XCTAssertEqual(heard.value, 1)
        XCTAssertEqual(driver.log.value, ["add created", "install", "uninstall", "remove"])
        slot.value = nil
    }

    func testConcurrentStopsClaimCleanupOnceWithoutWaitingOnFirstStop() throws {
        // MainThread's no-run-loop fallback executes only injected fake hooks.
        XCTAssertFalse(MainThread.isRunning)
        let driver = AXObserverDriver(), removing = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        let heard = AXTestValue(0)
        var calls = driver.calls
        calls.remove = { _, _, _ in
            driver.log.update { $0.append("remove") }
            removing.signal()
            XCTAssertEqual(resume.wait(timeout: .now() + 5), .success)
        }
        let ax = SystemAX(observerCalls: calls), element = ax.app(pid: 7)
        let observation = try ax.observe(pid: 7, element: element, names: ["created"]) { _, _ in heard.update { $0 += 1 } }
        DispatchQueue.global().async { observation.stop(); done.signal() }
        defer { resume.signal() }
        XCTAssertEqual(removing.wait(timeout: .now() + 5), .success)
        DispatchQueue.concurrentPerform(iterations: 100) { _ in observation.stop() }
        driver.fire("cleanup-pending", element)
        XCTAssertEqual(heard.value, 0)
        XCTAssertEqual(driver.log.value, ["add created", "install", "uninstall", "remove"])
        resume.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(driver.log.value, ["add created", "install", "uninstall", "remove"])
    }

    func testAlreadyClaimedCallbackMayFinishAfterStopWithoutBlockingTeardown() throws {
        let driver = AXObserverDriver(), entered = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        let heard = AXTestValue(0)
        let ax = SystemAX(observerCalls: driver.calls), element = ax.app(pid: 7)
        let observation = try ax.observe(pid: 7, element: element, names: ["created"]) { _, _ in
            entered.signal()
            XCTAssertEqual(resume.wait(timeout: .now() + 5), .success)
            heard.update { $0 += 1 }
        }
        DispatchQueue.global().async { driver.fire("created", element); finished.signal() }
        defer { resume.signal() }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        observation.stop()
        XCTAssertEqual(driver.log.value, ["add created", "install", "uninstall", "remove created"])
        driver.fire("after-stop", element)
        XCTAssertEqual(heard.value, 0)
        resume.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(heard.value, 1)
    }

    func testObservationDeinitCleansUpAndClosesRetainedSDKCallback() throws {
        let driver = AXObserverDriver(), heard = AXTestValue(0)
        let ax = SystemAX(observerCalls: driver.calls), element = ax.app(pid: 7)
        var observation: (any AXObservation)? = try ax.observe(pid: 7, element: element, names: ["created"]) { _, _ in heard.update { $0 += 1 } }
        XCTAssertNotNil(observation)
        observation = nil
        driver.fire("after-deinit", element)
        XCTAssertEqual(heard.value, 0)
        XCTAssertEqual(driver.log.value, ["add created", "install", "uninstall", "remove created"])
    }

    func testFailedCreateClosesCallbackRetainedByInjectedSDK() {
        let driver = AXObserverDriver(), heard = AXTestValue(0)
        var calls = driver.calls
        calls.create = { _, callback in
            driver.callback.value = callback
            throw AX.failure(AX.invalidElement)
        }
        let backend = SystemAX(observerCalls: calls), element = backend.app(pid: 7)
        XCTAssertThrowsError(try backend.observe(pid: 7, element: element, names: ["created"]) { _, _ in heard.update { $0 += 1 } })
        driver.fire("after-create-failed", element)
        XCTAssertEqual(heard.value, 0)
        XCTAssertTrue(driver.log.value.isEmpty)
    }

    func testFailedRegistrationClosesRetainedCallbackBeforeCleanup() {
        let driver = AXObserverDriver(), heard = AXTestValue(0)
        let ax = SystemAX(observerCalls: driver.calls), element = ax.app(pid: 7)
        var calls = driver.calls
        calls.add = { _, _, name in
            driver.fire("during-add", element)
            return name == "bad" ? AX.invalidElement : 0
        }
        calls.remove = { _, _, _ in driver.fire("during-remove", element) }
        calls.uninstall = { _ in driver.fire("during-uninstall", element) }
        let backend = SystemAX(observerCalls: calls)
        XCTAssertThrowsError(try backend.observe(pid: 7, element: element, names: ["good", "bad"]) { _, _ in heard.update { $0 += 1 } })
        driver.fire("after-failure", element)
        XCTAssertEqual(heard.value, 2) // registration can deliver; cleanup cannot
    }

    func testObserverOnlySourceLifecycleUsesMainHopAndIPCStaysOnWorker() {
        let inHop = AXTestValue(false), log = AXTestValue<[String]>([])
        let done = DispatchSemaphore(value: 0)
        var calls = SystemAX.ObserverCalls()
        calls.mainHop = { work in
            XCTAssertFalse(inHop.value)
            inHop.value = true
            defer { inHop.value = false }
            work()
        }
        calls.create = { _, _ in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertFalse(inHop.value)
            log.update { $0.append("create") }
            return 0
        }
        calls.add = { _, _, name in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertFalse(inHop.value)
            log.update { $0.append("add \(name)") }
            return 0
        }
        calls.install = { _ in
            XCTAssertTrue(inHop.value)
            log.update { $0.append("install") }
        }
        calls.uninstall = { _ in
            XCTAssertTrue(inHop.value)
            log.update { $0.append("uninstall") }
        }
        calls.remove = { _, _, name in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertFalse(inHop.value)
            log.update { $0.append("remove \(name)") }
        }
        let ax = SystemAX(observerCalls: calls), element = ax.app(pid: 7)
        DispatchQueue.global().async {
            defer { done.signal() }
            do {
                let observation = try ax.observe(pid: 7, element: element, names: ["first", "second"]) { _, _ in }
                observation.stop()
                observation.stop()
            } catch { XCTFail("Unexpected registration error: \(error)") }
        }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(log.value, ["create", "add first", "add second", "install", "uninstall", "remove first", "remove second"])
    }

    func testObserverFailedRegistrationCleansOnWorkerWithoutMainHop() {
        let log = AXTestValue<[String]>([]), done = DispatchSemaphore(value: 0)
        var calls = SystemAX.ObserverCalls()
        calls.mainHop = { _ in XCTFail("No source was installed; failure cleanup must not main-hop") }
        calls.create = { _, _ in
            XCTAssertFalse(Thread.isMainThread)
            log.update { $0.append("create") }
            return 0
        }
        calls.add = { _, _, name in
            XCTAssertFalse(Thread.isMainThread)
            log.update { $0.append("add \(name)") }
            return name == "bad" ? AX.invalidElement : 0
        }
        calls.install = { _ in XCTFail("Must not install after failure") }
        calls.uninstall = { _ in XCTFail("Must not uninstall an uninstalled source") }
        calls.remove = { _, _, name in
            XCTAssertFalse(Thread.isMainThread)
            log.update { $0.append("remove \(name)") }
        }
        let ax = SystemAX(observerCalls: calls), element = ax.app(pid: 7)
        DispatchQueue.global().async {
            defer { done.signal() }
            do {
                _ = try ax.observe(pid: 7, element: element, names: ["good", "bad"]) { _, _ in }
                XCTFail("Registration should fail")
            } catch {
                XCTAssertEqual((error as? HarnessError)?.message, AX.failure(AX.invalidElement).message)
            }
        }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(log.value, ["create", "add good", "add bad", "remove good"])
    }

    func testReentrantStopRetainsTokenUntilObservationDeinit() throws {
        let driver = AXObserverDriver(), deaths = AXTestValue(0)
        let slot = AXTestValue<(any AXObservation)?>(nil)
        var calls = driver.calls
        calls.create = { _, callback in
            driver.callback.value = callback
            return AXTokenLifetimeProbe { deaths.update { $0 += 1 } }
        }
        let ax = SystemAX(observerCalls: calls), element = ax.app(pid: 7)
        slot.value = try ax.observe(pid: 7, element: element, names: ["created"]) { _, _ in
            slot.value?.stop()
            XCTAssertEqual(deaths.value, 0, "Reentrant stop must retain the observer token")
        }
        driver.fire("created", element)
        slot.value?.stop()
        XCTAssertEqual(deaths.value, 0, "Stopped Observation still owns its immutable token")
        slot.value = nil
        XCTAssertEqual(deaths.value, 1)
    }

    func testSynchronousBackendCallsAreNotGloballySerializedOrMainHopped() throws {
        let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        let firstDone = DispatchSemaphore(value: 0), secondDone = DispatchSemaphore(value: 0)
        var calls = SystemAX.Calls()
        calls.get = { _, name in
            XCTAssertFalse(Thread.isMainThread)
            if name == "first" {
                entered.signal()
                XCTAssertEqual(resume.wait(timeout: .now() + 5), .success)
            }
            return (0, name)
        }
        let ax = SystemAX(calls: calls), element = ax.app(pid: 7)
        DispatchQueue.global().async {
            XCTAssertEqual(try? ax.get(element, "first") as? String, "first")
            firstDone.signal()
        }
        defer { resume.signal() }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        DispatchQueue.global().async {
            XCTAssertEqual(try? ax.get(element, "second") as? String, "second")
            secondDone.signal()
        }
        XCTAssertEqual(secondDone.wait(timeout: .now() + 5), .success)
        resume.signal()
        XCTAssertEqual(firstDone.wait(timeout: .now() + 5), .success)
    }

}

/// Only checked-Sendable values may enter this test recorder. SDK objects are
/// constructed inside fake calls or captured as the existing immutable handle.
private final class AXTestValue<Value: Sendable>: Sendable {
    private let state: OSAllocatedUnfairLock<Value>
    init(_ value: Value) { state = OSAllocatedUnfairLock(initialState: value) }
    var value: Value {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
    func update(_ body: @Sendable (inout Value) -> Void) { state.withLock(body) }
}

/// Entirely fake observer driver: no default observer hook reaches the SDK.
private final class AXObserverDriver: Sendable {
    let callback = AXTestValue<(@Sendable (String, UIElementRef) -> Void)?>(nil)
    let log = AXTestValue<[String]>([])
    func fire(_ name: String, _ element: UIElementRef) { callback.value?(name, element) }
    var calls: SystemAX.ObserverCalls {
        var calls = SystemAX.ObserverCalls()
        calls.create = { [self] _, callback in self.callback.value = callback; return 0 }
        calls.add = { [self] _, _, name in log.update { $0.append("add \(name)") }; return 0 }
        calls.remove = { [self] _, _, name in log.update { $0.append("remove \(name)") } }
        calls.install = { [self] _ in log.update { $0.append("install") } }
        calls.uninstall = { [self] _ in log.update { $0.append("uninstall") } }
        return calls
    }
}

/// Fake immutable Sendable token; its deinit observes ownership, not SDK behavior.
private final class AXTokenLifetimeProbe: Sendable {
    let onDeinit: @Sendable () -> Void
    init(_ onDeinit: @escaping @Sendable () -> Void) { self.onDeinit = onDeinit }
    deinit { onDeinit() }
}
