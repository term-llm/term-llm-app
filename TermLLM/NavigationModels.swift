import Foundation

/// A latitude/longitude pair that is `Equatable` and `Sendable`, unlike
/// `CLLocationCoordinate2D`, so routes and fixes can be compared in tests.
struct Coordinate: Equatable, Sendable {
    var latitude: Double
    var longitude: Double
}

/// One location reading from the device.
struct LocationFix: Equatable, Sendable {
    var coordinate: Coordinate
    /// Radius of uncertainty in metres; negative means invalid.
    var horizontalAccuracy: Double
    var timestamp: Date
    /// Metres per second, or negative when unknown.
    var speed: Double = -1
}

enum TravelMode: String, CaseIterable, Sendable {
    case walking, driving
}

struct NavigationPlace: Equatable, Sendable {
    var name: String
    var address: String?
    var coordinate: Coordinate
}

/// One maneuver of a route: the instruction to give when reaching the start
/// of `points`, then the stretch to travel until the next step.
struct NavigationStep: Equatable, Sendable {
    var instruction: String
    var notice: String?
    var distance: Double
    var points: [Coordinate]
}

struct NavigationRoute: Equatable, Sendable {
    var name: String?
    var distance: Double
    var expectedTravelTime: TimeInterval
    var steps: [NavigationStep]
}

enum NavigationError: LocalizedError, Equatable {
    case locationDenied
    case locationUnavailable(String)
    case noPlaces(String)
    case noRoute(String)
    case unknownPreview(String)
    case noPreview

    var errorDescription: String? {
        switch self {
        case .locationDenied:
            return "Location access is off for term-llm. The user can turn it on in Settings › Privacy & Security › Location Services › term-llm."
        case .locationUnavailable(let reason):
            return "The iPhone couldn't get its location: \(reason)"
        case .noPlaces(let query):
            return "No places matched \"\(query)\" near the user. Try a more specific name or an address."
        case .noRoute(let name):
            return "Apple Maps found no route to \(name)."
        case .unknownPreview(let id):
            return "There is no route preview \"\(id)\". Call navigation_preview first."
        case .noPreview:
            return "There is no route to start. Call navigation_preview first."
        }
    }
}
