import Foundation

struct Prediction: Sendable, Equatable {
    /// The stop this update is *actually* about. The feed's `stop_sequence` cannot be trusted to match the
    /// static timetable — measured on the live feed, 18 of 336 running trips publish sequences shifted a stop
    /// from `stop_times.txt`, which showed the next stop's arrival against this stop and made a bus that had
    /// arrived read as minutes away. `stop_id` is published on every update and always belongs to the trip.
    var stopID: String = ""
    let arrival: Date?
    let departure: Date?
    /// The feed's own delay for this stop, when it publishes one. Kept separately from `time` because a
    /// stop the feed *omits* can still inherit it — see `Merge.mergeDepartures`.
    let delay: TimeInterval?
    let scheduleRelationship: TransitRealtime_TripUpdate.StopTimeUpdate.ScheduleRelationship

    var time: Date? { arrival ?? departure }
}

struct ServiceAlert: Sendable, Identifiable, Equatable {
    let id: String
    let headerText: String
    let descriptionText: String
    let effect: TransitRealtime_Alert.Effect
    let severity: TransitRealtime_Alert.SeverityLevel
    let informedRouteIDs: Set<String>
    let informedStopIDs: Set<String>
    let activeFrom: Date?
    let activeTo: Date?

    /// One window over all of an alert's active periods: earliest start, latest end.
    ///
    /// Every period, not just the first — a planned closure can be one alert with a window per night, and
    /// reading `activePeriod.first` expired the whole thing the morning after night one. A period with no end
    /// makes the alert open-ended, **unless the feed has split the window in two**: Adelaide publishes a
    /// bounded alert as a start-only period plus an end-only one (33 of 74 alerts on 2026-11-13, every alert
    /// that had an end at all). Read as "any missing end is open-ended", none of those ever expired here and
    /// none showed its "Until" date.
    static func window(of periods: [(start: Date?, end: Date?)]) -> (from: Date?, to: Date?) {
        let from = periods.compactMap(\.start).min()
        let ends = periods.compactMap(\.end)
        let hasEndOnly = periods.contains { $0.start == nil && $0.end != nil }
        let openEnded = periods.isEmpty || (periods.contains { $0.end == nil } && !hasEndOnly)
        return (from, openEnded ? nil : ends.max())
    }

    /// Whether this alert has not yet expired. The feed keeps publishing an alert past the end of its active
    /// period and nothing filtered on it: the Alerts tab listed finished roadworks under a heading that reads
    /// "No active alerts" when empty, the tab badge counted them, and a favourite kept an amber closure
    /// banner for a closure that had ended. A missing end is open-ended, not expired. Alerts starting in the
    /// future are kept — planned works are exactly what you want warning of, and the row shows when.
    func isActive(now: Date = .now) -> Bool {
        guard let activeTo else { return true }
        return activeTo >= now
    }
}

struct RealtimeFrame: Sendable {
    let vehicles: [String: LiveVehicle]                    // keyed by tripID
    let predictions: [String: [UInt32: Prediction]]        // tripID -> stopSequence -> Prediction
    let cancelledTripIDs: Set<String>
    let alerts: [ServiceAlert]
    /// Publish time of the newest vehicles or trip_updates message — what the map's age badge reports.
    let headerTimestamp: Date?
    /// Publish time of the trip_updates message `predictions` came from. Its own field because the two feeds
    /// run on different clocks (vehicles 15 s, trip_updates 60 s, measured 2026-11-12) and are polled under
    /// different screens: taken off the newest header, predictions minutes old read as seconds old whenever
    /// the small vehicles payload kept arriving and the large trip_updates one did not.
    var tripUpdatesTimestamp: Date? = nil
    /// Age past which `predictions` no longer vouch for anything — set by the engine from the interval it is
    /// actually polling trip_updates at. See `GhostCutoffs.predictionsStaleAfter`.
    var predictionsStaleAfter: TimeInterval = GhostCutoffs.predictionsStaleAfter(pollInterval: 60)

    /// Whether the predictions in this frame have stopped being current by `now`.
    func predictionsAreStale(at now: Date) -> Bool {
        guard let tripUpdatesTimestamp else { return false }
        return now.timeIntervalSince(tripUpdatesTimestamp) > predictionsStaleAfter
    }
    /// Whether trip_updates has ever landed. Absence of a prediction means "running to timetable" only
    /// once this is true; before it, we simply haven't asked yet.
    var hasTripUpdates: Bool = false
}

/// Backed by UserDefaults so Settings sliders (§5.4) take effect immediately, no threading required.
enum GhostCutoffs {
    static var staleAfter: TimeInterval {
        let v = UserDefaults.standard.double(forKey: "staleCutoffSeconds")
        return v > 0 ? v : 90
    }
    /// When predictions stop counting as current, given how often they are being fetched. Not `staleAfter`:
    /// that is tuned to vehicle positions, which publish every 15 s, while trip_updates publishes every ~60 s
    /// and is readable up to 8.5 s later (2026-11-12). At 90 s one late publish flashed "Live times last
    /// updated" and dropped every "Due" row back to "Departed" — and under Data Saver or Relaxed, which
    /// poll every 2–4 cycles, every row did so between polls. Two missed polls plus lag, or the user's
    /// cutoff if that is longer.
    static func predictionsStaleAfter(pollInterval: TimeInterval) -> TimeInterval {
        max(staleAfter, 2 * pollInterval + 30)
    }
    /// How far ahead of its scheduled start an untracked trip is still worth drawing as a ghost. Fixed at
    /// 5 min: it was a Settings slider, but it is an internal threshold about feed behaviour that nobody
    /// can tune without knowing what the feed does, and the "Show ghosts on map" toggle is the control
    /// that actually answers a user's question.
    static let ghostLookahead: TimeInterval = 5 * 60
}

/// Single source of truth for combining a scheduled trip with realtime data. §4 / §4.1 of the plan.
enum Merge {
    /// Per-row state for a stop's departure list: fills in liveTime and honours schedule_relationship
    /// (SKIPPED/CANCELED) and delay handling — a stop with no explicit stop_time_update is interpolated
    /// between the nearest known delay before and after it, so a recovering bus isn't frozen at a stale figure.
    static func mergeDepartures(_ departures: [Departure], tripID: String, frame: RealtimeFrame?) -> [Departure] {
        guard let frame else { return departures.map { restate($0, .pending, liveTime: nil) } }
        guard frame.hasTripUpdates else {
            return departures.map { restate($0, .pending, liveTime: nil) }
        }
        if frame.cancelledTripIDs.contains(tripID) {
            return departures.map { restate($0, .cancelled, liveTime: nil) }
        }

        let tripPredictions = frame.predictions[tripID] ?? [:]

        // The bus's position, inferred from pruning. The feed drops a stop's update the moment the bus is past
        // it and republishes an absolute time for every *remaining* stop, so the smallest still-published stop
        // is where the bus is now. vehicle_positions carries no `current_stop_sequence` on this feed — this is
        // the only "where is the bus" signal there is. Verified: over 5 min the boundary advances or holds for
        // 790/792 trips, so it tracks progress reliably.
        //
        // Taken from the *matched* rows where possible — a static sequence, correct even on the trips whose
        // published sequences are shifted. Only when nothing matched (a stop sheet passes one stop's row, and
        // an already-passed stop matches nothing) does it fall back to the published numbering.
        let matchedBoundary = departures.compactMap {
            prediction(for: $0, in: tripPredictions) != nil ? $0.stopSequence : nil
        }.min()
        // Sequence 999 marks the trip's final stop, not junk — measured, 142/142 of them were the last stop in
        // `stop_times`. So a trip publishing *only* 999 is a bus on its last leg with every other stop behind
        // it. Treating it as "no position" left every earlier stop counting down to a time long past.
        let publishedBoundary = tripPredictions.keys.map(Int.init).filter { $0 < 900 }.min()
        // Only asked of a row with no update of its own. On the published numbering the test is `<=`: where
        // the two numberings differ the published one runs a stop *below* the timetable's (292/292 shifted
        // updates, 2026-11-12), so an unmatched row sitting at the smallest published number is a passed stop
        // whose number the next stop's update has taken. With `<` it read "Scheduled" for a bus already gone.
        let isBehindBus = { (sequence: Int) -> Bool in
            if let matchedBoundary { return sequence < matchedBoundary }
            if let publishedBoundary { return sequence <= publishedBoundary }
            return !tripPredictions.isEmpty
        }
        // "As of when": the publish that dropped the stop, not the newest header in the frame.
        let publishedAt = frame.tripUpdatesTimestamp

        // Every delay we actually know for this trip, by stop sequence: derived from a stop's own absolute
        // predicted time against its schedule, or from a published `delay` field (this feed sends none).
        // Sorted, so an omitted stop can be bracketed and *interpolated* between the nearest known delay
        // before and after it — a bus recovering from 6 min down to 3 must not show a gap stop as the stale 6.
        // The feed publishes an absolute time for every remaining stop, so gaps are rare, but when the feed
        // does skip a stop this tracks the recovery instead of freezing it.
        var knownDelays: [(seq: Int, delay: TimeInterval)] = []
        for dep in departures {
            if let t = prediction(for: dep, in: tripPredictions)?.time {
                knownDelays.append((dep.stopSequence, t.timeIntervalSince(dep.scheduledTime)))
            }
        }
        for (seq, pred) in tripPredictions where pred.time == nil {
            if let d = pred.delay { knownDelays.append((Int(seq), d)) }
        }
        knownDelays.sort { $0.seq < $1.seq }

        // The boundary stop's own predicted arrival, used to bound the stop just below it. Looked up through
        // the same matcher when the boundary came from a matched row, so it can't pick up a shifted trip's
        // neighbouring stop.
        let boundaryTime: Date? = matchedBoundary.flatMap { boundary in
            departures.first { $0.stopSequence == boundary }
                .flatMap { prediction(for: $0, in: tripPredictions)?.time }
        } ?? publishedBoundary.flatMap { tripPredictions[UInt32(clamping: $0)]?.time }

        // Worked out once, not per row: a trip sheet merges the whole route on every frame, and answering this
        // per passed stop was an array built and scanned for each, O(stops²) on the longest trips.
        // "Directly below" is the next stop *in the list we were given*, not `boundary - 1`: static sequences
        // skip numbers, so `boundary - 1` can be a stop that doesn't exist. A stop sheet passes one stop's
        // rows and has no neighbours to compare, so there it is sequence adjacency.
        let rowsBehind = departures.map(\.stopSequence).filter(isBehindBus)
        let nearestBehind = rowsBehind.count > 1 ? rowsBehind.max() : nil
        let isDirectlyBehind = { (sequence: Int) -> Bool in
            if let nearestBehind { return sequence == nearestBehind }
            return sequence >= (matchedBoundary ?? publishedBoundary ?? .max) - 1
        }

        return departures
            .sorted { $0.stopSequence < $1.stopSequence }
            .map { dep -> Departure in
                if let pred = prediction(for: dep, in: tripPredictions) {
                    if pred.scheduleRelationship == .skipped {
                        return restate(dep, .cancelled, liveTime: nil)
                    }
                    if let predictedTime = pred.time {
                        return restate(dep, .live, liveTime: predictedTime, isStillListed: true)
                    }
                }

                // A stop behind the bus: the feed dropped its update, so it has departed, no later than that
                // publish. Showing the timetable there is what made a bus that had moved on still read "due in
                // 2 min", the list contradicting the GPS dot on the map.
                //
                // Not gated on the scheduled time having come. It was, to ride out a boundary that jumps ahead
                // and comes back — but that is 5 of 1374 trip-cycles, against 72 of 893 dropped stops that were
                // simply ahead of schedule (2026-11-12), and each of those fell back to the timetable and
                // counted down to a bus already gone. A stop that does come back matches again and is restored.
                //
                // When it left is not published. For the stop just behind the bus the boundary stop's arrival
                // bounds it, capped at the publish — "just now", never a future time. Further back the best
                // figure is the timetable, capped the same way for a bus running early.
                if isBehindBus(dep.stopSequence), let publishedAt {
                    let departed = isDirectlyBehind(dep.stopSequence)
                        ? min(boundaryTime ?? publishedAt, publishedAt)
                        : min(dep.scheduledTime, publishedAt)
                    return restate(dep, .live, liveTime: departed)
                }

                // Omitted upcoming stop: interpolate its delay between the nearest known delay before and after
                // it, so it tracks a recovering (or worsening) bus rather than holding the last figure. Only an
                // earlier figure known → hold it. No earlier figure at all → running to timetable as far as we
                // know; a later delay never leaks back onto a stop nothing yet places the bus before.
                guard let earlier = knownDelays.last(where: { $0.seq <= dep.stopSequence }) else { return dep }
                let delay: TimeInterval
                if let later = knownDelays.first(where: { $0.seq > dep.stopSequence }) {
                    let frac = Double(dep.stopSequence - earlier.seq) / Double(later.seq - earlier.seq)
                    delay = earlier.delay + (later.delay - earlier.delay) * frac
                } else {
                    delay = earlier.delay
                }
                return restate(dep, .live, liveTime: dep.scheduledTime.addingTimeInterval(delay))
            }
    }

    /// Whether a row belongs under "earlier departures".
    ///
    /// The clock alone is not enough. A stop the feed still lists has not been served: its predicted time
    /// slipping behind the clock means the bus is due, not gone, and 44 of 529 stops due within 30 s were
    /// still listed a whole 60 s cycle later (2026-11-12). Held only while the predictions are fresh — after
    /// the stale cutoff nothing is vouching for the row and the clock decides again.
    static func hasGone(_ dep: Departure, frame: RealtimeFrame?, now: Date) -> Bool {
        guard dep.displayTime < now else { return false }
        guard dep.isStillListed, let frame, frame.tripUpdatesTimestamp != nil else { return true }
        return frame.predictionsAreStale(at: now)
    }

    /// The update that actually belongs to this stop.
    ///
    /// Keyed on `stop_id`, not `stop_sequence`: measured against the live feed, 18 of 336 running trips
    /// publish sequences shifted by a stop from `stop_times.txt`, so reading `predictions[dep.stopSequence]`
    /// returned the *neighbouring* stop's arrival — a bus pulling in read as four minutes away while the stop
    /// before it, already served, showed the one minute that belonged here.
    ///
    /// The sequence still gets first say when it agrees with the stop, which is the common case and the only
    /// way to tell apart the 542 trips that serve the same stop twice; ties there go to the nearer sequence.
    ///
    /// The `stop_id` search only reaches `maxPublishedShift`. Unbounded, it found the *other visit* on a trip
    /// that serves a stop twice: on the 492 loops that end where they start, a passed sequence 1 matched the
    /// final stop's 999, which dragged the boundary back to stop 1 and un-passed the whole route (6 of 346
    /// running trips, measured 2026-10-31), with invented times on every stop behind the bus.
    static func prediction(for dep: Departure, in preds: [UInt32: Prediction]) -> Prediction? {
        if let byPosition = preds[UInt32(clamping: dep.stopSequence)],
           byPosition.stopID.isEmpty || byPosition.stopID == dep.stopID {
            return byPosition
        }
        guard !dep.stopID.isEmpty else { return nil }
        return preds
            .filter { $0.value.stopID == dep.stopID && abs(Int($0.key) - dep.stopSequence) <= maxPublishedShift }
            .min { abs(Int($0.key) - dep.stopSequence) < abs(Int($1.key) - dep.stopSequence) }?
            .value
    }

    /// How far a published `stop_sequence` strays from `stop_times.txt`: 219 of 219 shifted updates were off by
    /// exactly one (measured 2026-10-31).
    private static let maxPublishedShift = 1

    /// How many stops the bus still has to serve before this one — 0 once it is the stop being worked toward.
    ///
    /// Counted over the updates the feed still publishes, not subtracted from sequence numbers: static
    /// sequences are non-contiguous, so `dep.stopSequence - busSequence` claimed "7 stops away" for a bus two
    /// stops back. Nil when the trip has no updates, or when this stop is already behind the bus.
    static func stopsAway(for dep: Departure, frame: RealtimeFrame?) -> Int? {
        guard let preds = frame?.predictions[dep.tripID], !preds.isEmpty else { return nil }
        guard let mine = prediction(for: dep, in: preds) else { return nil }
        // 999 marks the final stop, so it sorts last rather than as sequence 999 among real numbers.
        let rank = { (seq: UInt32) in seq == 999 ? Int.max : Int(seq) }
        guard let myKey = preds.first(where: { $0.value == mine })?.key else { return nil }
        return preds.keys.filter { rank($0) < rank(myKey) }.count
    }

    /// The stop sequence the bus is currently working toward, inferred from feed pruning: an update is
    /// dropped once the bus passes a stop, so the smallest still-published sequence is where the bus is.
    /// Nil when the trip has no predictions. 999 marks the final stop, so it is excluded from the published
    /// fallback — a trip publishing only 999 has no earlier stop to name. This feed carries no
    /// `current_stop_sequence`, so this is the only position signal there is — the same boundary
    /// `mergeDepartures` uses to mark passed stops, exposed for "N stops away" and list trimming.
    /// Pass the trip's stops in wherever the caller has them: the answer is then a *static* sequence, matched
    /// by stop, and correct on the trips whose published sequences are shifted. Without them it falls back to
    /// the published numbering, which is right for the other 95% and never worse than a stop out.
    static func busStopSequence(
        tripID: String, frame: RealtimeFrame?, among departures: [Departure] = []
    ) -> Int? {
        guard let preds = frame?.predictions[tripID], !preds.isEmpty else { return nil }
        let matched = departures.compactMap { prediction(for: $0, in: preds) != nil ? $0.stopSequence : nil }
        return matched.min() ?? preds.keys.map(Int.init).filter { $0 < 900 }.min()
    }

    private static func restate(
        _ dep: Departure, _ state: TrackingState, liveTime: Date?, isStillListed: Bool = false
    ) -> Departure {
        Departure(
            tripID: dep.tripID, stopSequence: dep.stopSequence, stopID: dep.stopID, routeID: dep.routeID,
            routeShortName: dep.routeShortName, routeColor: dep.routeColor, headsign: dep.headsign,
            direction: dep.direction, scheduledTime: dep.scheduledTime, liveTime: liveTime, state: state,
            isStillListed: isStillListed
        )
    }

    /// Vehicle-tracking classification for a trip as a whole — drives map markers and the Trip Detail chip.
    static func trackingState(
        tripID: String, scheduledStart: Date?, frame: RealtimeFrame?, now: Date
    ) -> TrackingState {
        guard let frame else { return .pending }
        if frame.cancelledTripIDs.contains(tripID) { return .cancelled }

        if let vehicle = frame.vehicles[tripID] {
            let age = now.timeIntervalSince(vehicle.timestamp)
            return age <= GhostCutoffs.staleAfter ? .live : .stale(secondsAgo: Int(age))
        }

        // Same rule as `mergeDepartures`: without trip_updates we haven't established that this service is
        // running to timetable, so it is `.pending`, not `.scheduled`. Claiming otherwise is what made the
        // Trip Detail chip read "Scheduled" and flip to LIVE a moment later.
        guard frame.hasTripUpdates else { return .pending }

        let hasTripUpdate = !(frame.predictions[tripID] ?? [:]).isEmpty
        if !hasTripUpdate, let start = scheduledStart, start <= now.addingTimeInterval(GhostCutoffs.ghostLookahead) {
            return .ghost
        }
        return .scheduled
    }

    /// Which service day a trip belongs to. GTFS departure times are seconds from service midnight and run
    /// past 24h, so a "00:40" trip is yesterday's service still running — pick whichever midnight puts the
    /// first departure closest to now. Tomorrow is a candidate too: a wide departure window lists the first
    /// morning buses late at night, and those read as ~19 h in the past against today's midnight.
    static func serviceDate(firstDeparture: Int, now: Date) -> Date {
        let today = AdelaideTZ.startOfDay(now)
        // A day off `now`, then anchored — not a day off the anchor. On a daylight-saving changeover the two
        // differ by an hour, which is a whole trip's worth of wrong times.
        let neighbours = [-1, 1].compactMap {
            AdelaideTZ.calendar.date(byAdding: .day, value: $0, to: now).map(AdelaideTZ.startOfDay)
        }
        let distance = { (midnight: Date) in
            abs(midnight.addingTimeInterval(TimeInterval(firstDeparture)).timeIntervalSince(now))
        }
        // Today first, so a tie stays on today.
        return ([today] + neighbours).min { distance($0) < distance($1) } ?? today
    }

    /// Interpolated position for a ghost trip: where it *should* be right now, from the static schedule + shape.
    ///
    /// Anchors stops to the shape by nearest point rather than `shape_dist_traveled` — that column is optional
    /// in GTFS and isn't present in this feed's stop_times, and the old distance-based version silently fell
    /// back to "middle of the route" whenever it was missing, which was always.
    static func interpolatedPosition(
        shape: [(lat: Double, lon: Double, dist: Double?)],
        stopTimes: [(seq: Int, lat: Double, lon: Double, dep: Int)],
        serviceMidnight: Date, now: Date
    ) -> (lat: Double, lon: Double)? {
        guard let firstShape = shape.first, let lastShape = shape.last,
              let first = stopTimes.first, let last = stopTimes.last else { return nil }

        let nowSeconds = now.timeIntervalSince(serviceMidnight)
        if nowSeconds <= Double(first.dep) { return (firstShape.lat, firstShape.lon) }
        if nowSeconds >= Double(last.dep) { return (lastShape.lat, lastShape.lon) }

        guard let idx = stopTimes.firstIndex(where: { Double($0.dep) >= nowSeconds }), idx > 0 else { return nil }
        let a = stopTimes[idx - 1], b = stopTimes[idx]
        let span = Double(b.dep - a.dep)
        let frac = span > 0 ? (nowSeconds - Double(a.dep)) / span : 0

        let indexA = Double(nearestShapeIndex(to: (a.lat, a.lon), in: shape))
        let indexB = Double(nearestShapeIndex(to: (b.lat, b.lon), in: shape))
        let target = indexA + (indexB - indexA) * frac

        // Blend between the two bracketing shape points so the marker glides instead of snapping vertex to vertex.
        let lower = Int(target.rounded(.down))
        let upper = min(lower + 1, shape.count - 1)
        let t = target - Double(lower)
        guard lower >= 0, lower < shape.count else { return nil }
        return (
            shape[lower].lat + (shape[upper].lat - shape[lower].lat) * t,
            shape[lower].lon + (shape[upper].lon - shape[lower].lon) * t
        )
    }

    private static func nearestShapeIndex(
        to point: (lat: Double, lon: Double),
        in shape: [(lat: Double, lon: Double, dist: Double?)]
    ) -> Int {
        var bestIdx = 0
        var bestDist = Double.greatestFiniteMagnitude
        for (i, p) in shape.enumerated() {
            let dLat = p.lat - point.lat, dLon = p.lon - point.lon
            let d = dLat * dLat + dLon * dLon
            if d < bestDist { bestDist = d; bestIdx = i }
        }
        return bestIdx
    }
}
