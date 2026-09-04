import Foundation
#if canImport(FoundationNetworking)
// URLSession lives in Foundation on Apple platforms but in FoundationNetworking on Linux,
// where the core package is compiled for tests.
import FoundationNetworking
#endif

/// Uploads documents to the DMS in resumable chunks, then waits for server-side ingestion.
///
/// Two things about this endpoint drive the design:
///
/// 1. **A 200 on the final chunk means "bytes received", not "file ready".** Assembly,
///    verification, OCR and indexing all happen after the response has closed, so a failure
///    there produces no HTTP error at all — it surfaces only as an `ERROR:` string from
///    `/upload-status`. Polling afterwards is mandatory, not optional.
/// 2. **`chunkSize` must always be sent.** With it, each chunk is written at an absolute
///    offset and order does not matter. Without it the server falls back to append-mode,
///    which corrupts any upload whose chunks do not arrive in order.
/// The upload path a view model drives.
///
/// Declared separately from `UploadService` so a screen that attaches a scan can be tested
/// without a server: the interesting behaviour is what the *caller* does with the event
/// sequence — attach on success, report the ingestion failure that arrives with no HTTP
/// error — not the chunking underneath it.
protocol UploadProviding: Sendable {
    func upload(
        data: Data,
        fileName: String,
        folderName: String,
        chunkSize: Int
    ) -> AsyncThrowingStream<UploadService.UploadEvent, Error>
}

extension UploadProviding {
    func upload(
        data: Data, fileName: String, folderName: String
    ) -> AsyncThrowingStream<UploadService.UploadEvent, Error> {
        upload(
            data: data, fileName: fileName, folderName: folderName,
            chunkSize: UploadService.chunkSize)
    }
}

struct UploadService: UploadProviding {
    let client: APIClient

    /// The server's hard cap is 64 MB per request body, but the tested path is 10 MB and the
    /// web client never exceeds it. Staying well under the cap also keeps a failed chunk cheap
    /// to retry on a patchy courtroom connection.
    static let chunkSize = 10 * 1024 * 1024
    static let constrainedChunkSize = 4 * 1024 * 1024

    enum UploadEvent {
        case progress(sent: Int, total: Int)
        case processing(String)
        case finished(IngestState)
    }

    /// Mirrors the server's `safeSegment`: anything outside `[A-Za-z0-9._-]` becomes `_`.
    ///
    /// Status polls must use the sanitised name, because the server re-sanitises before
    /// resolving the path — polling with the original name silently never resolves, and the
    /// upload appears to hang forever rather than failing.
    ///
    /// This substitutes **per UTF-16 code unit**, because the server's regex runs over a
    /// JavaScript string. Mapping over Swift `Character`s instead would collapse each
    /// Devanagari grapheme cluster to a single `_` — "देखिए.pdf" would become `___.pdf`
    /// where the server writes `_____.pdf`, and every Hindi-named upload would hang.
    static func sanitize(fileName: String) -> String {
        let allowed = Set(
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-".utf16)
        let underscore = "_".utf16.first!
        let cleaned = String(
            decoding: fileName.utf16.map { allowed.contains($0) ? $0 : underscore },
            as: UTF16.self)
        // The server rejects empty and all-dots names, which would otherwise escape the
        // storage root.
        if cleaned.isEmpty || cleaned.allSatisfy({ $0 == "." }) { return "_" }
        return cleaned
    }

    func upload(
        data: Data,
        fileName: String,
        folderName: String,
        // No default here: the three-argument convenience is the one on `UploadProviding`, so
        // that both the real service and any stand-in offer exactly the same call shapes.
        chunkSize: Int
    ) -> AsyncThrowingStream<UploadEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let credentials = await client.currentCredentials() else {
                        throw APIError.notAuthenticated
                    }
                    // Stable across retries so re-sent chunks overwrite rather than duplicate.
                    let uploadID = UUID().uuidString
                    let total = data.count
                    let chunkCount = max(1, Int(ceil(Double(total) / Double(chunkSize))))

                    for index in 0..<chunkCount {
                        try Task.checkCancellation()
                        let start = index * chunkSize
                        let end = min(start + chunkSize, total)
                        let chunk = data.subdata(in: start..<end)

                        try await sendChunk(
                            chunk, index: index, chunkCount: chunkCount, chunkSize: chunkSize,
                            totalBytes: total, fileName: fileName, folderName: folderName,
                            uploadID: uploadID, credentials: credentials)

                        continuation.yield(.progress(sent: end, total: total))
                    }

                    // The upload is only half the job — ingestion runs after the response closed.
                    let state = try await waitForIngestion(
                        fileName: fileName, folderName: folderName,
                        onProgress: { continuation.yield(.processing($0)) })
                    continuation.yield(.finished(state))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Chunk transfer

    private func sendChunk(
        _ chunk: Data, index: Int, chunkCount: Int, chunkSize: Int, totalBytes: Int,
        fileName: String, folderName: String, uploadID: String, credentials: Credentials
    ) async throws {
        var request = try await client.makeRequest("POST", "/upload-chunk", requiresAuth: true)
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")
        // The server accepts these as headers as well as form fields; the web client sends both.
        request.setValue(uploadID, forHTTPHeaderField: "x-upload-id")
        request.setValue(String(totalBytes), forHTTPHeaderField: "x-total-bytes")

        // Every numeric value is a decimal string: multipart has no typing, and the server
        // `parseInt`s each one with no NaN guard — a non-numeric value would silently corrupt
        // the offset arithmetic rather than error.
        let fields: [(String, String)] = [
            ("userId", credentials.userIDString),
            ("folderName", folderName),
            ("fileName", fileName),
            ("chunkIndex", String(index)),
            ("totalChunks", String(chunkCount)),
            ("chunkSize", String(chunkSize)),
            ("uploadId", uploadID),
            ("totalBytes", String(totalBytes)),
        ]

        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }
        for (name, value) in fields {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        // The file part is ignored unless it carries a `filename` parameter.
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n")
        append("Content-Type: application/octet-stream\r\n\r\n")
        body.append(chunk)
        append("\r\n--\(boundary)--\r\n")
        request.httpBody = body

        do {
            _ = try await client.send(request, as: UploadChunkResponse.self)
        } catch let error as APIError {
            // Over the cap the server destroys the socket rather than replying, so a reset
            // mid-chunk means "too large" even though no 413 arrived.
            if case .transport = error, chunk.count > 32 * 1024 * 1024 {
                throw APIError.server(
                    status: 413,
                    message: "That chunk was too large for the server. Try a smaller chunk size.")
            }
            throw error
        }
    }

    // MARK: - Ingestion

    /// Polls until the document reaches a terminal state.
    ///
    /// Note the in-memory status map does not survive a server restart, so a file can revert
    /// to a generic "Reading document content..." mid-poll without anything being wrong.
    func waitForIngestion(
        fileName: String,
        folderName: String,
        pollInterval: Duration = .seconds(2),
        timeout: Duration = .seconds(900),
        onProgress: (String) -> Void = { _ in }
    ) async throws -> IngestState {
        let safeName = Self.sanitize(fileName: fileName)
        let deadline = ContinuousClock.now + timeout

        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let request = try await client.makeRequest(
                "GET", "/upload-status",
                query: ["folderName": folderName, "fileName": safeName])
            let response = try await client.send(request, as: UploadStatusResponse.self)
            let state = IngestState.classify(response.status)

            if state.isTerminal { return state }
            if case .inProgress(let message) = state { onProgress(message) }
            try await Task.sleep(for: pollInterval)
        }
        return .inProgress("Still processing — this is taking longer than usual.")
    }
}
