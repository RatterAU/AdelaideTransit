import Foundation
import Compression

/// Builds a real GTFS zip in a temp directory, so tests can drive `GTFSIngest.ingest` and `GTFSStore` over
/// the same code path the app runs rather than a hand-populated database that only resembles one.
///
/// Deliberately not a mock or a protocol seam: the interesting failures in this app are in the SQL and in
/// the file swap, and neither survives being stubbed out.
struct GTFSFixture {
    var files: [String: String] = [:]

    /// A small but complete network: two routes, a bus that continues under a second route number from a
    /// nearby bay (the 502 → 110 handover in miniature), an after-midnight trip belonging to the previous
    /// service day, and a service suppressed by a calendar exception.
    ///
    /// Coordinates are real Adelaide ones so the r-tree and the 100 m handover box behave as they do live.
    /// The one date `HOLIDAY` is cancelled on, and the day the store tests query.
    static let suppressedDate = "20250611"

    static func standard(
        calendarStart: String = "20200101", calendarEnd: String = "20991231"
    ) -> GTFSFixture {
        var fixture = GTFSFixture()
        fixture.files["stops.txt"] = """
            stop_id,stop_code,stop_name,stop_lat,stop_lon
            10001,X1,Grenfell St - Stop A1,-34.92350,138.60100
            10002,X2,Grenfell St - Stop A2,-34.92360,138.60400
            10003,X3,Currie St - Stop B1,-34.92450,138.59510
            10004,X4,"Paradise Interchange, Terminus",-34.87600,138.66500
            10005,X5,Zone I Paradise Interchange - North West,-34.87605,138.66508
            10006,X6,Quiet Suburban Stop,-34.95000,138.70000

            """
        fixture.files["routes.txt"] = """
            route_id,route_short_name,route_long_name,route_type,route_color
            R502,502,City to Paradise,3,
            R110,110,Paradise to City,3,1A6DBA
            RTRAM,TRAM,Glenelg Tram,0,FFCC00

            """
        // BLOCK1 is one bus: 502 in, 110 back out of the neighbouring bay 10 minutes later.
        // BLOCK2 is the same bus starting a new shift somewhere else entirely — a depot run, not a handover.
        fixture.files["trips.txt"] = """
            trip_id,route_id,service_id,trip_headsign,direction_id,shape_id,block_id
            T502,R502,WEEKDAY,Paradise Interchange,0,SHP1,BLOCK1
            T110,R110,WEEKDAY,City,1,SHP1,BLOCK1
            TDEPOT,R502,WEEKDAY,Depot,0,SHP1,BLOCK2
            TLATE,R502,WEEKDAY,Late Night City,0,SHP1,BLOCK3
            TSUPPRESSED,RTRAM,HOLIDAY,Glenelg,0,SHP1,BLOCK4

            """
        // T502 arrives 10004 at 09:20. T110 leaves 10005 — 8 m away, a different stop_id — at 09:30.
        // TLATE runs at 25:10, i.e. 01:10 the following morning on the previous service day.
        fixture.files["stop_times.txt"] = """
            trip_id,stop_sequence,stop_id,arrival_time,departure_time
            T502,1,10003,09:00:00,09:00:00
            T502,2,10001,09:10:00,09:10:00
            T502,3,10004,09:20:00,09:20:00
            T110,1,10005,09:30:00,09:30:00
            T110,2,10002,09:45:00,09:45:00
            TDEPOT,1,10006,09:25:00,09:25:00
            TDEPOT,2,10003,09:50:00,09:50:00
            TLATE,1,10001,25:10:00,25:10:00
            TSUPPRESSED,1,10001,,09:05:00

            """
        fixture.files["shapes.txt"] = """
            shape_id,shape_pt_sequence,shape_pt_lat,shape_pt_lon
            SHP1,1,-34.92450,138.59510
            SHP1,2,-34.92350,138.60100
            SHP1,3,-34.87600,138.66500

            """
        fixture.files["calendar.txt"] = """
            service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
            WEEKDAY,1,1,1,1,1,1,1,\(calendarStart),\(calendarEnd)
            HOLIDAY,1,1,1,1,1,1,1,\(calendarStart),\(calendarEnd)

            """
        fixture.files["calendar_dates.txt"] = """
            service_id,date,exception_type
            HOLIDAY,\(suppressedDate),2

            """
        return fixture
    }

    /// Enough rows to look like a database and far too few to be Adelaide — what `validateStagedDatabase`
    /// exists to refuse.
    static func truncated() -> GTFSFixture {
        var fixture = GTFSFixture()
        fixture.files["stops.txt"] = "stop_id,stop_code,stop_name,stop_lat,stop_lon\n1,A,One,-34.9,138.6\n"
        fixture.files["routes.txt"] = "route_id,route_short_name,route_long_name,route_type,route_color\nR,1,One,3,\n"
        fixture.files["trips.txt"] = "trip_id,route_id,service_id,trip_headsign,direction_id,shape_id,block_id\nT,R,S,H,0,,\n"
        fixture.files["stop_times.txt"] = "trip_id,stop_sequence,stop_id,arrival_time,departure_time\nT,1,1,09:00:00,09:00:00\n"
        return fixture
    }

    func write(into directory: URL, named name: String = "feed.zip") throws -> URL {
        var archive: [UInt8] = []
        var central: [UInt8] = []

        for (fileName, contents) in files.sorted(by: { $0.key < $1.key }) {
            let raw = Array(contents.utf8)
            let deflated = Self.deflate(raw)
            let offset = archive.count
            let nameBytes = Array(fileName.utf8)

            archive += Self.u32(0x0403_4b50) + Self.u16(20) + Self.u16(0) + Self.u16(8) + Self.u16(0) + Self.u16(0)
            archive += Self.u32(0) + Self.u32(UInt32(deflated.count)) + Self.u32(UInt32(raw.count))
            archive += Self.u16(UInt16(nameBytes.count)) + Self.u16(0) + nameBytes + deflated

            central += Self.u32(0x0201_4b50) + Self.u16(20) + Self.u16(20) + Self.u16(0) + Self.u16(8)
            central += Self.u16(0) + Self.u16(0)
            central += Self.u32(0) + Self.u32(UInt32(deflated.count)) + Self.u32(UInt32(raw.count))
            central += Self.u16(UInt16(nameBytes.count)) + Self.u16(0) + Self.u16(0) + Self.u16(0) + Self.u16(0)
            central += Self.u32(0) + Self.u32(UInt32(offset)) + nameBytes
        }

        let centralOffset = archive.count
        archive += central
        archive += Self.u32(0x0605_4b50) + Self.u16(0) + Self.u16(0)
        archive += Self.u16(UInt16(files.count)) + Self.u16(UInt16(files.count))
        archive += Self.u32(UInt32(central.count)) + Self.u32(UInt32(centralOffset)) + Self.u16(0)

        let url = directory.appendingPathComponent(name)
        try Data(archive).write(to: url)
        return url
    }

    /// A fresh temp directory, deleted by the caller.
    static func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gtfs-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// `COMPRESSION_ZLIB` is Apple's name for raw DEFLATE, which is exactly what a zip member holds and what
    /// `ZipReader` inflates with.
    private static func deflate(_ input: [UInt8]) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: input.count + 4096)
        let written = output.withUnsafeMutableBufferPointer { dst in
            input.withUnsafeBufferPointer { src in
                compression_encode_buffer(
                    dst.baseAddress!, dst.count, src.baseAddress!, src.count, nil, COMPRESSION_ZLIB
                )
            }
        }
        return Array(output.prefix(written))
    }

    private static func u16(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8)] }
    private static func u32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)]
    }
}
