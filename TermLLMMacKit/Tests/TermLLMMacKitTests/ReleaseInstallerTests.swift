import Foundation
import os
import XCTest
@testable import TermLLMMacKit

struct FixtureTransport: ReleaseTransport {
    let archive: Data
    var version = "0.9.95"
    var checksumOverride: String?
    var releaseURL: URL?
    let requests = OSAllocatedUnfairLock<[URL]>(initialState: [])
    func fetch(_ url: URL) throws -> ReleaseResponse {
        requests.withLock { $0.append(url) }
        if url == ReleaseInstaller.latestURL || url.path.contains("/releases/tag/") {
            return ReleaseResponse(data: Data(), url: releaseURL ?? URL(string: "https://github.com/term-llm/term-llm/releases/tag/v\(version)")!)
        }
        if url.lastPathComponent == "checksums.txt" {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try archive.write(to: dir); defer { try? FileManager.default.removeItem(at: dir) }
            let digest = try checksumOverride ?? CLIProvisioner.sha256(of: dir)
            return ReleaseResponse(data: Data("\(digest)  term-llm_\(version)_darwin_\(ReleaseInstaller.nativeArchitecture).tar.gz\n".utf8), url: url)
        }
        return ReleaseResponse(data: archive, url: url)
    }
}

final class ReleaseFixture {
    let home: URL
    let runner = FakeCommandRunner()
    let binary: URL
    var provisioner: CLIProvisioner { CLIProvisioner(home: home, runner: runner) }
    static let requirement = "identifier \"com.apple.true\" and anchor apple"
    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("termllm-release-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        binary = home.appendingPathComponent("term-llm")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: binary)
        runner.handler = { exe, args, env in
            if exe.path == "/usr/bin/tar" { return try ProcessCommandRunner().run(executable: exe, arguments: args, environment: ["HOME": self.home.path], timeout: 20) }
            XCTAssertEqual(env?["TERM_LLM_NO_PROMPT"], "1")
            XCTAssertEqual(env?["TERM_LLM_SKIP_UPDATE_CHECK"], "1")
            if args == ["--version"] { return CommandResult(status: 0, stdout: "term-llm version 0.9.95", stderr: "") }
            return CommandResult(status: 0, stdout: ServiceFixtures.readyJSON, stderr: "")
        }
    }
    func cleanup() { runner.handler = nil; try? FileManager.default.removeItem(at: home) }
    func archive() throws -> Data {
        let output = home.appendingPathComponent(UUID().uuidString + ".tar.gz")
        let result = try ProcessCommandRunner().run(executable: URL(fileURLWithPath: "/usr/bin/tar"),
                    arguments: ["-czf", output.path, "-C", home.path, "term-llm"], environment: ["HOME": home.path], timeout: 20)
        XCTAssertTrue(result.succeeded)
        return try Data(contentsOf: output)
    }
    func installer(transport: FixtureTransport? = nil, requirement: String = ReleaseFixture.requirement) throws -> ReleaseInstaller {
        try ReleaseInstaller(provisioner: provisioner, transport: transport ?? FixtureTransport(archive: archive()), requirement: requirement)
    }
}

final class ReleaseInstallerTests: XCTestCase {
    var fixture: ReleaseFixture!
    override func setUpWithError() throws { fixture = try ReleaseFixture() }
    override func tearDownWithError() throws { fixture.cleanup(); fixture = nil }
    func testSignedReleaseInstallsAndCleansStage() throws {
        let installer = try fixture.installer()
        let selection = try XCTUnwrap(installer.install())
        XCTAssertEqual(selection.version, "0.9.95"); XCTAssertEqual(selection.source, .release)
        XCTAssertEqual(selection.schemaVersion, 2)
        XCTAssertEqual(selection.provenance, "https://github.com/term-llm/term-llm/releases/tag/v0.9.95")
        try installer.verifyManaged()
        let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.provisioner.managedMarkerURL)) as! [String: Any]
        XCTAssertEqual(marker["owner"] as? String, "the term-llm app")
        XCTAssertEqual(marker["app_bundle_id"] as? String, "com.termllm.app")
        XCTAssertTrue((marker["update_hint"] as! String).contains(fixture.provisioner.managedMarkerURL.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.provisioner.supportDirectory.appendingPathComponent("staging").path), [])
        XCTAssertNil(try installer.install()) // equal version
        XCTAssertNil(try installer.install(version: "0.9.96", skippedVersions: ["0.9.96"]))
    }
    func testLatestAcceptsOnlyKnownCoreRepositoriesIncludingGitHubCaseVariations() throws {
        XCTAssertEqual(ReleaseInstaller.latestURL.absoluteString, "https://github.com/term-llm/term-llm/releases/latest")
        for repository in ["term-llm/term-llm", "samsaffron/term-llm", "SamSaffron/Term-LLM", "TERM-LLM/TERM-LLM"] {
            let transport = FixtureTransport(archive: Data(), releaseURL: URL(string: "https://GitHub.com/\(repository)/releases/tag/v0.9.95")!)
            XCTAssertEqual(try fixture.installer(transport: transport).latestVersion(), "0.9.95", repository)
        }
    }
    func testLatestRejectsUntrustedOrAmbiguousFinalURLs() throws {
        for final in [
            "http://github.com/term-llm/term-llm/releases/tag/v0.9.95",
            "https://github.com.evil.invalid/term-llm/term-llm/releases/tag/v0.9.95",
            "https://example.invalid/term-llm/term-llm/releases/tag/v0.9.95",
            "https://github.com/other/term-llm/releases/tag/v0.9.95",
            "https://github.com/term-llm/term-llm-app/releases/tag/v0.9.95",
            "https://github.com/user/../term-llm/term-llm/releases/tag/v0.9.95",
            "https://user:password@github.com/term-llm/term-llm/releases/tag/v0.9.95",
            "https://github.com:8443/term-llm/term-llm/releases/tag/v0.9.95",
            "https://github.com/term-llm/term-llm/releases/tag/v0.9.95?next=other",
            "https://github.com/term-llm/term-llm/releases/tag/v0.9.95#other",
            "https://github.com/term-llm/term-llm/releases/tag/v0.9.95/extra",
            "https://github.com/term-llm/term-llm/releases/tag/v0.9.95/",
            "https://github.com/term-llm/term-llm/releases/tag/v0.9.95%2Fextra",
            "https://github.com/%74erm-llm/term-llm/releases/tag/v0.9.95",
            "https://github.com/term-llm/term-llm/releases/tag/v00.9.95",
            "https://github.com/term-llm/term-llm/releases/latest"
        ] {
            let transport = FixtureTransport(archive: Data(), releaseURL: URL(string: final)!)
            XCTAssertThrowsError(try fixture.installer(transport: transport).install(), final)
            XCTAssertEqual(transport.requests.withLock { $0 }, [ReleaseInstaller.latestURL], final)
        }
        XCTAssertTrue(fixture.runner.calls.isEmpty)
        XCTAssertFalse(fixture.provisioner.managedMarkerPresent)
    }
    func testDownloadsAndProvenanceFollowValidatedFinalRepositoryAndTag() throws {
        for (repository, tag) in [("term-llm/term-llm", "v0.9.95"), ("samsaffron/term-llm", "0.9.95")] {
            let provenance = "https://github.com/\(repository)/releases/tag/\(tag)"
            let transport = FixtureTransport(archive: try fixture.archive(), releaseURL: URL(string: provenance)!)
            let installer = try fixture.installer(transport: transport)
            let selection = try XCTUnwrap(installer.install(force: true))
            XCTAssertEqual(selection.provenance, provenance)
            let base = "https://github.com/\(repository)/releases/download/\(tag)/"
            XCTAssertEqual(transport.requests.withLock { $0.map(\.absoluteString) }, [
                ReleaseInstaller.latestURL.absoluteString,
                base + "term-llm_0.9.95_darwin_\(ReleaseInstaller.nativeArchitecture).tar.gz",
                base + "checksums.txt"
            ])
        }
    }
    func testExplicitVersionResolvesFinalRepositoryBeforeDownloading() throws {
        let provenance = "https://github.com/samsaffron/term-llm/releases/tag/v0.9.95"
        let transport = FixtureTransport(archive: try fixture.archive(), releaseURL: URL(string: provenance)!)
        let installer = try fixture.installer(transport: transport)
        try installer.withVerifiedCandidate(version: "v0.9.95") { _, version, source in
            XCTAssertEqual(version, "0.9.95")
            XCTAssertEqual(source, provenance)
        }
        let requests = transport.requests.withLock { $0.map(\.absoluteString) }
        XCTAssertEqual(requests.first, "https://github.com/term-llm/term-llm/releases/tag/v0.9.95")
        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(requests.dropFirst().allSatisfy { $0.hasPrefix("https://github.com/samsaffron/term-llm/releases/download/v0.9.95/") })
    }
    func testExplicitVersionRejectsRedirectToDifferentVersionBeforeDownloading() throws {
        let transport = FixtureTransport(archive: Data())
        XCTAssertThrowsError(try fixture.installer(transport: transport).install(version: "0.9.96"))
        XCTAssertEqual(transport.requests.withLock { $0.count }, 1)
        XCTAssertTrue(fixture.runner.calls.isEmpty)
    }
    func testVerifyManagedRechecksAfterTheFileChanges() throws {
        let installer = try fixture.installer()
        _ = try XCTUnwrap(installer.install())
        try installer.verifyManaged()
        try installer.verifyManaged() // unchanged file: memoized
        let handle = try FileHandle(forWritingTo: fixture.provisioner.managedBinary)
        try handle.seekToEnd(); try handle.write(contentsOf: Data([0])); try handle.close()
        XCTAssertThrowsError(try installer.verifyManaged(), "A modified binary must not reuse an earlier verification")
    }
    func testChecksumMismatchNeverExtractsOrExecutesCandidate() throws {
        let transport = FixtureTransport(archive: try fixture.archive(), checksumOverride: String(repeating: "0", count: 64))
        XCTAssertThrowsError(try fixture.installer(transport: transport).install())
        XCTAssertTrue(fixture.runner.calls.isEmpty)
        XCTAssertFalse(fixture.provisioner.managedMarkerPresent)
    }
    func testTamperedBinaryRejectedBeforeExecution() throws {
        let handle = try FileHandle(forWritingTo: fixture.binary)
        try handle.seekToEnd(); try handle.write(contentsOf: Data([0])); try handle.close()
        XCTAssertThrowsError(try fixture.installer().install())
        XCTAssertEqual(fixture.runner.calls.count, 1) // tar only
    }
    func testWrongRequirementRejectedBeforeExecution() throws {
        XCTAssertThrowsError(try fixture.installer(requirement: "identifier \"not.the.cli\" and anchor apple").install())
        XCTAssertEqual(fixture.runner.calls.count, 1)
    }
    func testCanonicalRepositoryStillRequiresProductionDeveloperIDSignature() throws {
        let transport = FixtureTransport(archive: try fixture.archive())
        let installer = ReleaseInstaller(provisioner: fixture.provisioner, transport: transport)
        // /usr/bin/true is valid Apple-signed code, but not the trusted CLI.
        XCTAssertThrowsError(try installer.install()) { error in
            guard case ReleaseError.signature = error else { return XCTFail("Expected signature failure, got \(error)") }
        }
        XCTAssertEqual(fixture.runner.calls.count, 1) // tar only; never execute
        XCTAssertFalse(fixture.provisioner.managedMarkerPresent)
    }
    func testSymlinkMemberRejected() throws {
        try FileManager.default.removeItem(at: fixture.binary)
        try FileManager.default.createSymbolicLink(atPath: fixture.binary.path, withDestinationPath: "/usr/bin/true")
        XCTAssertThrowsError(try fixture.installer().install())
        XCTAssertEqual(fixture.runner.calls.count, 1)
    }
    func testBelowMinimumRejected() throws {
        XCTAssertThrowsError(try fixture.installer().install(version: "0.9.93"))
        XCTAssertTrue(fixture.runner.calls.isEmpty)
    }
    func testSmokeFailureDoesNotPromote() throws {
        let previous = fixture.runner.handler!
        fixture.runner.handler = { exe, args, env in
            if args == ["service", "status", "web", "--json"] { return CommandResult(status: 0, stdout: "{\"schema_version\":2,\"services\":[]}", stderr: "") }
            return try previous(exe, args, env)
        }
        XCTAssertThrowsError(try fixture.installer().install())
        XCTAssertNil(try fixture.provisioner.loadSelection().get())
    }
    func testSemanticCompare() throws {
        XCTAssertGreaterThan(try SemanticVersion("0.10.0"), try SemanticVersion("0.9.99"))
        XCTAssertThrowsError(try SemanticVersion("1.2.3/../../bad"))
    }
    func testOptInLiveLatestVerificationWithoutPromotion() throws {
        guard ProcessInfo.processInfo.environment["TERM_LLM_RELEASE_E2E"] == "1" else { throw XCTSkip("Set TERM_LLM_RELEASE_E2E=1 to verify the real signed release in a temporary home.") }
        // Do NOT use FakeCommandRunner: signed real candidate gets --version
        // only, with HOME/XDG paths confined to this fixture. No service query.
        let runner = TemporaryHomeRunner(home: fixture.home)
        let p = CLIProvisioner(home: fixture.home, runner: runner)
        let installer = ReleaseInstaller(provisioner: p)
        let version = try installer.latestVersion()
        try installer.withVerifiedCandidate(version: version, smokeTest: false) { _, _, _ in }
        XCTAssertFalse(FileManager.default.fileExists(atPath: p.managedBinary.path))
    }
}
private struct TemporaryHomeRunner: CommandRunning {
    let home: URL
    func run(executable: URL, arguments: [String], environment: [String: String]?, timeout: TimeInterval) throws -> CommandResult {
        var env = environment ?? [:]
        env["HOME"] = home.path; env["XDG_CONFIG_HOME"] = home.appendingPathComponent("config").path
        env["TERM_LLM_CONFIG_DIR"] = home.appendingPathComponent("config").path
        return try ProcessCommandRunner().run(executable: executable, arguments: arguments, environment: env, timeout: timeout)
    }
}
