import AppKit
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
        XCTAssertEqual(setup.skill.deletingLastPathComponent().lastPathComponent, "computer-use")
        XCTAssertTrue(text.hasPrefix("---\nname: computer-use\n"), "term-llm needs the folder's name")
        XCTAssertTrue(text.contains("Esc on the Mac"))
        XCTAssertEqual(setup.skillModule.path, setup.skill.deletingLastPathComponent().path + "/js/index.mjs")
        XCTAssertTrue(try String(contentsOf: setup.skillModule, encoding: .utf8).contains("export const computer"))
        XCTAssertTrue(text.contains("module: js/index.mjs"))
        // A stale or missing module means the skill needs installing again.
        try "// old".write(to: setup.skillModule, atomically: true, encoding: .utf8)
        XCTAssertFalse(setup.skillInstalled)
        try setup.installSkill()
        XCTAssertTrue(setup.skillInstalled)
        try FileManager.default.removeItem(at: setup.skill)
        try FileManager.default.createSymbolicLink(
            atPath: setup.skill.path, withDestinationPath: home.appendingPathComponent("untouched").path)
        XCTAssertThrowsError(try setup.installSkill())
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("untouched").path))
    }
    func testSkillStateTellsAnOldSkillFromAMissingOne() throws {
        XCTAssertEqual(setup.skillState, .missing)
        try setup.installSkill()
        XCTAssertEqual(setup.skillState, .installed)
        try "older instructions".write(to: setup.skill, atomically: true, encoding: .utf8)
        XCTAssertEqual(setup.skillState, .outdated)
        try setup.installSkill()
        try FileManager.default.removeItem(at: setup.skillModule)
        XCTAssertEqual(setup.skillState, .outdated, "A skill from before the module needs updating, not installing")
    }
    @discardableResult
    private func writeLegacySkill(extra: Bool = false) throws -> URL {
        let folder = setup.legacySkill.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("js"), withIntermediateDirectories: true)
        try "---\nname: term-llm-computer\ndescription: old\n---\n".write(to: setup.legacySkill, atomically: true, encoding: .utf8)
        try "// old".write(to: folder.appendingPathComponent("js/index.mjs"), atomically: true, encoding: .utf8)
        if extra { try "mine".write(to: folder.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8) }
        return folder
    }
    func testUpdatingReplacesTheSkillsOldName() throws {
        let folder = try writeLegacySkill()
        XCTAssertEqual(setup.skillState, .outdated, "The old name needs updating, not a fresh install")
        try setup.installSkill()
        XCTAssertEqual(setup.skillState, .installed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "Agents must not see two skills")

        // Someone else's file stays, and so does its folder; the old skill goes.
        try writeLegacySkill(extra: true)
        XCTAssertEqual(setup.skillState, .outdated, "An old copy left beside the new one still needs removing")
        try setup.installSkill()
        XCTAssertEqual(setup.skillState, .installed)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["notes.txt"])
    }
    func testOldNameIsLeftAloneUnlessItIsTheAppsOwnCopy() throws {
        let folder = setup.legacySkill.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "---\nname: something-else\n---\n".write(to: setup.legacySkill, atomically: true, encoding: .utf8)
        XCTAssertEqual(setup.skillState, .missing)
        try setup.installSkill()
        XCTAssertTrue(FileManager.default.fileExists(atPath: setup.legacySkill.path))
        try FileManager.default.removeItem(at: folder)

        let elsewhere = home.appendingPathComponent("dotfiles/term-llm-computer")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try "---\nname: term-llm-computer\n---\n".write(
            to: elsewhere.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: elsewhere)
        XCTAssertEqual(setup.skillState, .installed, "A linked folder is not the app's copy")
        try setup.installSkill()
        XCTAssertTrue(FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("SKILL.md").path))
    }
    func testIssuesPutGrantsFirstAndOnlyShowWhileEnabled() {
        let status = ComputerUseStatus(grants: ["Accessibility": true, "Screen Recording": false, "Input Monitoring": false])
        let files = ComputerUseSetup(commandInstalled: false, skill: .outdated)
        XCTAssertEqual(ComputerUseIssue.list(enabled: false, status: status, setup: files), [])
        XCTAssertEqual(
            ComputerUseIssue.list(enabled: true, status: status, setup: nil),
            [.grant("Input Monitoring"), .grant("Screen Recording")], "Unchecked files are not reported")
        XCTAssertEqual(
            ComputerUseIssue.list(enabled: true, status: status, setup: files),
            [.grant("Input Monitoring"), .grant("Screen Recording"), .command, .skillOutdated])
        XCTAssertEqual(
            ComputerUseIssue.list(
                enabled: true, status: ComputerUseStatus(grants: ["Accessibility": true]),
                setup: ComputerUseSetup(commandInstalled: true, skill: .missing)), [.skillMissing])
        XCTAssertEqual(
            ComputerUseIssue.list(
                enabled: true, status: ComputerUseStatus(), setup: ComputerUseSetup(commandInstalled: true, skill: .installed)), [])
        XCTAssertEqual(ComputerUseIssue.grant("Screen Recording").title, "Needs Screen Recording")
        XCTAssertEqual(ComputerUseIssue.grant("Screen Recording").action, "Allow…")
        XCTAssertEqual(ComputerUseIssue.skillOutdated.action, "Update Skill")
        XCTAssertEqual(ComputerUseIssue.grant("Something New").detail, "Something New isn't allowed.")
    }
    func testWindowCallsOutMissingFilesAtTheTopUntilFixed() async throws {
        try setup.setEnabled(true)
        let controller = ComputerUseController(home: home, state: setup.state, binary: setup.binary, suppressRuntime: true)
        XCTAssertEqual(controller.issues, [], "Nothing is called out before the files are checked")
        XCTAssertEqual(controller.icon, "terminal")
        let view = ComputerUseViewController(controller: controller)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = view
        defer { window.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func shown(_ text: String) -> NSView? {
            descendants(view.view).first {
                !$0.isHiddenOrHasHiddenAncestor
                    && (($0 as? NSTextField)?.stringValue == text || ($0 as? NSButton)?.title == text)
            }
        }
        controller.refreshInstallations()
        try await waitUntil("callout shown") { shown(ComputerUseIssue.skillMissing.detail) != nil }
        XCTAssertEqual(controller.issues, [.command, .skillMissing])
        XCTAssertEqual(controller.icon, "exclamationmark.triangle")
        view.view.layoutSubtreeIfNeeded()
        let callout = try XCTUnwrap(shown(ComputerUseIssue.skillMissing.detail))
        XCTAssertNotNil(shown("Install Command"))
        XCTAssertNotNil(shown(ComputerUseIssue.command.detail))
        let explanation = try XCTUnwrap(
            descendants(view.view).first { ($0 as? NSTextField)?.stringValue.hasPrefix("Let term-llm agents") == true })
        let top = { (child: NSView) in child.convert(child.bounds, to: nil).maxY }
        XCTAssertGreaterThan(top(callout), top(explanation), "The callout comes before the explanation")

        try setup.installCommand()
        try FileManager.default.createDirectory(
            at: setup.skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "older instructions".write(to: setup.skill, atomically: true, encoding: .utf8)
        controller.refreshInstallations()
        try await waitUntil("command installed") { shown("Update Skill") != nil && shown("Install Command") == nil }
        XCTAssertEqual(controller.issues, [.skillOutdated])
        try setup.installSkill()
        controller.refreshInstallations()
        try await waitUntil("callout hidden") { controller.issues.isEmpty && shown("Update Skill") == nil }
        XCTAssertNil(shown(ComputerUseIssue.skillOutdated.detail))
        XCTAssertEqual(controller.icon, "terminal")
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
