import XCTest
@testable import TermLLMMacKit

final class SupportDirectoryMigrationTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("termllm-move-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    /// An install made by an earlier build: old location, old paths recorded inside.
    private func makeEarlierInstall() throws -> CLIProvisioner {
        var provisioner = CLIProvisioner(home: home)
        let payload = home.appendingPathComponent("payload/term-llm")
        try FileManager.default.createDirectory(at: payload.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\necho test\n".write(to: payload, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: payload.path)
        _ = try provisioner.installFixture(binary: payload, version: "1.2.3")
        let new = provisioner.supportDirectory, old = provisioner.legacySupportDirectory
        try FileManager.default.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: new, to: old)
        for name in ["install.json", "bin/term-llm.managed.json"] {
            let url = old.appendingPathComponent(name)
            var changed = false
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            let earlier = CLIProvisioner.replacingPath(in: object, from: new.path, to: old.path, changed: &changed)
            XCTAssertTrue(changed, name)
            try JSONSerialization.data(withJSONObject: earlier).write(to: url)
        }
        return provisioner
    }

    func testEarlierFilesMoveNextToTermLLMSettingsWithTheirPathsRewritten() throws {
        let provisioner = try makeEarlierInstall()
        let old = provisioner.legacySupportDirectory
        let link = provisioner.pathLink
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path,
                                                   withDestinationPath: old.appendingPathComponent("bin/term-llm").path)

        XCTAssertTrue(try provisioner.migrateLegacySupportDirectory())

        XCTAssertEqual(provisioner.supportDirectory.path, home.appendingPathComponent(".config/term-llm/app").path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "Nothing is left at the old location")
        let selection = try XCTUnwrap(try provisioner.loadSelection().get())
        XCTAssertEqual(selection.binaryPath, provisioner.managedBinary.path)
        XCTAssertTrue(provisioner.problems(in: selection).isEmpty)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), provisioner.managedBinary.path,
                       "The Terminal command follows the move")
        let marker = try String(contentsOf: provisioner.managedMarkerURL, encoding: .utf8)
        XCTAssertFalse(marker.contains("Application Support"), marker)
        XCTAssertFalse(try provisioner.migrateLegacySupportDirectory(), "Files move once")
    }

    func testAServiceStillOnTheOldPathKeepsWorkingUntilNothingNamesIt() throws {
        let provisioner = try makeEarlierInstall()
        let old = provisioner.legacySupportDirectory
        let oldBinary = old.appendingPathComponent("bin/term-llm").path
        let agents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let plist = agents.appendingPathComponent("com.term-llm.web.plist")
        let definition: [String: Any] = ["Label": "com.term-llm.web", "ProgramArguments": [oldBinary, "service", "run"]]
        try PropertyListSerialization.data(fromPropertyList: definition, format: .xml, options: 0).write(to: plist)

        XCTAssertTrue(try provisioner.migrateLegacySupportDirectory())
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: old.path), provisioner.supportDirectory.path)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: oldBinary), "The service can still start")

        // term-llm's own service spec records the binary as well.
        try FileManager.default.removeItem(at: plist)
        let spec = home.appendingPathComponent(".config/term-llm/services/web/service.json")
        try FileManager.default.createDirectory(at: spec.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["binary": oldBinary]).write(to: spec)
        XCTAssertFalse(try provisioner.migrateLegacySupportDirectory())
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: old.path))

        try FileManager.default.removeItem(at: spec)
        XCTAssertFalse(try provisioner.migrateLegacySupportDirectory())
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: old.path), "The link goes once unused")
        XCTAssertTrue(FileManager.default.fileExists(atPath: provisioner.managedBinary.path))
    }

    func testNothingMovesWithoutAnEarlierInstallOrOntoANewerOne() throws {
        let provisioner = CLIProvisioner(home: home)
        XCTAssertFalse(try provisioner.migrateLegacySupportDirectory())
        XCTAssertFalse(FileManager.default.fileExists(atPath: provisioner.supportDirectory.path),
                       "Remote-only use creates no folder")
        try FileManager.default.createDirectory(at: provisioner.legacySupportDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: provisioner.supportDirectory, withIntermediateDirectories: true)
        XCTAssertFalse(try provisioner.migrateLegacySupportDirectory(), "An existing folder is never replaced")
        XCTAssertTrue(FileManager.default.fileExists(atPath: provisioner.legacySupportDirectory.path))
    }
}
