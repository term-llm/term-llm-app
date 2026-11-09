import Foundation
import SwiftUI

/// The few system services shared code needs, behind one platform seam.
/// iPhone/iPad use UIKit; the native Mac target uses AppKit (see TermLLMMac/).
/// Keep platform differences here instead of scattering UIKit/AppKit calls.

#if os(iOS)
import UIKit

typealias PlatformImage = UIImage
typealias NativeWindowScene = UIWindowScene
typealias NativeSceneSession = UISceneSession

extension Image {
    init(platformImage: PlatformImage) { self.init(uiImage: platformImage) }
}

extension PlatformImage {
    static func fromCGImage(_ image: CGImage) -> PlatformImage { UIImage(cgImage: image) }
    var platformCGImage: CGImage? { cgImage }
}

/// A scene's identity and activation, as push routing and presence use them.
extension UIWindowScene {
    var sceneIdentifier: String { session.persistentIdentifier }
    var sceneSession: UISceneSession { session }
    var isForegroundActive: Bool { activationState == .foregroundActive }
    var isAttachedToApp: Bool { activationState != .unattached }
    var hasKeyWindow: Bool { windows.contains(where: \.isKeyWindow) }
}

enum NativeAppState: Equatable { case active, inactive, background }

@MainActor
enum NativeApp {
    static var state: NativeAppState {
        switch UIApplication.shared.applicationState {
        case .active: .active
        case .background: .background
        default: .inactive
        }
    }
    static var supportsMultipleScenes: Bool { UIApplication.shared.supportsMultipleScenes }
    static var openSceneIdentifiers: Set<String> { Set(UIApplication.shared.openSessions.map(\.persistentIdentifier)) }
    static func openSession(identifier: String) -> UISceneSession? {
        UIApplication.shared.openSessions.first { $0.persistentIdentifier == identifier }
    }
    static func activate(_ session: UISceneSession?, activity: NSUserActivity, failed: @escaping (Error) -> Void) {
        UIApplication.shared.requestSceneSessionActivation(session, userActivity: activity, options: nil, errorHandler: failed)
    }
    static func registerForRemoteNotifications() { UIApplication.shared.registerForRemoteNotifications() }
    static func open(_ url: URL) { UIApplication.shared.open(url) }
    /// Opens this app's page in system Settings (notification permission lives there).
    static var notificationSettingsURL: URL? { URL(string: UIApplication.openNotificationSettingsURLString) }
    static var appSettingsURL: URL? { URL(string: UIApplication.openSettingsURLString) }
    static func copy(_ string: String) { UIPasteboard.general.string = string }
    static func copy(_ url: URL) { UIPasteboard.general.url = url }
    /// The key window, for system sheets such as web authentication.
    static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
    }

    nonisolated static let didEnterBackground = UIApplication.didEnterBackgroundNotification
    nonisolated static let willEnterForeground = UIApplication.willEnterForegroundNotification
    nonisolated static let willTerminate = UIApplication.willTerminateNotification
    nonisolated static let didReceiveMemoryWarning = UIApplication.didReceiveMemoryWarningNotification
}

@MainActor
enum NativeDevice {
    static var model: String { UIDevice.current.model }
    static var name: String { UIDevice.current.name }
    static var systemName: String { UIDevice.current.systemName }
    static var systemVersion: String { UIDevice.current.systemVersion }
    /// For diagnostics: the OS family, whatever the device's own name for it.
    static var platformName: String { "iOS" }
    /// Hardware identifier, such as "iPhone17,1".
    static var modelIdentifier: String {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: system.machine) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
    }

    struct Battery { var level: Float?; var state: String }

    static func battery() -> Battery {
        let device = UIDevice.current
        // Also enabled by the health sampler; never switched off again.
        if !device.isBatteryMonitoringEnabled { device.isBatteryMonitoringEnabled = true }
        let state = switch device.batteryState {
        case .charging: "charging"
        case .full: "full"
        case .unplugged: "unplugged"
        default: "unknown"
        }
        return Battery(level: device.batteryLevel >= 0 ? device.batteryLevel : nil, state: state)
    }

    static func lightImpact() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
}

extension Color {
    static var platformBackground: Color { Color(.systemBackground) }
    static var platformGroupedBackground: Color { Color(.systemGroupedBackground) }
    static var platformSecondaryGroupedBackground: Color { Color(.secondarySystemGroupedBackground) }
    static var platformSecondaryBackground: Color { Color(.secondarySystemBackground) }
    static var platformTertiaryFill: Color { Color(.tertiarySystemFill) }
    static var platformGray5: Color { Color(.systemGray5) }
}

extension UIView {
    /// The scene this view is shown in.
    @MainActor var nativeScene: NativeWindowScene? { window?.windowScene }
    /// Releases keyboard focus held inside this view.
    @MainActor func resignNativeFocus() { endEditing(true) }
}

extension View {
    func inlineNavigationTitle() -> some View { navigationBarTitleDisplayMode(.inline) }
    func urlTextEntry() -> some View {
        textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never)
    }
    func noAutocapitalization() -> some View { textInputAutocapitalization(.never) }
    func platformInsetGroupedListStyle() -> some View { listStyle(.insetGrouped) }
}

extension ToolbarItemPlacement {
    static var platformLeading: ToolbarItemPlacement { .topBarLeading }
    static var platformTrailing: ToolbarItemPlacement { .topBarTrailing }
}

extension SearchFieldPlacement {
    static var platformAlwaysVisible: SearchFieldPlacement { .navigationBarDrawer(displayMode: .always) }
}

extension View {
    func navigationBarVisibility(_ visibility: Visibility) -> some View { toolbar(visibility, for: .navigationBar) }
}

typealias PlatformEditMode = EditMode
typealias PlatformEditButton = EditButton

extension View {
    func platformEditMode(_ mode: Binding<EditMode>) -> some View { environment(\.editMode, mode) }
}

#elseif os(macOS)
import AppKit
import IOKit.ps

typealias PlatformImage = NSImage
/// The Mac client has exactly one retained window (see MacClientWindow).
typealias NativeWindowScene = MacClientWindow
typealias NativeSceneSession = MacClientWindow

extension Image {
    init(platformImage: PlatformImage) { self.init(nsImage: platformImage) }
}

extension PlatformImage {
    static func fromCGImage(_ image: CGImage) -> PlatformImage {
        NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
    var platformCGImage: CGImage? { cgImage(forProposedRect: nil, context: nil, hints: nil) }
}

enum NativeAppState: Equatable { case active, inactive, background }

@MainActor
enum NativeApp {
    /// Follows the client window, not the process: a hidden, minimized or
    /// app-hidden window is background even though the app keeps running.
    static var state: NativeAppState { MacClientWindow.shared.appState }
    static var supportsMultipleScenes: Bool { false }
    static var openSceneIdentifiers: Set<String> { [MacClientWindow.shared.sceneIdentifier] }
    static func openSession(identifier: String) -> MacClientWindow? {
        MacClientWindow.shared.sceneIdentifier == identifier ? MacClientWindow.shared : nil
    }
    /// One window: there is never another scene to activate. Bring it forward.
    static func activate(_ session: MacClientWindow?, activity: NSUserActivity, failed: @escaping (Error) -> Void) {
        MacClientWindow.shared.show()
    }
    static func registerForRemoteNotifications() { NSApplication.shared.registerForRemoteNotifications() }
    static func open(_ url: URL) { NSWorkspace.shared.open(url) }
    static var notificationSettingsURL: URL? {
        URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")")
    }
    /// Privacy & Security ▸ Media & Apple Music, where MusicKit access lives.
    static var appSettingsURL: URL? { URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Media") }
    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
    static func copy(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
    }
    /// The key window, for system sheets such as web authentication.
    static var keyWindow: NSWindow? { NSApp.keyWindow ?? MacClientWindow.shared.window }

    nonisolated static let didEnterBackground = MacClientWindow.didEnterBackgroundNotification
    nonisolated static let willEnterForeground = MacClientWindow.willEnterForegroundNotification
    nonisolated static let willTerminate = NSApplication.willTerminateNotification
    /// macOS has no app memory warning; the window sends this on critical memory pressure.
    nonisolated static let didReceiveMemoryWarning = MacClientWindow.didReceiveMemoryWarningNotification
}

@MainActor
enum NativeDevice {
    static var model: String { "Mac" }
    static var name: String { Host.current().localizedName ?? "Mac" }
    static var systemName: String { "macOS" }
    static var platformName: String { "macOS" }
    /// Hardware identifier, such as "Mac16,13".
    static var modelIdentifier: String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "Mac" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "Mac" }
        return String(decoding: bytes.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
    }
    static var systemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion)" + (version.patchVersion > 0 ? ".\(version.patchVersion)" : "")
    }

    struct Battery { var level: Float?; var state: String }

    /// The internal battery, if this Mac has one; desktop Macs report unknown.
    static func battery() -> Battery {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return Battery(level: nil, state: "unknown")
        }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = description[kIOPSCurrentCapacityKey] as? Int
            let maximum = description[kIOPSMaxCapacityKey] as? Int
            let level = current.flatMap { current in maximum.flatMap { $0 > 0 ? Float(current) / Float($0) : nil } }
            let charging = description[kIOPSIsChargingKey] as? Bool
            let onAC = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let charged = description[kIOPSIsChargedKey] as? Bool == true
            let state = charged || (onAC && charging == false && (level ?? 0) >= 0.99) ? "full"
                : charging == true ? "charging" : onAC ? "unknown" : "unplugged"
            return Battery(level: level, state: state)
        }
        return Battery(level: nil, state: "unknown")
    }

    static func lightImpact() {}
}

extension Color {
    static var platformBackground: Color { Color(nsColor: .textBackgroundColor) }
    static var platformGroupedBackground: Color { Color(nsColor: .windowBackgroundColor) }
    static var platformSecondaryGroupedBackground: Color { Color(nsColor: .controlBackgroundColor) }
    static var platformSecondaryBackground: Color { Color(nsColor: .underPageBackgroundColor) }
    static var platformTertiaryFill: Color { Color(nsColor: .quaternaryLabelColor) }
    static var platformGray5: Color { Color(nsColor: .separatorColor) }
}

extension NSView {
    /// Releases keyboard focus held inside this view.
    @MainActor func resignNativeFocus() {
        guard let window, let responder = window.firstResponder as? NSView,
              responder === self || responder.isDescendant(of: self) else { return }
        window.makeFirstResponder(nil)
    }
}

/// Touch-keyboard and navigation-bar presentation has no Mac equivalent.
extension View {
    func inlineNavigationTitle() -> some View { self }
    func urlTextEntry() -> some View { self }
    func noAutocapitalization() -> some View { self }
    func platformInsetGroupedListStyle() -> some View { listStyle(.inset) }
}

extension ToolbarItemPlacement {
    static var platformLeading: ToolbarItemPlacement { .navigation }
    static var platformTrailing: ToolbarItemPlacement { .primaryAction }
}

extension SearchFieldPlacement {
    static var platformAlwaysVisible: SearchFieldPlacement { .automatic }
}

extension View {
    /// A Mac window has one title bar for every destination; hiding it would
    /// also remove the window controls.
    func navigationBarVisibility(_ visibility: Visibility) -> some View { self }
}

/// Mac lists reorder by dragging rows directly; there is no edit mode.
enum PlatformEditMode: Equatable {
    case inactive, active
    var isEditing: Bool { self == .active }
}

struct PlatformEditButton: View {
    var body: some View { EmptyView() }
}

extension View {
    func platformEditMode(_ mode: Binding<PlatformEditMode>) -> some View { self }
}
#endif
