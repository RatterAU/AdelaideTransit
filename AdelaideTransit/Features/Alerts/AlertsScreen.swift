import SwiftUI

/// Which of the three sections each alert belongs to: your starred routes first, then your starred stops,
/// then everything else. Exactly one section per alert — an alert on a starred route *at* a starred stop
/// used to be eligible for both, and the de-duplication that prevented showing it twice was three
/// re-derivations of the same lists.
func splitAlerts(
    _ alerts: [ServiceAlert], favouriteRoutes: Set<String>, favouriteStops: Set<String>
) -> (route: [ServiceAlert], stop: [ServiceAlert], other: [ServiceAlert]) {
    var route: [ServiceAlert] = [], stop: [ServiceAlert] = [], other: [ServiceAlert] = []
    for alert in alerts {
        if !favouriteRoutes.isEmpty, !alert.informedRouteIDs.isDisjoint(with: favouriteRoutes) {
            route.append(alert)
        } else if !alert.informedStopIDs.isDisjoint(with: favouriteStops) {
            stop.append(alert)
        } else {
            other.append(alert)
        }
    }
    return (route, stop, other)
}

struct AlertsScreen: View {
    @Environment(\.gtfsStore) private var store
    @Environment(\.realtimeEngine) private var engine

    @State private var alerts: [ServiceAlert] = []
    @State private var favouriteStopIDs: Set<String> = []
    @State private var routes: [String: (shortName: String, longName: String, color: String?, type: Int)] = [:]
    @State private var modeFilter: Int?
    @State private var expandedID: String?
    @AppStorage(FavouriteRoutes.key) private var favouriteRouteIDsRaw = ""
    @AppStorage(SeenAlerts.key) private var seenAlertIDsRaw = ""
    @Environment(Router.self) private var router

    private var favouriteRoutes: Set<String> { FavouriteRoutes.decode(favouriteRouteIDsRaw) }

    /// Filter and split in one pass. As four chained computed properties `other` re-derived `stopAlerts`,
    /// which re-derived `routeAlerts`, which re-derived the mode filter — so the filter ran six times and
    /// the favourite-route scan three, on every render, for a partition that is one loop.
    private var sections: (route: [ServiceAlert], stop: [ServiceAlert], other: [ServiceAlert]) {
        let visible = modeFilter.map { mode in
            alerts.filter { alert in alert.informedRouteIDs.contains { routes[$0]?.type == mode } }
        } ?? alerts
        return splitAlerts(visible, favouriteRoutes: favouriteRoutes, favouriteStops: favouriteStopIDs)
    }

    var body: some View {
        let (routeAlerts, stopAlerts, other) = sections
        return NavigationStack {
            List {
                Picker("Mode", selection: $modeFilter) {
                    Text("All").tag(Int?.none)
                    Text("Bus").tag(Int?.some(3))
                    Text("Tram").tag(Int?.some(0))
                    Text("Train").tag(Int?.some(2))
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)

                if !routeAlerts.isEmpty {
                    Section("Affecting your favourite routes") {
                        ForEach(routeAlerts) { alert in row(alert) }
                    }
                }
                if !stopAlerts.isEmpty {
                    Section("Affecting your favourite stops") {
                        ForEach(stopAlerts) { alert in row(alert) }
                    }
                }
                let noFavouriteSections = routeAlerts.isEmpty && stopAlerts.isEmpty
                Section(noFavouriteSections ? "Alerts" : "Other alerts") {
                    if other.isEmpty && noFavouriteSections {
                        Text("No active alerts").foregroundStyle(.secondary)
                    }
                    ForEach(other) { alert in row(alert) }
                }
            }
            .navigationTitle("Alerts")
        }
        .task { await engine.setDemand(.alertsTab) }
        .task { await loadFavourites() }
        .task {
            for await frame in engine.frames {
                alerts = frame.alerts
                markSeen()
            }
        }
        .onDisappear { markSeen() }
        .task {
            let loaded = (try? await store.allRoutes()) ?? [:]
            routes = loaded
        }
    }

    private func row(_ alert: ServiceAlert) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                expandedID = expandedID == alert.id ? nil : alert.id
            } label: {
                HStack(alignment: .top) {
                    Image(systemName: severityGlyph(alert.severity))
                        .foregroundStyle(severityColor(alert.severity))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(alert.headerText).font(.subheadline).bold()
                        if let from = alert.activeFrom {
                            Text(from, style: .relative).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .buttonStyle(.plain)

            if expandedID == alert.id, !alert.descriptionText.isEmpty {
                Text(alert.descriptionText).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func severityGlyph(_ severity: TransitRealtime_Alert.SeverityLevel) -> String {
        switch severity {
        case .severe: return "exclamationmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        default: return "info.circle.fill"
        }
    }

    private func severityColor(_ severity: TransitRealtime_Alert.SeverityLevel) -> Color {
        switch severity {
        case .severe: return .red
        case .warning: return .orange
        default: return .blue
        }
    }

    /// Everything currently listed counts as seen — including alerts further down the list, because the tab
    /// is the thing you opened, not the individual row. Rewritten to exactly the active set so stale IDs
    /// don't accumulate in UserDefaults.
    private func markSeen() {
        // Only when it actually changes. This runs on every frame the tab is open, and an unchanged rewrite
        // is still a `UserDefaults` write plus an `@AppStorage` invalidation, which re-renders every view
        // reading the key — including the row list this is called from.
        let raw = SeenAlerts.markSeen(Set(alerts.map(\.id)))
        if raw != seenAlertIDsRaw { seenAlertIDsRaw = raw }
        if router.alertBadgeCount != 0 { router.alertBadgeCount = 0 }
    }

    private func loadFavourites() async {
        let favs = (try? await store.favourites()) ?? []
        favouriteStopIDs = Set(favs.map(\.stopID))
    }
}
