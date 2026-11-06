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

    func testBundledInstallWritesManifestAndBinaryOutsideApp() throws {
        var provisioner = CLIProvisioner(home: home)
        let payload = try makePayload("#!/bin/sh\necho test\n")
        let selection = try provisioner.installBundled(payload: payload, version: "1.2.3")

        XCTAssertEqual(selection.source, .bundled)
        XCTAssertEqual(selection.version, "1.2.3")
        XCTAssertEqual(selection.binaryPath, provisioner.managedBinary.path)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: provisioner.managedBinary.path))
        XCTAssertFalse(selection.binaryPath.contains(".app/"))

        let loaded = try XCTUnwrap(try provisioner.loadSelection().get())
        XCTAssertEqual(loaded, selection)
        XCTAssertEqual(try CLIProvisioner.sha256(of: provisioner.managedBinary), selection.sha256)
        XCTAssertTrue(provisioner.problems(in: loaded).isEmpty)
    }

    func testBundledInstallWritesManagedOwnershipMarker() throws {
        var provisioner = CLIProvisioner(home: home)
        let payload = try makePayload("#!/bin/sh\necho test\n")
        _ = try provisioner.installBundled(payload: payload, version: "1")
        XCTAssertTrue(provisioner.managedMarkerPresent)
        let data = try Data(contentsOf: provisioner.managedMarkerURL)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["owner"] as? String, "term-llm macOS companion")
        XCTAssertEqual(json["schema_version"] as? Int, 1)
    }

    func testRemoveManagedInstallRemovesMarker() throws {
        var provisioner = CLIProvisioner(home: home)
        let payload = try makePayload("#!/bin/sh\necho test\n")
        _ = try provisioner.installBundled(payload: payload, version: "1")
        XCTAssertTrue(provisioner.managedMarkerPresent)
        _ = try provisioner.removeManagedInstall()
        XCTAssertFalse(provisioner.managedMarkerPresent)
    }

    func testChecksumMismatchKeepsPreviousInstallation() throws {
        var provisioner = CLIProvisioner(home: home)
        let first = try makePayload("#!/bin/sh\necho one\n")
        let selection = try provisioner.installBundled(payload: first, version: "1")
        let second = try makePayload("#!/bin/sh\necho two\n")

        XCTAssertThrowsError(try provisioner.installBundled(payload: second,
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
        XCTAssertThrowsError(try provisioner.installBundled(payload: payload, version: "x")) { error in
            guard case CLIProvisionerError.payloadInvalid = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertNil(try provisioner.loadSelection().get())
    }

    func testReinstallCopiesBackupAndReplacesBinary() throws {
        var provisioner = CLIProvisioner(home: home)
        let first = try makePayload("#!/bin/sh\necho one\n")
        let second = try makePayload("#!/bin/sh\necho two\n")
        let firstSelection = try provisioner.installBundled(payload: first, version: "1")
        let secondSelection = try provisioner.installBundled(payload: second, version: "2")

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
        let selection = try provisioner.installBundled(payload: first, version: "1")
        let manifestBefore = try Data(contentsOf: provisioner.manifestURL)
        let markerBefore = try Data(contentsOf: provisioner.managedMarkerURL)

        provisioner.failurePoint = .afterMarker
        XCTAssertThrowsError(try provisioner.installBundled(payload: second, version: "2"))
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
        let selection = try provisioner.installBundled(payload: first, version: "1")
        let markerBefore = try Data(contentsOf: provisioner.managedMarkerURL)

        provisioner.failurePoint = .afterReplace
        XCTAssertThrowsError(try provisioner.installBundled(payload: second, version: "2"))
        provisioner.failurePoint = nil

        XCTAssertEqual(try CLIProvisioner.sha256(of: provisioner.managedBinary), selection.sha256)
        XCTAssertEqual(try Data(contentsOf: provisioner.managedMarkerURL), markerBefore)
        XCTAssertEqual(try provisioner.loadSelection().get(), selection)
    }

    func testFailedInstallLeavesNoStagingFiles() throws {
        var provisioner = CLIProvisioner(home: home)
        let payload = try makePayload("#!/bin/sh\necho one\n")
        provisioner.failurePoint = .afterMarker
        XCTAssertThrowsError(try provisioner.installBundled(payload: payload, version: "1"))
        provisioner.failurePoint = nil
        let entries = try FileManager.default.contentsOfDirectory(atPath: provisioner.binDirectory.path)
        XCTAssertTrue(entries.filter { $0.contains(".staging-") }.isEmpty,
                      "temporary staging files must not survive a failed install")
    }

    func testBackupPruningKeepsNewestThree() throws {
        var provisioner = CLIProvisioner(home: home)
        for index in 1...5 {
            let payload = try makePayload("#!/bin/sh\necho version-#{index}\n")
            _ = try provisioner.installBundled(payload: payload, version: "\(index)")
        }
        let backups = try FileManager.default.contentsOfDirectory(at: provisioner.backupDirectory,
                                                                  includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 3)
    }

    func testFailureBeforeReplaceLeavesPreviousInstallationUntouched() throws {
        var provisioner = CLIProvisioner(home: home)
        let first = try makePayload("#!/bin/sh\necho one\n")
        let second = try makePayload("#!/bin/sh\necho two\n")
        let selection = try provisioner.installBundled(payload: first, version: "1")
        let manifestBefore = try Data(contentsOf: provisioner.manifestURL)

        provisioner.failurePoint = .beforeReplace
        XCTAssertThrowsError(try provisioner.installBundled(payload: second, version: "2"))
        provisioner.failurePoint = nil

        XCTAssertEqual(try CLIProvisioner.sha256(of: provisioner.managedBinary), selection.sha256)
        XCTAssertEqual(try Data(contentsOf: provisioner.manifestURL), manifestBefore)
    }

    func testFailedFirstInstallLeavesNoBinaryManifestOrMarker() throws {
        var provisioner = CLIProvisioner(home: home)
        let payload = try makePayload("#!/bin/sh\necho one\n")
        provisioner.failurePoint = .afterMarker
        XCTAssertThrowsError(try provisioner.installBundled(payload: payload, version: "1"))
        provisioner.failurePoint = nil

        XCTAssertFalse(FileManager.default.fileExists(atPath: provisioner.managedBinary.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: provisioner.manifestURL.path))
        XCTAssertFalse(provisioner.managedMarkerPresent)
        XCTAssertNil(try provisioner.loadSelection().get())
    }

    func testPATHLinkIsCreatedAndRefreshIsIdempotent() throws {
        var provisioner = CLIProvisioner(home: home)
        let payload = try makePayload("#!/bin/sh\necho test\n")
        let selection = try provisioner.installBundled(payload: payload, version: "1")
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
        let selection = try provisioner.installBundled(payload: payload, version: "1")
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

    func testAdoptExternalNeverCopiesOrLinks() throws {
        var provisioner = CLIProvisioner(home: home)
        let external = try makePayload("#!/bin/sh\necho brew\n", name: "external-term-llm")
        let selection = try provisioner.adoptExternal(ExternalCLI(path: external.path,
                                                                  resolvedPath: external.path,
                                                                  version: "9.9.9",
                                                                  provenance: "Homebrew"))

        XCTAssertEqual(selection.source, .external)
        XCTAssertEqual(selection.binaryPath, external.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: provisioner.managedBinary.path))
        if case .skippedExternal = provisioner.syncPATHLink(for: selection) {
            // expected
        } else {
            XCTFail("external installs must not be linked")
        }
        XCTAssertEqual(try provisioner.loadSelection().get()?.binaryPath, external.path)
    }

    func testDetectExternalSkipsManagedPaths() throws {
        var provisioner = CLIProvisioner(home: home)
        let bin = home.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let external = bin.appendingPathComponent("term-llm")
        try "#!/bin/sh\necho external\n".write(to: external, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: external.path)

        let results = provisioner.detectExternal(includeVersions: false, searchDirectories: [bin.path])
        XCTAssertEqual(results.map(\.path), [external.path])
        XCTAssertEqual(results.first?.provenance, "Existing install")
    }

    func testRemoveManagedInstallLeavesExternalSelectionStateClean() throws {
        var provisioner = CLIProvisioner(home: home)
        let payload = try makePayload("#!/bin/sh\necho test\n")
        _ = try provisioner.installBundled(payload: payload, version: "1")
        XCTAssertTrue(try provisioner.removeManagedInstall())
        XCTAssertFalse(FileManager.default.fileExists(atPath: provisioner.managedBinary.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: provisioner.pathLink.path))
        XCTAssertNil(try provisioner.loadSelection().get())
    }
}
