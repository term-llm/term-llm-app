import XCTest
@testable import TermLLM

/// An L-shaped test route: 200 m north, then a right turn and 150 m east.
enum TestRoutes {
    static let origin = Coordinate(latitude: 37.7749, longitude: -122.4194)
    static let corner = Geo.moved(origin, north: 200)
    static let end = Geo.moved(corner, east: 150)

    static var lShape: NavigationRoute {
        NavigationRoute(name: "Oak St", distance: 350, expectedTravelTime: 300, steps: [
            NavigationStep(instruction: "", distance: 0, points: [origin]),
            NavigationStep(instruction: "Head north on Main St", distance: 200,
                           points: stride(from: 0.0, through: 200, by: 50).map { Geo.moved(origin, north: $0) }),
            NavigationStep(instruction: "Turn right onto Oak St", distance: 150,
                           points: stride(from: 0.0, through: 150, by: 50).map { Geo.moved(corner, east: $0) }),
            NavigationStep(instruction: "Arrive at the destination", distance: 0, points: [end]),
        ])
    }

    static func fix(_ coordinate: Coordinate, accuracy: Double = 5, at time: TimeInterval = 0) -> LocationFix {
        LocationFix(coordinate: coordinate, horizontalAccuracy: accuracy, timestamp: Date(timeIntervalSince1970: time))
    }
}

final class RouteTrackerTests: XCTestCase {
    private let route = TestRoutes.lShape

    func testGeometryLength() {
        XCTAssertEqual(RouteGeometry(route: route).length, 350, accuracy: 0.5)
    }

    func testProgressOnFirstLegPointsToTheTurn() throws {
        let match = try XCTUnwrap(RouteGeometry(route: route).match(Geo.moved(TestRoutes.origin, east: 4, north: 120)))
        XCTAssertEqual(match.along, 120, accuracy: 0.5)
        XCTAssertEqual(match.remaining, 230, accuracy: 0.5)
        XCTAssertEqual(match.offRouteDistance, 4, accuracy: 0.2)
        XCTAssertEqual(match.stepIndex, 1)
        XCTAssertEqual(match.nextStepIndex, 2)
        XCTAssertEqual(try XCTUnwrap(match.distanceToNext), 80, accuracy: 0.5)
    }

    func testProgressAfterTheTurn() throws {
        let match = try XCTUnwrap(RouteGeometry(route: route).match(Geo.moved(TestRoutes.corner, east: 60)))
        XCTAssertEqual(match.stepIndex, 2)
        XCTAssertEqual(match.nextStepIndex, 3)
        XCTAssertEqual(try XCTUnwrap(match.distanceToNext), 90, accuracy: 0.5)
    }

    func testOnRouteThenOffRouteOnlyAfterConsecutiveFixes() {
        var tracker = RouteTracker(route: route, destination: TestRoutes.end)
        XCTAssertEqual(tracker.state, .waitingForLocation)
        tracker.update(TestRoutes.fix(Geo.moved(TestRoutes.origin, north: 50)))
        XCTAssertEqual(tracker.state, .onRoute)

        // Missed the turn: kept walking north past the corner.
        let beyond = [240.0, 260, 280].map { Geo.moved(TestRoutes.origin, north: $0) }
        tracker.update(TestRoutes.fix(beyond[0]))
        XCTAssertEqual(tracker.state, .onRoute, "one fix 40 m away is not enough")
        tracker.update(TestRoutes.fix(beyond[1]))
        XCTAssertEqual(tracker.state, .onRoute)
        tracker.update(TestRoutes.fix(beyond[2]))
        XCTAssertEqual(tracker.state, .offRoute)

        // Coming back: still off until clearly near the route again.
        tracker.update(TestRoutes.fix(Geo.moved(TestRoutes.origin, north: 225)))
        XCTAssertEqual(tracker.state, .offRoute)
        tracker.update(TestRoutes.fix(Geo.moved(TestRoutes.origin, north: 205)))
        XCTAssertEqual(tracker.state, .onRoute)
    }

    func testInaccurateFixesAreIgnored() {
        var tracker = RouteTracker(route: route, destination: TestRoutes.end)
        tracker.update(TestRoutes.fix(Geo.moved(TestRoutes.origin, north: 50)))
        for _ in 0..<5 { tracker.update(TestRoutes.fix(Geo.moved(TestRoutes.origin, east: 300), accuracy: 120)) }
        XCTAssertEqual(tracker.state, .onRoute)
        XCTAssertTrue(tracker.poorAccuracy)
    }

    func testWideAccuracyRaisesTheOffRouteThreshold() {
        var tracker = RouteTracker(route: route, destination: TestRoutes.end)
        for _ in 0..<4 { tracker.update(TestRoutes.fix(Geo.moved(TestRoutes.origin, east: 45, north: 100), accuracy: 40)) }
        XCTAssertEqual(tracker.state, .onRoute, "45 m off with 40 m accuracy is within 1.5x accuracy")
    }

    func testArrival() {
        var tracker = RouteTracker(route: route, destination: TestRoutes.end)
        tracker.update(TestRoutes.fix(Geo.moved(TestRoutes.corner, east: 140)))
        XCTAssertEqual(tracker.state, .arrived)
        tracker.update(TestRoutes.fix(TestRoutes.origin))
        XCTAssertEqual(tracker.state, .arrived, "arrival is final")
    }

    func testRemainingTimeScalesTheRouteEstimate() throws {
        var tracker = RouteTracker(route: route, destination: TestRoutes.end)
        tracker.update(TestRoutes.fix(Geo.moved(TestRoutes.origin, north: 175)))
        XCTAssertEqual(try XCTUnwrap(tracker.remainingTime), 300 * 175 / 350, accuracy: 1)
    }

    func testRouteThatDoublesBackKeepsTheLaterPass() throws {
        // Out 100 m north and back along the same street.
        let o = TestRoutes.origin, top = Geo.moved(o, north: 100)
        let route = NavigationRoute(name: nil, distance: 200, expectedTravelTime: 160, steps: [
            NavigationStep(instruction: "Head north", distance: 100, points: [o, top]),
            NavigationStep(instruction: "Make a U-turn", distance: 100, points: [top, o]),
        ])
        let geometry = RouteGeometry(route: route)
        let point = Geo.moved(o, north: 40)
        XCTAssertEqual(try XCTUnwrap(geometry.match(point)).along, 40, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(geometry.match(point, after: 150)).along, 160, accuracy: 0.5)
    }
}
