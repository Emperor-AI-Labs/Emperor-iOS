import XCTest
@testable import EmperorCore

/// A stand-in analysis server: a script of job answers, served one per poll.
final class FakeAnalysis: AnalysisProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _startError: Error?
    private var _jobs: [Result<AnalysisJob, Error>] = []
    private var _starts: [(AnalysisJobTool, [ChatAttachment], String)] = []
    private var _polls = 0
    private var _history: Result<[AnalysisRunSummary], Error> = .success([])
    private var _historyAsked: [AnalysisJobTool?] = []
    private var _runs: [String: AnalysisRun] = [:]
    private var _deleteError: Error?
    private var _deleted: [String] = []

    func failStart(_ error: Error) { lock.withLock { _startError = error } }
    /// The answers to successive polls; the last one repeats.
    func script(_ jobs: [Result<AnalysisJob, Error>]) { lock.withLock { _jobs = jobs } }
    func setHistory(_ result: Result<[AnalysisRunSummary], Error>) { lock.withLock { _history = result } }
    func store(_ run: AnalysisRun) { lock.withLock { _runs[run.summary.id] = run } }
    func failDelete(_ error: Error?) { lock.withLock { _deleteError = error } }

    var starts: [(AnalysisJobTool, [ChatAttachment], String)] { lock.withLock { _starts } }
    var polls: Int { lock.withLock { _polls } }
    var historyAsked: [AnalysisJobTool?] { lock.withLock { _historyAsked } }
    var deleted: [String] { lock.withLock { _deleted } }

    func start(tool: AnalysisJobTool, files: [ChatAttachment], reference: String) async throws -> String {
        try lock.withLock {
            _starts.append((tool, files, reference))
            if let e = _startError { throw e }
            return "job-1"
        }
    }

    func job(id: String) async throws -> AnalysisJob {
        try lock.withLock {
            let index = min(_polls, _jobs.count - 1)
            _polls += 1
            return try _jobs[index].get()
        }
    }

    func history(tool: AnalysisJobTool?) async throws -> [AnalysisRunSummary] {
        try lock.withLock {
            _historyAsked.append(tool)
            return try _history.get()
        }
    }

    func run(id: String) async throws -> AnalysisRun {
        try lock.withLock {
            guard let run = _runs[id] else { throw APIError.server(status: 404, message: AnalysisService.runGoneMessage) }
            return run
        }
    }

    func deleteRun(id: String) async throws {
        try lock.withLock {
            if let e = _deleteError { throw e }
            _deleted.append(id)
        }
    }
}

private func analysisJob(_ status: AnalysisJob.Status, stage: String? = nil, progress: Double? = nil,
                 result: String? = nil, runId: String? = nil, error: String? = nil) -> Result<AnalysisJob, Error> {
    .success(AnalysisJob(
        success: true, status: status, stage: stage, progress: progress,
        result: result.map(AnalysisFixtures.value), runId: runId, error: error, usage: nil))
}

private let analysisUploads = ChatAttachment(name: "Plaint.pdf", folderName: "Uploads")

/// Linux XCTest cannot invoke a `@MainActor` test method — see `ChatViewModelTests`.
@MainActor
private func withRun(
    _ tool: AnalysisJobTool = .devilsAdvocate,
    maxPolls: Int = 750,
    _ body: @MainActor (FakeAnalysis, AnalysisRunViewModel) async -> Void
) async {
    let fake = FakeAnalysis()
    let model = AnalysisRunViewModel(tool: tool, service: fake, pollInterval: 0, maxPolls: maxPolls, sleep: { _ in })
    await body(fake, model)
}

@MainActor
private func withHistory(
    _ tool: AnalysisJobTool?,
    _ body: @MainActor (FakeAnalysis, AnalysisHistoryViewModel) async -> Void
) async {
    let fake = FakeAnalysis()
    await body(fake, AnalysisHistoryViewModel(tool: tool, service: fake))
}

final class AnalysisRunViewModelTests: XCTestCase {

    func testEachToolRunsFromStartThroughPollsToItsResult() async {
        let fixtures: [(AnalysisJobTool, String)] = [
            (.docIndex, AnalysisFixtures.docIndex),
            (.listOfDates, AnalysisFixtures.listOfDates),
            (.devilsAdvocate, AnalysisFixtures.devilsAdvocate),
        ]
        for (tool, fixture) in fixtures {
            await withRun(tool) { fake, model in
                fake.script([
                    analysisJob(.reading, stage: "Reading Plaint.pdf", progress: 0.05),
                    analysisJob(.thinking, stage: "Thinking", progress: 0.5),
                    analysisJob(.done, stage: "Done", progress: 1, result: fixture, runId: "anr_1"),
                ])
                model.setFiles([analysisUploads])
                model.reference = "  We act for Helios. "
                await model.start()

                XCTAssertEqual(fake.polls, 3)
                XCTAssertEqual(fake.starts.first?.0, tool)
                XCTAssertEqual(fake.starts.first?.1, [analysisUploads])
                guard case .done(let outcome) = model.phase else { return XCTFail("\(tool): \(model.phase)") }
                XCTAssertEqual(outcome.result.tool, tool)
                XCTAssertEqual(outcome.runID, "anr_1")
                XCTAssertEqual(outcome.fileNames, ["Plaint.pdf"])
                XCTAssertEqual(outcome.reference, "We act for Helios.")
                XCTAssertFalse(outcome.isFromHistory)
            }
        }
    }

    func testTheStageAndProgressFollowTheServerWhileItRuns() async {
        await withRun { fake, _ in
            fake.script([analysisJob(.writing, stage: "Checking the answer", progress: 0.9)])
            // The wait after the first poll is cancelled, so the run stops where it stood.
            let model = AnalysisRunViewModel(tool: .docIndex, service: fake, pollInterval: 0, sleep: { _ in
                throw CancellationError()
            })
            model.setFiles([analysisUploads])
            await model.start()
            XCTAssertEqual(model.phase, .running(stage: "Checking the answer", progress: 0.9))
        }
        await withRun { fake, _ in
            // A poll without a stage keeps the last line rather than blanking it.
            fake.script([analysisJob(.reading, stage: "  ", progress: nil)])
            let model = AnalysisRunViewModel(tool: .docIndex, service: fake, pollInterval: 0, sleep: { _ in
                throw CancellationError()
            })
            model.setFiles([analysisUploads])
            await model.start()
            XCTAssertEqual(model.phase, .running(stage: AnalysisRunViewModel.firstStage, progress: 0))
        }
    }

    func testAnErrorStatusShowsTheServersPlainWords() async {
        await withRun { fake, model in
            fake.script([analysisJob(.reading), analysisJob(.error, error: "The AI service is busy. Try again in a minute.")])
            model.setFiles([analysisUploads])
            await model.start()
            XCTAssertEqual(model.phase, .failed(AnalysisFailure(message: "The AI service is busy. Try again in a minute.")))
            if case .failed(let f) = model.phase { XCTAssertTrue(f.canRetry) }
        }
        await withRun { fake, model in
            fake.script([analysisJob(.error)])
            model.setFiles([analysisUploads])
            await model.start()
            XCTAssertEqual(model.phase, .failed(AnalysisFailure(message: AnalysisRunViewModel.failedMessage)))
        }
    }

    func testTryAgainAfterAFailedRunStartsItAgainWithTheSameInputs() async {
        await withRun { fake, model in
            fake.script([analysisJob(.error, error: "busy")])
            model.setFiles([analysisUploads])
            model.reference = "note"
            await model.start()
            fake.script([analysisJob(.done, result: AnalysisFixtures.devilsAdvocate)])
            await model.retry()
            XCTAssertEqual(fake.starts.count, 2)
            XCTAssertEqual(fake.starts.last?.2, "note")
            guard case .done = model.phase else { return XCTFail("\(model.phase)") }
        }
    }

    func testAJobTheServerLostSaysToRunItAgain() async {
        await withRun { fake, model in
            fake.script([analysisJob(.reading), .failure(APIError.server(status: 404, message: AnalysisService.lostJobMessage))])
            model.setFiles([analysisUploads])
            await model.start()
            XCTAssertEqual(model.phase, .failed(AnalysisFailure(message: AnalysisService.lostJobMessage)))
        }
    }

    func testAPlanRefusalIsWordedHereAndOffersNoRetry() async {
        await withRun { fake, model in
            let refusal = Refusal(code: .queryLimit, status: 402, serverMessage: "Upgrade your plan to keep going.")
            fake.failStart(APIError.refused(refusal))
            model.setFiles([analysisUploads])
            await model.start()
            guard case .failed(let failure) = model.phase else { return XCTFail("\(model.phase)") }
            XCTAssertEqual(failure.message, "This account has used this month's questions.")
            XCTAssertEqual(failure.refusal?.code, .queryLimit)
            XCTAssertFalse(failure.canRetry)
            XCTAssertEqual(fake.polls, 0)
        }
    }

    func testTooManyPollsGivesUpInPlainWords() async {
        await withRun(maxPolls: 4) { fake, model in
            fake.script([analysisJob(.thinking)])
            model.setFiles([analysisUploads])
            await model.start()
            XCTAssertEqual(fake.polls, 4)
            XCTAssertEqual(model.phase, .failed(AnalysisFailure(message: AnalysisRunViewModel.tooLongMessage)))
        }
    }

    func testAResultThatCannotBeReadIsAFailureNotAHalfPage() async {
        await withRun(.docIndex) { fake, model in
            fake.script([analysisJob(.done, result: AnalysisFixtures.listOfDates)])
            model.setFiles([analysisUploads])
            await model.start()
            XCTAssertEqual(model.phase, .failed(AnalysisFailure(message: AnalysisJobTool.docIndex.unreadableResult)))
        }
        await withRun(.docIndex) { fake, model in
            fake.script([analysisJob(.done)])
            model.setFiles([analysisUploads])
            await model.start()
            XCTAssertEqual(model.phase, .failed(AnalysisFailure(message: AnalysisJobTool.docIndex.unreadableResult)))
        }
    }

    func testNothingStartsWithoutDocuments() async {
        await withRun { fake, model in
            XCTAssertFalse(model.canRun)
            XCTAssertEqual(model.runHint, AnalysisService.noFilesMessage)
            await model.start()
            XCTAssertTrue(fake.starts.isEmpty)
            XCTAssertEqual(model.phase, .idle)
            model.setFiles([analysisUploads])
            XCTAssertTrue(model.canRun)
            XCTAssertEqual(model.runHint, AnalysisJobTool.devilsAdvocate.runNote)
        }
    }

    func testTheDocumentsAreCappedDedupedAndLimitedToMyFilesFolders() async {
        await withRun { _, model in
            let many = (0..<12).map { ChatAttachment(name: "\($0).pdf", folderName: "Uploads") }
            model.setFiles(many + [many[0]])
            XCTAssertEqual(model.files.count, 10)
            XCTAssertEqual(model.files.first, many[0])
            XCTAssertTrue(model.filesNotice?.contains("Only the first 10") ?? false)

            model.setFiles([analysisUploads, ChatAttachment(name: "Root.pdf"), ChatAttachment(name: "M.pdf", folderName: "_projects/p1")])
            XCTAssertEqual(model.files, [analysisUploads])
            XCTAssertEqual(model.filesNotice, AnalysisService.rootFileMessage + " " + AnalysisService.matterFileMessage)

            model.setFiles([analysisUploads])
            XCTAssertNil(model.filesNotice)
            model.remove(analysisUploads)
            XCTAssertTrue(model.files.isEmpty)
        }
    }

    func testTheNoteIsKeptWithinTheServersLength() async {
        await withRun { _, model in
            model.reference = String(repeating: "a", count: 2500)
            XCTAssertEqual(model.reference.utf16.count, 2000)
            model.reference = "  short  "
            XCTAssertEqual(model.reference, "  short  ")
        }
    }

    func testCancelStopsFollowingAndKeepsTheInputs() async {
        await withRun { fake, model in
            fake.script([analysisJob(.thinking)])
            model.setFiles([analysisUploads])
            model.reference = "note"
            let gated = AnalysisRunViewModel(tool: .docIndex, service: fake, pollInterval: 0, sleep: { _ in
                throw CancellationError()
            })
            gated.setFiles([analysisUploads])
            await gated.start()
            // The sleep was cancelled: the run stops where it was, untouched.
            guard case .running = gated.phase else { return XCTFail("\(gated.phase)") }
            gated.cancel()
            XCTAssertEqual(gated.phase, .idle)
            XCTAssertEqual(gated.files, [analysisUploads])

            model.startOver()
            XCTAssertTrue(model.files.isEmpty)
            XCTAssertEqual(model.reference, "")
            XCTAssertEqual(model.phase, .idle)
        }
    }

    func testASavedRunOpensInPlaceOfAFreshOne() async {
        await withRun(.listOfDates) { fake, model in
            let summary = AnalysisRunSummary(
                id: "anr_7", tool: .listOfDates, title: "Helios", createdAt: "2026-10-16T09:30:00.000Z",
                fileNames: ["a.pdf", "b.pdf"], reference: "We act for Helios.")
            fake.store(AnalysisRun(summary: summary, result: AnalysisFixtures.value(AnalysisFixtures.listOfDates)))

            let opened = await model.open(runID: "anr_7")

            XCTAssertTrue(opened)
            XCTAssertNil(model.opening)
            guard case .done(let outcome) = model.phase else { return XCTFail("\(model.phase)") }
            XCTAssertTrue(outcome.isFromHistory)
            XCTAssertNotNil(outcome.savedAt)
            XCTAssertEqual(outcome.runID, "anr_7")
            XCTAssertEqual(outcome.fileNames, ["a.pdf", "b.pdf"])
            XCTAssertEqual(outcome.reference, "We act for Helios.")
        }
    }

    func testASavedRunThatIsGoneOrUnreadableSaysSo() async {
        await withRun(.listOfDates) { fake, model in
            let opened = await model.open(runID: "anr_missing")
            XCTAssertFalse(opened)
            XCTAssertEqual(model.phase, .failed(AnalysisFailure(message: AnalysisService.runGoneMessage)))

            // "Try again" opens it again rather than starting a run with no documents.
            let summary = AnalysisRunSummary(id: "anr_missing", tool: .listOfDates)
            fake.store(AnalysisRun(summary: summary, result: AnalysisFixtures.value(AnalysisFixtures.listOfDates)))
            await model.retry()
            guard case .done = model.phase else { return XCTFail("\(model.phase)") }
            XCTAssertTrue(fake.starts.isEmpty)

            fake.store(AnalysisRun(summary: .init(id: "anr_bad", tool: .listOfDates), result: .object([:])))
            let bad = await model.open(runID: "anr_bad")
            XCTAssertFalse(bad)
            XCTAssertEqual(model.phase, .failed(AnalysisFailure(message: AnalysisRunViewModel.savedRunUnreadable)))

            // Another tool's run is not drawn as this one.
            model.show(AnalysisRun(summary: .init(id: "x", tool: .docIndex), result: AnalysisFixtures.value(AnalysisFixtures.docIndex)))
            XCTAssertEqual(model.phase, .failed(AnalysisFailure(message: AnalysisRunViewModel.savedRunUnreadable)))
        }
    }
}

final class AnalysisHistoryViewModelTests: XCTestCase {

    private static let runs = [
        AnalysisRunSummary(id: "anr_2", tool: .docIndex, title: "Our bundle", fileNames: ["Plaint.pdf"]),
        AnalysisRunSummary(id: "anr_1", tool: .docIndex, title: "", fileNames: ["Lease_Deed.pdf"]),
    ]

    func testTheHistoryLoadsForItsToolAndKnowsEmptyFromFailed() async {
        await withHistory(.docIndex) { fake, model in
            XCTAssertEqual(model.state, .idle)
            await model.load()
            XCTAssertEqual(fake.historyAsked, [.docIndex])
            XCTAssertEqual(model.state, .loaded)
            XCTAssertTrue(model.presentation.showsEmptyState)

            fake.setHistory(.success(Self.runs))
            await model.load()
            XCTAssertEqual(model.runs.map(\.id), ["anr_2", "anr_1"])
            XCTAssertFalse(model.presentation.showsEmptyState)
            XCTAssertEqual(model.subtitle, "Your past runs of Doc Index. Only you can see them.")
        }
        await withHistory(nil) { fake, model in
            fake.setHistory(.failure(APIError.server(status: 500, message: "Could not load your history.")))
            await model.load()
            XCTAssertEqual(fake.historyAsked, [nil])
            XCTAssertTrue(model.presentation.showsFailureState)
            XCTAssertEqual(model.subtitle, "Your past runs of the analysis tools. Only you can see them.")
        }
    }

    func testDeletingRemovesTheRowAndAFailureIsSaid() async {
        await withHistory(.docIndex) { fake, model in
            fake.setHistory(.success(Self.runs))
            await model.load()
            await model.delete("anr_2")
            XCTAssertEqual(fake.deleted, ["anr_2"])
            XCTAssertEqual(model.runs.map(\.id), ["anr_1"])
            XCTAssertNil(model.actionError)

            fake.failDelete(APIError.server(status: 500, message: "Could not delete that run. Try again."))
            await model.delete("anr_1")
            XCTAssertEqual(model.runs.map(\.id), ["anr_1"])
            XCTAssertEqual(model.actionError, "Could not delete that run. Try again.")
        }
    }

    func testSearchMatchesTitlesAndFileNamesOnceTheListIsLong() async {
        await withHistory(.docIndex) { fake, model in
            fake.setHistory(.success(Self.runs))
            await model.load()
            XCTAssertFalse(model.offersSearch)
            model.query = "lease"
            XCTAssertEqual(model.visible.map(\.id), ["anr_1"])
            model.query = "BUNDLE"
            XCTAssertEqual(model.visible.map(\.id), ["anr_2"])
            model.query = " "
            XCTAssertEqual(model.visible.count, 2)

            fake.setHistory(.success((0..<9).map { AnalysisRunSummary(id: "r\($0)", tool: .docIndex) }))
            await model.load()
            XCTAssertTrue(model.offersSearch)
        }
    }
}
