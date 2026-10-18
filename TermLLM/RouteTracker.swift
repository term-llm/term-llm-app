import Foundation

/// Where a fix sits on a route, from plain geometry.
struct RouteProgress: Equatable, Sendable {
    /// Metres travelled along the route to the matched point.
    var along: Double
    /// Metres left to the end of the route.
    var remaining: Double
    /// Metres between the fix and the route line.
    var offRouteDistance: Double
    /// Index of the step being travelled.
    var stepIndex: Int
    /// Index of the next step with an instruction, if any.
    var nextStepIndex: Int?
    /// Metres until the next instruction applies.
    var distanceToNext: Double?
}

/// Matches location fixes to one route and decides, conservatively, whether
/// the user has left it or arrived. Pure value type so it can be tested with
/// recorded tracks.
struct RouteTracker: Equatable, Sendable {
    enum State: String, Equatable, Sendable {
        case waitingForLocation = "waiting_for_location"
        case onRoute = "on_route"
        case offRoute = "off_route"
        case arrived
    }

    struct Thresholds: Equatable, Sendable {
        /// Fixes less accurate than this are ignored for decisions.
        var maxUsableAccuracy: Double = 65
        /// Minimum off-route distance before a fix counts as off route.
        var offRouteMinimum: Double = 30
        /// Consecutive off-route fixes needed to declare the user off route.
        var offRouteFixes = 3
        /// Back on route once within this fraction of the off-route threshold.
        var rejoinFraction: Double = 0.6
        /// Arrived within this many metres of the destination (or route end).
        var arrivalRadius: Double = 25
    }

    let route: NavigationRoute
    let destination: Coordinate
    var thresholds = Thresholds()

    private(set) var state: State = .waitingForLocation
    private(set) var progress: RouteProgress?
    private(set) var lastFix: LocationFix?
    private var offRouteCount = 0
    private let geometry: RouteGeometry

    init(route: NavigationRoute, destination: Coordinate, thresholds: Thresholds = Thresholds()) {
        self.route = route
        self.destination = destination
        self.thresholds = thresholds
        self.geometry = RouteGeometry(route: route)
    }

    /// Whether the last usable fix was too inaccurate to act on.
    private(set) var poorAccuracy = false

    mutating func update(_ fix: LocationFix) {
        guard state != .arrived else { return }
        lastFix = fix
        guard fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= thresholds.maxUsableAccuracy else {
            poorAccuracy = true
            return
        }
        poorAccuracy = false
        guard let matched = geometry.match(fix.coordinate, after: progress?.along) else { return }
        progress = matched

        let toDestination = Geo.distance(fix.coordinate, destination)
        if toDestination <= thresholds.arrivalRadius
            || (matched.remaining <= thresholds.arrivalRadius && matched.offRouteDistance <= thresholds.offRouteMinimum) {
            state = .arrived
            return
        }

        let limit = max(thresholds.offRouteMinimum, fix.horizontalAccuracy * 1.5)
        if matched.offRouteDistance > limit {
            offRouteCount += 1
            if offRouteCount >= thresholds.offRouteFixes { state = .offRoute }
            else if state == .waitingForLocation { state = .onRoute }
        } else {
            if state == .offRoute, matched.offRouteDistance > limit * thresholds.rejoinFraction { return }
            offRouteCount = 0
            state = .onRoute
        }
    }

    /// Metres from the user's matched position to the start of step `index`
    /// (negative once passed), or from the route start before any fix.
    func distance(toStep index: Int) -> Double? {
        guard geometry.stepStarts.indices.contains(index) else { return nil }
        return geometry.stepStarts[index] - (progress?.along ?? 0)
    }

    /// Estimated seconds left, scaled from the route's own estimate.
    var remainingTime: TimeInterval? {
        guard let progress, geometry.length > 0 else { return nil }
        return route.expectedTravelTime * progress.remaining / geometry.length
    }
}

/// Flattened route polyline with cumulative distances, for matching.
struct RouteGeometry: Equatable, Sendable {
    struct Segment: Equatable, Sendable {
        var start: Coordinate
        var end: Coordinate
        var step: Int
        var startDistance: Double
        var length: Double
    }

    private(set) var segments: [Segment] = []
    /// Cumulative distance at which each step starts.
    private(set) var stepStarts: [Double] = []
    private(set) var length: Double = 0
    private let instructionSteps: [Bool]

    init(route: NavigationRoute) {
        instructionSteps = route.steps.map { !$0.instruction.trimmingCharacters(in: .whitespaces).isEmpty }
        var total = 0.0
        var previous: Coordinate?
        for (index, step) in route.steps.enumerated() {
            stepStarts.append(total)
            // Steps share their boundary point; continue from the previous end
            // so gaps between steps are still covered.
            var points = step.points
            if let previous, let first = points.first, first != previous { points.insert(previous, at: 0) }
            guard points.count > 1 else { continue }
            for (a, b) in zip(points, points.dropFirst()) {
                let length = Geo.distance(a, b)
                guard length > 0 else { continue }
                segments.append(Segment(start: a, end: b, step: index, startDistance: total, length: length))
                total += length
            }
            previous = points.last
        }
        length = total
    }

    /// The closest point on the route. `after` is the previous match: a point
    /// far behind it must be clearly closer to win, which keeps routes that
    /// double back from jumping to the wrong pass.
    func match(_ coordinate: Coordinate, after previous: Double? = nil) -> RouteProgress? {
        var best: (score: Double, distance: Double, along: Double, step: Int)?
        for segment in segments {
            let (fraction, distance) = Geo.project(coordinate, onto: segment.start, segment.end)
            let along = segment.startDistance + fraction * segment.length
            var score = distance
            if let previous, along < previous - 50 { score += (previous - along) * 0.5 }
            if best == nil || score < best!.score {
                best = (score, distance, along, segment.step)
            }
        }
        guard let best else { return nil }
        let next = instructionSteps.indices.first { $0 > best.step && instructionSteps[$0] }
        return RouteProgress(
            along: best.along,
            remaining: max(0, length - best.along),
            offRouteDistance: best.distance,
            stepIndex: best.step,
            nextStepIndex: next,
            distanceToNext: next.map { max(0, stepStarts[$0] - best.along) }
        )
    }
}

/// Small-area geometry on a local flat projection; accurate to well under a
/// metre over the distances between route points.
enum Geo {
    static let metresPerDegreeLatitude = 111_320.0

    static func distance(_ a: Coordinate, _ b: Coordinate) -> Double {
        let (x, y) = offset(from: a, to: b)
        return (x * x + y * y).squareRoot()
    }

    /// Projection of `point` onto segment a→b: fraction along it (0…1) and
    /// the distance from the point to that projection, in metres.
    static func project(_ point: Coordinate, onto a: Coordinate, _ b: Coordinate) -> (Double, Double) {
        let (bx, by) = offset(from: a, to: b)
        let (px, py) = offset(from: a, to: point)
        let lengthSquared = bx * bx + by * by
        let fraction = lengthSquared > 0 ? min(1, max(0, (px * bx + py * by) / lengthSquared)) : 0
        let dx = px - fraction * bx, dy = py - fraction * by
        return (fraction, (dx * dx + dy * dy).squareRoot())
    }

    /// East/north metres from `origin` to `point`.
    static func offset(from origin: Coordinate, to point: Coordinate) -> (Double, Double) {
        let latitude = (origin.latitude + point.latitude) / 2 * .pi / 180
        let x = (point.longitude - origin.longitude) * metresPerDegreeLatitude * cos(latitude)
        let y = (point.latitude - origin.latitude) * metresPerDegreeLatitude
        return (x, y)
    }

    /// The coordinate `east`/`north` metres from `origin` (for tests and fakes).
    static func moved(_ origin: Coordinate, east: Double = 0, north: Double = 0) -> Coordinate {
        let latitude = origin.latitude + north / metresPerDegreeLatitude
        let longitude = origin.longitude + east / (metresPerDegreeLatitude * cos(origin.latitude * .pi / 180))
        return Coordinate(latitude: latitude, longitude: longitude)
    }
}
