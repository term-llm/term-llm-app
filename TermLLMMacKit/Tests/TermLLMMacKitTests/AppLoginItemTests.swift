import XCTest
@testable import TermLLMMacKit

final class AppLoginItemTests: XCTestCase {
    private var home: URL!
    private var app: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("termllm-login-\(UUID().uuidString)", isDirectory: true)
        app = home.appendingPathComponent("Applications/term-llm.app/Contents/MacOS/TermLLMMac")
        try FileManager.default.createDirectory(at: app.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: app, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: app.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    func testEnableWritesOwnedPlistWithoutLaunchingNow() throws {
        let item = AppLoginItem(home: home)
        try item.enable(appExecutable: app)

        XCTAssertTrue(item.isEnabled)
        let data = try Data(contentsOf: item.plistURL)
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["Label"] as? String, AppLoginItem.label)
        XCTAssertEqual(plist[AppLoginItem.markerKey] as? String, AppLoginItem.markerValue)
        XCTAssertEqual(plist["ProgramArguments"] as? [String], [app.path])
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist["AssociatedBundleIdentifiers"] as? [String], ["com.termllm.app"])
        XCTAssertEqual(plist["KeepAlive"] as? Bool, false)
    }

    func testEnableRefusesForeignPlist() throws {
        let item = AppLoginItem(home: home)
        try FileManager.default.createDirectory(at: item.plistURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let foreign = try PropertyListSerialization.data(fromPropertyList: ["Label": AppLoginItem.label],
                                                          format: .xml, options: 0)
        try foreign.write(to: item.plistURL)

        XCTAssertThrowsError(try item.enable(appExecutable: app)) { error in
            guard case AppLoginItem.LoginItemError.foreignFile = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertFalse(item.isEnabled)
        XCTAssertEqual(try Data(contentsOf: item.plistURL), foreign)
    }

    func testDisableRemovesOnlyOwnedPlist() throws {
        let item = AppLoginItem(home: home)
        try item.enable(appExecutable: app)
        try item.disable()
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.plistURL.path))
    }

    func testDisableWhenAbsentIsNoOp() throws {
        let item = AppLoginItem(home: home)
        XCTAssertNoThrow(try item.disable())
    }

    func testDisableRefusesForeignPlist() throws {
        let item = AppLoginItem(home: home)
        try FileManager.default.createDirectory(at: item.plistURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("not a plist".utf8).write(to: item.plistURL)
        XCTAssertThrowsError(try item.disable())
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.plistURL.path))
    }

    func testRefreshRewritesOnlyWhenExecutableMoved() throws {
        let item = AppLoginItem(home: home)
        try item.enable(appExecutable: app)
        let movedApp = home.appendingPathComponent("Moved/TermLLMMac")
        try FileManager.default.createDirectory(at: movedApp.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: app, to: movedApp)

        item.refreshIfNeeded(appExecutable: movedApp)
        let data = try Data(contentsOf: item.plistURL)
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["ProgramArguments"] as? [String], [movedApp.path])
    }
    func testRefreshMigratesLegacyCompanionAssociationWithoutAnotherAgent() throws {
        let item = AppLoginItem(home: home)
        try item.enable(appExecutable: app)
        var plist = try XCTUnwrap(try PropertyListSerialization.propertyList(
            from: Data(contentsOf: item.plistURL), format: nil) as? [String: Any])
        plist["AssociatedBundleIdentifiers"] = ["com.termllm.companion"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: item.plistURL)
        item.refreshIfNeeded(appExecutable: app)
        let migrated = try XCTUnwrap(try PropertyListSerialization.propertyList(
            from: Data(contentsOf: item.plistURL), format: nil) as? [String: Any])
        XCTAssertEqual(migrated["ProgramArguments"] as? [String], [app.path])
        XCTAssertEqual(migrated["AssociatedBundleIdentifiers"] as? [String], ["com.termllm.app"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: item.plistURL.deletingLastPathComponent().path),
                       [AppLoginItem.label + ".plist"])
    }

    // MARK: - Open at Login registration

    func testEnableRegistersWithSystemInsteadOfLaunchAgent() throws {
        let system = FakeLoginService()
        let item = AppLoginItem(home: home, mainApp: system)
        try item.enable(appExecutable: app)
        XCTAssertEqual(system.calls, ["register"])
        XCTAssertTrue(item.isEnabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.plistURL.path),
                       "A registered app must not also appear as a background launch agent")
        try item.disable()
        XCTAssertEqual(system.calls, ["register", "unregister"])
        XCTAssertFalse(item.isEnabled)
    }

    func testUnsignedBuildFallsBackToLaunchAgent() throws {
        let system = FakeLoginService()
        system.failRegistration = true
        let item = AppLoginItem(home: home, mainApp: system)
        try item.enable(appExecutable: app)
        XCTAssertTrue(item.legacyEnabled)
        XCTAssertTrue(item.isEnabled)
    }

    func testRefreshMovesLegacyAgentToOpenAtLogin() throws {
        try AppLoginItem(home: home).enable(appExecutable: app)
        let system = FakeLoginService()
        let item = AppLoginItem(home: home, mainApp: system)
        item.refreshIfNeeded(appExecutable: app)
        XCTAssertEqual(system.status, .enabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.plistURL.path))
        // Nothing to move the next time, and no repeated registration.
        item.refreshIfNeeded(appExecutable: app)
        XCTAssertEqual(system.calls, ["register"])
    }

    func testRefreshNeverRegistersWithoutAnExistingPreference() {
        let system = FakeLoginService()
        AppLoginItem(home: home, mainApp: system).refreshIfNeeded(appExecutable: app)
        XCTAssertTrue(system.calls.isEmpty)
    }

    func testPendingApprovalCountsAsEnabled() throws {
        let system = FakeLoginService()
        system.statusAfterRegister = .requiresApproval
        let item = AppLoginItem(home: home, mainApp: system)
        try item.enable(appExecutable: app)
        XCTAssertTrue(item.isEnabled)
        XCTAssertTrue(item.needsApproval)
    }

    func testSystemRegistrationOnlyInsideTheApp() {
        XCTAssertNil(AppLoginItem.systemService, "A test runner must never register itself as a login item")
    }
}

private final class FakeLoginService: MainAppLoginService, @unchecked Sendable {
    var status: MainAppLoginStatus = .notRegistered
    var statusAfterRegister: MainAppLoginStatus = .enabled
    var failRegistration = false
    var calls: [String] = []

    func register() throws {
        calls.append("register")
        if failRegistration { throw NSError(domain: "SMAppServiceErrorDomain", code: 1) }
        status = statusAfterRegister
    }

    func unregister() throws {
        calls.append("unregister")
        status = .notRegistered
    }
}
