import Foundation
import XCTest
@testable import TermLLMMacKit

/// Stateful core contract fixture. All commands are FakeCommandRunner calls;
/// tar is the only subprocess, and all files live below a temporary home.
final class OwnershipFixture {
    let release: ReleaseFixture
    var binaries: [String: String] = [:]
    var running: Set<String> = ["web"]
    var supportsRebind = true
    var supportsReload = true
    var failVerification = false
    var unhealthyReload = false
    /// Status polls after a reload that see the successor's start-up gap.
    var transientUnhealthyPolls = 0
    var tokenAvailable = false
    var reloaded = false
    init() throws {
        release = try ReleaseFixture()
        let runner = release.runner
        let fallback = runner.handler!
        runner.handler = { [unowned self] exe, args, env in
            if exe.path == "/usr/bin/tar" || args == ["--version"] || exe.path.contains("/staging/") { return try fallback(exe, args, env) }
            let ok = CommandResult(status: 0, stdout: "", stderr: "")
            // Like 0.9.94, a CLI without the subcommand prints the parent help and exits 0.
            if args == ["service", "rebind", "--help"] { return ServiceHelpFixtures.help(for: "rebind", supported: self.supportsRebind) }
            if args == ["service", "reload", "--help"] { return ServiceHelpFixtures.help(for: "reload", supported: self.supportsReload) }
            if args.count >= 3 {
                let kind = args[2]
                switch args[1] {
                case "status":
                    var binary = self.binaries[kind]
                    if self.failVerification, binary == self.release.provisioner.managedBinary.path { binary = self.release.binary.path }
                    var state = self.unhealthyReload && self.reloaded ? "unhealthy" : (self.running.contains(kind) ? "ready" : "stopped")
                    if self.reloaded && self.transientUnhealthyPolls > 0 {
                        self.transientUnhealthyPolls -= 1
                        state = "unhealthy"
                    }
                    let obj: [String: Any] = ["schema_version": 1, "services": [["kind": kind, "installed": binary != nil,
                        "managed": true, "registered": binary != nil, "state": binary == nil ? "not_installed" : state,
                        "running": self.running.contains(kind), "autostart": true, "binary": binary ?? "", "auth": "bearer",
                        "enrollment": "not_required", "healthy": state == "ready"]]]
                    return CommandResult(status: 0, stdout: String(decoding: try JSONSerialization.data(withJSONObject: obj), as: UTF8.self), stderr: "")
                case "rebind": self.binaries[kind] = args.last!; return ok
                case "reload": self.reloaded = true; return ok
                case "restart": self.reloaded = false; return ok
                case "token": return CommandResult(status: self.tokenAvailable ? 0 : 1, stdout: self.tokenAvailable ? "synthetic-fixture-token-only" : "", stderr: "unavailable") // no Keychain
                case "uninstall": self.binaries[kind] = nil; return ok
                default: break
                }
            }
            XCTFail("Unexpected fixture command: \(args)"); return CommandResult(status: 99, stdout: "", stderr: "")
        }
    }
    func cleanup() { release.cleanup() }
    func installOld() throws {
        _ = try release.provisioner.installFixture(binary: release.binary, version: "0.9.94")
    }
    func manager() throws -> MigrationManager {
        MigrationManager(provisioner: release.provisioner, installer: try release.installer())
    }
    func updater() throws -> CLIUpdater {
        var updater = try CLIUpdater(provisioner: release.provisioner, installer: release.installer())
        updater.reloadTimeout = 0.05; updater.pollInterval = 0.001
        updater.unconfirmedSettle = 0; updater.failureGrace = 0.01
        return updater
    }
}

final class OwnershipTests: XCTestCase {
    var fixture: OwnershipFixture!
    override func setUpWithError() throws { fixture = try OwnershipFixture() }
    override func tearDownWithError() throws { fixture.cleanup(); fixture = nil }
    func testReadOnlyConflictScanAndFakeCellarPaths() throws {
        let p = fixture.release.provisioner
        let bin = fixture.release.home.appendingPathComponent("brew/bin")
        let cellar = fixture.release.home.appendingPathComponent("brew/Cellar/term-llm/1/term-llm")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cellar.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: cellar)
        try FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent("term-llm").path, withDestinationPath: cellar.path)
        try FileManager.default.createDirectory(at: p.pathLink.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: p.pathLink.path, withDestinationPath: "/nonexistent/foreign")
        let conflicts = ConflictScanner(provisioner: p, searchDirectories: [bin, p.pathLink.deletingLastPathComponent()], homebrewBinDirectories: [bin]).scan()
        XCTAssertTrue(conflicts.contains(.homebrewFormula(path: bin.appendingPathComponent("term-llm").path)))
        XCTAssertTrue(conflicts.contains(.pathLinkOccupied(path: p.pathLink.path, target: "/nonexistent/foreign")))
        XCTAssertTrue(fixture.release.runner.calls.isEmpty)
        XCTAssertFalse(p.managedMarkerPresent)
    }
    func testIndirectManagedLinkStillRequiresExplicitPATHMigration() throws {
        try fixture.installOld()
        let p = fixture.release.provisioner
        let indirect = fixture.release.home.appendingPathComponent("other-link")
        try FileManager.default.createSymbolicLink(atPath: indirect.path, withDestinationPath: p.managedBinary.path)
        try FileManager.default.createDirectory(at: p.pathLink.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: p.pathLink.path, withDestinationPath: indirect.path)
        XCTAssertTrue(ConflictScanner(provisioner: p, searchDirectories: []).scan().contains(.pathLinkOccupied(path: p.pathLink.path, target: indirect.path)))
        try fixture.manager().migrate()
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: p.pathLink.path), p.managedBinary.path)
        XCTAssertTrue(ConflictScanner.exists(indirect))
    }
    func testUpdateStateWithoutPendingRestartFieldDecodes() throws {
        let state = try JSONDecoder().decode(CLIUpdateState.self, from: Data("{\"skippedVersions\":[\"0.9.95\"],\"lastInstalledVersion\":\"0.9.94\"}".utf8))
        XCTAssertEqual(state.pendingRestart, [])
        XCTAssertEqual(state.skippedVersions, ["0.9.95"])
    }
    func testDamagedManagedInstallRequiresExplicitRepairWithoutExecution() throws {
        try fixture.installOld()
        try Data("tampered".utf8).write(to: fixture.release.provisioner.managedBinary)
        XCTAssertThrowsError(try fixture.updater().check())
        XCTAssertTrue(fixture.release.runner.calls.isEmpty)
        XCTAssertEqual(try fixture.updater().check(force: true).lastInstalledVersion, "0.9.95")
    }
    func testMigrationRebindAndMoveRegularFile() throws {
        try fixture.installOld()
        let p = fixture.release.provisioner
        fixture.binaries = ["web": fixture.release.binary.path, "hub": fixture.release.binary.path]
        try FileManager.default.createDirectory(at: p.pathLink.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("foreign checkout command".utf8).write(to: p.pathLink)
        let manager = try fixture.manager()
        try manager.migrate()
        let journal = try XCTUnwrap(manager.loadJournal())
        XCTAssertTrue(journal.complete)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: journal.displacedFile!)), Data("foreign checkout command".utf8))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: p.pathLink.path), p.managedBinary.path)
        let calls = fixture.release.runner.calls.map(\.arguments).filter { $0.starts(with: ["service", "rebind"]) && !$0.contains("--help") }
        XCTAssertEqual(calls, [["service", "rebind", "web", "--binary", p.managedBinary.path], ["service", "rebind", "hub", "--binary", p.managedBinary.path]])
        XCTAssertEqual(try Data(contentsOf: fixture.release.binary), try Data(contentsOf: p.managedBinary))
        try manager.rollback()
        XCTAssertEqual(try String(contentsOf: p.pathLink, encoding: .utf8), "foreign checkout command")
        XCTAssertEqual(fixture.binaries["web"], fixture.release.binary.path)
    }
    func testMigrationVerificationFailureRebindsBack() throws {
        try fixture.installOld(); fixture.binaries = ["web": fixture.release.binary.path, "hub": fixture.release.binary.path]
        fixture.failVerification = true
        let manager = try fixture.manager()
        XCTAssertThrowsError(try manager.migrate())
        XCTAssertEqual(fixture.binaries["web"], fixture.release.binary.path)
        XCTAssertTrue(try XCTUnwrap(manager.loadJournal()).rolledBack)
        XCTAssertFalse(fixture.release.runner.calls.contains { $0.arguments.starts(with: ["service", "rebind", "hub"]) }, "An unattempted service must not be restarted by rollback")
    }
    func testResumeAfterInterruptedRebind() throws {
        try fixture.installOld()
        let manager = try fixture.manager()
        let journal = MigrationJournal(id: "interrupted", services: [.init(kind: "web", previousBinary: fixture.release.binary.path, wasRunning: true, confirmed: false)], pathRecorded: false, complete: false, rolledBack: false)
        try JSONEncoder().encode(journal).write(to: manager.journalURL)
        fixture.binaries = ["web": fixture.release.provisioner.managedBinary.path]
        try manager.migrate()
        XCTAssertTrue(try XCTUnwrap(manager.loadJournal()).complete)
        XCTAssertFalse(fixture.release.runner.calls.contains { $0.arguments == ["service", "rebind", "web", "--binary", fixture.release.provisioner.managedBinary.path] })
    }
    func testIncompleteMigrationDefersUpdatesWithoutExecutingCLI() throws {
        try fixture.installOld()
        let manager = try fixture.manager()
        let journal = MigrationJournal(id: "interrupted", services: [], pathRecorded: false, complete: false, rolledBack: false)
        try JSONEncoder().encode(journal).write(to: manager.journalURL)
        let updater = try fixture.updater()
        XCTAssertThrowsError(try updater.check())
        XCTAssertTrue(fixture.release.runner.calls.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: updater.stateURL.path))
    }
    func testUnsupportedRebindDoesNothing() throws {
        try fixture.installOld(); fixture.supportsRebind = false
        fixture.binaries = ["web": fixture.release.binary.path]
        let manager = try fixture.manager()
        XCTAssertNotNil(manager.unavailableReason(conflicts: [.serviceBinary(kind: "web", binary: fixture.release.binary.path)]))
        XCTAssertThrowsError(try manager.migrate())
        XCTAssertNil(try manager.loadJournal())
    }
    func testUpdaterNewerInstallsAndReloadsOwnedRunningOnly() throws {
        try fixture.installOld()
        fixture.binaries = ["web": fixture.release.provisioner.managedBinary.path, "hub": fixture.release.binary.path]
        let state = try fixture.updater().check()
        XCTAssertEqual(state.lastInstalledVersion, "0.9.95")
        XCTAssertTrue(fixture.release.runner.calls.contains { $0.arguments == ["service", "reload", "web"] })
        XCTAssertFalse(fixture.release.runner.calls.contains { $0.arguments == ["service", "reload", "hub"] })
        XCTAssertFalse(fixture.release.runner.calls.contains { $0.arguments.contains("restart") })
        XCTAssertEqual(state.unconfirmedReloads, ["web"], "Without a bearer token readiness cannot prove the new version")
    }
    func testParentHelpExitZeroIsNotReloadSupport() throws {
        try fixture.installOld(); fixture.supportsReload = false
        fixture.binaries = ["web": fixture.release.provisioner.managedBinary.path]
        let state = try fixture.updater().check()
        XCTAssertEqual(state.pendingRestart, ["web"])
        XCTAssertFalse(fixture.release.runner.calls.contains { $0.arguments == ["service", "reload", "web"] },
                       "A CLI that answers with the parent help must never be sent a no-op reload")
    }
    func testStartupGapAfterReloadIsNotAFailedRelease() throws {
        try fixture.installOld(); fixture.tokenAvailable = true; fixture.transientUnhealthyPolls = 2
        fixture.binaries = ["web": fixture.release.provisioner.managedBinary.path]
        let checker = DelayedVersionChecker(); checker.succeedAfter = 1
        var updater = try fixture.updater(); updater.versionChecker = checker
        updater.failureGrace = 5; updater.reloadTimeout = 5
        let state = try updater.check()
        XCTAssertEqual(state.lastInstalledVersion, "0.9.95")
        XCTAssertEqual(state.skippedVersions, [])
        XCTAssertEqual(state.unconfirmedReloads, [])
        XCTAssertEqual(checker.calls, 1, "Only a ready successor is asked for its version")
        XCTAssertFalse(fixture.release.runner.calls.contains { $0.arguments.contains("restart") })
    }
    func testUpdaterUnhealthyRollsBackSkipsAndRestarts() throws {
        try fixture.installOld(); fixture.unhealthyReload = true
        fixture.binaries = ["web": fixture.release.provisioner.managedBinary.path]
        let updater = try fixture.updater()
        XCTAssertThrowsError(try updater.check())
        XCTAssertEqual(try fixture.release.provisioner.loadSelection().get()?.version, "0.9.94")
        XCTAssertEqual(try updater.loadState().skippedVersions, ["0.9.95"])
        XCTAssertTrue(fixture.release.runner.calls.contains { $0.arguments == ["service", "restart", "web", "--no-enable"] })
    }
    func testReloadUnsupportedPendingNoAutomaticRestart() throws {
        try fixture.installOld(); fixture.supportsReload = false
        fixture.binaries = ["web": fixture.release.provisioner.managedBinary.path]
        let updater = try fixture.updater()
        XCTAssertEqual(try updater.check().pendingRestart, ["web"])
        XCTAssertFalse(fixture.release.runner.calls.contains { $0.arguments.contains("restart") })
        try updater.finishRestart(kind: "web")
        XCTAssertEqual(try updater.loadState().pendingRestart, [])
    }
    func testHandOverLeavesBinaryLinkServicesAndRemovesMetadata() throws {
        try fixture.installOld()
        let p = fixture.release.provisioner
        _ = p.syncPATHLink(for: try XCTUnwrap(p.loadSelection().get()))
        try p.handOver()
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: p.managedBinary.path))
        XCTAssertTrue(ConflictScanner.exists(p.pathLink))
        XCTAssertNil(try p.loadSelection().get()); XCTAssertFalse(p.managedMarkerPresent)
        XCTAssertTrue(fixture.release.runner.calls.isEmpty)
    }
    func testRemoveOnlyUninstallsServicesUsingManagedPath() throws {
        try fixture.installOld()
        fixture.binaries = ["web": fixture.release.provisioner.managedBinary.path, "hub": fixture.release.binary.path]
        try fixture.updater().remove()
        XCTAssertNil(fixture.binaries["web"]); XCTAssertNotNil(fixture.binaries["hub"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.release.provisioner.managedBinary.path))
    }
    func testResumeAfterPATHFileMovedBeforeLinkCreation() throws {
        try fixture.installOld()
        let p = fixture.release.provisioner
        let moved = p.supportDirectory.appendingPathComponent("migrated/interrupted/term-llm")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("displaced".utf8).write(to: moved)
        let manager = try fixture.manager()
        let journal = MigrationJournal(id: "interrupted", services: [], pathRecorded: true, displacedFile: moved.path, complete: false, rolledBack: false)
        try JSONEncoder().encode(journal).write(to: manager.journalURL)
        XCTAssertNil(manager.unavailableReason(conflicts: []), "Incomplete journal must be resumable even when conflicts are already gone")
        try manager.migrate()
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: p.pathLink.path), p.managedBinary.path)
        XCTAssertTrue(try XCTUnwrap(manager.loadJournal()).complete)
        try manager.rollback()
        XCTAssertEqual(try String(contentsOf: p.pathLink, encoding: .utf8), "displaced")
    }
    func testForeignSymlinkMigrationAndRollbackPreserveTargetFile() throws {
        try fixture.installOld()
        let p = fixture.release.provisioner
        try FileManager.default.createDirectory(at: p.pathLink.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: p.pathLink.path, withDestinationPath: fixture.release.binary.path)
        let before = try Data(contentsOf: fixture.release.binary)
        let manager = try fixture.manager()
        try manager.migrate(); try manager.rollback()
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: p.pathLink.path), fixture.release.binary.path)
        XCTAssertEqual(try Data(contentsOf: fixture.release.binary), before)
    }
    func testUpdaterWaitsForHealthVersionRatherThanSignalOrReadyAlone() throws {
        try fixture.installOld(); fixture.tokenAvailable = true
        fixture.binaries = ["web": fixture.release.provisioner.managedBinary.path]
        let checker = DelayedVersionChecker()
        var updater = try fixture.updater(); updater.versionChecker = checker
        XCTAssertEqual(try updater.check().lastInstalledVersion, "0.9.95")
        XCTAssertEqual(checker.calls, 3)
    }
    func testHealthyOldVersionAtTimeoutIsUnconfirmedNotRolledBack() throws {
        // A busy service keeps serving the previous build until its work ends;
        // the pending re-exec will load the installed release.
        try fixture.installOld(); fixture.tokenAvailable = true
        fixture.binaries = ["web": fixture.release.provisioner.managedBinary.path]
        let checker = DelayedVersionChecker(); checker.succeedAfter = Int.max
        var updater = try fixture.updater(); updater.versionChecker = checker
        let state = try updater.check()
        XCTAssertGreaterThan(checker.calls, 0)
        XCTAssertEqual(state.unconfirmedReloads, ["web"])
        XCTAssertEqual(state.skippedVersions, [])
        XCTAssertEqual(try fixture.release.provisioner.loadSelection().get()?.version, "0.9.95")
        XCTAssertFalse(fixture.release.runner.calls.contains { $0.arguments.contains("restart") })
    }
    func testFreshSetupRecordsInstalledVersionAndNeverExecutesLegacySelection() throws {
        let p = fixture.release.provisioner
        try FileManager.default.createDirectory(at: p.supportDirectory, withIntermediateDirectories: true)
        let legacy = """
        {"schemaVersion":1,"source":"external","binaryPath":"/never-execute-legacy","version":"","sha256":"","installedAt":"2026-11-01T00:00:00Z","provenance":"Legacy"}
        """
        try Data(legacy.utf8).write(to: p.manifestURL)
        XCTAssertEqual(try fixture.updater().setUp().lastInstalledVersion, "0.9.95")
        XCTAssertFalse(fixture.release.runner.calls.contains { $0.executable == "/never-execute-legacy" })
        XCTAssertTrue(ConflictScanner(provisioner: p, searchDirectories: []).scan().contains(.legacyExternalSelection(path: "/never-execute-legacy")))
    }
    func testHomebrewRemovalExactCallsWithNoDependents() throws {
        try fixture.installOld()
        let manager = try fixture.manager()
        let journal = MigrationJournal(id: "complete", services: [], pathRecorded: false, complete: true, rolledBack: false)
        try JSONEncoder().encode(journal).write(to: manager.journalURL)
        fixture.release.runner.handler = { exe, args, env in
            XCTAssertEqual(exe, self.fixture.release.binary)
            XCTAssertEqual(env, ["HOMEBREW_NO_AUTO_UPDATE": "1"])
            return CommandResult(status: 0, stdout: "", stderr: "")
        }
        try manager.removeHomebrewCopy(brewCandidates: [fixture.release.binary])
        XCTAssertEqual(fixture.release.runner.calls.map(\.arguments), [["uses", "--installed", "term-llm"], ["uninstall", "term-llm"]])
    }
    func testHomebrewRemovalRefusesDependentsAndNeedsCompletedMigration() throws {
        try fixture.installOld()
        let manager = try fixture.manager()
        XCTAssertThrowsError(try manager.removeHomebrewCopy(brewCandidates: [fixture.release.binary]))
        let journal = MigrationJournal(id: "complete", services: [], pathRecorded: false, complete: true, rolledBack: false)
        try JSONEncoder().encode(journal).write(to: manager.journalURL)
        fixture.release.runner.handler = { _, args, env in
            XCTAssertEqual(env?["HOMEBREW_NO_AUTO_UPDATE"], "1")
            XCTAssertEqual(args, ["uses", "--installed", "term-llm"])
            return CommandResult(status: 0, stdout: "dependent-formula\n", stderr: "")
        }
        XCTAssertThrowsError(try manager.removeHomebrewCopy(brewCandidates: [fixture.release.binary]))
    }
}

private final class DelayedVersionChecker: ServiceVersionChecking {
    var calls = 0
    var succeedAfter = 3
    func matches(status: ServiceStatus, token: String, version: String) -> Bool {
        XCTAssertEqual(token, "synthetic-fixture-token-only")
        XCTAssertEqual(version, "0.9.95")
        calls += 1
        return calls >= succeedAfter
    }
}

final class HealthVersionTests: XCTestCase {
    override func tearDown() { ProbeURLProtocol.reset(); super.tearDown() }
    func testHealthRequestUsesAuthHeaderMountAndExactVersionWithoutCookies() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProbeURLProtocol.self]
        let checker = HTTPServiceVersionChecker(configuration: configuration)
        let status = try XCTUnwrap(JSONDecoder().decode(ServiceStatusReport.self, from: Data(ServiceFixtures.readyJSON.utf8)).service("web"))
        ProbeURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:8765/ui/healthz")
            XCTAssertNil(request.url?.query)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, Data("{\"version\":\"0.9.95\"}".utf8))
        }
        XCTAssertTrue(checker.matches(status: status, token: "fixture-token", version: "0.9.95"))
        XCTAssertFalse(checker.matches(status: status, token: "fixture-token", version: "0.9.96"))
    }
    func testHealthRedirectDoesNotVerifyOrForwardCredential() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProbeURLProtocol.self]
        let checker = HTTPServiceVersionChecker(configuration: configuration)
        let status = try XCTUnwrap(JSONDecoder().decode(ServiceStatusReport.self, from: Data(ServiceFixtures.readyJSON.utf8)).service("web"))
        ProbeURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil, headerFields: ["Location": "http://example.invalid/steal"])!, Data())
        }
        XCTAssertFalse(checker.matches(status: status, token: "fixture-token", version: "0.9.95"))
        XCTAssertEqual(ProbeURLProtocol.requests.count, 1)
    }
}
