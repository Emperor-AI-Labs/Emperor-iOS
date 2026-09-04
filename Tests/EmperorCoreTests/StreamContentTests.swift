import XCTest
@testable import EmperorCore

/// The server stores and streams answers with every control tag left in — stripping is
/// entirely the client's job. These pin what a practitioner should actually end up reading.
final class StreamContentTests: XCTestCase {

    func testPlainProsePassesThroughUntouched() {
        let content = StreamContent.parse("The Plaintiff's claim under Section 4 fails.")
        XCTAssertEqual(content.prose, "The Plaintiff's claim under Section 4 fails.")
        XCTAssertTrue(content.artifacts.isEmpty)
    }

    func testReasoningIsSeparatedFromProse() {
        let content = StreamContent.parse(
            "<think>The limitation point turns on Article 58.</think>The suit is barred.")
        XCTAssertEqual(content.reasoning, ["The limitation point turns on Article 58."])
        XCTAssertEqual(content.prose, "The suit is barred.")
    }

    /// A drafted document is delivered as a trigger line plus a body, and belongs in a side
    /// panel rather than inline in the transcript.
    func testCanvasArtifactIsExtractedWithItsTitle() {
        let content = StreamContent.parse("""
        Here is the petition.
        [CANVAS_TRIGGER: Writ Petition]
        <canvas_content><h1>IN THE HIGH COURT</h1></canvas_content>
        """)

        XCTAssertEqual(content.artifacts.count, 1)
        XCTAssertEqual(content.artifacts.first?.kind, .canvas)
        XCTAssertEqual(content.artifacts.first?.title, "Writ Petition")
        XCTAssertEqual(content.artifacts.first?.body, "<h1>IN THE HIGH COURT</h1>")
        XCTAssertEqual(content.prose, "Here is the petition.")
    }

    func testTableArtifactIsExtracted() {
        let content = StreamContent.parse(
            "[TABLE_TRIGGER: Chronology]<table_content>| Date | Event |</table_content>")
        XCTAssertEqual(content.artifacts.first?.kind, .table)
        XCTAssertEqual(content.artifacts.first?.title, "Chronology")
        XCTAssertEqual(content.prose, "")
    }

    /// Two documents in one answer must not cross-attach titles to bodies.
    func testMultipleArtifactsKeepTheirOwnTitles() {
        let content = StreamContent.parse("""
        [CANVAS_TRIGGER: First]<canvas_content>one</canvas_content>
        [CANVAS_TRIGGER: Second]<canvas_content>two</canvas_content>
        """)
        XCTAssertEqual(content.artifacts.map(\.title), ["First", "Second"])
        XCTAssertEqual(content.artifacts.map(\.body), ["one", "two"])
    }

    /// A trigger line whose body has not streamed in yet must not flash as prose.
    func testOrphanTriggerLineIsNotShownAsProse() {
        let content = StreamContent.parse("Drafting now.\n[CANVAS_TRIGGER: Writ Petition]")
        XCTAssertEqual(content.prose, "Drafting now.")
        XCTAssertTrue(content.artifacts.isEmpty)
    }

    /// A tag arriving a few characters at a time must not render half-open.
    func testPartialTrailingTagIsHidden() {
        let content = StreamContent.parse("The order is dated 4 March.<canvas_c")
        XCTAssertEqual(content.prose, "The order is dated 4 March.")
    }

    /// …but a mathematical or textual `<` is prose and must survive.
    func testLiteralAngleBracketInProseSurvives() {
        let content = StreamContent.parse("The claim is valid where damages < 50,000 rupees.")
        XCTAssertEqual(content.prose, "The claim is valid where damages < 50,000 rupees.")
    }

    func testPlanIsDecoded() {
        let content = StreamContent.parse("""
        <plan>{"tasks":[{"title":"Read the file","subtasks":[{"label":"Open paperbook","tools":["read"]}]}]}</plan>Working.
        """)
        XCTAssertEqual(content.plan?.tasks.first?.title, "Read the file")
        XCTAssertEqual(content.plan?.tasks.first?.subtasks?.first?.label, "Open paperbook")
        XCTAssertEqual(content.prose, "Working.")
    }

    func testFollowUpQueriesAreDecoded() {
        let content = StreamContent.parse(
            "Done.<follow-up-queries>[\"What is the limitation period?\",\"Who signed it?\"]</follow-up-queries>")
        XCTAssertEqual(content.followUps.count, 2)
        XCTAssertEqual(content.prose, "Done.")
    }

    /// The provider writes failures as bracketed prose once the response is already
    /// streaming, because the status line is long gone by then.
    func testInBandErrorIsSurfacedSeparately() {
        let content = StreamContent.parse("Partial answer.\n\n[Error: upstream timed out]")
        XCTAssertEqual(content.errors, ["Error: upstream timed out"])
        XCTAssertEqual(content.prose, "Partial answer.")
    }

    func testServerErrorVariantIsAlsoCaught() {
        let content = StreamContent.parse("Text.\n\n[Server Error: database is locked]")
        XCTAssertEqual(content.errors, ["Server Error: database is locked"])
    }

    /// The interrupted marker only exists on the persisted copy, so this is the signal when
    /// loading history rather than when streaming.
    func testInterruptedMarkerIsDetected() {
        let content = StreamContent.parse("""
        The draft stops here.

        ---
        ⚠️ **This response was interrupted and is incomplete.** Nothing above has been lost.
        """)
        XCTAssertTrue(content.wasInterrupted)
    }

    func testCleanAnswerIsNotFlaggedInterrupted() {
        XCTAssertFalse(StreamContent.parse("A complete answer.").wasInterrupted)
    }

    // MARK: - Truncation detection

    /// A draft stranded inside an unclosed wrapper is the failure the server cannot report:
    /// `/chat` discards the provider's `status:'length'` verdict (sync-server.js:7797), so this
    /// arrives with no marker, `incomplete:false`, and a clean end of stream.
    func testAnUnclosedDocumentBlockIsDetectedAsTruncation() {
        let content = StreamContent.parse(
            "[CANVAS_TRIGGER: Written Submissions]\n<canvas_content><p>IN THE HIGH COURT")
        XCTAssertTrue(content.hasUnclosedDocumentBlock)
        XCTAssertTrue(content.looksTruncated)
        XCTAssertFalse(content.wasInterrupted, "no marker was present — this is the inferred case")
    }

    func testAnUnclosedTableBlockIsAlsoDetected() {
        let content = StreamContent.parse("<table_content>| A | B |")
        XCTAssertTrue(content.looksTruncated)
    }

    /// A complete artifact must not be mistaken for a truncated one.
    func testAClosedDocumentBlockIsNotTruncated() {
        let content = StreamContent.parse(
            "[CANVAS_TRIGGER: Draft]\n<canvas_content><p>Complete.</p></canvas_content>")
        XCTAssertFalse(content.hasUnclosedDocumentBlock)
        XCTAssertFalse(content.looksTruncated)
        XCTAssertEqual(content.artifacts.count, 1)
    }

    /// Several artifacts in one answer, all closed.
    func testMultipleClosedBlocksAreNotTruncated() {
        let content = StreamContent.parse(
            "<canvas_content>one</canvas_content>Then:<canvas_content>two</canvas_content>")
        XCTAssertFalse(content.looksTruncated)
        XCTAssertEqual(content.artifacts.count, 2)
    }

    /// The closing tag must never be miscounted as an opening one.
    func testClosingTagIsNotCountedAsAnOpening() {
        let content = StreamContent.parse("</canvas_content>")
        XCTAssertFalse(content.hasUnclosedDocumentBlock)
    }

    /// The explicit marker still works, and still means truncated.
    func testTheServerMarkerStillReportsTruncation() {
        let content = StreamContent.parse(
            "Partial answer.\n\n---\n\u{26A0}\u{FE0F} **This response was interrupted and is incomplete.**")
        XCTAssertTrue(content.wasInterrupted)
        XCTAssertTrue(content.looksTruncated)
    }

    // MARK: - What goes back to the server

    /// **The destructive one.** `POST /chat` replaces the chat's stored messages with exactly
    /// what it receives (`sync-server.js:4250`), so the assistant turn this client appends is
    /// what survives — for the web client too. Posting `prose` back would permanently delete
    /// the drafted document and every citation on the next follow-up question.
    func testPersistableContentKeepsArtifactsAndCitations() {
        let answer = """
            The suit is barred <@Sale_Deed.pdf:P-5:7>.

            [CANVAS_TRIGGER: Written Submissions]
            <canvas_content><p>IN THE HIGH COURT</p></canvas_content>
            """
        let content = StreamContent.parse(answer)

        XCTAssertFalse(
            content.prose.contains("<@Sale_Deed.pdf:P-5:7>"), "prose is stripped, as intended")
        XCTAssertTrue(
            content.persistableContent.contains("<@Sale_Deed.pdf:P-5:7>"),
            "the citation must survive the round trip")
        XCTAssertTrue(
            content.persistableContent.contains("<canvas_content>"),
            "so must the drafted document")
        XCTAssertTrue(content.persistableContent.contains("IN THE HIGH COURT"))
    }

    /// The model's private reasoning must NOT go back — the server's own persisted copy
    /// (`fullContent`) never contains it, and echoing it would put the model's working into
    /// the stored history.
    func testPersistableContentDropsPrivateReasoning() {
        let content = StreamContent.parse(
            "<think>Let me reconsider limitation.</think>The suit is barred.")

        XCTAssertFalse(content.persistableContent.contains("<think>"))
        XCTAssertFalse(content.persistableContent.contains("reconsider limitation"))
        XCTAssertTrue(content.persistableContent.contains("The suit is barred."))
    }
}
