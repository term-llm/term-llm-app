import CoreLocation
import Foundation
import MapKit

/// `LocationProvider` backed by `CLLocationManager`, foreground only.
@MainActor
final class CoreLocationProvider: NSObject, LocationProvider {
    private let manager = CLLocationManager()
    private var authorizationWaiters: [CheckedContinuation<Void, Error>] = []
    private var fixWaiters: [CheckedContinuation<LocationFix, Error>] = []
    private var updateHandler: (@MainActor (LocationFix) -> Void)?
    /// A cached fix newer than this is good enough for planning.
    static let maxCachedAge: TimeInterval = 15
    static let maxPlanningAccuracy: Double = 100

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func currentFix() async throws -> LocationFix {
        try await authorize()
        if let cached = manager.location, -cached.timestamp.timeIntervalSinceNow < Self.maxCachedAge,
           cached.horizontalAccuracy >= 0, cached.horizontalAccuracy <= Self.maxPlanningAccuracy {
            return Self.fix(cached)
        }
        return try await withCheckedThrowingContinuation { continuation in
            fixWaiters.append(continuation)
            // Continuous updates already resolve waiters; otherwise ask once.
            if fixWaiters.count == 1, updateHandler == nil { manager.requestLocation() }
        }
    }

    func startUpdates(mode: TravelMode, _ handler: @escaping @MainActor (LocationFix) -> Void) async throws {
        try await authorize()
        updateHandler = handler
        manager.activityType = mode == .driving ? .automotiveNavigation : .otherNavigation
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = 5
        manager.startUpdatingLocation()
    }

    func stopUpdates() {
        updateHandler = nil
        manager.stopUpdatingLocation()
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
    }

    private func authorize() async throws {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            return
        case .denied, .restricted:
            throw NavigationError.locationDenied
        default:
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                authorizationWaiters.append(continuation)
                if authorizationWaiters.count == 1 { manager.requestWhenInUseAuthorization() }
            }
        }
    }

    private func authorizationChanged(_ status: CLAuthorizationStatus) {
        let result: Result<Void, Error>
        switch status {
        case .notDetermined: return
        case .authorizedWhenInUse, .authorizedAlways: result = .success(())
        default: result = .failure(NavigationError.locationDenied)
        }
        let waiters = authorizationWaiters
        authorizationWaiters = []
        waiters.forEach { $0.resume(with: result) }
    }

    private func received(_ fixes: [LocationFix]) {
        guard let latest = fixes.last else { return }
        if !fixWaiters.isEmpty, latest.horizontalAccuracy >= 0 {
            let waiters = fixWaiters
            fixWaiters = []
            waiters.forEach { $0.resume(returning: latest) }
        }
        if let updateHandler { fixes.forEach(updateHandler) }
    }

    private func failed(_ error: Error) {
        // During continuous updates a transient "location unknown" is normal;
        // only one-shot requests report it.
        if (error as? CLError)?.code == .denied { stopUpdates() }
        guard !fixWaiters.isEmpty else { return }
        let failure: Error = (error as? CLError)?.code == .denied
            ? NavigationError.locationDenied
            : NavigationError.locationUnavailable(error.localizedDescription)
        let waiters = fixWaiters
        fixWaiters = []
        waiters.forEach { $0.resume(throwing: failure) }
    }

    nonisolated static func fix(_ location: CLLocation) -> LocationFix {
        LocationFix(coordinate: Coordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude),
                    horizontalAccuracy: location.horizontalAccuracy, timestamp: location.timestamp, speed: location.speed)
    }
}

extension CoreLocationProvider: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.authorizationChanged(status) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let fixes = locations.map(Self.fix)
        Task { @MainActor in self.received(fixes) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.failed(error) }
    }
}

/// `RoutePlanner` backed by Apple Maps search and directions.
@MainActor
final class MapKitRoutePlanner: RoutePlanner {
    /// Search radius around the user, in metres.
    static let searchSpan: CLLocationDistance = 25_000

    func search(_ query: String, near: Coordinate) async throws -> [NavigationPlace] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = MKCoordinateRegion(center: Self.cl(near), latitudinalMeters: Self.searchSpan,
                                            longitudinalMeters: Self.searchSpan)
        let response: MKLocalSearch.Response
        do {
            response = try await MKLocalSearch(request: request).start()
        } catch let error as MKError where error.code == .placemarkNotFound {
            throw NavigationError.noPlaces(query)
        }
        return response.mapItems.prefix(5).map(Self.place)
    }

    func route(from origin: Coordinate, to place: NavigationPlace, mode: TravelMode) async throws -> NavigationRoute {
        let request = MKDirections.Request()
        request.source = Self.mapItem(origin, name: nil)
        request.destination = Self.mapItem(place.coordinate, name: place.name)
        request.transportType = mode == .driving ? .automobile : .walking
        request.requestsAlternateRoutes = false
        let response: MKDirections.Response
        do {
            response = try await MKDirections(request: request).calculate()
        } catch let error as MKError where error.code == .directionsNotFound {
            throw NavigationError.noRoute(place.name)
        }
        guard let route = response.routes.first else { throw NavigationError.noRoute(place.name) }
        return NavigationRoute(
            name: route.name.isEmpty ? nil : route.name,
            distance: route.distance,
            expectedTravelTime: route.expectedTravelTime,
            steps: route.steps.map { step in
                NavigationStep(instruction: step.instructions, notice: step.notice, distance: step.distance,
                               points: Self.coordinates(step.polyline))
            }
        )
    }

    func describe(_ coordinate: Coordinate) async throws -> NavigationPlace? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        if #available(iOS 26.0, macOS 26.0, *) {
            guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
            return try await request.mapItems.first.map(Self.place)
        }
        guard let placemark = try await CLGeocoder().reverseGeocodeLocation(location).first else { return nil }
        return Self.place(placemark, at: coordinate)
    }

    /// Pre-iOS 26 reverse geocoding result as a place.
    @available(iOS, deprecated: 26.0)
    @available(macOS, deprecated: 26.0)
    private static func place(_ placemark: CLPlacemark, at coordinate: Coordinate) -> NavigationPlace {
        var parts: [String] = []
        for part in [placemark.name, placemark.locality, placemark.administrativeArea, placemark.country] {
            if let part, !part.isEmpty, !parts.contains(part) { parts.append(part) }
        }
        let address = parts.isEmpty ? nil : parts.joined(separator: ", ")
        return NavigationPlace(name: placemark.name ?? address ?? "Current location", address: address, coordinate: coordinate)
    }

    private static func place(_ item: MKMapItem) -> NavigationPlace {
        let coordinate: CLLocationCoordinate2D
        let address: String?
        if #available(iOS 26.0, macOS 26.0, *) {
            coordinate = item.location.coordinate
            address = item.address?.shortAddress ?? item.address?.fullAddress
        } else {
            coordinate = item.placemark.coordinate
            address = item.placemark.title
        }
        return NavigationPlace(name: item.name ?? address ?? "Destination", address: address,
                               coordinate: Coordinate(latitude: coordinate.latitude, longitude: coordinate.longitude))
    }

    private static func mapItem(_ coordinate: Coordinate, name: String?) -> MKMapItem {
        let item: MKMapItem
        if #available(iOS 26.0, macOS 26.0, *) {
            item = MKMapItem(location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude), address: nil)
        } else {
            item = MKMapItem(placemark: MKPlacemark(coordinate: cl(coordinate)))
        }
        item.name = name
        return item
    }

    private static func coordinates(_ polyline: MKPolyline) -> [Coordinate] {
        let points = polyline.points()
        return (0..<polyline.pointCount).map { index in
            let coordinate = points[index].coordinate
            return Coordinate(latitude: coordinate.latitude, longitude: coordinate.longitude)
        }
    }

    private static func cl(_ coordinate: Coordinate) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
}
