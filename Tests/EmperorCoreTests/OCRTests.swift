import XCTest
@testable import EmperorCore

final class OCRTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: - Language

    /// **Omitting `lang` silently translates to Hindi** (`sync-server.js:12118`). So the
    /// digitise-only case needs an explicit value, and `Original` is it.
    func testDigitiseOnlyIsAnExplicitValueNotAnOmission() {
        XCTAssertEqual(OCRLanguage.original.rawValue, "Original")
        XCTAssertFalse(OCRLanguage.original.translates, "Original must skip translation")
        XCTAssertTrue(OCRLanguage.hindi.translates)
    }

    /// The server skips translation for `none|original|english|en` — so "English" means "leave
    /// it as it is", not "translate to English". Offering it as a target would mislead.
    func testEnglishIsNotOfferedAsATargetBecauseItIsANoOp() {
        XCTAssertFalse(OCRLanguage.translates("English"))
        XCTAssertFalse(OCRLanguage.translates("en"))
        XCTAssertFalse(OCRLanguage.translates("none"))
        XCTAssertFalse(
            OCRLanguage.allCases.contains { $0.rawValue.lowercased() == "english" },
            "an 'English' option would silently do nothing")
    }

    func testTheLanguageListIsNonTrivial() {
        XCTAssertGreaterThan(OCRLanguage.allCases.count, 20)
        XCTAssertTrue(OCRLanguage.allCases.contains(.hindi))
        XCTAssertTrue(OCRLanguage.allCases.contains(.tamil))
    }

    // MARK: - Job decoding

    /// **Every field except `status` must be optional.** A global clear wipes the server's job
    /// map, and the completion path then re-inserts the job by spreading an `undefined` —
    /// producing a row with no fileName, no targetLang and no logs. Non-optional fields crash
    /// on it.
    func testAJobStrippedBySomeoneElsesClearStillDecodes() throws {
        let job = try decode(OCRJob.self, #"{"status":"completed","progress":100}"#)

        XCTAssertEqual(job.state, .completed)
        XCTAssertNil(job.fileName)
        XCTAssertNil(job.targetLang)
        XCTAssertNil(job.logs)
    }

    func testJobStatesMapAndKnowWhichAreTerminal() {
        XCTAssertEqual(OCRJobState(wire: "starting"), .starting)
        XCTAssertEqual(OCRJobState(wire: "processing"), .running)
        XCTAssertEqual(OCRJobState(wire: "completed"), .completed)
        XCTAssertEqual(OCRJobState(wire: "failed"), .failed)
        XCTAssertEqual(OCRJobState(wire: "something-new"), .unknown("something-new"))

        XCTAssertTrue(OCRJobState.completed.isTerminal)
        XCTAssertTrue(OCRJobState.failed.isTerminal)
        XCTAssertFalse(OCRJobState.starting.isTerminal)
        XCTAssertFalse(
            OCRJobState.unknown("x").isTerminal,
            "an unrecognised state must not be mistaken for finished")
    }

    /// **`status == "completed"` does not mean "translated".** A failed translation is a WARN
    /// log line and the job completes carrying the *original* text. There is no field on the
    /// wire for this — the log is the only signal.
    func testACompletedJobWithAFailedTranslationIsFlagged() throws {
        let job = try decode(OCRJob.self, """
            {"status":"completed","targetLang":"Hindi","logs":[
              {"timestamp":"12:00:01","message":"Reading page 1"},
              {"timestamp":"12:00:09","message":"WARN: translation failed (upstream 429) — keeping original text."}
            ]}
            """)

        XCTAssertEqual(job.state, .completed)
        XCTAssertTrue(job.translationMayBeIncomplete)
    }

    /// **`/ocr-status` returns `logs` as plain strings**, not objects — `addLog` pushes the raw
    /// message (`sync-server.js:12163-12167`). Modelling only the object shape made the entire
    /// feature fail silently: the first poll threw `typeMismatch`, the poll loop swallowed it,
    /// and the job spun forever with no error and no result.
    func testLogsDecodeFromThePlainStringArrayTheStatusRouteActuallyReturns() throws {
        let job = try decode(OCRJob.self, """
            {"status":"processing","logs":["[Step 1] Auditing document…","[Step 2] Reading page 3"]}
            """)

        XCTAssertEqual(job.logs?.count, 2)
        XCTAssertEqual(job.logs?.first?.message, "[Step 1] Auditing document…")
        XCTAssertNil(job.logs?.first?.timestamp, "the status route carries no timestamp")
    }

    /// The SSE channel wraps them — and keys the text `msg`, not `message`. Both shapes decode.
    func testLogsAlsoDecodeTheSSEObjectShape() throws {
        let job = try decode(OCRJob.self, """
            {"status":"processing","logs":[{"msg":"Reading page 3","timestamp":"12:00:01"}]}
            """)

        XCTAssertEqual(job.logs?.first?.message, "Reading page 3")
        XCTAssertEqual(job.logs?.first?.timestamp, "12:00:01")
    }

    /// The translation caveat is derived from those strings, so it has to survive the real shape.
    func testTheTranslationCaveatWorksAgainstTheRealStringLogs() throws {
        let job = try decode(OCRJob.self, """
            {"status":"completed","targetLang":"Hindi",
             "logs":["Reading page 1","WARN: translation failed (upstream 429) — keeping original text."]}
            """)
        XCTAssertTrue(job.translationMayBeIncomplete)
    }

    /// A job that 404s on every poll — which is what a global clear produces — must still hit
    /// the deadline. Checking the clock only after a *successful* fetch made the timeout
    /// unreachable in exactly the case it exists for.
    func testAJobThatFailsEveryPollStillHitsTheDeadline() async {
        let clock = MutableClock(start: Date(timeIntervalSince1970: 1_789_365_600))
        await withOCR(clock: clock) { service, model in
            service.job = OCRJob(
                id: "job_1", status: "starting", step: 0, progress: 0, fileName: "Order.pdf",
                targetLang: "Hindi", pageSetup: nil, logs: [], error: nil, outputFile: nil)
            await model.submit(data: Data("%PDF".utf8), fileName: "Order.pdf")

            // The job is wiped server-side; every later poll 404s.
            service.statusError = APIError.server(status: 404, message: "not found")
            await model.pollOnce()
            XCTAssertNil(model.errorMessage, "one failure is not a stall")

            clock.advance(by: OCRViewModel.stallTimeout + 10)
            let finished = await model.pollOnce()

            XCTAssertTrue(finished, "polling must stop rather than run until the battery dies")
            XCTAssertNotNil(model.errorMessage)
        }
    }

    func testACleanTranslationIsNotFlagged() throws {
        let job = try decode(OCRJob.self, """
            {"status":"completed","targetLang":"Hindi","logs":[
              {"timestamp":"12:00:01","message":"Translated 12 pages"}]}
            """)
        XCTAssertFalse(job.translationMayBeIncomplete)
    }

    /// A digitise-only job cannot have a failed translation, because it never ran one.
    func testADigitiseOnlyJobIsNeverFlaggedForTranslation() throws {
        let job = try decode(OCRJob.self, """
            {"status":"completed","targetLang":"Original","logs":[
              {"timestamp":"12:00:09","message":"WARN: translation failed"}]}
            """)
        XCTAssertFalse(job.translationMayBeIncomplete)
    }

    // MARK: - Submission

    /// The multipart parser matches the **first** `name="` in a part header, and `name="` is a
    /// substring of `filename="`. Written the other way round, the field name is read as the
    /// filename and the upload 500s with "Missing file".
    func testTheFilePartWritesNameBeforeFilename() async throws {
        let (service, _) = try await makeService()
        HTTPStub.always(.json(#"{"success":true,"jobId":"job_1"}"#))

        _ = try await service.submit(
            data: Data("%PDF-1.4".utf8), fileName: "Order.pdf", language: .hindi)

        let body = String(
            decoding: HTTPStub.lastRequest?.httpBody ?? Data(), as: UTF8.self)
        let namePosition = try XCTUnwrap(body.range(of: "name=\"file\""))
        let filenamePosition = try XCTUnwrap(body.range(of: "filename=\"Order.pdf\""))
        XCTAssertLessThan(namePosition.lowerBound, filenamePosition.lowerBound)
    }

    /// `lang` is always sent, because omitting it means Hindi.
    func testLanguageIsAlwaysSentEvenForDigitiseOnly() async throws {
        let (service, _) = try await makeService()
        HTTPStub.always(.json(#"{"success":true,"jobId":"job_1"}"#))

        _ = try await service.submit(
            data: Data("%PDF".utf8), fileName: "Order.pdf", language: .original)

        let body = String(decoding: HTTPStub.lastRequest?.httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"lang\""))
        XCTAssertTrue(body.contains("\r\n\r\nOriginal\r\n"))
    }

    /// `splitBuffer` scans the whole body including the PDF bytes, so a short boundary that
    /// happens to occur inside the file silently truncates the upload — with a 200.
    func testTheBoundaryIsLongAndRandom() async throws {
        let (service, _) = try await makeService()
        HTTPStub.always(.json(#"{"success":true,"jobId":"job_1"}"#))

        _ = try await service.submit(
            data: Data("%PDF".utf8), fileName: "Order.pdf", language: .hindi)

        let contentType = try XCTUnwrap(HTTPStub.lastRequest?.header("Content-Type"))
        let boundary = String(contentType.split(separator: "=").last ?? "")
        XCTAssertGreaterThan(boundary.count, 60, "long enough not to collide with file bytes")
        XCTAssertFalse(contentType.contains("\""), "a quoted boundary breaks the naive parser")
        XCTAssertFalse(contentType.contains("charset"), "nothing may follow the boundary")
    }

    // MARK: - Polling and stalls

    /// A job orphaned by a server restart stays `"starting"` forever — there is no sweeper, no
    /// TTL and no delete. Without a client deadline the app polls a dead job indefinitely.
    func testAStalledJobIsGivenUpOnRatherThanPolledForever() async {
        let clock = MutableClock(start: Date(timeIntervalSince1970: 1_789_365_600))
        await withOCR(clock: clock) { service, model in
            service.job = OCRJob(
                id: "job_1", status: "starting", step: 0, progress: 0,
                fileName: "Order.pdf", targetLang: "Hindi", pageSetup: nil,
                logs: [], error: nil, outputFile: nil)
            await model.submit(data: Data("%PDF".utf8), fileName: "Order.pdf")

            // First poll establishes the baseline — the job is genuinely "starting".
            await model.pollOnce()
            XCTAssertNil(model.errorMessage, "one observation is not a stall")

            // Now nothing changes and the clock runs past the deadline.
            clock.advance(by: OCRViewModel.stallTimeout + 10)
            await model.pollOnce()

            XCTAssertNotNil(model.errorMessage)
            XCTAssertTrue(model.errorMessage?.contains("interrupted") == true)
        }
    }

    /// Progress that is still moving must not be mistaken for a stall.
    func testAJobThatIsStillMovingIsNotGivenUpOn() async {
        let clock = MutableClock(start: Date(timeIntervalSince1970: 1_789_365_600))
        await withOCR(clock: clock) { service, model in
            service.job = OCRJob(
                id: "job_1", status: "processing", step: 1, progress: 10,
                fileName: "Order.pdf", targetLang: "Hindi", pageSetup: nil,
                logs: [], error: nil, outputFile: nil)
            await model.submit(data: Data("%PDF".utf8), fileName: "Order.pdf")
            await model.pollOnce()

            clock.advance(by: OCRViewModel.stallTimeout - 10)
            service.job?.progress = 40
            await model.pollOnce()

            XCTAssertNil(model.errorMessage)
            XCTAssertTrue(model.isRunning)
        }
    }

    func testACompletedJobDownloadsItsResult() async {
        await withOCR { service, model in
            service.job = OCRJob(
                id: "job_1", status: "completed", step: 5, progress: 100,
                fileName: "Order.pdf", targetLang: "Hindi", pageSetup: nil,
                logs: [], error: nil, outputFile: "Order_Hindi.docx")
            await model.submit(data: Data("%PDF".utf8), fileName: "Order.pdf")
            await model.pollOnce()

            XCTAssertNotNil(model.result)
            XCTAssertEqual(model.result?.fileName, "Order_Hindi.docx")
            XCTAssertNil(model.resultCaveat, "a clean run carries no caveat")
        }
    }

    /// The caveat has to reach the user: they are about to rely on a document they believe is
    /// translated.
    func testAnIncompleteTranslationProducesACaveat() async {
        await withOCR { service, model in
            service.job = OCRJob(
                id: "job_1", status: "completed", step: 5, progress: 100,
                fileName: "Order.pdf", targetLang: "Hindi", pageSetup: nil,
                logs: [OCRLogLine(timestamp: "t", message: "WARN: translation empty — keeping original text.")],
                error: nil, outputFile: "Order_Hindi.docx")
            await model.submit(data: Data("%PDF".utf8), fileName: "Order.pdf")
            await model.pollOnce()

            XCTAssertEqual(model.result?.translationMayBeIncomplete, true)
            XCTAssertNotNil(model.resultCaveat)
            XCTAssertTrue(model.resultCaveat?.contains("original language") == true)
        }
    }

    // MARK: - Helpers

    private func makeService() async throws -> (OCRService, APIClient) {
        let client = APIClient(
            config: APIConfig(baseURL: URL(string: "https://example.test/api")!),
            session: HTTPStub.session())
        await client.setCredentials(Credentials(token: "t", userID: 42))
        return (OCRService(client: client), client)
    }

    /// Before each test, not only after. `tearDown` alone leaves the **first** test in the class
    /// reading whatever the previous suite left in `HTTPStub.seen`. See `HTTPStub.reset`.
    override func setUp() {
        super.setUp()
        HTTPStub.reset()
    }

    override func tearDown() {
        HTTPStub.reset()
        super.tearDown()
    }
}

/// A clock the test moves by hand, so a stall can be exercised without waiting for one.
final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(start: Date) { current = start }

    var now: Date { lock.withLock { current } }
    func advance(by interval: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(interval) }
    }
}

@MainActor
private func withOCR(
    clock: MutableClock = MutableClock(start: Date(timeIntervalSince1970: 1_789_365_600)),
    _ body: @MainActor (FakeOCR, OCRViewModel) async -> Void
) async {
    let service = FakeOCR()
    let model = OCRViewModel(service: service, now: { clock.now })
    await body(service, model)
    model.cancelPolling()
}
