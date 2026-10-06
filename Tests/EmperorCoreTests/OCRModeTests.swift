import XCTest
@testable import EmperorCore

/// OCR as a mode of its own beside Translate, and the switch between them.
///
/// The web's page carries the same two tabs (`OCRTranslate.jsx:624-650`): OCR digitises only and
/// sends `lang: 'Original'`, both take the same files, and moving between them starts clean.
final class OCRModeTests: XCTestCase {

    // MARK: - What each mode is

    func testTheSwitchOffersOCRThenTranslateAndNeverPDFToWord() {
        XCTAssertEqual(OCRViewModel.Mode.switchable, [.ocr, .translate], "the web's tab order")
        XCTAssertTrue(OCRViewModel.Mode.ocr.isSwitchable)
        XCTAssertTrue(OCRViewModel.Mode.translate.isSwitchable)
        XCTAssertFalse(OCRViewModel.Mode.pdfToWord.isSwitchable)
    }

    func testOCRIsTitledAndExplainedAsItsOwnOption() {
        XCTAssertEqual(OCRViewModel.Mode.ocr.title, "OCR")
        XCTAssertEqual(OCRViewModel.Mode.translate.title, "Translate")
        XCTAssertEqual(OCRViewModel.Mode.pdfToWord.title, "PDF to Word")
        XCTAssertEqual(
            OCRViewModel.Mode.ocr.summary,
            "Make a scanned or photographed document searchable and editable, in its own language.")
        XCTAssertNotNil(OCRViewModel.Mode.translate.summary)
        XCTAssertNil(OCRViewModel.Mode.pdfToWord.summary, "no switch, so no line under one")
    }

    /// A language control in OCR would be a choice that changes nothing — it always sends
    /// Original — so only Translate shows one.
    func testOnlyTranslateAsksForALanguage() {
        XCTAssertFalse(OCRViewModel.Mode.ocr.choosesLanguage)
        XCTAssertTrue(OCRViewModel.Mode.translate.choosesLanguage)
        XCTAssertFalse(OCRViewModel.Mode.pdfToWord.choosesLanguage)
    }

    func testOCRScansWithTheCameraAsTranslateDoes() {
        XCTAssertTrue(OCRViewModel.Mode.ocr.offersScanning)
        XCTAssertTrue(OCRViewModel.Mode.translate.offersScanning)
        XCTAssertFalse(OCRViewModel.Mode.pdfToWord.offersScanning)
    }

    // MARK: - What each mode accepts

    /// The web's list for OCR and Translate (`OCRTranslate.jsx:309-310`), PDFs alone for PDF to
    /// Word.
    func testOCRAndTranslateTakeTheWebsFileTypes() {
        let web = ["pdf", "docx", "jpg", "jpeg", "png", "webp", "tiff", "tif"]
        XCTAssertEqual(OCRViewModel.Mode.ocr.acceptedFileExtensions, web)
        XCTAssertEqual(OCRViewModel.Mode.translate.acceptedFileExtensions, web)
        XCTAssertEqual(OCRViewModel.Mode.pdfToWord.acceptedFileExtensions, ["pdf"])

        for name in ["Order.pdf", "Order.PDF", "Brief.docx", "Page.jpg", "Page.JPEG", "Page.png",
                     "Page.webp", "Page.tiff", "Page.tif", "W.P.(C) 1234-2024.pdf"] {
            XCTAssertTrue(OCRViewModel.Mode.ocr.accepts(fileName: name), name)
            XCTAssertTrue(OCRViewModel.Mode.translate.accepts(fileName: name), name)
        }
        for name in ["Photo.heic", "Old.doc", "Notes.txt", "Order", "pdf", "Order.pdf.zip", "Order."] {
            XCTAssertFalse(OCRViewModel.Mode.ocr.accepts(fileName: name), name)
        }
        XCTAssertTrue(OCRViewModel.Mode.pdfToWord.accepts(fileName: "Brief.pdf"))
        XCTAssertFalse(OCRViewModel.Mode.pdfToWord.accepts(fileName: "Page.jpg"))
        XCTAssertFalse(OCRViewModel.Mode.pdfToWord.accepts(fileName: "Brief.docx"))
    }

    func testAFileTheModeCannotReadIsRefusedBeforeItIsSent() async {
        await withModeModel(.ocr) { service, model in
            await model.submit(data: Data("x".utf8), fileName: "Photo.heic")
            XCTAssertTrue(service.submitted.isEmpty)
            XCTAssertEqual(model.errorMessage, OCRViewModel.Mode.ocr.unsupportedFileMessage)
            XCTAssertFalse(model.isRunning)
        }
        await withModeModel(.pdfToWord) { service, model in
            await model.submit(data: Data("x".utf8), fileName: "Page.jpg")
            XCTAssertTrue(service.submitted.isEmpty)
            XCTAssertEqual(model.errorMessage, OCRViewModel.Mode.pdfToWord.unsupportedFileMessage)
        }
    }

    /// The scanner's PDF and every type the picker offers go through.
    func testAnImageAndAScanAreSentInOCR() async {
        await withModeModel(.ocr) { service, model in
            service.job = startingJob()
            await model.submit(data: Data("x".utf8), fileName: "Page.png")
            XCTAssertEqual(service.submitted.first?.fileName, "Page.png")
            XCTAssertNil(model.errorMessage)
        }
        await withModeModel(.ocr) { service, model in
            service.job = startingJob()
            let scan = ScannedDocument.suggestedName(for: Date(timeIntervalSince1970: 1_789_365_600))
            await model.submit(data: Data("%PDF".utf8), fileName: scan)
            XCTAssertEqual(service.submitted.first?.fileName, scan)
        }
    }

    // MARK: - What OCR sends

    /// **OCR never translates.** Whatever the language control last held — Translate's choice
    /// survives a switch — the request says Original, which is the server's digitise-only value.
    func testOCRAlwaysSendsOriginal() async {
        await withModeModel(.ocr) { service, model in
            model.language = .tamil
            service.job = startingJob()
            await model.submit(data: Data("%PDF".utf8), fileName: "Order.pdf")
            XCTAssertEqual(service.submitted.first?.language, .original)
            XCTAssertEqual(model.effectiveLanguage, .original)
        }
    }

    func testAChoiceMadeInTranslateIsNotSentAfterSwitchingToOCR() async {
        await withModeModel(.translate) { service, model in
            model.language = .hindi
            model.switchMode(to: .ocr)
            service.job = startingJob()
            await model.submit(data: Data("%PDF".utf8), fileName: "Order.pdf")
            XCTAssertEqual(service.submitted.first?.language, .original)

            // And it is still there for whoever switches back.
            await finish(service, model)
            model.switchMode(to: .translate)
            XCTAssertEqual(model.language, .hindi)
            XCTAssertEqual(model.effectiveLanguage, .hindi)
        }
    }

    // MARK: - Switching

    /// As the web's tabs do (`OCRTranslate.jsx:636`): a finished document belongs to the mode
    /// that made it, so moving to the other one starts clean.
    func testSwitchingClearsAFinishedDocumentAndItsError() async {
        await withModeModel(.ocr) { service, model in
            service.job = completedJob(output: "1790000000000_Order.docx")
            await model.submit(data: Data("%PDF".utf8), fileName: "Order.pdf")
            await model.pollOnce()
            XCTAssertNotNil(model.result)
            model.errorMessage = "Something the last run said."

            XCTAssertTrue(model.canSwitchMode)
            model.switchMode(to: .translate)

            XCTAssertEqual(model.mode, .translate)
            XCTAssertNil(model.result)
            XCTAssertNil(model.job)
            XCTAssertNil(model.errorMessage)
            XCTAssertFalse(model.isRunning)
        }
    }

    /// Switching while a document is on its way would land its result on the other mode's
    /// screen, under the other mode's name.
    func testSwitchingIsRefusedWhileADocumentIsBeingRead() async {
        await withModeModel(.ocr) { service, model in
            service.job = startingJob()
            await model.submit(data: Data("%PDF".utf8), fileName: "Order.pdf")
            XCTAssertTrue(model.isRunning)
            XCTAssertFalse(model.canSwitchMode)

            model.switchMode(to: .translate)
            XCTAssertEqual(model.mode, .ocr)

            await model.pollOnce()
            XCTAssertNotNil(model.job, "the job being read was not dropped")
            XCTAssertTrue(model.isRunning)
        }
    }

    /// A stalled job that was given up on no longer holds the screen, so the switch frees up
    /// with the pickers.
    func testAJobGivenUpOnFreesTheSwitch() async {
        let clock = MutableClock(start: Date(timeIntervalSince1970: 1_789_365_600))
        await withModeModel(.ocr, clock: clock) { service, model in
            service.job = startingJob()
            await model.submit(data: Data("%PDF".utf8), fileName: "Order.pdf")
            await model.pollOnce()
            clock.advance(by: OCRViewModel.stallTimeout + 10)
            await model.pollOnce()

            XCTAssertTrue(model.canSwitchMode)
            model.switchMode(to: .translate)
            XCTAssertEqual(model.mode, .translate)
            XCTAssertNil(model.errorMessage, "the stall belonged to the OCR run")
        }
    }

    func testChoosingTheModeAlreadyShownChangesNothing() async {
        await withModeModel(.ocr) { service, model in
            service.job = completedJob(output: "1790000000000_Order.docx")
            await model.submit(data: Data("%PDF".utf8), fileName: "Order.pdf")
            await model.pollOnce()
            model.switchMode(to: .ocr)
            XCTAssertNotNil(model.result, "re-selecting the current tab is not a reset")
        }
    }

    /// PDF to Word is its own tool, locked as the web's `/tools/pdf-to-docx` page is — and
    /// neither OCR nor Translate can be switched into it.
    func testPDFToWordIsLockedAndCannotBeSwitchedInto() async {
        await withModeModel(.pdfToWord) { _, model in
            XCTAssertFalse(model.canSwitchMode)
            model.switchMode(to: .ocr)
            XCTAssertEqual(model.mode, .pdfToWord)
        }
        await withModeModel(.ocr) { _, model in
            model.switchMode(to: .pdfToWord)
            XCTAssertEqual(model.mode, .ocr)
        }
    }

    // MARK: - Naming the result

    /// The web's name for an OCR result (`OCRTranslate.jsx:593-595`), from the job's own record
    /// of the source — not the server's, which for a Word document put through OCR is the very
    /// name it went in with.
    func testAnOCRResultIsNamedAsTheWebNamesIt() async {
        await withModeModel(.ocr) { service, model in
            var finished = completedJob(output: "1790000000000_Bakshi_Order.docx")
            finished.fileName = "Bakshi_Order.docx"
            service.job = finished
            await model.submit(data: Data("PK".utf8), fileName: "Bakshi Order.docx")
            await model.pollOnce()
            XCTAssertEqual(model.result?.fileName, "Bakshi_Order_ocr.docx")
            XCTAssertEqual(service.downloaded, ["1790000000000_Bakshi_Order.docx"],
                           "the stored name is still the one asked for")
        }
    }

    /// A job's record can lose its `fileName` (see `OCRJob`); the name it was sent under stands in.
    func testAnOCRResultWhoseRecordLostItsNameIsNamedFromTheUpload() async {
        await withModeModel(.ocr) { service, model in
            var finished = completedJob(output: "1790000000000_Order.docx")
            finished.fileName = nil
            service.job = finished
            await model.submit(data: Data("%PDF".utf8), fileName: "Order.pdf")
            await model.pollOnce()
            XCTAssertEqual(model.result?.fileName, "Order_ocr.docx")
        }
    }

    /// Translate keeps the server's name, which carries the language.
    func testATranslatedResultKeepsTheServersName() async {
        await withModeModel(.translate) { service, model in
            model.language = .hindi
            var finished = completedJob(output: "1790000000000_Order_Hindi.docx")
            finished.targetLang = "Hindi"
            service.job = finished
            await model.submit(data: Data("%PDF".utf8), fileName: "Order.pdf")
            await model.pollOnce()
            XCTAssertEqual(model.result?.fileName, "Order_Hindi.docx")
        }
    }

    func testTheOCRNameDropsOnlyARealExtension() {
        let ocr = OCRViewModel.Mode.ocr
        XCTAssertEqual(ocr.resultFileName(source: "Order.pdf"), "Order_ocr.docx")
        XCTAssertEqual(ocr.resultFileName(source: "Scan.PDF"), "Scan_ocr.docx")
        XCTAssertEqual(ocr.resultFileName(source: "a.b.tiff"), "a.b_ocr.docx")
        XCTAssertEqual(ocr.resultFileName(source: "Order"), "Order_ocr.docx")
        XCTAssertEqual(
            ocr.resultFileName(source: "W.P.(C) 1234-2024"), "W.P.(C) 1234-2024_ocr.docx",
            "a dot inside a court reference is not an extension")
        XCTAssertEqual(ocr.resultFileName(source: ".pdf"), "document_ocr.docx")
        XCTAssertEqual(ocr.resultFileName(source: ""), "document_ocr.docx")
        XCTAssertNil(OCRViewModel.Mode.translate.resultFileName(source: "Order.pdf"))
        XCTAssertNil(OCRViewModel.Mode.pdfToWord.resultFileName(source: "Order.pdf"))
    }

    // MARK: - Wording

    func testEachModeSpeaksForItself() {
        XCTAssertEqual(OCRViewModel.Mode.ocr.againTitle, "Digitise another")
        XCTAssertEqual(OCRViewModel.Mode.translate.againTitle, "Translate another")
        XCTAssertEqual(OCRViewModel.Mode.pdfToWord.againTitle, "Convert another")
        XCTAssertEqual(OCRViewModel.Mode.ocr.failureTitle, "Could not digitise")
        XCTAssertEqual(OCRViewModel.Mode.translate.failureTitle, "Could not translate")
        XCTAssertEqual(OCRViewModel.Mode.pdfToWord.failureTitle, "Could not convert")
    }
}

// MARK: - Helpers

private func startingJob() -> OCRJob {
    OCRJob(
        id: "1790000000000", status: "starting", step: 1, progress: 5, fileName: "Order.pdf",
        targetLang: "Original", pageSetup: nil, logs: [], error: nil, outputFile: nil,
        ownerID: "42")
}

private func completedJob(output: String) -> OCRJob {
    OCRJob(
        id: "1790000000000", status: "completed", step: 5, progress: 100, fileName: "Order.pdf",
        targetLang: "Original", pageSetup: nil, logs: [], error: nil, outputFile: output,
        ownerID: "42")
}

/// Takes a running job to completion, so the screen is free to switch.
@MainActor
private func finish(_ service: FakeOCR, _ model: OCRViewModel) async {
    service.job = completedJob(output: "1790000000000_Order.docx")
    await model.pollOnce()
}

@MainActor
private func withModeModel(
    _ mode: OCRViewModel.Mode,
    clock: MutableClock = MutableClock(start: Date(timeIntervalSince1970: 1_789_365_600)),
    _ body: @MainActor (FakeOCR, OCRViewModel) async -> Void
) async {
    let service = FakeOCR()
    let model = OCRViewModel(service: service, mode: mode, now: { clock.now })
    await body(service, model)
    model.cancelPolling()
}
