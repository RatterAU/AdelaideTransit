import Foundation
import Compression

enum ZipError: Error {
    case malformed
    case entryNotFound(String)
    case unsupportedMethod(UInt16)
    case inflateFailed
}

/// Minimal zip reader: central directory + local headers, stored/deflate only.
/// GTFS zips from Google's exporter never use other methods or zip64. No third-party dependency.
struct ZipEntry {
    let name: String
    let method: UInt16
    let compressedSize: UInt32
    let uncompressedSize: UInt32
    let localHeaderOffset: UInt32
}

final class ZipReader {
    private let data: Data
    let entries: [String: ZipEntry]

    init(fileURL: URL) throws {
        data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        entries = try Self.readCentralDirectory(data)
    }

    /// Decompressed bytes of one archive member.
    func extract(_ name: String) throws -> Data {
        guard let entry = entries[name] else { throw ZipError.entryNotFound(name) }

        var offset = Int(entry.localHeaderOffset)
        guard offset + 30 <= data.count, Self.u32(data, offset) == 0x0403_4b50 else { throw ZipError.malformed }
        let nameLen = Int(Self.u16(data, offset + 26))
        let extraLen = Int(Self.u16(data, offset + 28))
        offset += 30 + nameLen + extraLen

        let compressedRange = offset..<(offset + Int(entry.compressedSize))
        guard compressedRange.upperBound <= data.count else { throw ZipError.malformed }
        let compressed = data.subdata(in: compressedRange)

        switch entry.method {
        case 0:
            return compressed
        case 8:
            return try inflate(compressed, uncompressedSize: Int(entry.uncompressedSize))
        default:
            throw ZipError.unsupportedMethod(entry.method)
        }
    }

    private func inflate(_ compressed: Data, uncompressedSize: Int) throws -> Data {
        guard uncompressedSize > 0 else { return Data() }
        var output = Data(count: uncompressedSize)
        let written = output.withUnsafeMutableBytes { dst -> Int in
            compressed.withUnsafeBytes { src -> Int in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, uncompressedSize,
                    src.bindMemory(to: UInt8.self).baseAddress!, compressed.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == uncompressedSize else { throw ZipError.inflateFailed }
        return output
    }

    // MARK: - Central directory parsing

    private static func readCentralDirectory(_ data: Data) throws -> [String: ZipEntry] {
        // Find End Of Central Directory record by scanning backward for its signature.
        // Comment field is variable length (<=64KB) so search the tail of the file.
        let searchStart = max(0, data.count - 66_000)
        var eocdOffset = -1
        var i = data.count - 22
        while i >= searchStart {
            if u32(data, i) == 0x0605_4b50 {
                eocdOffset = i
                break
            }
            i -= 1
        }
        guard eocdOffset >= 0 else { throw ZipError.malformed }

        let entryCount = Int(u16(data, eocdOffset + 10))
        let centralDirOffset = Int(u32(data, eocdOffset + 16))

        var entries: [String: ZipEntry] = [:]
        entries.reserveCapacity(entryCount)

        var offset = centralDirOffset
        for _ in 0..<entryCount {
            guard offset + 46 <= data.count, u32(data, offset) == 0x0201_4b50 else { throw ZipError.malformed }
            let method = u16(data, offset + 10)
            let compressedSize = u32(data, offset + 20)
            let uncompressedSize = u32(data, offset + 24)
            let nameLen = Int(u16(data, offset + 28))
            let extraLen = Int(u16(data, offset + 30))
            let commentLen = Int(u16(data, offset + 32))
            let localHeaderOffset = u32(data, offset + 42)

            let nameRange = (offset + 46)..<(offset + 46 + nameLen)
            let name = String(data: data.subdata(in: nameRange), encoding: .utf8) ?? ""

            entries[name] = ZipEntry(
                name: name, method: method,
                compressedSize: compressedSize, uncompressedSize: uncompressedSize,
                localHeaderOffset: localHeaderOffset
            )

            offset += 46 + nameLen + extraLen + commentLen
        }
        return entries
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        let base = data.startIndex + offset
        return UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return UInt32(data[base])
            | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)
    }
}
