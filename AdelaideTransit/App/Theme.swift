import SwiftUI

enum Theme {
    /// Deterministic stand-ins for routes the feed publishes no `route_color` for. Every such route used to
    /// fall back to `.accentColor`, so a stop served entirely by colourless routes rendered as a column of
    /// identical blue capsules — the single biggest reason a departure list read as flat. Seeded by route
    /// name, so a given route is always the same colour. Chosen dark enough for white text.
    private static let fallbackPalette: [Color] = [
        Color(red: 0.18, green: 0.38, blue: 0.72), Color(red: 0.72, green: 0.24, blue: 0.24),
        Color(red: 0.15, green: 0.48, blue: 0.36), Color(red: 0.52, green: 0.28, blue: 0.62),
        Color(red: 0.78, green: 0.44, blue: 0.10), Color(red: 0.14, green: 0.44, blue: 0.56),
        Color(red: 0.60, green: 0.20, blue: 0.44), Color(red: 0.36, green: 0.42, blue: 0.20),
    ]

    private static func rgb(_ hex: String?) -> (r: Double, g: Double, b: Double)? {
        guard let hex, hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    static func routeColor(_ hex: String?, seed: String = "") -> Color {
        if let c = rgb(hex) { return Color(red: c.r, green: c.g, blue: c.b) }
        guard !seed.isEmpty else { return .accentColor }
        // Sum of scalars, not `hashValue` — Swift's hash is seeded per launch, so the palette would
        // reshuffle on every app start.
        let index = seed.unicodeScalars.reduce(0) { ($0 &+ Int($1.value)) } % fallbackPalette.count
        return fallbackPalette[index]
    }

    /// White text on a light route colour is invisible, and Adelaide publishes plenty of pale ones — that
    /// washed-out badge is a large part of why some stops' lists looked dull and others didn't.
    /// Rec. 601 luma, which tracks perceived brightness closely enough for a two-way choice.
    static func routeTextColor(_ hex: String?) -> Color {
        guard let c = rgb(hex) else { return .white }   // palette fallbacks are all dark
        return (0.299 * c.r + 0.587 * c.g + 0.114 * c.b) > 0.62 ? .black : .white
    }

    static let live = Color.green
    static let stale = Color.orange
    static let ghost = Color.gray
    static let cancelled = Color.red
}

/// A value-type format style rather than a cached `DateFormatter`: Sendable, cheap to construct, and it
/// avoids the usual static-formatter dance in a struct that re-renders on every realtime frame.
func clockStyle(use24Hour: Bool) -> Date.FormatStyle {
    let base = Date.FormatStyle(timeZone: AdelaideTZ.timeZone)
    return use24Hour
        ? base.hour(.twoDigits(amPM: .omitted)).minute()
        : base.hour(.defaultDigits(amPM: .abbreviated)).minute()
}

/// "in 4 min" / "now" / "2 min ago". Paired with a clock time everywhere it appears: the countdown answers
/// "do I need to move", the clock time answers "which service is this". Either alone leaves half the question.
func countdownText(to date: Date, now: Date = .now) -> String {
    let seconds = date.timeIntervalSince(now)
    let minutes = Int(seconds / 60)
    if seconds < -60 { return "\(-minutes) min ago" }
    if seconds < 30 { return "now" }
    if minutes < 60 { return "\(max(minutes, 1)) min" }
    let hours = minutes / 60
    let remainder = minutes % 60
    return remainder == 0 ? "\(hours) hr" : "\(hours) hr \(remainder) min"
}

/// Starred routes are a flat list of route IDs in UserDefaults, not a table: there is no relational
/// question to ask of them, only "is this one starred", and every view that needs the answer already has
/// `@AppStorage`.
enum FavouriteRoutes {
    static let key = "favouriteRouteIDs"
    static func decode(_ raw: String) -> Set<String> {
        Set(raw.split(separator: ",").map(String.init))
    }
    static func encode(_ ids: Set<String>) -> String { ids.sorted().joined(separator: ",") }
}

/// Which alerts you've already looked at. The badge counted *active* alerts, so it sat there permanently
/// on a long-running roadworks notice and stopped meaning "something new". Stored as IDs, not a count or a
/// timestamp: alerts come and go out of order, and an alert that ends and returns is new again.
///
/// Pruned to the currently-active set on every write, so this can't grow forever.
enum SeenAlerts {
    static let key = "seenAlertIDs"

    static func decode(_ raw: String) -> Set<String> {
        Set(raw.split(separator: "\u{1}").map(String.init))
    }

    static func encode(_ ids: Set<String>) -> String { ids.sorted().joined(separator: "\u{1}") }

    /// Mark everything currently on screen as seen, dropping IDs no longer in the feed.
    static func markSeen(_ active: Set<String>) -> String { encode(active) }
}

/// Alerts that mean a stop isn't usable, as opposed to "expect delays". These are the ones worth putting in
/// front of you on a favourite before you walk there.
func isClosure(_ alert: ServiceAlert) -> Bool {
    switch alert.effect {
    case .noService, .stopMoved, .detour, .significantDelays: return true
    default: return false
    }
}

/// "2 stops away" — how far the bus actually is, which is what you want when a countdown says "4 min" and
/// you can see traffic. `nil` once it's beyond the point where counting stops means anything.
func stopsAwayText(_ stops: Int) -> String? {
    switch stops {
    case ..<0: return nil
    case 0: return "at this stop"
    case 1: return "1 stop away"
    case ...8: return "\(stops) stops away"
    default: return nil
    }
}

enum WalkVerdict: Equatable {
    /// Say nothing. Either you have time, or walking there was never the plan.
    case comfortable
    case tight(walkMinutes: Int)
    case missed(walkMinutes: Int)
}

/// Whether the walk to this stop is worth warning about.
///
/// The old rule was "departs sooner than the walk takes", full stop — so a stop a 150-minute walk away
/// labelled every departure in the next two and a half hours "Tight — 150 min walk". A walk that long was
/// never under consideration; you're looking at that stop to see when buses run, not to sprint for one.
/// The warning only carries information when walking there was plausible to begin with.
func walkVerdict(walkSeconds: TimeInterval, secondsUntilDeparture: TimeInterval) -> WalkVerdict {
    let walkMinutes = max(1, Int((walkSeconds / 60).rounded()))
    // You're at the stop. Under ~90s (~120 m) there's nothing to warn about — GPS puts you on top of it, and
    // "Tight — 1 min walk" while standing 5 m away is the warning firing at the one time it's meaningless.
    guard walkSeconds > 90 else { return .comfortable }
    // Beyond this the stop isn't a "leave now and make it" proposition at any departure time.
    guard walkSeconds <= 25 * 60 else { return .comfortable }
    let slack = secondsUntilDeparture - walkSeconds
    if slack >= 3 * 60 { return .comfortable }
    return slack >= 0 ? .tight(walkMinutes: walkMinutes) : .missed(walkMinutes: walkMinutes)
}

/// "240m" / "1.4km". Shared so the stop sheet and the favourites list can't drift into two spellings.
func distanceText(_ metres: Double) -> String {
    metres < 1000 ? "\(Int(metres.rounded()))m" : String(format: "%.1fkm", metres / 1000)
}

/// How stale a vehicle position is. Seconds while that's the honest unit, minutes once "412s ago" stops
/// being a number anyone reads — which is exactly the range an unstarted trip's bus reports in.
func pingAgeText(_ age: TimeInterval) -> String {
    let seconds = max(0, Int(age))
    return seconds < 90 ? "\(seconds)s ago" : "\(seconds / 60) min ago"
}

/// Shared "N min early/late" phrasing so a delta always reads unambiguously in either direction.
func deltaLabel(_ delta: TimeInterval) -> String {
    let minutes = Int(abs(delta) / 60)
    guard minutes > 0 else { return "on time" }
    return delta > 0 ? "\(minutes) min late" : "\(minutes) min early"
}

func deltaColor(_ delta: TimeInterval) -> Color {
    if abs(delta) < 60 { return .blue }   // on time
    return delta > 0 ? .red : .green      // late : early
}

extension TrackingState {
    var tint: Color {
        switch self {
        case .pending: return .secondary
        case .scheduled: return .secondary
        case .live: return Theme.live
        case .stale: return Theme.stale
        case .ghost: return Theme.ghost
        case .cancelled: return Theme.cancelled
        }
    }

    var glyph: String {
        switch self {
        case .pending: return "ellipsis"
        case .scheduled: return "clock"
        case .live: return "circle.fill"
        case .stale: return "circle.dotted"
        case .ghost: return "questionmark.circle"
        case .cancelled: return "xmark.circle.fill"
        }
    }

    var label: String {
        switch self {
        case .pending: return "Checking live times"
        case .scheduled: return "Scheduled"
        case .live: return "LIVE"
        case .stale(let secondsAgo): return "Last seen \(pingAgeText(TimeInterval(secondsAgo)))"
        case .ghost: return "Not tracking"
        case .cancelled: return "Cancelled"
        }
    }
}

extension Occupancy {
    var label: String {
        switch self {
        case .empty: return "Empty"
        case .manySeatsAvailable: return "Many seats"
        case .fewSeatsAvailable: return "Few seats"
        case .standingRoomOnly: return "Standing room"
        case .crushedStandingRoomOnly: return "Very crowded"
        case .full: return "Full"
        case .notAcceptingPassengers, .notBoardable: return "Not boarding"
        case .noDataAvailable: return "No crowding data"
        }
    }

    /// Filled people for how full it is — readable at caption size without the label.
    var glyph: String {
        switch self {
        case .empty, .manySeatsAvailable: return "person"
        case .fewSeatsAvailable: return "person.2"
        case .standingRoomOnly, .crushedStandingRoomOnly: return "person.3"
        case .full, .notAcceptingPassengers, .notBoardable, .noDataAvailable: return "person.3.fill"
        }
    }

    var tint: Color {
        switch self {
        case .empty, .manySeatsAvailable: return .green
        case .fewSeatsAvailable: return .orange
        case .standingRoomOnly, .crushedStandingRoomOnly, .full, .notAcceptingPassengers, .notBoardable: return .red
        case .noDataAvailable: return .secondary
        }
    }
}
