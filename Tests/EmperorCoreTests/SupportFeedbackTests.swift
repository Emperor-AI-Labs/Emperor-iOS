import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import EmperorCore

/// "Report a bug": the multipart body the web's `submitSupportFeedback` sends, the route on the
/// wire, and the dialog in front of it.
final class SupportFeedbackTests: XCTestCase {

    private static let config = APIConfig(baseURL: URL(string: "https://example.test/api")!)

    override func setUp() {
        super.setUp()
        HTTPStub.reset()
    }

    override func tearDown() {
        HTTPStub.reset()
        super.tearDown()
    }

    private static let shot = SupportAttachment(name: "screenshot-1.jpg", contentType: "image/jpeg", data: Data([0xFF, 0xD8, 0xFF]))

    // MARK: - The body

    func testTheBodyCarriesTheWebsFieldsThenEachFileAsFileN() throws {
        let body = SupportFeedbackBody.body(
            fields: .init(description: "The list is blank", userID: "42", kind: .bug, pageURL: "ios/You"),
            attachments: [Self.shot, SupportAttachment(name: "", contentType: "image/png", data: Data("PNG".utf8))],
            boundary: "B0UND")
        let text = String(decoding: body, as: UTF8.self)
        let expected = [
            "--B0UND\r\nContent-Disposition: form-data; name=\"description\"\r\n\r\nThe list is blank\r\n",
            "--B0UND\r\nContent-Disposition: form-data; name=\"userId\"\r\n\r\n42\r\n",
            "--B0UND\r\nContent-Disposition: form-data; name=\"kind\"\r\n\r\nbug\r\n",
            "--B0UND\r\nContent-Disposition: form-data; name=\"pageUrl\"\r\n\r\nios/You\r\n",
            "--B0UND\r\nContent-Disposition: form-data; name=\"file_0\"; filename=\"screenshot-1.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n",
        ].joined()
        XCTAssertTrue(text.hasPrefix(expected), text)
        XCTAssertTrue(body.range(of: Data([0xFF, 0xD8, 0xFF])) != nil)
        XCTAssertTrue(text.contains("name=\"file_1\"; filename=\"attachment_1\"\r\nContent-Type: image/png\r\n\r\nPNG\r\n"))
        XCTAssertTrue(text.hasSuffix("--B0UND--\r\n"))
        XCTAssertEqual(SupportFeedbackBody.contentType(boundary: "B0UND"), "multipart/form-data; boundary=B0UND")
    }

    func testAFilenameCannotBreakItsHeader() {
        XCTAssertEqual(SupportFeedbackBody.filename("a\"b\r\nc.png", index: 0), "a_b__c.png")
        XCTAssertEqual(SupportFeedbackBody.filename("  ", index: 3), "attachment_3")
    }

    func testTheKindIsBugOrFeedbackAndNothingElse() {
        XCTAssertEqual(SupportFeedbackKind(wire: "bug"), .bug)
        XCTAssertEqual(SupportFeedbackKind(wire: "BUG"), .feedback)
        XCTAssertEqual(SupportFeedbackKind(wire: "praise"), .feedback)
        XCTAssertEqual(SupportFeedbackKind(wire: nil), .feedback)
    }

    // MARK: - The route

    private func makeService() async -> SupportFeedbackService {
        let client = APIClient(config: Self.config, session: HTTPStub.session())
        await client.setCredentials(Credentials(token: "tok-abc", userID: 42))
        var service = SupportFeedbackService(client: client)
        service.newBoundary = { "Boundary-fixed" }
        return service
    }

    func testAReportIsPostedAsMultipart() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":true,"id":17}"#))

        let id = try await service.submit(description: "  Blank list \n", kind: .bug, pageURL: "ios/You", attachments: [Self.shot])

        XCTAssertEqual(id, 17)
        let sent = try XCTUnwrap(HTTPStub.lastRequest)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.path, "/api/support-feedback")
        XCTAssertEqual(sent.header("Content-Type"), "multipart/form-data; boundary=Boundary-fixed")
        XCTAssertEqual(sent.header("Authorization"), "Bearer tok-abc")
        let text = String(decoding: try XCTUnwrap(sent.httpBody), as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"description\"\r\n\r\nBlank list\r\n"))
        XCTAssertTrue(text.contains("name=\"userId\"\r\n\r\n42\r\n"))
        XCTAssertTrue(text.contains("name=\"file_0\"; filename=\"screenshot-1.jpg\""))
    }

    func testWhatCannotBeAcceptedIsNeverSent() async {
        let service = await makeService()
        let tooMany = Array(repeating: Self.shot, count: 13)
        let tooBig = [SupportAttachment(name: "big.jpg", contentType: "image/jpeg",
                                        data: Data(count: SupportFeedbackService.maxAttachmentBytes + 1))]
        for (description, files, message) in [
            ("   ", [Self.shot], SupportFeedbackService.emptyMessage),
            ("Bug", tooMany, SupportFeedbackService.tooManyMessage),
            ("Bug", tooBig, SupportFeedbackService.tooLargeMessage),
        ] {
            do {
                try await service.submit(description: description, kind: .bug, pageURL: "ios/You", attachments: files)
                XCTFail("expected a refusal")
            } catch {
                XCTAssertEqual(error as? APIError, .server(status: 400, message: message))
            }
        }
        XCTAssertTrue(HTTPStub.seen.isEmpty)
    }

    func testRefusalsAreWorded() {
        XCTAssertEqual(
            SupportFeedbackService.failure(status: 400, answer: try? JSONDecoder().decode(SupportFeedbackService.Answer.self, from: Data(#"{"error":"Description is required"}"#.utf8)), body: Data()),
            .server(status: 400, message: "Description is required"))
        XCTAssertEqual(
            SupportFeedbackService.failure(status: 413, answer: nil, body: Data()),
            .server(status: 413, message: SupportFeedbackService.tooLargeMessage))
        XCTAssertEqual(
            SupportFeedbackService.failure(status: 200, answer: nil, body: Data()),
            .server(status: 200, message: SupportFeedbackService.failedMessage))
    }

    // MARK: - The dialog

    func testTheDescriptionIsRequiredAndTheReportIsABugFromTheScreen() async {
        await withReport { service, model in
            XCTAssertFalse(model.canSend)
            let sentEmpty = await model.send()
            XCTAssertFalse(sentEmpty)
            XCTAssertTrue(service.sent.isEmpty)

            model.description = "  The cause list is empty  "
            model.add([Self.shot])
            let sent = await model.send()
            XCTAssertTrue(sent)
            XCTAssertTrue(model.isSent)
            XCTAssertFalse(model.canSend)
            XCTAssertEqual(service.sent, [.init(description: "The cause list is empty", kind: .bug, pageURL: "ios/You", attachments: [Self.shot])])
        }
    }

    func testAttachmentsStopAtTwelve() async {
        await withReport { _, model in
            model.add(Array(repeating: Self.shot, count: 10))
            model.addScreenshots([Data([1]), Data([2]), Data([3])])
            XCTAssertEqual(model.attachments.count, 12)
            XCTAssertEqual(model.attachments.suffix(2).map(\.name), ["screenshot-11.jpg", "screenshot-12.jpg"])
            XCTAssertEqual(model.attachments.last?.contentType, "image/jpeg")
            XCTAssertFalse(model.canAddAttachments)
            model.remove(model.attachments[11].id)
            XCTAssertEqual(model.remainingSlots, 1)
        }
    }

    func testAFailedSendKeepsTheReportAndSaysWhy() async {
        await withReport { service, model in
            service.error = APIError.server(status: 413, message: SupportFeedbackService.tooLargeMessage)
            model.description = "Crash on open"
            model.add([Self.shot])
            let sent = await model.send()
            XCTAssertFalse(sent)
            XCTAssertEqual(model.error, SupportFeedbackService.tooLargeMessage)
            XCTAssertEqual(model.description, "Crash on open")
            XCTAssertEqual(model.attachments.count, 1)
            model.description += "!"
            XCTAssertNil(model.error, "typing again clears the error, as on the web")
        }
    }
}

@MainActor
private func withReport(_ body: @MainActor (FakeSupportFeedback, BugReportViewModel) async -> Void) async {
    let service = FakeSupportFeedback()
    await body(service, BugReportViewModel(screen: "You", service: service))
}
