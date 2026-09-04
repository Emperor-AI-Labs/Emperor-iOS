import XCTest
@testable import EmperorCore

/// Opening a Word document through the server's converter.
///
/// The trap this guards is specific: the metadata route answers **200 with `success: false`**
/// when conversion fails. Reading the status code alone leaves the view model with no data and
/// no error, and the screen falls through to "not a format this app can display" — which is
/// both wrong and hides the reason the server gave.
final class OfficePreviewViewModelTests: XCTestCase {

    private final class FakePreviews: OfficePreviewProviding, @unchecked Sendable {
        var response = OfficePreview.Response(
            success: true, fileName: "brief.docx", pages: 3, cached: false,
            reason: nil, error: nil)
        var pdf = Data("%PDF-1.4 fake".utf8)
        var pdfError: Error?
        private(set) var pdfRequested = false

        func preview(fileName: String, folderName: String?) async throws -> OfficePreview.Response {
            response
        }

        func previewPDF(fileName: String, folderName: String?) async throws -> Data {
            pdfRequested = true
            if let pdfError { throw pdfError }
            return pdf
        }
    }

    // Computed rather than stored, as in `SourceDocumentViewModelTests`: these types are not
    // `Sendable`, so a stored static would be shared mutable state under Swift 6.
    private static func mention(for name: String) -> AnnexureMention {
        AnnexureMention(fileName: name, mark: "Annexure A", startPage: 2, endPage: nil)
    }

    @MainActor
    private func withDoc(
        named name: String = "brief.docx",
        _ body: @MainActor (FakeFiles, FakePreviews, SourceDocumentViewModel) async -> Void
    ) async {
        let files = FakeFiles()
        let previews = FakePreviews()
        await body(files, previews, SourceDocumentViewModel(
            attachment: ChatAttachment(name: name, folderName: "Matters"),
            mention: Self.mention(for: name),
            service: files,
            officePreview: previews))
    }

    // MARK: - The happy path

    @MainActor
    func testAWordDocumentIsFetchedThroughTheConverterRatherThanViewFile() async {
        await withDoc { files, previews, model in
            await model.load()

            XCTAssertTrue(previews.pdfRequested, "the converted PDF was never asked for")
            XCTAssertNil(files.lastRequestedName, "/view-file must not be used for a .docx")
            XCTAssertEqual(model.data, previews.pdf)
        }
    }

    /// The renderer picks its branch on `isPDF`. A converted document has to report true or a
    /// successful preview falls through to "cannot display".
    @MainActor
    func testAConvertedDocumentRendersThroughThePDFPath() async {
        await withDoc { _, _, model in
            await model.load()

            XCTAssertTrue(model.isPDF)
            XCTAssertTrue(model.isConvertedPreview)
        }
    }

    // MARK: - The 200-that-means-failure

    @MainActor
    func testAFailedConversionArrivingAsATwoHundredBecomesAnError() async {
        await withDoc { _, previews, model in
            previews.response = OfficePreview.Response(
                success: false, fileName: nil, pages: nil, cached: nil,
                reason: "too-big", error: "over 50 MB")

            await model.load()

            XCTAssertNil(model.data)
            XCTAssertEqual(
                model.errorMessage,
                "That document is too large to preview. Share it to open it elsewhere.")
            XCTAssertFalse(
                previews.pdfRequested,
                "the bytes must not be fetched after the conversion said it failed")
        }
    }

    /// The message must be the server's reason, not the generic "not a format this app can
    /// display" — the app *can* display it; the server could not convert it.
    @MainActor
    func testTheFailureExplanationSurvivesIntoTheUnavailableMessage() async {
        await withDoc { _, previews, model in
            previews.response = OfficePreview.Response(
                success: false, fileName: nil, pages: nil, cached: nil,
                reason: "busy", error: nil)

            await model.load()

            XCTAssertTrue(model.unavailableMessage.contains("converting several documents"))
            XCTAssertFalse(model.unavailableMessage.contains("not a format"))
        }
    }

    @MainActor
    func testAFailureFetchingTheBytesIsReported() async {
        await withDoc { _, previews, model in
            previews.pdfError = APIError.server(status: 422, message: "conversion vanished")

            await model.load()

            XCTAssertNil(model.data)
            XCTAssertNotNil(model.errorMessage)
            XCTAssertFalse(model.isConvertedPreview)
        }
    }

    // MARK: - Everything else is untouched

    @MainActor
    func testAPDFStillGoesThroughViewFile() async {
        await withDoc(named: "order.pdf") { files, previews, model in
            files.data = ["order.pdf": Data("%PDF".utf8)]

            await model.load()

            XCTAssertFalse(previews.pdfRequested, "a PDF needs no conversion")
            XCTAssertFalse(model.isConvertedPreview)
            XCTAssertTrue(model.isPDF)
        }
    }

    @MainActor
    func testASpreadsheetIsNotSentToTheConverter() async {
        // LibreOffice would convert it, but a spreadsheet paginated onto A4 loses whatever
        // falls off the right edge — which looks like it worked.
        await withDoc(named: "costs.xlsx") { files, previews, model in
            files.data = ["costs.xlsx": Data("bytes".utf8)]

            await model.load()

            XCTAssertFalse(previews.pdfRequested)
            XCTAssertFalse(model.isOfficeDocument)
        }
    }

    /// The service is optional so the core stays constructible without it. A `.docx` with no
    /// converter wired in must fall back rather than silently render nothing.
    @MainActor
    func testWithNoConverterWiredInItFallsBackToTheRawFile() async {
        let files = FakeFiles()
        files.data = ["brief.docx": Data("PK-zip-bytes".utf8)]
        let model = SourceDocumentViewModel(
            attachment: ChatAttachment(name: "brief.docx", folderName: "Matters"),
            mention: Self.mention(for: "brief.docx"),
            service: files)

        await model.load()

        XCTAssertEqual(model.data, Data("PK-zip-bytes".utf8))
        XCTAssertFalse(model.isConvertedPreview)
    }
}
