import XCTest
@testable import TermLLM

@MainActor
private final class FakeLocation: LocationProvider {
    var fix = TestRoutes.fix(TestRoutes.origin)
    var error: Error?
    private(set) var handler: (@MainActor (LocationFix) -> Void)?
    private(set) var startedModes: [TravelMode] = []
    private(set) var stops = 0

    func currentFix() async throws -> LocationFix {
        if let error { throw error }
        return fix
    }

    func startUpdates(mode: TravelMode, _ handler: @escaping @MainActor (LocationFix) -> Void) async throws {
        if let error { throw error }
        startedModes.append(mode)
        self.handler = handler
    }

    func stopUpdates() {
        stops += 1
        handler = nil
    }

    /// Timestamp given to fixes from `send`.
    var now = Date(timeIntervalSince1970: 1_000_000)

    func send(_ coordinate: Coordinate, accuracy: Double = 5, at time: Date? = nil) {
        handler?(LocationFix(coordinate: coordinate, horizontalAccuracy: accuracy, timestamp: time ?? now))
    }
}

@MainActor
private final class FakePlanner: RoutePlanner {
    var places: [NavigationPlace] = [
        NavigationPlace(name: "Blue Bottle Coffee", address: "66 Mint St", coordinate: TestRoutes.end),
        NavigationPlace(name: "Blue Bottle Coffee (Ferry Building)", address: "1 Ferry Building", coordinate: TestRoutes.origin),
    ]
    var route = TestRoutes.lShape
    var reroute: NavigationRoute?
    private(set) var searches: [(String, Coordinate)] = []
    private(set) var routes: [(Coordinate, String, TravelMode)] = []
    var described: NavigationPlace? = NavigationPlace(name: "Ferry Building", address: "1 Ferry Building, San Francisco",
                                                      coordinate: TestRoutes.origin)
    var describeError: Error?
    private(set) var describeCalls = 0

    func describe(_ coordinate: Coordinate) async throws -> NavigationPlace? {
        describeCalls += 1
        if let describeError { throw describeError }
        return described
    }

    func search(_ query: String, near: Coordinate) async throws -> [NavigationPlace] {
        searches.append((query, near))
        return places
    }

    func route(from: Coordinate, to place: NavigationPlace, mode: TravelMode) async throws -> NavigationRoute {
        routes.append((from, place.name, mode))
        return routes.count > 1 ? (reroute ?? route) : route
    }
}

@MainActor
final class NavigationToolsTests: XCTestCase {
    private var location: FakeLocation!
    private var planner: FakePlanner!
    private var service: NavigationService!
    private var clock = Date(timeIntervalSince1970: 1_000_000)
    private var ids = 0

    override func setUp() async throws {
        location = FakeLocation()
        planner = FakePlanner()
        service = NavigationService(location: location, planner: planner,
                                    now: { [unowned self] in clock },
                                    makeID: { [unowned self] in ids += 1; return "id\(ids)" },
                                    timeZone: TimeZone(identifier: "UTC")!)
    }

    override func tearDown() async throws {
        service.stop()
    }

    @discardableResult
    private func call(_ name: String, _ arguments: [String: JSONValue] = [:]) async throws -> JSONValue {
        let tool = try XCTUnwrap(service.tools.first { $0.name == name }, "no tool \(name)")
        let result = try await tool.call(arguments)
        XCTAssertFalse(result.isError)
        return try JSONValue.decode(Data(result.text.utf8))
    }

    private func callFailing(_ name: String, _ arguments: [String: JSONValue] = [:]) async -> String {
        do {
            try await call(name, arguments)
            XCTFail("\(name) should fail")
            return ""
        } catch {
            return error.localizedDescription
        }
    }

    func testToolCatalogue() {
        let tools = service.tools
        XCTAssertEqual(tools.map(\.name), ["location_current", "navigation_preview", "navigation_start", "navigation_status", "navigation_stop"])
        XCTAssertEqual(tools.filter(\.readOnly).map(\.name), ["location_current", "navigation_preview", "navigation_status"])
        XCTAssertTrue(tools.allSatisfy { $0.inputSchema["type"] == "object" })
        XCTAssertEqual(tools.first { $0.name == "navigation_preview" }?.inputSchema["required"], ["destination"])
        _ = DeviceToolRegistry(tools: BuiltInDeviceTools.standard + tools)
    }

    func testCurrentLocationWithAddress() async throws {
        location.fix = LocationFix(coordinate: Coordinate(latitude: 37.7955123, longitude: -122.3937456), horizontalAccuracy: 8.4,
                                   timestamp: clock.addingTimeInterval(-3), speed: 1.34)
        let here = try await call("location_current")
        XCTAssertEqual(here["latitude"], .double(37.795512))
        XCTAssertEqual(here["longitude"], .double(-122.393746))
        XCTAssertEqual(here["accuracy_m"], 8)
        XCTAssertEqual(here["age_s"], 3)
        XCTAssertEqual(here["speed_mps"], .double(1.3))
        XCTAssertEqual(here["address"], "1 Ferry Building, San Francisco")
        XCTAssertEqual(here["place"], "Ferry Building")
        XCTAssertEqual(here["maps_url"], "https://maps.apple.com/?ll=37.795512,-122.393746")
        XCTAssertNil(here["navigating_to"])
        XCTAssertTrue(location.startedModes.isEmpty, "a one-off reading must not start tracking")
    }

    func testCurrentLocationWithoutAddressOrWhenLookupFails() async throws {
        let plain = try await call("location_current", ["include_address": false])
        XCTAssertNil(plain["address"])
        XCTAssertNil(plain["speed_mps"], "unknown speed is omitted")
        XCTAssertEqual(planner.describeCalls, 0)

        planner.describeError = NavigationError.locationUnavailable("offline")
        let fallback = try await call("location_current")
        XCTAssertNotNil(fallback["latitude"])
        XCTAssertNil(fallback["address"])

        location.error = NavigationError.locationDenied
        let denied = await callFailing("location_current")
        XCTAssertTrue(denied.contains("Location access is off"), denied)
    }

    func testCurrentLocationMentionsActiveNavigation() async throws {
        try await call("navigation_preview", ["destination": "blue bottle"])
        try await call("navigation_start")
        let here = try await call("location_current", ["include_address": false])
        XCTAssertEqual(here["navigating_to"], "Blue Bottle Coffee")
    }

    func testPreviewPlansFromCurrentLocationWithoutTracking() async throws {
        let preview = try await call("navigation_preview", ["destination": "blue bottle"])
        XCTAssertEqual(preview["preview_id"], "p-id1")
        XCTAssertEqual(preview["destination"]?["name"], "Blue Bottle Coffee")
        XCTAssertEqual(preview["destination"]?["address"], "66 Mint St")
        XCTAssertEqual(preview["mode"], "walking")
        XCTAssertEqual(preview["distance_m"], 350)
        XCTAssertEqual(preview["eta_minutes"], 5)
        XCTAssertEqual(preview["via"], "Oak St")
        XCTAssertEqual(preview["steps"], ["Head north on Main St", "Turn right onto Oak St", "Arrive at the destination"])
        guard case .array(let others)? = preview["other_matches"] else { return XCTFail("no other_matches") }
        XCTAssertEqual(others.first?["name"], "Blue Bottle Coffee (Ferry Building)")

        XCTAssertEqual(planner.searches.map(\.0), ["blue bottle"])
        XCTAssertEqual(planner.searches.first?.1, TestRoutes.origin)
        XCTAssertTrue(location.startedModes.isEmpty, "preview must not start tracking")
        let idle = try await call("navigation_status")
        XCTAssertEqual(idle, ["active": false])
    }

    func testDrivingModeAndValidation() async throws {
        let preview = try await call("navigation_preview", ["destination": "x", "mode": "car"])
        XCTAssertEqual(preview["mode"], "driving")
        XCTAssertEqual(planner.routes.last?.2, .driving)
        let message = await callFailing("navigation_preview", ["destination": "x", "mode": "teleport"])
        XCTAssertTrue(message.contains("walking, driving"), message)
        let missing = await callFailing("navigation_preview")
        XCTAssertTrue(missing.contains("destination is required"), missing)
    }

    func testNoPlacesAndDeniedLocationAreExplained() async {
        planner.places = []
        let none = await callFailing("navigation_preview", ["destination": "nowhere"])
        XCTAssertTrue(none.contains("No places matched \"nowhere\""), none)

        location.error = NavigationError.locationDenied
        let denied = await callFailing("navigation_preview", ["destination": "x"])
        XCTAssertTrue(denied.contains("Location access is off"), denied)
    }

    func testStartRequiresAPreview() async {
        let message = await callFailing("navigation_start")
        XCTAssertTrue(message.contains("navigation_preview first"), message)
        let unknown = await callFailing("navigation_start", ["preview_id": "p-nope"])
        XCTAssertTrue(unknown.contains("p-nope"), unknown)
    }

    func testFullWalk() async throws {
        try await call("navigation_preview", ["destination": "blue bottle"])
        let started = try await call("navigation_start", ["preview_id": "p-id1"])
        XCTAssertEqual(started["started"], true)
        XCTAssertEqual(started["active"], true)
        XCTAssertEqual(started["nav_id"], "n-id2")
        XCTAssertEqual(started["state"], "waiting_for_location")
        XCTAssertEqual(started["next"], ["instruction": "Head north on Main St"])
        XCTAssertEqual(location.startedModes, [.walking])

        location.send(Geo.moved(TestRoutes.origin, east: 3, north: 120))
        var status = try await call("navigation_status")
        XCTAssertEqual(status["state"], "on_route")
        XCTAssertEqual(status["remaining_m"], 230)
        XCTAssertEqual(status["next"], ["instruction": "Turn right onto Oak St", "in_m": 80])
        XCTAssertEqual(status["upcoming"], [
            ["instruction": "Turn right onto Oak St", "lat": Self.degrees(TestRoutes.corner.latitude),
             "lon": Self.degrees(TestRoutes.corner.longitude), "in_m": 80],
            ["instruction": "Arrive at the destination", "lat": Self.degrees(TestRoutes.end.latitude),
             "lon": Self.degrees(TestRoutes.end.longitude), "in_m": 230],
        ])
        XCTAssertEqual(status["gps_accuracy_m"], 5)

        location.send(Geo.moved(TestRoutes.corner, east: 140))
        status = try await call("navigation_status")
        XCTAssertEqual(status["state"], "arrived")
        XCTAssertNil(status["next"])
        XCTAssertEqual(location.handler == nil, true, "GPS stops on arrival")

        let stopped = try await call("navigation_stop")
        XCTAssertEqual(stopped["stopped"], true)
        XCTAssertEqual(stopped["destination"]?["name"], "Blue Bottle Coffee")
        let after = try await call("navigation_status")
        XCTAssertEqual(after, ["active": false])
        let again = try await call("navigation_stop")
        XCTAssertEqual(again, ["active": false, "stopped": false])
    }

    func testOffRouteReroutesAndBumpsTheRouteVersion() async throws {
        try await call("navigation_preview", ["destination": "blue bottle"])
        try await call("navigation_start")
        location.send(Geo.moved(TestRoutes.origin, north: 50))

        // The new route from where the user is: back south, then east.
        let here = Geo.moved(TestRoutes.origin, north: 280)
        planner.reroute = NavigationRoute(name: "Back", distance: 230, expectedTravelTime: 200, steps: [
            NavigationStep(instruction: "Head south on Main St", distance: 80, points: [here, TestRoutes.corner]),
            NavigationStep(instruction: "Turn left onto Oak St", distance: 150, points: [TestRoutes.corner, TestRoutes.end]),
        ])
        for north in [240.0, 260, 280] { location.send(Geo.moved(TestRoutes.origin, north: north)) }
        // Checked synchronously: the reroute task may finish during any await.
        XCTAssertEqual(service.active?.rerouting, true)
        XCTAssertEqual(NavigationTools.status(try XCTUnwrap(service.active), now: clock, timeZone: .current)["state"], "rerouting")

        await service.settleReroute()
        let status = try await call("navigation_status")
        XCTAssertEqual(status["route_version"], 2)
        XCTAssertEqual(status["state"], "on_route", "replayed the last fix onto the new route")
        XCTAssertEqual(status["next"], ["instruction": "Turn left onto Oak St", "in_m": 80])
        XCTAssertEqual(planner.routes.last?.0, here)
    }

    private static func degrees(_ value: Double) -> JSONValue { .double((value * 1e5).rounded() / 1e5) }

    func testStatusTellsTheStoryOfTheWalk() async throws {
        try await call("navigation_preview", ["destination": "blue bottle"])
        try await call("navigation_start")
        let base = location.now
        func walk(_ seconds: TimeInterval, north: Double) {
            location.send(Geo.moved(TestRoutes.origin, north: north), at: base.addingTimeInterval(seconds))
        }
        // A minute and a half up Main St, sampled about once a minute.
        for (seconds, north) in [(0.0, 0.0), (20, 20), (40, 40), (60, 60), (90, 90), (120, 120)] { walk(seconds, north: north) }
        // Then straight past the right turn at 200 m.
        let here = Geo.moved(TestRoutes.origin, north: 280)
        planner.reroute = NavigationRoute(name: "Back", distance: 230, expectedTravelTime: 200, steps: [
            NavigationStep(instruction: "Head south on Main St", distance: 80, points: [here, TestRoutes.corner]),
            NavigationStep(instruction: "Turn left onto Oak St", distance: 150, points: [TestRoutes.corner, TestRoutes.end]),
        ])
        clock = base.addingTimeInterval(175)
        for (seconds, north) in [(150.0, 240.0), (160, 260), (170, 280)] { walk(seconds, north: north) }
        await service.settleReroute()

        let status = try await call("navigation_status")
        XCTAssertEqual(status["now"], "13:49:35")
        XCTAssertEqual(status["started_at"], "13:46:40")
        XCTAssertEqual(status["position"], ["time": "13:49:30", "age_s": 5,
                                            "lat": Self.degrees(here.latitude), "lon": Self.degrees(here.longitude)])
        guard case .array(let trail)? = status["trail"] else { return XCTFail("no trail") }
        XCTAssertEqual(trail.map { $0["time"] }, ["13:46:40", "13:47:40", "13:48:40", "13:49:30", "13:49:35"])
        XCTAssertEqual(trail.map { $0["event"] }, ["started", nil, nil, "went_off_route", "rerouted"])
        XCTAssertEqual(trail.map { $0["state"] }, ["on_route", "on_route", "on_route", "off_route", "on_route"])
        XCTAssertEqual(trail[1], ["time": "13:47:40", "lat": Self.degrees(Geo.moved(TestRoutes.origin, north: 60).latitude),
                                  "lon": Self.degrees(TestRoutes.origin.longitude), "accuracy_m": 5,
                                  "state": "on_route", "remaining_m": 290])
        XCTAssertEqual(trail[3]["off_route_m"], 80)
        XCTAssertEqual(trail[3]["remaining_m"], 150)
        XCTAssertEqual(trail[4]["remaining_m"], 230, "measured on the new route")
        XCTAssertEqual(status["upcoming"], [
            ["instruction": "Turn left onto Oak St", "lat": Self.degrees(TestRoutes.corner.latitude),
             "lon": Self.degrees(TestRoutes.corner.longitude), "in_m": 80],
        ])
    }

    func testTrailKeepsOnlyTheLastHalfHour() async throws {
        try await call("navigation_preview", ["destination": "blue bottle"])
        try await call("navigation_start")
        let base = location.now
        for minute in 0..<120 { location.send(TestRoutes.origin, at: base.addingTimeInterval(Double(minute) * 60)) }
        let trail = try XCTUnwrap(service.active?.trail)
        XCTAssertEqual(trail.count, 31, "minutes 89…119")
        XCTAssertEqual(trail.first?.time, base.addingTimeInterval(89 * 60))
        XCTAssertNil(trail.first?.event, "the start rolled off")

        clock = base.addingTimeInterval(119 * 60)
        let status = try await call("navigation_status")
        guard case .array(let shown)? = status["trail"] else { return XCTFail("no trail") }
        XCTAssertEqual(shown.count, 31)
        XCTAssertNotNil(status["trail_note"])
    }

    func testTrailIsCappedEvenWithinTheWindow() async throws {
        try await call("navigation_preview", ["destination": "blue bottle"])
        try await call("navigation_start")
        // Bouncing on and off route every few seconds records an event each time.
        for index in 0..<200 {
            let east = index % 6 < 3 ? 0.0 : 80.0
            location.send(Geo.moved(TestRoutes.origin, east: east, north: 100), at: location.now.addingTimeInterval(Double(index) * 5))
        }
        XCTAssertLessThanOrEqual(try XCTUnwrap(service.active?.trail.count), NavigationService.maxTrailPoints)
    }

    func testOldTrailIsHiddenWhenNoNewFixesArrive() async throws {
        try await call("navigation_preview", ["destination": "blue bottle"])
        try await call("navigation_start")
        location.send(TestRoutes.origin)
        clock = location.now.addingTimeInterval(NavigationService.trailWindow + 60)
        let status = try await call("navigation_status")
        XCTAssertNil(status["trail"])
        XCTAssertNotNil(status["trail_note"])
        XCTAssertNotNil(status["position"], "the last known position is still reported, with its age")
    }

    func testStalePreviewIsReplannedFromHere() async throws {
        try await call("navigation_preview", ["destination": "blue bottle"])
        clock.addTimeInterval(NavigationService.previewFreshness + 1)
        location.fix = TestRoutes.fix(Geo.moved(TestRoutes.origin, north: 10))
        try await call("navigation_start")
        XCTAssertEqual(planner.routes.count, 2)
        XCTAssertEqual(planner.routes.last?.0, location.fix.coordinate)
    }

    func testStartingAgainReplacesTheActiveNavigation() async throws {
        try await call("navigation_preview", ["destination": "blue bottle"])
        try await call("navigation_start")
        try await call("navigation_preview", ["destination": "other", "mode": "driving"])
        let second = try await call("navigation_start")
        XCTAssertEqual(second["mode"], "driving")
        XCTAssertEqual(location.stops, 1)
        XCTAssertEqual(location.startedModes, [.walking, .driving])
    }

    func testFailedTrackingLeavesNothingActive() async throws {
        try await call("navigation_preview", ["destination": "blue bottle"])
        location.error = NavigationError.locationDenied
        _ = await callFailing("navigation_start")
        XCTAssertNil(service.active)
    }

    func testRoundedDistances() {
        XCTAssertEqual(NavigationTools.roundedDistance(42), 40)
        XCTAssertEqual(NavigationTools.roundedDistance(43), 45)
        XCTAssertEqual(NavigationTools.roundedDistance(347), 350)
        XCTAssertEqual(NavigationTools.roundedDistance(1_234), 1_250)
        XCTAssertEqual(NavigationTools.minutes(20), 1)
        XCTAssertEqual(NavigationTools.minutes(0), 0)
    }
}
