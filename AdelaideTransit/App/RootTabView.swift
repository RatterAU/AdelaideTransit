import SwiftUI

@MainActor
@Observable
final class Router {
    /// Opens on Favourites (tab 1), not the map. Nearest stop first is the answer to "when's my bus"
    /// without a single tap; the map is what you go to when the answer isn't on that list.
    var selectedTab: Int = 1
    var pendingStop: StopSummary?
    var alertBadgeCount: Int = 0
    /// Alerts that concern you: on a starred route, or at a starred stop. Held here rather than re-derived
    /// per screen so the badge and the favourites banners can't disagree about what's active.
    var relevantAlerts: [ServiceAlert] = []
    var favouriteStopIDs: Set<String> = []

    func openStopOnMap(_ stop: StopSummary) {
        pendingStop = stop
        selectedTab = 0
    }
}

struct RootTabView: View {
    @Environment(\.realtimeEngine) private var engine
    @Environment(\.gtfsStore) private var store
    @State private var router = Router()
    @AppStorage(SeenAlerts.key) private var seenAlertIDsRaw = ""
    /// One location manager for the whole app. The map and the favourites list both need a fix; owning one
    /// each meant two CLLocationManagers running the GPS chip continuously side by side.
    @State private var locationManager = LocationManager()
    @AppStorage(FavouriteRoutes.key) private var favouriteRouteIDsRaw = ""

    var body: some View {
        TabView(selection: $router.selectedTab) {
            Tab("Map", systemImage: "map", value: 0) {
                MapScreen()
            }
            Tab("Favourites", systemImage: "star.fill", value: 1) {
                FavouritesScreen()
            }
            Tab("Alerts", systemImage: "exclamationmark.triangle.fill", value: 2) {
                AlertsScreen()
            }
            .badge(router.alertBadgeCount)
            Tab("Settings", systemImage: "gearshape.fill", value: 3) {
                SettingsScreen()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .environment(router)
        .environment(locationManager)
        .task { locationManager.requestWhenInUse() }
        .task { await loadFavouriteStops() }
        // Badge the Alerts tab whenever something you starred — a route *or* a stop — has an active alert,
        // from anywhere in the app: the engine polls alerts slowly under every foreground screen, so this
        // stays current without the tab open.
        //
        // The count is *unseen* alerts, not active ones. Counting active meant a fortnight of roadworks
        // pinned a red dot to the tab that opening it did nothing about, so the badge stopped carrying
        // information — which is the whole job of a badge.
        .task {
            for await frame in engine.frames {
                let routes = FavouriteRoutes.decode(favouriteRouteIDsRaw)
                let mine = frame.alerts.filter {
                    !$0.informedRouteIDs.isDisjoint(with: routes)
                        || !$0.informedStopIDs.isDisjoint(with: router.favouriteStopIDs)
                }
                router.relevantAlerts = mine
                let seen = SeenAlerts.decode(seenAlertIDsRaw)
                router.alertBadgeCount = mine.count { !seen.contains($0.id) }
            }
        }
        // Favourites change while the app is open; the badge is wrong until the next one lands otherwise.
        .onChange(of: router.selectedTab) { _, _ in Task { await loadFavouriteStops() } }
    }

    private func loadFavouriteStops() async {
        router.favouriteStopIDs = Set(((try? await store.favourites()) ?? []).map(\.stopID))
    }
}
