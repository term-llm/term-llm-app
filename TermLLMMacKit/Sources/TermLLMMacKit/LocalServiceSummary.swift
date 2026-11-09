import Foundation

/// What the simple Local Service view shows: one headline, one next step and at
/// most one notice. Paths, versions and every other control live in Advanced.
/// Pure, so each state is testable without AppKit or a live service.
public struct LocalServiceSummary: Equatable, Sendable {
    public enum Tone: Equatable, Sendable { case off, ok, busy, attention, problem }

    public enum Action: Equatable, Sendable {
        case setUp, repair, createService, repairService, startService, stopService, restartService,
             openChat, migrate, resumeMigration, finishUpdate, checkForUpdates, removeHomebrewCopy,
             leaveDeveloperMode

        public var title: String {
            switch self {
            case .setUp: return "Set Up term-llm"
            case .repair: return "Repair"
            case .createService: return "Start Local Service"
            case .repairService: return "Repair Service"
            case .startService: return "Start"
            case .stopService: return "Stop"
            case .restartService: return "Restart"
            case .openChat: return "Open Chat"
            case .migrate: return "Switch to the App's Copy…"
            case .resumeMigration: return "Finish Switching…"
            case .finishUpdate: return "Restart Service…"
            case .checkForUpdates: return "Try Again"
            case .removeHomebrewCopy: return "Remove Homebrew's Copy…"
            case .leaveDeveloperMode: return "Leave Developer Mode"
            }
        }
    }

    public struct Notice: Equatable, Sendable {
        public var tone: Tone = .attention
        public var text: String
        public var action: Action?
        public var actionEnabled = true
        /// Why the action is unavailable, when it is.
        public var footnote: String?
    }

    public var tone: Tone
    public var title: String
    public var detail: String
    public var primary: Action?
    public var primaryEnabled = true
    /// Why the primary action is unavailable, when it is.
    public var primaryNote: String?
    public var secondary: Action?
    public var notice: Notice?
}

/// Model state the summary is derived from.
public struct LocalServiceFacts: Sendable {
    public var home: String
    public var managedBinary: String
    /// Set while an action runs.
    public var busyMessage: String?
    public var developerModeEnabled = false
    public var developerBinary: String?
    public var selection: CLISelection?
    public var verifiedVersion: String?
    public var ownershipError: String?
    public var handedOver = false
    public var service: ServiceStatus?
    public var serviceError: String?
    public var conflicts: [OwnershipConflict] = []
    public var migrationBlocker: MigrationBlocker?
    public var migration: MigrationJournal?
    public var updates = CLIUpdateState()

    public init(home: String, managedBinary: String) {
        self.home = home
        self.managedBinary = managedBinary
    }

    /// Abbreviates the home directory as `~`.
    public func tilde(_ path: String) -> String {
        guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    var migrationIncomplete: Bool { migration.map { !$0.complete && !$0.rolledBack } ?? false }
}

extension LocalServiceSummary {
    public static func make(_ facts: LocalServiceFacts) -> LocalServiceSummary {
        var summary = base(facts)
        guard let busy = facts.busyMessage else { return summary }
        summary.tone = .busy
        summary.detail = busy
        summary.primaryEnabled = false
        summary.primaryNote = nil
        summary.secondary = nil
        summary.notice?.actionEnabled = false
        return summary
    }

    private static func base(_ f: LocalServiceFacts) -> LocalServiceSummary {
        if f.developerModeEnabled {
            guard let binary = f.developerBinary else {
                return LocalServiceSummary(tone: .problem, title: "Developer Mode can't find its term-llm",
                                           detail: "The executable you chose is missing or can't run.",
                                           primary: .leaveDeveloperMode)
            }
            var summary = service(f, ownBinary: binary, installed: "term-llm")
            // Show which build runs; the version isn't verified in Developer Mode.
            if summary.detail == "term-llm" { summary.detail = f.tilde(binary) }
            summary.notice = Notice(tone: .off, text: "Developer Mode is on, so the app isn't installing or updating term-llm.",
                                    action: .leaveDeveloperMode)
            return summary
        }
        if f.ownershipError != nil {
            return LocalServiceSummary(tone: .problem, title: "term-llm needs repair",
                                       detail: "The app's copy no longer passes its signature check.", primary: .repair)
        }
        guard let selection = f.selection, selection.source == .release else {
            if f.handedOver {
                return LocalServiceSummary(tone: .off, title: "term-llm updates itself",
                                           detail: "The app no longer manages it. Set it up again to let the app keep it up to date.",
                                           primary: .setUp)
            }
            if f.selection != nil {
                return LocalServiceSummary(tone: .attention, title: "term-llm needs setting up again",
                                           detail: "Install the signed release so the app can keep it up to date.", primary: .setUp)
            }
            return LocalServiceSummary(tone: .off, title: "term-llm isn't set up on this Mac",
                                       detail: "Set it up to run term-llm here. Remote connections don't need it.", primary: .setUp)
        }
        guard let version = f.verifiedVersion else {
            return LocalServiceSummary(tone: .busy, title: "Checking term-llm…", detail: "Verifying the app's copy.")
        }
        var summary = service(f, ownBinary: f.managedBinary, installed: "term-llm \(version)")
        if summary.notice == nil { summary.notice = notice(f) }
        return summary
    }

    private static func service(_ f: LocalServiceFacts, ownBinary: String, installed: String) -> LocalServiceSummary {
        guard let service = f.service else {
            if let error = f.serviceError {
                return LocalServiceSummary(tone: .problem, title: "Can't check the local service", detail: firstLine(error))
            }
            return LocalServiceSummary(tone: .busy, title: "\(installed) is installed", detail: "Checking the local service…")
        }
        var summary = state(of: service, installed: installed)
        guard !f.developerModeEnabled, service.installed, let binary = service.binary, !binary.isEmpty, binary != ownBinary else {
            return summary
        }
        // Another copy runs the service. It can still be chatted with, started,
        // stopped and restarted; only reinstalling would replace its binary.
        let reinstall: [Action] = [.createService, .repairService]
        if let primary = summary.primary, reinstall.contains(primary) { summary.primary = nil }
        if service.state == .ready || service.state == .stopped { summary.detail = "Using \(describe(binary, f))" }
        summary.notice = switchNotice(f, "The app doesn't manage this copy of term-llm, so it won't update it.")
        return summary
    }

    /// Ownership notices are informational: they offer the switch when it can
    /// run and otherwise just say when it will be possible.
    private static func switchNotice(_ f: LocalServiceFacts, _ text: String,
                                     action: Action? = nil, available: Bool? = nil) -> Notice {
        let blocked = f.migrationBlocker
        let canAct = available ?? (blocked == nil)
        return Notice(tone: .off, text: text,
                      action: canAct ? (action ?? (f.migrationIncomplete ? .resumeMigration : .migrate)) : nil,
                      footnote: canAct ? nil : blocked == .needsNewerRelease
                          ? "Switching to the app's copy needs a newer term-llm release." : blocked?.shortReason)
    }

    private static func state(of service: ServiceStatus, installed: String) -> LocalServiceSummary {
        switch service.state {
        case .notInstalled:
            return LocalServiceSummary(tone: .off, title: "\(installed) is installed",
                                       detail: "The local service isn't set up yet.", primary: .createService)
        case .notRegistered:
            return LocalServiceSummary(tone: .attention, title: "The local service needs repair",
                                       detail: "Its settings exist, but macOS isn't running it.", primary: .repairService)
        case .unmanaged:
            return LocalServiceSummary(tone: .attention, title: "Another local service is in the way",
                                       detail: "A term-llm service that the app can't manage is registered. The app leaves it alone.")
        case .stopped:
            return LocalServiceSummary(tone: .off, title: "Local service is stopped", detail: installed, primary: .startService)
        case .unhealthy:
            return LocalServiceSummary(tone: .problem, title: "Local service isn't responding",
                                       detail: firstLine(service.healthError ?? "Its health check failed."),
                                       primary: .restartService, secondary: .stopService)
        case .error:
            return LocalServiceSummary(tone: .problem, title: "Local service error",
                                       detail: firstLine(service.error ?? "The service manager reported an error."))
        case .ready:
            if service.auth == "passkey" {
                let pending = service.enrollment == .pending
                return LocalServiceSummary(tone: pending ? .attention : .ok, title: "Running",
                                           detail: pending ? "Finish passkey setup in your browser to sign in."
                                                           : "\(installed) · signs in with a passkey in your browser",
                                           secondary: .stopService)
            }
            return LocalServiceSummary(tone: .ok, title: "Running", detail: installed, primary: .openChat, secondary: .stopService)
        }
    }

    /// The single most useful follow-up for a managed install, if any.
    private static func notice(_ f: LocalServiceFacts) -> Notice? {
        if f.migrationIncomplete {
            return Notice(text: "Switching to the app's copy didn't finish.", action: .resumeMigration,
                          actionEnabled: f.migrationBlocker == nil, footnote: f.migrationBlocker?.shortReason)
        }
        if !f.updates.pendingRestart.isEmpty {
            return Notice(text: "An update is installed. Restart the local service to finish.", action: .finishUpdate)
        }
        // Other commands on PATH are listed in Advanced; the switch doesn't touch them.
        let actionable = f.conflicts.filter { if case .foreignCommand = $0 { return false }; return true }
        let homebrew = actionable.contains { if case .homebrewFormula = $0 { return true }; return false }
        if let conflict = actionable.first(where: { if case .homebrewFormula = $0 { return false }; return true }) {
            let text: String
            switch conflict {
            case .serviceBinary(let kind, _): text = "Your \(kind) service uses another copy of term-llm."
            case .pathLinkOccupied: text = "The term-llm command in Terminal runs another copy."
            default: text = "The app was set up to use another copy of term-llm."
            }
            return switchNotice(f, text)
        }
        if homebrew {
            let switched = f.migration?.complete == true
            return switchNotice(f, "Homebrew's term-llm is also installed.", action: .removeHomebrewCopy,
                                available: switched || f.migrationBlocker == nil)
        }
        if f.updates.lastError != nil {
            return Notice(text: "Couldn't update term-llm.", action: .checkForUpdates)
        }
        return nil
    }

    static func describe(_ binary: String, _ f: LocalServiceFacts) -> String {
        if binary.contains("/Cellar/") || binary.hasPrefix("/opt/homebrew/") { return "Homebrew's term-llm" }
        return f.tilde(binary)
    }

    static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? text
        return line.count > 160 ? String(line.prefix(159)) + "…" : line
    }
}

extension OwnershipConflict {
    /// One short line for the Advanced list.
    public func displayText(tilde: (String) -> String) -> String {
        switch self {
        case .homebrewFormula(let path): return "Homebrew: \(tilde(path))"
        case .foreignCommand(let path, let resolved):
            return path == resolved ? "Also installed: \(tilde(path))" : "Also installed: \(tilde(path)) → \(tilde(resolved))"
        case .pathLinkOccupied(let path, let target): return "Terminal command: \(tilde(path)) → \(tilde(target))"
        case .serviceBinary(let kind, let binary): return "\(kind.prefix(1).uppercased() + kind.dropFirst()) service: \(tilde(binary))"
        case .legacyExternalSelection(let path): return "Earlier setup: \(tilde(path))"
        }
    }
}
