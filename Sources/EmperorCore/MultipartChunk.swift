import Foundation

/// Builds the `/upload-chunk` request body for a single chunk.
///
/// This exists as its own type for one reason: **the foreground and background paths must send
/// byte-identical bodies.** A background `URLSession` cannot use `httpBody` at all — it requires
/// `uploadTask(with:fromFile:)` — so the background path has to write its body to a file while
/// the foreground path builds one in memory. Two hand-written multipart encoders would drift,
/// and the one that drifts is the one nothing can test.
///
/// So there is one field list and one encoder here, and both callers use it.
///
/// ## Reading from the file rather than the file into memory
///
/// The 200-page scan this feature exists for is the case that breaks the old design: it held the
/// whole document in a `Data` and chunked that. A large paperbook is comfortably enough to be
/// killed for memory on an older phone, and being killed mid-upload was exactly the failure this
/// was meant to fix. `write(chunk:)` seeks to the chunk's offset and reads only its own bytes.
enum MultipartChunk {

    /// Everything the server needs to place a chunk. All values are decimal strings: multipart
    /// has no typing, and each is `parseInt`ed with no `NaN` guard, so a non-numeric value
    /// corrupts the offset arithmetic silently instead of erroring.
    struct Fields: Equatable, Sendable {
        let userID: String
        let fileName: String
        let folderName: String
        let uploadID: String
        let chunkIndex: Int
        let chunkCount: Int
        let chunkSize: Int
        let totalBytes: Int

        /// - Important: `chunkSize` is not optional and must never be dropped. With it the
        ///   server writes each chunk at an absolute offset; without it the route falls back to
        ///   appending, and any chunk that arrives out of order corrupts the document. The
        ///   background path enqueues every chunk at once precisely because this field makes
        ///   order irrelevant.
        var formFields: [(String, String)] {
            [
                ("userId", userID),
                ("folderName", folderName),
                ("fileName", fileName),
                ("chunkIndex", String(chunkIndex)),
                ("totalChunks", String(chunkCount)),
                ("chunkSize", String(chunkSize)),
                ("uploadId", uploadID),
                ("totalBytes", String(totalBytes)),
            ]
        }
    }

    static func boundary() -> String { "Boundary-\(UUID().uuidString)" }

    static func contentType(boundary: String) -> String {
        "multipart/form-data; boundary=\(boundary)"
    }

    /// The part of the body that precedes the file bytes.
    static func header(fields: Fields, boundary: String) -> Data {
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }
        for (name, value) in fields.formFields {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        // The file part is ignored entirely unless it carries a `filename` parameter — without
        // it the server sees the fields, answers 200, and stores nothing.
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fields.fileName)\"\r\n")
        append("Content-Type: application/octet-stream\r\n\r\n")
        return body
    }

    static func trailer(boundary: String) -> Data {
        Data("\r\n--\(boundary)--\r\n".utf8)
    }

    /// The whole body in memory. Used by the foreground path, which already holds the bytes.
    static func body(chunk: Data, fields: Fields, boundary: String) -> Data {
        var body = header(fields: fields, boundary: boundary)
        body.append(chunk)
        body.append(trailer(boundary: boundary))
        return body
    }

    enum ChunkError: LocalizedError, Equatable {
        case sourceUnreadable(String)
        case shortRead(expected: Int, got: Int)

        var errorDescription: String? {
            switch self {
            case .sourceUnreadable(let path):
                return "The document could not be read from \(path)."
            case .shortRead(let expected, let got):
                // Worth its own message: it means the file changed under the upload, and
                // continuing would send a truncated chunk that the server accepts happily.
                return "The document changed while it was being sent (expected \(expected) "
                    + "bytes, read \(got))."
            }
        }
    }

    /// Writes the body for one chunk to `destination`, reading only that chunk from `source`.
    ///
    /// - Returns: the byte length of the file written, which is what
    ///   `totalBytesExpectedToSend` will report — the body, not the chunk.
    @discardableResult
    static func write(
        chunkAt range: Range<Int>,
        from source: URL,
        to destination: URL,
        fields: Fields,
        boundary: String
    ) throws -> Int {
        guard let handle = try? FileHandle(forReadingFrom: source) else {
            throw ChunkError.sourceUnreadable(source.path)
        }
        defer { try? handle.close() }

        try handle.seek(toOffset: UInt64(range.lowerBound))
        let bytes = try handle.read(upToCount: range.count) ?? Data()
        // A short read means the file shrank after the manifest recorded its size. Sending it
        // would place fewer bytes than the offsets assume, and every later chunk would then sit
        // at the wrong place in a file the server still calls complete.
        guard bytes.count == range.count else {
            throw ChunkError.shortRead(expected: range.count, got: bytes.count)
        }

        var body = header(fields: fields, boundary: boundary)
        body.append(bytes)
        body.append(trailer(boundary: boundary))

        try body.write(to: destination, options: .atomic)
        return body.count
    }
}
