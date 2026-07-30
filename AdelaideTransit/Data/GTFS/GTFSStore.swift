import Foundation
import GRDB
import Network

enum AdelaideTZ {
    static let timeZone = TimeZone(identifier: "Australia/Adelaide")!
    /// Built once. As a computed property this allocated a fresh `Calendar` on every access, and
    /// `Merge.serviceDate` alone touches it three times per departure query.
    static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal
    }()
    static func startOfDay(_ date: Date) -> Date { calendar.startOfDay(for: date) }
    /// Straight from components rather than a `DateFormatter`. The old version constructed a formatter per
    /// call — the expensive half of using one — inside the per-service-day loop of every departures query.
    /// It's also Sendable, which a shared `DateFormatter` is not.
    static func yyyymmdd(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

actor GTFSStore {
    static let appGroupID = "group.com.adelaidetransit.app"

    static var containerDirectory: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    static var dbURL: URL { containerDirectory.appendingPathComponent("network.sqlite") }
    /// Deliberately a separate file from `network.sqlite`, which ingest replaces wholesale.
    static var userDBURL: URL { containerDirectory.appendingPathComponent("user.sqlite") }
    static var stagingDBURL: URL { containerDirectory.appendingPathComponent("network-new.sqlite") }
    static var stagingZipURL: URL { containerDirectory.appendingPathComponent("download.zip") }

    private var dbQueue: DatabaseQueue?
    /// User-owned data, in its own file. Opened lazily and independently of the timetable: favourites must
    /// keep working even before a feed has ever been ingested, and must survive every ingest afterwards.
    private var userQueue: DatabaseQueue?
    /// Keyed by day, not a single slot. Every `departures` call resolves today *and* yesterday, so a
    /// one-entry cache was evicted by the second lookup of the very call that filled it and never hit —
    /// three calendar queries per stop sheet, every time.
    private var serviceCache: [String: Set<String>] = [:]

    /// True once a static feed has been ingested at least once (post first-launch).
    var isReady: Bool { dbQueue != nil }

    init() {
        dbQueue = try? Self.openDatabase()
    }

    private func open() throws {
        dbQueue = try Self.openDatabase()
    }

    /// Opens the database **and migrates it**.
    ///
    /// The migrator used to run in exactly one place: `GTFSIngest.ingest`, against a brand-new staging
    /// file. But re-ingest only happens when the *remote* feed changes, so a database created before a
    /// migration was written stayed on the old schema forever. `stops.importance` arrived in v2, and every
    /// device still on a v1 file failed every thinned map query outright —
    /// `no such column: s.importance` — which `loadStops`' `try?` swallowed into "no stops today".
    /// Migrating on open is the only thing that reaches an already-installed database.
    private static func openDatabase() throws -> DatabaseQueue? {
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return nil }
        var config = Configuration()
        config.readonly = false
        let queue = try DatabaseQueue(path: dbURL.path, configuration: config)
        try Schema.migrator().migrate(queue)
        return queue
    }

    /// `importance` defaults to 0, so a database migrated in place has the column but no values — and a
    /// grid cell picking `MAX(importance)` from an all-zero set picks arbitrarily. Recomputing is a
    /// GROUP BY over every stop_time, so it runs once, off the launch path, and only when needed.
    func backfillStopImportanceIfNeeded() throws {
        guard let dbQueue else { return }
        let needed = try dbQueue.read { db in
            (try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(importance), 0) FROM stops") ?? 0) == 0
        }
        guard needed else { return }
        try dbQueue.write { db in try Schema.recomputeStopImportance(db) }
    }

    /// `block_id` is the one column no backfill can compute — it exists only in the feed. The v3 migration
    /// forces a re-ingest by dropping the stored feed identity, but that heals nothing if the re-ingest
    /// itself failed (offline, Data Saver, killed mid-download): the migration has already been recorded as
    /// applied and never runs again, so `continuation` returns nil for every trip, forever, and buses that
    /// carry on under a new number look like they terminate. Re-arming the trigger is one DELETE.
    func rearmIngestIfBlocksMissing() throws {
        guard let dbQueue else { return }
        let missing = try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM trips WHERE block_id IS NOT NULL)") == 0
        }
        guard missing else { return }
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM meta WHERE key IN ('etag', 'last_modified')")
        }
    }

    // MARK: - Refresh lifecycle (§2.1)

    /// First-launch or update-check entry point. Safe to call anytime; cheap when unchanged.
    /// `allowCellular` gates only *automatic* re-ingest — first launch and a manual "Check now" (force) always proceed.
    func refreshIfNeeded(force: Bool = false, allowCellular: Bool = false) async throws {
        let storedMeta = try storedFeedMetadata()
        let firstLaunch = !isReady

        // Always ask the server who it is, even when we already know we're going to ingest.
        //
        // This used to reuse `storedMeta` on a first launch or a forced refresh — and on a first launch
        // that is *empty*, so the ingest recorded no feed identity at all. Every daily check afterwards
        // then compared a real `ETag` against nil, concluded "changed", and re-downloaded 19.7 MB and
        // rebuilt the entire database. Every day. Forever. Each rebuild also blanked the map for its
        // duration and, before `swapInStagedDatabase` learned to carry them, deleted every favourite.
        // The static feed does publish `ETag` and `Last-Modified` (unlike the realtime feeds) — the app
        // simply never stored them.
        let probe = try? await GTFSIngest.remoteFeedChanged(against: storedMeta)
        let changed: Bool
        let newMeta: GTFSIngest.FeedMetadata
        if force || firstLaunch {
            changed = true
            newMeta = probe?.meta ?? storedMeta
        } else {
            guard let probe else { return } // couldn't ask; try again next time rather than re-ingest blind
            (changed, newMeta) = probe
        }
        guard changed else { return }

        if !firstLaunch && !force && !allowCellular {
            guard await currentPathIsWiFiOrWired() else { return }
        }

        try await GTFSIngest.downloadZip(to: Self.stagingZipURL)
        // Off the actor. `ingest` is synchronous and runs for tens of seconds — parsing 1.16M stop_times and
        // writing them — and called directly it held this actor's executor for all of it, so every query the
        // UI made was queued behind the rebuild. It touches only the staging file, which nothing else has
        // opened, so there is nothing here to serialise against.
        let (zipURL, stagingURL) = (Self.stagingZipURL, Self.stagingDBURL)
        try await Task.detached(priority: .utility) {
            try GTFSIngest.ingest(zipURL: zipURL, intoDatabaseAt: stagingURL, meta: newMeta)
        }.value
        try? FileManager.default.removeItem(at: Self.stagingZipURL)

        try validateStagedDatabase()
        try swapInStagedDatabase()
    }

    struct StagedFeedRejected: Error { let detail: String }

    /// Refuse to swap in a database that cannot be a real Adelaide timetable.
    ///
    /// The swap is irreversible from the app's point of view — the previous timetable is gone and the next
    /// check will see the new feed identity as current, so a bad file would persist until Adelaide Metro
    /// published again. A truncated download or a partially-written zip is exactly the sort of thing that
    /// produces a technically-valid SQLite file with almost nothing in it. Thresholds are an order of
    /// magnitude below the real feed (9171 stops, 31379 trips, ~1.16M stop times): loose enough to survive
    /// a genuine network shrinking, tight enough that an empty or truncated build cannot get through.
    private func validateStagedDatabase() throws {
        let staged = try DatabaseQueue(path: Self.stagingDBURL.path)
        let counts = try staged.read { db in
            (stops: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM stops") ?? 0,
             trips: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM trips") ?? 0,
             stopTimes: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM stop_times") ?? 0)
        }
        try? staged.close() // see GTFSIngest.ingest — the file is moved and its sidecars deleted right after
        guard counts.stops >= 1_000, counts.trips >= 1_000, counts.stopTimes >= 100_000 else {
            try? FileManager.default.removeItem(at: Self.stagingDBURL)
            throw StagedFeedRejected(
                detail: "stops \(counts.stops), trips \(counts.trips), stop_times \(counts.stopTimes)"
            )
        }
    }

    private func swapInStagedDatabase() throws {
        // Nothing user-owned lives in this file — favourites are in `user.sqlite`, which this never
        // touches. That is the whole point of the split: the timetable database is disposable, and
        // replacing it wholesale is allowed to be exactly as destructive as it looks.
        try? dbQueue?.close() // close, don't just release — deinit timing is not a file-handle guarantee
        dbQueue = nil
        let fm = FileManager.default

        // Move the old file aside rather than deleting it, and only discard it once the new one is in
        // place. Deleting first meant a failure at exactly the wrong moment — a corrupt staging file, a
        // full disk — left the device with *no* database at all: no stops, no favourites, and the app
        // back at its first-launch download screen. The window was small, but the cost of losing it was
        // total, and a rename is free.
        let previous = Self.dbURL.appendingPathExtension("previous")
        try? fm.removeItem(at: previous)
        let hadPrevious = fm.fileExists(atPath: Self.dbURL.path)
        if hadPrevious {
            try fm.moveItem(at: Self.dbURL, to: previous)
        }
        do {
            try fm.moveItem(at: Self.stagingDBURL, to: Self.dbURL)
        } catch {
            if hadPrevious { try? fm.moveItem(at: previous, to: Self.dbURL) }
            try? open()
            throw error
        }
        try? fm.removeItem(at: previous)

        // Only the database file itself is renamed, so without this the *old* database's `-wal` and `-shm`
        // sidecars are left sitting beside the *new* file, where SQLite will try to associate them with it.
        // GRDB checkpoints on close, so in practice they are empty and SQLite rejects the mismatched
        // header — but "usually harmless" is not a property to rely on for the file the whole app reads.
        // The staging file's own sidecars are orphaned by the same rename and nothing else deletes them.
        for base in [Self.dbURL, Self.stagingDBURL] {
            for suffix in ["-wal", "-shm"] {
                try? fm.removeItem(at: URL(fileURLWithPath: base.path + suffix))
            }
        }
        try open()
        // Every cache here is keyed on data the new file may have changed. A timetable swap that left them
        // populated would serve the old feed's answers against the new database.
        serviceCache.removeAll()
        allRoutesCache = nil
        lastShape = nil
        lastStopTimes = nil
    }

    private func currentPathIsWiFiOrWired() async -> Bool {
        await withCheckedContinuation { cont in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                cont.resume(returning: !path.usesInterfaceType(.cellular))
                monitor.cancel()
            }
            monitor.start(queue: DispatchQueue.global())
        }
    }

    private func storedFeedMetadata() throws -> GTFSIngest.FeedMetadata {
        guard let dbQueue else { return .init(etag: nil, lastModified: nil) }
        return try dbQueue.read { db in
            let etag = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'etag'")
            let lastModified = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'last_modified'")
            return .init(etag: etag, lastModified: lastModified)
        }
    }

    func feedInfo() throws -> (etag: String?, lastModified: String?, ingestedAt: String?, dbSizeBytes: Int) {
        guard let dbQueue else { return (nil, nil, nil, 0) }
        let size = (try? FileManager.default.attributesOfItem(atPath: Self.dbURL.path)[.size] as? Int) ?? 0
        return try dbQueue.read { db in
            (
                try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'etag'"),
                try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'last_modified'"),
                try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'ingested_at'"),
                size
            )
        }
    }

    // MARK: - Active service resolution

    private func activeServiceIDs(on date: Date) throws -> Set<String> {
        let key = AdelaideTZ.yyyymmdd(date)
        if let cached = serviceCache[key] { return cached }
        guard let dbQueue else { return [] }

        let weekday = AdelaideTZ.calendar.component(.weekday, from: date) // 1 = Sunday
        let columns = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        let column = columns[weekday - 1]
        let ymd = AdelaideTZ.yyyymmdd(date)

        let ids: Set<String> = try dbQueue.read { db in
            var set = Set<String>()
            let base = try String.fetchAll(db, sql: """
                SELECT service_id FROM calendar
                WHERE \(column) = 1 AND start_date <= ? AND end_date >= ?
                """, arguments: [ymd, ymd])
            set.formUnion(base)

            let added = try String.fetchAll(db, sql: "SELECT service_id FROM calendar_dates WHERE date = ? AND exception_type = 1", arguments: [ymd])
            set.formUnion(added)
            let removed = try String.fetchAll(db, sql: "SELECT service_id FROM calendar_dates WHERE date = ? AND exception_type = 2", arguments: [ymd])
            set.subtract(removed)
            return set
        }
        serviceCache[key] = ids
        return ids
    }

    // MARK: - Core queries (§3)

    /// Stops in a box, thinned to at most one per `cell`-sized grid square — the most important one in each.
    ///
    /// This replaces map clustering. Clustering cost more than it saved: MapKit re-partitions on every
    /// region change, so a pan is a continuous stream of annotation merges and splits, each destroying and
    /// rebuilding views. Thinning at query time instead means the annotation count is bounded by the number
    /// of grid cells on screen — roughly constant at every zoom — and panning adds no work at all.
    ///
    /// The grid is anchored to absolute coordinates, not the viewport, so a given cell always resolves to
    /// the same stop. Were it viewport-relative, panning would reshuffle which stop each cell picked and
    /// reintroduce exactly the churn this exists to avoid.
    ///
    /// `cell == 0` disables thinning (used where the caller knows the set is already small).
    func stopsIn(
        minLat: Double, maxLat: Double, minLon: Double, maxLon: Double,
        cell: Double = 0, limit: Int = 1200
    ) throws -> [StopSummary] {
        guard let dbQueue else { return [] }
        let bbox = "r.min_lat <= ? AND r.max_lat >= ? AND r.min_lon <= ? AND r.max_lon >= ?"
        let bounds: [any DatabaseValueConvertible] = [maxLat, minLat, maxLon, minLon]

        return try dbQueue.read { db in
            let rows: [Row]
            if cell > 0 {
                // SQLite picks the bare columns from the row that produced MAX(importance), so each cell
                // yields its best-connected stop rather than an arbitrary member.
                rows = try Row.fetchAll(db, sql: """
                    SELECT s.id, s.code, s.name, s.lat, s.lon, MAX(s.importance) FROM stops s
                    JOIN stops_rtree r ON r.id = s.id
                    WHERE \(bbox)
                    GROUP BY CAST(s.lat / ? AS INTEGER), CAST(s.lon / ? AS INTEGER)
                    LIMIT ?
                    """, arguments: StatementArguments(bounds + [cell, cell, limit]))
            } else {
                rows = try Row.fetchAll(db, sql: """
                    SELECT s.id, s.code, s.name, s.lat, s.lon FROM stops s
                    JOIN stops_rtree r ON r.id = s.id
                    WHERE \(bbox)
                    LIMIT ?
                    """, arguments: StatementArguments(bounds + [limit]))
            }
            return rows.map {
                StopSummary(id: $0["id"], code: $0["code"], name: $0["name"], lat: $0["lat"], lon: $0["lon"])
            }
        }
    }

    /// Cached: the route table changes only on a feed swap (which clears this), but Map, Settings and Alerts
    /// each load the whole thing on appear — three full-table reads of the same few hundred rows otherwise.
    private var allRoutesCache: [String: (shortName: String, longName: String, color: String?, type: Int)]?

    func allRoutes() throws -> [String: (shortName: String, longName: String, color: String?, type: Int)] {
        if let allRoutesCache { return allRoutesCache }
        guard let dbQueue else { return [:] }
        let result = try dbQueue.read { db in
            var result: [String: (shortName: String, longName: String, color: String?, type: Int)] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, short_name, long_name, color, type FROM routes") {
                result[row["id"]] = (
                    shortName: row["short_name"] ?? "", longName: row["long_name"] ?? "",
                    color: row["color"], type: row["type"]
                )
            }
            return result
        }
        allRoutesCache = result
        return result
    }

    func searchStops(matching query: String) throws -> [StopSummary] {
        guard let dbQueue, !query.isEmpty else { return [] }
        let pattern = "%\(query)%"
        return try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, code, name, lat, lon FROM stops
                WHERE name LIKE ? OR code LIKE ? LIMIT 30
                """, arguments: [pattern, pattern])
                .map { StopSummary(id: $0["id"], code: $0["code"], name: $0["name"], lat: $0["lat"], lon: $0["lon"]) }
        }
    }

    /// Scheduled departures at a stop within [from, from+window], across the two service-days
    /// that can produce wall-clock times in that window (today's, and yesterday's after-midnight trips).
    func departures(stopID: String, from: Date, window: TimeInterval = 90 * 60) throws -> [Departure] {
        guard let dbQueue else { return [] }
        let to = from.addingTimeInterval(window)

        var results: [Departure] = []
        for daysAgo in [0, 1] {
            let serviceDate = AdelaideTZ.calendar.date(byAdding: .day, value: -daysAgo, to: AdelaideTZ.startOfDay(from))!
            let serviceIDs = try activeServiceIDs(on: serviceDate)
            guard !serviceIDs.isEmpty else { continue }
            let placeholders = serviceIDs.map { _ in "?" }.joined(separator: ",")
            // Bound the scan to the window in SQL. Without this every call read *every* departure of the
            // whole service day at this stop — the busiest stop is served by 62 routes — joined trips and
            // routes for all of them, then threw almost all of it away in Swift. `st_stop(stop_id, dep)`
            // makes the bounded version an index range scan. Rounded outward so the exact Swift-side
            // comparison below still owns the boundary.
            let lo = Int(from.timeIntervalSince(serviceDate).rounded(.down))
            let hi = Int(to.timeIntervalSince(serviceDate).rounded(.up))
            guard hi >= 0 else { continue }

            let rows = try dbQueue.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT st.trip_id, st.seq, st.arr, st.dep, t.route_id, t.headsign, t.direction,
                           r.short_name, r.color
                    FROM stop_times st
                    JOIN trips t ON t.id = st.trip_id
                    JOIN routes r ON r.id = t.route_id
                    WHERE st.stop_id = ? AND st.dep BETWEEN ? AND ? AND t.service_id IN (\(placeholders))
                    ORDER BY st.dep
                    """, arguments: StatementArguments(
                        [stopID, lo, hi] as [any DatabaseValueConvertible] + Array(serviceIDs)
                    ))
            }

            for row in rows {
                let depSeconds: Int = row["dep"]
                let wallClock = serviceDate.addingTimeInterval(TimeInterval(depSeconds))
                guard wallClock >= from, wallClock <= to else { continue }
                results.append(Departure(
                    tripID: row["trip_id"], stopSequence: row["seq"], routeID: row["route_id"],
                    routeShortName: row["short_name"] ?? "", routeColor: row["color"],
                    headsign: row["headsign"] ?? "", direction: row["direction"],
                    scheduledTime: wallClock, liveTime: nil, state: .scheduled
                ))
            }
        }
        return results.sorted { $0.scheduledTime < $1.scheduledTime }
    }

    func tripInfo(tripID: String) throws -> (routeID: String, shortName: String, color: String?, headsign: String, shapeID: String?)? {
        guard let dbQueue else { return nil }
        return try dbQueue.read { db in
            try Row.fetchOne(db, sql: """
                SELECT t.route_id, r.short_name, r.color, t.headsign, t.shape_id
                FROM trips t JOIN routes r ON r.id = t.route_id
                WHERE t.id = ?
                """, arguments: [tripID])
                .map { (routeID: $0["route_id"], shortName: $0["short_name"] ?? "", color: $0["color"], headsign: $0["headsign"] ?? "", shapeID: $0["shape_id"]) }
        }
    }

    /// One slot, for the same reason as `shape`: opening a trip loads it from `MapScreen` and from
    /// `TripDetailSheet` back to back, for the same tripID.
    private var lastStopTimes: (tripID: String, rows: [(seq: Int, stopID: String, name: String, lat: Double, lon: Double, dep: Int)])?

    func allStopTimes(tripID: String) throws -> [(seq: Int, stopID: String, name: String, lat: Double, lon: Double, dep: Int)] {
        guard let dbQueue else { return [] }
        if let lastStopTimes, lastStopTimes.tripID == tripID { return lastStopTimes.rows }
        let rows = try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT st.seq, st.stop_id, s.name, s.lat, s.lon, st.dep FROM stop_times st
                JOIN stops s ON s.id = st.stop_id
                WHERE st.trip_id = ? ORDER BY st.seq
                """, arguments: [tripID])
                .map { (seq: $0["seq"] as Int, stopID: $0["stop_id"] as String, name: $0["name"] as String,
                        lat: $0["lat"] as Double, lon: $0["lon"] as Double, dep: $0["dep"] as Int) }
        }
        lastStopTimes = (tripID, rows)
        return rows
    }

    /// One slot, because exactly one trip is open at a time and two views ask for it.
    ///
    /// Tapping a bus loads the same shape twice within a frame or two — `MapScreen.loadTripContext` draws
    /// the polyline, `TripDetailSheet.load` drives the mini map and the ghost. Shapes run to thousands of
    /// rows, so that was two full reads and two array builds for one tap. Unlike `activeServiceIDs`, a
    /// single slot is right here: both callers ask for the *same* tripID, so the second is always a hit.
    private var lastShape: (tripID: String, points: [(lat: Double, lon: Double, dist: Double?)])?

    func shape(tripID: String) throws -> [(lat: Double, lon: Double, dist: Double?)] {
        guard let dbQueue else { return [] }
        if let lastShape, lastShape.tripID == tripID { return lastShape.points }
        let shapeID = try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT shape_id FROM trips WHERE id = ?", arguments: [tripID])
        }
        guard let shapeID, !shapeID.isEmpty else { return [] }
        let points = try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT lat, lon, dist FROM shapes WHERE shape_id = ? ORDER BY seq", arguments: [shapeID])
                .map { (lat: $0["lat"] as Double, lon: $0["lon"] as Double, dist: $0["dist"] as Double?) }
        }
        lastShape = (tripID, points)
        return points
    }

    /// The trip this one becomes: same vehicle, new route number, no change for the passenger.
    ///
    /// Measured against the live feed: 27.8% of blocks span more than one route, and the 502 → 110 handover
    /// at Stop S1 Grenfell St is one of 54 such blocks. But a block is a *whole day* of one bus's work, so
    /// "same block" alone is not enough — 14645 of 22985 consecutive pairs start somewhere other than where
    /// the previous trip ended, and those are runs to the depot or the start of a new shift. Requiring the
    /// next trip to begin where this one ended is what separates "stay on the bus" from "the bus goes to the
    /// depot now".
    ///
    /// **"Where it ended" is a place, not a `stop_id`.** Matching stop IDs exactly found 8004 handovers and
    /// missed 6954 more, because an interchange is many stops: the 273 arrives at "Paradise Interchange
    /// Terminus" and leaves from "Zone I Paradise Interchange - North West side" 74 m away, a J2 crosses
    /// Harbour Town from Zone A to Zone B, and a turnaround swaps to the other side of the same road. Those
    /// are the services that appeared to stop abruptly mid-route. 100 m covers all of them and is far short
    /// of the next stop along any route.
    ///
    /// The 20-minute layover bound covers 7888 of 8340 same-stop handovers; beyond that you would get off
    /// and wait rather than sit on a parked bus.
    func continuation(after tripID: String) throws -> (
        tripID: String, routeID: String, shortName: String, color: String?, headsign: String,
        departure: Int, startsAtSameStop: Bool
    )? {
        guard let dbQueue else { return nil }
        return try dbQueue.read { db in
            guard let current = try Row.fetchOne(db, sql: """
                SELECT t.block_id, t.service_id, s.lat AS last_lat, s.lon AS last_lon,
                       st.stop_id AS last_stop, st.arr AS last_arr
                FROM trips t
                JOIN stop_times st ON st.trip_id = t.id
                JOIN stops s ON s.id = st.stop_id
                WHERE t.id = ? AND st.seq = (SELECT MAX(s2.seq) FROM stop_times s2 WHERE s2.trip_id = t.id)
                """, arguments: [tripID]),
                let blockID: String = current["block_id"],
                let lastStop: String = current["last_stop"],
                let lastArr: Int = current["last_arr"]
            else { return nil }

            let lat: Double = current["last_lat"], lon: Double = current["last_lon"]
            // Degrees, not metres: a box beats a haversine here and 100 m is small enough that the
            // latitude-scaled longitude term is a constant at Adelaide's -34.9°.
            let dLat = Self.handoverRadiusMetres / 110_540
            let dLon = Self.handoverRadiusMetres / (111_320 * cos(lat * .pi / 180))

            return try Row.fetchOne(db, sql: """
                SELECT t.id, t.route_id, r.short_name, r.color, t.headsign, st.dep, st.stop_id
                FROM trips t
                JOIN routes r ON r.id = t.route_id
                JOIN stop_times st ON st.trip_id = t.id
                JOIN stops s ON s.id = st.stop_id
                WHERE t.block_id = ? AND t.service_id = ? AND t.id <> ?
                  AND st.seq = (SELECT MIN(s2.seq) FROM stop_times s2 WHERE s2.trip_id = t.id)
                  AND st.dep >= ? AND st.dep <= ?
                  AND s.lat BETWEEN ? AND ? AND s.lon BETWEEN ? AND ?
                ORDER BY st.dep
                LIMIT 1
                """, arguments: [
                    blockID, current["service_id"] as String, tripID,
                    lastArr, lastArr + Self.maxLayoverSeconds,
                    lat - dLat, lat + dLat, lon - dLon, lon + dLon
                ])
                .map { (
                    tripID: $0["id"], routeID: $0["route_id"], shortName: $0["short_name"] ?? "",
                    color: $0["color"], headsign: $0["headsign"] ?? "", departure: $0["dep"],
                    startsAtSameStop: ($0["stop_id"] as String) == lastStop
                ) }
        }
    }

    /// Every other trip the same vehicle works today.
    ///
    /// Positions are published against the trip a bus is running *right now*, so a trip that hasn't started
    /// has no vehicle of its own even when its bus is out there and reporting — it's still finishing the
    /// previous run under that run's trip ID. The block is the link: one vehicle, one day's work. Deliberately
    /// the whole block rather than `continuation`'s strict handover test — here we're not claiming "stay on
    /// the bus", only "this is the vehicle that will turn up", which holds across a depot run too.
    func blockmates(of tripID: String) throws -> [String] {
        guard let dbQueue else { return [] }
        return try dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT other.id FROM trips t
                JOIN trips other ON other.block_id = t.block_id AND other.service_id = t.service_id
                WHERE t.id = ? AND other.id <> ? AND t.block_id IS NOT NULL
                """, arguments: [tripID, tripID])
        }
    }

    private static let maxLayoverSeconds = 20 * 60
    private static let handoverRadiusMetres = 100.0

    // MARK: - Favourites

    /// Opens `user.sqlite`, migrating it and — once — rescuing anything still in the old location.
    ///
    /// Existing installs have their favourites inside the timetable database. The adoption below moves them
    /// across the first time this runs and then drops the old table, so there is exactly one home for them
    /// afterwards and no ambiguity about which copy is authoritative.
    private func user() throws -> DatabaseQueue {
        if let userQueue { return userQueue }
        let queue = try DatabaseQueue(path: Self.userDBURL.path)
        try Schema.userMigrator().migrate(queue)
        userQueue = queue
        try? adoptLegacyFavourites(into: queue)
        return queue
    }

    private func adoptLegacyFavourites(into queue: DatabaseQueue) throws {
        guard let dbQueue else { return }
        let alreadyHasSome = try queue.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM favourites") ?? 0) > 0
        }
        guard !alreadyHasSome else { return }

        let legacy = try dbQueue.read { db -> [Row] in
            guard try db.tableExists("favourites") else { return [] }
            return try Row.fetchAll(db, sql: "SELECT stop_id, route_id, label, sort, grp FROM favourites ORDER BY sort")
        }
        guard !legacy.isEmpty else { return }

        try queue.write { db in
            for row in legacy {
                try db.execute(
                    sql: "INSERT INTO favourites(stop_id, route_id, label, sort, grp) VALUES (?, ?, ?, ?, ?)",
                    arguments: [row["stop_id"], row["route_id"], row["label"], row["sort"], row["grp"]]
                )
            }
        }
        try? dbQueue.write { db in try db.execute(sql: "DROP TABLE IF EXISTS favourites") }
    }

    /// Favourites come from the user database, stop details from the timetable — so the join that used to
    /// be one SQL statement is now done in memory. That is the right trade at this size: favourites are a
    /// handful of rows, and the alternative (`ATTACH`) would couple the two files back together at exactly
    /// the seam this split exists to keep apart.
    ///
    /// A favourite whose stop no longer exists in the current feed is skipped rather than dropped from
    /// storage: the stop may well return in the next timetable, and deleting user data because a feed
    /// momentarily disagrees is how favourites vanish.
    func favourites() throws -> [(id: Int64, stopID: String, stopName: String, routeID: String?, label: String?, group: String?, lat: Double, lon: Double)] {
        let rows = try user().read { db in
            try Row.fetchAll(db, sql: "SELECT id, stop_id, route_id, label, grp FROM favourites ORDER BY sort")
        }
        guard !rows.isEmpty, let dbQueue else { return [] }

        let ids = rows.map { $0["stop_id"] as String }
        let stops = try dbQueue.read { db -> [String: (name: String, lat: Double, lon: Double)] in
            let placeholders = databaseQuestionMarks(count: ids.count)
            return try Row.fetchAll(
                db, sql: "SELECT id, name, lat, lon FROM stops WHERE id IN (\(placeholders))",
                arguments: StatementArguments(ids)
            ).reduce(into: [:]) { acc, row in
                acc[row["id"] as String] = (name: row["name"], lat: row["lat"], lon: row["lon"])
            }
        }

        return rows.compactMap { row in
            let stopID: String = row["stop_id"]
            guard let stop = stops[stopID] else { return nil }
            return (id: row["id"], stopID: stopID, stopName: stop.name, routeID: row["route_id"],
                    label: row["label"], group: row["grp"], lat: stop.lat, lon: stop.lon)
        }
    }

    func updateFavouriteLabel(id: Int64, label: String) throws {
        try user().write { db in
            try db.execute(sql: "UPDATE favourites SET label = ? WHERE id = ?", arguments: [label, id])
        }
    }

    func stopSummary(id: String) throws -> StopSummary? {
        guard let dbQueue else { return nil }
        return try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT id, code, name, lat, lon FROM stops WHERE id = ?", arguments: [id])
                .map { StopSummary(id: $0["id"], code: $0["code"], name: $0["name"], lat: $0["lat"], lon: $0["lon"]) }
        }
    }

    func addFavourite(stopID: String, routeID: String?, label: String?, group: String?) throws {
        try user().write { db in
            try db.execute(sql: "INSERT INTO favourites(stop_id, route_id, label, grp) VALUES (?, ?, ?, ?)",
                            arguments: [stopID, routeID, label, group])
        }
    }

    func removeFavourite(id: Int64) throws {
        try user().write { db in try db.execute(sql: "DELETE FROM favourites WHERE id = ?", arguments: [id]) }
    }
}

/// `?, ?, ?` for an `IN` clause. Building it by hand is how a bound query turns into string interpolation
/// and stops being a bound query.
private func databaseQuestionMarks(count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ", ")
}
