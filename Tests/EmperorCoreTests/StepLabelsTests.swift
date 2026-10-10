import XCTest
@testable import EmperorCore

/// The reading card says what is happening in plain words: never a page range, a tool's name or
/// the query the model searched with.
final class StepLabelsTests: XCTestCase {

    func testReadingDropsThePageRange() {
        XCTAssertEqual(
            StepLabels.friendly("Reading pages 55-73 of Evidence_Vol_2.pdf"), "Reading Evidence Vol 2.pdf")
        XCTAssertEqual(StepLabels.friendly("Reading pages 3–5 of Supply Agreement"), "Reading Supply Agreement")
        XCTAssertEqual(StepLabels.friendly("Reading page 4 of AWARD.pdf"), "Reading AWARD.pdf")
        XCTAssertEqual(StepLabels.friendly("Mapping the structure of Order.pdf"), "Reading Order.pdf")
        XCTAssertEqual(StepLabels.friendly("Reading: a.pdf"), "Reading a.pdf")
    }

    func testSearchesNeverShowTheQuery() {
        XCTAssertEqual(
            StepLabels.friendly("Searching the record for: part payments received"),
            "Searching your documents")
        XCTAssertEqual(StepLabels.friendly("Searching the record"), "Searching your documents")
    }

    func testAmbientStatusesReadNaturally() {
        XCTAssertEqual(StepLabels.friendly("Thinking..."), "Thinking")
        XCTAssertEqual(StepLabels.friendly("Emperor is thinking..."), "Thinking")
        XCTAssertEqual(StepLabels.friendly("Preparing…"), "Preparing")
        // A list of documents is not one step, and is left as it came rather than guessed at.
        XCTAssertEqual(
            StepLabels.friendly("Reading: a.pdf, b.pdf and 2 more"), "Reading: a.pdf, b.pdf and 2 more")
    }

    private func snapshot(_ labels: [(String, WorkStatus)]) -> ReasoningSnapshot {
        let steps = labels.enumerated().map { WorkStep(label: $1.0, status: $1.1, at: $0) }
        return ReasoningSnapshot(workLog: [.group(WorkGroup(status: .inProgress, steps: steps))])
    }

    func testConsecutiveReadsOfOneDocumentAreOneLine() {
        let log = snapshot([
            ("Reading pages 1-5 of a.pdf", .completed),
            ("Reading pages 6-9 of a.pdf", .inProgress),
            ("Searching the record for: limitation", .pending),
        ])
        XCTAssertEqual(StepLabels.steps(log), [
            StepLabels.Step(text: "Reading a.pdf", status: .inProgress),
            StepLabels.Step(text: "Searching your documents", status: .pending),
        ])
    }

    func testTitlesCountTheDocumentsRead() {
        XCTAssertEqual(StepLabels.runningTitle(ReasoningSnapshot()), "Looking through your record…")
        let one = snapshot([("Reading pages 1-5 of a.pdf", .inProgress)])
        XCTAssertEqual(StepLabels.runningTitle(one), "Reading 1 document…")
        let two = snapshot([
            ("Reading pages 1-5 of a.pdf", .completed),
            ("Mapping the structure of b.pdf", .completed),
            ("Reading pages 6-9 of a.pdf", .completed),
        ])
        XCTAssertEqual(StepLabels.runningTitle(two), "Reading 2 documents…")
        XCTAssertEqual(StepLabels.documents(two), ["a.pdf", "b.pdf"])
    }

    func testTheSummarySaysWhatWasDone() {
        XCTAssertEqual(StepLabels.summary(ReasoningSnapshot()), "Answered directly")
        let log = snapshot([
            ("Reading pages 1-5 of a.pdf", .completed),
            ("Reading pages 1-2 of b.pdf", .completed),
            ("Searching the record for: limitation", .completed),
        ])
        XCTAssertEqual(StepLabels.summary(log), "Read 2 documents · searched your files")
        let searchOnly = snapshot([("Searching the record for: bail", .completed)])
        XCTAssertEqual(StepLabels.summary(searchOnly), "Searched your files")
    }

    /// A step whose results were thrown away is not work the answer rests on.
    func testSupersededStepsAreLeftOut() {
        let log = snapshot([
            ("Reading pages 1-5 of a.pdf", .superseded),
            ("Searching the record for: bail", .completed),
        ])
        XCTAssertEqual(StepLabels.steps(log).map(\.text), ["Searching your documents"])
        XCTAssertEqual(StepLabels.summary(log), "Searched your files")
    }
}
