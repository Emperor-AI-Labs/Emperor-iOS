import XCTest
@testable import EmperorCore

/// Ported behaviours from `src/lib/streamManager.js`. Each case pins a distinction that the
/// platform learned the hard way — the comments there record why.
final class ReasoningTrackerTests: XCTestCase {

    private func groups(_ tracker: ReasoningTracker) -> [WorkGroup] {
        tracker.workLog.compactMap { if case .group(let g) = $0 { return g } else { return nil } }
    }

    private func notes(_ tracker: ReasoningTracker) -> [String] {
        tracker.workLog.compactMap {
            if case .note(_, let text, _) = $0 { return text } else { return nil }
        }
    }

    /// Drives the tracker the way ChatService does: parser events, in order.
    private func run(_ chunks: [String]) -> ReasoningTracker {
        let parser = ChatStreamParser()
        let tracker = ReasoningTracker()
        for chunk in chunks {
            for event in parser.consume(text: chunk) { tracker.consume(event) }
        }
        for event in parser.finish() { tracker.consume(event) }
        return tracker
    }

    // MARK: - What counts as a step

    /// Ambient pipeline chatter is useful as a live status line but is not work the model
    /// chose to do. Counting it padded a run of 8 tool calls into "14 steps".
    func testAmbientStatusIsNotAStep() {
        let tracker = run([
            "<status>Preparing...</status>",
            "<status>Thinking...</status>",
            "<status>Emperor is thinking...</status>",
            "<status>Processing document chunks...</status>",
            "<status>Reading: a.pdf, b.pdf and 2 more</status>",
            "Answer.",
        ])
        XCTAssertTrue(groups(tracker).isEmpty)
    }

    /// The colon is what distinguishes a real step from Pre-RAG's ambient listing.
    func testGenuineToolCallsAreLogged() {
        let tracker = run([
            "<status>Reading pages 55-73 of Evidence_Vol_2.pdf</status>",
            "<status>Mapping the structure of Order.pdf</status>",
            "<status>Searching the record for: limitation</status>",
            "The suit is barred.",
        ])
        let steps = groups(tracker).flatMap(\.steps)
        XCTAssertEqual(steps.count, 3)
        XCTAssertEqual(steps.first?.label, "Reading pages 55-73 of Evidence_Vol_2.pdf")
    }

    /// The ~20s keep-alive is not progress and must never advance anything. Its text ends in
    /// U+2026, not three dots.
    func testHeartbeatIsNeverAStep() {
        let tracker = run(["<status>Still working…</status>", "Answer."])
        XCTAssertTrue(groups(tracker).isEmpty)
    }

    /// Labels stay raw. Generalising them would throw away the document name and page range,
    /// which is exactly what makes the log worth reading.
    func testStepLabelsAreKeptVerbatim() {
        let tracker = run([
            "<status>Reading pages 4-9 of Sale_Deed.pdf</status>", "Done.",
        ])
        XCTAssertEqual(groups(tracker).first?.steps.first?.label,
                       "Reading pages 4-9 of Sale_Deed.pdf")
    }

    // MARK: - Grouping

    /// A run of statuses with no prose between them is one agentic round, because the server
    /// writes every tool call of a round back-to-back before any result returns.
    func testConsecutiveCallsFormOneRound() {
        let tracker = run([
            "<status>Reading pages 1-5 of a.pdf</status>",
            "<status>Reading pages 6-9 of b.pdf</status>",
            "Now the answer.",
        ])
        XCTAssertEqual(groups(tracker).count, 1)
        XCTAssertEqual(groups(tracker).first?.steps.count, 2)
    }

    /// Narration between rounds closes the group and opens a new one.
    func testNarrationSplitsRounds() {
        let tracker = run([
            "<status>Reading pages 1-5 of a.pdf</status>",
            "I will now check the counter-affidavit before going further.",
            "<status>Reading pages 2-4 of b.pdf</status>",
            "Concluding.",
        ])
        XCTAssertEqual(groups(tracker).count, 2)
        XCTAssertEqual(notes(tracker).count, 1)
        XCTAssertTrue(notes(tracker)[0].contains("counter-affidavit"))
    }

    /// A closed round's steps are completed — the model narrating again means results are back.
    func testClosedRoundIsMarkedCompleted() {
        let tracker = run([
            "<status>Reading pages 1-5 of a.pdf</status>",
            "That establishes the date of possession beyond doubt.",
        ])
        XCTAssertEqual(groups(tracker).first?.status, .completed)
        XCTAssertEqual(groups(tracker).first?.steps.first?.status, .completed)
    }

    // MARK: - Rollback

    /// The discarded round really did fire those calls. Mark them rather than delete them —
    /// but a superseded call must never wear the same tick as one that delivered.
    func testRolledBackStepsAreSupersededNotDeleted() {
        let parser = ChatStreamParser()
        let tracker = ReasoningTracker()
        func feed(_ text: String) {
            for event in parser.consume(text: text) { tracker.consume(event) }
        }

        feed("Working on it now, reading the file.")
        feed("<status>Reading pages 1-5 of a.pdf</status>")
        let offset = ("Working on it now, reading the file." as NSString).length
        feed("<truncate:\(offset)/>")

        let steps = groups(tracker).flatMap(\.steps)
        XCTAssertEqual(steps.count, 1, "the step should survive the rollback, marked")
        XCTAssertEqual(steps.first?.status, .superseded)
    }

    // MARK: - Plan

    private let planChunk = """
    <plan>{"tasks":[{"title":"Read the record","subtasks":[\
    {"label":"Open the paperbook"},{"label":"Map the annexures"}]},\
    {"title":"Draft","subtasks":[{"label":"Write the grounds"}]}]}</plan>
    """

    /// The plan arrives as one blob, so without a cursor the panel would snap straight from
    /// empty to finished. Only the first row runs at the outset.
    func testPlanStartsWithOnlyTheFirstRowRunning() {
        let tracker = run([planChunk])
        XCTAssertEqual(tracker.plan.count, 2)
        XCTAssertEqual(tracker.plan[0].subtasks.map(\.status), [.inProgress, .pending])
        XCTAssertEqual(tracker.plan[0].status, .inProgress)
        XCTAssertEqual(tracker.plan[1].status, .pending)
    }

    /// The cursor advances on a genuine tool call, never on a timer.
    func testRealToolCallAdvancesThePlan() {
        let parser = ChatStreamParser()
        let tracker = ReasoningTracker()
        func feed(_ text: String) {
            for event in parser.consume(text: text) { tracker.consume(event) }
        }
        feed(planChunk)
        feed("<status>Reading pages 1-5 of a.pdf</status>")

        XCTAssertEqual(tracker.plan[0].subtasks.map(\.status), [.completed, .inProgress])
    }

    /// …but ambient chatter does not.
    func testAmbientStatusDoesNotAdvanceThePlan() {
        let parser = ChatStreamParser()
        let tracker = ReasoningTracker()
        func feed(_ text: String) {
            for event in parser.consume(text: text) { tracker.consume(event) }
        }
        feed(planChunk)
        feed("<status>Thinking...</status>")
        feed("<status>Still working…</status>")

        XCTAssertEqual(tracker.plan[0].subtasks.map(\.status), [.inProgress, .pending])
    }

    /// Once the answer is genuinely streaming, the research steps are behind us — otherwise
    /// the panel sits stuck on step one while prose scrolls past.
    func testAnswerStreamingAdvancesToTheLastStep() {
        let tracker = run([
            planChunk,
            String(repeating: "The petitioner submits as follows. ", count: 4),
        ])
        XCTAssertEqual(tracker.plan.last?.subtasks.last?.status, .inProgress)
    }

    /// A clean finish completes everything.
    func testFinishCompletesThePlan() {
        let tracker = run([planChunk, "Answer."])
        tracker.finish(ended: .completed)
        XCTAssertTrue(tracker.plan.allSatisfy { $0.status == .completed })
        XCTAssertTrue(tracker.plan.flatMap(\.subtasks).allSatisfy { $0.status == .completed })
    }

    /// A stop is not a completion: work still in flight is reported unfinished rather than
    /// ticked off, because we genuinely do not know whether it came back.
    func testStopLeavesInFlightWorkUnfinished() {
        let parser = ChatStreamParser()
        let tracker = ReasoningTracker()
        for event in parser.consume(text: "<status>Reading pages 1-5 of a.pdf</status>") {
            tracker.consume(event)
        }
        tracker.finish(ended: .stopped)

        XCTAssertEqual(groups(tracker).first?.steps.first?.status, .stopped)
        XCTAssertEqual(groups(tracker).first?.status, .stopped)
    }

    // MARK: - Notes

    func testShortNarrationIsKeptWhole() {
        let text = "Now let me read the remaining files."
        XCTAssertEqual(ReasoningTracker.summarise(text), text)
    }

    /// A long paragraph keeps its tail — the lead-in to the next batch of work is at the end.
    func testLongNarrationKeepsItsTail() {
        let long = String(repeating: "Analysis of the record continues. ", count: 20)
            + "Now let me read the remaining files."
        let summary = ReasoningTracker.summarise(long)
        XCTAssertLessThanOrEqual(summary.count, 241)
        XCTAssertTrue(summary.hasSuffix("Now let me read the remaining files."))
    }

    func testMarkdownIsStrippedFromNotes() {
        XCTAssertEqual(ReasoningTracker.summarise("**Now** let me `read` it."),
                       "Now let me read it.")
    }
}
