import XCTest
@testable import EmperorCore

/// These pin the hand-rolled `/chat` wire format. Every case below is a behaviour the
/// server actually produces, cited to the emperor-ai source that produces it.
final class ChatStreamParserTests: XCTestCase {

    private func feed(_ parser: ChatStreamParser, _ chunks: [String]) -> [ChatStreamEvent] {
        var events: [ChatStreamEvent] = []
        for chunk in chunks { events += parser.consume(text: chunk) }
        events += parser.finish()
        return events
    }

    // MARK: - Status extraction

    func testStatusTagsNeverReachTheAnswer() {
        let parser = ChatStreamParser()
        let events = feed(parser, ["<status>Preparing...</status>The Plaintiff"])

        XCTAssertEqual(events.first, .status("Preparing..."))
        XCTAssertEqual(parser.raw, "The Plaintiff")
    }

    /// The server writes several statuses inside one chunk when it reads multiple files.
    func testMultipleStatusesInOneChunk() {
        let parser = ChatStreamParser()
        _ = feed(parser, ["<status>Reading: a.pdf</status><status>Thinking...</status>Answer"])
        XCTAssertEqual(parser.raw, "Answer")
    }

    /// A chunk boundary landing inside a status tag must not leak the fragment.
    /// The web client splits only on the full literal `"<status"`, so `"<sta"` escapes there
    /// (src/lib/api.js:132). We hold back on any prefix of `"<status>"`.
    func testStatusTagSplitAcrossChunkBoundary() {
        let parser = ChatStreamParser()
        _ = feed(parser, ["Before<sta", "tus>Reading: x.pdf</status>After"])
        XCTAssertEqual(parser.raw, "BeforeAfter")
    }

    func testStatusSplitImmediatelyAfterOpeningBracket() {
        let parser = ChatStreamParser()
        _ = feed(parser, ["Before<", "status>Thinking...</status>After"])
        XCTAssertEqual(parser.raw, "BeforeAfter")
    }

    /// A held-back `<` that turns out to be prose, not a tag, must be released.
    func testLoneAngleBracketIsNotSwallowed() {
        let parser = ChatStreamParser()
        _ = feed(parser, ["where x < ", "y applies"])
        XCTAssertEqual(parser.raw, "where x < y applies")
    }

    /// A stream that dies mid-tag still has to yield its prose. The web client drops this
    /// tail on the floor because its loop simply ends.
    func testUnterminatedStatusIsFlushedAtEndOfStream() {
        let parser = ChatStreamParser()
        _ = feed(parser, ["Answer text<status>Thinking"])
        XCTAssertTrue(parser.raw.hasPrefix("Answer text"))
    }

    // MARK: - Rollback

    /// `<truncate:N/>` rolls back a retried round. Without it the retry double-renders.
    func testTruncateRollsBackToOffset() {
        let parser = ChatStreamParser()
        _ = feed(parser, ["Good start.", "BAD ATTEMPT<truncate:11/>", "Real answer."])
        XCTAssertEqual(parser.raw, "Good start.Real answer.")
    }

    /// N is a UTF-16 offset because the server computes it with JavaScript `.length`.
    /// An emoji is two UTF-16 units but one Swift Character, so a Character-based slice
    /// would cut in the wrong place.
    func testTruncateOffsetIsUTF16NotCharacters() {
        let parser = ChatStreamParser()
        // "⚖️" is U+2696 U+FE0F — 2 UTF-16 units, 1 Character.
        let prefix = "⚖️ok"                       // 4 UTF-16 units, 3 Characters
        XCTAssertEqual(prefix.utf16.count, 4)
        _ = feed(parser, [prefix + "junk<truncate:4/>", "tail"])
        XCTAssertEqual(parser.raw, prefix + "tail")
    }

    func testTruncateBeyondBufferIsClamped() {
        let parser = ChatStreamParser()
        _ = feed(parser, ["short<truncate:9999/>"])
        XCTAssertEqual(parser.raw, "short")
    }

    /// The offset indexes the server's **content-only** string.
    ///
    /// `fullContent` is appended to only by content deltas (`OpenRouterProvider.js:642,646`) and
    /// never by the `<think>` blocks written alongside them (`:616`). Our buffer keeps those
    /// blocks for the reasoning panel, so it is longer — and slicing it at N directly cuts too
    /// early and eats real answer text. Fires only on a reasoning model, which is exactly why
    /// it survived the first round of tests.
    /// Reasoning is flushed at sentence boundaries as it arrives, so it precedes the content of
    /// the round that produced it. A rollback therefore takes that round's reasoning with it,
    /// and must leave every earlier round's reasoning standing.
    ///
    /// Counted naively, `raw` here is 26 units longer than the string the server measured, so
    /// slicing at 11 directly would cut inside the first reasoning block and destroy prose.
    func testTruncateIgnoresReasoningWhenCountingTheOffset() {
        let parser = ChatStreamParser()
        _ = feed(parser, [
            "<think>First pass.</think>",
            "Good start.",                                  // server content 0..11
            "<think>Reconsidering.</think>",                // round 2 begins at content 11
            "BAD ATTEMPT<truncate:11/>",                    // round 2 failed — roll back to 11
            "Real answer.",
        ])
        XCTAssertEqual(
            parser.raw,
            "<think>First pass.</think>Good start.Real answer.",
            "round 1's reasoning survives; round 2's goes with its content")
    }

    /// Several surviving reasoning blocks accumulate several rounds of drift, so the
    /// translation has to walk them all rather than adjusting once.
    func testTruncateAccountsForEveryReasoningBlock() {
        let parser = ChatStreamParser()
        _ = feed(parser, [
            "<think>a</think>", "One.",          // content 0..4
            "<think>bb</think>", "Two.",         // content 4..8
            "<think>ccc</think>",                // round 3 begins at content 8
            "junk<truncate:8/>",
            "Three.",
        ])
        XCTAssertEqual(parser.raw, "<think>a</think>One.<think>bb</think>Two.Three.")
    }

    /// A rollback landing inside the prose *before* any reasoning must be unaffected by the
    /// translation — the mapping has to be identity until the first `<think>`.
    func testTruncateBeforeAnyReasoningIsUnchanged() {
        let parser = ChatStreamParser()
        _ = feed(parser, ["Keep.Drop<think>x</think><truncate:5/>", "Next."])
        XCTAssertEqual(parser.raw, "Keep.Next.")
    }

    // MARK: - Busy refusal

    /// A second send on a chat that is still generating is answered 200, with the refusal
    /// arriving as a status tag ahead of its own explanation (sync-server.js:7256-7276).
    /// The explanation must not land in the transcript.
    func testBusyRefusalIsDivertedFromTheAnswer() {
        let parser = ChatStreamParser()
        let events = feed(parser, [
            "<status>Still drafting your earlier request</status>",
            "Your draft for this chat is still being generated (3m 12s so far).",
        ])

        XCTAssertTrue(events.contains(.busy))
        XCTAssertTrue(parser.isBusy)
        XCTAssertEqual(parser.raw, "")
        XCTAssertTrue(parser.busyNotice.contains("still being generated"))
    }

    // MARK: - Usage

    /// Written once, last, immediately before the response ends.
    func testUsageIsLiftedOutOfContent() {
        let parser = ChatStreamParser()
        let events = feed(parser, ["Answer.\n<usage>{\"total_tokens\":42,\"cost\":0.0141}</usage>"])

        XCTAssertEqual(parser.raw.trimmingCharacters(in: .whitespacesAndNewlines), "Answer.")
        let usage = events.compactMap { if case .usage(let u) = $0 { return u } else { return nil } }.first
        XCTAssertEqual(usage?["total_tokens"]?.intValue, 42)
    }

    /// `<usage>` is only written `if (finalUsage)`, so it is not a terminator.
    func testStreamWithoutUsageStillCompletes() {
        let parser = ChatStreamParser()
        _ = feed(parser, ["Answer with no usage block."])
        XCTAssertEqual(parser.raw, "Answer with no usage block.")
    }

    // MARK: - UTF-8 boundaries

    /// Chunk boundaries fall mid-character routinely on Devanagari and ₹.
    func testMultiByteCharacterSplitAcrossChunks() {
        let parser = ChatStreamParser()
        let text = "देखिए ₹1,00,000"
        var bytes = Array(Data(text.utf8))
        var events: [ChatStreamEvent] = []
        // Feed one byte at a time — the worst case for a naive decoder.
        while !bytes.isEmpty {
            events += parser.consume(Data([bytes.removeFirst()]))
        }
        events += parser.finish()
        XCTAssertEqual(parser.raw, text)
    }

    /// **Content that arrives in the same chunk as the marker is the retry's real answer.**
    /// Discarding to end-of-buffer deletes it. The server sleeps before retrying, which makes
    /// the coalesced case rare rather than impossible — a proxy or the OS can still merge them,
    /// and the web client loses the text when that happens (`streamManager.js:294-296`).
    func testContentArrivingWithTheMarkerSurvivesTheRollback() {
        let parser = ChatStreamParser()
        _ = feed(parser, ["Good start.", "BAD ATTEMPT<truncate:11/>Real answer."])
        XCTAssertEqual(parser.raw, "Good start.Real answer.")
    }

    /// Two rollbacks in one delivered chunk must both apply.
    func testTwoRollbacksInOneChunkBothApply() {
        let parser = ChatStreamParser()
        _ = feed(parser, ["Keep.", "one<truncate:5/>two<truncate:5/>three"])
        XCTAssertEqual(parser.raw, "Keep.three")
    }

    /// The rollback offset still reaches the listener, so superseded work can be marked rather
    /// than silently vanishing.
    func testARollbackIsStillReported() {
        let parser = ChatStreamParser()
        let events = feed(parser, ["Good start.BAD<truncate:11/>Real."])
        XCTAssertTrue(events.contains { if case .rolledBack = $0 { return true }; return false })
    }
}
