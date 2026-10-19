import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import EmperorCore

/// The analysis routes on the wire: paths, query, body keys, and how each failure is worded.
final class AnalysisServiceWireTests: XCTestCase {

    private static let config = APIConfig(baseURL: URL(string: "https://example.test/api")!)

    override func setUp() {
        super.setUp()
        HTTPStub.reset()
    }

    override func tearDown() {
        HTTPStub.reset()
        super.tearDown()
    }

    private func makeService() async -> AnalysisService {
        let client = APIClient(config: Self.config, session: HTTPStub.session())
        await client.setCredentials(Credentials(token: "tok-abc", userID: 42))
        var service = AnalysisService(client: client)
        service.newRunID = { "run-fixed" }
        return service
    }

    private let plaint = ChatAttachment(name: "Plaint.pdf", folderName: "Uploads")
    private let order = ChatAttachment(name: "Order.pdf", folderName: "Cases/Helios")

    // MARK: - Start

    func testStartSendsTheWebsBodyAndReturnsTheJobID() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":true,"jobId":"job-1"}"#, status: 202))

        let id = try await service.start(tool: .listOfDates, files: [plaint, order, plaint], reference: "  We act for Helios.  \n")

        XCTAssertEqual(id, "job-1")
        let sent = try XCTUnwrap(HTTPStub.lastRequest)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.path, "/api/analysis/start")
        XCTAssertEqual(sent.header("Authorization"), "Bearer tok-abc")
        let body = sent.bodyJSON
        XCTAssertEqual(Set(body.keys), ["userId", "tool", "chatId", "files", "reference"])
        XCTAssertEqual(body["userId"] as? String, "42")
        XCTAssertEqual(body["tool"] as? String, "list-of-dates")
        XCTAssertEqual(body["chatId"] as? String, "run-fixed")
        XCTAssertEqual(body["reference"] as? String, "We act for Helios.")
        let files = try XCTUnwrap(body["files"] as? [[String: String]])
        XCTAssertEqual(files, [["name": "Plaint.pdf", "folderName": "Uploads"], ["name": "Order.pdf", "folderName": "Cases/Helios"]])
    }

    func testTheRunIDIsARandomLowercaseUUIDByDefault() async {
        let client = APIClient(config: Self.config, session: HTTPStub.session())
        let id = AnalysisService(client: client).newRunID()
        XCTAssertNotNil(UUID(uuidString: id))
        XCTAssertEqual(id, id.lowercased())
    }

    func testTheNoteIsCappedAtTheServersLengthInUTF16() {
        let long = String(repeating: "क", count: 2100)
        XCTAssertEqual(AnalysisService.cleanReference(long).utf16.count, 2000)
        let emoji = String(repeating: "a", count: 1999) + "😀😀"
        // An emoji is two UTF-16 units: the one that would straddle the limit is left out whole.
        XCTAssertEqual(AnalysisService.cleanReference(emoji), String(repeating: "a", count: 1999))
        XCTAssertEqual(AnalysisService.cleanReference("  x  "), "x")
    }

    func testDocumentsTheToolsCannotReadAreRefusedBeforeAnythingIsSent() async {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":true,"jobId":"job-1"}"#, status: 202))
        let cases: [([ChatAttachment], String)] = [
            ([], AnalysisService.noFilesMessage),
            ([ChatAttachment(name: "Root.pdf")], AnalysisService.rootFileMessage),
            ([ChatAttachment(name: "Root.pdf", folderName: ".")], AnalysisService.rootFileMessage),
            ([ChatAttachment(name: "M.pdf", folderName: "_projects/p1/Pleadings")], AnalysisService.matterFileMessage),
            ((0..<11).map { ChatAttachment(name: "\($0).pdf", folderName: "Uploads") }, AnalysisService.tooManyFilesMessage),
        ]
        for (files, message) in cases {
            do {
                _ = try await service.start(tool: .docIndex, files: files, reference: "")
                XCTFail("expected a refusal for \(files)")
            } catch let error as APIError {
                XCTAssertEqual(error, .server(status: 400, message: message))
            } catch {
                XCTFail("unexpected \(error)")
            }
        }
        XCTAssertTrue(HTTPStub.seen.isEmpty)
    }

    func testTenDocumentsAreAllowed() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":true,"jobId":"job-1"}"#, status: 202))
        let ten = (0..<10).map { ChatAttachment(name: "\($0).pdf", folderName: "Uploads") }
        _ = try await service.start(tool: .docIndex, files: ten, reference: "")
        XCTAssertEqual((HTTPStub.lastRequest?.bodyJSON["files"] as? [Any])?.count, 10)
    }

    private func startError(_ status: Int, _ body: String) async -> APIError? {
        let service = await makeService()
        HTTPStub.always(.json(body, status: status))
        do {
            _ = try await service.start(tool: .devilsAdvocate, files: [plaint], reference: "")
            return nil
        } catch {
            return error as? APIError
        }
    }

    /// The plan refusals are worded by this client, never with the server's "Upgrade…".
    func testPlanRefusalsArriveAsRefusalsWordedHere() async {
        let required = await startError(402, #"{"success":false,"error":"Choose a plan to start using Emperor AI.","code":"PLAN_REQUIRED"}"#)
        XCTAssertEqual(required?.refusal?.code, .planRequired)

        let notInPlan = await startError(402, #"{"success":false,"error":"Upgrade to use analysis.","code":"FEATURE_NOT_IN_PLAN"}"#)
        XCTAssertEqual(notInPlan?.refusal?.code, .featureNotInPlan)

        let limit = await startError(402, #"{"success":false,"error":"This month’s queries are used up. Upgrade your plan to keep going.","code":"LIMIT"}"#)
        XCTAssertEqual(limit?.refusal?.code, .queryLimit)
        let message = DisplayText.message(for: limit!)
        XCTAssertEqual(message, "This account has used this month's questions.")
        XCTAssertFalse(message.contains("Upgrade"))
    }

    func testTooLongAndTooManyRunningKeepTheServersPlainWords() async {
        let long = await startError(413, #"{"success":false,"error":"These documents are too long to analyse in one go. Try fewer or shorter documents."}"#)
        XCTAssertEqual(long, .server(status: 413, message: "These documents are too long to analyse in one go. Try fewer or shorter documents."))
        let longBare = await startError(413, "")
        XCTAssertEqual(longBare, .server(status: 413, message: AnalysisService.tooLongMessage))
        let busy = await startError(429, #"{"success":false,"error":"You already have 2 analyses running. Wait for one to finish."}"#)
        XCTAssertEqual(busy, .server(status: 429, message: "You already have 2 analyses running. Wait for one to finish."))
        let busyBare = await startError(429, "{}")
        XCTAssertEqual(busyBare, .server(status: 429, message: AnalysisService.tooManyRunningMessage))
    }

    func testABadRequestKeepsTheServersSentence() async {
        let bad = await startError(400, #"{"success":false,"error":"At most 10 documents at a time"}"#)
        XCTAssertEqual(bad, .server(status: 400, message: "At most 10 documents at a time"))
    }

    // MARK: - Job

    func testTheJobIsAskedForByIDAndDecodesEachStatus() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":true,"status":"thinking","stage":"Reading Plaint.pdf (1 of 2)","progress":0.12}"#))

        let job = try await service.job(id: "job-1")

        let sent = try XCTUnwrap(HTTPStub.lastRequest)
        XCTAssertEqual(sent.httpMethod, "GET")
        XCTAssertEqual(sent.path, "/api/analysis/job")
        XCTAssertEqual(sent.queryItems, ["userId": "42", "id": "job-1"])
        XCTAssertEqual(job.status, .thinking)
        XCTAssertEqual(job.stage, "Reading Plaint.pdf (1 of 2)")
        XCTAssertEqual(job.progress, 0.12)
    }

    func testADoneJobCarriesItsResultRunAndUsage() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":true,"status":"done","stage":"Done","progress":1,"runId":"anr_9","usage":{"model":"m","inputTokens":10,"outputTokens":5,"costUsd":0.0012},"result":"# + AnalysisFixtures.devilsAdvocate + "}"))

        let job = try await service.job(id: "job-1")

        XCTAssertEqual(job.status, .done)
        XCTAssertEqual(job.runId, "anr_9")
        XCTAssertEqual(job.usage, AnalysisUsage(model: "m", inputTokens: 10, outputTokens: 5, costUsd: 0.0012))
        let result = try AnalysisResult.decode(try XCTUnwrap(job.result), tool: .devilsAdvocate)
        XCTAssertEqual(result.tool, .devilsAdvocate)
    }

    func testAnUnknownJobStatusIsAContractBreak() async {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":true,"status":"queued","stage":"","progress":0}"#))
        do {
            _ = try await service.job(id: "job-1")
            XCTFail("expected a decoding error")
        } catch let error as APIError {
            guard case .decoding = error else { return XCTFail("got \(error)") }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testAJobTheServerHasForgottenSaysToRunItAgain() async {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":false,"error":"This analysis is no longer running."}"#, status: 404))
        do {
            _ = try await service.job(id: "job-1")
            XCTFail("expected a 404")
        } catch let error as APIError {
            XCTAssertEqual(error, .server(status: 404, message: AnalysisService.lostJobMessage))
            XCTAssertTrue(DisplayText.message(for: error).hasSuffix("Run it again."))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: - History

    func testHistoryIsAskedPerToolOrForEveryTool() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"""
            {"success":true,"runs":[{"id":"anr_2","tool":"doc-index","title":"Our bundle","createdAt":"2026-10-16T09:30:00.000Z","fileNames":["a.pdf"],"reference":"","usage":{"model":"m","inputTokens":1,"outputTokens":2,"costUsd":0}},
              {"id":"anr_1","tool":"devils-advocate","title":"Helios v. Northgrid","createdAt":"2026-10-15 08:00:00","fileNames":[],"reference":"note","usage":null}]}
            """#))

        let runs = try await service.history(tool: .docIndex)
        XCTAssertEqual(HTTPStub.lastRequest?.path, "/api/analysis/history")
        XCTAssertEqual(HTTPStub.lastRequest?.queryItems, ["userId": "42", "tool": "doc-index"])
        XCTAssertEqual(runs.map(\.id), ["anr_2", "anr_1"])
        XCTAssertEqual(runs[1].tool, .devilsAdvocate)
        XCTAssertNil(runs[1].usage)
        XCTAssertNotNil(runs[1].createdDate)

        _ = try await service.history(tool: nil)
        XCTAssertEqual(HTTPStub.lastRequest?.queryItems, ["userId": "42"])
    }

    func testARunIsFetchedWithItsResult() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":true,"run":{"id":"anr_1","tool":"list-of-dates","title":"Helios","createdAt":"2026-10-16T09:30:00.000Z","fileNames":["a.pdf"],"reference":"","usage":null,"result":"# + AnalysisFixtures.listOfDates + "}}"))

        let run = try await service.run(id: "anr_1")

        XCTAssertEqual(HTTPStub.lastRequest?.path, "/api/analysis/run")
        XCTAssertEqual(HTTPStub.lastRequest?.httpMethod, "GET")
        XCTAssertEqual(HTTPStub.lastRequest?.queryItems, ["userId": "42", "id": "anr_1"])
        XCTAssertEqual(run.summary.tool, .listOfDates)
        XCTAssertEqual(try AnalysisResult.decode(run.result, tool: .listOfDates).tool, .listOfDates)
    }

    func testAMissingRunIsWordedOnce() async {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":false,"error":"No such saved analysis."}"#, status: 404))
        do {
            _ = try await service.run(id: "anr_x")
            XCTFail("expected a 404")
        } catch let error as APIError {
            XCTAssertEqual(error, .server(status: 404, message: AnalysisService.runGoneMessage))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testDeletingARunThatIsAlreadyGoneIsNotAnError() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":false,"error":"No such saved analysis."}"#, status: 404))
        try await service.deleteRun(id: "anr_1")
        XCTAssertEqual(HTTPStub.lastRequest?.httpMethod, "DELETE")
        XCTAssertEqual(HTTPStub.lastRequest?.path, "/api/analysis/run")
        XCTAssertEqual(HTTPStub.lastRequest?.queryItems, ["userId": "42", "id": "anr_1"])

        HTTPStub.always(.json(#"{"success":true}"#))
        try await service.deleteRun(id: "anr_1")
    }

    func testAFailedDeleteIsAnError() async {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":false,"error":"Could not delete."}"#, status: 403))
        do {
            try await service.deleteRun(id: "anr_1")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? APIError, .server(status: 403, message: "Could not delete."))
        }
    }
}
