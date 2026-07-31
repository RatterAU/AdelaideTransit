import SwiftUI
import MapKit

struct TripDetailSheet: View {
    @Environment(\.gtfsStore) private var store
    @Environment(\.dismiss) private var dismiss
    let tripID: String
    let frame: RealtimeFrame?
    var originStop: StopSummary? = nil
    var userLocation: CLLocationCoordinate2D? = nil
    /// Owned by the presenting screen, not by this view. The detent modifier has to live outside the
    /// `.id`-keyed content swap to survive it — see `MapScreen`'s `.sheet` — so the switch to `.large` for
    /// map mode reaches up rather than declaring a second, conflicting set of detents down here.
    @Binding var detent: PresentationDetent
    var onSelectStop: (StopSummary) -> Void = { _ in }

    @State private var info: (routeID: String, shortName: String, color: String?, headsign: String, shapeID: String?)?
    @State private var stopTimes: [(seq: Int, stopID: String, name: String, lat: Double, lon: Double, dep: Int)] = []
    @State private var shapePoints: [(lat: Double, lon: Double, dist: Double?)] = []
    @State private var serviceDate: Date?
    @State private var flyTo: MKCoordinateRegion?
    @State private var flyToToken = UUID()
    @State private var showMap = false
    @State private var ghostVehicle: LiveVehicle?
    /// Stop tapped on the mini map, previewed before it opens.
    @State private var previewStop: StopSummary?
    @State private var blockmateIDs: [String] = []
    @State private var routeLines: RouteLines?
    @State private var continuation: (
        tripID: String, routeID: String, shortName: String, color: String?, headsign: String,
        departure: Int, startsAtSameStop: Bool
    )?
    @State private var continuationStopTimes: [(seq: Int, stopID: String, name: String, lat: Double, lon: Double, dep: Int)] = []
    @AppStorage("lateThresholdSeconds") private var lateThreshold: Double = 60
    @AppStorage(FavouriteRoutes.key) private var favouriteRouteIDsRaw = ""

    private var vehicle: LiveVehicle? { frame?.vehicles[tripID] }

    /// The bus that will run this trip, reporting under an earlier trip in the same block.
    ///
    /// Only consulted when this trip has no position of its own — a service that hasn't started yet is
    /// exactly the case where "where is my bus" has an answer the trip ID can't reach. Blocks are sequential
    /// so at most one blockmate is live; newest ping wins if the feed is briefly carrying two.
    private var upstreamVehicle: LiveVehicle? {
        guard vehicle == nil, let frame else { return nil }
        return blockmateIDs.compactMap { frame.vehicles[$0] }.max { $0.timestamp < $1.timestamp }
    }

    /// Whichever position we actually have for this bus, its own or its current run's.
    private var shownVehicle: LiveVehicle? { vehicle ?? upstreamVehicle }
    private var trackingState: TrackingState {
        Merge.trackingState(tripID: tripID, scheduledStart: scheduledStart, frame: frame, now: .now)
    }
    private var scheduledStart: Date? {
        guard let serviceDate, let first = stopTimes.first else { return nil }
        return serviceDate.addingTimeInterval(TimeInterval(first.dep))
    }

    private var routeColor: Color { Theme.routeColor(info?.color, seed: info?.shortName ?? "") }

    /// Only this trip's stops, so the mini map declutters to the route instead of the whole city.
    private var routeStops: [StopSummary] {
        stopTimes.map { StopSummary(id: $0.stopID, code: nil, name: $0.name, lat: $0.lat, lon: $0.lon) }
    }

    private var mergedStops: [Departure] {
        guard let info, let serviceDate else { return [] }
        let departures = stopTimes.map { st in
            Departure(
                tripID: tripID, stopSequence: st.seq, routeID: info.routeID,
                routeShortName: info.shortName, routeColor: info.color, headsign: st.name,
                direction: nil, scheduledTime: serviceDate.addingTimeInterval(TimeInterval(st.dep)),
                liveTime: nil, state: .scheduled
            )
        }
        return Merge.mergeDepartures(departures, tripID: tripID, frame: frame)
    }

    /// The onward leg, merged against its **own** tripID.
    ///
    /// A separate `Merge.mergeDepartures` call, not an extension of this trip's rows: the continuation is a
    /// different trip as far as the feed is concerned, with its own predictions and its own cancellation
    /// state. Appending its stops to `mergedStops` would look up 110's stop sequences in 502's prediction
    /// table and quietly produce wrong times.
    private var continuationStops: [Departure] {
        guard let continuation, let serviceDate, !continuationStopTimes.isEmpty else { return [] }
        let departures = continuationStopTimes.map { st in
            Departure(
                tripID: continuation.tripID, stopSequence: st.seq, routeID: continuation.routeID,
                routeShortName: continuation.shortName, routeColor: continuation.color, headsign: st.name,
                direction: nil, scheduledTime: serviceDate.addingTimeInterval(TimeInterval(st.dep)),
                liveTime: nil, state: .scheduled
            )
        }
        let merged = Merge.mergeDepartures(departures, tripID: continuation.tripID, frame: frame)
        // When the onward trip starts at the very stop this one ended at, showing it twice reads as the bus
        // arriving somewhere it already is. When it starts at a *different* bay of the same interchange —
        // which is most handovers — that first row is where you actually re-board, so it stays.
        return continuation.startsAtSameStop ? Array(merged.dropFirst()) : merged
    }

    /// Stop sequence of the stop you came from, so the list can point at it.
    private var originSequence: Int? {
        guard let originStop else { return nil }
        return stopTimes.first { $0.stopID == originStop.id }?.seq
    }

    /// Next stops onward only — once you're on the bus, where it's been is noise.
    ///
    /// Never trims past the stop you're waiting at, though: cutting the list at the bus's current position
    /// hid your own stop whenever the bus hadn't reached it yet, which is precisely when you're looking.
    private var upcomingStops: [Departure] {
        let cutoff: Int?
        if let busSeq = Merge.busStopSequence(tripID: tripID, frame: frame) {
            cutoff = min(busSeq, originSequence ?? busSeq)
        } else if let originSequence {
            cutoff = originSequence
        } else {
            cutoff = nil
        }
        guard let cutoff else { return mergedStops.filter { $0.displayTime >= Date() } }
        return mergedStops.filter { $0.stopSequence >= cutoff }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if trackingState == .ghost {
                Label("No live tracking for this service — showing schedule", systemImage: "questionmark.circle")
                    .font(.caption)
                    .foregroundStyle(Theme.ghost)
                    .padding(.horizontal)
                    .padding(.bottom, 6)
            }

            Picker("View", selection: $showMap) {
                Label("Stops", systemImage: "list.bullet").tag(false)
                Label("Map", systemImage: "map").tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)

            Divider()

            if showMap {
                miniMap
            } else {
                // Hoisted once per render. As `upcomingStops.first` / `originSequence` inside the row builder
                // they re-ran `Merge.mergeDepartures` over the whole route for every row — O(stops²) merges on
                // each frame. The bus moves once per publish, not once per row.
                let stops = upcomingStops
                let nextSeq = stops.first?.stopSequence
                let yourSeq = originSequence
                let contStops = continuationStops
                ScrollViewReader { proxy in
                    List {
                        ForEach(stops) { dep in
                            Button {
                                if let stop = routeStops.first(where: { $0.id == stopID(for: dep) }) {
                                    onSelectStop(stop)
                                }
                            } label: {
                                stopRow(
                                    dep,
                                    isNext: dep.stopSequence == nextSeq,
                                    isYours: dep.stopSequence == yourSeq
                                )
                            }
                            .buttonStyle(.plain)
                            .id(dep.stopSequence)
                        }

                        // The same bus, a different route number. Without this the list simply stopped at
                        // the handover stop, which read as "this is where the bus terminates" when in fact
                        // it carries straight on — the 502 becoming the 110 at Grenfell St.
                        if let continuation, !contStops.isEmpty {
                            Section {
                                ForEach(contStops) { dep in
                                    stopRow(dep, isNext: false, isYours: false)
                                }
                            } header: {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text("Continues as")
                                        Text(continuation.shortName)
                                            .bold()
                                            .foregroundStyle(Theme.routeTextColor(continuation.color))
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(
                                                Theme.routeColor(continuation.color, seed: continuation.shortName),
                                                in: Capsule()
                                            )
                                        Text("to \(continuation.headsign)")
                                    }
                                    // Same bus, different bay. Saying nothing here would have you sitting at
                                    // the arrival stand watching it leave from the far side of the interchange.
                                    if !continuation.startsAtSameStop, let bay = continuationStopTimes.first?.name {
                                        Label("Departs from \(bay)", systemImage: "figure.walk")
                                    }
                                }
                                .font(.caption)
                                .textCase(nil)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    // Land on your own stop rather than the top of a long route.
                    .onChange(of: originSequence) { _, seq in
                        guard let seq else { return }
                        proxy.scrollTo(seq, anchor: .center)
                    }
                }
            }
        }
        // Keyed on the trip: tapping a bus on the map while this sheet is already open swaps the content in
        // place, and a plain `.task` would leave the previous trip's stops, shape and blockmates on screen.
        .task(id: tripID) { await load() }
        // A new publish is the only thing that moves the bus, or advances a ghost along its shape.
        .onChange(of: frame?.headerTimestamp) { _, _ in rebuildGeometry() }
        // Map mode needs room, and re-framing the bus+you on every switch beats leaving a stale viewport.
        .onChange(of: showMap) { _, isMap in
            previewStop = nil
            guard isMap else { return }
            detent = .large
            frameBusInContext()
        }
    }

    /// No live fix, but the timetable still says where it should be — better than an empty map.
    ///
    /// Memoised, like the map screen already does. As computed properties this and `routeLines` re-ran a
    /// pair of O(shape) nearest-point scans plus an O(shape) split on *every* render of the sheet — shapes
    /// run to thousands of points, and nothing about them changes between realtime frames.
    private func rebuildGeometry() {
        ghostVehicle = interpolatedGhost()
        routeLines = RouteLines.split(
            shape: shapePoints,
            at: vehicle?.coordinate ?? ghostVehicle?.coordinate,
            color: routeColor
        )
    }

    private func interpolatedGhost() -> LiveVehicle? {
        guard vehicle == nil, let info, let serviceDate else { return nil }
        guard let position = Merge.interpolatedPosition(
            shape: shapePoints,
            stopTimes: stopTimes.map { (seq: $0.seq, lat: $0.lat, lon: $0.lon, dep: $0.dep) },
            serviceMidnight: serviceDate,
            now: .now
        ) else { return nil }
        return LiveVehicle(
            tripID: tripID, vehicleLabel: nil, routeID: info.routeID, directionID: nil,
            lat: position.lat, lon: position.lon, bearing: nil, speedMS: nil,
            timestamp: .now, currentStopSequence: nil
        )
    }

    private var miniMap: some View {
        MapViewRepresentable(
            stops: routeStops,
            // Without this the version stays at its default and the stops, which start empty and arrive
            // asynchronously, would never be applied to the map at all.
            stopsVersion: routeStops.count,
            vehicles: shownVehicle.map { [$0] } ?? [],
            // Suppressed once an upstream position is on screen: the interpolated ghost claims the bus is
            // partway along *this* route while the real one is still finishing the last, and drawing both
            // puts the same vehicle in two places.
            ghostVehicles: (upstreamVehicle == nil ? ghostVehicle : nil).map { [$0] } ?? [],
            routes: info.map { [$0.routeID: RouteInfo(shortName: $0.shortName, color: routeColor, type: 0)] } ?? [:],
            userTrackingEnabled: true,
            routeLines: routeLines,
            flyTo: flyTo,
            flyToID: flyTo != nil ? flyToToken : nil,
            mapEmphasis: "muted",
            markerScale: 1.0,
            onRegionChange: { _ in },
            onSelectStop: { stop in onSelectStop(stop) },
            onSelectVehicle: { _ in },
            // Tapping a stop on the route answers "when does *this* bus get here" first; opening the stop is
            // the second tap, on the card.
            onPreviewStop: { stop in withAnimation(.snappy) { previewStop = stop } }
        )
        .overlay(alignment: .bottom) {
            if let previewStop { stopPreviewCard(previewStop) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                HStack {
                    Text(info?.shortName ?? "")
                        .font(.headline).bold()
                        .foregroundStyle(Theme.routeTextColor(info?.color))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(routeColor, in: Capsule())
                    if let routeID = info?.routeID, FavouriteRoutes.decode(favouriteRouteIDsRaw).contains(routeID) {
                        Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow)
                    }
                    Text(info?.headsign ?? "")
                        .font(.headline)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 6) {
                Label(trackingState.label, systemImage: trackingState.glyph)
                    .font(.caption).bold()
                    .foregroundStyle(trackingState.tint)
                // Against your own stop, not the head of the route — "4 stops away" answers the question
                // a countdown can't when you can see the traffic it's sitting in.
                if let busSeq = Merge.busStopSequence(tripID: tripID, frame: frame), let origin = originSequence,
                   let text = stopsAwayText(origin - busSeq) {
                    Text("· \(text)").font(.caption).foregroundStyle(.secondary)
                }
            }

            if let shownVehicle {
                HStack(spacing: 12) {
                    if let label = shownVehicle.vehicleLabel {
                        Label("Vehicle \(label)", systemImage: "bus.fill")
                            .font(.subheadline).bold()
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.thinMaterial, in: Capsule())
                    }
                    Spacer()
                    if let kmh = shownVehicle.speedKMH {
                        Text("\(Int(kmh)) km/h")
                            .font(.subheadline)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(pingAgeText(context.date.timeIntervalSince(shownVehicle.timestamp)))
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                // The position is real but it is not on *this* route yet: without saying so, a marker sitting
                // three suburbs off the line reads as a bug rather than as the bus finishing its last run.
                if upstreamVehicle != nil {
                    Label(
                        "This service hasn't started — showing where its bus last reported on its current run",
                        systemImage: "arrow.turn.up.right"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private func stopRow(_ dep: Departure, isNext: Bool, isYours: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    // Which route serves this stop, on the row itself — on the continuation section it is a
                    // different number from the one in the header, and that is exactly where it matters.
                    Text(dep.routeShortName)
                        .font(.caption2).bold()
                        .foregroundStyle(Theme.routeTextColor(dep.routeColor))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(
                            Theme.routeColor(dep.routeColor, seed: dep.routeShortName), in: Capsule()
                        )
                    Text(dep.headsign)
                        .foregroundStyle(.primary)
                        .fontWeight(isYours ? .semibold : .regular)
                    // The one stop that answers "where is it up to right now".
                    if isNext {
                        Text("NEXT")
                            .font(.caption2).bold()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(routeColor, in: Capsule())
                    }
                    if isYours {
                        Label("YOUR STOP", systemImage: "person.fill")
                            .font(.caption2).bold()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.tint, in: Capsule())
                    }
                }
                HStack(spacing: 4) {
                    Image(systemName: dep.state.glyph).font(.caption2)
                    // Predictions without a GPS fix are realtime but not a sighting — don't call them LIVE.
                    // With no vehicles in the feed at all we aren't polling positions, so we can't claim this
                    // trip lacks one — `shownVehicle` also covers a bus still reporting under its previous trip.
                    Text(dep.state == .live && shownVehicle == nil && !(frame?.vehicles.isEmpty ?? true)
                         ? "Realtime — no GPS" : dep.state.label)
                        .font(.caption2)
                }
                .foregroundStyle(dep.state.tint)
            }
            Spacer()
            // Clock time answers "which service is this"; the countdown answers "do I need to move".
            // Showing one without the other always left half the question open.
            VStack(alignment: .trailing, spacing: 1) {
                Text(countdownText(to: dep.displayTime))
                    .monospacedDigit()
                    .fontWeight(isYours ? .bold : .regular)
                    .foregroundStyle(isYours ? Color.accentColor : .primary)
                    .contentTransition(.numericText())
                Text(dep.displayTime, style: .time)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if let delta = dep.delta, abs(delta) >= lateThreshold {
                    Text(deltaLabel(delta))
                        .font(.caption2)
                        .foregroundStyle(deltaColor(delta))
                }
            }
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }
        .strikethrough(dep.state == .cancelled)
        .contentShape(Rectangle())
        .listRowBackground(isYours ? Color.accentColor.opacity(0.10) : Color.clear)
    }

    /// What this bus does at a stop you tapped on the route: route, stop, when it gets there, how long that
    /// is. Opaque and app-styled on purpose — MapKit's own callout bubble is translucent and unstyleable,
    /// which over a map of coloured lines is barely readable.
    private func stopPreviewCard(_ stop: StopSummary) -> some View {
        let dep = stopTimes.first { $0.stopID == stop.id }
            .flatMap { st in mergedStops.first { $0.stopSequence == st.seq } }
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(info?.shortName ?? "")
                        .font(.caption).bold()
                        .foregroundStyle(Theme.routeTextColor(info?.color))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(routeColor, in: Capsule())
                    Text(stop.name).font(.subheadline).bold().lineLimit(1)
                }
                if let dep {
                    HStack(spacing: 6) {
                        Text(dep.displayTime, style: .time).monospacedDigit()
                        Text("· \(countdownText(to: dep.displayTime))").monospacedDigit()
                        if let delta = dep.delta, abs(delta) >= lateThreshold {
                            Text(deltaLabel(delta)).foregroundStyle(deltaColor(delta))
                        }
                    }
                    .font(.caption)
                } else {
                    // A stop on the shape that this trip doesn't serve — say so rather than showing a blank.
                    Text("Not served by this trip").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary))
        .shadow(radius: 8, y: 2)
        .padding(12)
        .contentShape(Rectangle())
        .onTapGesture {
            previewStop = nil
            onSelectStop(stop)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func stopID(for dep: Departure) -> String {
        stopTimes.first { $0.seq == dep.stopSequence }?.stopID ?? ""
    }

    private func load() async {
        info = try? await store.tripInfo(tripID: tripID)
        stopTimes = (try? await store.allStopTimes(tripID: tripID)) ?? []
        shapePoints = (try? await store.shape(tripID: tripID)) ?? []

        if let firstDep = stopTimes.first?.dep {
            serviceDate = Merge.serviceDate(firstDeparture: firstDep, now: .now)
        }

        blockmateIDs = (try? await store.blockmates(of: tripID)) ?? []
        continuation = try? await store.continuation(after: tripID)
        if let c = continuation {
            continuationStopTimes = (try? await store.allStopTimes(tripID: c.tripID)) ?? []
        } else {
            continuationStopTimes = []
        }

        rebuildGeometry()
        frameBusInContext()
    }

    /// Frame the bus together with whatever gives the most context: your location, else the stop you tapped from.
    private func frameBusInContext() {
        if let busCoord = shownVehicle?.coordinate ?? ghostVehicle?.coordinate {
            if let userLocation {
                flyTo = fitRegion(busCoord, userLocation)
            } else if let originStop {
                flyTo = fitRegion(busCoord, CLLocationCoordinate2D(latitude: originStop.lat, longitude: originStop.lon))
            } else {
                flyTo = MKCoordinateRegion(center: busCoord, span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02))
            }
        } else if let first = routeStops.first {
            flyTo = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: first.lat, longitude: first.lon),
                                        span: MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03))
        }
        flyToToken = UUID()
    }

    private func fitRegion(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> MKCoordinateRegion {
        let minLat = min(a.latitude, b.latitude), maxLat = max(a.latitude, b.latitude)
        let minLon = min(a.longitude, b.longitude), maxLon = max(a.longitude, b.longitude)
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let latDelta = max((maxLat - minLat) * 1.8, 0.012)
        let lonDelta = max((maxLon - minLon) * 1.8, 0.012)
        return MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta))
    }
}
