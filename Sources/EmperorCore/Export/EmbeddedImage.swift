import Foundation

/// A picture pulled out of a drafted fragment, ready to be packed into a document.
///
/// Only `data:` URIs. A remote `src` would mean a network fetch in the middle of an export —
/// which would make it slow, fallible and dependent on a signature the exporter has no business
/// holding. The platform's editor inlines what it pastes, so this covers what actually arrives;
/// anything else is marked in the text rather than silently vanishing.
struct EmbeddedImage: Equatable, Sendable {
    enum Format: String, Equatable, Sendable {
        case png, jpeg, gif

        /// The extension the package files it under, which `[Content_Types].xml` must declare.
        var fileExtension: String { self == .jpeg ? "jpeg" : rawValue }
    }

    let format: Format
    let data: Data
    /// Pixels, as read out of the file's own header.
    let width: Int
    let height: Int

    /// Reads a `data:` URI. Returns nil for a remote source, an unknown format, or bytes whose
    /// header does not parse — a picture whose size cannot be read cannot be laid out.
    static func parse(dataURI: String) -> EmbeddedImage? {
        let trimmed = dataURI.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("data:") else { return nil }
        guard let comma = trimmed.firstIndex(of: ",") else { return nil }
        let header = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 5)..<comma].lowercased()
        guard header.contains("base64") else { return nil }

        let encoded = String(trimmed[trimmed.index(after: comma)...])
            // A pasted URI is often wrapped across lines; Foundation rejects the whitespace.
            .components(separatedBy: .whitespacesAndNewlines).joined()
        guard let bytes = Data(base64Encoded: encoded), !bytes.isEmpty else { return nil }
        return read(bytes)
    }

    /// Identifies the format from the bytes rather than the declared MIME type, and reads the
    /// dimensions out of the header.
    static func read(_ bytes: Data) -> EmbeddedImage? {
        let b = [UInt8](bytes)
        if let size = pngSize(b) {
            return EmbeddedImage(format: .png, data: bytes, width: size.0, height: size.1)
        }
        if let size = jpegSize(b) {
            return EmbeddedImage(format: .jpeg, data: bytes, width: size.0, height: size.1)
        }
        if let size = gifSize(b) {
            return EmbeddedImage(format: .gif, data: bytes, width: size.0, height: size.1)
        }
        return nil
    }

    // MARK: - Headers

    private static func pngSize(_ b: [UInt8]) -> (Int, Int)? {
        // Signature, then IHDR at a fixed offset with width and height as big-endian 32-bit.
        guard b.count >= 24,
              b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47
        else { return nil }
        let width = Int(b[16]) << 24 | Int(b[17]) << 16 | Int(b[18]) << 8 | Int(b[19])
        let height = Int(b[20]) << 24 | Int(b[21]) << 16 | Int(b[22]) << 8 | Int(b[23])
        return width > 0 && height > 0 ? (width, height) : nil
    }

    private static func gifSize(_ b: [UInt8]) -> (Int, Int)? {
        guard b.count >= 10, b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 else { return nil }
        let width = Int(b[6]) | Int(b[7]) << 8          // little-endian, unlike PNG
        let height = Int(b[8]) | Int(b[9]) << 8
        return width > 0 && height > 0 ? (width, height) : nil
    }

    /// Walks the marker segments to the start-of-frame, which is the only one carrying the size.
    ///
    /// There is no fixed offset: a JPEG out of a phone camera opens with EXIF and an embedded
    /// thumbnail, so the frame header can be tens of kilobytes in.
    private static func jpegSize(_ b: [UInt8]) -> (Int, Int)? {
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var index = 2
        while index + 9 < b.count {
            guard b[index] == 0xFF else { index += 1; continue }
            let marker = b[index + 1]
            // Padding and the standalone markers carry no length field.
            if marker == 0xFF || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD9) {
                index += 2
                continue
            }
            let length = Int(b[index + 2]) << 8 | Int(b[index + 3])
            // SOF0-SOF3, SOF5-SOF7, SOF9-SOF11, SOF13-SOF15. DHT/DAC/SOS are not frames.
            let isFrame = (0xC0...0xCF).contains(marker)
                && marker != 0xC4 && marker != 0xC8 && marker != 0xCC
            if isFrame {
                let height = Int(b[index + 5]) << 8 | Int(b[index + 6])
                let width = Int(b[index + 7]) << 8 | Int(b[index + 8])
                return width > 0 && height > 0 ? (width, height) : nil
            }
            guard length >= 2 else { return nil }
            index += 2 + length
        }
        return nil
    }
}
