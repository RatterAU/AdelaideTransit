import Foundation
import GRDB

/// Byte-level CSV reader — no full-file String, no third-party dependency.
/// GTFS text is UTF-8 CSV per spec (RFC4180-style quoting for fields with commas).
struct CSVReader: Sequence, IteratorProtocol {
    private let bytes: [UInt8]
    private var index: Int = 0
    let header: [String]
    let columnIndex: [String: Int]

    init(data: Data) {
        bytes = [UInt8](data)
        var i = 0
        header = Self.readRow(bytes, &i) ?? []
        index = i
        var map: [String: Int] = [:]
        for (n, name) in header.enumerated() { map[name] = n }
        columnIndex = map
    }

    mutating func next() -> [String]? {
        Self.readRow(bytes, &index)
    }

    subscript(row: [String], column: String) -> String {
        guard let i = columnIndex[column], i < row.count else { return "" }
        return row[i]
    }

    private static func readRow(_ bytes: [UInt8], _ index: inout Int) -> [String]? {
        guard index < bytes.count else { return nil }
        var fields: [String] = []
        var field: [UInt8] = []
        var inQuotes = false
        while index < bytes.count {
            let b = bytes[index]
            if inQuotes {
                if b == 0x22 {
                    if index + 1 < bytes.count, bytes[index + 1] == 0x22 {
                        field.append(0x22); index += 2
                    } else {
                        inQuotes = false; index += 1
                    }
                } else {
                    field.append(b); index += 1
                }
                continue
            }
            switch b {
            case 0x22: inQuotes = true; index += 1
            case 0x2C:
                fields.append(String(decoding: field, as: UTF8.self))
                field.removeAll(keepingCapacity: true)
                index += 1
            case 0x0D:
                index += 1
            case 0x0A:
                index += 1
                fields.append(String(decoding: field, as: UTF8.self))
                return fields
            default:
                field.append(b); index += 1
            }
        }
        fields.append(String(decoding: field, as: UTF8.self))
        return fields
    }
}

enum GTFSTime {
    /// "HH:MM:SS" (hours may exceed 23 for after-midnight trips) -> seconds since service midnight.
    static func seconds(_ hms: String) -> Int? {
        let parts = hms.split(separator: ":")
        guard parts.count == 3,
              let h = Int(parts[0]), let m = Int(parts[1]), let s = Int(parts[2]) else { return nil }
        return h * 3600 + m * 60 + s
    }
}

enum GTFSIngest {
    struct FeedMetadata: Sendable {
        let etag: String?
        let lastModified: String?
    }

    static let staticFeedURL = URL(string: "https://gtfs.adelaidemetro.com.au/v1/static/latest/google_transit.zip")!

    /// Cheap conditional check: a HEAD request, ~300 bytes, no body download.
    static func remoteFeedChanged(against stored: FeedMetadata) async throws -> (changed: Bool, meta: FeedMetadata) {
        var request = URLRequest(url: staticFeedURL)
        request.httpMethod = "HEAD"
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return (true, stored) }
        let etag = http.value(forHTTPHeaderField: "ETag")
        let lastModified = http.value(forHTTPHeaderField: "Last-Modified")
        let unchanged = etag != nil && etag == stored.etag
            || (etag == nil && lastModified != nil && lastModified == stored.lastModified)
        return (!unchanged, FeedMetadata(etag: etag, lastModified: lastModified))
    }

    /// Returns the feed identity carried by the download itself.
    ///
    /// The `HEAD` probe is the usual source of it, but the probe can fail where the download succeeds — a
    /// proxy that rejects `HEAD`, a flaky first launch — and an ingest recorded with no identity makes every
    /// later daily check compare a real `ETag` against nil, conclude "changed", and rebuild the whole
    /// database. Every day, forever. The response to the request we already made carries the same headers.
    @discardableResult
    static func downloadZip(to destination: URL) async throws -> FeedMetadata {
        let (tempURL, response) = try await URLSession.shared.download(from: staticFeedURL)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)
        let http = response as? HTTPURLResponse
        return FeedMetadata(
            etag: http?.value(forHTTPHeaderField: "ETag"),
            lastModified: http?.value(forHTTPHeaderField: "Last-Modified")
        )
    }

    /// Streaming ingest of one static GTFS zip into a fresh database file.
    /// Runs off-main; caller is responsible for atomically swapping the file in afterward.
    static func ingest(zipURL: URL, intoDatabaseAt dbURL: URL, meta: FeedMetadata) throws {
        // Sidecars too: deleting only the database leaves the previous attempt's `-wal`/`-shm` beside the
        // new file, where SQLite tries to associate them with it.
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: dbURL.path + suffix))
        }
        let zip = try ZipReader(fileURL: zipURL)

        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL")
            try db.execute(sql: "PRAGMA synchronous=NORMAL")
        }
        let dbQueue = try DatabaseQueue(path: dbURL.path, configuration: config)
        let migrator = Schema.migrator()
        try migrator.migrate(dbQueue)

        try ingestStops(zip, dbQueue)
        try ingestRoutes(zip, dbQueue)
        try ingestTrips(zip, dbQueue)
        try ingestStopTimes(zip, dbQueue)
        try ingestShapes(zip, dbQueue)
        try ingestCalendar(zip, dbQueue)
        try ingestCalendarDates(zip, dbQueue)
        try dbQueue.write { db in try Schema.recomputeStopImportance(db) }

        try dbQueue.write { db in
            if let etag = meta.etag {
                try db.execute(sql: "INSERT OR REPLACE INTO meta(key, value) VALUES('etag', ?)", arguments: [etag])
            }
            if let lastModified = meta.lastModified {
                try db.execute(sql: "INSERT OR REPLACE INTO meta(key, value) VALUES('last_modified', ?)", arguments: [lastModified])
            }
            try db.execute(sql: "INSERT OR REPLACE INTO meta(key, value) VALUES('ingested_at', ?)",
                            arguments: [ISO8601DateFormatter().string(from: Date())])
        }

        try verify(dbQueue)
        // Close explicitly rather than leaving it to deinit. The caller validates this file, moves it, and
        // deletes its sidecars; any fd still open when that happens is an unlinked-vnode-in-use violation,
        // which SQLite reports on the *next* access as a bare "disk I/O error" (code 10).
        try? dbQueue.close()
    }

    private static func verify(_ dbQueue: DatabaseQueue) throws {
        let stopCount = try dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM stops") } ?? 0
        guard stopCount > 100 else {
            throw NSError(domain: "GTFSIngest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Ingest verification failed: only \(stopCount) stops"])
        }
    }

    // MARK: - Per-table ingest

    private static func ingestStops(_ zip: ZipReader, _ dbQueue: DatabaseQueue) throws {
        var csv = CSVReader(data: try zip.extract("stops.txt"))
        try dbQueue.write { db in
            let stmt = try db.makeStatement(sql: "INSERT INTO stops(id, code, name, lat, lon) VALUES (?, ?, ?, ?, ?)")
            let rtreeStmt = try db.makeStatement(sql: "INSERT INTO stops_rtree(id, min_lat, max_lat, min_lon, max_lon) VALUES (?, ?, ?, ?, ?)")
            while let row = csv.next() {
                let id = csv[row, "stop_id"]
                guard !id.isEmpty else { continue }
                let lat = Double(csv[row, "stop_lat"]) ?? 0
                let lon = Double(csv[row, "stop_lon"]) ?? 0
                try stmt.execute(arguments: [id, csv[row, "stop_code"], csv[row, "stop_name"], lat, lon])
                try rtreeStmt.execute(arguments: [id, lat, lat, lon, lon])
            }
        }
    }

    private static func ingestRoutes(_ zip: ZipReader, _ dbQueue: DatabaseQueue) throws {
        var csv = CSVReader(data: try zip.extract("routes.txt"))
        try dbQueue.write { db in
            let stmt = try db.makeStatement(sql: "INSERT INTO routes(id, short_name, long_name, type, color) VALUES (?, ?, ?, ?, ?)")
            while let row = csv.next() {
                let id = csv[row, "route_id"]
                guard !id.isEmpty else { continue }
                try stmt.execute(arguments: [
                    id, csv[row, "route_short_name"], csv[row, "route_long_name"],
                    Int(csv[row, "route_type"]) ?? 3, csv[row, "route_color"]
                ])
            }
        }
    }

    private static func ingestTrips(_ zip: ZipReader, _ dbQueue: DatabaseQueue) throws {
        var csv = CSVReader(data: try zip.extract("trips.txt"))
        try dbQueue.write { db in
            let stmt = try db.makeStatement(sql: "INSERT INTO trips(id, route_id, service_id, headsign, direction, shape_id, block_id) VALUES (?, ?, ?, ?, ?, ?, ?)")
            while let row = csv.next() {
                let id = csv[row, "trip_id"]
                guard !id.isEmpty else { continue }
                let directionRaw = csv[row, "direction_id"]
                let blockID = csv[row, "block_id"]
                try stmt.execute(arguments: [
                    id, csv[row, "route_id"], csv[row, "service_id"], csv[row, "trip_headsign"],
                    directionRaw.isEmpty ? nil : Int(directionRaw), csv[row, "shape_id"],
                    blockID.isEmpty ? nil : blockID
                ])
            }
        }
    }

    private static func ingestStopTimes(_ zip: ZipReader, _ dbQueue: DatabaseQueue) throws {
        var csv = CSVReader(data: try zip.extract("stop_times.txt"))
        try dbQueue.write { db in
            let stmt = try db.makeStatement(sql: "INSERT INTO stop_times(trip_id, seq, stop_id, arr, dep) VALUES (?, ?, ?, ?, ?)")
            while let row = csv.next() {
                let tripID = csv[row, "trip_id"]
                guard !tripID.isEmpty else { continue }
                let arr = GTFSTime.seconds(csv[row, "arrival_time"])
                let dep = GTFSTime.seconds(csv[row, "departure_time"]) ?? arr
                guard let arrival = arr, let departure = dep else { continue }
                try stmt.execute(arguments: [
                    tripID, Int(csv[row, "stop_sequence"]) ?? 0, csv[row, "stop_id"], arrival, departure
                ])
            }
        }
    }

    private static func ingestShapes(_ zip: ZipReader, _ dbQueue: DatabaseQueue) throws {
        guard let data = try? zip.extract("shapes.txt") else { return }
        var csv = CSVReader(data: data)
        try dbQueue.write { db in
            let stmt = try db.makeStatement(sql: "INSERT INTO shapes(shape_id, seq, lat, lon, dist) VALUES (?, ?, ?, ?, ?)")
            while let row = csv.next() {
                let shapeID = csv[row, "shape_id"]
                guard !shapeID.isEmpty else { continue }
                let distRaw = csv[row, "shape_dist_traveled"]
                try stmt.execute(arguments: [
                    shapeID, Int(csv[row, "shape_pt_sequence"]) ?? 0,
                    Double(csv[row, "shape_pt_lat"]) ?? 0, Double(csv[row, "shape_pt_lon"]) ?? 0,
                    distRaw.isEmpty ? nil : Double(distRaw)
                ])
            }
        }
    }

    private static func ingestCalendar(_ zip: ZipReader, _ dbQueue: DatabaseQueue) throws {
        guard let data = try? zip.extract("calendar.txt") else { return }
        var csv = CSVReader(data: data)
        try dbQueue.write { db in
            let stmt = try db.makeStatement(sql: """
                INSERT INTO calendar(service_id, monday, tuesday, wednesday, thursday, friday, saturday, sunday, start_date, end_date)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            while let row = csv.next() {
                let id = csv[row, "service_id"]
                guard !id.isEmpty else { continue }
                try stmt.execute(arguments: [
                    id,
                    Int(csv[row, "monday"]) ?? 0, Int(csv[row, "tuesday"]) ?? 0, Int(csv[row, "wednesday"]) ?? 0,
                    Int(csv[row, "thursday"]) ?? 0, Int(csv[row, "friday"]) ?? 0, Int(csv[row, "saturday"]) ?? 0,
                    Int(csv[row, "sunday"]) ?? 0, csv[row, "start_date"], csv[row, "end_date"]
                ])
            }
        }
    }

    private static func ingestCalendarDates(_ zip: ZipReader, _ dbQueue: DatabaseQueue) throws {
        guard let data = try? zip.extract("calendar_dates.txt") else { return }
        var csv = CSVReader(data: data)
        try dbQueue.write { db in
            let stmt = try db.makeStatement(sql: "INSERT INTO calendar_dates(service_id, date, exception_type) VALUES (?, ?, ?)")
            while let row = csv.next() {
                let id = csv[row, "service_id"]
                guard !id.isEmpty else { continue }
                try stmt.execute(arguments: [id, csv[row, "date"], Int(csv[row, "exception_type"]) ?? 0])
            }
        }
    }
}
