import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

protocol OCRProviding: Sendable {
    func submit(data: Data, fileName: String, language: OCRLanguage) async throws -> String
    func status(jobID: String) async throws -> OCRJob
    func download(outputFile: String) async throws -> Data
}

/// Digitising and translating a scanned document.
///
/// ## What this service deliberately does not do
///
/// This app lists only the job ids it created itself, so a user never sees a job this device did
/// not start. Do not swap in a server-side history listing without confirming the contract of
/// that endpoint first — the containment here is the client's, not the server's.
struct OCRService: OCRProviding {
    let client: APIClient

    /// Submits a document.
    ///
    /// - Parameter language: always sent. Omitting `lang` makes the server translate to Hindi
    ///   by default (`sync-server.js:12118`) — a "just digitise this" request would come back
    ///   in a language nobody asked for.
    func submit(data: Data, fileName: String, language: OCRLanguage) async throws -> String {
        var request = try await client.makeRequest("POST", "/ocr-translate")

        // A long random boundary, because `splitBuffer` scans the *whole* body including the
        // PDF bytes (`sync-server.js:4314-4327`). A boundary that happens to occur inside the
        // file silently truncates the upload — and still answers 200.
        let boundary = "Boundary-\(UUID().uuidString)-\(UUID().uuidString)"
        // Exactly `multipart/form-data; boundary=<token>`: the server takes the raw remainder
        // after `boundary=` (`:12112`), so a quoted value or a trailing `; charset=` breaks it.
        request.setValue(
            "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }

        // `pageSetup` is `JSON.parse`d server-side (`sync-server.js:12140`), so a bare "A4"
        // throws and is silently discarded. Send valid JSON, or the intent is an accident that
        // only works because the renderer defaults to A4 anyway.
        for (name, value) in [
            ("lang", language.rawValue),
            ("pageSetup", #"{"size":"A4"}"#),
        ] {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }

        // Forward-compatible and currently ignored: the route reads no userId, so every job is
        // billed to NULL (`sync-server.js:12243-12252`). Sending it costs nothing and means the
        // client needs no change when the server grows the branch its own comment describes.
        if let credentials = await client.currentCredentials() {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"userId\"\r\n\r\n")
            append("\(credentials.userIDString)\r\n")
        }

        // `name` before `filename`: the parser matches the first `name="` in the header, and
        // `name="` is a substring of `filename="` (`sync-server.js:12131`). Reversed, the field
        // is read as the filename and the upload 500s with "Missing file".
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n")
        append("Content-Type: application/pdf\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")
        request.httpBody = body

        let response = try await client.send(request, as: OCRSubmitResponse.self)
        try CaseService.throwIfUnsuccessful(success: response.success, error: response.error)
        guard let jobID = response.jobId else {
            throw APIError.server(status: 500, message: "The server did not return a job id.")
        }
        return jobID
    }

    /// Polls a job.
    ///
    /// Polling rather than the SSE log stream: `/ocr-logs` sets no heartbeat, no `retry:`, no
    /// `id:`, never reads `Last-Event-ID`, never closes on completion, and omits
    /// `X-Accel-Buffering: no` — so behind nginx it can be proxy-buffered and simply stop,
    /// while still looking connected (`sync-server.js:12302-12323`). This route's body already
    /// carries the full log array plus the status and progress the stream does not provide.
    func status(jobID: String) async throws -> OCRJob {
        var request = try await client.makeRequest(
            "GET", "/ocr-status", query: ["jobId": jobID])
        // The route sets no Cache-Control (`sync-server.js:12294`), so URLSession's heuristic
        // caching can replay a stale poll and make a live job look frozen.
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let response = try await client.send(request, as: OCRStatusResponse.self)
        guard let job = response.resolvedJob else {
            throw APIError.server(
                status: 404, message: response.error ?? "That job could not be found.")
        }
        return job
    }

    func download(outputFile: String) async throws -> Data {
        let request = try await client.makeRequest(
            "GET", "/ocr-download", query: ["file": outputFile])
        let (data, response) = try await client.perform(request)
        guard (200..<300).contains(response.statusCode) else {
            throw APIError.server(
                status: response.statusCode,
                message: "That document could not be downloaded.")
        }
        return data
    }
}
