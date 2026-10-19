import XCTest
@testable import EmperorCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Feedback on a draft or an answer — `POST /draft-feedback`, as the web's `DraftFeedbackButton`
/// sends it, and the sheet in front of it.
final class FeedbackTests: XCTestCase {

    private static let config = APIConfig(baseURL: URL(string: "https://example.test/api")!)

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

    private func makeService() async -> FeedbackService {
        let client = APIClient(config: Self.config, session: HTTPStub.session())
        await client.setCredentials(Credentials(token: "tok-abc", userID: 42))
        return FeedbackService(client: client)
    }

    private static func feedback(
        rating: DraftFeedbackRating? = .down, categories: [DraftFeedbackCategory] = [.citations],
        comment: String = "Para 14 cites nothing.", html: String? = "<h1>WRIT PETITION</h1>"
    ) -> DraftFeedback {
        DraftFeedback(
            chatID: "chat-1", documentID: nil, documentTitle: "Writ Petition", rating: rating,
            categories: categories, comment: comment, docHTML: html)
    }

    // MARK: - The wire

    func testTheBodyIsTheWebs() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"ok":true,"id":7}"#))

        let id = try await service.send(Self.feedback(categories: [.formatting, .citations]))

        XCTAssertEqual(id, 7)
        let sent = try XCTUnwrap(HTTPStub.lastRequest)
        XCTAssertEqual(sent.path, "/api/draft-feedback")
        let body = sent.bodyJSON
        XCTAssertEqual(body["userId"] as? String, "42")
        XCTAssertEqual(body["chatId"] as? String, "chat-1")
        XCTAssertEqual(body["documentTitle"] as? String, "Writ Petition")
        XCTAssertEqual(body["rating"] as? String, "down")
        XCTAssertEqual(body["categories"] as? [String], ["Formatting", "Citations"])
        XCTAssertEqual(body["comment"] as? String, "Para 14 cites nothing.")
        XCTAssertEqual(body["docHtml"] as? String, "<h1>WRIT PETITION</h1>")
        // Present and null, as the web sends it when it has no saved id.
        XCTAssertTrue(body.keys.contains("documentId"))
        XCTAssertTrue(body["documentId"] is NSNull)
    }

    func testTheSixCategoriesAreTheWebsWords() {
        XCTAssertEqual(
            DraftFeedbackCategory.allCases.map(\.rawValue),
            ["Formatting", "Accuracy", "Structure", "Citations", "Annexures", "Other"])
        XCTAssertEqual(DraftFeedbackRating.up.label, "Good")
        XCTAssertEqual(DraftFeedbackRating.down.label, "Needs work")
    }

    /// A comment with no rating is enough; the rating goes as null.
    func testNoRatingIsSentAsNull() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"ok":true,"id":1}"#))

        try await service.send(Self.feedback(rating: nil, categories: []))

        let body = try XCTUnwrap(HTTPStub.lastRequest).bodyJSON
        XCTAssertTrue(body["rating"] is NSNull)
        XCTAssertEqual(body["categories"] as? [String], [])
    }

    /// An answer with no draft sends no text: the conversation id is how a reviewer finds it.
    func testAnAnswerWithNoDraftSendsNoText() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"ok":true}"#))

        try await service.send(Self.feedback(html: nil))

        XCTAssertEqual(try XCTUnwrap(HTTPStub.lastRequest).bodyJSON["docHtml"] as? String, "")
    }

    /// The server trims rather than refuses, so both are capped before they are uploaded.
    func testTheCommentAndTheDraftAreCappedAtTheServersLimits() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"ok":true}"#))

        try await service.send(Self.feedback(
            comment: String(repeating: "x", count: FeedbackService.commentLimit + 500),
            html: String(repeating: "é", count: FeedbackService.htmlLimit + 10)))

        let body = try XCTUnwrap(HTTPStub.lastRequest).bodyJSON
        XCTAssertEqual((body["comment"] as? String)?.count, FeedbackService.commentLimit)
        XCTAssertEqual((body["docHtml"] as? String)?.utf16.count, FeedbackService.htmlLimit)
    }

    /// A cut never splits a character in two — an emoji is two UTF-16 units.
    func testTheDraftIsCutOnACharacterBoundary() {
        let html = String(repeating: "a", count: FeedbackService.htmlLimit - 1) + "🙂🙂"
        let capped = FeedbackService.cappedHTML(html)
        XCTAssertEqual(capped.utf16.count, FeedbackService.htmlLimit - 1)
        XCTAssertFalse(capped.contains("🙂"))
    }

    /// The route's refusal: 400 with `ok: false` and its reason, which reaches the person.
    func testARefusalCarriesTheServersReason() async {
        let service = await makeService()
        HTTPStub.always(.json(#"{"ok":false,"error":"Pick a rating or write a comment"}"#, status: 400))

        do {
            try await service.send(Self.feedback(rating: nil, comment: ""))
            XCTFail("a 400 must throw")
        } catch {
            XCTAssertTrue("\(error)".contains("Pick a rating or write a comment"), "\(error)")
        }
    }

    /// "Sent" is only what the server said it stored.
    func testATwoHundredWithoutOkStillThrows() async {
        let service = await makeService()
        HTTPStub.always(.json(#"{"ok":false,"error":"Missing parameters"}"#))

        do {
            try await service.send(Self.feedback())
            XCTFail("ok:false must not read as sent")
        } catch {
            XCTAssertTrue("\(error)".contains("Missing parameters"))
        }
    }

    func testAServerErrorThrows() async {
        let service = await makeService()
        HTTPStub.always(.json(#"{"ok":false,"error":"nope"}"#, status: 500))

        do {
            try await service.send(Self.feedback())
            XCTFail("a 500 must throw")
        } catch {}
    }

    // MARK: - What it is about

    func testADraftsTargetCarriesItsHTMLAndItsWord() {
        let doc = StreamArtifact(kind: .canvas, format: .html, title: "Plaint", body: "<p>x</p>")
        let target = DraftFeedbackTarget.artifact(doc, chatID: "c")
        XCTAssertEqual(target.subject, "document")
        XCTAssertEqual(target.docHTML, "<p>x</p>")

        let table = StreamArtifact(kind: .table, format: .markdown, title: "Dates", body: "| a | b |\n|---|---|\n| 1 | 2 |")
        let tableTarget = DraftFeedbackTarget.artifact(table, chatID: "c")
        XCTAssertEqual(tableTarget.subject, "table")
        XCTAssertTrue(tableTarget.docHTML?.contains("<table") ?? false, "a Markdown table goes as HTML")
    }

    func testAnAnswerIsAboutItsDraftWhenItHasOne() {
        let withDraft = StreamContent.parse(
            "Here it is.\n[CANVAS_TRIGGER: Plaint]\n<canvas_content><h1>PLAINT</h1><p>Body</p></canvas_content>")
        XCTAssertEqual(withDraft.artifacts.count, 1)
        let target = DraftFeedbackTarget.answer(withDraft, chatID: "c")
        XCTAssertEqual(target.subject, "document")
        XCTAssertEqual(target.title, "Plaint")
        XCTAssertTrue(target.docHTML?.contains("PLAINT") ?? false)

        let plain = DraftFeedbackTarget.answer(StreamContent.parse("Section 9 applies."), chatID: "c")
        XCTAssertEqual(plain.subject, "answer")
        XCTAssertNil(plain.docHTML)
    }

    // MARK: - The sheet

    func testTheSheetNeedsARatingOrAComment() async {
        await onFeedbackMainActor {
            let model = DraftFeedbackViewModel(target: Self.documentTarget, service: RecordingFeedback())
            XCTAssertFalse(model.canSend)
            model.toggle(.formatting)
            XCTAssertFalse(model.canSend, "categories alone are not enough for the route")
            model.comment = "  "
            XCTAssertFalse(model.canSend)
            model.comment = "The prayer is missing."
            XCTAssertTrue(model.canSend)
            model.comment = ""
            model.toggle(.up)
            XCTAssertTrue(model.canSend)
            model.toggle(.up)
            XCTAssertNil(model.rating, "tapping the chosen rating again clears it")
        }
    }

    func testCategoriesKeepTheChipOrder() async {
        await onFeedbackMainActor {
            let model = DraftFeedbackViewModel(target: Self.documentTarget, service: RecordingFeedback())
            model.toggle(.other)
            model.toggle(.accuracy)
            model.toggle(.annexures)
            model.toggle(.other)
            XCTAssertEqual(model.categories, [.accuracy, .annexures])
        }
    }

    func testSendingPassesEverythingAndASentSheetCannotSendTwice() async {
        await onFeedbackMainActor {
            let fake = RecordingFeedback()
            let model = DraftFeedbackViewModel(target: Self.documentTarget, rating: .down, service: fake)
            model.toggle(.citations)
            model.comment = "Wrong section."
            let sent = await model.send()
            XCTAssertTrue(sent)
            XCTAssertTrue(model.isSent)
            XCTAssertEqual(fake.sent.count, 1)
            XCTAssertEqual(fake.sent.first?.rating, .down)
            XCTAssertEqual(fake.sent.first?.categories, [.citations])
            XCTAssertEqual(fake.sent.first?.docHTML, "<p>Draft</p>")
            XCTAssertEqual(fake.sent.first?.documentTitle, "Plaint")
            XCTAssertFalse(model.canSend)
        }
    }

    func testAFailureKeepsEverythingAndSaysWhy() async {
        await onFeedbackMainActor {
            let fake = RecordingFeedback()
            fake.failure = APIError.server(status: 400, message: "Pick a rating or write a comment")
            let model = DraftFeedbackViewModel(target: Self.documentTarget, rating: .up, service: fake)
            model.comment = "Good"
            let sent = await model.send()
            XCTAssertFalse(sent)
            XCTAssertEqual(model.error, "Pick a rating or write a comment")
            XCTAssertEqual(model.comment, "Good")
            XCTAssertEqual(model.rating, .up)
        }
    }

    /// The footer says what leaves the phone: the draft's text when there is one.
    func testThePrivacyNoteSaysWhenTheDraftIsSent() async {
        await onFeedbackMainActor {
            let doc = DraftFeedbackViewModel(target: Self.documentTarget, service: RecordingFeedback())
            XCTAssertEqual(doc.title, "Feedback on this document")
            XCTAssertTrue(doc.privacyNote.contains("text is sent"))

            let answer = DraftFeedbackViewModel(
                target: DraftFeedbackTarget(subject: "answer", title: "", chatID: "c", docHTML: nil),
                service: RecordingFeedback())
            XCTAssertTrue(answer.privacyNote.contains("not sent"))
        }
    }

    private static let documentTarget = DraftFeedbackTarget(
        subject: "document", title: "Plaint", chatID: "chat-1", docHTML: "<p>Draft</p>")
}

/// Linux XCTest cannot invoke a `@MainActor` test method — see `ChatViewModelTests`.
@MainActor
private func onFeedbackMainActor(_ body: @MainActor () async -> Void) async {
    await body()
}

/// Records what the sheet sends, and fails when told to.
private final class RecordingFeedback: FeedbackProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [DraftFeedback] = []
    var failure: Error?

    var sent: [DraftFeedback] { lock.withLock { _sent } }

    func send(_ feedback: DraftFeedback) async throws -> Int? {
        if let failure { throw failure }
        lock.withLock { _sent.append(feedback) }
        return 1
    }
}
