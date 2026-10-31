import SwiftUI
import CoreLocation

struct FavouriteRow: View {
    let favourite: (id: Int64, stopID: String, stopName: String, routeID: String?, label: String?, group: String?, lat: Double, lon: Double)
    let departures: [Departure]
    /// The tick this row was built on. Passed in so the chips can't be skipped as unchanged — see `DepartureRow`.
    var now: Date = .now
    /// Straight-line metres from you, when a fix is available. Also what the list is ordered by.
    ///
    /// Deliberately not routed: routing is a throttled network request, and this list would fire one per
    /// favourite every time you moved. The routed walk is what you get on tapping through to the stop.
    var distance: CLLocationDistance?
    /// A closure, detour or stop-moved alert naming this stop. Shown on the row itself: a stop you starred
    /// is one you actually walk to, and finding out it's shut from the Alerts tab is finding out too late.
    var alert: ServiceAlert?
    /// So the empty state names the window actually queried rather than a hardcoded 90 minutes.
    var windowHours: Double = 2
    let onTap: () -> Void
    let onRename: (String) -> Void
    @AppStorage(FavouriteRoutes.key) private var favouriteRouteIDsRaw = ""

    private var favouriteRouteIDs: Set<String> { FavouriteRoutes.decode(favouriteRouteIDsRaw) }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(favourite.label ?? favourite.stopName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    if let distance {
                        // Always straight-line here — routing a whole list on every move would hammer the
                        // throttle. Labelled so it isn't mistaken for the routed walk you get on tap-through.
                        Text("\(distanceText(distance)) straight-line")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }

                if let alert {
                    // Amber line, not a greyed row: dimming is reserved for departures that have already
                    // gone, and a shut stop is information you need to read, not skip past.
                    Label(alert.headerText, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.stale)
                        .lineLimit(2)
                }

                if departures.isEmpty {
                    Text("No departures in the next \(windowText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 10) {
                        ForEach(departures.prefix(3)) { dep in
                            HStack(spacing: 4) {
                                Text(dep.routeShortName)
                                    .font(.caption).bold()
                                    .foregroundStyle(Theme.routeTextColor(dep.routeColor))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(
                                        Theme.routeColor(dep.routeColor, seed: dep.routeShortName),
                                        in: Capsule()
                                    )
                                if favouriteRouteIDs.contains(dep.routeID) {
                                    Image(systemName: "star.fill")
                                        .font(.system(size: 7))
                                        .foregroundStyle(.yellow)
                                }
                                Circle()
                                    .fill(dep.state.tint)
                                    .frame(width: 6, height: 6)
                                Text(minutesText(dep))
                                    .font(.caption)
                                    .monospacedDigit()
                            }
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename") {
                renamePrompt = favourite.label ?? favourite.stopName
                showRename = true
            }
        }
        .alert("Rename favourite", isPresented: $showRename) {
            TextField("Label", text: $renamePrompt)
            Button("Save") { onRename(renamePrompt) }
                // An empty label renders as a blank row title.
                .disabled(renamePrompt.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
    }

    @State private var showRename = false
    @State private var renamePrompt = ""

    private var windowText: String {
        windowHours < 1 ? "\(Int(windowHours * 60)) min"
            : windowHours == 1 ? "hour" : "\(Int(windowHours)) hours"
    }

    private func minutesText(_ dep: Departure) -> String {
        // The same cut-offs as `countdownText`: flooring alone read "now" here at 59s while the stop's own
        // list said "1 min" for the same bus.
        let seconds = dep.displayTime.timeIntervalSince(now)
        return seconds < 30 ? "now" : "\(max(1, Int(seconds / 60)))m"
    }
}
