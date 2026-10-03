import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

protocol OCRProviding: Sendable {
    func submit(data: Data, fileName: String, language: OCRLanguage) async throws -> String
    func status(jobID: String) async throws -> OCRJob
    func download(outputFile: String) async throws -> Data
    /// This account's jobs, newest first.
    func history() async throws -> OCRHistory
    /// Removes every job the history listing covers.
    func clearHistory() async throws
}

/// Digitising and translating a scanned document, and the account's history of doing so.
///
/// Every `/ocr-*` route answers for the signed-in account: the history lists that account's
/// jobs, and status, logs and downloads are served for those jobs only
/// (`sync-server.js:4462-4472`). This client sends its bearer token on every call, so the history
/// it shows is the user's own — and it narrows the listing to jobs recorded against this account
/// as well, so that is true for every kind of account (see `OCRHistory.listedOtherJobs`).
struct OCRService: OCRProviding {
    let client: APIClient

    /// Submits a document.
    ///
    /// - Parameter language: always sent. Omitting `lang` makes the server translate to Hindi
    ///   by default (`sync-server.js:15384`) — a "just digitise this" request would come back
    ///   in a language nobody asked for.
    func submit(data: Data, fileName: String, language: OCRLanguage) async throws -> String {
        var request = try await client.makeRequest("POST", "/ocr-translate")

        // A long random boundary, because `splitBuffer` scans the *whole* body including the
        // PDF bytes (`sync-server.js:5252`). A boundary that happens to occur inside the file
        // silently truncates the upload — and still answers 200.
        let boundary = "Boundary-\(UUID().uuidString)-\(UUID().uuidString)"
        // Exactly `multipart/form-data; boundary=<token>`: the server takes the raw remainder
        // after `boundary=` (`:15378`), so a quoted value or a trailing `; charset=` breaks it.
        request.setValue(
            "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }

        // `pageSetup` is `JSON.parse`d server-side (`sync-server.js:15409`), so a bare "A4"
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

        // The job is recorded against the account the bearer token names, which is what puts it
        // in this user's history. `userId` is sent as well, as on every other call this client
        // makes, so nothing changes here if the server ever reads it.
        if let credentials = await client.currentCredentials() {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"userId\"\r\n\r\n")
            append("\(credentials.userIDString)\r\n")
        }

        // `name` before `filename`: the parser matches the first `name="` in the header, and
        // `name="` is a substring of `filename="` (`sync-server.js:15397`). Reversed, the field
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
    /// while still looking connected (`sync-server.js:15646-15670`). This route's body already
    /// carries the full log array plus the status and progress the stream does not provide.
    func status(jobID: String) async throws -> OCRJob {
        var request = try await client.makeRequest(
            "GET", "/ocr-status", query: ["jobId": jobID])
        // The route sets no Cache-Control (`sync-server.js:15638`), so URLSession's heuristic
        // caching can replay a stale poll and make a live job look frozen.
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let response = try await client.send(request, as: OCRStatusResponse.self)
        guard let job = response.resolvedJob else {
            throw APIError.server(
                status: 404, message: response.error ?? "That job could not be found.")
        }
        return job
    }

    /// Fetches a finished document by its stored name — `outputFile`, not `downloadName`.
    func download(outputFile: String) async throws -> Data {
        var request = try await client.makeRequest(
            "GET", "/ocr-download", query: ["file": outputFile])
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await client.perform(request)
        guard (200..<300).contains(response.statusCode) else {
            // A result is served only while its job is in this account's history and the file
            // is still on the server (`sync-server.js:15696-15697`), so a 404 is "gone", not
            // "broken" — and worth saying in those words.
            throw APIError.server(
                status: response.statusCode,
                message: response.statusCode == 404
                    ? "That document is no longer available. It may have been cleared from your history."
                    : "That document could not be downloaded.")
        }
        return data
    }

    func history() async throws -> OCRHistory {
        var request = try await client.makeRequest("GET", "/ocr-history")
        // A history that replays from URLSession's cache would show a job as still running
        // after it finished.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let response = try await client.send(request, as: OCRHistoryResponse.self)

        let me = await client.currentCredentials()?.userIDString
        let mine = response.jobs.filter { me != nil && $0.ownerID == me }
        return OCRHistory(
            jobs: mine,
            listedOtherJobs: mine.count != response.jobs.count || response.unreadable > 0)
    }

    /// `POST /ocr-clear` (`sync-server.js:15682-15687`). It removes every job the history
    /// listing covers, running ones included — which is why the screen withholds it whenever the
    /// listing covered anything this screen does not show.
    func clearHistory() async throws {
        let request = try await client.makeRequest("POST", "/ocr-clear")
        let response = try await client.send(request, as: OCRClearResponse.self)
        try CaseService.throwIfUnsuccessful(success: response.success, error: response.error)
    }
}
