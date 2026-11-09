import Foundation
import ServiceManagement

/// Registration state of the app in System Settings › General › Login Items.
public enum MainAppLoginStatus: Equatable, Sendable {
    case notRegistered, enabled, requiresApproval, notFound
}

/// The system's Open at Login registration for the running app. Injectable so
/// tests never register a test executable as the user's login item.
public protocol MainAppLoginService: Sendable {
    var status: MainAppLoginStatus { get }
    func register() throws
    func unregister() throws
}

/// `SMAppService.mainApp`: listed under Open at Login with the app's own name and
/// icon, instead of a launch agent under Allow in the Background.
public struct SystemMainAppLoginService: MainAppLoginService {
    public init() {}

    public var status: MainAppLoginStatus {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        case .notRegistered: return .notRegistered
        @unknown default: return .notRegistered
        }
    }

    public func register() throws { try SMAppService.mainApp.register() }
    public func unregister() throws { try SMAppService.mainApp.unregister() }
}

/// The unified Mac app's own launch-at-login preference.
///
/// This is deliberately separate from the core service's autostart: one brings
/// up the GUI, the other brings up the local server. It uses the system Open at
/// Login registration. The older launch agent remains only as a fallback for
/// builds that can't register (for example unsigned development builds) and is
/// migrated away whenever registration works. The plist is owned by this app
/// (marker checked before any write or delete); there is no app-specific watchdog.
public struct AppLoginItem: Sendable {
    // Keep the legacy label/marker so an opted-in companion login preference
    // migrates to the full app rather than creating two launch agents.
    public static let label = "com.term-llm.companion.menubar"
    public static let bundleIdentifier = "com.termllm.app"
    public static let markerKey = "TermLLMCompanionOwner"
    public static let markerValue = "app-login-item-v1"

    public enum LoginItemError: Error, LocalizedError, Equatable {
        case appNotExecutable(String)
        case foreignFile(String)
        case writeFailed(String)
        case notEnabled

        public var errorDescription: String? {
            switch self {
            case .appNotExecutable(let path): return "The app executable is missing at \(path)."
            case .foreignFile(let path):
                return "A launch agent that this app does not own already exists at \(path); it was left untouched."
            case .writeFailed(let reason): return "Could not write the login item: \(reason)"
            case .notEnabled: return "The app is not set to open at login."
            }
        }
    }

    public let home: URL
    public let fileManager: FileManager
    /// nil uses only the launch agent.
    public let mainApp: MainAppLoginService?

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                fileManager: FileManager = .default,
                mainApp: MainAppLoginService? = nil) {
        self.home = home
        self.fileManager = fileManager
        self.mainApp = mainApp
    }

    /// The system registration, but only inside TermLLM.app itself: tests and
    /// other executables must never register themselves as a login item.
    public static var systemService: MainAppLoginService? {
        Bundle.main.bundleIdentifier == bundleIdentifier ? SystemMainAppLoginService() : nil
    }

    public var plistURL: URL {
        home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent(Self.label + ".plist")
    }

    public var isEnabled: Bool { isRegistered || legacyEnabled }

    /// Registered, but macOS still needs the user to allow it in Login Items.
    public var needsApproval: Bool { mainApp?.status == .requiresApproval }

    private var isRegistered: Bool {
        guard let status = mainApp?.status else { return false }
        return status == .enabled || status == .requiresApproval
    }

    /// True only for a launch agent this app wrote. An unrelated agent with the
    /// same name is never reported as ours or removed.
    public var legacyEnabled: Bool {
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return false
        }
        return plist[Self.markerKey] as? String == Self.markerValue
    }

    public func plistData(appExecutable: URL) throws -> Data {
        let plist: [String: Any] = [
            "Label": Self.label,
            Self.markerKey: Self.markerValue,
            "ProgramArguments": [appExecutable.path],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
            "AssociatedBundleIdentifiers": [Self.bundleIdentifier],
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist,
                                                  format: .xml,
                                                  options: 0)
    }

    /// Opens the app at the next login. Prefers the system registration and
    /// removes the older launch agent once that works; otherwise writes the
    /// launch agent. The running app is never started a second time.
    public func enable(appExecutable: URL) throws {
        guard fileManager.isExecutableFile(atPath: appExecutable.path) else {
            throw LoginItemError.appNotExecutable(appExecutable.path)
        }
        if registerWithSystem() {
            if legacyEnabled { try removeLegacy() }
            return
        }
        try writeLegacy(appExecutable: appExecutable)
    }

    public func disable() throws {
        if isRegistered, let mainApp {
            do {
                try mainApp.unregister()
            } catch {
                throw LoginItemError.writeFailed(error.localizedDescription)
            }
            if legacyEnabled { try removeLegacy() }
            return
        }
        try removeLegacy()
    }

    /// Moves an older launch-agent login item to the system registration, or,
    /// when that isn't possible, rewrites a stale executable path after the app
    /// has moved. Only ever touches our own plist, and only if it exists.
    public func refreshIfNeeded(appExecutable: URL) {
        guard legacyEnabled else { return }
        if registerWithSystem() {
            try? removeLegacy()
            return
        }
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let arguments = plist["ProgramArguments"] as? [String],
              arguments.first != appExecutable.path ||
                plist["AssociatedBundleIdentifiers"] as? [String] != [Self.bundleIdentifier] else { return }
        try? writeLegacy(appExecutable: appExecutable)
    }

    private func registerWithSystem() -> Bool {
        guard let mainApp else { return false }
        if !isRegistered {
            // Unsigned development builds can fail here; the launch agent remains.
            do { try mainApp.register() } catch { return false }
        }
        return isRegistered
    }

    /// Writes the launch agent for the next login. It deliberately does not
    /// bootstrap the job now: the app is already running, and forcing an
    /// immediate load would start a duplicate process (LaunchServices
    /// single-instance rules do not apply to a direct launchd exec).
    private func writeLegacy(appExecutable: URL) throws {
        let directory = plistURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o755])
        } catch {
            throw LoginItemError.writeFailed(error.localizedDescription)
        }
        if fileManager.fileExists(atPath: plistURL.path) && !legacyEnabled {
            throw LoginItemError.foreignFile(plistURL.path)
        }
        do {
            try plistData(appExecutable: appExecutable).write(to: plistURL, options: [.atomic])
            try? fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plistURL.path)
        } catch {
            throw LoginItemError.writeFailed(error.localizedDescription)
        }
    }

    /// Removes only our own launch agent file, so the running app is never
    /// terminated as a side effect. Missing is already off.
    private func removeLegacy() throws {
        guard fileManager.fileExists(atPath: plistURL.path) else { return }
        guard legacyEnabled else { throw LoginItemError.foreignFile(plistURL.path) }
        do {
            try fileManager.removeItem(at: plistURL)
        } catch {
            throw LoginItemError.writeFailed(error.localizedDescription)
        }
    }
}
