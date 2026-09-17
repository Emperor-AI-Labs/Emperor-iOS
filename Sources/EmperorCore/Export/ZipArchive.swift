import Foundation

/// A ZIP container, stored rather than compressed.
///
/// A `.docx` is a ZIP of XML parts, so producing one needs an archive writer and Foundation has
/// none. This writes the smallest archive Word accepts: no compression, no data descriptors, no
/// Zip64 — a drafted pleading is tens of kilobytes of XML, and the saving is not worth carrying
/// a deflate implementation for.
///
/// Deterministic on purpose. Every entry is stamped with the same fixed timestamp, so the same
/// document exported twice is byte-identical — which is what lets the tests compare whole
/// archives rather than poking at them.
struct ZipArchive {
    private struct Entry {
        let path: String
        let data: Data
        let crc: UInt32
        let offset: Int
    }

    private var entries: [Entry] = []
    private var payload = Data()

    /// 1 January 1980, the earliest a DOS timestamp can express. Zero is not a valid date, and
    /// some readers object to it.
    private static let dosTime: UInt16 = 0
    private static let dosDate: UInt16 = 0x0021

    mutating func add(_ path: String, _ contents: String) {
        add(path, Data(contents.utf8))
    }

    mutating func add(_ path: String, _ data: Data) {
        let name = Data(path.utf8)
        let crc = ZipArchive.crc32(data)
        let offset = payload.count

        payload.append(littleEndian: UInt32(0x0403_4B50))   // local file header
        payload.append(littleEndian: UInt16(20))            // version needed
        payload.append(littleEndian: UInt16(0))             // flags
        payload.append(littleEndian: UInt16(0))             // method: stored
        payload.append(littleEndian: ZipArchive.dosTime)
        payload.append(littleEndian: ZipArchive.dosDate)
        payload.append(littleEndian: crc)
        payload.append(littleEndian: UInt32(data.count))    // compressed
        payload.append(littleEndian: UInt32(data.count))    // uncompressed
        payload.append(littleEndian: UInt16(name.count))
        payload.append(littleEndian: UInt16(0))             // extra field length
        payload.append(name)
        payload.append(data)

        entries.append(Entry(path: path, data: data, crc: crc, offset: offset))
    }

    /// The finished archive.
    func data() -> Data {
        var out = payload
        let directoryOffset = out.count

        for entry in entries {
            let name = Data(entry.path.utf8)
            out.append(littleEndian: UInt32(0x0201_4B50))   // central directory header
            out.append(littleEndian: UInt16(20))            // version made by
            out.append(littleEndian: UInt16(20))            // version needed
            out.append(littleEndian: UInt16(0))             // flags
            out.append(littleEndian: UInt16(0))             // method: stored
            out.append(littleEndian: ZipArchive.dosTime)
            out.append(littleEndian: ZipArchive.dosDate)
            out.append(littleEndian: entry.crc)
            out.append(littleEndian: UInt32(entry.data.count))
            out.append(littleEndian: UInt32(entry.data.count))
            out.append(littleEndian: UInt16(name.count))
            out.append(littleEndian: UInt16(0))             // extra
            out.append(littleEndian: UInt16(0))             // comment
            out.append(littleEndian: UInt16(0))             // disk number
            out.append(littleEndian: UInt16(0))             // internal attributes
            out.append(littleEndian: UInt32(0))             // external attributes
            out.append(littleEndian: UInt32(entry.offset))
            out.append(name)
        }

        let directorySize = out.count - directoryOffset
        out.append(littleEndian: UInt32(0x0605_4B50))       // end of central directory
        out.append(littleEndian: UInt16(0))                 // this disk
        out.append(littleEndian: UInt16(0))                 // disk with the directory
        out.append(littleEndian: UInt16(entries.count))
        out.append(littleEndian: UInt16(entries.count))
        out.append(littleEndian: UInt32(directorySize))
        out.append(littleEndian: UInt32(directoryOffset))
        out.append(littleEndian: UInt16(0))                 // comment length
        return out
    }

    // MARK: - CRC32

    /// Built once. The per-byte alternative is fine for a small file and wasteful for a table of
    /// authorities that runs to a megabyte.
    private static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    /// `Swift.withUnsafeBytes(of:_:)`, spelled out: inside a `Data` extension the bare name
    /// resolves to `Data`'s own instance method, which reads this buffer rather than the value.
    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
