import SwiftUI
import CoreLocation
import MapKit

struct StopSheet: View {
    @Environment(\.gtfsStore) private var store
    let stop: StopSummary
    let frame: RealtimeFrame?
    var userLocation: CLLocationCoordinate2D?
    let onSelectTrip: (String) -> Void

    @State private var departures: [Departure] = []
    @State private var favouriteID: Int64?
    @State private var showPast = false
    @State private var routedWalk: WalkingEstimator.Walk?
    @State private var departuresLoadedAt: Date = .distantPast
    /// Same interval the favourites list reloads on: the schedule query is cheap, re-running it on every 15s
    /// frame is not, and a query this old is a few tail rows behind at worst.
    private static let scheduleReloadInterval: TimeInterval = 5 * 60
    @AppStorage("pastDeparturesWindowMinutes") private var pastWindowMinutes: Double = 30
    @AppStorage("departureWindowHours") private var departureWindowHours: Double = 2
    @AppStorage("hapticsEnabled") private var haptics = true

    /// Merged and split in one pass. As three separate computed properties the whole group-merge-sort ran
    /// three times per render — once for the list and once for each of `upcoming` and `past`.
    private var split: (upcoming: [Departure], past: [Departure]) {
        let merged = Dictionary(grouping: departures, by: \.tripID)
            .flatMap { tripID, rows in Merge.mergeDepartures(rows, tripID: tripID, frame: frame) }
            .sorted { $0.displayTime < $1.displayTime }
        // Already sorted by time, so the first future departure is the split point.
        let now = Date()
        let boundary = merged.firstIndex { $0.displayTime >= now } ?? merged.endIndex
        return (Array(merged[boundary...]), Array(merged[..<boundary]))
    }

    var body: some View {
        let (upcoming, past) = split
        return VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            List {
                if !past.isEmpty {
                    Button {
                        withAnimation(.snappy) { showPast.toggle() }
                    } label: {
                        Label(
                            showPast ? "Hide earlier departures" : "Show departures from the last \(Int(pastWindowMinutes)) min",
                            systemImage: showPast ? "chevron.up" : "chevron.down"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    if showPast {
                        ForEach(past) { dep in
                            Button { onSelectTrip(dep.tripID) } label: {
                                DepartureRow(
                                    departure: dep, isPast: true, walkSeconds: nil,
                                    vehicleLabel: vehicleLabel(for: dep),
                                    hasVehicle: hasVehicle(for: dep)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                ForEach(upcoming) { dep in
                    Button { onSelectTrip(dep.tripID) } label: {
                        DepartureRow(
                            departure: dep, isPast: false,
                            walkSeconds: walkSeconds, stopsAway: stopsAway(for: dep),
                            vehicleLabel: vehicleLabel(for: dep),
                            hasVehicle: hasVehicle(for: dep)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
        }
        // Keyed on the stop. `.sheet(item:)` swaps content in place without changing view identity, so a
        // plain `.task` did not re-run when you tapped a second stop — the new stop's sheet was listing the
        // previous stop's departures until something else happened to reload them.
        .task(id: stop.id) { await load() }
        .task(id: walkKey) { await routeWalk() }
        // The rows are fetched once and merged against every frame, so a sheet left open — which this one is
        // built for, background interaction is enabled and you can keep panning the map — watched its window
        // slide off the end of what it had fetched and decayed to an empty list that never recovered.
        .task(id: frame?.headerTimestamp) {
            guard Date.now.timeIntervalSince(departuresLoadedAt) > Self.scheduleReloadInterval else { return }
            await load()
        }
    }

    /// Whether we can say anything at all about GPS for this trip. With *no* vehicles in the whole feed we
    /// aren't polling vehicle_positions — Settings' vehicle toggle turns that poll off, and the Favourites
    /// screen never asks for it — so "no GPS" would be a statement about our own polling, not about the bus.
    /// A fix older than the stale cutoff doesn't count: the map stops drawing the bus at that age, so a row
    /// claiming a position the map isn't showing is the same contradiction in the other direction.
    private func hasVehicle(for departure: Departure) -> Bool {
        guard let frame, !frame.vehicles.isEmpty else { return true }
        guard let vehicle = frame.vehicles[departure.tripID] else { return false }
        return Date.now.timeIntervalSince(vehicle.timestamp) <= GhostCutoffs.staleAfter
    }

    /// Fleet number of the bus running this trip, when it's reporting one.
    private func vehicleLabel(for departure: Departure) -> String? {
        frame?.vehicles[departure.tripID]?.vehicleLabel
    }

    /// How many stops back down the route the bus currently is, from the feed's pruning boundary — this feed
    /// publishes no `current_stop_sequence`, so the smallest still-published stop is the bus's position.
    private func stopsAway(for departure: Departure) -> Int? {
        Merge.stopsAway(for: departure, frame: frame)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(stop.name).font(.headline)
                HStack(spacing: 6) {
                    if let code = stop.code, !code.isEmpty { Text(code) }
                    // "walking" once MapKit has routed the actual path; "straight-line" while it's still the
                    // crow-flies fallback — so the number never silently pretends to be something it isn't.
                    if let walkDistance {
                        Text("• \(distanceText(walkDistance)) \(routedWalk != nil ? "walking" : "straight-line")")
                    }
                    if let walkSeconds {
                        Text("• \(max(1, Int(walkSeconds / 60))) min")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                // Within walking range → hand off to Maps for the actual routed, turn-by-turn path. The
                // in-app figure is an estimate; this is the "show me how to get there" the estimate implies.
                if canWalk {
                    Button {
                        openWalkingDirections()
                    } label: {
                        Label("Walking directions", systemImage: "figure.walk")
                    }
                    .font(.caption)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.top, 2)
                }
            }
            Spacer()
            Button {
                Task { await toggleFavourite() }
            } label: {
                Image(systemName: favouriteID != nil ? "star.fill" : "star")
                    .foregroundStyle(favouriteID != nil ? .yellow : .secondary)
                    .font(.title3)
            }
            .sensoryFeedback(.success, trigger: favouriteID) { _, _ in haptics }
        }
        .padding()
    }

    /// Routed walking time once MapKit has answered, straight-line over a flat average until then. The
    /// fallback shows instantly and is never wrong by more than the detour; the routed figure accounts for
    /// the river, the rail corridor and the arterial you can't cross.
    /// Nil past the point where a walk stops being a walk. The fallback used to divide *any* distance by a
    /// constant pace, so a stop on the other side of the world — or simply an outer-suburban one you
    /// searched for — printed "160,318 min walk" in the header. Beyond the routing limit there is no
    /// walking answer worth stating, and `walkVerdict` is already silent there.
    private var walkSeconds: TimeInterval? {
        if let routedWalk { return routedWalk.seconds }
        guard let distance, distance <= WalkingEstimator.maxRoutableMetres else { return nil }
        return distance / WalkingEstimator.fallbackMetresPerSecond
    }

    /// Offer directions only when the stop is a plausible walk — same bound the estimate uses.
    private var canWalk: Bool {
        guard let distance else { return false }
        return distance <= WalkingEstimator.maxRoutableMetres
    }

    /// Hand off to Maps for turn-by-turn walking directions from where you are to the stop.
    private func openWalkingDirections() {
        let destination = MKMapItem(
            location: CLLocation(latitude: stop.lat, longitude: stop.lon), address: nil
        )
        destination.name = stop.name
        MKMapItem.openMaps(
            with: [.forCurrentLocation(), destination],
            launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking]
        )
    }

    /// Metres along the route you'd actually walk, straight-line until that lands.
    private var walkDistance: CLLocationDistance? { routedWalk?.metres ?? distance }

    private var distance: CLLocationDistance? {
        guard let userLocation else { return nil }
        return CLLocation(latitude: userLocation.latitude, longitude: userLocation.longitude)
            .distance(from: CLLocation(latitude: stop.lat, longitude: stop.lon))
    }

    /// Re-routes when the stop changes or you've moved ~110 m, not on every location tick.
    private var walkKey: String? {
        guard let userLocation else { return nil }
        return String(format: "%@|%.3f,%.3f", stop.id, userLocation.latitude, userLocation.longitude)
    }

    private func routeWalk() async {
        guard let userLocation else { return }
        if let hit = WalkingEstimator.shared.cached(stopID: stop.id, from: userLocation) {
            routedWalk = hit
            return
        }
        routedWalk = await WalkingEstimator.shared.estimate(
            stopID: stop.id, from: userLocation,
            to: CLLocationCoordinate2D(latitude: stop.lat, longitude: stop.lon)
        )
    }

    private func load() async {
        let pastWindow = pastWindowMinutes * 60
        departures = (try? await store.departures(
            stopID: stop.id,
            from: Date().addingTimeInterval(-pastWindow),
            window: pastWindow + departureWindowHours * 3600
        )) ?? []
        departuresLoadedAt = .now
        favouriteID = (try? await store.favourites())?.first { $0.stopID == stop.id && $0.routeID == nil }?.id
    }

    private func toggleFavourite() async {
        if let id = favouriteID {
            try? await store.removeFavourite(id: id)
            favouriteID = nil
        } else {
            try? await store.addFavourite(stopID: stop.id, routeID: nil, label: stop.name, group: nil)
            favouriteID = (try? await store.favourites())?.first { $0.stopID == stop.id && $0.routeID == nil }?.id
        }
    }
}

struct DepartureRow: View {
    let departure: Departure
    var isPast: Bool = false
    /// Time needed to reach this stop on foot, when the user's location is known.
    var walkSeconds: TimeInterval? = nil
    /// Stops between the bus's last reported position and this one, when it's being tracked.
    var stopsAway: Int? = nil
    /// Fleet number of the bus itself — the one thing that identifies the vehicle rather than the service,
    /// so you can tell which bus you're looking at when two of the same route are due together.
    var vehicleLabel: String? = nil
    /// Whether a GPS position actually exists for this trip. Predicted times alone are realtime, but they are
    /// not a sighting of the bus — calling them "LIVE" next to an empty map is the claim the app can't back.
    var hasVehicle: Bool = false
    @AppStorage("lateThresholdSeconds") private var lateThreshold: Double = 60
    @AppStorage("use24HourClock") private var use24Hour = false
    @AppStorage(FavouriteRoutes.key) private var favouriteRouteIDsRaw = ""

    private var isFavouriteRoute: Bool {
        FavouriteRoutes.decode(favouriteRouteIDsRaw).contains(departure.routeID)
    }

    private var verdict: WalkVerdict {
        guard let walkSeconds, !isPast, departure.state != .cancelled else { return .comfortable }
        return walkVerdict(
            walkSeconds: walkSeconds,
            secondsUntilDeparture: departure.displayTime.timeIntervalSinceNow
        )
    }

    var body: some View {
        HStack {
            Text(departure.routeShortName)
                .font(.subheadline).bold()
                .foregroundStyle(Theme.routeTextColor(departure.routeColor))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(
                    Theme.routeColor(departure.routeColor, seed: departure.routeShortName),
                    in: Capsule()
                )
                .overlay(alignment: .topTrailing) {
                    if isFavouriteRoute {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.yellow)
                            .padding(2)
                            .background(.background, in: Circle())
                            .offset(x: 3, y: -3)
                    }
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(departure.headsign).lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: isPast ? "checkmark.circle" : departure.state.glyph).font(.caption2)
                    Text(isPast ? "Departed" : stateLabel).font(.caption2)
                    if let stopsAway, let text = stopsAwayText(stopsAway), !isPast {
                        Text("· \(text)").font(.caption2)
                    }
                    if let vehicleLabel {
                        Label(vehicleLabel, systemImage: "bus.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(isPast ? .secondary : departure.state.tint)

                // Its own line, and never a dimmer. Fading the whole row meant that at a stop a 12-minute
                // walk away *every departure in the next 12 minutes* — the top of the list, the part you
                // actually read — rendered at 60% opacity. That is what "the list looks dull" was.
                switch verdict {
                case .comfortable:
                    EmptyView()
                case .tight(let minutes):
                    Label("Tight — \(minutes) min walk", systemImage: "figure.walk")
                        .font(.caption2)
                        .foregroundStyle(Theme.stale)
                case .missed(let minutes):
                    Label("\(minutes) min walk — you won't make it", systemImage: "figure.walk")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 1) {
                // Past: how long ago it left, over the actual clock time it left at. Future: countdown over time.
                Text(isPast ? agoText : countdownText(to: departure.displayTime))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(clockText)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if let delta = departure.delta, abs(delta) >= lateThreshold {
                    Text(deltaLabel(delta))
                        .font(.caption2)
                        .foregroundStyle(deltaColor(delta))
                }
            }
        }
        .padding(.vertical, 4)
        .opacity(isPast ? 0.55 : 1)
        .strikethrough(departure.state == .cancelled)
        .animation(.snappy, value: departure.displayTime)
    }

    /// "LIVE" only when there is a GPS fix behind it. A feed prediction with no vehicle *is* realtime — it
    /// just isn't a sighting of the bus, so it says so rather than implying a dot on the map.
    private var stateLabel: String {
        departure.state == .live && !hasVehicle ? "Realtime — no GPS" : departure.state.label
    }

    private var clockText: String { departure.displayTime.formatted(clockStyle(use24Hour: use24Hour)) }

    /// "5 min ago" for a departure that's already left, against its actual departure time.
    private var agoText: String {
        let minutes = Int(Date().timeIntervalSince(departure.displayTime) / 60)
        return minutes <= 0 ? "just now" : "\(minutes) min ago"
    }
}
