import XCTest
@testable import TermLLMMacKit

final class LocalServiceSummaryTests: XCTestCase {
    private let home = "/Users/tester"
    private var managed: String { home + "/.config/term-llm/app/bin/term-llm" }

    private func facts(_ configure: (inout LocalServiceFacts) -> Void = { _ in }) -> LocalServiceFacts {
        var facts = LocalServiceFacts(home: home, managedBinary: managed)
        configure(&facts)
        return facts
    }

    private func installed(_ configure: (inout LocalServiceFacts) -> Void = { _ in }) -> LocalServiceFacts {
        facts { facts in
            facts.selection = CLISelection(source: .release, binaryPath: managed, version: "0.9.94", sha256: "abc",
                                           provenance: "https://github.com/samsaffron/term-llm/releases/tag/v0.9.94")
            facts.verifiedVersion = "0.9.94"
            configure(&facts)
        }
    }

    private func service(_ state: ServiceStatus.State, binary: String? = nil, auth: String = "bearer",
                         enrollment: ServiceStatus.Enrollment = .notRequired) -> ServiceStatus {
        let installed = state != .notInstalled
        return ServiceStatus(kind: "web", installed: installed, managed: installed, registered: installed, state: state,
                             running: state == .ready || state == .unhealthy, autostart: true,
                             binary: installed ? (binary ?? managed) : "", host: "127.0.0.1", port: 8765,
                             auth: auth, enrollment: enrollment)
    }

    func testFreshMacOffersSetUpOnly() {
        let summary = LocalServiceSummary.make(facts())
        XCTAssertEqual(summary.title, "term-llm isn't set up on this Mac")
        XCTAssertEqual(summary.primary, .setUp)
        XCTAssertNil(summary.secondary)
        XCTAssertNil(summary.notice)
    }

    func testInstalledWithoutServiceOffersToStartOne() {
        let summary = LocalServiceSummary.make(installed { $0.service = self.service(.notInstalled) })
        XCTAssertEqual(summary.title, "term-llm 0.9.94 is installed")
        XCTAssertEqual(summary.primary, .createService)
        XCTAssertEqual(summary.primary?.title, "Start Local Service")
    }

    func testRunningOffersChatAndStop() {
        let summary = LocalServiceSummary.make(installed { $0.service = self.service(.ready) })
        XCTAssertEqual(summary.tone, .ok)
        XCTAssertEqual(summary.title, "Running")
        XCTAssertEqual(summary.detail, "term-llm 0.9.94")
        XCTAssertEqual(summary.primary, .openChat)
        XCTAssertEqual(summary.secondary, .stopService)
        XCTAssertNil(summary.notice)
    }

    func testStoppedAndUnhealthy() {
        XCTAssertEqual(LocalServiceSummary.make(installed { $0.service = self.service(.stopped) }).primary, .startService)
        let unhealthy = LocalServiceSummary.make(installed { $0.service = self.service(.unhealthy) })
        XCTAssertEqual(unhealthy.tone, .problem)
        XCTAssertEqual(unhealthy.primary, .restartService)
    }

    func testPasskeyServiceHasNoChatButton() {
        let summary = LocalServiceSummary.make(installed { $0.service = self.service(.ready, auth: "passkey", enrollment: .pending) })
        XCTAssertNil(summary.primary)
        XCTAssertEqual(summary.secondary, .stopService)
        XCTAssertEqual(summary.tone, .attention)
    }

    /// A healthy service on a checkout build is reported as running, with Chat;
    /// ownership is a quiet note, and the switch waits for a newer core.
    func testHealthyServiceOnAnotherCopyIsRunning() {
        let checkout = home + "/Source/term-llm/term-llm"
        let summary = LocalServiceSummary.make(installed {
            $0.service = self.service(.ready, binary: checkout)
            $0.conflicts = [.pathLinkOccupied(path: self.home + "/.local/bin/term-llm", target: checkout),
                            .serviceBinary(kind: "web", binary: checkout)]
            $0.migrationBlocker = .needsNewerRelease
        })
        XCTAssertEqual(summary.tone, .ok)
        XCTAssertEqual(summary.title, "Running")
        XCTAssertEqual(summary.detail, "Using ~/Source/term-llm/term-llm")
        XCTAssertEqual(summary.primary, .openChat)
        XCTAssertEqual(summary.secondary, .stopService, "Lifecycle controls don't depend on which copy runs")
        XCTAssertEqual(summary.notice?.tone, .off)
        XCTAssertEqual(summary.notice?.text, "The app doesn't manage this copy of term-llm, so it won't update it.")
        XCTAssertNil(summary.notice?.action, "No disabled switch button while the core can't rebind")
        XCTAssertEqual(summary.notice?.footnote, "Switching to the app's copy needs a newer term-llm release.")
    }

    func testServiceOnAnotherCopyIsControlledButNeverReinstalled() {
        let unhealthy = LocalServiceSummary.make(installed {
            $0.service = self.service(.unhealthy, binary: "/opt/homebrew/bin/term-llm")
        })
        XCTAssertEqual(unhealthy.tone, .problem)
        XCTAssertEqual(unhealthy.primary, .restartService)
        XCTAssertEqual(unhealthy.secondary, .stopService)
        XCTAssertEqual(unhealthy.notice?.action, .migrate)
        let unregistered = LocalServiceSummary.make(installed {
            $0.service = self.service(.notRegistered, binary: "/opt/homebrew/bin/term-llm")
        })
        XCTAssertNil(unregistered.primary, "Repairing would reinstall it on the app's copy; that's the switch")
    }

    func testHomebrewServiceIsNamedAndSwitchable() {
        let summary = LocalServiceSummary.make(installed {
            $0.service = self.service(.stopped, binary: "/opt/homebrew/bin/term-llm")
        })
        XCTAssertEqual(summary.detail, "Using Homebrew's term-llm")
        XCTAssertEqual(summary.title, "Local service is stopped")
        XCTAssertEqual(summary.primary, .startService)
        XCTAssertEqual(summary.notice?.action, .migrate)
        XCTAssertNil(summary.notice?.footnote)
    }

    func testPATHConflictBecomesTheOnlyNotice() {
        let summary = LocalServiceSummary.make(installed {
            $0.service = self.service(.ready)
            $0.conflicts = [.foreignCommand(path: "/usr/local/bin/term-llm", resolved: "/usr/local/bin/term-llm"),
                            .pathLinkOccupied(path: self.home + "/.local/bin/term-llm", target: "/elsewhere")]
        })
        XCTAssertEqual(summary.primary, .openChat)
        XCTAssertEqual(summary.notice?.text, "The term-llm command in Terminal runs another copy.")
        XCTAssertEqual(summary.notice?.tone, .off)
        XCTAssertEqual(summary.notice?.action, .migrate)
    }

    func testOtherCommandsOnPATHStayInAdvanced() {
        let summary = LocalServiceSummary.make(installed {
            $0.service = self.service(.ready)
            $0.conflicts = [.foreignCommand(path: self.home + "/go/bin/term-llm", resolved: self.home + "/go/bin/term-llm")]
        })
        XCTAssertNil(summary.notice)
    }

    func testHomebrewRemovalOffered() {
        let summary = LocalServiceSummary.make(installed {
            $0.service = self.service(.ready)
            $0.conflicts = [.homebrewFormula(path: "/opt/homebrew/bin/term-llm")]
            $0.migration = MigrationJournal(id: "done", services: [], pathRecorded: true, complete: true, rolledBack: false)
        })
        XCTAssertEqual(summary.notice?.action, .removeHomebrewCopy)
        XCTAssertEqual(summary.notice?.actionEnabled, true)
    }

    func testPendingRestartAndInterruptedSwitchNotices() {
        let restart = LocalServiceSummary.make(installed {
            $0.service = self.service(.ready)
            $0.updates.pendingRestart = ["web"]
        })
        XCTAssertEqual(restart.notice?.action, .finishUpdate)
        let interrupted = LocalServiceSummary.make(installed {
            $0.service = self.service(.ready)
            $0.migration = MigrationJournal(id: "x", services: [], pathRecorded: false, complete: false, rolledBack: false)
        })
        XCTAssertEqual(interrupted.notice?.action, .resumeMigration)
    }

    func testFailedUpdateOffersRetry() {
        let summary = LocalServiceSummary.make(installed {
            $0.service = self.service(.ready)
            $0.updates.lastError = "network down"
        })
        XCTAssertEqual(summary.notice?.action, .checkForUpdates)
    }

    func testVerificationFailureOffersRepair() {
        let summary = LocalServiceSummary.make(installed { $0.ownershipError = "checksum" })
        XCTAssertEqual(summary.tone, .problem)
        XCTAssertEqual(summary.primary, .repair)
    }

    func testDeveloperModeUsesItsBinaryAndSaysSo() {
        let checkout = home + "/Source/term-llm/term-llm"
        let summary = LocalServiceSummary.make(facts {
            $0.developerModeEnabled = true
            $0.developerBinary = checkout
            $0.service = self.service(.unhealthy, binary: checkout)
        })
        XCTAssertEqual(summary.primary, .restartService)
        XCTAssertEqual(summary.notice?.tone, .off)
        XCTAssertEqual(summary.notice?.action, .leaveDeveloperMode)
        let running = LocalServiceSummary.make(facts {
            $0.developerModeEnabled = true
            $0.developerBinary = checkout
            $0.service = self.service(.ready, binary: checkout)
        })
        XCTAssertEqual(running.detail, "~/Source/term-llm/term-llm", "Developer Mode shows which build runs")
        XCTAssertEqual(running.primary, .openChat)
        let missing = LocalServiceSummary.make(facts { $0.developerModeEnabled = true })
        XCTAssertEqual(missing.primary, .leaveDeveloperMode)
    }

    func testBusyDisablesEverythingAndShowsProgress() {
        let summary = LocalServiceSummary.make(installed {
            $0.service = self.service(.ready)
            $0.updates.pendingRestart = ["web"]
            $0.busyMessage = "Checking for updates…"
        })
        XCTAssertEqual(summary.tone, .busy)
        XCTAssertEqual(summary.detail, "Checking for updates…")
        XCTAssertFalse(summary.primaryEnabled)
        XCTAssertNil(summary.secondary)
        XCTAssertEqual(summary.notice?.actionEnabled, false)
    }

    func testUnverifiedReleaseShowsCheckingNotSetUp() {
        let summary = LocalServiceSummary.make(installed { $0.verifiedVersion = nil })
        XCTAssertEqual(summary.tone, .busy)
        XCTAssertNil(summary.primary)
    }

    func testConflictLinesAreShortAndUseTilde() {
        let tilde = { (path: String) in LocalServiceFacts(home: self.home, managedBinary: "").tilde(path) }
        XCTAssertEqual(OwnershipConflict.serviceBinary(kind: "web", binary: home + "/Source/term-llm/term-llm").displayText(tilde: tilde),
                       "Web service: ~/Source/term-llm/term-llm")
        XCTAssertEqual(OwnershipConflict.pathLinkOccupied(path: home + "/.local/bin/term-llm", target: "/x").displayText(tilde: tilde),
                       "Terminal command: ~/.local/bin/term-llm → /x")
        XCTAssertEqual(tilde("/Users/testerX/file"), "/Users/testerX/file")
    }
}
