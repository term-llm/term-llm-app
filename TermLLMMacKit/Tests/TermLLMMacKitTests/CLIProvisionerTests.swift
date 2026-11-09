import XCTest
@testable import TermLLMMacKit

final class CLIProvisionerTests: XCTestCase {
    private var home: URL!
    private var payloadDirectory: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("termllm-cli-\(UUID().uuidString)", isDirectory: true)
        payloadDirectory = home.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(at: payloadDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func makePayload(_ contents: String, name: String = "term-llm") throws -> URL {
        let url = payloadDirectory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testVerifiedReleaseInstallWritesManifestAndBinaryOutsideApp() throws {
        var provisioner = CLIProvisioner(home: home)
        let payload = try makePayload("#!/bin/sh\necho test\n")
        let selection = try provisioner.installFixture(binary: payload, version: "1.2.3")

        XCTAssertEqual(selection.source, .release)
        XCTAssertEqual(selection.version, "1.2.3")
        XCTAssertEqual(selection.binaryPath, provisioner.managedBinary.path)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: provisioner.managedBinary.path))
        XCTAssertFalse(selection.binaryPath.contains(".app/"))

        let loaded = try XCTUnwrap(try provisioner.loadSelection().get())
        XCTAssertEqual(loaded, selection)
        XCTAssertEqual(try CLIProvisioner.sha256(of: provisioner.managedBinary), selection.sha256)
        XCTAssertTrue(provisioner.problems(in: loaded).isEmpty)
    }

    func testVerifiedReleaseInstallWritesManagedOwnershipMarker() throws {
        var provisioner = CLIProvisioner(home: home)
        let payload = try makePayload("#!/bin/sh\necho test\n")
        _ = try provisioner.installFixture(binary: payload, version: "1")
        XCTAssertTrue(provisioner.managedMarkerPresent)
        let data = try Data(contentsOf: provisioner.managedMarkerURL)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["owner"] as? String, "the term-llm app")
        XCTAssertEqual(json["schema_version"] as? Int, 1)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("TermLLM.app"),
                       "term-llm upgrade shows this text; the product is only ever called term-llm")
    }

    func testOlderMarkerWordingIsRefreshedWithoutChangingOwnership() throws {
        var provisioner = CLIProvisioner(home: home)
        _ = try provisioner.installFixture(binary: try makePayload("#!/bin/sh\necho test\n"), version: "1")
        let older = #"{"schema_version":1,"owner":"TermLLM.app","app_bundle_id":"com.termllm.app","update_hint":"Update it from TermLLM.app."}"#
        try Data(older.utf8).write(to: provisioner.managedMarkerURL)
        try provisioner.refreshManagedMarkerWording()
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(contentsOf: provisioner.managedMarkerURL)) as? [String: Any])
        XCTAssertEqual(json["owner"] as? String, "the term-llm app")
        XCTAssertEqual(json["app_bundle_id"] as? String, "com.termllm.app")
        XCTAssertEqual(json["schema_version"] as? Int, 1)
        XCTAssertTrue((json["update_hint"] as? String)?.hasPrefix("Update it from the term-llm app.") == true)

        // Someone else's marker, or none at all, is left exactly as it is.
        let foreign = #"{"schema_version":1,"owner":"Homebrew","update_hint":"brew upgrade term-llm"}"#
        try Data(foreign.utf8).write(to: provisioner.managedMarkerURL)
        try provisioner.refreshManagedMarkerWording()
        XCTAssertEqual(try String(contentsOf: provisioner.managedMarkerURL, encoding: .utf8), foreign)
        try FileManager.default.removeItem(at: provisioner.managedMarkerURL)
        try provisioner.refreshManagedMarkerWording()
        XCTAssertFalse(provisioner.managedMarkerPresent)
    }

    func testRemoveManagedInstallRemovesMarker() throws {
        var provisioner = CLIProvisioner(home: home)
        let payload = try makePayload("#!/bin/sh\necho test\n")
        _ = try provisioner.installFixture(binary: payload, version: "1")
        XCTAssertTrue(provisioner.managedMarkerPresent)
        _ = try provisioner.removeManagedInstall()
        XCTAssertFalse(provisioner.managedMarkerPresent)
    }

    func testChecksumMismatchKeepsPreviousInstallation() throws {
        var provisioner = CLIProvisioner(home: home)
        let first = try makePayload("#!/bin/sh\necho one\n")
        let selection = try provisioner.installFixture(binary: first, version: "1")
        let second = try makePayload("#!/bin/sh\necho two\n")

        XCTAssertThrowsError(try provisioner.installFixture(binary: second,
                                                             version: "2",
                                                             expectedSHA256: String(repeating: "0", count: 64))) { error in
            guard case CLIProvisionerError.checksumMismatch = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try CLIProvisioner.sha256(of: provisioner.managedBinary), selection.sha256)
        XCTAssertEqual(try provisioner.loadSelection().get(), selection)
    }

    func testEmptyPayloadRejected() throws {
        var provisioner = CLIProvisioner(home: home)
        let payload = try makePayload("")
        XCTAssertThrowsError(try provisioner.installFixture(binary: payload, version: "x")) { error in
            guard case CLIProvisionerError.candidateInvalid = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertNil(try provisioner.loadSelection().get())
    }

    func testReinstallCopiesBackupAndReplacesBinary() throws {
        var provisioner = CLIProvisioner(home: home)
        let first = try makePayload("#!/bin/sh\necho one\n")
        let second = try makePayload("#!/bin/sh\necho two\n")
        let firstSelection = try provisioner.installFixture(binary: first, version: "1")
        let secondSelection = try provisioner.installFixture(binary: second, version: "2")

        XCTAssertEqual(try CLIProvisioner.sha256(of: provisioner.managedBinary), secondSelection.sha256)
        let backups = try FileManager.default.contentsOfDirectory(at: provisioner.backupDirectory,
                                                                  includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 1)
        let backupBinary = backups[0].appendingPathComponent("term-llm")
        XCTAssertEqual(try CLIProvisioner.sha256(of: backupBinary), firstSelection.sha256)
    }

    func testFinalisationFailureRestoresPreviousBinaryManifestAndMarker() throws {
        var provisioner = CLIProvisioner(home: home)
        let first = try makePayload("#!/bin/sh\necho one\n")
        let second = try makePayload("#!/bin/sh\necho two\n")
        let selection = try provisioner.installFixture(binary: first, version: "1")
        let manifestBefore = try Data(contentsOf: provisioner.manifestURL)
        let markerBefore = try Data(contentsOf: provisioner.managedMarkerURL)

        provisioner.failurePoint = .afterMarker
        XCTAssertThrowsError(try provisioner.installFixture(binary: second, version: "2"))
        provisioner.failurePoint = nil

        XCTAssertEqual(try CLIProvisioner.sha256(of: provisioner.managedBinary), selection.sha256)
        XCTAssertEqual(try Data(contentsOf: provisioner.manifestURL), manifestBefore)
        XCTAssertEqual(try Data(contentsOf: provisioner.managedMarkerURL), markerBefore)
        XCTAssertEqual(try provisioner.loadSelection().get(), selection)
    }

    func testFailureAfterReplaceRestoresPreviousBinaryAndMarker() throws {
        var provisioner = CLIProvisioner(home: home)
        let first = try makePayload("#!/bin/sh\necho one\n")
        let second = try makePayload("#!/bin/sh\necho two\n")
        let selection = try provisioner.installFixture(binary: first, version: "1")
        let markerBefore = try Data(contentsOf: provisioner.managedMarkerURL)

        provisioner.failurePoint = .afterReplace
        XCTAssertThrowsError(try provisioner.installFixture(binary: second, version: "2"))
        provisioner.failurePoint = nil

        XCTAssertEqual(try CLIProvisioner.sha256(of: provisioner.managedBinary), selection.sha256)
        XCTAssertEqual(try Data(contentsOf: provisioner.managedMarkerURL), markerBefore)
        XCTAssertEqual(try provisioner.loadSelection().get(), selection)
    }

    func testFailedInstallLeavesNoStagingFiles() throws {
        var provisioner = CLIProvisioner(home: home)
        let payload = try makePayload("#!/bin/sh\necho one\n")
        provisioner.failurePoint = .afterMarker
        XCTAssertThrowsError(try provisioner.installFixture(binary: payload, version: "1"))
        provisioner.failurePoint = nil
        let entries = try FileManager.default.contentsOfDirectory(atPath: provisioner.binDirectory.path)
        XCTAssertTrue(entries.filter { $0.contains(".staging-") }.isEmpty,
                      "temporary staging files must not survive a failed install")
    }

    func testBackupPruningKeepsNewestThree() throws {
        var provisioner = CLIProvisioner(home: home)
        for index in 1...5 {
            let payload = try makePayload("#!/bin/sh\necho version-#{index}\n")
            _ = try provisioner.installFixture(binary: payload, version: "\(index)")
        }
        let backups = try FileManager.default.contentsOfDirectory(at: provisioner.backupDirectory,
                                                                  includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 3)
    }

    func testFailureBeforeReplaceLeavesPreviousInstallationUntouched() throws {
        var provisioner = CLIProvisioner(home: home)
        let first = try makePayload("#!/bin/sh\necho one\n")
        let second = try makePayload("#!/bin/sh\necho two\n")
        let selection = try provisioner.installFixture(binary: first, version: "1")
        let manifestBefore = try Data(contentsOf: provisioner.manifestURL)

        provisioner.failurePoint = .beforeReplace
        XCTAssertThrowsError(try provisioner.installFixture(binary: second, version: "2"))
        provisioner.failurePoint = nil

        XCTAssertEqual(try CLIProvisioner.sha256(of: provisioner.managedBinary), selection.sha256)
        XCTAssertEqual(try Data(contentsOf: provisioner.manifestURL), manifestBefore)
    }

    func testFailedFirstInstallLeavesNoBinaryManifestOrMarker() throws {
        var provisioner = CLIProvisioner(home: home)
        let payload = try makePayload("#!/bin/sh\necho one\n")
        provisioner.failurePoint = .afterMarker
        XCTAssertThrowsError(try provisioner.installFixture(binary: payload, version: "1"))
        provisioner.failurePoint = nil

        XCTAssertFalse(FileManager.default.fileExists(atPath: provisioner.managedBinary.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: provisioner.manifestURL.path))
        XCTAssertFalse(provisioner.managedMarkerPresent)
        XCTAssertNil(try provisioner.loadSelection().get())
    }

    func testPATHLinkIsCreatedAndRefreshIsIdempotent() throws {
        var provisioner = CLIProvisioner(home: home)
        let payload = try makePayload("#!/bin/sh\necho test\n")
        let selection = try provisioner.installFixture(binary: payload, version: "1")
        if case .notLinked = provisioner.inspectPATHLink(for: selection) {
            // expected before the app creates the link
        } else {
            XCTFail("a fresh install should not claim a PATH link")
        }

        guard case .linked(let path) = provisioner.syncPATHLink(for: selection) else {
            return XCTFail("expected a new link")
        }
        XCTAssertEqual(path, provisioner.pathLink.path)
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: provisioner.pathLink.path)
        XCTAssertEqual(URL(fileURLWithPath: destination).standardizedFileURL.path,
                       provisioner.managedBinary.standardizedFileURL.path)

        guard case .alreadyLinked = provisioner.syncPATHLink(for: selection) else {
            return XCTFail("expected the existing link to be recognised")
        }
    }

    func testForeignPATHFileIsNeverReplaced() throws {
        var provisioner = CLIProvisioner(home: home)
        let payload = try makePayload("#!/bin/sh\necho test\n")
        let selection = try provisioner.installFixture(binary: payload, version: "1")
        try FileManager.default.createDirectory(at: provisioner.pathLink.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "#!/bin/sh\necho foreign\n".write(to: provisioner.pathLink, atomically: true, encoding: .utf8)

        guard case .collision(let path) = provisioner.syncPATHLink(for: selection) else {
            return XCTFail("expected a collision")
        }
        XCTAssertEqual(path, provisioner.pathLink.path)
        XCTAssertEqual(try String(contentsOf: provisioner.pathLink, encoding: .utf8),
                       "#!/bin/sh\necho foreign\n")
    }

    func testLegacySelectionsDecodeForMigrationOnly() throws {
        let provisioner = CLIProvisioner(home: home)
        try FileManager.default.createDirectory(at: provisioner.supportDirectory, withIntermediateDirectories: true)
        for source in ["external", "bundled"] {
            let json = """
            {"schemaVersion":1,"source":"\(source)","binaryPath":"/never-execute-me","version":"","sha256":"","installedAt":"2026-11-01T00:00:00Z","provenance":"Legacy"}
            """
            try Data(json.utf8).write(to: provisioner.manifestURL)
            XCTAssertEqual(try provisioner.loadSelection().get()?.schemaVersion, 1)
            if source == "external" {
                XCTAssertTrue(ConflictScanner(provisioner: provisioner, searchDirectories: []).scan().contains(.legacyExternalSelection(path: "/never-execute-me")))
            }
        }
    }

    func testRollbackRestoresMatchingManifestMarkerAndBinary() throws {
        let p = CLIProvisioner(home: home)
        let first = try makePayload("one")
        let before = try p.installFixture(binary: first, version: "0.9.94")
        let marker = try Data(contentsOf: p.managedMarkerURL)
        let second = try makePayload("two")
        _ = try p.installFixture(binary: second, version: "0.9.95")
        _ = try p.rollbackToPrevious()
        XCTAssertEqual(try p.loadSelection().get(), before)
        XCTAssertEqual(try Data(contentsOf: p.managedMarkerURL), marker)
        XCTAssertEqual(try CLIProvisioner.sha256(of: p.managedBinary), before.sha256)
    }

    func testDeveloperModeDisablesManagementAndLeavesMarkerAlone() throws {
        let p = CLIProvisioner(home: home)
        let binary = try makePayload("fixture")
        let store = DeveloperModeStore(provisioner: p)
        try store.enable(binary: binary)
        XCTAssertEqual(try store.load(), binary)
        XCTAssertThrowsError(try p.installFixture(binary: binary, version: "1"))
        XCTAssertThrowsError(try p.handOver())
        XCTAssertThrowsError(try p.removeManagedInstall())
        XCTAssertFalse(p.managedMarkerPresent)
        try store.disable()
        XCTAssertNil(try store.load())
    }

    func testRollbackUsesNewestBackupAndIsTransactionalOnFailure() throws {
        var p = CLIProvisioner(home: home)
        let one = try makePayload("one")
        _ = try p.installFixture(binary: one, version: "0.9.94")
        let two = try makePayload("two")
        let previous = try p.installFixture(binary: two, version: "0.9.95")
        let three = try makePayload("three")
        let current = try p.installFixture(binary: three, version: "0.9.96")
        let marker = try Data(contentsOf: p.managedMarkerURL)
        p.failurePoint = .afterMarker
        XCTAssertThrowsError(try p.rollbackToPrevious())
        XCTAssertEqual(try p.loadSelection().get(), current)
        XCTAssertEqual(try CLIProvisioner.sha256(of: p.managedBinary), current.sha256)
        XCTAssertEqual(try Data(contentsOf: p.managedMarkerURL), marker)
        p.failurePoint = nil
        _ = try p.rollbackToPrevious()
        XCTAssertEqual(try p.loadSelection().get(), previous)
    }

    func testCorruptDeveloperSettingFailsClosedUntilDisabled() throws {
        let p = CLIProvisioner(home: home)
        let binary = try makePayload("fixture")
        let selected = try p.installFixture(binary: binary, version: "0.9.94")
        let store = DeveloperModeStore(provisioner: p)
        try Data("not-json".utf8).write(to: store.url)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try p.handOver())
        if case .notLinked = p.syncPATHLink(for: selected) {} else { XCTFail("Developer Mode must never write PATH") }
        XCTAssertFalse(ConflictScanner.exists(p.pathLink))
        XCTAssertTrue(p.managedMarkerPresent)
        try store.disable()
        XCTAssertNil(try store.load())
    }

    func testRemoveManagedInstallClearsOwnedFiles() throws {
        var provisioner = CLIProvisioner(home: home)
        let payload = try makePayload("#!/bin/sh\necho test\n")
        _ = try provisioner.installFixture(binary: payload, version: "1")
        XCTAssertTrue(try provisioner.removeManagedInstall())
        XCTAssertFalse(FileManager.default.fileExists(atPath: provisioner.managedBinary.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: provisioner.pathLink.path))
        XCTAssertNil(try provisioner.loadSelection().get())
    }
}

// Provisioner transaction tests intentionally bypass signature verification.
// ReleaseInstallerTests exercise the security boundary before this API.
extension CLIProvisioner {
    func installFixture(binary: URL, version: String, expectedSHA256: String? = nil) throws -> CLISelection {
        try installVerified(binary: binary, version: version,
                            sha256: expectedSHA256 ?? Self.sha256(of: binary), provenance: "Test fixture")
    }
}
