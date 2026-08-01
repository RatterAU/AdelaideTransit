import SwiftUI

struct SettingsScreen: View {
    @Environment(\.gtfsStore) private var store
    @Environment(\.realtimeEngine) private var engine

    // Realtime
    @AppStorage("refreshSpeedScale") private var refreshSpeedScale: Double = 1.0
    @AppStorage("dataSaverEnabled") private var dataSaverEnabled = false
    @AppStorage("staleCutoffSeconds") private var staleCutoff: Double = 90

    // Display
    @AppStorage("use24HourClock") private var use24Hour = false
    @AppStorage("lateThresholdSeconds") private var lateThreshold: Double = 60
    @AppStorage("showGhostsOnMap") private var showGhostsOnMap = true
    @AppStorage("hideRouteBus") private var hideBus = false
    @AppStorage("hideRouteTram") private var hideTram = false
    @AppStorage("hideRouteTrain") private var hideTrain = false
    @AppStorage("mapEmphasis") private var mapEmphasis = "muted"
    @AppStorage("vehicleMarkerScale") private var markerScale: Double = 1.0
    @AppStorage("showAllLiveBuses") private var showAllLiveBuses = true
    @AppStorage("autoCenterOnLaunch") private var autoCenterOnLaunch = true
    @AppStorage("keepScreenAwakeTracking") private var keepScreenAwake = true
    @AppStorage("pastDeparturesWindowMinutes") private var pastWindowMinutes: Double = 30
    @AppStorage("departureWindowHours") private var departureWindowHours: Double = 2
    @AppStorage(FavouriteRoutes.key) private var favouriteRouteIDsRaw = ""
    @State private var allRoutes: [String: (shortName: String, longName: String, color: String?, type: Int)] = [:]

    private typealias RouteEntry = (id: String, shortName: String, longName: String, color: String?)

    private var starredRoutes: [RouteEntry] {
        FavouriteRoutes.decode(favouriteRouteIDsRaw)
            .compactMap { id in
                allRoutes[id].map { (id: id, shortName: $0.shortName, longName: $0.longName, color: $0.color) }
            }
            .sorted { $0.shortName.localizedStandardCompare($1.shortName) == .orderedAscending }
    }

    private func toggleRoute(_ id: String) {
        var ids = FavouriteRoutes.decode(favouriteRouteIDsRaw)
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        favouriteRouteIDsRaw = FavouriteRoutes.encode(ids)
    }

    // Timetable data
    @AppStorage("allowCellularUpdates") private var allowCellularUpdates = false
    @State private var feedETag: String?
    @State private var feedIngestedAt: String?
    @State private var dbSizeBytes: Int = 0
    @State private var isCheckingUpdate = false
    @State private var updateResultMessage: String?

    // App
    @AppStorage("hapticsEnabled") private var hapticsEnabled = true

    var body: some View {
        NavigationStack {
            Form {
                Section("Realtime") {
                    Picker("Refresh interval", selection: $refreshSpeedScale) {
                        Text("Fast").tag(0.5)
                        Text("Normal").tag(1.0)
                        Text("Relaxed").tag(2.0)
                    }
                    Toggle("Data Saver", isOn: $dataSaverEnabled)
                    Text("Doubles polling intervals. Auto-enables under iOS Low Data Mode regardless of this toggle.")
                        .font(.caption).foregroundStyle(.secondary)
                    VStack(alignment: .leading) {
                        Text("Stale cutoff — \(Int(staleCutoff))s")
                        Slider(value: $staleCutoff, in: 30...180, step: 15)
                    }
                }
                .onChange(of: refreshSpeedScale) { _, v in Task { await engine.setSpeedScale(v) } }
                .onChange(of: dataSaverEnabled) { _, v in Task { await engine.setDataSaver(v) } }

                Section("Display") {
                    // "Countdown" was removed rather than implemented: every departure deliberately shows a
                    // countdown *and* a clock time — one answers "do I need to move", the other "which
                    // service is this" — so the toggle had nothing legitimate to switch off. It was read
                    // by three views and used by none.
                    Toggle("24-hour clock", isOn: $use24Hour)
                    VStack(alignment: .leading) {
                        Text("Late threshold — \(Int(lateThreshold))s")
                        Slider(value: $lateThreshold, in: 30...300, step: 15)
                    }
                    Picker("Show departures up to", selection: $departureWindowHours) {
                        ForEach([1.0, 2.0, 3.0, 4.0, 6.0, 8.0], id: \.self) { hours in
                            Text("\(Int(hours)) hour\(hours == 1 ? "" : "s")").tag(hours)
                        }
                    }
                    Picker("Show past departures up to", selection: $pastWindowMinutes) {
                        Text("15 min").tag(15.0)
                        Text("30 min").tag(30.0)
                        Text("60 min").tag(60.0)
                    }
                    Toggle("Show ghosts on map", isOn: $showGhostsOnMap)
                }

                Section("Favourite routes") {
                    Text("Starred routes are marked wherever they appear in a departure list.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(starredRoutes, id: \.id) { route in
                        HStack {
                            Text(route.shortName)
                                .font(.subheadline).bold()
                                .foregroundStyle(Theme.routeTextColor(route.color))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Theme.routeColor(route.color, seed: route.shortName), in: Capsule())
                            Spacer()
                            Button("Remove", systemImage: "star.slash") { toggleRoute(route.id) }
                                .labelStyle(.iconOnly)
                                .foregroundStyle(.secondary)
                        }
                    }
                    NavigationLink {
                        RoutePickerScreen(routes: allRoutes, selected: $favouriteRouteIDsRaw)
                    } label: {
                        Label("Add a route", systemImage: "plus.circle")
                    }
                }

                Section("Map") {
                    Toggle("Show all live buses", isOn: $showAllLiveBuses)
                    Text("When off, buses still appear once you open a trip from a stop. Only shows vehicles updated in the last 2 minutes either way.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Auto-centre on my location at launch", isOn: $autoCenterOnLaunch)
                    Toggle("Keep screen awake while tracking a bus", isOn: $keepScreenAwake)
                    Toggle("Hide buses", isOn: $hideBus)
                    Toggle("Hide trams", isOn: $hideTram)
                    Toggle("Hide trains", isOn: $hideTrain)
                    Picker("Map style", selection: $mapEmphasis) {
                        Text("Muted").tag("muted")
                        Text("Standard").tag("standard")
                        Text("Hybrid").tag("hybrid")
                    }
                    VStack(alignment: .leading) {
                        Text("Vehicle marker size")
                        Slider(value: $markerScale, in: 0.7...1.6, step: 0.1)
                    }
                }

                Section("Timetable data") {
                    LabeledContent("Feed version", value: feedETag ?? "—")
                    LabeledContent("Last checked", value: feedIngestedAt ?? "—")
                    LabeledContent("Database size", value: ByteCountFormatter.string(fromByteCount: Int64(dbSizeBytes), countStyle: .file))
                    Toggle("Allow cellular timetable updates", isOn: $allowCellularUpdates)
                    Button {
                        Task { await checkForUpdate() }
                    } label: {
                        if isCheckingUpdate { ProgressView() } else { Text("Check for update now") }
                    }
                    .disabled(isCheckingUpdate)
                    if let updateResultMessage {
                        Text(updateResultMessage).font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("App") {
                    Toggle("Haptics", isOn: $hapticsEnabled)
                    NavigationLink("About") {
                        AboutScreen()
                    }
                    Text("Timetable & realtime data © Adelaide Metro / SA Dept for Infrastructure and Transport, CC-BY 4.0")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
        .task { await loadFeedInfo() }
        .task { allRoutes = (try? await store.allRoutes()) ?? [:] }
        .task {
            await engine.setSpeedScale(refreshSpeedScale)
            await engine.setDataSaver(dataSaverEnabled)
            // Nothing on this screen shows realtime data. Without this the engine kept whatever the previous
            // tab asked for, so sitting in Settings went on fetching vehicle_positions every 15s.
            await engine.setDemand(.none)
        }
    }

    private func loadFeedInfo() async {
        guard let info = try? await store.feedInfo() else { return }
        feedETag = info.etag
        feedIngestedAt = info.ingestedAt
        dbSizeBytes = info.dbSizeBytes
    }

    private func checkForUpdate() async {
        isCheckingUpdate = true
        updateResultMessage = nil
        do {
            // Say which of the two things happened. "Up to date." was printed either way, so a check that
            // had just rebuilt the whole timetable reported the same as one that found nothing to do.
            let outcome = try await store.refreshIfNeeded(force: true, allowCellular: true)
            await loadFeedInfo()
            switch outcome {
            case .updated: updateResultMessage = "Timetable updated."
            case .unchanged: updateResultMessage = "Already up to date."
            case .deferred: updateResultMessage = "Couldn't reach the feed. Try again shortly."
            }
        } catch {
            updateResultMessage = "Couldn't check: \(error.localizedDescription)"
        }
        isCheckingUpdate = false
    }
}

/// The whole route list, grouped by mode, with search. Typing a route ID blind into a text field meant you
/// had to already know the answer; this is a picker you can browse.
private struct RoutePickerScreen: View {
    let routes: [String: (shortName: String, longName: String, color: String?, type: Int)]
    @Binding var selected: String

    @State private var query = ""

    private typealias Entry = (id: String, shortName: String, longName: String, color: String?, type: Int)

    private var sections: [(title: String, routes: [Entry])] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let all: [Entry] = routes
            .map { (id: $0.key, shortName: $0.value.shortName, longName: $0.value.longName,
                    color: $0.value.color, type: $0.value.type) }
            .filter {
                trimmed.isEmpty
                    || $0.shortName.localizedCaseInsensitiveContains(trimmed)
                    || $0.longName.localizedCaseInsensitiveContains(trimmed)
            }
            // Natural order, so W90 sorts after W9 and 100 after 99.
            .sorted { $0.shortName.localizedStandardCompare($1.shortName) == .orderedAscending }

        let known: [(type: Int, title: String)] = [(3, "Buses"), (0, "Trams"), (2, "Trains")]
        let grouped = known.map { group in
            (title: group.title, routes: all.filter { $0.type == group.type })
        }
        let knownTypes = Set(known.map(\.type))
        let other = (title: "Other", routes: all.filter { !knownTypes.contains($0.type) })
        return (grouped + [other]).filter { !$0.routes.isEmpty }
    }

    var body: some View {
        List {
            ForEach(sections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.routes, id: \.id) { route in
                        Button { toggle(route.id) } label: { row(route) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Route number or name")
        .navigationTitle("Favourite routes")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ route: Entry) -> some View {
        let isSelected = FavouriteRoutes.decode(selected).contains(route.id)
        return HStack(spacing: 10) {
            Text(route.shortName)
                .font(.subheadline).bold()
                .foregroundStyle(Theme.routeTextColor(route.color))
                .frame(minWidth: 44)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Theme.routeColor(route.color, seed: route.shortName), in: Capsule())
            Text(route.longName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Image(systemName: isSelected ? "star.fill" : "star")
                .foregroundStyle(isSelected ? .yellow : .secondary)
        }
        .contentShape(Rectangle())
    }

    private func toggle(_ id: String) {
        var ids = FavouriteRoutes.decode(selected)
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        selected = FavouriteRoutes.encode(ids)
    }
}

private struct AboutScreen: View {
    var body: some View {
        List {
            Text("Adelaide Transit is a personal, single-user app: no accounts, no analytics, no backend. All timetable and realtime data comes directly from Adelaide Metro's public GTFS feeds.")
                .font(.footnote)
        }
        .navigationTitle("About")
    }
}
