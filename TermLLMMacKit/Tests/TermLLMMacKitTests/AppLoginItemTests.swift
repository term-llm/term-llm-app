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
}
