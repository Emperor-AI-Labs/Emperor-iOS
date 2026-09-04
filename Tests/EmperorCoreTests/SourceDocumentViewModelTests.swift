import XCTest
@testable import EmperorCore

final class SourceDocumentViewModelTests: XCTestCase {

    // Computed rather than stored: `ChatAttachment` is not `Sendable`, so a stored static
    // would be shared mutable state as far as Swift 6 is concerned.
    fileprivate static var attachment: ChatAttachment {
        ChatAttachment(name: "Sale_Deed.pdf", folderName: "Partition_Suit")
    }
    fileprivate static var mention: AnnexureMention {
        AnnexureMention(fileName: "Sale_Deed.pdf", mark: "Annexure A", startPage: 5, endPage: 7)
    }

    // MARK: - Page mapping

    /// The server indexes pages as `idx + 1` (`sync-server.js:1479`); PDFKit is 0-based. An
    /// off-by-one here lands the reader on the wrong page of a pleading.
    func testCitedPageMapsToAZeroBasedIndex() {
        XCTAssertEqual(SourceDocumentViewModel.pageIndex(for: 5, pageCount: 20), 4)
        XCTAssertEqual(SourceDocumentViewModel.pageIndex(for: 1, pageCount: 20), 0)
    }

    /// A citation can name a page beyond the file if the model read a different edition.
    /// Landing on the last page beats showing nothing.
    func testAPageBeyondTheDocumentIsClampedToTheLast() {
        XCTAssertEqual(SourceDocumentViewModel.pageIndex(for: 900, pageCount: 20), 19)
    }

    func testNoPageOrAnEmptyDocumentYieldsNoIndex() {
        XCTAssertNil(SourceDocumentViewModel.pageIndex(for: nil, pageCount: 20))
        XCTAssertNil(SourceDocumentViewModel.pageIndex(for: 5, pageCount: 0))
        // 0 and negatives are not pages the server can have meant.
        XCTAssertNil(SourceDocumentViewModel.pageIndex(for: 0, pageCount: 20))
        XCTAssertNil(SourceDocumentViewModel.pageIndex(for: -3, pageCount: 20))
    }

    // MARK: - Titles

    func testTitlesReadAsWrittenRatherThanAsStoredOnDisk() async {
        await withSource { _, model in
            XCTAssertEqual(model.displayName, "Sale Deed.pdf")
            XCTAssertEqual(model.subtitle, "Annexure A · pp. 5–7")
        }
    }

    /// A citation naming a single page says "p. 5", not a range.
    func testASinglePageCitationHasNoRange() async {
        let single = AnnexureMention(
            fileName: "Sale_Deed.pdf", mark: "Annexure A", startPage: 5, endPage: 5)
        await withSource(mention: single) { _, model in
            XCTAssertEqual(model.subtitle, "Annexure A · p. 5")
        }
    }

    // MARK: - Loading

    func testLoadFetchesTheDocument() async {
        await withSource { files, model in
            files.data = ["Sale_Deed.pdf": Data("%PDF-1.4".utf8)]
            await model.load()

            XCTAssertEqual(model.data, Data("%PDF-1.4".utf8))
            XCTAssertFalse(model.isLoading)
            XCTAssertNil(model.errorMessage)
        }
    }

    /// A document deleted since the answer was written is the failure the user most needs
    /// explained, and this route answers with a bare text body rather than the JSON envelope.
    func testAMissingDocumentExplainsItself() async {
        await withSource { files, model in
            files.dataError = APIError.server(
                status: 404, message: "That document is no longer in your library.")
            await model.load()

            XCTAssertEqual(model.unavailableMessage, "That document is no longer in your library.")
        }
    }

    /// When the file arrived intact but is not something we can show, the honest message is
    /// about the format — not a network error that did not happen.
    func testAnUnshowableFormatSaysSo() async {
        await withSource { files, model in
            files.data = ["Sale_Deed.pdf": Data([0xFF, 0xD8, 0xFF])]
            await model.load()

            XCTAssertEqual(
                model.unavailableMessage, "Sale Deed.pdf is not a format this app can display.")
        }
    }

    func testFormatIsSniffedFromTheExtension() async {
        await withSource { _, model in
            XCTAssertTrue(model.isPDF)
        }
        // Case-insensitively: the server preserves whatever the uploader typed.
        let shouty = ChatAttachment(name: "ORDER.PDF", folderName: nil)
        await withSource(attachment: shouty) { _, model in
            XCTAssertTrue(model.isPDF)
        }
        let text = ChatAttachment(name: "notes.txt", folderName: nil)
        await withSource(attachment: text) { _, model in
            XCTAssertFalse(model.isPDF)
        }
    }

    func testTextContentsDecodeUTF8() async {
        await withSource(attachment: ChatAttachment(name: "notes.txt", folderName: nil)) { files, model in
            files.data = ["notes.txt": Data("Adjourned to 14th.".utf8)]
            await model.load()

            XCTAssertEqual(model.textContents, "Adjourned to 14th.")
        }
    }
}

@MainActor
private func withSource(
    attachment: ChatAttachment = SourceDocumentViewModelTests.attachment,
    mention: AnnexureMention = SourceDocumentViewModelTests.mention,
    _ body: @MainActor (FakeFiles, SourceDocumentViewModel) async -> Void
) async {
    let files = FakeFiles()
    await body(files, SourceDocumentViewModel(
        attachment: attachment, mention: mention, service: files))
}
