import CoreLocation
import Observation

/// `@MainActor` because that is where it already lives: the delegate is set from a main-actor initialiser,
/// so Core Location delivers every callback on the main queue, and every reader is a SwiftUI view. Stating it
/// makes the mutations of `authorized` and `lastLocation` checked rather than assumed.
@MainActor
@Observable
final class LocationManager: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var authorized = false
    var lastLocation: CLLocationCoordinate2D?

    override init() {
        super.init()
        manager.delegate = self
        // Ten metres is finer than any decision here needs — which stop is nearest, roughly how far you'd
        // walk. Full accuracy runs the GPS chip continuously for precision nothing in the UI uses.
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 10
        // Off, deliberately. When iOS pauses updates it does not resume them on its own — it expects the app
        // to notice and restart — so a few stationary minutes froze `lastLocation` for the rest of the
        // session: favourites stuck in the order you were last walking in, walking estimates measured from
        // where you used to be, and auto-centre pointing at a previous suburb. `distanceFilter` is already
        // doing the battery saving this was for.
        manager.pausesLocationUpdatesAutomatically = false
    }

    func requestWhenInUse() {
        manager.requestWhenInUseAuthorization()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorized = manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways
        if authorized { manager.startUpdatingLocation() }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        lastLocation = locations.last?.coordinate
    }
}
