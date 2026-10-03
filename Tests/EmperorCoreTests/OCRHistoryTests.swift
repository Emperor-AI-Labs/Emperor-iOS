import XCTest
@testable import EmperorCore

/// Translation history, and the PDF to Word mode of the same screen.
///
/// The JSON here is shaped as `sync-server.js` writes it today: `/ocr-status` answers with the
/// job as the whole body, `/ocr-history` with a bare array of `{id, ...job}`
/// (`sync-server.js:15631-15680`), and a job carries the page setup as the object `JSON.parse`
/// made of it.
final class OCRHistoryTests: XCTestCase {

    /// One job exactly as the pipeline records it at the end of a run.
    private let completedJob = """
        {"id":"1790000000000","status":"completed","step":5,"progress":100,
         "fileName":"Partition_Suit_Order.pdf","targetLang":"Hindi",
         "pageSetup":{"size":"A4","orientation":"portrait","margins":{"top":1}},
         "logs":["[Step 1] Auditing document…","COMPLETE: Document digitized, translated, and rendered to DOCX."],
         "userId":"42","admin":false,
         "outputFile":"1790000000000_Partition_Suit_Order_Hindi.docx",
         "markdownFile":"1790000000000_Partition_Suit_Order_Hindi.md",
         "engine":"layout","pages":3,"digitalPages":1,"scannedPages":2,"warnings":[]}
        """

    override func setUp() {
        super.setUp()
        HTTPStub.reset()
    }

    override func tearDown() {
        HTTPStub.reset()
        super.tearDown()
    }

    // MARK: - Decoding

    /// **The page setup is an object on the wire.** Modelled as a string, it failed every job
    /// that carried one — and with it the whole history listing.
    func testAJobWithAnObjectPageSetupDecodes() throws {
        let job = try JSONDecoder().decode(OCRJob.self, from: Data(completedJob.utf8))
        XCTAssertEqual(job.state, .completed)
        XCTAssertEqual(job.ownerID, "42")
        if case .object(let setup)? = job.pageSetup {
            XCTAssertEqual(setup["size"], .string("A4"))
        } else {
            XCTFail("the page setup should survive as JSON")
        }
    }

    /// `/ocr-status` returns the job itself, not `{job: …}`.
    func testTheStatusRouteBodyIsTheJobItself() throws {
        let response = try JSONDecoder().decode(OCRStatusResponse.self, from: Data(completedJob.utf8))
        XCTAssertEqual(response.resolvedJob?.outputFile, "1790000000000_Partition_Suit_Order_Hindi.docx")
        XCTAssertEqual(response.resolvedJob?.progress, 100)

        let nested = try JSONDecoder().decode(
            OCRStatusResponse.self, from: Data(#"{"success":true,"job":{"status":"starting"}}"#.utf8))
        XCTAssertEqual(nested.resolvedJob?.state, .starting, "the older nested shape still reads")

        let missing = try JSONDecoder().decode(
            OCRStatusResponse.self, from: Data(#"{"error":"Job not found"}"#.utf8))
        XCTAssertNil(missing.resolvedJob)
    }

    /// Records round-trip through a JSON file, and an older writer stored numbers.
    func testOwnerAndProgressAreReadLeniently() throws {
        let job = try JSONDecoder().decode(
            OCRJob.self, from: Data(#"{"status":"starting","userId":42,"progress":37.5,"step":2}"#.utf8))
        XCTAssertEqual(job.ownerID, "42")
        XCTAssertEqual(job.progress, 37)
        XCTAssertEqual(job.step, 2)
    }

    /// One unreadable entry must not cost the user the list.
    func testOneUnreadableJobDoesNotFailTheListing() throws {
        let body = "[\(completedJob), {\"no\":\"status\"}, 7, {\"status\":\"failed\",\"userId\":\"42\"}]"
        let response = try JSONDecoder().decode(OCRHistoryResponse.self, from: Data(body.utf8))
        XCTAssertEqual(response.jobs.count, 2)
        XCTAssertEqual(response.unreadable, 2)
    }

    // MARK: - What a row shows

    /// Results are stored as `<jobId>_<name>`; the server strips that when it serves the file,
    /// so the saved name should not carry it either.
    func testTheDownloadNameDropsTheStoragePrefix() throws {
        let job = try JSONDecoder().decode(OCRJob.self, from: Data(completedJob.utf8))
        XCTAssertEqual(job.downloadName, "Partition_Suit_Order_Hindi.docx")

        var short = job
        short.outputFile = "12345_Order.docx"
        XCTAssertEqual(short.downloadName, "12345_Order.docx", "under ten digits is part of the name")
        short.outputFile = "1790000000000Order.docx"
        XCTAssertEqual(short.downloadName, "1790000000000Order.docx", "no underscore, no prefix")
    }

    func testTheRowIsDatedByItsIdAndNamedAsTheUserWouldWriteIt() throws {
        let job = try JSONDecoder().decode(OCRJob.self, from: Data(completedJob.utf8))
        XCTAssertEqual(job.createdAt, Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(job.displayName, "Partition Suit Order.pdf")
        XCTAssertEqual(job.languageLabel, "Hindi")

        var original = job
        original.targetLang = "Original"
        XCTAssertEqual(original.languageLabel, "Original language")
        original.id = "job_1"
        XCTAssertNil(original.createdAt, "an id that is not a timestamp gives no date rather than 1970")
        original.fileName = nil
        XCTAssertEqual(original.displayName, "Untitled document")
    }

    // MARK: - The service

    func testHistoryIsReadFreshAndNarrowedToThisAccount() async throws {
        let service = try await makeService(userID: 42)
        HTTPStub.always(.json("""
            [\(completedJob),
             {"id":"1789000000000","status":"completed","userId":"7","fileName":"Someone_Else.pdf"},
             {"id":"1788000000000","status":"completed","fileName":"Legacy.pdf"}]
            """))

        let history = try await service.history()

        XCTAssertEqual(history.jobs.map(\.fileName), ["Partition_Suit_Order.pdf"])
        XCTAssertTrue(history.listedOtherJobs, "the listing covered jobs this screen does not show")
        let request = try XCTUnwrap(HTTPStub.lastRequest)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/api/ocr-history")
        XCTAssertEqual(request.header("Authorization"), "Bearer t")
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testAnOrdinaryAccountsHistoryIsClearable() async throws {
        let service = try await makeService(userID: 42)
        HTTPStub.always(.json("[\(completedJob)]"))
        let history = try await service.history()
        XCTAssertEqual(history.jobs.count, 1)
        XCTAssertFalse(history.listedOtherJobs)
    }

    func testClearIsAPostToTheClearRoute() async throws {
        let service = try await makeService(userID: 42)
        HTTPStub.always(.json(#"{"success":true}"#))
        try await service.clearHistory()
        let request = try XCTUnwrap(HTTPStub.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/ocr-clear")
    }

    func testAFailedClearIsAnError() async throws {
        let service = try await makeService(userID: 42)
        HTTPStub.always(.json(#"{"error":"disk"}"#, status: 500))
        do {
            try await service.clearHistory()
            XCTFail("a 500 must not read as cleared")
        } catch {
            XCTAssertEqual(DisplayText.message(for: error), "disk")
        }
    }

    /// A result is served only while its job is in this account's history, so a 404 means the
    /// document is gone — and the message says that rather than "could not download".
    func testAGoneDocumentIsDescribedAsGone() async throws {
        let service = try await makeService(userID: 42)
        HTTPStub.always(.json(#"{"error":"File not found"}"#, status: 404))
        do {
            _ = try await service.download(outputFile: "1790000000000_Order.docx")
            XCTFail("a 404 must throw")
        } catch {
            XCTAssertTrue(DisplayText.message(for: error).contains("no longer available"))
        }
        XCTAssertEqual(
            HTTPStub.lastRequest?.url?.query?.contains("file=1790000000000_Order.docx"), true,
            "the stored name is what the server is asked for, not the display name")
    }

    // MARK: - The screen

    func testHistoryLoadsAndAFinishedRowOpens() async {
        await withHistoryModel { service, model in
            service.historyJobs = [job(id: "1790000000000", status: "completed", output: "1790000000000_Order.docx")]
            await model.loadHistory()
            XCTAssertEqual(model.history.count, 1)
            XCTAssertTrue(model.historyPresentation.state.hasLoaded)
            XCTAssertTrue(model.canClearHistory)

            await model.open(model.history[0])
            XCTAssertEqual(service.downloaded, ["1790000000000_Order.docx"])
            XCTAssertEqual(model.opened?.fileName, "Order.docx")
            XCTAssertNil(model.openingJobID)
        }
    }

    func testAnUnfinishedRowDoesNotTryToOpen() async {
        await withHistoryModel { service, model in
            await model.open(job(id: "1", status: "starting", output: nil))
            await model.open(job(id: "2", status: "failed", output: "2_x.docx"))
            XCTAssertTrue(service.downloaded.isEmpty)
            XCTAssertNil(model.opened)
        }
    }

    /// "The server says you have nothing" is not "we could not ask".
    func testAFailedLoadIsAFailureNotAnEmptyHistory() async {
        await withHistoryModel { service, model in
            service.historyError = APIError.transport("offline")
            await model.loadHistory()
            XCTAssertTrue(model.historyPresentation.showsFailureState)
            XCTAssertFalse(model.historyPresentation.showsEmptyState)
            XCTAssertFalse(model.canClearHistory)
        }
    }

    func testAnEmptyHistoryIsSaidAsEmpty() async {
        await withHistoryModel { _, model in
            await model.loadHistory()
            XCTAssertTrue(model.historyPresentation.showsEmptyState)
            XCTAssertFalse(model.canClearHistory, "nothing to clear")
        }
    }

    /// Clearing removes everything the listing covered. When that was more than this screen
    /// shows, the control is not offered at all.
    func testClearIsWithheldWhenTheListingCoveredOtherJobs() async {
        await withHistoryModel { service, model in
            service.historyJobs = [job(id: "1", status: "completed", output: "1_x.docx")]
            service.historyListedOthers = true
            await model.loadHistory()
            XCTAssertFalse(model.canClearHistory)
            await model.clearHistory()
            XCTAssertEqual(service.clearCalls, 0)
        }
    }

    func testClearingEmptiesTheListAndAsksAgain() async {
        await withHistoryModel { service, model in
            service.historyJobs = [
                job(id: "1", status: "completed", output: "1_x.docx"),
                job(id: "2", status: "starting", output: nil),
            ]
            await model.loadHistory()
            XCTAssertTrue(model.clearHistoryConfirmation.contains("2 documents"))
            XCTAssertTrue(
                model.clearHistoryConfirmation.contains("1 still being read"),
                "a job still running elsewhere goes too, and the confirmation says so")

            await model.clearHistory()
            XCTAssertEqual(service.clearCalls, 1)
            XCTAssertTrue(model.history.isEmpty)
            XCTAssertEqual(service.historyCalls, 2, "re-read after clearing rather than assumed")
        }
    }

    /// Clearing would remove the job this screen is waiting on.
    func testClearIsWithheldWhileThisScreensOwnDocumentIsBeingRead() async {
        await withHistoryModel { service, model in
            service.job = job(id: "1790000000001", status: "starting", output: nil)
            service.historyJobs = [job(id: "1", status: "completed", output: "1_x.docx")]
            await model.submit(data: Data("%PDF".utf8), fileName: "Order.pdf")
            await model.loadHistory()
            XCTAssertTrue(model.isRunning)
            XCTAssertFalse(model.canClearHistory)
        }
    }

    /// The live job is shown once, as progress — not again as a history row.
    func testTheRunningJobIsNotListedTwice() async {
        await withHistoryModel { service, model in
            let live = job(id: "job_live", status: "starting", output: nil)
            service.job = live
            service.historyJobs = [live, job(id: "1", status: "completed", output: "1_x.docx")]
            await model.submit(data: Data("%PDF".utf8), fileName: "Order.pdf")
            await model.loadHistory()
            XCTAssertEqual(model.visibleHistory.map(\.id), ["1"])
        }
    }

    func testAFinishedJobRefreshesTheHistory() async {
        await withHistoryModel { service, model in
            service.job = job(id: "1790000000002", status: "completed", output: "1790000000002_Order.docx")
            await model.submit(data: Data("%PDF".utf8), fileName: "Order.pdf")
            await model.pollOnce()
            XCTAssertEqual(service.historyCalls, 1)
            XCTAssertEqual(model.result?.fileName, "Order.docx", "saved without the storage prefix")
        }
    }

    /// Between the upload's answer and the first poll there is no job yet. That gap used to read
    /// as "nothing running" and flashed the pickers back for two seconds.
    func testASubmittedJobCountsAsRunningBeforeItsFirstStatus() async {
        await withHistoryModel { service, model in
            service.job = job(id: "1", status: "starting", output: nil)
            await model.submit(data: Data("%PDF".utf8), fileName: "Order.pdf")
            XCTAssertNil(model.job)
            XCTAssertTrue(model.isRunning)
        }
    }

    /// A stalled job's last state is still "running". Giving up must end the run, or the screen
    /// sits on a progress bar with no way to start again.
    func testGivingUpOnAStalledJobLetsTheUserStartAgain() async {
        let clock = MutableClock(start: Date(timeIntervalSince1970: 1_789_365_600))
        let service = FakeOCR()
        await givingUp(service: service, clock: clock)
    }

    /// The server's reason for a failed job is the one thing the user can act on.
    func testAFailedJobSaysWhy() async {
        await withHistoryModel { service, model in
            var failed = job(id: "1", status: "failed", output: nil)
            failed.error = "This PDF is password-protected."
            service.job = failed
            await model.submit(data: Data("%PDF".utf8), fileName: "Order.pdf")
            await model.pollOnce()
            XCTAssertFalse(model.isRunning)
            XCTAssertEqual(model.errorMessage, "This PDF is password-protected.")
        }
    }

    /// The web refuses an upload over its proxy's limit before sending it; so does this, rather
    /// than spending minutes uploading a file that comes back as an HTML error page.
    func testAnOversizedUploadIsRefusedBeforeItIsSent() async {
        await withHistoryModel { service, model in
            await model.submit(data: Data(count: OCRViewModel.maxUploadBytes + 1), fileName: "Huge.pdf")
            XCTAssertTrue(service.submitted.isEmpty)
            XCTAssertEqual(model.errorMessage, OCRViewModel.tooLargeMessage)
            XCTAssertFalse(model.isRunning)
        }
    }

    // MARK: - PDF to Word

    /// The web's PDF to DOCX is this same pipeline locked to digitise-only
    /// (`OCRTranslate.jsx:511-513`). Whatever the language control last held, it sends Original.
    func testPDFToWordNeverTranslates() async {
        await withHistoryModel(mode: .pdfToWord) { service, model in
            model.language = .tamil
            service.job = job(id: "1", status: "starting", output: nil)
            await model.submit(data: Data("%PDF".utf8), fileName: "Brief.pdf")
            XCTAssertEqual(service.submitted.first?.language, .original)
        }
    }

    func testTranslateSendsTheChosenLanguage() async {
        await withHistoryModel { service, model in
            model.language = .english
            service.job = job(id: "1", status: "starting", output: nil)
            await model.submit(data: Data("%PDF".utf8), fileName: "Order.pdf")
            XCTAssertEqual(service.submitted.first?.language, .english)
        }
    }

    // MARK: - Helpers

    private func makeService(userID: Int) async throws -> OCRService {
        let client = APIClient(
            config: APIConfig(baseURL: URL(string: "https://example.test/api")!),
            session: HTTPStub.session())
        await client.setCredentials(Credentials(token: "t", userID: userID))
        return OCRService(client: client)
    }
}

private func job(id: String, status: String, output: String?) -> OCRJob {
    OCRJob(
        id: id, status: status, step: nil, progress: nil, fileName: "Order.pdf",
        targetLang: "Hindi", pageSetup: nil, logs: [], error: nil, outputFile: output,
        ownerID: "42")
}

@MainActor
private func givingUp(service: FakeOCR, clock: MutableClock) async {
    let model = OCRViewModel(service: service, now: { clock.now })
    service.job = job(id: "1", status: "starting", output: nil)
    await model.submit(data: Data("%PDF".utf8), fileName: "Order.pdf")
    await model.pollOnce()
    XCTAssertTrue(model.isRunning)

    clock.advance(by: OCRViewModel.stallTimeout + 10)
    let stopped = await model.pollOnce()

    XCTAssertTrue(stopped)
    XCTAssertEqual(model.errorMessage, OCRViewModel.stalledMessage)
    XCTAssertFalse(model.isRunning, "the pickers come back so another try is possible")
    model.cancelPolling()
}

@MainActor
private func withHistoryModel(
    mode: OCRViewModel.Mode = .translate,
    _ body: @MainActor (FakeOCR, OCRViewModel) async -> Void
) async {
    let service = FakeOCR()
    let model = OCRViewModel(service: service, mode: mode)
    await body(service, model)
    model.cancelPolling()
}
