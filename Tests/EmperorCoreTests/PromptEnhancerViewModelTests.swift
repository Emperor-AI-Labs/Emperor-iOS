import XCTest
@testable import EmperorCore

/// A stand-in enhancer that yields exactly the chunks it is given.
///
/// `chunks` are **accumulated** values, matching what `EnhancerService` emits, so a test that
/// wants two deltas writes `["Rew", "Rewritten"]`.
private final class FakeEnhancer: PromptEnhancing, @unchecked Sendable {
    var chunks: [String] = []
    var failure: Error?
    /// Runs after each chunk is yielded, so a test can simulate the user typing mid-stream.
    ///
    /// Async, and it must hop to the main actor itself: this runs inside the producer, which
    /// is not main-actor isolated, so touching the view model from here directly traps.
    var afterChunk: (@Sendable (Int) async -> Void)?
    private(set) var receivedPrompt: String?
    private(set) var receivedAttachments: [ChatAttachment] = []

    func enhance(
        prompt: String, attachments: [ChatAttachment]
    ) async throws -> AsyncThrowingStream<String, Error> {
        receivedPrompt = prompt
        receivedAttachments = attachments
        let chunks = chunks
        let failure = failure
        let afterChunk = afterChunk
        return AsyncThrowingStream { continuation in
            // A Task rather than a straight-line loop, so `afterChunk` can await. The
            // interleaving with the consumer is deliberately not pinned — an edit landing
            // either side of a chunk must produce the same outcome, which is the point.
            let task = Task {
                for (index, chunk) in chunks.enumerated() {
                    continuation.yield(chunk)
                    await afterChunk?(index)
                }
                if let failure {
                    continuation.finish(throwing: failure)
                } else {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@MainActor
private func withEnhancer(
    text: String = "help me draft a reply",
    _ body: @MainActor (FakeEnhancer, PromptEnhancerViewModel) async -> Void
) async {
    let fake = FakeEnhancer()
    await body(fake, PromptEnhancerViewModel(service: fake, text: text))
}

final class PromptEnhancerViewModelTests: XCTestCase {

    // MARK: - The happy path

    func testRewriteReplacesTheComposerText() async {
        await withEnhancer { fake, model in
            fake.chunks = ["Please draft", "Please draft a reply to the s.138 notice."]
            await model.run()

            XCTAssertEqual(model.text, "Please draft a reply to the s.138 notice.")
            XCTAssertTrue(model.canUndo)
            XCTAssertNil(model.failureNotice)
            XCTAssertFalse(model.isEnhancing)
        }
    }

    func testAttachmentsAreSentSoTheRewriteCanBeGrounded() async {
        await withEnhancer { fake, model in
            fake.chunks = ["Rewritten."]
            model.attachments = [ChatAttachment(name: "notice.pdf", folderName: "Bakshi")]
            await model.run()

            XCTAssertEqual(fake.receivedPrompt, "help me draft a reply")
            XCTAssertEqual(fake.receivedAttachments.first?.name, "notice.pdf")
            XCTAssertEqual(fake.receivedAttachments.first?.folderName, "Bakshi")
        }
    }

    func testBlankComposerIsNotSent() async {
        await withEnhancer(text: "   \n ") { fake, model in
            await model.run()
            XCTAssertNil(fake.receivedPrompt)
            XCTAssertFalse(model.canEnhance)
        }
    }

    // MARK: - Failure is a 200 with an empty body

    /// The server answers 200 on **every** one of its own error paths — OpenRouter down, its
    /// 15s abort, a mid-stream break. So an empty stream is a failure wearing a success's
    /// clothes, and the one thing that must not happen is the user's text being replaced with
    /// nothing.
    func testAnEmptyResultLeavesTheOriginalTextAlone() async {
        await withEnhancer { fake, model in
            fake.chunks = []
            await model.run()

            XCTAssertEqual(model.text, "help me draft a reply")
            XCTAssertFalse(model.canUndo)
            XCTAssertEqual(model.failureNotice, PromptEnhancerViewModel.Copy.emptyResult)
        }
    }

    func testAWhitespaceOnlyResultCountsAsEmpty() async {
        await withEnhancer { fake, model in
            fake.chunks = ["  \n  "]
            await model.run()
            XCTAssertEqual(model.text, "help me draft a reply")
            XCTAssertNotNil(model.failureNotice)
        }
    }

    /// **The 2026-07-28 bug, ported.** Once a chunk has landed, what is in the box is *ours*.
    /// Leaving a visibly truncated half-sentence there is worse than either outcome — the user
    /// never wrote it and cannot tell it is incomplete.
    func testAMidStreamFailureRestoresTheOriginalRatherThanLeavingPartialText() async {
        await withEnhancer { fake, model in
            fake.chunks = ["Please draft a reply to the s.13"]
            fake.failure = APIError.transport("connection lost")
            await model.run()

            XCTAssertEqual(model.text, "help me draft a reply")
            XCTAssertFalse(model.canUndo)
            XCTAssertNotNil(model.failureNotice)
        }
    }

    func testAFailureBeforeAnyChunkAlsoLeavesTheOriginal() async {
        await withEnhancer { fake, model in
            fake.failure = APIError.transport("offline")
            await model.run()
            XCTAssertEqual(model.text, "help me draft a reply")
            XCTAssertNotNil(model.failureNotice)
        }
    }

    // MARK: - The user typing wins

    /// Someone who keeps typing while the rewrite streams has decided what they want. Writing
    /// over them mid-keystroke is the single most irritating thing this feature could do.
    func testAUserEditMidStreamStopsUsWritingAtAll() async {
        await withEnhancer { fake, model in
            fake.chunks = ["Please", "Please draft", "Please draft a reply."]
            fake.afterChunk = { [weak model] index in
                guard index == 0 else { return }
                await MainActor.run { model?.text = "my own words instead" }
            }
            await model.run()

            XCTAssertEqual(model.text, "my own words instead")
            XCTAssertFalse(model.canUndo)
        }
    }

    /// And their edit must not be rolled back by a failure that arrives afterwards.
    func testAFailureAfterAUserEditLeavesTheUsersText() async {
        await withEnhancer { fake, model in
            fake.chunks = ["Please"]
            fake.failure = APIError.transport("lost")
            fake.afterChunk = { [weak model] _ in
                await MainActor.run { model?.text = "my own words instead" }
            }
            await model.run()

            XCTAssertEqual(model.text, "my own words instead")
        }
    }

    // MARK: - Undo

    func testUndoRestoresTheOriginalWording() async {
        await withEnhancer { fake, model in
            fake.chunks = ["A much more specific prompt."]
            await model.run()
            model.undo()

            XCTAssertEqual(model.text, "help me draft a reply")
            XCTAssertFalse(model.canUndo)
        }
    }

    /// Fixing one wrong word is the most ordinary edit there is; it must not cost the revert.
    func testASmallEditKeepsUndoAvailable() async {
        await withEnhancer { fake, model in
            fake.chunks = ["Draft a reply to the s.138 notice for ABC Limited."]
            await model.run()
            model.text = "Draft a reply to the s.138 notice for ABC Ltd."

            XCTAssertTrue(model.canUndo)
        }
    }

    /// Rewriting the thing wholesale means there is no longer a clean "before" to go back to.
    func testRewritingItEntirelyDropsUndo() async {
        await withEnhancer { fake, model in
            fake.chunks = ["Draft a reply to the s.138 notice for ABC Limited."]
            await model.run()
            model.text = "completely different question about a lease"

            XCTAssertFalse(model.canUndo)
        }
    }

    func testUndoDoesNothingWhenThereIsNothingToUndo() async {
        await withEnhancer { _, model in
            model.undo()
            XCTAssertEqual(model.text, "help me draft a reply")
        }
    }

    /// Typing after a failure should clear the notice rather than leaving it accusing them.
    func testTypingClearsTheFailureNotice() async {
        await withEnhancer { fake, model in
            fake.chunks = []
            await model.run()
            XCTAssertNotNil(model.failureNotice)

            model.text = "help me draft a reply to the notice"
            XCTAssertNil(model.failureNotice)
        }
    }

    // MARK: - Placeholders

    func testAResultWithBlanksOffersThemToBeFilled() async {
        await withEnhancer { fake, model in
            fake.chunks = ["Draft the next filing for {{WHICH MATTER OR CASE NUMBER}}."]
            await model.run()

            XCTAssertEqual(model.template?.labels, ["WHICH MATTER OR CASE NUMBER"])
        }
    }

    func testAResultWithoutBlanksOffersNothing() async {
        await withEnhancer { fake, model in
            fake.chunks = ["Draft the next filing in the Bakshi matter."]
            await model.run()
            XCTAssertNil(model.template)
        }
    }

    func testFillingTheBlanksRewritesTheComposer() async {
        await withEnhancer { fake, model in
            fake.chunks = ["Draft for {{WHICH MATTER}} before {{DATE}}."]
            await model.run()
            model.applyFilled(["WHICH MATTER": "Bakshi", "DATE": "12 September"])

            XCTAssertEqual(model.text, "Draft for Bakshi before 12 September.")
            // Offering to fill it again would show the answers back as questions.
            XCTAssertNil(model.template)
        }
    }

    func testAnUnansweredBlankIsStillSentAsItsLabel() async {
        await withEnhancer { fake, model in
            fake.chunks = ["Draft for {{WHICH MATTER}} before {{DATE}}."]
            await model.run()
            model.applyFilled(["DATE": "12 September"])

            XCTAssertEqual(model.text, "Draft for {{WHICH MATTER}} before 12 September.")
        }
    }

    /// Filling the blanks is our write, not the user's, so it must not be mistaken for one and
    /// invalidate the revert — the original wording is still the thing to go back to.
    func testFillingTheBlanksKeepsUndoPointingAtTheOriginal() async {
        await withEnhancer { fake, model in
            fake.chunks = ["Draft for {{WHICH MATTER}}."]
            await model.run()
            model.applyFilled(["WHICH MATTER": "Bakshi"])
            model.undo()

            XCTAssertEqual(model.text, "help me draft a reply")
        }
    }

    func testClearingTheComposerResetsEverything() async {
        await withEnhancer { fake, model in
            fake.chunks = ["Rewritten with {{A BLANK}}."]
            await model.run()
            model.clear()

            XCTAssertEqual(model.text, "")
            XCTAssertFalse(model.canUndo)
            XCTAssertNil(model.template)
            XCTAssertNil(model.failureNotice)
        }
    }

    // MARK: - Edit distance

    func testIdenticalStringsAreDistanceZero() {
        XCTAssertEqual(PromptEnhancerViewModel.editDistanceRatio("abc", "abc"), 0)
    }

    func testTwoEmptyStringsAreDistanceZero() {
        XCTAssertEqual(PromptEnhancerViewModel.editDistanceRatio("", ""), 0)
    }

    func testEverythingDeletedIsDistanceOne() {
        XCTAssertEqual(PromptEnhancerViewModel.editDistanceRatio("abc", ""), 1)
        XCTAssertEqual(PromptEnhancerViewModel.editDistanceRatio("", "abc"), 1)
    }

    /// A length comparison would call these identical. They are not the same prompt.
    func testSameLengthButDifferentWordsIsNotTreatedAsUnchanged() {
        let ratio = PromptEnhancerViewModel.editDistanceRatio("draft a reply", "cancel my case")
        XCTAssertGreaterThan(ratio, PromptEnhancerViewModel.Copy.undoInvalidateThreshold)
    }

    func testDistanceIsSymmetric() {
        let forward = PromptEnhancerViewModel.editDistanceRatio("kitten", "sitting")
        let backward = PromptEnhancerViewModel.editDistanceRatio("sitting", "kitten")
        XCTAssertEqual(forward, backward, accuracy: 0.0001)
        XCTAssertEqual(forward, 3.0 / 7.0, accuracy: 0.0001)
    }

    /// The cap keeps a long paste cheap. Two long strings differing only past the cap read as
    /// identical, which is the intended trade: they are the same prompt for this purpose.
    func testDistanceIsCappedForLongText() {
        let base = String(repeating: "a", count: 5000)
        let ratio = PromptEnhancerViewModel.editDistanceRatio(base, base + "zzz")
        XCTAssertLessThan(ratio, 0.001)
    }
}
