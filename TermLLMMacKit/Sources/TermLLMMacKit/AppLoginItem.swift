import Foundation

/// The menu-bar app's own launch-at-login preference.
///
/// This is deliberately separate from the core service's autostart: one brings
/// up the GUI, the other brings up the local server. The plist is owned by this
/// companion (marker checked before any write or delete) and launchd remains the
/// mechanism; there is no app-specific watchdog.
public struct AppLoginItem: Sendable {
    public static let label = "com.term-llm.companion.menubar"
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

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                fileManager: FileManager = .default) {
        self.home = home
        self.fileManager = fileManager
    }

    public var plistURL: URL {
        home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent(Self.label + ".plist")
    }

    /// True only for a plist this companion wrote. An unrelated agent with the
    /// same name is never reported as ours or removed.
    public var isEnabled: Bool {
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
            "AssociatedBundleIdentifiers": ["com.termllm.companion"],
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist,
                                                  format: .xml,
                                                  options: 0)
    }

    /// Writes the app's own launch agent for the next login. It deliberately
    /// does not bootstrap the job now: the app is already running, and forcing
    /// an immediate load would start a duplicate process (LaunchServices
    /// single-instance rules do not apply to a direct launchd exec). The plist
    /// is read by launchd at login, and disabling only removes this owned file
    /// so the running app is never terminated as a side effect.
    public func enable(appExecutable: URL) throws {
        guard fileManager.isExecutableFile(atPath: appExecutable.path) else {
            throw LoginItemError.appNotExecutable(appExecutable.path)
        }
        let directory = plistURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o755])
        } catch {
            throw LoginItemError.writeFailed(error.localizedDescription)
        }
        if fileManager.fileExists(atPath: plistURL.path) && !isEnabled {
            throw LoginItemError.foreignFile(plistURL.path)
        }
        do {
            try plistData(appExecutable: appExecutable).write(to: plistURL, options: [.atomic])
            try? fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plistURL.path)
        } catch {
            throw LoginItemError.writeFailed(error.localizedDescription)
        }
    }

    public func disable() throws {
        guard fileManager.fileExists(atPath: plistURL.path) else {
            // Already off (another instance or a prior clean disable); toggling
            // off is idempotent rather than an error.
            return
        }
        guard isEnabled else { throw LoginItemError.foreignFile(plistURL.path) }
        do {
            try fileManager.removeItem(at: plistURL)
        } catch {
            throw LoginItemError.writeFailed(error.localizedDescription)
        }
    }

    /// Rewrites a stale executable path after the app has been moved, but only
    /// for our own plist.
    public func refreshIfNeeded(appExecutable: URL) {
        guard isEnabled, let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let arguments = plist["ProgramArguments"] as? [String],
              arguments.first != appExecutable.path else { return }
        try? enable(appExecutable: appExecutable)
    }

}
