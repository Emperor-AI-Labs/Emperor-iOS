import XCTest
@testable import EmperorCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The in-app report channel for a generated answer.
///
/// Both stores require one for a product that produces AI content, and this app had none. The
/// interesting behaviour is not the happy path — it is that this route answers **200 with
/// `ok: false`** when it rejects, so a client that trusts the status code tells the user a
/// report was filed that was not.
final class FeedbackTests: XCTestCase {

    private static let config = APIConfig(baseURL: URL(string: "https://example.test/api")!)

    override func tearDown() {
        HTTPStub.reset()
        super.tearDown()
    }

    private func makeService() async -> FeedbackService {
        let client = APIClient(config: Self.config, session: HTTPStub.session())
        await client.setCredentials(Credentials(token: "tok-abc", userID: 42))
        return FeedbackService(client: client)
    }

    func testAReportPostsTheReasonAsACategory() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"ok":true,"id":7}"#))

        try await service.reportAnswer(
            chatID: "chat-1", reason: .fabricatedCitation, comment: "Para 14 cites nothing.")

        let sent = try XCTUnwrap(HTTPStub.lastRequest)
        XCTAssertEqual(sent.path, "/api/draft-feedback")
        let body = sent.bodyJSON
        XCTAssertEqual(body["categories"] as? [String], ["fabricated-citation"])
        XCTAssertEqual(body["chatId"] as? String, "chat-1")
        XCTAssertEqual(body["comment"] as? String, "Para 14 cites nothing.")
    }

    /// `rating` is coerced to null server-side unless it is exactly `up` or `down`, and a null
    /// rating with an empty comment is a 400. A report is always a complaint.
    func testTheRatingIsAlwaysDown() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"ok":true}"#))

        try await service.reportAnswer(chatID: "c", reason: .harmful, comment: "")

        let body = try XCTUnwrap(HTTPStub.lastRequest).bodyJSON
        XCTAssertEqual(body["rating"] as? String, "down")
    }

    /// The reported answer is already stored against the chat id. Sending it again would copy
    /// privileged client material into a second table for no reviewer benefit.
    func testTheAnswerTextIsNotSent() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"ok":true}"#))

        try await service.reportAnswer(chatID: "c", reason: .wrongLaw, comment: "wrong section")

        let body = try XCTUnwrap(HTTPStub.lastRequest).bodyJSON
        XCTAssertNil(body["docHtml"], "the answer's text must not travel with the report")
    }

    /// The server truncates rather than rejects, so an uncapped field loses its tail with no
    /// error. Capped client-side, where the sheet can say so before the tap.
    func testALongCommentIsCappedRatherThanTruncatedServerSide() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"ok":true}"#))

        try await service.reportAnswer(
            chatID: "c", reason: .other,
            comment: String(repeating: "x", count: FeedbackService.commentLimit + 500))

        let body = try XCTUnwrap(HTTPStub.lastRequest).bodyJSON
        XCTAssertEqual((body["comment"] as? String)?.count, FeedbackService.commentLimit)
    }

    /// **The one that matters.** A rejection arrives as 200, so branching on the status code
    /// would report failure as success.
    func testARejectionArrivingAsTwoHundredStillThrows() async {
        let service = await makeService()
        HTTPStub.always(.json(#"{"ok":false,"error":"Missing parameters"}"#))

        do {
            try await service.reportAnswer(chatID: "c", reason: .other, comment: "x")
            XCTFail("a 200 with ok:false must not be treated as a filed report")
        } catch {
            XCTAssertTrue(
                "\(error)".contains("Missing parameters"),
                "the server's own reason should reach the user, got \(error)")
        }
    }

    func testAServerErrorThrows() async {
        let service = await makeService()
        HTTPStub.always(.json(#"{"error":"nope"}"#, status: 500))

        do {
            try await service.reportAnswer(chatID: "c", reason: .other, comment: "x")
            XCTFail("a 500 must throw")
        } catch {}
    }

    /// A report from a screen that has no conversation behind it still has to be filable —
    /// `chatId` is nullable on the route.
    func testAReportWithNoChatStillSends() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"ok":true}"#))

        try await service.reportAnswer(chatID: nil, reason: .other, comment: "general")

        XCTAssertNotNil(HTTPStub.lastRequest)
    }

    func testEveryReasonIsOfferableAndHasAStableWireValue() {
        XCTAssertEqual(ReportReason.allCases.count, 4)
        for reason in ReportReason.allCases {
            XCTAssertFalse(reason.label.isEmpty)
            XCTAssertEqual(reason.rawValue, reason.rawValue.lowercased())
        }
    }
}
