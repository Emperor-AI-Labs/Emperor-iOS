import XCTest
@testable import EmperorCore

/// Citation resolution and scan attachment — the two flows that used to live in
/// `ChatThreadView` and so could not be exercised without a device.
final class ChatCitationAndScanTests: XCTestCase {

    private static var mention: AnnexureMention {
        AnnexureMention(fileName: "Sale_Deed.pdf", mark: "Annexure A", startPage: 5, endPage: 7)
    }

    // MARK: - Citations

    /// A citation is by construction a file the model was given, so the turn's own attachments
    /// resolve it without a network call — and `tree()` is an expensive server-side walk.
    func testCitationResolvesFromTheTurnsAttachmentsWithoutFetchingTheLibrary() async {
        await withThread { files, _, model in
            model.attachments = [
                ChatAttachment(name: "Sale_Deed.pdf", folderName: "Partition_Suit"),
            ]
            await model.showSource(Self.mention)

            XCTAssertEqual(model.openSource?.attachment.folderName, "Partition_Suit")
            XCTAssertEqual(files.treeCallCount, 0, "the library must not be fetched needlessly")
            XCTAssertNil(model.citationError)
        }
    }

    /// A citation from an earlier turn may name a file no longer attached to the composer, so
    /// the library is the necessary second stage.
    func testCitationFallsBackToTheLibrary() async {
        await withThread { files, _, model in
            files.tree = [folder("Partition_Suit", [
                .file(readyFile("Partition_Suit/Sale_Deed.pdf")),
            ])]
            await model.showSource(Self.mention)

            XCTAssertEqual(model.openSource?.attachment.name, "Sale_Deed.pdf")
            XCTAssertEqual(model.openSource?.attachment.folderName, "Partition_Suit")
            XCTAssertEqual(model.openSource?.mention, Self.mention)
        }
    }

    /// A transcript cites repeatedly. Re-walking the whole storage tree per tap would be a
    /// visible stall on every one after the first.
    func testTheLibraryIsFetchedOnlyOnce() async {
        await withThread { files, _, model in
            files.tree = [folder("Partition_Suit", [
                .file(readyFile("Partition_Suit/Sale_Deed.pdf")),
            ])]
            await model.showSource(Self.mention)
            model.openSource = nil
            await model.showSource(Self.mention)

            XCTAssertEqual(files.treeCallCount, 1)
            XCTAssertNotNil(model.openSource, "the cached tree still resolves the second tap")
        }
    }

    /// A dead tap is the worst outcome here: the product's central claim is that every line
    /// names a page you can open, so a citation that cannot be opened has to say why.
    func testAnUnresolvableCitationNamesTheMissingFile() async {
        await withThread { _, _, model in
            await model.showSource(Self.mention)

            XCTAssertNil(model.openSource)
            XCTAssertEqual(
                model.citationError,
                "Sale Deed.pdf is not in your document library any more, so its cited page cannot be opened.",
                "the name is shown as written, not as sanitised on disk")
        }
    }

    // MARK: - Scanning

    private static var scan: ScannedDocument {
        ScannedDocument(
            pdfData: Data("%PDF-1.4".utf8), suggestedName: "Scan-2026-08-26T09-15-00Z.pdf")
    }

    func testASuccessfulScanIsAttachedToTheTurn() async {
        await withThread { _, uploads, model in
            uploads.events = [.finished(.scanned)]
            await model.attach(Self.scan)

            XCTAssertEqual(model.attachments.count, 1)
            XCTAssertEqual(model.attachments.first?.folderName, "Scans")
            XCTAssertNil(model.scanError)
        }
    }

    /// Annexure citations match on the exact on-disk name, so the attachment must carry the
    /// sanitised form rather than the name as captured.
    func testTheAttachedNameIsTheSanitisedOnDiskName() async {
        await withThread { _, uploads, model in
            uploads.events = [.finished(.ready)]
            await model.attach(ScannedDocument(
                pdfData: Data(), suggestedName: "देखिए.pdf"))

            XCTAssertEqual(
                model.attachments.first?.name,
                UploadService.sanitize(fileName: "देखिए.pdf"))
        }
    }

    /// Ingestion runs after the HTTP response has closed, so a failure there arrives with no
    /// error status at all. This is the only place it can surface.
    func testAnIngestionFailureIsReportedAndNothingIsAttached() async {
        await withThread { _, uploads, model in
            uploads.events = [.finished(.failed("ERROR: the file could not be read"))]
            await model.attach(Self.scan)

            XCTAssertTrue(model.attachments.isEmpty)
            XCTAssertEqual(model.scanError, "ERROR: the file could not be read")
        }
    }

    /// A file that is still ingesting when the stream ends is not usable yet — attaching it
    /// would put a name on the turn the server cannot read.
    func testAFileStillIngestingIsNotAttached() async {
        await withThread { _, uploads, model in
            uploads.events = [.progress(sent: 10, total: 10), .processing("Extracting text")]
            await model.attach(Self.scan)

            XCTAssertTrue(model.attachments.isEmpty)
            XCTAssertNil(model.scanError, "still working is not a failure")
        }
    }

    /// A dropped connection mid-upload reads as offline rather than as a scanner fault — the
    /// user's next action is to find signal, not to re-photograph the paperbook.
    func testATransportFailureDuringUploadIsReported() async {
        await withThread { _, uploads, model in
            uploads.error = APIError.transport("The network connection was lost.")
            await model.attach(Self.scan)

            XCTAssertTrue(model.attachments.isEmpty)
            XCTAssertEqual(model.scanError, DisplayText.offlineMessage)
        }
    }

    func testAFailedCaptureIsReported() async {
        await withThread { _, _, model in
            model.reportScanFailure(ScanError.noPages)
            XCTAssertEqual(model.scanError, "No pages were captured.")
        }
    }

    // MARK: - Seeding

    /// `preferred_model` seeds the picker only; the per-request model is what the server
    /// honours and is sent explicitly on every turn regardless.
    func testPreferredModelSeedsThePicker() async {
        await withThread(preferredModel: "thinking") { _, _, model in
            XCTAssertEqual(model.model, .thinking)
        }
    }

    /// An account with no preference, or one naming a model this build does not know, must
    /// still land on something valid.
    func testAnUnknownPreferenceFallsBackToTheDefault() async {
        await withThread(preferredModel: "gpt-5-turbo-ultra") { _, _, model in
            XCTAssertEqual(model.model, .default)
        }
        await withThread(preferredModel: nil) { _, _, model in
            XCTAssertEqual(model.model, .default)
        }
    }
}

@MainActor
private func withThread(
    preferredModel: String? = nil,
    _ body: @MainActor (FakeFiles, FakeUploads, ChatViewModel) async -> Void
) async {
    let files = FakeFiles()
    let uploads = FakeUploads()
    await body(files, uploads, ChatViewModel(
        chatID: "chat-1",
        service: InertChat(),
        files: files,
        uploads: uploads,
        preferredModel: preferredModel))
}
