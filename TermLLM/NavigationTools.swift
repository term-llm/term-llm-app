import Foundation

/// The agent's navigation tools. Planning is separate from starting so the
/// agent can confirm the destination before the iPhone begins tracking.
@MainActor
final class NavigationTools {
    private unowned let service: NavigationService

    init(service: NavigationService) {
        self.service = service
    }

    var tools: [DeviceTool] {
        [
            tool("location_current",
                 "The iPhone's current location: latitude, longitude, accuracy, and (unless include_address is false) the street address "
                 + "or place there. Use it for \"where am I\", finding things nearby, or anything else that depends on where the user is.",
                 schema(["include_address": .boolean("Look up the address at the location. Default true.")]),
                 readOnly: true) { try await $0.currentLocation($1) },
            tool("navigation_preview",
                 "Find a destination near the user and plan a route to it from the iPhone's current location. Does not start navigation. "
                 + "Tell the user the place and the distance or time; if other_matches suggests a different place was meant, confirm first. "
                 + "Then call navigation_start with the preview_id.",
                 schema(["destination": .string("Place name, business, or address, e.g. \"Blue Bottle Coffee Market St\"."),
                         "mode": .enumeration(TravelMode.allCases.map(\.rawValue), "How the user travels. Default walking.")],
                        required: ["destination"]),
                 readOnly: true) { try await $0.preview($1) },
            tool("navigation_start",
                 "Start turn-by-turn tracking on the iPhone for a route from navigation_preview, replacing any active navigation. "
                 + "The iPhone follows the user's location and reroutes automatically if they go off route.",
                 schema(["preview_id": .string("Id from navigation_preview. Default: the latest preview.")])) { try await $0.start($1) },
            tool("navigation_status",
                 "How the user is doing on the active route: distance and time left, the next instruction, whether they are off route "
                 + "or have arrived, and the recent story — a trail covering the last 30 minutes (at most 40 points) of where they were about once a minute (local time, coordinates, "
                 + "state, distance off route) plus every time they went off route, came back, were rerouted, or arrived. "
                 + "Compare the trail with the coordinates of the upcoming maneuvers to explain what went wrong and how to correct it.",
                 schema([:]), readOnly: true) { tools, _ in tools.status() },
            tool("navigation_stop", "Stop navigation on the iPhone and stop using location.",
                 schema([:])) { tools, _ in tools.stop() },
        ]
    }

    // MARK: - Tools

    private func currentLocation(_ args: Arguments) async throws -> JSONValue {
        let (fix, place) = try await service.currentLocation(includeAddress: try args.bool("include_address") ?? true)
        let latitude = (fix.coordinate.latitude * 1e6).rounded() / 1e6
        let longitude = (fix.coordinate.longitude * 1e6).rounded() / 1e6
        var result: [String: JSONValue] = [
            "latitude": .double(latitude),
            "longitude": .double(longitude),
            "accuracy_m": .int(Int(fix.horizontalAccuracy.rounded())),
            "age_s": .int(max(0, Int(service.currentDate.timeIntervalSince(fix.timestamp).rounded()))),
            "maps_url": .string("https://maps.apple.com/?ll=\(latitude),\(longitude)"),
        ]
        if fix.speed >= 0 { result["speed_mps"] = .double((fix.speed * 10).rounded() / 10) }
        if let place {
            if let address = place.address, !address.isEmpty { result["address"] = .string(address) }
            if place.name != place.address { result["place"] = .string(place.name) }
        }
        if let navigation = service.active { result["navigating_to"] = .string(navigation.place.name) }
        return .object(result)
    }

    private func preview(_ args: Arguments) async throws -> JSONValue {
        let destination = try args.string("destination", "the place to go")
        let preview = try await service.preview(destination: destination, mode: try mode(args))
        var result: [String: JSONValue] = [
            "preview_id": .string(preview.id),
            "destination": Self.place(preview.place),
            "mode": .string(preview.mode.rawValue),
            "distance_m": .int(Self.roundedDistance(preview.route.distance)),
            "eta_minutes": .int(Self.minutes(preview.route.expectedTravelTime)),
            "steps": .array(Self.instructions(preview.route).prefix(Self.previewSteps).map(JSONValue.string)),
        ]
        if let name = preview.route.name { result["via"] = .string(name) }
        if !preview.otherMatches.isEmpty { result["other_matches"] = .array(preview.otherMatches.map(Self.place)) }
        return .object(result)
    }

    private func start(_ args: Arguments) async throws -> JSONValue {
        let navigation = try await service.start(previewID: try args.optionalString("preview_id"))
        return Self.merging(Self.status(navigation, now: service.currentDate, timeZone: service.timeZone), ["started": .bool(true)])
    }

    private func status() -> JSONValue {
        guard let navigation = service.active else { return ["active": false] }
        return Self.status(navigation, now: service.currentDate, timeZone: service.timeZone)
    }

    private func stop() -> JSONValue {
        guard let stopped = service.stop() else { return ["active": false, "stopped": false] }
        return ["active": false, "stopped": true, "destination": Self.place(stopped.place)]
    }

    private func mode(_ args: Arguments) throws -> TravelMode {
        guard let raw = try args.optionalString("mode") else { return .walking }
        switch raw.lowercased() {
        case "walking", "walk", "on foot": return .walking
        case "driving", "drive", "car": return .driving
        default:
            throw DeviceToolError(message: "Unknown mode \"\(raw)\". Use one of \(TravelMode.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
    }

    // MARK: - JSON

    static let previewSteps = 8

    /// Upcoming maneuvers listed with their coordinates, so the agent can
    /// compare them with the trail.
    static let upcomingSteps = 6

    static func status(_ navigation: ActiveNavigation, now: Date, timeZone: TimeZone) -> JSONValue {
        let tracker = navigation.tracker
        let clock = clockFormatter(timeZone)
        var state = tracker.state.rawValue
        if navigation.rerouting { state = "rerouting" }
        var result: [String: JSONValue] = [
            "active": true,
            "nav_id": .string(navigation.id),
            "destination": place(navigation.place),
            "mode": .string(navigation.mode.rawValue),
            "state": .string(state),
            "route_version": .int(navigation.routeVersion),
            "now": .string(clock.string(from: now)),
            "started_at": .string(clock.string(from: navigation.startedAt)),
        ]
        if let fix = tracker.lastFix {
            result["position"] = position(fix, clock: clock, now: now)
            if fix.horizontalAccuracy >= 0 { result["gps_accuracy_m"] = .int(Int(fix.horizontalAccuracy.rounded())) }
        }
        if tracker.poorAccuracy { result["gps"] = "poor" }
        if let error = navigation.rerouteError { result["reroute_error"] = .string(error) }
        let trail = navigation.recentTrail(now: now)
        if !trail.points.isEmpty { result["trail"] = .array(trail.points.map { trailPoint($0, clock: clock) }) }
        if trail.truncated { result["trail_note"] = .string("Only the last \(Int(NavigationService.trailWindow / 60)) minutes are kept; earlier points were dropped.") }
        guard tracker.state != .arrived else { return .object(result) }

        if let progress = tracker.progress {
            result["remaining_m"] = .int(roundedDistance(progress.remaining))
            if let seconds = tracker.remainingTime { result["eta_minutes"] = .int(minutes(seconds)) }
            if tracker.state == .offRoute { result["off_route_m"] = .int(roundedDistance(progress.offRouteDistance)) }
            if let index = progress.nextStepIndex, let distance = progress.distanceToNext {
                result["next"] = step(navigation.route.steps[index], in: distance)
            }
        } else {
            // No usable fix yet: describe the route from the start.
            result["remaining_m"] = .int(roundedDistance(navigation.route.distance))
            result["eta_minutes"] = .int(minutes(navigation.route.expectedTravelTime))
            if let first = instructions(navigation.route).first { result["next"] = ["instruction": .string(first)] }
        }
        let upcoming = upcoming(navigation)
        if !upcoming.isEmpty { result["upcoming"] = .array(upcoming) }
        return .object(result)
    }

    /// Remaining maneuvers from the next one on, with where each happens.
    private static func upcoming(_ navigation: ActiveNavigation) -> [JSONValue] {
        let steps = navigation.route.steps
        let first = navigation.tracker.progress?.nextStepIndex ?? 0
        guard first < steps.count else { return [] }
        return steps.indices[first...]
            .filter { !steps[$0].instruction.trimmingCharacters(in: .whitespaces).isEmpty }
            .prefix(upcomingSteps)
            .map { index in
                var object: [String: JSONValue] = ["instruction": .string(steps[index].instruction)]
                if let at = steps[index].points.first {
                    object["lat"] = coordinateValue(at.latitude)
                    object["lon"] = coordinateValue(at.longitude)
                }
                if let distance = navigation.tracker.distance(toStep: index) {
                    object["in_m"] = .int(roundedDistance(distance))
                }
                return .object(object)
            }
    }

    private static func trailPoint(_ point: TrailPoint, clock: DateFormatter) -> JSONValue {
        var object: [String: JSONValue] = [
            "time": .string(clock.string(from: point.time)),
            "lat": coordinateValue(point.coordinate.latitude),
            "lon": coordinateValue(point.coordinate.longitude),
            "accuracy_m": .int(Int(point.accuracy.rounded())),
            "state": .string(point.state),
        ]
        if let offRoute = point.offRoute, offRoute >= 10 { object["off_route_m"] = .int(roundedDistance(offRoute)) }
        if let remaining = point.remaining { object["remaining_m"] = .int(roundedDistance(remaining)) }
        if point.speed >= 0 { object["speed_mps"] = .double((point.speed * 10).rounded() / 10) }
        if let event = point.event { object["event"] = .string(event.rawValue) }
        return .object(object)
    }

    private static func position(_ fix: LocationFix, clock: DateFormatter, now: Date) -> JSONValue {
        [
            "time": .string(clock.string(from: fix.timestamp)),
            "age_s": .int(max(0, Int(now.timeIntervalSince(fix.timestamp).rounded()))),
            "lat": coordinateValue(fix.coordinate.latitude),
            "lon": coordinateValue(fix.coordinate.longitude),
        ]
    }

    /// Five decimal places: about a metre.
    private static func coordinateValue(_ degrees: Double) -> JSONValue {
        .double((degrees * 1e5).rounded() / 1e5)
    }

    /// Local wall-clock time, which is how people talk about a walk.
    static func clockFormatter(_ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }

    private static func step(_ step: NavigationStep, in distance: Double) -> JSONValue {
        var object: [String: JSONValue] = [
            "instruction": .string(step.instruction),
            "in_m": .int(roundedDistance(distance)),
        ]
        if let notice = step.notice, !notice.isEmpty { object["notice"] = .string(notice) }
        return .object(object)
    }

    static func place(_ place: NavigationPlace) -> JSONValue {
        var object: [String: JSONValue] = [
            "name": .string(place.name),
            "latitude": .double((place.coordinate.latitude * 1e5).rounded() / 1e5),
            "longitude": .double((place.coordinate.longitude * 1e5).rounded() / 1e5),
        ]
        if let address = place.address, !address.isEmpty { object["address"] = .string(address) }
        return .object(object)
    }

    static func instructions(_ route: NavigationRoute) -> [String] {
        route.steps.map(\.instruction).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Distances as a person would say them: 5 m under 100 m, 10 m under 1 km, then 50 m.
    static func roundedDistance(_ metres: Double) -> Int {
        let step: Double = metres < 100 ? 5 : metres < 1000 ? 10 : 50
        return Int((max(0, metres) / step).rounded() * step)
    }

    static func minutes(_ seconds: TimeInterval) -> Int {
        max(seconds > 0 ? 1 : 0, Int((seconds / 60).rounded()))
    }

    private static func merging(_ value: JSONValue, _ extra: [String: JSONValue]) -> JSONValue {
        .object((value.objectValue ?? [:]).merging(extra) { _, new in new })
    }

    // MARK: - Plumbing

    private func tool(_ name: String, _ description: String, _ schema: JSONValue, readOnly: Bool = false,
                      _ run: @escaping @MainActor (NavigationTools, Arguments) async throws -> JSONValue) -> DeviceTool {
        DeviceTool(name: name, description: description, inputSchema: schema, readOnly: readOnly) { [weak self] arguments in
            guard let self else { throw DeviceToolError(message: "Navigation is unavailable.") }
            let result = try await run(self, Arguments(arguments))
            return DeviceToolResult(text: String(decoding: result.encoded(), as: UTF8.self))
        }
    }

    private enum Parameter {
        case string(String), boolean(String), enumeration([String], String)

        var json: JSONValue {
            switch self {
            case .string(let description): return ["type": "string", "description": .string(description)]
            case .boolean(let description): return ["type": "boolean", "description": .string(description)]
            case .enumeration(let values, let description):
                return ["type": "string", "enum": .array(values.map(JSONValue.string)), "description": .string(description)]
            }
        }
    }

    private func schema(_ properties: [String: Parameter], required: [String] = []) -> JSONValue {
        [
            "type": "object",
            "properties": .object(properties.mapValues(\.json)),
            "required": .array(required.map(JSONValue.string)),
            "additionalProperties": false,
        ]
    }
}
