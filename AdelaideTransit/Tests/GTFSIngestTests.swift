import Foundation
import Compression
import Testing
@testable import AdelaideTransit

/// The zip reader inflates straight out of the memory-mapped archive, by pointer, and everything the app
/// knows comes through it — a wrong offset here is not a bad stop, it is no timetable at all. There was no
/// test on it, so this builds a real archive and reads it back.
struct ZipReaderTests {
    @Test func readsADeflatedMemberBackByteForByte() throws {
        // Long enough that deflate actually compresses, and repetitive enough that it does so heavily —
        // which is what makes the compressed range shorter than the entry and the offset arithmetic matter.
        let text = String(repeating: "stop_id,stop_name,stop_lat,stop_lon\n8010,Currie St,-34.9245,138.5951\n", count: 400)
        let url = try makeZip(entries: ["stops.txt": Array(text.utf8)])
        defer { try? FileManager.default.removeItem(at: url) }

        let bytes = try ZipReader(fileURL: url).extract("stops.txt")
        #expect(String(decoding: bytes, as: UTF8.self) == text)
    }

    /// Two members, so the second one's local header offset is non-zero — the case a base-pointer mistake
    /// would read straight past.
    @Test func readsTheSecondMemberFromItsOwnOffset() throws {
        let first = Array(String(repeating: "a,b,c\n", count: 300).utf8)
        let second = Array(String(repeating: "trip_id,seq\n99,1\n", count: 300).utf8)
        let url = try makeZip(entries: ["routes.txt": first, "stop_times.txt": second])
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = try ZipReader(fileURL: url)
        #expect(try reader.extract("routes.txt") == first)
        #expect(try reader.extract("stop_times.txt") == second)
    }

    @Test func reportsAMissingMember() throws {
        let url = try makeZip(entries: ["stops.txt": Array("x".utf8)])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: ZipError.self) { try ZipReader(fileURL: url).extract("calendar.txt") }
    }

    // MARK: - Minimal zip writer (test-only)

    /// Deflate + the three record types the reader parses. `COMPRESSION_ZLIB` is Apple's name for raw
    /// DEFLATE, which is exactly what a zip member holds — the same constant the reader inflates with.
    private func makeZip(entries: [String: [UInt8]]) throws -> URL {
        var archive: [UInt8] = []
        var directory: [UInt8] = []

        for (name, contents) in entries.sorted(by: { $0.key < $1.key }) {
            let deflated = deflate(contents)
            let localOffset = archive.count
            let nameBytes = Array(name.utf8)

            archive += u32(0x0403_4b50) + u16(20) + u16(0) + u16(8) + u16(0) + u16(0)
            archive += u32(0) + u32(UInt32(deflated.count)) + u32(UInt32(contents.count))
            archive += u16(UInt16(nameBytes.count)) + u16(0) + nameBytes + deflated

            directory += u32(0x0201_4b50) + u16(20) + u16(20) + u16(0) + u16(8) + u16(0) + u16(0)
            directory += u32(0) + u32(UInt32(deflated.count)) + u32(UInt32(contents.count))
            directory += u16(UInt16(nameBytes.count)) + u16(0) + u16(0) + u16(0) + u16(0)
            directory += u32(0) + u32(UInt32(localOffset)) + nameBytes
        }

        let directoryOffset = archive.count
        archive += directory
        archive += u32(0x0605_4b50) + u16(0) + u16(0)
        archive += u16(UInt16(entries.count)) + u16(UInt16(entries.count))
        archive += u32(UInt32(directory.count)) + u32(UInt32(directoryOffset)) + u16(0)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ziptest-\(UUID().uuidString).zip")
        try Data(archive).write(to: url)
        return url
    }

    private func deflate(_ input: [UInt8]) -> [UInt8] {
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

    private func u16(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8)] }
    private func u32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)]
    }
}

/// The CSV reader is what turns those bytes into rows, and it is hand-written against GTFS's quoting rules.
struct CSVReaderTests {
    private func rows(_ text: String) -> (header: [String], rows: [[String]]) {
        var csv = CSVReader(bytes: Array(text.utf8))
        var out: [[String]] = []
        while let row = csv.next() { out.append(row) }
        return (csv.header, out)
    }

    @Test func readsQuotedFieldsContainingCommasAndQuotes() {
        let (header, body) = rows("a,b,c\n1,\"Grenfell St, Stop A1\",\"say \"\"hi\"\"\"\n")
        #expect(header == ["a", "b", "c"])
        #expect(body == [["1", "Grenfell St, Stop A1", "say \"hi\""]])
    }

    @Test func handlesCRLFAndAFinalRowWithoutANewline() {
        let (_, body) = rows("a,b\r\n1,2\r\n3,4")
        #expect(body == [["1", "2"], ["3", "4"]])
    }

    /// A short row must not read a neighbouring column's value — `stop_code` is routinely absent.
    @Test func missingColumnReadsAsEmptyRatherThanShiftingLeft() {
        var csv = CSVReader(bytes: Array("stop_id,stop_code,stop_name\n8010\n".utf8))
        let row = csv.next() ?? []
        #expect(csv[row, "stop_id"] == "8010")
        #expect(csv[row, "stop_name"] == "")
        #expect(csv[row, "nonexistent"] == "")
    }
}

struct GTFSTimeTests {
    @Test func parsesAfterMidnightHoursPastTwentyFour() {
        #expect(GTFSTime.seconds("25:14:00") == 25 * 3600 + 14 * 60)
        #expect(GTFSTime.seconds("00:00:00") == 0)
    }

    /// A blank time is what makes `ingestStopTimes` fall back to the other column rather than drop the row.
    @Test func rejectsBlankAndMalformedTimes() {
        #expect(GTFSTime.seconds("") == nil)
        #expect(GTFSTime.seconds("07:30") == nil)
    }
}
