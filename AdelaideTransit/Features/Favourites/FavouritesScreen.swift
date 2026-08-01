import SwiftUI
import CoreLocation

struct FavouritesScreen: View {
    @Environment(\.gtfsStore) private var store
    @Environment(\.realtimeEngine) private var engine
    @Environment(Router.self) private var router

    typealias Favourite = (id: Int64, stopID: String, stopName: String, routeID: String?, label: String?, group: String?, lat: Double, lon: Double)

    @State private var favourites: [Favourite] = []
    @Environment(LocationManager.self) private var locationManager
    @State private var departuresByStop: [String: [Departure]] = [:]
    @State private var lastFrame: RealtimeFrame?
    @State private var departuresLoadedAt: Date = .distantPast
    /// The same window the stop sheet uses. This screen used the store's 90-minute default and said so in
    /// fixed text, so widening the window in Settings changed one screen and not the other.
    @AppStorage("departureWindowHours") private var departureWindowHours: Double = 2
    /// The schedule query itself is cheap; re-running it on every 15s frame is not, and the timetable a
    /// query behind is at most a few minutes of tail rows.
    private static let scheduleReloadInterval: TimeInterval = 5 * 60

    /// Nearest first. This is a live read of `locationManager.lastLocation`, which is `@Observable`, so the
    /// order re-resolves whenever a fix lands — including every time you come back to this tab — without a
    /// reload or a stored sort order to go stale.
    ///
    /// Falls back to the manual `sort` column when there's no fix yet, so the list is never arbitrary.
    private func grouped(by distances: [Int64: CLLocationDistance]) -> [(key: String, items: [Favourite])] {
        let groups = Dictionary(grouping: favourites) { $0.group ?? "Favourites" }
        return groups.keys.sorted().map { key in
            let items = groups[key] ?? []
            guard !distances.isEmpty else { return (key: key, items: items) }
            return (key: key, items: items.sorted {
                (distances[$0.id] ?? .greatestFiniteMagnitude) < (distances[$1.id] ?? .greatestFiniteMagnitude)
            })
        }
    }

    /// One pass, one `CLLocation` per favourite. Computed inside the sort comparator it allocated two per
    /// comparison — O(n log n) of them per render — and every row then asked for its own again.
    private var distanceByID: [Int64: CLLocationDistance] {
        guard let here = locationManager.lastLocation else { return [:] }
        let origin = CLLocation(latitude: here.latitude, longitude: here.longitude)
        return favourites.reduce(into: [:]) { acc, fav in
            acc[fav.id] = origin.distance(from: CLLocation(latitude: fav.lat, longitude: fav.lon))
        }
    }

    var body: some View {
        let distances = distanceByID
        return NavigationStack {
            Group {
                if favourites.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(grouped(by: distances), id: \.key) { section in
                            Section(section.key) {
                                ForEach(section.items, id: \.id) { fav in
                                    FavouriteRow(
                                        favourite: fav,
                                        departures: mergedDepartures(for: fav),
                                        distance: distances[fav.id],
                                        alert: closure(for: fav),
                                        windowHours: departureWindowHours,
                                        onTap: { openOnMap(fav) },
                                        onRename: { newLabel in Task { await rename(fav, to: newLabel) } }
                                    )
                                    .swipeActions {
                                        Button("Delete", role: .destructive) {
                                            Task { await delete(fav) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Favourites")
        }
        .task { await engine.setDemand(.favourites) }
        .task { await load() }
        .task {
            for await frame in engine.frames {
                lastFrame = frame
                if Date.now.timeIntervalSince(departuresLoadedAt) > Self.scheduleReloadInterval {
                    await load()
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "star").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("No favourites yet")
            Button("Find stops on the map") { router.selectedTab = 0 }
                .buttonStyle(.bordered)
        }
    }

    private func mergedDepartures(for fav: Favourite) -> [Departure] {
        let rows = departuresByStop[fav.stopID] ?? []
        let filtered = fav.routeID == nil ? rows : rows.filter { $0.routeID == fav.routeID }
        // Drop what has already gone. The rows are fetched once and merged against every frame, so without
        // this a favourite kept showing the three buses it was showing five minutes ago — and `minutesText`
        // clamps a negative countdown to "now", so they read as three buses about to leave.
        // No grace period: `StopSheet.split` boundaries on `now` exactly, and a minute of slack here meant the
        // preview's first row was a bus the stop's own list filed under "earlier departures".
        let cutoff = Date.now
        return Dictionary(grouping: filtered, by: \.tripID)
            .flatMap { tripID, group in Merge.mergeDepartures(group, tripID: tripID, frame: lastFrame) }
            .filter { $0.displayTime >= cutoff }
            .sorted { $0.displayTime < $1.displayTime }
    }

    /// The closure alert for this stop, if any. Read off `router.relevantAlerts`, which the app already
    /// keeps current for the tab badge — polling or filtering alerts a second time here would be a second
    /// answer to the same question, free to drift from the first.
    private func closure(for fav: Favourite) -> ServiceAlert? {
        router.relevantAlerts.first { isClosure($0) && $0.informedStopIDs.contains(fav.stopID) }
    }

    private func openOnMap(_ fav: Favourite) {
        Task {
            if let stop = try? await store.stopSummary(id: fav.stopID) {
                router.openStopOnMap(stop)
            }
        }
    }

    /// Rebuilt wholesale rather than filled in for missing keys only. The old version loaded each stop once
    /// and never again: leave the tab open and the 90-minute window slides past every row it fetched, so the
    /// list decays to "No departures in the next 90 min" and never recovers. It also kept feeding merged
    /// rows for favourites you'd deleted.
    private func load() async {
        favourites = ((try? await store.favourites()) ?? [])
        var fresh: [String: [Departure]] = [:]
        for stopID in Set(favourites.map(\.stopID)) {
            fresh[stopID] = (try? await store.departures(
                stopID: stopID, from: Date(), window: departureWindowHours * 3600
            )) ?? []
        }
        departuresByStop = fresh
        departuresLoadedAt = .now
    }

    private func rename(_ fav: Favourite, to label: String) async {
        try? await store.updateFavouriteLabel(id: fav.id, label: label)
        await load()
    }

    private func delete(_ fav: Favourite) async {
        try? await store.removeFavourite(id: fav.id)
        await load()
    }

    // Drag-to-reorder was removed with the Edit button: the list now orders by distance from you, so a
    // manual order would be overwritten on the next location fix. The stored `sort` column still backs the
    // fallback ordering used before a fix arrives.
}
