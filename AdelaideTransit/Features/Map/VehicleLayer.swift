import SwiftUI
import MapKit

struct RouteInfo {
    let shortName: String
    let color: Color
    let type: Int
}

@MainActor
final class StopAnnotation: NSObject, @preconcurrency MKAnnotation {
    let stop: StopSummary
    let isFavourite: Bool
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: stop.lat, longitude: stop.lon) }
    var title: String? { stop.name }
    init(stop: StopSummary, isFavourite: Bool) {
        self.stop = stop
        self.isFavourite = isFavourite
    }
}

@MainActor
final class VehicleAnnotation: NSObject, @preconcurrency MKAnnotation {
    let tripID: String
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var routeShortName: String
    var color: Color
    var bearing: Double?
    /// Interpolated from the timetable, not observed — drawn faded so it never reads as a real fix.
    let isGhost: Bool

    init(vehicle: LiveVehicle, routes: [String: RouteInfo], isGhost: Bool = false) {
        tripID = vehicle.tripID
        coordinate = vehicle.coordinate
        let info = vehicle.routeID.flatMap { routes[$0] }
        routeShortName = info?.shortName ?? "?"
        color = info?.color ?? .accentColor
        bearing = vehicle.bearing
        self.isGhost = isGhost
    }

    /// Returns whether a property the *view* draws (bearing, route, colour) changed — the coordinate animates
    /// itself via KVO, but nothing observes the others, so a moving bus's chevron and badge stayed frozen at
    /// their first-seen values until the view was re-dequeued. The caller reconfigures the live view when so.
    func update(from vehicle: LiveVehicle, routes: [String: RouteInfo]) -> Bool {
        var changed = false
        if bearing != vehicle.bearing { bearing = vehicle.bearing; changed = true }
        if let info = vehicle.routeID.flatMap({ routes[$0] }) {
            if routeShortName != info.shortName { routeShortName = info.shortName; changed = true }
            if color != info.color { color = info.color; changed = true }
        }
        // A stationary bus re-publishes the same coordinate every poll; animating that is hundreds of
        // pointless Core Animation transactions per minute across a full map of vehicles.
        let moved = abs(coordinate.latitude - vehicle.coordinate.latitude) > 1e-7
            || abs(coordinate.longitude - vehicle.coordinate.longitude) > 1e-7
        if moved {
            UIView.animate(withDuration: 4.0, delay: 0, options: [.curveLinear]) {
                self.coordinate = vehicle.coordinate
            }
        }
        return changed
    }
}

final class StopDotView: MKAnnotationView {
    private static let plainSize = CGRect(x: 0, y: 0, width: 14, height: 14)
    private static let favouriteSize = CGRect(x: 0, y: 0, width: 20, height: 20)
    /// Built on demand — the overwhelming majority of stops are not favourites, and this used to allocate
    /// an image view (and decode the symbol) for every dot on the map.
    private var star: UIImageView?

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        // Precomputed shadowPath — without it Core Animation rasterizes an offscreen mask
        // per view every frame, which is what made panning laggy with hundreds of these on screen.
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 1.5
        layer.shadowOffset = CGSize(width: 0, height: 1)
        layer.shouldRasterize = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Rasterization scale, set where the value is real. `traitCollection.displayScale` is not resolved
    /// until the view is in a window — at `init` it can be 0, which rasterizes every stop dot on the map at
    /// a degenerate scale. UIKit's own default of 1.0 is merely blurry, which is the right thing to have in
    /// the gap.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        let scale = traitCollection.displayScale
        if scale > 0, layer.rasterizationScale != scale { layer.rasterizationScale = scale }
    }

    func configure(isFavourite: Bool) {
        // Never the system callout: its bubble is translucent and styled by MapKit, which reads as a
        // half-legible grey blob over the map. The trip sheet draws its own card instead.
        canShowCallout = false
        let size = isFavourite ? Self.favouriteSize : Self.plainSize
        frame = size
        layer.cornerRadius = size.height / 2
        layer.shadowPath = CGPath(ellipseIn: size, transform: nil)
        backgroundColor = isFavourite ? .systemYellow : .white
        layer.borderWidth = isFavourite ? 2 : 2.5
        layer.borderColor = isFavourite ? UIColor.white.cgColor : UIColor.systemGray.cgColor

        if isFavourite {
            let view = star ?? {
                let created = UIImageView(image: UIImage(systemName: "star.fill"))
                created.tintColor = .white
                created.contentMode = .scaleAspectFit
                addSubview(created)
                star = created
                return created
            }()
            view.isHidden = false
            view.frame = CGRect(origin: .zero, size: size.size).insetBy(dx: 5, dy: 5)
        } else {
            star?.isHidden = true
        }
        // Favourites outrank ordinary stops when MapKit has to decide what to hide in tight space.
        displayPriority = isFavourite ? .required : .defaultLow
    }
}

final class VehicleMarkerView: MKAnnotationView {
    private let badge = UIView()
    private let label = UILabel()
    private let chevron = UIImageView(image: UIImage(systemName: "location.north.fill"))

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        setup()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static let height: CGFloat = 26

    private func setup() {
        frame = CGRect(x: 0, y: 0, width: 44, height: Self.height)
        centerOffset = .zero
        canShowCallout = false
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.3
        layer.shadowRadius = 2
        layer.shadowOffset = CGSize(width: 0, height: 1)

        badge.layer.borderWidth = 1
        badge.layer.borderColor = UIColor.white.cgColor
        addSubview(badge)

        label.font = .systemFont(ofSize: 12, weight: .bold)
        label.textColor = .white
        label.textAlignment = .center
        addSubview(label)

        chevron.tintColor = .white
        chevron.contentMode = .scaleAspectFit
        addSubview(chevron)
    }

    /// Badge width grows to fit the route number — a fixed 44pt box was clipping anything longer than 2 chars.
    func configure(routeShortName: String, color: Color, bearing: Double?, opacity: CGFloat, scale: CGFloat) {
        let textWidth = (routeShortName as NSString).size(withAttributes: [.font: label.font as Any]).width
        let showsChevron = bearing != nil
        let width = max(30, ceil(textWidth) + 18 + (showsChevron ? 14 : 0))
        bounds = CGRect(x: 0, y: 0, width: width, height: Self.height)
        transform = CGAffineTransform(scaleX: scale, y: scale)
        layer.shadowPath = CGPath(roundedRect: bounds, cornerWidth: bounds.height / 2, cornerHeight: bounds.height / 2, transform: nil)

        badge.frame = bounds
        badge.layer.cornerRadius = bounds.height / 2
        badge.backgroundColor = UIColor(color)

        let labelWidth = width - (showsChevron ? 16 : 0)
        label.frame = CGRect(x: 8, y: 0, width: labelWidth - 8, height: bounds.height)
        label.text = routeShortName
        alpha = opacity

        if let bearing {
            chevron.isHidden = false
            chevron.frame = CGRect(x: width - 16, y: bounds.height / 2 - 6, width: 12, height: 12)
            chevron.transform = CGAffineTransform(rotationAngle: bearing * .pi / 180)
        } else {
            chevron.isHidden = true
        }
    }
}

struct RouteLines {
    let travelled: [CLLocationCoordinate2D]
    let ahead: [CLLocationCoordinate2D]
    let color: Color

    /// Split a trip's shape into travelled/ahead at the bus's nearest shape point.
    /// Shared by the map and the trip sheet — both drew the same line and had drifted into two copies.
    static func split(
        shape: [(lat: Double, lon: Double, dist: Double?)],
        at vehicle: CLLocationCoordinate2D?,
        color: Color
    ) -> RouteLines? {
        guard !shape.isEmpty else { return nil }
        let coords = shape.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        guard let vehicle else { return RouteLines(travelled: [], ahead: coords, color: color) }

        var bestIdx = 0
        var bestDist = Double.greatestFiniteMagnitude
        for (i, c) in coords.enumerated() {
            let dLat = c.latitude - vehicle.latitude
            let dLon = c.longitude - vehicle.longitude
            let d = dLat * dLat + dLon * dLon
            if d < bestDist { bestDist = d; bestIdx = i }
        }
        return RouteLines(travelled: Array(coords[0...bestIdx]), ahead: Array(coords[bestIdx...]), color: color)
    }
}

struct MapViewRepresentable: UIViewRepresentable {
    static let defaultRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: -34.9285, longitude: 138.6007),
        span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
    )

    let stops: [StopSummary]
    /// Bumped by the owner whenever `stops` is reassigned. SwiftUI calls `updateUIView` on every render —
    /// including each 1s clock tick — and rebuilding annotation ID sets over ~1500 stops each time was
    /// pure waste, since the list only actually changes when a query lands.
    var stopsVersion: Int = 0
    var favouriteStopIDs: Set<String> = []
    let vehicles: [LiveVehicle]
    /// Bumped by the owner whenever `vehicles` or `ghostVehicles` is reassigned, exactly like `stopsVersion`.
    /// `updateUIView` runs on every render — a sheet drag, a keystroke in the search field, a pan tick — and
    /// `applyVehicles` was hashing every trip ID on the map twice per call to rediscover that nothing had
    /// changed. The vehicle list only actually moves when the feed publishes.
    var vehiclesVersion: Int = 0
    /// Schedule-interpolated positions for trips with no live feed, so they don't just vanish off the map.
    var ghostVehicles: [LiveVehicle] = []
    let routes: [String: RouteInfo]
    let userTrackingEnabled: Bool
    var routeLines: RouteLines? = nil
    var flyTo: MKCoordinateRegion? = nil
    var flyToID: UUID? = nil
    var mapEmphasis: String = "muted"
    var markerScale: CGFloat = 1.0
    let onRegionChange: (MKCoordinateRegion) -> Void
    let onSelectStop: (StopSummary) -> Void
    let onSelectVehicle: (String) -> Void
    /// When set, a stop tap previews the stop rather than opening it — the caller draws its own card and
    /// decides what a second tap does. Nil (the main map) keeps the single tap that goes straight there,
    /// where there is no trip context worth previewing. Called with nil when a tap lands on the bare map,
    /// which is what dismisses the caller's card.
    var onPreviewStop: ((StopSummary?) -> Void)? = nil
    /// The stop the caller is previewing, echoed back as a point in the map view's own coordinate space on
    /// every region change so the card can sit on top of its pin instead of at the bottom of the screen.
    /// Nil point = that stop is off screen (or gone), so the caller draws nothing.
    var previewStopID: String? = nil
    var onPreviewPoint: ((CGPoint?) -> Void)? = nil

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.preferredConfiguration = Self.configuration(for: mapEmphasis)
        map.register(VehicleMarkerView.self, forAnnotationViewWithReuseIdentifier: "vehicle")
        map.register(StopDotView.self, forAnnotationViewWithReuseIdentifier: "stop")
        map.setRegion(Self.defaultRegion, animated: false)
        if onPreviewStop != nil {
            let tap = UITapGestureRecognizer(
                target: context.coordinator, action: #selector(Coordinator.handleMapTap(_:))
            )
            // MapKit's own recognisers must keep working — this one only observes, so that a tap on bare map
            // dismisses the caller's preview card.
            tap.delegate = context.coordinator
            tap.cancelsTouchesInView = false
            map.addGestureRecognizer(tap)
        }
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.applyStops(stops, version: stopsVersion, favourites: favouriteStopIDs, to: map)
        context.coordinator.applyVehicles(
            vehicles, version: vehiclesVersion, ghosts: ghostVehicles, routes: routes, to: map
        )
        context.coordinator.applyRouteLines(routeLines, to: map)

        // Both of these were being reassigned on every SwiftUI render. Reassigning `preferredConfiguration`
        // makes MapKit reconfigure and redraw the base map — doing that on each frame arrival, and during
        // panning, was pure overhead for a value that changes only from Settings.
        if map.showsUserLocation != userTrackingEnabled {
            map.showsUserLocation = userTrackingEnabled
        }
        if context.coordinator.lastEmphasis != mapEmphasis {
            context.coordinator.lastEmphasis = mapEmphasis
            map.preferredConfiguration = Self.configuration(for: mapEmphasis)
        }

        if let flyTo, flyToID != context.coordinator.lastFlyToID {
            context.coordinator.lastFlyToID = flyToID
            map.setRegion(flyTo, animated: true)
        }

        // A newly previewed stop needs its first point without waiting for a pan. Deferred: this runs inside
        // SwiftUI's update pass, and the callback writes state.
        if context.coordinator.lastPreviewStopID != previewStopID {
            context.coordinator.lastPreviewStopID = previewStopID
            DispatchQueue.main.async { [weak map] in
                guard let map else { return }
                context.coordinator.reportPreviewPoint(map)
            }
        }
    }

    private static func configuration(for emphasis: String) -> MKMapConfiguration {
        switch emphasis {
        case "standard": return MKStandardMapConfiguration(elevationStyle: .flat)
        case "hybrid": return MKHybridMapConfiguration(elevationStyle: .flat)
        default: return MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: MapViewRepresentable
        private var stopAnnotations: [String: StopAnnotation] = [:]
        private var vehicleAnnotations: [String: VehicleAnnotation] = [:]
        private var regionChangeWorkItem: DispatchWorkItem?
        private var routeOverlays: [MKPolyline] = []
        private var lastStopsVersion = -1
        private var lastVehiclesVersion = -1
        private var lastFavourites: Set<String> = []
        private var lastRouteSignature = ""
        private var lastMarkerScale: CGFloat?
        var lastEmphasis: String?
        var lastFlyToID: UUID?
        var lastPreviewStopID: String?
        private var lastReportedPoint: CGPoint?

        init(_ parent: MapViewRepresentable) { self.parent = parent }

        func applyRouteLines(_ lines: RouteLines?, to map: MKMapView) {
            // Route shapes run to thousands of points. Rebuilding both polylines on every render — which
            // includes every realtime frame and every pan tick — was the single most expensive thing here,
            // and almost always produced an identical overlay.
            // Counts alone would collide between two trips whose shapes happen to be the same length, and
            // the map view is reused across trips — so anchor on the split coordinate too.
            let signature = lines.map {
                "\($0.travelled.count)|\($0.ahead.count)|\($0.ahead.first?.latitude ?? 0)|\($0.ahead.first?.longitude ?? 0)"
            } ?? "none"
            guard signature != lastRouteSignature else { return }
            lastRouteSignature = signature

            map.removeOverlays(routeOverlays)
            routeOverlays = []
            guard let lines else { return }
            if lines.travelled.count > 1 {
                let poly = MKPolyline(coordinates: lines.travelled, count: lines.travelled.count)
                poly.title = "travelled"
                map.addOverlay(poly)
                routeOverlays.append(poly)
            }
            if lines.ahead.count > 1 {
                let poly = MKPolyline(coordinates: lines.ahead, count: lines.ahead.count)
                poly.title = "ahead"
                map.addOverlay(poly)
                routeOverlays.append(poly)
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolylineRenderer(polyline: polyline)
            let baseColor = UIColor(parent.routeLines?.color ?? .accentColor)
            renderer.strokeColor = polyline.title == "travelled" ? baseColor.withAlphaComponent(0.3) : baseColor
            renderer.lineWidth = 4
            return renderer
        }

        func applyStops(
            _ stops: [StopSummary], version: Int, favourites: Set<String>, to map: MKMapView
        ) {
            guard version != lastStopsVersion || favourites != lastFavourites else { return }
            lastStopsVersion = version
            let favouritesChanged = favourites != lastFavourites
            lastFavourites = favourites

            let incomingIDs = Set(stops.map(\.id))
            for removedID in Set(stopAnnotations.keys).subtracting(incomingIDs) {
                if let ann = stopAnnotations.removeValue(forKey: removedID) { map.removeAnnotation(ann) }
            }
            for stop in stops {
                let isFavourite = favourites.contains(stop.id)
                if let existing = stopAnnotations[stop.id] {
                    // Favourite state is fixed at construction (it drives clustering), so a change rebuilds.
                    guard favouritesChanged, existing.isFavourite != isFavourite else { continue }
                    map.removeAnnotation(existing)
                }
                let ann = StopAnnotation(stop: stop, isFavourite: isFavourite)
                stopAnnotations[stop.id] = ann
                map.addAnnotation(ann)
            }
        }

        func applyVehicles(
            _ vehicles: [LiveVehicle], version: Int, ghosts: [LiveVehicle],
            routes: [String: RouteInfo], to map: MKMapView
        ) {
            // Marker size is a Settings slider, and it reaches a view only through `configure`. Reconfiguring
            // solely on a vehicle-property change meant dragging the slider did nothing to the buses already
            // on screen — they kept the size they were created at until something else happened to rebuild
            // them, which on a map you're already looking at is never.
            let scaleChanged = parent.markerScale != lastMarkerScale
            // Version-gated for the same reason `applyStops` is: this runs on every render, and everything
            // below is O(vehicles) — two full sets of trip IDs hashed and subtracted, then a per-vehicle
            // dictionary lookup — against up to ~1000 buses. Dragging the sheet detent or typing in the
            // search field re-renders `MapScreen`, so that was the whole diff, per frame, for a list that
            // changes once per publish. The scale check stays outside the gate: the slider changes nothing
            // about the vehicles, only how they are drawn.
            guard version != lastVehiclesVersion || scaleChanged else { return }
            lastVehiclesVersion = version
            lastMarkerScale = parent.markerScale

            // A trip that just gained a live fix must drop its ghost, so live always wins on tripID. On the
            // full map there are no ghosts (they belong to the trip sheet), so skip building the live-ID set
            // over ~1000 vehicles when nothing needs de-duping against it.

            let all: [(LiveVehicle, Bool)]
            if ghosts.isEmpty {
                all = vehicles.map { ($0, false) }
            } else {
                let liveIDs = Set(vehicles.map(\.tripID))
                all = vehicles.map { ($0, false) } + ghosts.filter { !liveIDs.contains($0.tripID) }.map { ($0, true) }
            }
            let incomingIDs = Set(all.map(\.0.tripID))

            for removedID in Set(vehicleAnnotations.keys).subtracting(incomingIDs) {
                if let ann = vehicleAnnotations.removeValue(forKey: removedID) { map.removeAnnotation(ann) }
            }
            for (vehicle, isGhost) in all {
                // Ghost/live is baked into the annotation, so a flip has to rebuild rather than update.
                if let existing = vehicleAnnotations[vehicle.tripID], existing.isGhost == isGhost {
                    // Coordinate animates itself; reconfigure the on-screen view only when bearing/route/colour
                    // actually changed — which is a new publish, not every render.
                    let redraw = existing.update(from: vehicle, routes: routes)
                    if redraw || scaleChanged,
                       let view = map.view(for: existing) as? VehicleMarkerView {
                        view.configure(
                            routeShortName: existing.routeShortName,
                            color: isGhost ? .gray : existing.color,
                            bearing: existing.bearing,
                            opacity: isGhost ? 0.45 : 1,
                            scale: parent.markerScale
                        )
                    }
                } else {
                    if let stale = vehicleAnnotations[vehicle.tripID] { map.removeAnnotation(stale) }
                    let ann = VehicleAnnotation(vehicle: vehicle, routes: routes, isGhost: isGhost)
                    vehicleAnnotations[vehicle.tripID] = ann
                    map.addAnnotation(ann)
                }
            }
        }

        /// Fires continuously while the map moves, unlike `regionDidChangeAnimated`, so the preview card
        /// stays glued to its pin through the pan rather than jumping at the end of it.
        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            reportPreviewPoint(mapView)
        }

        /// Where the previewed stop currently sits in the map view. Nil once it leaves the visible rect — a
        /// card pinned to an off-screen pin would otherwise sit clamped at the edge pointing at nothing.
        func reportPreviewPoint(_ map: MKMapView) {
            guard let report = parent.onPreviewPoint else { return }
            var point: CGPoint?
            if let id = parent.previewStopID, let annotation = stopAnnotations[id] {
                let candidate = map.convert(annotation.coordinate, toPointTo: map)
                if map.bounds.insetBy(dx: -40, dy: -40).contains(candidate) { point = candidate }
            }
            // Every pan tick writes SwiftUI state otherwise, re-rendering the whole sheet for a sub-pixel move.
            if let point, let last = lastReportedPoint,
               abs(point.x - last.x) < 0.5, abs(point.y - last.y) < 0.5 { return }
            if point == nil && lastReportedPoint == nil { return }
            lastReportedPoint = point
            report(point)
        }

        /// A tap on bare map dismisses the caller's preview. Taps that land on an annotation are left alone —
        /// `didSelect` owns those, and clearing here would race it into dismissing the card it just opened.
        @objc func handleMapTap(_ recognizer: UITapGestureRecognizer) {
            guard let map = recognizer.view as? MKMapView, parent.previewStopID != nil else { return }
            var hit = map.hitTest(recognizer.location(in: map), with: nil)
            while let view = hit {
                if view is MKAnnotationView { return }
                hit = view.superview
            }
            parent.onPreviewStop?(nil)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            regionChangeWorkItem?.cancel()
            let region = mapView.region
            let work = DispatchWorkItem { [weak self] in self?.parent.onRegionChange(region) }
            regionChangeWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }
            // `as?`, not `as!`. Both identifiers are registered in `makeUIView`, so the cast holds — but a
            // forced cast turns any future mismatch (a renamed identifier, a reused map view) into a crash
            // on the map, where `nil` is a missing pin.
            if let stopAnn = annotation as? StopAnnotation {
                guard let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: "stop", for: stopAnn
                ) as? StopDotView else { return nil }
                view.configure(isFavourite: stopAnn.isFavourite)
                return view
            }
            if let vehicleAnn = annotation as? VehicleAnnotation {
                guard let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: "vehicle", for: vehicleAnn
                ) as? VehicleMarkerView else { return nil }
                view.configure(
                    routeShortName: vehicleAnn.routeShortName,
                    color: vehicleAnn.isGhost ? .gray : vehicleAnn.color,
                    bearing: vehicleAnn.bearing,
                    opacity: vehicleAnn.isGhost ? 0.45 : 1,
                    scale: parent.markerScale
                )
                return view
            }
            return nil
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let stopAnn = view.annotation as? StopAnnotation {
                mapView.deselectAnnotation(stopAnn, animated: false)
                if let preview = parent.onPreviewStop { return preview(stopAnn.stop) }
                parent.onSelectStop(stopAnn.stop)
            } else if let vehicleAnn = view.annotation as? VehicleAnnotation {
                parent.onSelectVehicle(vehicleAnn.tripID)
                mapView.deselectAnnotation(vehicleAnn, animated: false)
            }
        }
    }
}
