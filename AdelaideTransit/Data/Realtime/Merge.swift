import Foundation

struct Prediction: Sendable, Equatable {
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
    let headerTimestamp: Date?
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
        // it and republishes an absolute time for every *remaining* stop, so the smallest published sequence
        // is where the bus is now. vehicle_positions carries no `current_stop_sequence` on this feed — this is
        // the only "where is the bus" signal there is. Sequence 999 is a junk sentinel; ignore it. Verified:
        // over 5 min the boundary advances or holds for 790/792 trips, so it tracks progress reliably.
        let passedBoundary: Int? = tripPredictions.keys.map(Int.init).filter { $0 < 900 }.min()

        // Every delay we actually know for this trip, by stop sequence: derived from a stop's own absolute
        // predicted time against its schedule, or from a published `delay` field (this feed sends none).
        // Sorted, so an omitted stop can be bracketed and *interpolated* between the nearest known delay
        // before and after it — a bus recovering from 6 min down to 3 must not show a gap stop as the stale 6.
        // The feed publishes an absolute time for every remaining stop, so gaps are rare, but when the feed
        // does skip a stop this tracks the recovery instead of freezing it.
        var knownDelays: [(seq: Int, delay: TimeInterval)] = []
        for dep in departures {
            if let t = tripPredictions[UInt32(dep.stopSequence)]?.time {
                knownDelays.append((dep.stopSequence, t.timeIntervalSince(dep.scheduledTime)))
            }
        }
        for (seq, pred) in tripPredictions where pred.time == nil {
            if let d = pred.delay { knownDelays.append((Int(seq), d)) }
        }
        knownDelays.sort { $0.seq < $1.seq }

        return departures
            .sorted { $0.stopSequence < $1.stopSequence }
            .map { dep -> Departure in
                if let pred = tripPredictions[UInt32(dep.stopSequence)] {
                    if pred.scheduleRelationship == .skipped {
                        return restate(dep, .cancelled, liveTime: nil)
                    }
                    if let predictedTime = pred.time {
                        return restate(dep, .live, liveTime: predictedTime)
                    }
                }

                // The stop *directly* below the boundary is not reliably passed: the feed drops a stop's update
                // while the bus is still working toward it, so a bus physically at the stop reads as one stop
                // on. Marking it departed at its long-gone scheduled time is what made an imminent bus vanish
                // from the list and reappear at the next stop as "10 min late". Its time here is bounded by the
                // boundary stop's own published arrival — a hop away, in the future — so show that instead.
                // ponytail: the next stop's arrival is one hop long, so it's capped at the feed's publish
                // time — worst case this reads "now" for a bus that just left, never a future countdown for
                // one already gone. Subtracting the real scheduled gap needs the next stop's scheduled time,
                // which a stop sheet (one stop's rows) doesn't have; pass the whole trip's stop_times in if
                // "now" instead of "departed" starts to matter.
                //
                // Gated on the same "its scheduled time has come" condition as the departed branch below, so a
                // stop the bus genuinely hasn't reached yet still runs to timetable rather than inheriting a
                // later stop's time.
                if let passedBoundary, dep.stopSequence == passedBoundary - 1,
                   let ts = frame.headerTimestamp, dep.scheduledTime <= ts,
                   let nextTime = tripPredictions[UInt32(passedBoundary)]?.time {
                    return restate(dep, .live, liveTime: min(nextTime, ts))
                }

                // A stop below the boundary the bus has already served — the feed dropped its update. It has
                // departed, no later than the feed's publish time; showing the timetable there is what made a
                // bus that had moved on still read "due in 2 min", the list contradicting the GPS dot on the
                // map. Gated on the scheduled time having already come (using the feed timestamp as "now") so a
                // boundary that briefly jumps backward can't hide a stop the bus genuinely hasn't reached.
                if let passedBoundary, dep.stopSequence < passedBoundary,
                   let ts = frame.headerTimestamp, dep.scheduledTime <= ts {
                    return restate(dep, .live, liveTime: min(dep.scheduledTime, ts))
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

    /// The stop sequence the bus is currently working toward, inferred from feed pruning: an update is
    /// dropped once the bus passes a stop, so the smallest still-published sequence is where the bus is.
    /// Nil when the trip has no predictions. 999 is a junk sentinel. This feed carries no
    /// `current_stop_sequence`, so this is the only position signal there is — the same boundary
    /// `mergeDepartures` uses to mark passed stops, exposed for "N stops away" and list trimming.
    static func busStopSequence(tripID: String, frame: RealtimeFrame?) -> Int? {
        guard let preds = frame?.predictions[tripID], !preds.isEmpty else { return nil }
        return preds.keys.map(Int.init).filter { $0 < 900 }.min()
    }

    private static func restate(_ dep: Departure, _ state: TrackingState, liveTime: Date?) -> Departure {
        Departure(
            tripID: dep.tripID, stopSequence: dep.stopSequence, routeID: dep.routeID,
            routeShortName: dep.routeShortName, routeColor: dep.routeColor, headsign: dep.headsign,
            direction: dep.direction, scheduledTime: dep.scheduledTime, liveTime: liveTime, state: state
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
    /// first departure closest to now.
    static func serviceDate(firstDeparture: Int, now: Date) -> Date {
        let today = AdelaideTZ.startOfDay(now)
        // A day back from `now`, then anchored — not a day back from the anchor. On a daylight-saving
        // changeover the two differ by an hour, which is a whole trip's worth of wrong times.
        guard let yesterday = AdelaideTZ.calendar.date(byAdding: .day, value: -1, to: now)
            .map(AdelaideTZ.startOfDay) else { return today }
        let distance = { (midnight: Date) in
            abs(midnight.addingTimeInterval(TimeInterval(firstDeparture)).timeIntervalSince(now))
        }
        return distance(yesterday) < distance(today) ? yesterday : today
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
