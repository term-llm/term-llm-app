import AppKit
import Foundation
import XCTest
@preconcurrency import TermLLMMacKit

@testable import TermLLM

/// Pure configuration checks: no updater is started and no feed is contacted.
final class AppUpdatePolicyTests: XCTestCase {
    private var valid: [String: Any] {
        ["SUPublicEDKey": Data(repeating: 7, count: 32).base64EncodedString(),
         "SUFeedURL": AppUpdatePolicy.productionFeed,
         "SUVerifyUpdateBeforeExtraction": true,
         "SURequireSignedFeed": true,
         "SUSignedFeedFailureExpirationInterval": 0,
         "SUAllowsAutomaticUpdates": false]
    }

    func testProductionConfiguration() {
        XCTAssertNil(AppUpdatePolicy.disabledReason(info: valid, suppressed: false, allowLocalTestFeed: false))
    }

    func testMissingAndMalformedKeysFailClosed() {
        for key in ["", "$(SPARKLE_PUBLIC_ED_KEY)", "not base64", Data(repeating: 1, count: 31).base64EncodedString(),
                    Data(repeating: 1, count: 33).base64EncodedString(), Data(repeating: 0, count: 32).base64EncodedString(),
                    valid["SUPublicEDKey"] as! String + "\n"] {
            var info = valid
            info["SUPublicEDKey"] = key
            XCTAssertNotNil(AppUpdatePolicy.disabledReason(info: info, suppressed: false), key)
        }
        var info = valid
        info.removeValue(forKey: "SUPublicEDKey")
        XCTAssertNotNil(AppUpdatePolicy.disabledReason(info: info, suppressed: false))
    }

    func testMandatoryVerificationCannotFallBackToCodeSigning() {
        var info = valid
        info["SUVerifyUpdateBeforeExtraction"] = false
        XCTAssertNotNil(AppUpdatePolicy.disabledReason(info: info, suppressed: false))
        info.removeValue(forKey: "SUVerifyUpdateBeforeExtraction")
        XCTAssertNotNil(AppUpdatePolicy.disabledReason(info: info, suppressed: false))
    }

    func testSignedFeedsCannotExpireIntoUnsignedFallback() {
        for value in [false, "", NSNull()] as [Any] {
            var info = valid
            info["SURequireSignedFeed"] = value
            XCTAssertNotNil(AppUpdatePolicy.disabledReason(info: info, suppressed: false))
        }
        for value in [1, 86400, -1, "", NSNull()] as [Any] {
            var info = valid
            info["SUSignedFeedFailureExpirationInterval"] = value
            XCTAssertNotNil(AppUpdatePolicy.disabledReason(info: info, suppressed: false))
        }
        var info = valid
        info.removeValue(forKey: "SURequireSignedFeed")
        XCTAssertNotNil(AppUpdatePolicy.disabledReason(info: info, suppressed: false))
        info = valid
        info.removeValue(forKey: "SUSignedFeedFailureExpirationInterval")
        XCTAssertNotNil(AppUpdatePolicy.disabledReason(info: info, suppressed: false))
    }

    func testAutomaticInstallationIsForbidden() {
        var info = valid
        info["SUAllowsAutomaticUpdates"] = true
        XCTAssertNotNil(AppUpdatePolicy.disabledReason(info: info, suppressed: false))
        info.removeValue(forKey: "SUAllowsAutomaticUpdates")
        XCTAssertNotNil(AppUpdatePolicy.disabledReason(info: info, suppressed: false))
    }

    func testShippedPlistRequiresSignedFeedAndManualInstallation() {
        let info = Bundle.main.infoDictionary ?? [:]
        XCTAssertEqual(info["SURequireSignedFeed"] as? Bool, true)
        XCTAssertEqual((info["SUSignedFeedFailureExpirationInterval"] as? NSNumber)?.doubleValue, 0)
        XCTAssertEqual(info["SUVerifyUpdateBeforeExtraction"] as? Bool, true)
        XCTAssertEqual(info["SUAllowsAutomaticUpdates"] as? Bool, false)
    }

    func testProductionRejectsEveryFeedOverride() {
        for feed in ["http://127.0.0.1:8000/appcast.xml", "https://example.org/appcast.xml",
                     "http://term-llm.com/mac/appcast.xml", "$(SPARKLE_FEED_URL)", ""] {
            var info = valid
            info["SUFeedURL"] = feed
            XCTAssertNotNil(AppUpdatePolicy.disabledReason(info: info, suppressed: false, allowLocalTestFeed: false), feed)
        }
    }

    func testTestBuildAllowsOnlyExplicitIPv4LoopbackHTTP() {
        var info = valid
        info["SUFeedURL"] = "http://127.0.0.1:8000/appcast.xml"
        XCTAssertNil(AppUpdatePolicy.disabledReason(info: info, suppressed: false, allowLocalTestFeed: true))
        for feed in ["http://localhost:8000/appcast.xml", "https://example.org/appcast.xml", "file:///tmp/appcast.xml",
                     "http://127.0.0.1.evil/appcast.xml", "http://user:secret@127.0.0.1/appcast.xml",
                     "http://127.0.0.1/appcast.xml?token=secret", "http://127.0.0.1/appcast.xml#fragment"] {
            info["SUFeedURL"] = feed
            XCTAssertNotNil(AppUpdatePolicy.disabledReason(info: info, suppressed: false, allowLocalTestFeed: true), feed)
        }
        info["SUFeedURL"] = "http://127.0.0.1:8000/appcast.xml"
        info["SUPublicEDKey"] = ""
        XCTAssertNotNil(AppUpdatePolicy.disabledReason(info: info, suppressed: false, allowLocalTestFeed: true))
    }

    func testFixturesSuppressEvenValidConfiguration() {
        XCTAssertNotNil(AppUpdatePolicy.disabledReason(info: valid, suppressed: true))
    }

    func testReleaseHasNoImplicitTestFeedPermission() {
        #if !DEBUG && !SPARKLE_LOCAL_FEED_TEST
        XCTAssertFalse(AppUpdatePolicy.allowsLocalTestFeed)
        #endif
    }
}

@MainActor
final class AppUpdateControllerTests: XCTestCase {
    func testHostedTestSuppressionDoesNotConstructSparkleOrExposeUpdateActions() {
        let updates = AppUpdateController(info: [:], suppressed: true)
        updates.start()
        XCTAssertNil(updates.controller)
        XCTAssertFalse(updates.canCheckForUpdates)
        XCTAssertFalse(updates.automaticallyChecksForUpdates)
        let menu = NSMenu()
        updates.addMenuItems(to: menu)
        XCTAssertEqual(menu.numberOfItems, 1)
        XCTAssertEqual(menu.items.first?.title, "App Updates Unavailable")
        XCTAssertEqual(menu.items.first?.isEnabled, false)
        XCTAssertNotNil(menu.items.first?.toolTip)
    }

    func testMissingKeyCannotStartChecksOrExposeUI() {
        let updates = AppUpdateController(info: ["SUFeedURL": AppUpdatePolicy.productionFeed], suppressed: false)
        updates.start()
        updates.checkForUpdates()
        updates.setAutomaticChecks(true)
        XCTAssertNil(updates.controller)
        XCTAssertFalse(updates.canCheckForUpdates)
        let menu = NSMenu()
        updates.addMenuItems(to: menu)
        XCTAssertEqual(menu.numberOfItems, 1)
        XCTAssertEqual(menu.items.first?.title, "App Updates Unavailable")
        XCTAssertEqual(menu.items.first?.isEnabled, false)
        XCTAssertNotNil(menu.items.first?.toolTip)
    }
}

@MainActor
final class AppUpdateDrainTests: XCTestCase {
    func testShutdownAcknowledgmentIsNotProcessExit() async throws {
        var processExited = false
        var drained = false
        let waiter = Task { @MainActor in
            try await AppUpdateDrain.waitUntil(timeout: .seconds(2)) { processExited }
            drained = true
        }
        // Simulate an acknowledged shutdown while requests are still draining.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(drained)
        processExited = true
        try await waiter.value
        XCTAssertTrue(drained)
    }

    func testDrainTimesOutRatherThanAuthorizingReplacement() async {
        do {
            try await AppUpdateDrain.waitUntil(timeout: .zero) { false }
            XCTFail("A live helper must veto termination on timeout")
        } catch {
            XCTAssertEqual((error as NSError).domain, "AppUpdateDrain")
        }
    }

    func testDrainHonorsCancellation() async {
        let task = Task { @MainActor in
            try await AppUpdateDrain.waitUntil(timeout: .seconds(10)) { false }
        }
        task.cancel()
        do {
            try await task.value
            XCTFail("Cancelled preparation must not authorize replacement")
        } catch { XCTAssertTrue(error is CancellationError) }
    }
}


/// File-only home and a blocking fake login service: no launchctl, real login
/// registration, network requests or developer home access.
private final class DrainingLoginService: MainAppLoginService, @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var currentStatus = MainAppLoginStatus.notRegistered
    private var unregisters = 0
    var status: MainAppLoginStatus { lock.withLock { currentStatus } }
    var unregisterCount: Int { lock.withLock { unregisters } }
    func register() throws {
        guard release.wait(timeout: .now() + 5) == .success else {
            throw NSError(domain: "DrainingLoginService", code: 1)
        }
        lock.withLock { currentStatus = .enabled }
    }
    func unregister() throws {
        lock.withLock { unregisters += 1; currentStatus = .notRegistered }
    }
}

@MainActor
final class AppUpdateMutationDrainTests: XCTestCase {
    func testExistingDetachedMutationDrainsAndNewMutationsAreBlocked() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let service = DrainingLoginService()
        defer { service.release.signal() }
        let model = CompanionModel(home: home, loginService: service)
        model.setLoginItem(true)
        XCTAssertTrue(model.busy)
        var prepared = false
        let drain = Task { @MainActor in
            try await model.prepareForTermination()
            prepared = true
        }
        try await AppUpdateDrain.waitUntil(timeout: .seconds(2)) { model.preparingForTermination }
        XCTAssertFalse(prepared, "Detached mutation is still blocked in the fake service")
        model.setLoginItem(false)
        XCTAssertEqual(service.unregisterCount, 0)
        service.release.signal()
        try await drain.value
        XCTAssertFalse(model.busy)
        XCTAssertTrue(prepared)
        // Even once idle, mutations remain blocked until termination is either
        // committed or explicitly cancelled.
        model.setLoginItem(false)
        XCTAssertEqual(service.unregisterCount, 0)
        model.cancelTerminationPreparation()
        XCTAssertFalse(model.preparingForTermination)
        model.setLoginItem(false)
        try await model.prepareForTermination()
        XCTAssertEqual(service.unregisterCount, 1)
    }
}


private final class SuspendedLoginRefresh: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var starts = 0
    var startCount: Int { lock.withLock { starts } }
    func run() {
        lock.withLock { starts += 1 }
        _ = release.wait(timeout: .now() + 5)
    }
}

@MainActor
final class AppUpdateLoginRefreshDrainTests: XCTestCase {
    func testTimeoutAndRetryKeepTrackingDetachedLoginRefresh() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let refresh = SuspendedLoginRefresh()
        defer { refresh.release.signal() }
        let controller = MacLocalServiceController(home: home)
        controller.startLoginRefresh { refresh.run() }
        try await AppUpdateDrain.waitUntil(timeout: .seconds(2)) { refresh.startCount == 1 }
        for _ in 0..<2 {
            do {
                try await controller.waitForLoginRefresh(timeout: .zero)
                XCTFail("Live detached login refresh must veto termination")
            } catch {
                XCTAssertEqual((error as NSError).domain, "AppUpdateDrain")
            }
            XCTAssertTrue(controller.loginRefreshPending)
            // A timeout is not completion and must not admit a replacement.
            controller.startLoginRefresh { refresh.run() }
            XCTAssertEqual(refresh.startCount, 1)
        }
        refresh.release.signal()
        try await controller.waitForLoginRefresh(timeout: .seconds(2))
        XCTAssertFalse(controller.loginRefreshPending)
    }
}
