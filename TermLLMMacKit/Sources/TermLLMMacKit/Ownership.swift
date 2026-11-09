import Foundation
import Darwin

public enum OwnershipConflict: Equatable, Sendable, CustomStringConvertible {
    case homebrewFormula(path: String)
    case foreignCommand(path: String, resolved: String)
    case pathLinkOccupied(path: String, target: String)
    case serviceBinary(kind: String, binary: String)
    case legacyExternalSelection(path: String)
    public var description: String {
        switch self {
        case .homebrewFormula(let path): return "Homebrew copy: \(path)"
        case .foreignCommand(let path, let resolved):
            return path == resolved ? "Foreign command: \(path)" : "Foreign command: \(path) → \(resolved)"
        case .pathLinkOccupied(let path, let target): return "PATH link occupied: \(path) → \(target)"
        case .serviceBinary(let kind, let binary): return "\(kind) service uses \(binary)"
        case .legacyExternalSelection(let path): return "Legacy selection — migration pending: \(path)"
        }
    }
}

/// Read-only: never executes an unknown CLI (including legacy selections).
public struct ConflictScanner {
    public let provisioner: CLIProvisioner
    public let searchDirectories: [URL]
    public let homebrewBinDirectories: [URL]
    public init(provisioner: CLIProvisioner, searchDirectories: [URL]? = nil,
                homebrewBinDirectories: [URL] = [URL(fileURLWithPath: "/opt/homebrew/bin"), URL(fileURLWithPath: "/usr/local/bin")]) {
        self.provisioner = provisioner
        self.homebrewBinDirectories = homebrewBinDirectories
        self.searchDirectories = searchDirectories ?? [provisioner.home.appendingPathComponent(".local/bin"),
            URL(fileURLWithPath: "/usr/local/bin"), URL(fileURLWithPath: "/opt/homebrew/bin"),
            provisioner.home.appendingPathComponent("go/bin"), provisioner.home.appendingPathComponent("bin")]
    }
    public func scan(services: [ServiceStatus] = []) -> [OwnershipConflict] {
        let managed = provisioner.managedBinary.standardizedFileURL.path
        var conflicts: [OwnershipConflict] = []
        for dir in searchDirectories {
            let path = dir.appendingPathComponent("term-llm")
            // The managed Terminal link location is reported once, below.
            guard Self.exists(path), path.standardizedFileURL.path != provisioner.pathLink.standardizedFileURL.path else { continue }
            let resolved = path.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved != managed else { continue }
            if homebrewBinDirectories.contains(dir), resolved.contains("/Cellar/term-llm/") {
                conflicts.append(.homebrewFormula(path: path.path))
            } else { conflicts.append(.foreignCommand(path: path.path, resolved: resolved)) }
        }
        if Self.exists(provisioner.pathLink) {
            let target = try? provisioner.fileManager.destinationOfSymbolicLink(atPath: provisioner.pathLink.path)
            let destination = target.map { URL(fileURLWithPath: $0, relativeTo: provisioner.pathLink.deletingLastPathComponent()).standardizedFileURL.path }
            if destination != managed {
                conflicts.append(.pathLinkOccupied(path: provisioner.pathLink.path, target: target ?? "regular file"))
            }
        }
        for service in services where ["web", "hub"].contains(service.kind) && service.installed {
            if let binary = service.binary, binary != managed { conflicts.append(.serviceBinary(kind: service.kind, binary: binary)) }
        }
        if let selection = try? provisioner.loadSelection().get(), selection.source == .external {
            conflicts.append(.legacyExternalSelection(path: selection.binaryPath))
        } else if let data = try? Data(contentsOf: provisioner.supportDirectory.appendingPathComponent("legacy-selection.json")),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let path = json["binaryPath"] as? String,
                  (try? MigrationManager(provisioner: provisioner).loadJournal()?.complete) != true {
            conflicts.append(.legacyExternalSelection(path: path))
        }
        return conflicts
    }
    static func exists(_ url: URL) -> Bool { var info = stat(); return lstat(url.path, &info) == 0 }
}

public enum MigrationBlocker: Equatable, Sendable {
    case developerMode, notSetUp, nothingToMigrate, needsNewerRelease
    public var reason: String {
        switch self {
        case .developerMode: return "Leave Developer Mode before migrating."
        case .notSetUp: return "Set up a healthy signed managed release first."
        case .nothingToMigrate: return "No migration conflicts found."
        case .needsNewerRelease: return "This CLI lacks service rebind. A newer core release than 0.9.94 is required; nothing was changed."
        }
    }
    /// One line for the simple view.
    public var shortReason: String {
        switch self {
        case .developerMode: return "Not available in Developer Mode."
        case .notSetUp: return "Set up term-llm first."
        case .nothingToMigrate: return "Nothing needs switching."
        case .needsNewerRelease: return "Available after the next term-llm release."
        }
    }
}

public struct MigrationJournal: Codable, Equatable, Sendable {
    public struct Service: Codable, Equatable, Sendable {
        public var kind: String
        public var previousBinary: String
        public var wasRunning: Bool
        public var confirmed: Bool
        /// nil means an older journal, conservatively eligible for recovery.
        public var attempted: Bool? = nil
    }
    public var id: String
    public var services: [Service]
    public var pathRecorded: Bool
    public var previousLinkTarget: String?
    public var displacedFile: String?
    public var complete: Bool
    public var rolledBack: Bool
}

public struct MigrationManager {
    public let provisioner: CLIProvisioner
    public let installer: ReleaseInstaller
    public init(provisioner: CLIProvisioner, installer: ReleaseInstaller? = nil) {
        self.provisioner = provisioner; self.installer = installer ?? ReleaseInstaller(provisioner: provisioner)
    }
    public var journalURL: URL { provisioner.supportDirectory.appendingPathComponent("migration.json") }
    public func loadJournal() throws -> MigrationJournal? {
        guard ConflictScanner.exists(journalURL) else { return nil }
        return try JSONDecoder().decode(MigrationJournal.self, from: Data(contentsOf: journalURL))
    }
    private func save(_ journal: MigrationJournal) throws {
        try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
    }
    private func controller(_ kind: String) -> ServiceController {
        ServiceController(executable: provisioner.managedBinary, kind: kind, runner: provisioner.runner)
    }
    public func statuses() throws -> [ServiceStatus] {
        try ["web", "hub"].map { try controller($0).currentStatus() }
    }
    public func unavailableReason(conflicts: [OwnershipConflict]) -> String? {
        blocker(conflicts: conflicts)?.reason
    }
    /// Why migration cannot run now; nil when it can.
    public func blocker(conflicts: [OwnershipConflict]) -> MigrationBlocker? {
        if (try? provisioner.requireManagementEnabled()) == nil { return .developerMode }
        if (try? installer.verifyManaged()) == nil { return .notSetUp }
        let incomplete = (try? loadJournal()).map { !$0.complete && !$0.rolledBack } ?? false
        if conflicts.isEmpty && !incomplete { return .nothingToMigrate }
        if !controller("web").supports("rebind") { return .needsNewerRelease }
        return nil
    }
    /// Write-ahead journal. Resume re-queries core, so a crash between a command
    /// succeeding and its journal write never loses the previous executable.
    public func migrate() throws {
        try installer.verifyManaged()
        guard controller("web").supports("rebind") else { throw CLIProvisionerError.installFailed("Migration requires service rebind in a newer core release.") }
        var journal: MigrationJournal
        if let existing = try loadJournal(), !existing.complete, !existing.rolledBack { journal = existing }
        else {
            let states = try statuses()
            let conflicts = ConflictScanner(provisioner: provisioner).scan(services: states)
            guard !conflicts.isEmpty else { throw CLIProvisionerError.installFailed("No migration conflicts found.") }
            journal = MigrationJournal(id: UUID().uuidString, services: states.compactMap { status in
                guard status.installed, let binary = status.binary, binary != provisioner.managedBinary.path else { return nil }
                return .init(kind: status.kind, previousBinary: binary, wasRunning: status.running, confirmed: false, attempted: false)
            }, pathRecorded: false, complete: false, rolledBack: false)
            try save(journal)
        }
        do {
            for index in journal.services.indices {
                let previous = journal.services[index]
                let cli = controller(previous.kind)
                let current = try cli.currentStatus()
                journal.services[index].attempted = true
                try save(journal)
                if current.binary != provisioner.managedBinary.path { try cli.rebind(binary: provisioner.managedBinary.path) }
                let confirmed = try cli.currentStatus()
                guard confirmed.binary == provisioner.managedBinary.path,
                      !previous.wasRunning || confirmed.state == .ready else {
                    throw CLIProvisionerError.installFailed("Service migration verification failed for \(previous.kind).")
                }
                journal.services[index].confirmed = true
                try save(journal)
            }
            try migratePATH(&journal)
            journal.complete = true
            try save(journal)
        } catch {
            // Best effort is not success: keep the journal incomplete if rollback
            // cannot finish, allowing explicit recovery on the next launch.
            try? rollback()
            throw error
        }
    }
    private func migratePATH(_ journal: inout MigrationJournal) throws {
        let fm = provisioner.fileManager; let link = provisioner.pathLink
        if !journal.pathRecorded {
            if ConflictScanner.exists(link) {
                if let target = try? fm.destinationOfSymbolicLink(atPath: link.path) { journal.previousLinkTarget = target }
                else {
                    let attributes = try fm.attributesOfItem(atPath: link.path)
                    guard attributes[.type] as? FileAttributeType == .typeRegular else { throw CLIProvisionerError.unsafeLocation(link.path) }
                    journal.displacedFile = provisioner.supportDirectory.appendingPathComponent("migrated/\(journal.id)/term-llm").path
                }
            }
            journal.pathRecorded = true; try save(journal)
        }
        if let target = try? fm.destinationOfSymbolicLink(atPath: link.path),
           URL(fileURLWithPath: target, relativeTo: link.deletingLastPathComponent()).standardizedFileURL.path == provisioner.managedBinary.path { return }
        if let displaced = journal.displacedFile, !fm.fileExists(atPath: displaced) {
            try fm.createDirectory(at: URL(fileURLWithPath: displaced).deletingLastPathComponent(), withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try fm.moveItem(at: link, to: URL(fileURLWithPath: displaced))
        } else if let target = journal.previousLinkTarget, ConflictScanner.exists(link) {
            guard (try? fm.destinationOfSymbolicLink(atPath: link.path)) == target else { throw CLIProvisionerError.unsafeLocation(link.path) }
            try fm.removeItem(at: link)
        } else if ConflictScanner.exists(link) { throw CLIProvisionerError.unsafeLocation(link.path) }
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: provisioner.managedBinary.path)
    }
    public func rollback() throws {
        try installer.verifyManaged()
        guard var journal = try loadJournal(), !journal.rolledBack else { return }
        var serviceRecoveryFailed = false
        for previous in journal.services.reversed() where previous.attempted != false || previous.confirmed {
            guard provisioner.fileManager.isExecutableFile(atPath: previous.previousBinary) else {
                serviceRecoveryFailed = true; continue
            }
            do {
                let cli = controller(previous.kind)
                // Always restore the recorded path: the report that caused
                // verification failure is not evidence that rebind did nothing.
                try cli.rebind(binary: previous.previousBinary)
                let restored = try cli.currentStatus()
                if restored.binary != previous.previousBinary || (previous.wasRunning && restored.state != .ready) {
                    serviceRecoveryFailed = true
                }
            } catch { serviceRecoveryFailed = true }
        }
        if journal.pathRecorded {
            let fm = provisioner.fileManager; let link = provisioner.pathLink
            _ = provisioner.removePATHLink()
            if let displaced = journal.displacedFile, fm.fileExists(atPath: displaced) {
                guard !ConflictScanner.exists(link) else { throw CLIProvisionerError.unsafeLocation(link.path) }
                try fm.moveItem(at: URL(fileURLWithPath: displaced), to: link)
            } else if let target = journal.previousLinkTarget, !ConflictScanner.exists(link) {
                try fm.createSymbolicLink(atPath: link.path, withDestinationPath: target)
            }
        }
        guard !serviceRecoveryFailed else {
            throw CLIProvisionerError.installFailed("Some previous service binaries are missing or could not be restored. Migration remains incomplete; recover using its journal.")
        }
        journal.rolledBack = true; journal.complete = false; try save(journal)
    }
    /// Separate explicitly confirmed final step; never used by migrate().
    public func removeHomebrewCopy(brewCandidates: [URL] = [URL(fileURLWithPath: "/opt/homebrew/bin/brew"), URL(fileURLWithPath: "/usr/local/bin/brew")]) throws {
        try installer.verifyManaged()
        guard try loadJournal()?.complete == true,
              let brew = brewCandidates.first(where: { provisioner.fileManager.isExecutableFile(atPath: $0.path) }) else {
            throw CLIProvisionerError.installFailed("Complete migration before removing Homebrew's copy.")
        }
        let env = ["HOMEBREW_NO_AUTO_UPDATE": "1"]
        let dependents = try provisioner.runner.run(executable: brew, arguments: ["uses", "--installed", "term-llm"], environment: env, timeout: 60)
        guard dependents.succeeded, dependents.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIProvisionerError.installFailed("Homebrew has dependents or could not check them; its copy was left untouched.")
        }
        let result = try provisioner.runner.run(executable: brew, arguments: ["uninstall", "term-llm"], environment: env, timeout: 120)
        try controller("web").requireSuccess(result)
    }
}
