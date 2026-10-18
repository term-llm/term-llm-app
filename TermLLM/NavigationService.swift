import Foundation
import Observation

/// Supplies device location. The real one wraps `CLLocationManager`.
@MainActor
protocol LocationProvider: AnyObject {
    /// A recent, reasonably accurate fix; asks for permission when needed.
    func currentFix() async throws -> LocationFix
    /// Starts continuous updates, replacing any previous handler.
    func startUpdates(mode: TravelMode, _ handler: @escaping @MainActor (LocationFix) -> Void) async throws
    func stopUpdates()
}

/// Finds places and routes. The real one wraps MapKit.
@MainActor
protocol RoutePlanner: AnyObject {
    /// Places matching `query`, best first, searched around `near`.
    func search(_ query: String, near: Coordinate) async throws -> [NavigationPlace]
    func route(from: Coordinate, to: NavigationPlace, mode: TravelMode) async throws -> NavigationRoute
    /// The address or place at `coordinate` (reverse geocoding), if known.
    func describe(_ coordinate: Coordinate) async throws -> NavigationPlace?
}

/// A planned route the user has not started yet.
struct NavigationPreview: Equatable, Sendable {
    let id: String
    let place: NavigationPlace
    let otherMatches: [NavigationPlace]
    let mode: TravelMode
    let origin: Coordinate
    let route: NavigationRoute
    let createdAt: Date
}

/// One entry in the story of a walk: where the user was at a moment, and how
/// that related to the route then.
struct TrailPoint: Equatable, Sendable {
    enum Event: String, Sendable {
        case started, wentOffRoute = "went_off_route", backOnRoute = "back_on_route", rerouted, arrived
    }

    var time: Date
    var coordinate: Coordinate
    var accuracy: Double
    var speed: Double = -1
    /// Tracker state at the time, or "poor_gps" when the fix was too inaccurate to judge.
    var state: String
    var offRoute: Double?
    var remaining: Double?
    var event: Event?
}

/// The route being followed, and how the user is doing on it.
struct ActiveNavigation: Equatable, Sendable {
    let id: String
    let place: NavigationPlace
    let mode: TravelMode
    let startedAt: Date
    var tracker: RouteTracker
    /// Bumped each time the route is replaced by a reroute.
    var routeVersion = 1
    var rerouting = false
    var lastRerouteAt: Date?
    var rerouteError: String?
    /// Roughly one point a minute, plus one whenever something happened,
    /// limited to the recent window (see `NavigationService.trailWindow`).
    var trail: [TrailPoint] = []
    /// Whether older points have been dropped from the trail.
    var trailTruncated = false

    var route: NavigationRoute { tracker.route }

    /// A trail point for `fix` as the tracker currently sees it.
    func trailPoint(_ fix: LocationFix, time: Date? = nil, event: TrailPoint.Event?) -> TrailPoint {
        let judged = !tracker.poorAccuracy
        return TrailPoint(time: time ?? fix.timestamp, coordinate: fix.coordinate, accuracy: fix.horizontalAccuracy,
                          speed: fix.speed, state: judged ? tracker.state.rawValue : "poor_gps",
                          offRoute: judged ? tracker.progress?.offRouteDistance : nil,
                          remaining: judged ? tracker.progress?.remaining : nil, event: event)
    }

    mutating func record(_ point: TrailPoint) {
        trail.append(point)
        let cutoff = point.time.addingTimeInterval(-NavigationService.trailWindow)
        let stale = trail.prefix { $0.time < cutoff }.count
        let excess = trail.count - stale - NavigationService.maxTrailPoints
        let drop = stale + max(0, excess)
        if drop > 0 {
            trail.removeFirst(drop)
            trailTruncated = true
        }
    }

    /// The trail points within the window ending at `now`.
    func recentTrail(now: Date) -> (points: [TrailPoint], truncated: Bool) {
        let cutoff = now.addingTimeInterval(-NavigationService.trailWindow)
        let points = trail.filter { $0.time >= cutoff }
        return (points, trailTruncated || points.count < trail.count)
    }
}

/// Owns navigation on the device: planning, tracking the active route with
/// Core Location, and rerouting when the user leaves it. The agent drives it
/// through `NavigationTools`; nothing here talks to the server.
@MainActor
@Observable
final class NavigationService {
    static let shared = NavigationService(location: CoreLocationProvider(), planner: MapKitRoutePlanner())

    private(set) var active: ActiveNavigation?
    private(set) var previews: [NavigationPreview] = []

    @ObservationIgnored private let location: LocationProvider
    @ObservationIgnored private let planner: RoutePlanner
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let makeID: () -> String
    @ObservationIgnored private let thresholds: RouteTracker.Thresholds
    /// Time zone for the local times the tools report.
    @ObservationIgnored let timeZone: TimeZone
    @ObservationIgnored private var rerouteTask: Task<Void, Never>?
    @ObservationIgnored private var toolbox: NavigationTools!

    /// Previews older than this are re-planned from the current location on start.
    static let previewFreshness: TimeInterval = 5 * 60
    /// Minimum time between automatic reroutes.
    static let rerouteSpacing: TimeInterval = 15
    static let maxPreviews = 5
    /// How often the trail samples the user's position.
    static let trailInterval: TimeInterval = 60
    /// The trail covers at most this much recent time…
    nonisolated static let trailWindow: TimeInterval = 30 * 60
    /// …and at most this many points (a sample a minute plus room for events).
    nonisolated static let maxTrailPoints = 40

    init(location: LocationProvider, planner: RoutePlanner, now: @escaping () -> Date = Date.init,
         makeID: @escaping () -> String = { String(UUID().uuidString.prefix(8)).lowercased() },
         thresholds: RouteTracker.Thresholds = RouteTracker.Thresholds(), timeZone: TimeZone = .current) {
        self.timeZone = timeZone
        self.location = location
        self.planner = planner
        self.now = now
        self.makeID = makeID
        self.thresholds = thresholds
        toolbox = NavigationTools(service: self)
    }

    var tools: [DeviceTool] { toolbox.tools }

    // MARK: Location

    /// The device's current position and, best effort, the address there.
    func currentLocation(includeAddress: Bool) async throws -> (fix: LocationFix, place: NavigationPlace?) {
        let fix = try await location.currentFix()
        guard includeAddress else { return (fix, nil) }
        // An address is a nicety: a lookup failure still returns the fix.
        let place = try? await planner.describe(fix.coordinate)
        return (fix, place ?? nil)
    }

    /// The service's clock, so tools report fix age consistently in tests.
    var currentDate: Date { now() }

    // MARK: Planning

    func preview(destination: String, mode: TravelMode) async throws -> NavigationPreview {
        let fix = try await location.currentFix()
        let places = try await planner.search(destination, near: fix.coordinate)
        guard let place = places.first else { throw NavigationError.noPlaces(destination) }
        let route = try await planner.route(from: fix.coordinate, to: place, mode: mode)
        let preview = NavigationPreview(id: "p-" + makeID(), place: place, otherMatches: Array(places.dropFirst().prefix(4)),
                                        mode: mode, origin: fix.coordinate, route: route, createdAt: now())
        previews.append(preview)
        if previews.count > Self.maxPreviews { previews.removeFirst(previews.count - Self.maxPreviews) }
        return preview
    }

    // MARK: Tracking

    /// Starts following a preview (the latest when `previewID` is nil),
    /// replacing any active navigation.
    @discardableResult
    func start(previewID: String?) async throws -> ActiveNavigation {
        let preview: NavigationPreview
        if let previewID {
            guard let match = previews.first(where: { $0.id == previewID }) else { throw NavigationError.unknownPreview(previewID) }
            preview = match
        } else {
            guard let latest = previews.last else { throw NavigationError.noPreview }
            preview = latest
        }
        var route = preview.route
        if now().timeIntervalSince(preview.createdAt) > Self.previewFreshness {
            let fix = try await location.currentFix()
            route = try await planner.route(from: fix.coordinate, to: preview.place, mode: preview.mode)
        }
        stop()
        let navigation = ActiveNavigation(id: "n-" + makeID(), place: preview.place, mode: preview.mode, startedAt: now(),
                                          tracker: RouteTracker(route: route, destination: preview.place.coordinate,
                                                                thresholds: thresholds))
        active = navigation
        do {
            try await location.startUpdates(mode: preview.mode) { [weak self] fix in self?.receive(fix) }
        } catch {
            if active?.id == navigation.id { active = nil }
            throw error
        }
        return active ?? navigation
    }

    /// Ends navigation; returns what was stopped.
    @discardableResult
    func stop() -> ActiveNavigation? {
        rerouteTask?.cancel()
        rerouteTask = nil
        guard let stopped = active else { return nil }
        location.stopUpdates()
        active = nil
        return stopped
    }

    func receive(_ fix: LocationFix) {
        guard var navigation = active else { return }
        let before = navigation.tracker.state
        navigation.tracker.update(fix)
        let after = navigation.tracker.state
        var event: TrailPoint.Event?
        switch (before, after) {
        case _ where navigation.trail.isEmpty: event = .started
        case (.arrived, _): break
        case (_, .arrived): event = .arrived
        case (.onRoute, .offRoute): event = .wentOffRoute
        case (.offRoute, .onRoute): event = .backOnRoute
        default: break
        }
        if before != .arrived, event != nil
            || fix.timestamp.timeIntervalSince(navigation.trail.last?.time ?? .distantPast) >= Self.trailInterval {
            navigation.record(navigation.trailPoint(fix, event: event))
        }
        active = navigation
        switch navigation.tracker.state {
        case .arrived:
            // Keep reporting arrival, but stop using GPS.
            rerouteTask?.cancel()
            location.stopUpdates()
        case .offRoute:
            rerouteIfDue(from: fix)
        default:
            break
        }
    }

    private func rerouteIfDue(from fix: LocationFix) {
        guard var navigation = active, !navigation.rerouting else { return }
        if let last = navigation.lastRerouteAt, now().timeIntervalSince(last) < Self.rerouteSpacing { return }
        navigation.rerouting = true
        navigation.lastRerouteAt = now()
        active = navigation
        let id = navigation.id
        rerouteTask = Task { [weak self, planner] in
            let result: Result<NavigationRoute, Error>
            do { result = .success(try await planner.route(from: fix.coordinate, to: navigation.place, mode: navigation.mode)) }
            catch { result = .failure(error) }
            guard !Task.isCancelled else { return }
            self?.finishReroute(id: id, result: result)
        }
    }

    private func finishReroute(id: String, result: Result<NavigationRoute, Error>) {
        guard var navigation = active, navigation.id == id else { return }
        navigation.rerouting = false
        switch result {
        case .success(let route):
            let lastFix = navigation.tracker.lastFix
            navigation.tracker = RouteTracker(route: route, destination: navigation.place.coordinate, thresholds: thresholds)
            if let lastFix {
                navigation.tracker.update(lastFix)
                navigation.record(navigation.trailPoint(lastFix, time: now(), event: .rerouted))
            }
            navigation.routeVersion += 1
            navigation.rerouteError = nil
        case .failure(let error):
            navigation.rerouteError = error.localizedDescription
        }
        active = navigation
    }

    /// Waits for an in-flight reroute (tests).
    func settleReroute() async {
        await rerouteTask?.value
    }
}
