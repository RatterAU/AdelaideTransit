import Testing
import Foundation
@testable import AdelaideTransit

struct CountdownTests {
    private let now = Date(timeIntervalSince1970: 1_784_530_100)

    @Test func imminentDeparturesReadAsNow() {
        #expect(countdownText(to: now, now: now) == "now")
        #expect(countdownText(to: now.addingTimeInterval(20), now: now) == "now")
    }

    @Test func minutesRoundDownButNeverToZero() {
        #expect(countdownText(to: now.addingTimeInterval(60), now: now) == "1 min")
        #expect(countdownText(to: now.addingTimeInterval(45), now: now) == "1 min")
        #expect(countdownText(to: now.addingTimeInterval(9 * 60), now: now) == "9 min")
    }

    @Test func hoursAreSpelledOutBeyondSixtyMinutes() {
        #expect(countdownText(to: now.addingTimeInterval(60 * 60), now: now) == "1 hr")
        #expect(countdownText(to: now.addingTimeInterval(95 * 60), now: now) == "1 hr 35 min")
    }

    @Test func departedServicesReadAsAgo() {
        #expect(countdownText(to: now.addingTimeInterval(-120), now: now) == "2 min ago")
    }

    /// The boundary that decides "sprint" versus "missed it" — must not read as a future time.
    @Test func justDepartedDoesNotReadAsUpcoming() {
        let text = countdownText(to: now.addingTimeInterval(-30), now: now)
        #expect(text == "now")
    }

    @Test func clockStyleRespectsTwentyFourHourSetting() {
        // 03:30 UTC == 14:00 Adelaide (UTC+10:30)
        let date = Date(timeIntervalSince1970: 1_784_530_800)
        let twentyFour = date.formatted(clockStyle(use24Hour: true))
        let twelve = date.formatted(clockStyle(use24Hour: false))
        #expect(!twentyFour.lowercased().contains("m"))   // no am/pm marker
        #expect(twelve.lowercased().contains("m"))
        #expect(twentyFour.contains(":"))
    }
}

struct RouteAppearanceTests {

    /// White on a pale route colour is invisible. Adelaide publishes plenty of pale ones, which is why some
    /// stops' lists read as washed out and others didn't.
    @Test func badgeTextFlipsToBlackOnLightRouteColours() {
        #expect(Theme.routeTextColor("FFE600") == .black)   // yellow
        #expect(Theme.routeTextColor("FFFFFF") == .black)
        #expect(Theme.routeTextColor("003366") == .white)   // navy
        #expect(Theme.routeTextColor("000000") == .white)
        #expect(Theme.routeTextColor(nil) == .white)        // palette fallbacks are all dark
    }

    /// Routes with no `route_color` used to collapse to a single accent colour, so a stop served entirely by
    /// colourless routes was a column of identical capsules.
    @Test func colourlessRoutesGetDistinctStableColours() {
        let w90 = Theme.routeColor(nil, seed: "W90")
        let h30 = Theme.routeColor(nil, seed: "H30")
        #expect(w90 != h30)
        // Stable across calls — a per-launch hash seed would reshuffle the palette on every app start.
        #expect(Theme.routeColor(nil, seed: "W90") == w90)
        #expect(Theme.routeColor(nil, seed: "") == .accentColor)
        // A real colour always wins over the fallback.
        #expect(Theme.routeColor("003366", seed: "W90") != w90)
    }

    @Test func favouriteRoutesRoundTrip() {
        let encoded = FavouriteRoutes.encode(["W90", "H30"])
        #expect(FavouriteRoutes.decode(encoded) == ["W90", "H30"])
        #expect(FavouriteRoutes.decode("") == [])
    }

    /// The old rule was "departs sooner than the walk takes" and nothing else, so a stop a 150-minute walk
    /// away labelled every departure in the next two and a half hours "Tight — 150 min walk".
    @Test func absurdlyLongWalksAreNeverCalledTight() {
        #expect(walkVerdict(walkSeconds: 150 * 60, secondsUntilDeparture: 2 * 60) == .comfortable)
        #expect(walkVerdict(walkSeconds: 40 * 60, secondsUntilDeparture: 10 * 60) == .comfortable)
    }

    @Test func walkVerdictWarnsOnlyWhenItIsActuallyMarginal() {
        // Plenty of time: silent.
        #expect(walkVerdict(walkSeconds: 5 * 60, secondsUntilDeparture: 20 * 60) == .comfortable)
        // Doable, but you'd want to leave now.
        #expect(walkVerdict(walkSeconds: 5 * 60, secondsUntilDeparture: 6 * 60) == .tight(walkMinutes: 5))
        // Gone.
        #expect(walkVerdict(walkSeconds: 10 * 60, secondsUntilDeparture: 2 * 60) == .missed(walkMinutes: 10))
    }

    @Test func stopsAwayReadsNaturallyAndGivesUpWhenFar() {
        #expect(stopsAwayText(0) == "at this stop")
        #expect(stopsAwayText(1) == "1 stop away")
        #expect(stopsAwayText(4) == "4 stops away")
        // Past your stop, or far enough that counting stops stops meaning anything.
        #expect(stopsAwayText(-2) == nil)
        #expect(stopsAwayText(30) == nil)
    }

    private func alert(_ id: String, routes: Set<String> = [], stops: Set<String> = []) -> ServiceAlert {
        ServiceAlert(
            id: id, headerText: id, descriptionText: "", effect: .unknownEffect,
            severity: .unknownSeverity, informedRouteIDs: routes, informedStopIDs: stops,
            activeFrom: nil, activeTo: nil
        )
    }

    /// Every alert lands in exactly one section, starred route outranking starred stop — the property the
    /// old chain of four re-derived computed properties spent three list scans per render maintaining.
    @Test func alertsSplitIntoExactlyOneSectionEach() {
        let all = [
            alert("route-only", routes: ["W90"]),
            alert("stop-only", stops: ["12345"]),
            alert("both", routes: ["W90"], stops: ["12345"]),
            alert("neither", routes: ["H30"], stops: ["99999"]),
        ]
        let split = splitAlerts(all, favouriteRoutes: ["W90"], favouriteStops: ["12345"])

        #expect(split.route.map(\.id) == ["route-only", "both"])
        #expect(split.stop.map(\.id) == ["stop-only"])
        #expect(split.other.map(\.id) == ["neither"])
        #expect(split.route.count + split.stop.count + split.other.count == all.count)

        // No starred routes at all: the route section empties into the others, nothing is dropped.
        let noRoutes = splitAlerts(all, favouriteRoutes: [], favouriteStops: ["12345"])
        #expect(noRoutes.route.isEmpty)
        #expect(noRoutes.stop.map(\.id) == ["stop-only", "both"])
        #expect(noRoutes.other.map(\.id) == ["route-only", "neither"])
    }
}
