import Foundation
import XCTest

@testable import TermLLM

/// File fixtures only; never start the bundled helper or use the real home.
@MainActor
final class ComputerUseTests: XCTestCase {
    private var home: URL!
    private var setup: ComputerUseInstallation!
    override func setUp() async throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("computer-use-tests-\(UUID().uuidString)")
        setup = ComputerUseInstallation(
            home: home, state: home.appendingPathComponent("state"),
            binary: home.appendingPathComponent("term-llm.app/Contents/Helpers/term-llm-computer"))
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: home) }
    func testEnabledIsOffByDefaultAndUsesAFile() throws {
        XCTAssertFalse(setup.enabled)
        try setup.setEnabled(true)
        XCTAssertTrue(setup.enabled)
        let permissions = try FileManager.default.attributesOfItem(atPath: setup.state.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o700)
        try setup.setEnabled(false)
        XCTAssertFalse(setup.enabled)
    }
    func testInstallAndRepairAfterAppMoves() throws {
        try setup.installCommand()
        XCTAssertEqual(setup.linkDestination, setup.binary.path)
        let moved = ComputerUseInstallation(
            home: home, state: setup.state,
            binary: home.appendingPathComponent("Moved.app/Contents/Helpers/term-llm-computer"))
        try moved.installCommand(onlyIfOwned: true)
        XCTAssertEqual(moved.linkDestination, moved.binary.path)
        XCTAssertTrue(moved.linkIsCurrent)
    }
    func testRegularFileAndForeignDanglingLinkAreNeverReplaced() throws {
        try FileManager.default.createDirectory(
            at: setup.link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "mine".write(to: setup.link, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try setup.installCommand())
        try setup.installCommand(onlyIfOwned: true)
        XCTAssertEqual(try String(contentsOf: setup.link, encoding: .utf8), "mine")
        try FileManager.default.removeItem(at: setup.link)
        try FileManager.default.createSymbolicLink(
            atPath: setup.link.path, withDestinationPath: "/does/not/exist/term-llm-computer")
        XCTAssertThrowsError(try setup.installCommand())
        XCTAssertEqual(setup.linkDestination, "/does/not/exist/term-llm-computer")
    }
    func testRefreshDoesNotInstallAnAbsentLink() throws {
        try setup.installCommand(onlyIfOwned: true)
        XCTAssertNil(setup.linkDestination)
        XCTAssertFalse(FileManager.default.fileExists(atPath: setup.state.path))
    }
    func testSkillInstallAndLinkRefusal() throws {
        try setup.installSkill()
        XCTAssertTrue(setup.skillInstalled)
        let text = try String(contentsOf: setup.skill, encoding: .utf8)
        XCTAssertTrue(text.contains("name: term-llm-computer"))
        XCTAssertTrue(text.contains("Esc on the Mac"))
        try FileManager.default.removeItem(at: setup.skill)
        try FileManager.default.createSymbolicLink(
            atPath: setup.skill.path, withDestinationPath: home.appendingPathComponent("untouched").path)
        XCTAssertThrowsError(try setup.installSkill())
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("untouched").path))
    }
    func testHostedFixtureControllerNeverEnablesOrLaunches() {
        let controller = ComputerUseController(
            home: home, state: setup.state, binary: setup.binary, suppressRuntime: true)
        controller.start()
        controller.setEnabled(true)
        controller.send("allow", grant: "Accessibility")
        controller.shutdownForApplicationQuit()
        XCTAssertFalse(controller.enabled)
        XCTAssertFalse(setup.enabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: setup.state.path))
    }
}
