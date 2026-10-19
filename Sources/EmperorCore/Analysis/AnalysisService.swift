import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The analysis routes a view model needs.
protocol AnalysisProviding: Sendable {
    /// Starts a job on documents already in My Files and returns its id.
    func start(tool: AnalysisJobTool, files: [ChatAttachment], reference: String) async throws -> String
    /// Where a job stands. A job the server no longer holds is an error.
    func job(id: String) async throws -> AnalysisJob
    /// Saved runs, newest first — of one tool, or of every tool for `nil`.
    func history(tool: AnalysisJobTool?) async throws -> [AnalysisRunSummary]
    /// One saved run with its result.
    func run(id: String) async throws -> AnalysisRun
    /// Deletes a saved run. One that is already gone counts as deleted.
    func deleteRun(id: String) async throws
}

/// The analysis routes: `POST /analysis/start`, `GET /analysis/job`, `GET /analysis/history`,
/// `GET` and `DELETE /analysis/run`.
///
/// ## Documents come from My Files, by folder
///
/// A tool never takes an upload. It reads documents that are already in My Files — where they
/// were read and indexed on arrival — named the way the chat names them, `{name, folderName}`.
/// Two kinds are refused before anything is sent: a document at the top level of My Files,
/// which the tools cannot be pointed at (the web's picker leaves those out too), and one inside
/// a matter, which is not My Files at all.
///
/// ## A job lives on the server, in memory
///
/// The start answers at once with a job id; the result is fetched by polling. A job the server
/// has forgotten — it finished over an hour ago, or the server restarted — answers 404, and
/// the only thing to do then is run it again.
struct AnalysisService: AnalysisProviding {
    let client: APIClient
    /// The id each run is started under — the web uses a random UUID.
    var newRunID: @Sendable () -> String = { UUID().uuidString.lowercased() }

    static let rootFileMessage =
        "Documents at the top of My Files cannot be analysed. Move them into a folder first."
    static let matterFileMessage =
        "A matter’s documents cannot be used here. Put the document in My Files first."
    static let tooManyFilesMessage =
        "At most \(AnalysisJobTool.maxFiles) documents at a time."
    static let noFilesMessage = "Choose at least one document to begin."
    static let lostJobMessage =
        "The server lost track of this analysis — it finished over an hour ago, or the server restarted. Run it again."
    static let tooLongMessage =
        "These documents are too long to analyse in one go. Try fewer or shorter documents."
    static let tooManyRunningMessage =
        "You already have analyses running. Wait for one to finish, then try again."
    static let runGoneMessage = "That saved analysis is no longer there."

    /// Why a document cannot be sent, or `nil` when it can.
    static func refusal(for file: ChatAttachment) -> String? {
        let folder = (file.folderName ?? "").trimmingCharacters(in: .whitespaces)
        let segments = folder.split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "." }
        if segments.isEmpty { return rootFileMessage }
        if segments.contains(where: { $0.lowercased().hasPrefix("_projects") }) { return matterFileMessage }
        return nil
    }

    /// The note as the server will take it: trimmed, and no longer than it accepts — counted in
    /// UTF-16, as the server counts, without splitting a character.
    static func cleanReference(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf16.count > AnalysisJobTool.maxReferenceLength else { return trimmed }
        var out = ""
        var units = 0
        for character in trimmed {
            let size = character.utf16.count
            guard units + size <= AnalysisJobTool.maxReferenceLength else { break }
            out.append(character)
            units += size
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func start(tool: AnalysisJobTool, files: [ChatAttachment], reference: String) async throws -> String {
        var seen = Set<ChatAttachment>()
        let unique = files.filter { seen.insert($0).inserted }
        guard !unique.isEmpty else { throw APIError.server(status: 400, message: Self.noFilesMessage) }
        guard unique.count <= AnalysisJobTool.maxFiles else {
            throw APIError.server(status: 400, message: Self.tooManyFilesMessage)
        }
        if let refused = unique.lazy.compactMap(Self.refusal(for:)).first {
            throw APIError.server(status: 400, message: refused)
        }
        guard let credentials = await client.currentCredentials() else { throw APIError.notAuthenticated }

        let body = Payload(body: [
            "userId": .string(credentials.userIDString),
            "tool": .string(tool.rawValue),
            "chatId": .string(newRunID()),
            "files": .array(unique.map { file in
                .object(["name": .string(file.name), "folderName": .string(file.folderName ?? "")])
            }),
            "reference": .string(Self.cleanReference(reference)),
        ])
        let request = try await client.makeRequest("POST", "/analysis/start", body: body)
        // Never retried: a start that reached the server is a job, and a second would be another.
        let response: AnalysisStartResponse
        do {
            response = try await client.send(request, as: AnalysisStartResponse.self)
        } catch let error as APIError {
            throw Self.startFailure(error)
        }
        try CaseService.throwIfUnsuccessful(success: response.success, error: response.error)
        guard let jobID = response.jobId, !jobID.isEmpty else {
            throw APIError.decoding("The analysis was accepted without a job id.")
        }
        return jobID
    }

    /// A refused start, worded for this client.
    ///
    /// The plan refusals with codes this client knows are already `.refused`. The route's own
    /// "this month's queries are used up" carries a code of its own (`LIMIT`) and the web's
    /// sentence, which points at a purchase — so any other 402 here is read as the query
    /// allowance it is, and worded as `Refusal` words that.
    static func startFailure(_ error: APIError) -> APIError {
        guard case .server(let status, let message) = error else { return error }
        switch status {
        case 402:
            return .refused(Refusal(code: .queryLimit, status: 402, serverMessage: message))
        case 413:
            return .server(status: 413, message: plainOr(message, tooLongMessage))
        case 429:
            return .server(status: 429, message: plainOr(message, tooManyRunningMessage))
        default:
            return error
        }
    }

    /// The server's sentence where it wrote one in plain words, else ours.
    private static func plainOr(_ message: String, _ fallback: String) -> String {
        message.isEmpty || message.hasPrefix("The server returned status") ? fallback : message
    }

    func job(id: String) async throws -> AnalysisJob {
        let job: AnalysisJob
        do {
            job = try await withRetry {
                let request = try await client.makeRequest("GET", "/analysis/job", query: ["id": id])
                return try await client.send(request, as: AnalysisJob.self)
            }
        } catch APIError.server(status: 404, _) {
            throw APIError.server(status: 404, message: Self.lostJobMessage)
        }
        try CaseService.throwIfUnsuccessful(success: job.success, error: job.error)
        return job
    }

    func history(tool: AnalysisJobTool?) async throws -> [AnalysisRunSummary] {
        let query = tool.map { ["tool": $0.rawValue] } ?? [:]
        let response = try await withRetry {
            let request = try await client.makeRequest("GET", "/analysis/history", query: query)
            return try await client.send(request, as: AnalysisHistoryResponse.self)
        }
        try CaseService.throwIfUnsuccessful(success: response.success, error: response.error)
        return response.runs ?? []
    }

    func run(id: String) async throws -> AnalysisRun {
        let response: AnalysisRunResponse
        do {
            response = try await withRetry {
                let request = try await client.makeRequest("GET", "/analysis/run", query: ["id": id])
                return try await client.send(request, as: AnalysisRunResponse.self)
            }
        } catch APIError.server(status: 404, _) {
            throw APIError.server(status: 404, message: Self.runGoneMessage)
        }
        try CaseService.throwIfUnsuccessful(success: response.success, error: response.error)
        guard let run = response.run else { throw APIError.server(status: 404, message: Self.runGoneMessage) }
        return run
    }

    func deleteRun(id: String) async throws {
        let request = try await client.makeRequest("DELETE", "/analysis/run", query: ["id": id])
        let response: AnalysisDeleteResponse
        do {
            response = try await client.send(request, as: AnalysisDeleteResponse.self)
        } catch APIError.server(status: 404, _) {
            // Already gone: the list is what the person wanted.
            return
        }
        try CaseService.throwIfUnsuccessful(success: response.success, error: response.error)
    }

    private struct Payload: Encodable {
        let body: [String: JSONValue]
        func encode(to encoder: Encoder) throws { try body.encode(to: encoder) }
    }
}
