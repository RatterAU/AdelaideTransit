import MapKit

/// Routed walking time to a stop, rather than straight-line distance over a flat average speed.
///
/// Straight-line under-reads badly wherever a river, a rail corridor or a fenced arterial sits between you
/// and the stop — which is exactly where being told "you can still make it" costs you the bus. `MKDirections`
/// is network-bound and rate-limited, so results are cached and the caller shows the flat estimate until a
/// real answer lands. Nothing ever blocks on it.
@MainActor
@Observable
final class WalkingEstimator {
    static let shared = WalkingEstimator()

    /// ~4.9 km/h. Still the immediate answer, and the fallback when routing fails or is offline.
    static let fallbackMetresPerSecond: Double = 1.35

    /// Both come off the same route, so there is no reason to ask twice: the walked distance is the distance
    /// along the path the route actually takes, which around a river bend or a rail crossing is a long way
    /// off the straight line the list falls back to.
    struct Walk: Equatable {
        let seconds: TimeInterval
        let metres: CLLocationDistance
    }

    /// `nil` value = asked and got nothing back. Cached so a stop MapKit won't route to doesn't re-request
    /// on every reappearance of the sheet.
    private var cache: [String: Walk?] = [:]
    private var inFlight: Set<String> = []

    /// Past this, routing cannot change anything the user sees, so the request is not worth its throttle
    /// budget.
    ///
    /// `walkVerdict` already falls silent beyond a 25-minute walk — that far out the stop is not a
    /// leave-now proposition at any departure time. 25 minutes at the fallback pace is ~2 km of *path*,
    /// and straight-line distance is always ≤ routed distance, so "straight line over 2 km" proves "routed
    /// walk over 25 minutes" without asking. The displayed figure degrades to the straight line, which at
    /// that range is a rough idea of where the stop is rather than a number anyone acts on.
    ///
    /// This is also what bounds the favourites list: only the handful of favourites near you now get
    /// routed, with no arbitrary nearest-N cap to make neighbouring rows disagree about which kind of
    /// distance they're showing. It was 8 km, which asked for four times as far as the answer matters.
    static let maxRoutableMetres: CLLocationDistance = 1_750

    /// 3 decimal places is ~110 m: tight enough that it's still the same walking route, loose enough that
    /// taking a few steps doesn't miss the cache and fire another request.
    private func key(_ stopID: String, _ from: CLLocationCoordinate2D) -> String {
        String(format: "%@|%.3f,%.3f", stopID, from.latitude, from.longitude)
    }

    func cached(stopID: String, from: CLLocationCoordinate2D) -> Walk? {
        cache[key(stopID, from)] ?? nil
    }

    @discardableResult
    func estimate(
        stopID: String, from: CLLocationCoordinate2D, to: CLLocationCoordinate2D
    ) async -> Walk? {
        let k = key(stopID, from)
        if let hit = cache[k] { return hit }
        guard !inFlight.contains(k) else { return nil }

        let straightLine = CLLocation(latitude: from.latitude, longitude: from.longitude)
            .distance(from: CLLocation(latitude: to.latitude, longitude: to.longitude))
        guard straightLine <= Self.maxRoutableMetres else {
            cache[k] = Walk?.none
            return nil
        }

        inFlight.insert(k)
        defer { inFlight.remove(k) }

        // `MKPlacemark` and `MKMapItem(placemark:)` are both deprecated as of iOS 26; the deployment target
        // is 26.0, so there's nothing to fall back to and no availability check to write. A nil address is
        // right here — these are bare coordinates, not places, and geocoding them would be a wasted lookup.
        let request = MKDirections.Request()
        request.source = MKMapItem(
            location: CLLocation(latitude: from.latitude, longitude: from.longitude), address: nil
        )
        request.destination = MKMapItem(
            location: CLLocation(latitude: to.latitude, longitude: to.longitude), address: nil
        )
        request.transportType = .walking
        request.requestsAlternateRoutes = false
        do {
            guard let route = try await MKDirections(request: request).calculate().routes.first else {
                cache[k] = Walk?.none
                return nil
            }
            let walk = Walk(seconds: route.expectedTravelTime, metres: route.distance)
            cache[k] = walk
            return walk
        } catch {
            // Only a permanent answer earns a permanent cache entry. Throttling, a server failure and being
            // offline are all temporary, and caching them as misses meant one bad minute — a burst of
            // requests, a tunnel — left those stops showing the flat straight-line estimate for the rest of
            // the app's life, with nothing to trigger a retry. A stop MapKit genuinely can't route to is
            // still cached, which is what stops it being re-asked forever.
            switch (error as? MKError)?.code {
            case .directionsNotFound, .placemarkNotFound: cache[k] = Walk?.none
            default: break
            }
            return nil
        }
    }
}
