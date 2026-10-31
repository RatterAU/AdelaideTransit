import Foundation
import Testing
@testable import AdelaideTransit

/// `GTFSStore` is the app's only database surface and every screen reads through it, but none of its SQL had
/// a test: a wrong join or an off-by-one window is invisible until a stop looks empty on a phone.
///
/// These drive a real feed archive through the real ingest into a real store in a temp directory — the same
/// path `refreshIfNeeded` takes once the download lands.
@Suite(.serialized)
struct GTFSStoreTests {
    /// The fixture is six stops, so the production floors would (correctly) refuse it. Lowered here and
    /// nowhere else — `aTruncatedFeedIsRefusedAndTheOldDatabaseSurvives` uses the real ones.
    private static let fixtureFloors = GTFSStore.FeedFloors(stops: 1, trips: 1, stopTimes: 1)

    /// A store with the standard fixture already installed, plus its directory for cleanup.
    private func makeStore(
        _ fixture: GTFSFixture = .standard(), meta: GTFSIngest.FeedMetadata = .init(etag: "v1", lastModified: nil)
    ) async throws -> (store: GTFSStore, directory: URL) {
        let directory = try GTFSFixture.makeDirectory()
        let zip = try fixture.write(into: directory)
        let store = GTFSStore(directory: directory)
        try await store.installFeed(fromZipAt: zip, meta: meta, floors: Self.fixtureFloors)
        return (store, directory)
    }

    private func remove(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    /// 09:05 on a Wednesday, well clear of a daylight-saving changeover.
    private var wednesdayMorning: Date {
        AdelaideTZ.calendar.date(from: DateComponents(
            timeZone: AdelaideTZ.timeZone, year: 2025, month: 6, day: 11, hour: 8, minute: 55
        ))!
    }

    // MARK: - Ingest and installation

    @Test func ingestingAFeedMakesTheStoreReady() async throws {
        let (store, directory) = try await makeStore()
        defer { remove(directory) }

        #expect(await store.isReady)
        let routes = try await store.allRoutes()
        #expect(routes.count == 3)
        #expect(routes["R502"]?.shortName == "502")
        // The feed publishes no colour for 502 — that must survive as nil, not as an empty string that
        // `Theme.rgb` would then try to parse.
        #expect(routes["R502"]?.color?.isEmpty ?? true)
        #expect(routes["R110"]?.color == "1A6DBA")
    }

    @Test func feedIdentityIsStoredOnTheVeryFirstIngest() async throws {
        let (store, directory) = try await makeStore(meta: .init(etag: "abc123", lastModified: "Mon, 01 Jan 2025"))
        defer { remove(directory) }

        let info = try await store.feedInfo()
        // Empty identity here is what made every later daily HEAD compare a real ETag against nil and
        // rebuild the whole database, every day, forever.
        #expect(info.etag == "abc123")
        #expect(info.lastModified == "Mon, 01 Jan 2025")
        #expect(info.ingestedAt != nil)
        #expect(info.dbSizeBytes > 0)
    }

    @Test func aTruncatedFeedIsRefusedAndTheOldDatabaseSurvives() async throws {
        let (store, directory) = try await makeStore()
        defer { remove(directory) }

        let badZip = try GTFSFixture.truncated().write(into: directory, named: "bad.zip")
        await #expect(throws: GTFSStore.StagedFeedRejected.self) {
            try await store.installFeed(fromZipAt: badZip, meta: .init(etag: "v2", lastModified: nil))
        }
        // The swap is irreversible, so a rejected feed must leave the previous timetable answering queries.
        #expect(await store.isReady)
        #expect(try await store.allRoutes().count == 3)
        #expect(try await store.feedInfo().etag == "v1")
    }

    /// Calendars are optional at the zip layer, so the row-count floors alone let through a timetable where
    /// no service ever runs — every departure list empty until Adelaide Metro next published.
    @Test func aFeedWithNoServiceCalendarIsRefused() async throws {
        let (store, directory) = try await makeStore()
        defer { remove(directory) }

        var noCalendar = GTFSFixture.standard()
        noCalendar.files["calendar.txt"] = nil
        noCalendar.files["calendar_dates.txt"] = nil
        let zip = try noCalendar.write(into: directory, named: "no-calendar.zip")
        await #expect(throws: GTFSStore.StagedFeedRejected.self) {
            try await store.installFeed(
                fromZipAt: zip, meta: .init(etag: "v2", lastModified: nil), floors: Self.fixtureFloors
            )
        }
        #expect(try await store.feedInfo().etag == "v1")
    }

    /// What a background task's expiry reaches. Throwing, not returning: an abandoned ingest must not go on
    /// to validate and swap in a half-built file.
    @Test func aCancelledIngestThrowsRatherThanFinishing() throws {
        let directory = try GTFSFixture.makeDirectory()
        defer { remove(directory) }

        let zip = try GTFSFixture.standard().write(into: directory)
        #expect(throws: CancellationError.self) {
            try GTFSIngest.ingest(
                zipURL: zip, intoDatabaseAt: directory.appendingPathComponent("staged.sqlite"),
                meta: .init(etag: nil, lastModified: nil), isCancelled: { true }
            )
        }
    }

    /// The whole reason favourites live in their own file.
    @Test func favouritesSurviveAFullTimetableReplacement() async throws {
        let (store, directory) = try await makeStore()
        defer { remove(directory) }

        try await store.addFavourite(stopID: "10001", routeID: nil, label: "Work", group: nil)
        #expect(try await store.favourites().count == 1)

        let zip = try GTFSFixture.standard().write(into: directory, named: "second.zip")
        try await store.installFeed(
            fromZipAt: zip, meta: .init(etag: "v2", lastModified: nil), floors: Self.fixtureFloors
        )

        let favourites = try await store.favourites()
        #expect(favourites.count == 1)
        #expect(favourites.first?.label == "Work")
        #expect(favourites.first?.stopName == "Grenfell St - Stop A1")
    }

    @Test func starringAStopTwiceKeepsOneFavourite() async throws {
        let (store, directory) = try await makeStore()
        defer { remove(directory) }

        try await store.addFavourite(stopID: "10001", routeID: nil, label: "Work", group: nil)
        try await store.addFavourite(stopID: "10001", routeID: nil, label: "Work", group: nil)
        try await store.addFavourite(stopID: "10002", routeID: nil, label: "Home", group: nil)
        #expect(try await store.favourites().map(\.stopID).sorted() == ["10001", "10002"])
    }

    /// Skipped, not deleted: the stop may well come back in the next timetable, and dropping user data
    /// because a feed momentarily disagrees is how favourites vanish for good.
    @Test func aFavouriteMissingFromTheFeedIsHiddenRatherThanDestroyed() async throws {
        let (store, directory) = try await makeStore()
        defer { remove(directory) }

        try await store.addFavourite(stopID: "99999", routeID: nil, label: "Gone", group: nil)
        try await store.addFavourite(stopID: "10001", routeID: nil, label: "Here", group: nil)

        let visible = try await store.favourites()
        #expect(visible.count == 1)
        #expect(visible.first?.label == "Here")
    }

    @Test func favouritesCanBeRenamedAndRemoved() async throws {
        let (store, directory) = try await makeStore()
        defer { remove(directory) }

        try await store.addFavourite(stopID: "10001", routeID: nil, label: "Old", group: "Home")
        let id = try #require(try await store.favourites().first?.id)
        try await store.updateFavouriteLabel(id: id, label: "New")
        #expect(try await store.favourites().first?.label == "New")
        #expect(try await store.favourites().first?.group == "Home")

        try await store.removeFavourite(id: id)
        #expect(try await store.favourites().isEmpty)
    }

    // MARK: - Departures

    @Test func departuresAreBoundedToTheRequestedWindow() async throws {
        let (store, directory) = try await makeStore()
        defer { remove(directory) }

        // 08:55 + 20 min reaches 09:10 but not 09:20 — the SQL range scan owns the boundary, so a stop that
        // falls outside must not come back at all.
        let departures = try await store.departures(
            stopID: "10001", from: wednesdayMorning, window: 20 * 60
        )
        #expect(departures.map(\.tripID) == ["T502"])
        #expect(departures.first?.stopSequence == 2)
        #expect(departures.first?.routeShortName == "502")
        #expect(departures.first?.headsign == "Paradise Interchange")
    }

    @Test func departuresComeBackInTimeOrder() async throws {
        let (store, directory) = try await makeStore()
        defer { remove(directory) }

        let departures = try await store.departures(
            stopID: "10003", from: wednesdayMorning, window: 3 * 3600
        )
        #expect(departures.map(\.tripID) == ["T502", "TDEPOT"])
        #expect(departures[0].scheduledTime < departures[1].scheduledTime)
    }

    /// A "25:10:00" trip is the *previous* service day still running. Querying at 01:00 has to reach back a
    /// day to find it, which is the whole reason `departures` resolves two service days.
    @Test func anAfterMidnightTripBelongsToYesterdaysServiceDay() async throws {
        let (store, directory) = try await makeStore()
        defer { remove(directory) }

        let oneAM = AdelaideTZ.calendar.date(from: DateComponents(
            timeZone: AdelaideTZ.timeZone, year: 2025, month: 6, day: 12, hour: 1, minute: 0
        ))!
        let departures = try await store.departures(stopID: "10001", from: oneAM, window: 30 * 60)
        #expect(departures.map(\.tripID) == ["TLATE"])

        // And it must land at 01:10 wall-clock on the 12th, not 25:10 of some other day.
        let parts = AdelaideTZ.calendar.dateComponents(
            [.year, .month, .day, .hour, .minute], from: try #require(departures.first?.scheduledTime)
        )
        #expect(parts.day == 12 && parts.hour == 1 && parts.minute == 10)
    }

    /// Late in the evening a wide window runs into tomorrow's service day. Only today's and yesterday's were
    /// queried, so at the 8 h setting the first buses of the morning were missing from 20:20 onward.
    @Test func aLateEveningWindowReachesTomorrowsFirstBuses() async throws {
        let (store, directory) = try await makeStore()
        defer { remove(directory) }

        let tenPM = AdelaideTZ.calendar.date(from: DateComponents(
            timeZone: AdelaideTZ.timeZone, year: 2025, month: 6, day: 11, hour: 22, minute: 0
        ))!
        // Reaches 09:30 on the 12th: T502's 09:00 and not TDEPOT's 09:50, so the window still owns the edge.
        let departures = try await store.departures(stopID: "10003", from: tenPM, window: 11.5 * 3600)
        #expect(departures.map(\.tripID) == ["T502"])

        let parts = AdelaideTZ.calendar.dateComponents(
            [.day, .hour], from: try #require(departures.first?.scheduledTime)
        )
        #expect(parts.day == 12 && parts.hour == 9)
    }

    /// `calendar_dates` exception_type 2 removes a service on one date even though `calendar` runs it every
    /// day. Both directions, because a filter that drops everything also passes this test one-sided.
    @Test func aCalendarExceptionSuppressesItsServiceOnThatDayOnly() async throws {
        let (store, directory) = try await makeStore()
        defer { remove(directory) }

        // TSUPPRESSED departs 10001 at 09:05 under HOLIDAY, cancelled on exactly this date.
        let onTheExceptedDay = try await store.departures(
            stopID: "10001", from: wednesdayMorning, window: 30 * 60
        )
        #expect(!onTheExceptedDay.contains { $0.tripID == "TSUPPRESSED" })

        let theNextDay = try await store.departures(
            stopID: "10001",
            from: try #require(AdelaideTZ.calendar.date(byAdding: .day, value: 1, to: wednesdayMorning)),
            window: 30 * 60
        )
        #expect(theNextDay.contains { $0.tripID == "TSUPPRESSED" })
    }

    /// A stop_times row with a blank `arrival_time` used to be dropped outright, taking the departure with it.
    @Test func aBlankArrivalTimeFallsBackToTheDepartureTime() async throws {
        let (store, directory) = try await makeStore()
        defer { remove(directory) }

        let rows = try await store.allStopTimes(tripID: "TSUPPRESSED")
        #expect(rows.count == 1)
        #expect(rows.first?.dep == 9 * 3600 + 5 * 60)
    }

    @Test func departuresBeforeAnyServiceExistsAreEmptyRatherThanAnError() async throws {
        let (store, directory) = try await makeStore()
        defer { remove(directory) }
        #expect(try await store.departures(stopID: "10006", from: wednesdayMorning, window: 60).isEmpty)
    }

    // MARK: - Map queries

    @Test func stopsInABoxAreLimitedToThatBox() async throws {
        let (store, directory) = try await makeStore()
        defer { remove(directory) }

        let city = try await store.stopsIn(
            minLat: -34.930, maxLat: -34.920, minLon: 138.590, maxLon: 138.610
        )
        #expect(Set(city.map(\.id)) == ["10001", "10002", "10003"])
    }

    /// Thinning keeps the *most important* stop per grid cell — the interchange, not whichever row SQLite
    /// happened to reach first.
    @Test func gridThinningKeepsTheBusiestStopInACell() async throws {
        let (store, directory) = try await makeStore()
        defer { remove(directory) }

        // One cell wide enough to hold the whole network.
        let thinned = try await store.stopsIn(
            minLat: -35.0, maxLat: -34.8, minLon: 138.5, maxLon: 138.8, cell: 1.0
        )
        #expect(thinned.count == 1)
        // 10001 is served by both R502 and (via TLATE) R502 again plus RTRAM — two distinct routes, more
        // than any other stop in the fixture.
        #expect(thinned.first?.id == "10001")
    }

    /// The r-tree key is cast back to text to join `stops`, so "0123" can't find itself. It loses its pin, as
    /// a non-numeric id does, and nothing else: the join must not pull it in as stop 123, or lose the stop.
    @Test func aNonCanonicalStopIDLosesOnlyItsMapPin() async throws {
        var fixture = GTFSFixture.standard()
        fixture.files["stops.txt", default: ""] += "010007,X7,Leading Zero,-34.92355,138.60150\n"
        let (store, directory) = try await makeStore(fixture)
        defer { remove(directory) }

        let pins = try await store.stopsIn(minLat: -35, maxLat: -34.8, minLon: 138.5, maxLon: 138.8)
        #expect(!pins.contains { $0.id == "010007" })
        #expect(pins.contains { $0.id == "10001" })
        #expect(try await store.stopSummary(id: "010007")?.name == "Leading Zero")
    }

    /// A `LIMIT` in the SQL ran in storage order, before the ranking, so a common word dropped arbitrary
    /// stops: "main" matches 342 and the nearest could be one of the 42. Stored last here for that reason.
    @Test func searchRanksEveryMatchBeforeCapping() async throws {
        var fixture = GTFSFixture.standard()
        for i in 0..<350 {
            let lat = i == 349 ? -34.9 : -35.5
            fixture.files["stops.txt", default: ""] += "\(20000 + i),M\(i),Main Rd - Stop \(i),\(lat),138.6\n"
        }
        let (store, directory) = try await makeStore(fixture)
        defer { remove(directory) }

        let hits = try await store.searchStops(matching: "main", near: (lat: -34.9, lon: 138.6))
        #expect(hits.first?.id == "20349")
        #expect(hits.count == 30)
    }

    @Test func stopSummaryFindsAStopByID() async throws {
        let (store, directory) = try await makeStore()
        defer { remove(directory) }
        #expect(try await store.stopSummary(id: "10003")?.name == "Currie St - Stop B1")
        #expect(try await store.stopSummary(id: "nope") == nil)
    }

    /// A quoted field containing a comma has to survive the CSV reader intact all the way into a query.
    @Test func searchMatchesTokensInAnyOrderAndKeepsQuotedNames() async throws {
        let (store, directory) = try await makeStore()
        defer { remove(directory) }

        #expect(try await store.searchStops(matching: "grenfell a2").map(\.id) == ["10002"])
        #expect(try await store.searchStops(matching: "a2 grenfell").map(\.id) == ["10002"])
        let paradise = try await store.searchStops(matching: "paradise terminus")
        #expect(paradise.first?.name == "Paradise Interchange, Terminus")
    }

    @Test func searchingByStopCodeReturnsThatStopFirst() async throws {
        let (store, directory) = try await makeStore()
        defer { remove(directory) }
        #expect(try await store.searchStops(matching: "X3").first?.id == "10003")
    }

    @Test func shapeComesBackInSequenceOrder() async throws {
        let (store, directory) = try await makeStore()
        defer { remove(directory) }

        let shape = try await store.shape(tripID: "T502")
        #expect(shape.count == 3)
        #expect(shape.first?.lon == 138.59510)
        #expect(shape.last?.lon == 138.66500)
        // `shape_dist_traveled` is absent from this feed, which is why ghosts anchor by nearest point.
        #expect(shape.allSatisfy { $0.dist == nil })
    }

    @Test func stopTimesComeBackInSequenceOrderWithStopNames() async throws {
        let (store, directory) = try await makeStore()
        defer { remove(directory) }

        let rows = try await store.allStopTimes(tripID: "T502")
        #expect(rows.map(\.seq) == [1, 2, 3])
        #expect(rows.map(\.stopID) == ["10003", "10001", "10004"])
        #expect(rows.first?.name == "Currie St - Stop B1")
    }

    // MARK: - Block continuation

    /// The 502 → 110 case: same block, next trip starts 8 m from where this one ended, 10 minutes later.
    /// Matching by `stop_id` would miss it, because an interchange is many stops.
    @Test func continuationMatchesAHandoverAtANeighbouringBay() async throws {
        let (store, directory) = try await makeStore()
        defer { remove(directory) }

        let onward = try #require(try await store.continuation(after: "T502"))
        #expect(onward.tripID == "T110")
        #expect(onward.shortName == "110")
        #expect(onward.headsign == "City")
        // Different bay, so the first onward stop is where you re-board and must be kept.
        #expect(onward.startsAtSameStop == false)
    }

    /// A block alone is not a continuation — most consecutive pairs start somewhere else entirely.
    @Test func aDepotRunInTheSameBlockIsNotAContinuation() async throws {
        let (store, directory) = try await makeStore()
        defer { remove(directory) }
        #expect(try await store.continuation(after: "TDEPOT") == nil)
    }

    @Test func theLastTripOfABlockHasNoContinuation() async throws {
        let (store, directory) = try await makeStore()
        defer { remove(directory) }
        #expect(try await store.continuation(after: "T110") == nil)
    }

    /// Positions are published against the trip a bus is running *now*, so an unstarted trip finds its
    /// vehicle through the block rather than through its own trip ID.
    @Test func blockmatesLinkTheTripsOneVehicleWorks() async throws {
        let (store, directory) = try await makeStore()
        defer { remove(directory) }

        #expect(try await store.blockmates(of: "T502") == ["T110"])
        #expect(try await store.blockmates(of: "T110") == ["T502"])
        #expect(try await store.blockmates(of: "TLATE").isEmpty)
    }

    /// `block_id` can only come from the feed, and a migration that ran against a failed re-ingest left it
    /// permanently empty — so the store re-arms the ingest instead of staying quietly inert.
    @Test func missingBlockIDsReArmTheNextIngest() async throws {
        let (store, directory) = try await makeStore()
        defer { remove(directory) }

        // Blocks are present here, so the identity must be left alone.
        try await store.rearmIngestIfBlocksMissing()
        #expect(try await store.feedInfo().etag == "v1")
    }

    // MARK: - Stop importance

    @Test func importanceCountsDistinctRoutesAndBackfillIsANoOpWhenAlreadyComputed() async throws {
        let (store, directory) = try await makeStore()
        defer { remove(directory) }

        // Ingest computes it, so the backfill must find nothing to do and leave the values alone.
        try await store.backfillStopImportanceIfNeeded()
        let thinned = try await store.stopsIn(
            minLat: -35.0, maxLat: -34.8, minLon: 138.5, maxLon: 138.8, cell: 1.0
        )
        #expect(thinned.first?.id == "10001")
    }
}

struct RouteTypeTests {
    /// Adelaide's school (712) and regional (701) buses must read as buses, and basic types pass through.
    @Test func extendedRouteTypesFoldOntoBasicOnes() {
        #expect(GTFSStore.baseRouteType(701) == 3)
        #expect(GTFSStore.baseRouteType(712) == 3)
        #expect(GTFSStore.baseRouteType(900) == 0)
        #expect(GTFSStore.baseRouteType(109) == 2)
        for basic in [0, 2, 3, 4] { #expect(GTFSStore.baseRouteType(basic) == basic) }
    }
}
