import SwiftUI
import MapKit
import UIKit

private struct FlyToCommand: Equatable {
    let id = UUID()
    let region: MKCoordinateRegion
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

/// What the map's single sheet is showing. Modelling it as one value rather than two independent
/// `@State` flags is what lets stop → trip → stop be a content swap instead of a dismiss racing a present.
private enum SheetDestination: Identifiable, Equatable {
    case stop(StopSummary)
    case trip(tripID: String)

    var id: String {
        switch self {
        case .stop(let stop): return "stop-\(stop.id)"
        case .trip(let tripID): return "trip-\(tripID)"
        }
    }
}

struct MapScreen: View {
    @Environment(\.gtfsStore) private var store
    @Environment(\.realtimeEngine) private var engine
    @Environment(Router.self) private var router

    @State private var visibleRegion: MKCoordinateRegion?
    @State private var stops: [StopSummary] = []
    @State private var vehicles: [String: LiveVehicle] = [:]
    /// `filteredVehicles`, memoised. As a computed property read straight from `body` it culled up to ~1000
    /// vehicles to the viewport on *every* render — and `body` re-renders on a sheet-detent drag and on every
    /// keystroke in the search field, not just when a frame lands. The bus positions change once per publish.
    @State private var shownVehicles: [LiveVehicle] = []
    /// Bumped alongside `shownVehicles`/`tripGhostVehicle`, so the map can skip its own O(vehicles) diff for
    /// renders that didn't move anything. Same contract as `stopsVersion`.
    @State private var vehiclesVersion = 0
    @State private var routes: [String: RouteInfo] = [:]
    @State private var lastFrame: RealtimeFrame?
    @State private var flyTo: FlyToCommand?

    /// Both sheets, one piece of state, one presentation host. See the `.sheet` call site.
    @State private var presented: SheetDestination?
    /// The sheet's height, owned here rather than inside either sheet. See `detents(for:)`.
    @State private var sheetDetent: PresentationDetent = Self.stopDetent
    @State private var tripOriginStop: StopSummary?
    @State private var tripStopTimes: [(seq: Int, stopID: String, name: String, lat: Double, lon: Double, dep: Int)] = []
    @State private var tripShapePoints: [(lat: Double, lon: Double, dist: Double?)] = []
    @State private var tripRouteColor: Color = .accentColor
    /// Kept alongside the colour so the ghost marker can carry a route: `VehicleAnnotation` resolves its
    /// badge through `routes[routeID]`, and a nil id rendered every schedule-interpolated bus as "?".
    @State private var tripRouteID: String?
    /// Memoised: the split is an O(shape) scan and shapes run to thousands of points. As a computed
    /// property it re-ran on every render — including every 1s clock tick — not just when the bus moved.
    @State private var tripRouteLines: RouteLines?
    @State private var tripGhostVehicle: LiveVehicle?
    @State private var loadedStopBox: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)?
    @State private var loadedCell: Double = 0
    @State private var stopsVersion = 0
    @State private var favouriteStopIDs: Set<String> = []
    @State private var favouriteStops: [StopSummary] = []
    @State private var searchText = ""
    @State private var searchResults: [StopSummary] = []
    @Environment(LocationManager.self) private var locationManager
    @State private var hasCenteredOnUser = false
    @FocusState private var searchFocused: Bool

    @AppStorage("hideRouteBus") private var hideBus = false
    @AppStorage("hideRouteTram") private var hideTram = false
    @AppStorage("hideRouteTrain") private var hideTrain = false
    @AppStorage("mapEmphasis") private var mapEmphasis = "muted"
    @AppStorage("vehicleMarkerScale") private var markerScale: Double = 1.0
    @AppStorage("showAllLiveBuses") private var showAllLiveBuses = true
    @AppStorage("autoCenterOnLaunch") private var autoCenterOnLaunch = true
    @AppStorage("keepScreenAwakeTracking") private var keepScreenAwake = true
    @AppStorage("showGhostsOnMap") private var showGhostsOnMap = true
    @AppStorage("hapticsEnabled") private var haptics = true

    private static let adelaideCBD = CLLocationCoordinate2D(latitude: -34.9285, longitude: 138.6007)
    /// Grid resolution across the viewport. 18 held the on-screen annotation count under ~235 at every zoom
    /// against the real 9171-stop feed (versus an unbounded 4900+ before thinning existed); 24 trades some
    /// of that headroom back for stops appearing at a wider zoom, which is the whole point of the number.
    /// Cells scale with the square, so this is roughly 1.8x the annotations — re-measure if you raise it.
    /// Re-measured 2026-10-31: 229 on screen at peak, 541 held across the padded box — see `gridCell`.
    private static let stopsAcrossViewport = 24
    /// Below this span nothing is thinned at all. Raised from 0.02: the old boundary meant you had to zoom
    /// in further than felt natural before a specific stop reappeared.
    private static let thinningThresholdSpan = 0.03
    /// Backstop only — grid thinning already bounds the count well below this.
    private static let stopFetchLimit = 1200
    /// The height a stop sheet opens at: enough for the header and the first few departures, low enough
    /// that the map you tapped the pin on is still the thing you're looking at.
    private static let stopDetent = PresentationDetent.height(280)
    private static let tripDetent = PresentationDetent.height(360)

    /// Derived, so every reader below stayed as it was when the two flags became one enum.
    private var selectedStop: StopSummary? {
        if case .stop(let stop) = presented { return stop }
        return nil
    }

    private var selectedTripID: String? {
        if case .trip(let tripID) = presented { return tripID }
        return nil
    }

    /// Recomputes the drawn vehicle set and tells the map it changed. Called from the few places that can
    /// actually change it — a new frame, a pan, the route filters, opening or closing a trip — rather than
    /// letting `body` recompute it for every unrelated render.
    private func rebuildShownVehicles() {
        shownVehicles = filteredVehicles
        vehiclesVersion &+= 1
    }

    private var filteredVehicles: [LiveVehicle] {
        // Tracking a trip narrows to that one bus, so the route reads clean and nothing else is computed.
        if let selectedTripID {
            return vehicles[selectedTripID].map { [$0] } ?? []
        }
        guard showAllLiveBuses else { return [] }

        let now = Date.now
        // Cull to the viewport first. Adelaide runs ~1000 vehicles at peak and every survivor becomes an
        // MKAnnotation; off-screen ones cost view churn and diffing for something nobody can see.
        let bounds = visibleRegion.map { region -> (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) in
            let padLat = region.span.latitudeDelta * 0.75
            let padLon = region.span.longitudeDelta * 0.75
            return (region.center.latitude - padLat, region.center.latitude + padLat,
                    region.center.longitude - padLon, region.center.longitude + padLon)
        }

        return vehicles.values.filter { vehicle in
            if let bounds {
                guard vehicle.lat >= bounds.minLat, vehicle.lat <= bounds.maxLat,
                      vehicle.lon >= bounds.minLon, vehicle.lon <= bounds.maxLon else { return false }
            }
            // The Settings stale cutoff, not a second hardcoded one: at 120 s here against 90 s there, a bus
            // sat on the map while its departure row said "no GPS".
            guard now.timeIntervalSince(vehicle.timestamp) <= GhostCutoffs.staleAfter else { return false }
            guard let routeID = vehicle.routeID, let type = routes[routeID]?.type else { return true }
            if hideBus && type == 3 { return false }
            if hideTram && type == 0 { return false }
            if hideTrain && type == 2 { return false }
            return true
        }
    }

    /// While a trip is open, the map declutters to just that route's stops instead of the whole viewport.
    private var displayedStops: [StopSummary] {
        guard selectedTripID != nil else { return stops }
        return tripStopTimes.map { StopSummary(id: $0.stopID, code: nil, name: $0.name, lat: $0.lat, lon: $0.lon) }
    }

    /// Favourites are never thinned away. Grid thinning keeps the most-connected stop per cell, which is
    /// exactly the wrong answer for a quiet suburban stop next to a busy one — and that quiet one is the
    /// stop you starred. Merged after the grid query, so it survives at any zoom.
    private var displayedStopsWithFavourites: [StopSummary] {
        guard selectedTripID == nil, !favouriteStops.isEmpty else { return displayedStops }
        let present = Set(displayedStops.map(\.id))
        return displayedStops + favouriteStops.filter { !present.contains($0.id) }
    }

    /// The tracked trip has no live fix — show where the timetable says it should be rather than nothing.
    ///
    /// Memoised for the same reason `tripRouteLines` is: this runs two O(shape) nearest-point scans, and as
    /// a computed property it did so on every render rather than only when a new frame moved things.
    private func rebuildTripGhost() {
        tripGhostVehicle = showGhostsOnMap ? interpolatedTripGhost() : nil
        vehiclesVersion &+= 1 // the ghost is drawn through the same annotation path
    }

    private func interpolatedTripGhost() -> LiveVehicle? {
        guard let tripID = selectedTripID, vehicles[tripID] == nil,
              let firstDep = tripStopTimes.first?.dep else { return nil }
        guard let position = Merge.interpolatedPosition(
            shape: tripShapePoints,
            stopTimes: tripStopTimes.map { (seq: $0.seq, lat: $0.lat, lon: $0.lon, dep: $0.dep) },
            serviceMidnight: Merge.serviceDate(firstDeparture: firstDep, now: .now),
            now: .now
        ) else { return nil }
        return LiveVehicle(
            tripID: tripID, vehicleLabel: nil, routeID: tripRouteID, directionID: nil,
            lat: position.lat, lon: position.lon, bearing: nil, speedMS: nil,
            timestamp: .now, currentStopSequence: nil
        )
    }

    /// Cheap Equatable stand-in for "the tracked bus moved" — CLLocationCoordinate2D isn't Equatable.
    private var vehicleFix: String? {
        guard let tripID = selectedTripID, let v = vehicles[tripID] else { return nil }
        return "\(v.lat),\(v.lon)"
    }

    private func rebuildTripRouteLines() {
        guard let tripID = selectedTripID, !tripShapePoints.isEmpty else {
            tripRouteLines = nil
            return
        }
        tripRouteLines = RouteLines.split(
            shape: tripShapePoints,
            at: vehicles[tripID]?.coordinate,
            color: tripRouteColor
        )
    }

    private var demand: ScreenDemand {
        if selectedTripID != nil { return .tripDetail }
        return .map(stopSheetOpen: selectedStop != nil, showsVehicles: showAllLiveBuses)
    }

    var body: some View {
        ZStack(alignment: .top) {
            MapViewRepresentable(
                stops: displayedStopsWithFavourites,
                stopsVersion: stopsVersion,
                favouriteStopIDs: favouriteStopIDs,
                vehicles: shownVehicles,
                vehiclesVersion: vehiclesVersion,
                ghostVehicles: tripGhostVehicle.map { [$0] } ?? [],
                routes: routes,
                userTrackingEnabled: locationManager.authorized,
                routeLines: tripRouteLines,
                flyTo: flyTo?.region,
                flyToID: flyTo?.id,
                mapEmphasis: mapEmphasis,
                markerScale: markerScale,
                onRegionChange: { region in
                    visibleRegion = region
                    rebuildShownVehicles() // the cull is to this viewport
                    Task { await loadStops(in: region) }
                },
                onSelectStop: { stop in showStop(stop) },
                // A bus tapped on the map has no boarding stop. Left set, the stop a previous trip was opened
                // from came back as "YOUR STOP" on this one, and widened its list and its framing to match.
                onSelectVehicle: { tripID in
                    tripOriginStop = nil
                    showTrip(tripID)
                }
            )
            .ignoresSafeArea()

            if searchFocused {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture { searchFocused = false }
            }

            searchBar
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .sensoryFeedback(.selection, trigger: selectedStop?.id) { _, _ in haptics }
        .sensoryFeedback(.selection, trigger: selectedTripID) { _, _ in haptics }
        .overlay(alignment: .bottomTrailing) {
            locateButton
        }
        .overlay(alignment: .bottomLeading) {
            if let ts = lastFrame?.headerTimestamp {
                DataAgeBadge(timestamp: ts)
                    .padding()
            }
        }
        // `initial: true` is load-bearing. Tapping a favourite sets `pendingStop` and switches to this tab —
        // but the map tab is created lazily, so on the first open of a session the view didn't exist yet when
        // `pendingStop` was set, and a plain `onChange` never fires for a value already present on appear. The
        // result was "opens the map somewhere irrelevant and never goes to the stop". Firing on the initial
        // value handles the already-set stop the moment the map appears.
        .onChange(of: router.pendingStop, initial: true) { _, newValue in
            guard let newValue else { return }
            searchFocused = false
            showStop(newValue)
            fly(to: CLLocationCoordinate2D(latitude: newValue.lat, longitude: newValue.lon), spanDelta: 0.01)
            router.pendingStop = nil
        }
        // `initial: true` for the same reason `pendingStop` needs it: the app opens on Favourites, so the map
        // is built lazily — by the time it first appears the location fix has usually already landed, and a
        // plain `onChange` never fires for a value that was already there. "Auto-centre at launch" did
        // nothing at all except in the race where you opened the map before the first fix.
        //
        // Guarded so it can't steal a deliberate move: both this and the `pendingStop` handler fire on that
        // first appear, and either order is safe — a stop still pending, or a fly already issued, means the
        // user asked to be somewhere specific.
        .onChange(of: locationManager.lastLocation?.latitude, initial: true) { _, _ in
            guard let loc = locationManager.lastLocation, !hasCenteredOnUser, autoCenterOnLaunch,
                  flyTo == nil, presented == nil, router.pendingStop == nil else { return }
            hasCenteredOnUser = true
            fly(to: loc, spanDelta: 0.03)
        }
        // Derived from both inputs, not just the trip. Keyed on `selectedTripID` alone, turning the setting
        // off mid-trip never fired — the screen stayed awake for the rest of the session — and neither did
        // leaving the tab. Releasing it on disappear costs nothing: `initial: true` re-asserts on return.
        .onChange(of: keepScreenAwake && selectedTripID != nil, initial: true) { _, awake in
            UIApplication.shared.isIdleTimerDisabled = awake
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .task(id: selectedTripID) { await loadTripContext() }
        .onChange(of: vehicleFix) { _, _ in rebuildTripRouteLines() }
        .onChange(of: showGhostsOnMap) { _, _ in rebuildTripGhost() }
        // The other inputs to `filteredVehicles`. One `onChange` over an array rather than four, because the
        // list is only ever read as a whole and `[Bool]` is Equatable for free.
        .onChange(of: [showAllLiveBuses, hideBus, hideTram, hideTrain]) { _, _ in rebuildShownVehicles() }
        .task {
            let loaded = (try? await store.allRoutes()) ?? [:]
            routes = loaded.mapValues {
                RouteInfo(
                    shortName: $0.shortName,
                    color: Theme.routeColor($0.color, seed: $0.shortName),
                    textColor: Theme.routeTextColor($0.color),
                    type: $0.type
                )
            }
            // The hide-by-mode filters read `routes`; until this lands they can't classify anything.
            rebuildShownVehicles()
        }
        .task(id: demand) { await engine.setDemand(demand) }
        .task {
            for await frame in engine.frames {
                lastFrame = frame
                vehicles = frame.vehicles
                rebuildShownVehicles()
                rebuildTripGhost()
            }
        }
        .task { await loadFavourites() }
        // ONE sheet modifier, not two.
        //
        // Two chained `.sheet`s on the same view each get their own presentation host, and moving between
        // them (tapping a departure inside the stop sheet) meant dismissing one host while presenting from
        // another — which is what produced "Presenting view controller from detached view controller ...
        // will become a hard exception in a future release". A single modifier over an enum means the
        // transition is one content swap inside one host.
        // Starring a stop happens inside the sheet, so the map's gold pins refresh as it closes.
        .sheet(item: $presented, onDismiss: { Task { await loadFavourites() } }) { destination in
            sheetContent(for: destination)
                // `.id` is load-bearing, not tidiness. `.sheet(item:)` swaps its content in place when the
                // item changes: view identity is unchanged, so `@State` carries over and a plain `.task`
                // never re-runs. That is why tapping a second stop showed the previous stop's departures.
                // A distinct id forces a genuine new identity for both.
                .id(destination.id)
                // …and the presentation modifiers sit *outside* that id, which is the other half of it.
                //
                // Applied inside — as they were, one set per switch branch — they were destroyed and rebuilt
                // along with the content on every stop→stop swap. For the instant the subtree is gone the
                // sheet has no declared detents, so the presentation controller falls back to its default and
                // resolves to `.large`; the rebuilt subtree then re-declares `[280, large]` against a
                // controller already sitting at the top. That is why a second stop opened full-screen while
                // "dismiss, then tap" opened at 280. Out here the modifier keeps its identity across the
                // content swap, so the detent set is never absent and `sheetDetent` alone decides the height.
                .presentationDetents(Self.detents(for: destination), selection: $sheetDetent)
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(Self.backgroundInteraction(for: destination))
        }
    }

    private static func detents(for destination: SheetDestination) -> Set<PresentationDetent> {
        switch destination {
        case .stop: return [stopDetent, .large]
        case .trip: return [.height(90), tripDetent, .large]
        }
    }

    private static func backgroundInteraction(for destination: SheetDestination) -> PresentationBackgroundInteraction {
        switch destination {
        case .stop: return .enabled(upThrough: stopDetent)
        case .trip: return .enabled
        }
    }

    @ViewBuilder
    private func sheetContent(for destination: SheetDestination) -> some View {
        switch destination {
        case .stop(let stop):
            StopSheet(stop: stop, frame: lastFrame, userLocation: locationManager.lastLocation) { tripID in
                tripOriginStop = stop
                showTrip(tripID)
            }
        case .trip(let tripID):
            TripDetailSheet(
                tripID: tripID,
                frame: lastFrame,
                originStop: tripOriginStop,
                userLocation: locationManager.lastLocation,
                detent: $sheetDetent
            ) { stop in
                tripOriginStop = nil
                showStop(stop)
                fly(to: CLLocationCoordinate2D(latitude: stop.lat, longitude: stop.lon), spanDelta: 0.01)
            }
        }
    }

    private var searchBar: some View {
        VStack {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                // "or routes" was a promise the query never kept — `searchStops` matches stop name and code
                // only, so typing a route number returned whatever stops happened to contain those digits.
                TextField("Search stops", text: $searchText)
                    .focused($searchFocused)
                    .submitLabel(.search)
                    // `.task(id:)`, not `.onChange` + a bare `Task`. Every keystroke used to launch an
                    // unstructured, uncancellable query — a `LIKE '%…%'` scan of all 9171 stops, which no
                    // index can serve — and nothing ordered the replies. Typing "gren" quickly could land
                    // "gre"'s results last and leave the wrong list on screen. `.task(id:)` cancels the
                    // previous one, and the debounce means a burst of typing costs one query, not one each.
                    .task(id: searchText) {
                        guard !searchText.isEmpty else {
                            searchResults = []
                            return
                        }
                        guard (try? await Task.sleep(for: .milliseconds(250))) != nil else { return }
                        // Ranked against where you are: of the many stops on a named street, the near one is
                        // the one you meant.
                        let here = locationManager.lastLocation.map { (lat: $0.latitude, lon: $0.longitude) }
                        let hits = (try? await store.searchStops(matching: searchText, near: here)) ?? []
                        guard !Task.isCancelled else { return }
                        searchResults = hits
                    }
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        searchResults = []
                        searchFocused = false
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
            .padding(.horizontal)

            // A `List` here brought its own inset grouped background, separators and row insets, none of
            // which match the glass capsule above it — it read as a chunk of Settings dropped on the map.
            // A plain scroll of rows takes the same glass treatment as the search bar.
            if !searchResults.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(searchResults.enumerated()), id: \.element.id) { index, stop in
                            Button {
                                searchFocused = false
                                showStop(stop)
                                fly(to: CLLocationCoordinate2D(latitude: stop.lat, longitude: stop.lon), spanDelta: 0.01)
                                searchText = ""
                                searchResults = []
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "mappin.circle.fill")
                                        .foregroundStyle(.tint)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(stop.name).lineLimit(1)
                                        if let code = stop.code, !code.isEmpty {
                                            Text(code).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if index != searchResults.count - 1 {
                                Divider().padding(.leading, 44)
                            }
                        }
                    }
                }
                .scrollDismissesKeyboard(.immediately)
                .frame(maxHeight: 260)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
                .padding(.horizontal)
            }
        }
        .padding(.top, 8)
    }

    private var locateButton: some View {
        Button {
            if let loc = locationManager.lastLocation {
                fly(to: loc, spanDelta: 0.02)
            }
        } label: {
            Image(systemName: "location.fill")
                .padding(14)
        }
        .glassEffect(.regular, in: .circle)
        .padding()
    }

    /// Height first, then content, so both land in the same update — a new stop always opens at 280 even
    /// when the sheet is already up at `.large` from the stop before it.
    private func showStop(_ stop: StopSummary) {
        sheetDetent = Self.stopDetent
        presented = .stop(stop)
    }

    private func showTrip(_ tripID: String) {
        sheetDetent = Self.tripDetent
        presented = .trip(tripID: tripID)
    }

    private func fly(to coordinate: CLLocationCoordinate2D, spanDelta: Double) {
        flyTo = FlyToCommand(region: MKCoordinateRegion(
            center: coordinate, span: MKCoordinateSpan(latitudeDelta: spanDelta, longitudeDelta: spanDelta)
        ))
    }

    /// Route stops + shape for the open trip, so the map declutters to that route and can draw its polyline.
    private func loadTripContext() async {
        guard let tripID = selectedTripID else {
            tripStopTimes = []
            tripShapePoints = []
            tripRouteID = nil
            tripRouteLines = nil
            tripGhostVehicle = nil
            stopsVersion &+= 1
            rebuildShownVehicles() // closing a trip widens the map back to every bus in the viewport
            return
        }
        let info = try? await store.tripInfo(tripID: tripID)
        tripRouteColor = Theme.routeColor(info?.color, seed: info?.shortName ?? "")
        tripRouteID = info?.routeID
        tripShapePoints = (try? await store.shape(tripID: tripID)) ?? []
        tripStopTimes = (try? await store.allStopTimes(tripID: tripID)) ?? []
        stopsVersion &+= 1
        rebuildShownVehicles() // opening a trip narrows the map to that one bus
        rebuildTripRouteLines()
        rebuildTripGhost()
    }

    /// Grid cell size for the current zoom, quantised to powers of two.
    ///
    /// Quantising matters as much as the grid itself: a continuously-varying cell size would re-tier on
    /// every pinch frame, changing which stop each cell selects and churning annotations throughout the
    /// gesture. Snapping to octaves means a zoom crosses a tier boundary occasionally, not constantly.
    ///
    /// Up, never to nearest: nearest could land a cell at 0.7× the target, doubling the stops per area and
    /// taking the on-screen peak to 358 at 24 across. Up holds it at 229 against the real feed.
    private func gridCell(for span: Double) -> Double {
        // Close in, the whole viewport holds only a few dozen stops, so show every one — thinning here
        // would drop the second stop of an opposite-sides-of-the-road pair, which is exactly the pair
        // you're choosing between at this zoom.
        guard span >= Self.thinningThresholdSpan else { return 0 }
        let target = span / Double(Self.stopsAcrossViewport)
        guard target > 0 else { return 0 }
        return pow(2, log2(target).rounded(.up))
    }

    /// Fetches a box padded well beyond the viewport and reuses it until you pan outside it or change zoom
    /// tier, so a normal drag costs zero queries and zero annotation churn.
    private func loadStops(in region: MKCoordinateRegion) async {
        guard region.span.latitudeDelta < 1.2 else {
            // Bump the version, or the clear never reaches the map: `applyStops` is gated on it, so zooming
            // out past the cutoff emptied the array while leaving every annotation on screen.
            if !stops.isEmpty {
                stops = []
                stopsVersion &+= 1
            }
            loadedStopBox = nil
            return
        }
        let minLat = region.center.latitude - region.span.latitudeDelta / 2
        let maxLat = region.center.latitude + region.span.latitudeDelta / 2
        let minLon = region.center.longitude - region.span.longitudeDelta / 2
        let maxLon = region.center.longitude + region.span.longitudeDelta / 2
        let cell = gridCell(for: region.span.latitudeDelta)

        if let box = loadedStopBox, cell == loadedCell,
           minLat >= box.minLat, maxLat <= box.maxLat,
           minLon >= box.minLon, maxLon <= box.maxLon {
            return
        }

        let padLat = region.span.latitudeDelta * 0.35
        let padLon = region.span.longitudeDelta * 0.35
        let box = (minLat: minLat - padLat, maxLat: maxLat + padLat,
                   minLon: minLon - padLon, maxLon: maxLon + padLon)
        guard let fetched = try? await store.stopsIn(
            minLat: box.minLat, maxLat: box.maxLat, minLon: box.minLon, maxLon: box.maxLon,
            cell: cell, limit: Self.stopFetchLimit
        ) else { return }

        // Identical result — keep the existing annotations rather than bumping the version and
        // making the map tear them all down and rebuild them for no visible change.
        guard fetched.count != stops.count || Set(fetched.map(\.id)) != Set(stops.map(\.id)) else {
            loadedStopBox = box
            loadedCell = cell
            return
        }
        stops = fetched
        stopsVersion &+= 1
        loadedStopBox = fetched.count < Self.stopFetchLimit ? box : nil
        loadedCell = cell
    }

    private func loadFavourites() async {
        let favs = (try? await store.favourites()) ?? []
        favouriteStopIDs = Set(favs.map(\.stopID))
        favouriteStops = favs.map {
            StopSummary(id: $0.stopID, code: nil, name: $0.stopName, lat: $0.lat, lon: $0.lon)
        }
        stopsVersion &+= 1
    }
}

struct DataAgeBadge: View {
    let timestamp: Date

    var body: some View {
        // TimelineView instead of a Combine timer: it stops firing when the view is offscreen,
        // where the old autoconnected publisher ticked forever in the background.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let age = Int(max(0, context.date.timeIntervalSince(timestamp)))
            Label("\(age)s old", systemImage: age > 60 ? "exclamationmark.triangle.fill" : "dot.radiowaves.left.and.right")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(age > 60 ? Theme.stale : .secondary)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .glassEffect(.regular, in: .capsule)
        }
    }
}
