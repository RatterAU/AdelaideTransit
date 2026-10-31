import Testing
import Foundation
@testable import AdelaideTransit

/// `Merge` is where schedule and realtime combine — delay propagation, cancellation, service-day rollover.
/// It's pure and deterministic, so it's the one thing in this app worth pinning down with tests.
struct MergeTests {

    private let midnight = Date(timeIntervalSince1970: 1_700_000_000)

    private func departure(seq: Int, offset: TimeInterval, base: Date, stopID: String? = nil) -> Departure {
        Departure(
            tripID: "T1", stopSequence: seq, stopID: stopID ?? "S\(seq)", routeID: "R1", routeShortName: "155",
            routeColor: nil, headsign: "Stop \(seq)", direction: nil,
            scheduledTime: base.addingTimeInterval(offset), liveTime: nil, state: .scheduled
        )
    }

    private func frame(
        predictions: [String: [UInt32: Prediction]] = [:],
        cancelled: Set<String> = [],
        vehicles: [String: LiveVehicle] = [:],
        hasTripUpdates: Bool = true,
        timestamp: Date? = nil
    ) -> RealtimeFrame {
        RealtimeFrame(
            vehicles: vehicles, predictions: predictions, cancelledTripIDs: cancelled,
            alerts: [], headerTimestamp: timestamp, hasTripUpdates: hasTripUpdates
        )
    }

    // MARK: - mergeDepartures

    /// No frame at all means we haven't fetched yet — that must not read as "running to timetable".
    @Test func noFrameIsPendingNotScheduled() {
        let rows = [departure(seq: 1, offset: 0, base: midnight)]
        let merged = Merge.mergeDepartures(rows, tripID: "T1", frame: nil)
        #expect(merged.map(\.state) == [.pending])
    }

    /// Vehicle positions can arrive before trip updates; until the latter lands we know nothing about delays.
    @Test func frameWithoutTripUpdatesIsPending() {
        let rows = (1...2).map { departure(seq: $0, offset: TimeInterval($0 * 60), base: midnight) }
        let merged = Merge.mergeDepartures(rows, tripID: "T1", frame: frame(hasTripUpdates: false))
        #expect(merged.allSatisfy { $0.state == .pending })
    }

    /// Once trip updates have landed, silence about a trip genuinely does mean "to timetable".
    @Test func tripUpdatesPresentButSilentMeansScheduled() {
        let rows = [departure(seq: 1, offset: 0, base: midnight)]
        let merged = Merge.mergeDepartures(rows, tripID: "T1", frame: frame())
        #expect(merged.map(\.state) == [.scheduled])
    }

    @Test func cancelledTripMarksEveryStop() {
        let rows = (1...3).map { departure(seq: $0, offset: TimeInterval($0 * 60), base: midnight) }
        let merged = Merge.mergeDepartures(rows, tripID: "T1", frame: frame(cancelled: ["T1"]))
        #expect(merged.allSatisfy { $0.state == .cancelled })
        #expect(merged.allSatisfy { $0.liveTime == nil })
    }

    /// The subtle one: a stop with no explicit stop_time_update must inherit the last known delay,
    /// otherwise a bus running 5 min late shows every later stop as on time.
    @Test func delayPropagatesToLaterStopsWithoutPredictions() {
        let rows = (1...3).map { departure(seq: $0, offset: TimeInterval($0 * 60), base: midnight) }
        let predicted = midnight.addingTimeInterval(60 + 300) // stop 1, five minutes late
        let merged = Merge.mergeDepartures(
            rows, tripID: "T1",
            frame: frame(predictions: ["T1": [1: Prediction(arrival: predicted, departure: nil, delay: nil, scheduleRelationship: .scheduled)]])
        )
        #expect(merged.allSatisfy { $0.state == .live })
        #expect(merged.allSatisfy { $0.delta == 300 })
    }

    @Test func stopsBeforeAnyPredictionStayScheduled() {
        let rows = (1...3).map { departure(seq: $0, offset: TimeInterval($0 * 60), base: midnight) }
        let predicted = midnight.addingTimeInterval(180 + 120)
        let merged = Merge.mergeDepartures(
            rows, tripID: "T1",
            frame: frame(predictions: ["T1": [3: Prediction(arrival: predicted, departure: nil, delay: nil, scheduleRelationship: .scheduled)]])
        )
        #expect(merged[0].state == .scheduled)
        #expect(merged[1].state == .scheduled)
        #expect(merged[2].state == .live)
    }

    @Test func skippedStopIsCancelledButLaterStopsSurvive() {
        let rows = (1...2).map { departure(seq: $0, offset: TimeInterval($0 * 60), base: midnight) }
        let merged = Merge.mergeDepartures(
            rows, tripID: "T1",
            frame: frame(predictions: ["T1": [1: Prediction(arrival: nil, departure: nil, delay: nil, scheduleRelationship: .skipped)]])
        )
        #expect(merged[0].state == .cancelled)
        #expect(merged[1].state != .cancelled)
    }

    /// The stop-sheet case: we're handed the single row for one stop, and the feed's update for that trip
    /// covers a different stop. Propagating only within the rows we were given propagated within nothing,
    /// so the row fell through to plain "Scheduled" grey while the same payload said the bus was 5 min down.
    @Test func stopOmittedByFeedInheritsAnEarlierStopsPublishedDelay() {
        let rows = [departure(seq: 5, offset: 300, base: midnight)]
        let merged = Merge.mergeDepartures(
            rows, tripID: "T1",
            frame: frame(predictions: ["T1": [
                2: Prediction(arrival: nil, departure: nil, delay: 300, scheduleRelationship: .scheduled)
            ]])
        )
        #expect(merged[0].state == .live)
        #expect(merged[0].delta == 300)
    }

    /// Only *earlier* stops count. A delay published for a stop the bus hasn't reached says nothing about
    /// one it already passed.
    @Test func laterStopsPublishedDelayDoesNotLeakBackwards() {
        let rows = [departure(seq: 1, offset: 60, base: midnight)]
        let merged = Merge.mergeDepartures(
            rows, tripID: "T1",
            frame: frame(predictions: ["T1": [
                9: Prediction(arrival: nil, departure: nil, delay: 300, scheduleRelationship: .scheduled)
            ]])
        )
        #expect(merged[0].state == .scheduled)
        #expect(merged[0].liveTime == nil)
    }

    /// An explicit predicted time for this very stop always beats an inherited delay.
    @Test func explicitPredictionBeatsInheritedDelay() {
        let rows = [departure(seq: 5, offset: 300, base: midnight)]
        let predicted = midnight.addingTimeInterval(300 + 60)
        let merged = Merge.mergeDepartures(
            rows, tripID: "T1",
            frame: frame(predictions: ["T1": [
                2: Prediction(arrival: nil, departure: nil, delay: 600, scheduleRelationship: .scheduled),
                5: Prediction(arrival: predicted, departure: nil, delay: nil, scheduleRelationship: .scheduled)
            ]])
        )
        #expect(merged[0].delta == 60)
    }

    /// The trip-detail case, where one call covers every stop on the route. Stop 5 gets an explicit
    /// predicted time (1 min down) and the feed publishes 10 min at stop 10; stop 12 must inherit the
    /// *nearest earlier* figure — stop 10's — not the one carried forward from stop 5.
    @Test func nearestEarlierDelayWinsOverOneCarriedForwardFromFurtherBack() {
        let rows = [5, 12].map { departure(seq: $0, offset: TimeInterval($0 * 60), base: midnight) }
        let merged = Merge.mergeDepartures(
            rows, tripID: "T1",
            frame: frame(predictions: ["T1": [
                5: Prediction(
                    arrival: midnight.addingTimeInterval(5 * 60 + 60), departure: nil,
                    delay: 60, scheduleRelationship: .scheduled
                ),
                10: Prediction(arrival: nil, departure: nil, delay: 600, scheduleRelationship: .scheduled)
            ]])
        )
        #expect(merged[0].delta == 60)
        #expect(merged[1].delta == 600)
    }

    /// The real "bus past my stop" case. The feed drops a stop's update once the bus is past it and
    /// republishes absolute times for the remaining stops, so the smallest published sequence is the bus's
    /// position. A stop below that boundary whose time has come has departed — showing the timetable there is
    /// what left a bus that had moved on reading "due in 2 min" while the map's GPS dot sat beyond the stop.
    /// (vehicle_positions carries no current_stop_sequence on this feed, so the boundary is the only signal.)
    @Test func passedStopBelowThePublishedBoundaryReadsDeparted() {
        let ts = midnight.addingTimeInterval(1000)
        let rows = [departure(seq: 3, offset: 300, base: midnight)] // scheduled +300, before ts
        let merged = Merge.mergeDepartures(
            rows, tripID: "T1",
            frame: frame(
                predictions: ["T1": [
                    6: Prediction(arrival: midnight.addingTimeInterval(6 * 60), departure: nil, delay: nil, scheduleRelationship: .scheduled),
                    7: Prediction(arrival: midnight.addingTimeInterval(7 * 60), departure: nil, delay: nil, scheduleRelationship: .scheduled)
                ]],
                timestamp: ts
            )
        )
        #expect(merged[0].state == .live)
        #expect(merged[0].displayTime <= ts) // departed, not a future time
    }

    /// The feed keeps publishing an alert after its active period ends. Nothing filtered on it, so finished
    /// roadworks sat in the Alerts tab, in the tab badge, and as an amber banner on a favourite stop.
    @Test func expiredAlertsAreNotActiveButOpenEndedOnesAre() {
        func alert(to: Date?) -> ServiceAlert {
            ServiceAlert(
                id: "a", headerText: "", descriptionText: "", effect: .unknownEffect,
                severity: .unknownSeverity, informedRouteIDs: [], informedStopIDs: [],
                activeFrom: nil, activeTo: to
            )
        }
        let now = midnight
        #expect(alert(to: now.addingTimeInterval(-1)).isActive(now: now) == false)
        #expect(alert(to: now.addingTimeInterval(3600)).isActive(now: now))
        #expect(alert(to: nil).isActive(now: now)) // no end date is open-ended, not expired
    }

    // MARK: - stop search ranking

    /// Ranking is the whole point of the rewrite: SQL can filter but the old `LIMIT 30` handed back rows in
    /// table order. Words in any order must match, a typed stop number must win outright, and among equals
    /// the nearest stop is the one the user is standing at.
    @Test func stopSearchRanksCodeThenWordStartThenDistance() {
        let far = StopSummary(id: "1", code: "10001", name: "Grenfell St", lat: -34.99, lon: 138.6)
        let near = StopSummary(id: "2", code: "10002", name: "Grenfell St", lat: -34.92, lon: 138.6)
        let buried = StopSummary(id: "3", code: "10003", name: "Ungrenfelled Rd", lat: -34.92, lon: 138.6)
        let here = (lat: -34.92, lon: 138.6)

        let tokens = StopSearch.tokens("grenfell st")
        #expect(tokens == ["grenfell", "st"])
        // Reversed words find the same stop — the old contiguous `%grenfell st%` pattern could not.
        #expect(StopSearch.tokens("st grenfell").count == 2)

        let ranked = StopSearch.rank([far, buried, near], tokens: tokens, near: here)
        #expect(ranked.map(\.id) == ["2", "1", "3"]) // nearest word-start match, then far, then buried

        // A typed stop number outranks everything, however far away it is.
        let byCode = StopSearch.rank([near, far], tokens: StopSearch.tokens("10001"), near: here)
        #expect(byCode.first?.id == "1")
    }

    /// The stop directly below the boundary is where the feed is unreliable: it drops that update while the
    /// bus is still working toward the stop. Reporting it departed at its scheduled time is what made an
    /// imminent bus disappear from its own stop and show up one stop on as "10 min late". It must stay live
    /// and visible, bounded by the boundary stop's published arrival — but never past the feed's publish
    /// time, or a bus that left 1–2 min ago still counts down as if it were coming.
    @Test func stopJustBelowTheBoundaryStaysLiveAtTheNextStopsPublishedTime() {
        let ts = midnight.addingTimeInterval(1000)
        let nextArrival = midnight.addingTimeInterval(1060)
        let rows = [departure(seq: 5, offset: 300, base: midnight)] // scheduled long past: a late bus
        let merged = Merge.mergeDepartures(
            rows, tripID: "T1",
            frame: frame(
                predictions: ["T1": [
                    6: Prediction(arrival: nextArrival, departure: nil, delay: nil, scheduleRelationship: .scheduled)
                ]],
                timestamp: ts
            )
        )
        #expect(merged[0].state == .live)
        #expect(merged[0].displayTime == ts) // capped at publish time: never a future countdown for a bus already gone
    }

    /// The guard on the boundary, now only one stop wide. The stop directly below the boundary with a future
    /// scheduled time must not be hidden as departed — a boundary that briefly jumps backward (measured:
    /// ~0.25% of trips) would otherwise erase a genuinely upcoming departure from the list.
    @Test func stopDirectlyBelowBoundaryButStillFutureIsNotHiddenAsDeparted() {
        let ts = midnight.addingTimeInterval(100)
        let rows = [departure(seq: 5, offset: 300, base: midnight)] // scheduled +300, after ts
        let merged = Merge.mergeDepartures(
            rows, tripID: "T1",
            frame: frame(
                predictions: ["T1": [6: Prediction(arrival: midnight.addingTimeInterval(360), departure: nil, delay: nil, scheduleRelationship: .scheduled)]],
                timestamp: ts
            )
        )
        #expect(merged[0].displayTime > ts) // stays upcoming, not marked departed
    }

    /// An *early* bus: two or more stops below the boundary, the feed has pruned the stop but its scheduled
    /// time hasn't come. The route line (same boundary) already shows it passed, so the row must not keep
    /// counting down — the "line says gone, stop says one minute" contradiction.
    @Test func earlyBusWellBelowBoundaryReadsAsDeparted() {
        let ts = midnight.addingTimeInterval(100)
        let rows = [departure(seq: 3, offset: 300, base: midnight)] // scheduled +300, after ts
        let merged = Merge.mergeDepartures(
            rows, tripID: "T1",
            frame: frame(
                predictions: ["T1": [6: Prediction(arrival: midnight.addingTimeInterval(360), departure: nil, delay: nil, scheduleRelationship: .scheduled)]],
                timestamp: ts
            )
        )
        #expect(merged[0].displayTime <= ts) // departed, not a future countdown
    }

    /// A bus recovering: 6 min late at stop 5, 3 min late at stop 10, stop 7 omitted by the feed. The gap
    /// stop must interpolate toward the newer, smaller delay rather than freeze at the stale 6 — the "can't
    /// recover from a bus no longer being late" complaint.
    @Test func omittedStopInterpolatesBetweenBracketingDelays() {
        let rows = [5, 7, 10].map { departure(seq: $0, offset: TimeInterval($0 * 60), base: midnight) }
        let merged = Merge.mergeDepartures(
            rows, tripID: "T1",
            frame: frame(predictions: ["T1": [
                5: Prediction(arrival: midnight.addingTimeInterval(5 * 60 + 360), departure: nil, delay: nil, scheduleRelationship: .scheduled),
                10: Prediction(arrival: midnight.addingTimeInterval(10 * 60 + 180), departure: nil, delay: nil, scheduleRelationship: .scheduled)
            ]])
        )
        // stop 7 = 360 + (7-5)/(10-5) · (180 − 360) = 360 − 72 = 288s, between the 6 min and 3 min endpoints.
        #expect(merged[1].stopSequence == 7)
        #expect(abs((merged[1].delta ?? 0) - 288) < 1)
        #expect(merged[0].delta == 360) // stop 5 keeps its own explicit prediction
        #expect(merged[2].delta == 180) // stop 10 keeps its own explicit prediction
    }

    /// The bug that made a bus pulling into the stop read as four minutes away. Measured on the live feed:
    /// 18 of 336 running trips publish `stop_sequence` values shifted a stop from `stop_times.txt`, so the
    /// update filed under sequence 5 was really about the stop at sequence 6. Matching by `stop_id` — always
    /// published, always belonging to the trip — is what makes the times land on the right stops.
    @Test func predictionsAreMatchedByStopIDWhenTheFeedsSequencesAreShifted() {
        let rows = [5, 6].map { departure(seq: $0, offset: TimeInterval($0 * 60), base: midnight) }
        let merged = Merge.mergeDepartures(
            rows, tripID: "T1",
            frame: frame(predictions: ["T1": [
                // Shifted: the entry numbered 5 carries stop S6's id, and so on.
                5: Prediction(stopID: "S6", arrival: midnight.addingTimeInterval(6 * 60 + 60), departure: nil, delay: nil, scheduleRelationship: .scheduled),
                6: Prediction(stopID: "S7", arrival: midnight.addingTimeInterval(7 * 60 + 60), departure: nil, delay: nil, scheduleRelationship: .scheduled)
            ]], timestamp: midnight)
        )
        let atSix = merged.first { $0.stopSequence == 6 }
        #expect(atSix?.delta == 60)                                   // its own stop's prediction, not stop 7's
        #expect(atSix?.displayTime == midnight.addingTimeInterval(6 * 60 + 60))
        // Two-sided: stop 5 must not have swallowed stop 6's time either.
        #expect(merged.first { $0.stopSequence == 5 }?.displayTime != midnight.addingTimeInterval(6 * 60 + 60))
    }

    /// Sequence 999 is the trip's final stop, not junk — 142 of 142 of them were the last stop in
    /// `stop_times`. A trip publishing only 999 is a bus on its last leg, so every other stop is behind it;
    /// treating it as "no position at all" left those stops counting down to times long past.
    @Test func aTripPublishingOnlyTheTerminusMarksEarlierStopsDeparted() {
        let ts = midnight.addingTimeInterval(1000)
        let rows = [departure(seq: 3, offset: 300, base: midnight)]
        let merged = Merge.mergeDepartures(
            rows, tripID: "T1",
            frame: frame(
                predictions: ["T1": [
                    999: Prediction(stopID: "S40", arrival: midnight.addingTimeInterval(1200), departure: nil, delay: nil, scheduleRelationship: .scheduled)
                ]],
                timestamp: ts
            )
        )
        #expect(merged[0].displayTime <= ts)
    }

    /// 492 trips end where they start, so stop S1 is both sequence 1 and 999. Once the bus has left, only the
    /// 999 update carries that `stop_id`, and an unbounded `stop_id` search gave it to the passed sequence 1:
    /// boundary dragged back to the first stop, every stop behind the bus un-passed and showing invented times
    /// (trip 1135817 un-passed 139 stops on the live feed).
    @Test func aLoopTripsFirstStopDoesNotClaimItsFinalStopsPrediction() {
        let ts = midnight.addingTimeInterval(3000)
        let rows = [
            departure(seq: 1, offset: 0, base: midnight, stopID: "S1"),
            departure(seq: 2, offset: 600, base: midnight),
            departure(seq: 3, offset: 3000, base: midnight),
            departure(seq: 999, offset: 3600, base: midnight, stopID: "S1")
        ]
        let f = frame(predictions: ["T1": [
            3: Prediction(stopID: "S3", arrival: midnight.addingTimeInterval(3060), departure: nil, delay: nil, scheduleRelationship: .scheduled),
            999: Prediction(stopID: "S1", arrival: midnight.addingTimeInterval(3660), departure: nil, delay: nil, scheduleRelationship: .scheduled)
        ]], timestamp: ts)
        let merged = Merge.mergeDepartures(rows, tripID: "T1", frame: f)

        #expect(Merge.busStopSequence(tripID: "T1", frame: f, among: rows) == 3)
        #expect(merged[0].displayTime <= ts)                          // passed, not an hour late
        #expect(merged[1].displayTime <= ts)
        // Two-sided: the final visit still owns its own prediction.
        #expect(merged[3].displayTime == midnight.addingTimeInterval(3660))
        #expect(Merge.stopsAway(for: rows[0], frame: f) == nil)       // behind the bus
        #expect(Merge.stopsAway(for: rows[3], frame: f) == 1)
    }

    /// Stops away is a count of remaining stops, not a difference of sequence numbers: static sequences skip
    /// numbers on 26534 of 26535 trips, so subtracting them overstated how far back the bus was.
    @Test func stopsAwayCountsRemainingStopsNotSequenceGaps() {
        let dep = departure(seq: 40, offset: 600, base: midnight)
        let f = frame(predictions: ["T1": [
            10: Prediction(stopID: "S10", arrival: midnight, departure: nil, delay: nil, scheduleRelationship: .scheduled),
            25: Prediction(stopID: "S25", arrival: midnight, departure: nil, delay: nil, scheduleRelationship: .scheduled),
            40: Prediction(stopID: "S40", arrival: midnight, departure: nil, delay: nil, scheduleRelationship: .scheduled)
        ]])
        #expect(Merge.stopsAway(for: dep, frame: f) == 2)             // two stops before it, not 30
        // Two-sided: the stop the bus is working toward is zero away, not nil.
        #expect(Merge.stopsAway(for: departure(seq: 10, offset: 0, base: midnight), frame: f) == 0)
    }

    @Test func mergeSortsByStopSequence() {
        let rows = [3, 1, 2].map { departure(seq: $0, offset: TimeInterval($0 * 60), base: midnight) }
        let merged = Merge.mergeDepartures(rows, tripID: "T1", frame: frame())
        #expect(merged.map(\.stopSequence) == [1, 2, 3])
    }

    // MARK: - serviceDate

    /// A 00:40 trip belongs to yesterday's service day; picking today would place it ~24h away.
    @Test func afterMidnightTripResolvesToPreviousServiceDay() {
        let now = AdelaideTZ.startOfDay(Date()).addingTimeInterval(40 * 60)
        let firstDep = 24 * 3600 + 30 * 60 // 24:30 in GTFS terms
        let resolved = Merge.serviceDate(firstDeparture: firstDep, now: now)
        let expected = AdelaideTZ.calendar.date(byAdding: .day, value: -1, to: AdelaideTZ.startOfDay(now))!
        #expect(resolved == expected)
        // Sanity: the trip now lands near "now" rather than a day out.
        #expect(abs(resolved.addingTimeInterval(TimeInterval(firstDep)).timeIntervalSince(now)) < 3600)
    }

    /// GTFS times are seconds from *service* midnight, defined as noon minus twelve hours. On Adelaide's two
    /// daylight-saving changeover days that is an hour off calendar midnight, so anchoring at 00:00 shifted
    /// every departure on those days by an hour — an 08:00 bus listed as 09:00 in October.
    @Test func serviceMidnightHoldsAcrossDaylightSaving() {
        // 5 Oct 2025: Adelaide clocks jump 02:00 → 03:00, so the day is 23 hours long.
        for (day, month, year) in [(5, 10, 2025), (6, 4, 2025)] {
            let noonish = AdelaideTZ.calendar.date(
                from: DateComponents(year: year, month: month, day: day, hour: 9)
            )!
            let eightAM = AdelaideTZ.startOfDay(noonish).addingTimeInterval(8 * 3600)
            #expect(AdelaideTZ.calendar.component(.hour, from: eightAM) == 8)
            #expect(AdelaideTZ.calendar.component(.day, from: eightAM) == day)
        }
    }

    /// A wide departure window lists the first morning buses late at night. Without tomorrow as a candidate
    /// a 05:00 trip opened at 23:30 landed on today's 05:00, 18 hours in the past.
    @Test func earlyMorningTripOpenedLateAtNightResolvesToTomorrow() {
        let now = AdelaideTZ.startOfDay(Date()).addingTimeInterval(23.5 * 3600)
        let resolved = Merge.serviceDate(firstDeparture: 5 * 3600, now: now)
        let tomorrow = AdelaideTZ.startOfDay(AdelaideTZ.calendar.date(byAdding: .day, value: 1, to: now)!)
        #expect(resolved == tomorrow)
        #expect(resolved.addingTimeInterval(5 * 3600) > now)
    }

    @Test func middayTripResolvesToToday() {
        let now = AdelaideTZ.startOfDay(Date()).addingTimeInterval(12 * 3600)
        let resolved = Merge.serviceDate(firstDeparture: 12 * 3600, now: now)
        #expect(resolved == AdelaideTZ.startOfDay(now))
    }

    // MARK: - trackingState

    @Test func freshVehicleIsLive() {
        let now = Date()
        let vehicle = LiveVehicle(
            tripID: "T1", vehicleLabel: nil, routeID: nil, directionID: nil,
            lat: 0, lon: 0, bearing: nil, speedMS: nil,
            timestamp: now.addingTimeInterval(-5), currentStopSequence: nil
        )
        let state = Merge.trackingState(tripID: "T1", scheduledStart: nil, frame: frame(vehicles: ["T1": vehicle]), now: now)
        #expect(state == .live)
    }

    @Test func cancellationBeatsALiveVehicle() {
        let now = Date()
        let vehicle = LiveVehicle(
            tripID: "T1", vehicleLabel: nil, routeID: nil, directionID: nil,
            lat: 0, lon: 0, bearing: nil, speedMS: nil,
            timestamp: now, currentStopSequence: nil
        )
        let state = Merge.trackingState(
            tripID: "T1", scheduledStart: nil,
            frame: frame(cancelled: ["T1"], vehicles: ["T1": vehicle]), now: now
        )
        #expect(state == .cancelled)
    }

    /// Imminent departure, no vehicle and no trip update at all — the "not tracking" case.
    @Test func imminentTripWithNoRealtimeIsGhost() {
        let now = Date()
        let state = Merge.trackingState(
            tripID: "T1", scheduledStart: now.addingTimeInterval(60), frame: frame(), now: now
        )
        #expect(state == .ghost)
    }

    @Test func distantTripWithNoRealtimeIsScheduled() {
        let now = Date()
        let state = Merge.trackingState(
            tripID: "T1", scheduledStart: now.addingTimeInterval(6 * 3600), frame: frame(), now: now
        )
        #expect(state == .scheduled)
    }

    /// Same rule the departure rows already followed: before trip_updates has landed we have not
    /// established that anything is running to timetable, so the Trip Detail chip must not claim it.
    @Test func trackingStateIsPendingBeforeTripUpdatesLand() {
        let now = Date()
        #expect(Merge.trackingState(tripID: "T1", scheduledStart: nil, frame: nil, now: now) == .pending)
        #expect(Merge.trackingState(
            tripID: "T1", scheduledStart: now.addingTimeInterval(60),
            frame: frame(hasTripUpdates: false), now: now
        ) == .pending)
    }

    // MARK: - backoff

    /// An outage previously retried every 3s forever, on three feeds at once.
    @Test func backoffGrowsThenCaps() {
        #expect(RealtimeEngine.backoff(failures: 0) == 0)
        #expect(RealtimeEngine.backoff(failures: 1) == PollSchedule.missRetry)
        #expect(RealtimeEngine.backoff(failures: 3) == PollSchedule.missRetry * 4)
        #expect(RealtimeEngine.backoff(failures: 40) == 60)
    }

    // MARK: - interpolatedPosition

    private var straightShape: [(lat: Double, lon: Double, dist: Double?)] {
        (0...10).map { (lat: Double($0) / 10, lon: 0, dist: nil) }
    }

    private var twoStops: [(seq: Int, lat: Double, lon: Double, dep: Int)] {
        [(seq: 1, lat: 0, lon: 0, dep: 0), (seq: 2, lat: 1, lon: 0, dep: 600)]
    }

    @Test func interpolationSitsHalfwayAtTheHalfwayTime() {
        let position = Merge.interpolatedPosition(
            shape: straightShape, stopTimes: twoStops,
            serviceMidnight: midnight, now: midnight.addingTimeInterval(300)
        )
        let latitude = try! #require(position?.lat)
        #expect(abs(latitude - 0.5) < 0.01)
    }

    @Test func interpolationClampsToTerminiOutsideTheTrip() {
        let before = Merge.interpolatedPosition(
            shape: straightShape, stopTimes: twoStops,
            serviceMidnight: midnight, now: midnight.addingTimeInterval(-60)
        )
        let after = Merge.interpolatedPosition(
            shape: straightShape, stopTimes: twoStops,
            serviceMidnight: midnight, now: midnight.addingTimeInterval(9999)
        )
        #expect(before?.lat == 0)
        #expect(after?.lat == 1)
    }

    @Test func interpolationReturnsNilWithoutAShape() {
        let position = Merge.interpolatedPosition(
            shape: [], stopTimes: twoStops, serviceMidnight: midnight, now: midnight
        )
        #expect(position == nil)
    }
}
