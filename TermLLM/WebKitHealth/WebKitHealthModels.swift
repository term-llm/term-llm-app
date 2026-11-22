import Foundation

enum WebKitTeardownReason: String, Codable, Sendable, Equatable {
    case hiddenActivity = "hidden_activity"
    case thermal
    case manual

    var title: String {
        switch self {
        case .hiddenActivity: "The chat page kept working off screen"
        case .thermal: "The phone was hot"
        case .manual: "Chat page paused"
        }
    }

    /// Off-screen stops reopen by themselves when Chat is shown again. A
    /// manually paused page waits for an explicit reload.
    var resumesAutomatically: Bool { self == .hiddenActivity || self == .thermal }
}

/// A chat page whose web view was closed to stop its web process.
struct WebKitParkedPage: Equatable {
    let id = UUID()
    let reason: WebKitTeardownReason
    let detail: String
    let restoreURL: URL?
    let sourceID: UUID?
    let browserIdentity: UUID?
    /// Native destination at the time; a newer one (another chat) wins on resume.
    let destinationID: UUID?
    let date = Date()
}

/// Native facts about a browser view that its page cannot report itself.
struct WebKitPageContext: Equatable, Sendable {
    /// On screen in the active app and not covered by sign-in or error screens.
    var userCanSee = false
    var appBackground = false
    var inWindow = false
    var viewHidden = false
    var capturing = false
    var voiceLaunching = false
    var toolCalls = 0
    var signingIn = false
    var loading = false

    /// Work a teardown would break: a live call, a voice launch, a device tool reply, sign-in.
    var protectsPage: Bool { capturing || voiceLaunching || toolCalls > 0 || signingIn }
}

struct TimedPageSample: Equatable, Sendable {
    let uptime: TimeInterval
    let sample: WebPageHealthSample
}

struct WebKitHealthEvent: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    let date: Date
    let kind: String
    let message: String
}

struct WebKitHealthFinding: Identifiable, Equatable, Sendable {
    enum Severity: Int, Comparable, Sendable {
        case info, warning, critical
        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }
    let id: String
    let severity: Severity
    let title: String
    let detail: String
}

/// One wall-clock minute, kept for a few hours and persisted across launches.
struct WebKitHealthMinute: Codable, Equatable, Sendable {
    var start: Date
    var app: Double?
    var appPeak: Double?
    var device: Double?
    var devicePeak: Double?
    var thermal: Int
    var battery: Int?
    var charging: Bool?
    var foreground: Double
    var chatOnScreen: Double
    var pageReports: Int
    var pageVisible: Double?
    var busy: Double?
    var fps: Double?
    var animations: Int?
    var repainting: Int?
    var mutations: Double?
    var requests: Double?
    var audio: Int?
    var webViews: Int
    var memoryMB: Int?
    /// Share of one core the page probe used.
    var probe: Double?
    /// Share of one core this monitor used in the app process.
    var monitor: Double?
}

/// Everything the diagnostics screen shows, refreshed every sample.
struct WebKitHealthStatus: Equatable {
    enum PageState: Equatable {
        case none
        case loading
        case waiting
        case active
        case stalled(TimeInterval)
        case offScreenAwake
        case offScreenQuiet
    }

    var native: NativeHealthSample?
    var appCPUMinute: Double?
    var deviceCPUMinute: Double?
    var pageState: PageState = .none
    var context = WebKitPageContext()
    var latest: WebPageHealthSample?
    var lastReportAge: TimeInterval?
    /// Opening diagnostics takes Chat off screen, so also keep what the page
    /// last reported while it was visible.
    var lastOnScreen: WebPageHealthSample?
    var lastOnScreenAge: TimeInterval?
    var findings: [WebKitHealthFinding] = []
    var threads: [ThreadUsage] = []
    var webViewsAlive = 0
    var pages = 0
    var parked: WebKitParkedPage?
    /// What watching costs, as a share of one core: this monitor's own work in
    /// the app since launch, and the page probe over the last minute.
    var monitorShare: Double?
    var probeShare: Double?
}
