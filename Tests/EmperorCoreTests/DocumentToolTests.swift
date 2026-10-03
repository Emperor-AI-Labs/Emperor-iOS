import XCTest
@testable import EmperorCore

/// The tool hub, and the four new tools' view models, driven with a fake engine.
final class DocumentToolTests: XCTestCase {

    // MARK: - The hub

    /// The web's line, kept: PDF to Word is processed on the server and says so; every other
    /// tool runs on the device and never reaches the network (`ToolsHub.jsx:47`).
    func testOnlyPDFToWordLeavesThePhone() {
        XCTAssertEqual(DocumentTool.allCases.filter { !$0.isOnDevice }, [.pdfToWord])
    }

    func testTheHubListsEveryToolExactlyOnce() {
        let listed = DocumentTool.documentTools + DocumentTool.imageTools
        XCTAssertEqual(Set(listed), Set(DocumentTool.allCases))
        XCTAssertEqual(listed.count, DocumentTool.allCases.count)
        XCTAssertEqual(DocumentTool.imageTools, [.compressImage],
                       "the web keeps Compress Image apart from the document jobs")
    }

    func testEveryToolHasANameASummaryAndAnIcon() {
        for tool in DocumentTool.allCases {
            XCTAssertFalse(tool.title.isEmpty)
            XCTAssertFalse(tool.summary.isEmpty)
            XCTAssertFalse(tool.symbol.isEmpty)
            XCTAssertFalse(tool.summary.lowercased().contains("browser"), "there is no browser here")
        }
    }

    // MARK: - File names

    func testFileNamesFollowTheWebsRules() {
        XCTAssertEqual(ToolFileName.removingExtension("Order.final.jpg"), "Order.final")
        XCTAssertEqual(ToolFileName.removingExtension("noextension"), "noextension")
        XCTAssertEqual(ToolFileName.removingExtension("trailing."), "trailing.")
        XCTAssertEqual(ToolFileName.removingPDFExtension("Brief.PDF"), "Brief")
        XCTAssertEqual(ToolFileName.removingPDFExtension("Brief.docx"), "Brief.docx")
        XCTAssertEqual(ImageCompression.outputName(for: "Exhibit P-3.png"), "Exhibit P-3_compressed.jpg")
        XCTAssertEqual(PDFCompression.outputName(for: "Paperbook.pdf"), "Paperbook_compressed.pdf")
        XCTAssertEqual(ImagePDFLayout.outputName(firstImageName: "IMG_0412.HEIC"), "IMG_0412_images.pdf")
        XCTAssertEqual(ImagePDFLayout.outputName(firstImageName: nil), "images.pdf")
    }

    // MARK: - Compress image arithmetic

    func testPercentSmallerRoundsHalfUpAndNeverGoesNegative() {
        XCTAssertEqual(ImageCompression.percentSmaller(original: 1000, compressed: 125), 88) // 87.5
        XCTAssertEqual(ImageCompression.percentSmaller(original: 1000, compressed: 1200), 0)
        XCTAssertEqual(ImageCompression.percentSmaller(original: 0, compressed: 10), 0)
    }

    func testTheTargetMustBeAPositiveWholeNumberOfKB() {
        XCTAssertEqual(ImageCompression.targetBytes(kilobytes: "100"), 102_400)
        XCTAssertEqual(ImageCompression.targetBytes(kilobytes: " 50 "), 51_200)
        XCTAssertNil(ImageCompression.targetBytes(kilobytes: "0"))
        XCTAssertNil(ImageCompression.targetBytes(kilobytes: "-5"))
        XCTAssertNil(ImageCompression.targetBytes(kilobytes: "abc"))
        XCTAssertNil(ImageCompression.targetBytes(kilobytes: ""))
    }

    /// A target nothing can reach still yields the smallest attempt, marked as a miss — refusing
    /// to produce anything is less useful than an honest result.
    func testAnUnreachableTargetReturnsTheSmallestAttemptMarkedAsAMiss() throws {
        let result = try ImageCompression.search(width: 1000, height: 1000, targetBytes: 10) { w, h, _ in
            Data(count: w * h)
        }
        XCTAssertFalse(result.hitTarget)
        XCTAssertLessThan(result.width, 1000)
    }

    func testAnEncoderThatFailsIsAnErrorNotAnEmptyImage() {
        XCTAssertThrowsError(
            try ImageCompression.search(width: 10, height: 10, targetBytes: 100) { _, _, _ in nil })
    }

    // MARK: - Compress PDF decisions

    /// A typed page with a logo is not a scan; a full page at 150 dpi is.
    func testOnlyImageBackedPagesAreCandidates() {
        let a4 = (width: 595.28, height: 841.89)
        XCTAssertNil(PDFCompression.nativeSize(pageWidth: a4.width, pageHeight: a4.height, imagePixels: 0))
        XCTAssertNil(
            PDFCompression.nativeSize(pageWidth: a4.width, pageHeight: a4.height, imagePixels: 600 * 200),
            "a letterhead logo does not make a page a scan")
        let scan = PDFCompression.nativeSize(
            pageWidth: a4.width, pageHeight: a4.height, imagePixels: 1240 * 1754)
        XCTAssertNotNil(scan)
        XCTAssertEqual(Double(scan!.height), 1754, accuracy: 2, "the page at its images' own density")
    }

    /// The level's limit is applied the web's way — and a low-resolution scan is never blown up.
    func testTheRasterNeverExceedsTheLevelOrTheSource() {
        let balanced = PDFCompression.defaultLevel
        let big = PDFCompression.rasterSize(
            pageWidth: 595.28, pageHeight: 841.89, imagePixels: 2480 * 3508, level: balanced)
        XCTAssertEqual(big.map { max($0.width, $0.height) }, 1680)

        let small = PDFCompression.rasterSize(
            pageWidth: 595.28, pageHeight: 841.89, imagePixels: 600 * 849, level: balanced)
        XCTAssertNotNil(small)
        XCTAssertLessThanOrEqual(max(small!.width, small!.height), 850, "not scaled up to 1680")
    }

    func testTheThreePercentRuleIsStrict() {
        XCTAssertFalse(PDFCompression.worthReplacing(originalBytes: 10_000, candidateBytes: 9_700))
        XCTAssertTrue(PDFCompression.worthReplacing(originalBytes: 10_000, candidateBytes: 9_699))
        XCTAssertFalse(PDFCompression.worthReplacing(originalBytes: 10_000, candidateBytes: 12_000))
    }

    func testTheOutcomeSaysWhatHappened() {
        let shrunk = PDFCompression.Outcome(
            originalBytes: 10_000_000, compressedBytes: 2_500_000, pageCount: 40, pagesReencoded: 12)
        XCTAssertEqual(shrunk.savedPercent, 75)
        XCTAssertTrue(shrunk.hasReduction)
        XCTAssertTrue(shrunk.isMeaningful)
        XCTAssertEqual(shrunk.headline, "75% smaller")
        XCTAssertTrue(shrunk.detail.contains("12 scanned or photographed pages"))
        XCTAssertTrue(shrunk.detail.contains("the other 28 pages are unchanged"))

        let same = PDFCompression.Outcome(
            originalBytes: 10_000, compressedBytes: 9_900, pageCount: 3, pagesReencoded: 0)
        XCTAssertTrue(same.hasReduction)
        XCTAssertFalse(same.isMeaningful, "1% is under the web's 2% line")
        XCTAssertTrue(same.detail.hasPrefix("No meaningful reduction"))

        let grew = PDFCompression.Outcome(
            originalBytes: 10_000, compressedBytes: 11_000, pageCount: 3, pagesReencoded: 1)
        XCTAssertFalse(grew.hasReduction)
        XCTAssertEqual(grew.savedBytes, 0)
        XCTAssertEqual(grew.headline, "No reduction")
    }

    // MARK: - Image to PDF embedding

    func testPhotographsStayCompactAndGraphicsStayLossless() {
        XCTAssertEqual(ImagePDFLayout.embedding(forFileName: "a.JPG", isUpright: true), .originalJPEG)
        XCTAssertEqual(ImagePDFLayout.embedding(forFileName: "a.jpeg", isUpright: false), .jpeg,
                       "a rotated JPEG is redrawn upright, not passed through on its side")
        XCTAssertEqual(ImagePDFLayout.embedding(forFileName: "IMG_1.HEIC", isUpright: true), .jpeg)
        XCTAssertEqual(ImagePDFLayout.embedding(forFileName: "seal.png", isUpright: true), .lossless)
        XCTAssertEqual(ImagePDFLayout.embedding(forFileName: "scan.webp", isUpright: true), .lossless)
    }

    /// A library item is named by what its bytes are, so HEIC is never passed through as JPEG.
    func testImageBytesAreNamedByTheirSignature() {
        func data(_ bytes: [UInt8]) -> Data { Data(bytes + Array(repeating: 0, count: 8)) }
        XCTAssertEqual(ImagePDFLayout.sniffedExtension(data([0xFF, 0xD8, 0xFF, 0xE0])), "jpg")
        XCTAssertEqual(ImagePDFLayout.sniffedExtension(data([0x89, 0x50, 0x4E, 0x47])), "png")
        XCTAssertEqual(ImagePDFLayout.sniffedExtension(Data("GIF89a".utf8)), "gif")
        XCTAssertEqual(ImagePDFLayout.sniffedExtension(Data("RIFF\0\0\0\0WEBPVP8 ".utf8)), "webp")
        XCTAssertEqual(ImagePDFLayout.sniffedExtension(Data("\0\0\0\u{18}ftypheic".utf8)), "heic")
        XCTAssertEqual(ImagePDFLayout.sniffedExtension(Data("\0\0\0\u{18}ftypmp42".utf8)), nil,
                       "a video is not an image")
        XCTAssertNil(ImagePDFLayout.sniffedExtension(Data()))
        XCTAssertNil(ImagePDFLayout.sniffedExtension(Data("%PDF-1.7".utf8)))
    }

    func testAPhoneCameraPhotoIsAccepted() {
        XCTAssertTrue(ImagePDFLayout.isAccepted(fileName: "IMG_0412.HEIC"))
        XCTAssertTrue(ImagePDFLayout.isAccepted(fileName: "scan.png"))
        XCTAssertFalse(ImagePDFLayout.isAccepted(fileName: "brief.pdf"))
    }

    func testASmallImageIsScaledUpToFillThePageAsOnTheWeb() {
        let placement = ImagePDFLayout.placement(imageWidth: 100, imageHeight: 100, on: .a4)
        XCTAssertEqual(placement.width, 595.28 - 80, accuracy: 0.0001)
        XCTAssertEqual(placement.topLeftY(pageHeight: 841.89), placement.y, accuracy: 0.0001)
    }

    // MARK: - Rearrange

    func testRearrangeStartsFromTheDocumentAsItIs() async {
        await withRearrange { engine, model in
            model.load(sample("Brief.pdf"), pageCount: 6)
            XCTAssertEqual(model.spec, "1-6")
            XCTAssertEqual(model.parsed.pages, [1, 2, 3, 4, 5, 6])
            XCTAssertEqual(model.countLine, "6 pages out")
            XCTAssertNil(model.droppedNotice)
            XCTAssertTrue(model.canRun)
        }
    }

    /// The chips rewrite the instruction — there is no second copy of the order to drift.
    func testEditingThePreviewRewritesTheInstruction() async {
        await withRearrange { _, model in
            model.load(sample("Brief.pdf"), pageCount: 5)
            model.move(from: 4, to: 0)
            XCTAssertEqual(model.spec, "5, 1-4")
            model.duplicate(at: 0)
            XCTAssertEqual(model.spec, "5x2, 1-4")
            XCTAssertEqual(model.countLine, "6 pages out · 1 repeated")
            model.remove(at: 2)
            XCTAssertEqual(model.parsed.pages, [5, 5, 2, 3, 4])
            XCTAssertEqual(model.droppedNotice, "Page 1 will not appear in the result.")
            model.appendDropped()
            XCTAssertEqual(model.parsed.pages, [5, 5, 2, 3, 4, 1])
            model.resetOrder()
            XCTAssertEqual(model.spec, "1-5")
        }
    }

    func testMovesOutOfRangeOrOntoThemselvesDoNothing() async {
        await withRearrange { _, model in
            model.load(sample("Brief.pdf"), pageCount: 3)
            model.move(from: 0, to: -1)
            model.move(from: 2, to: 3)
            model.move(from: 1, to: 1)
            model.remove(at: 9)
            model.duplicate(at: -1)
            XCTAssertEqual(model.spec, "1-3")
        }
    }

    func testAnExampleFillsForThisDocument() async {
        await withRearrange { _, model in
            model.load(sample("Brief.pdf"), pageCount: 7)
            model.apply(PageOrder.examples[0])
            XCTAssertEqual(model.spec, "last, 1-6")
            XCTAssertEqual(model.parsed.pages, [7, 1, 2, 3, 4, 5, 6])
        }
    }

    /// The engine is handed the order exactly — duplicates and direction included.
    func testRunningSendsTheExactOrderAndNamesTheResult() async {
        await withRearrange { engine, model in
            model.load(sample("Paperbook.PDF"), pageCount: 10)
            model.spec = "9-7, 1x2"
            await model.run()
            XCTAssertEqual(engine.rearranged.first?.pages, [9, 8, 7, 1, 1])
            XCTAssertEqual(engine.rearranged.first?.name, "Paperbook_rearranged.pdf")
            XCTAssertEqual(model.state, .finished)
            XCTAssertEqual(model.output?.name, "Paperbook_rearranged.pdf")
            XCTAssertTrue(model.resultMessage?.hasPrefix("Rearranged into 5 pages") == true)
        }
    }

    /// A result must never sit beside an instruction that would build something else.
    func testEditingTheInstructionWithdrawsTheStaleResult() async {
        await withRearrange { _, model in
            model.load(sample("Brief.pdf"), pageCount: 4)
            await model.run()
            XCTAssertNotNil(model.output)
            model.spec = "4-1"
            XCTAssertNil(model.output)
            model.spec = "1-4"
            XCTAssertNotNil(model.output, "back to what was built, the file is still that file")
        }
    }

    func testNothingToBuildCannotRun() async {
        await withRearrange { engine, model in
            model.load(sample("Brief.pdf"), pageCount: 4)
            model.spec = "banana"
            XCTAssertFalse(model.canRun)
            await model.run()
            XCTAssertTrue(engine.rearranged.isEmpty)
        }
    }

    func testAnEngineFailureIsShownNotSwallowed() async {
        await withRearrange { engine, model in
            engine.error = APIError.transport("disk full")
            model.load(sample("Brief.pdf"), pageCount: 4)
            await model.run()
            XCTAssertEqual(model.state.failureMessage, "disk full")
            XCTAssertNil(model.output)
        }
    }

    // MARK: - Compress PDF

    func testCompressMeasuresAgainstTheFileItselfAndOffersOnlyARealReduction() async {
        await withCompressPDF { engine, model in
            model.load(sample("Bundle.pdf", bytes: 10_000), pageCount: 3)
            engine.compressResult = PDFCompression.Result(
                outcome: .init(originalBytes: 0, compressedBytes: 0, pageCount: 3, pagesReencoded: 2),
                data: Data(count: 4_000))
            engine.progressSteps = [0.3, 0.6, 1]
            await model.run()

            XCTAssertEqual(engine.compressedLevels, [PDFCompression.defaultLevel])
            XCTAssertEqual(model.currentOutcome?.originalBytes, 10_000)
            XCTAssertEqual(model.currentOutcome?.savedPercent, 60)
            XCTAssertEqual(model.currentOutput?.name, "Bundle_compressed.pdf")
            XCTAssertEqual(model.progress, 1)
            XCTAssertEqual(model.state, .finished)
        }
    }

    /// The web shows no download when nothing was saved. Offering a larger file as "compressed"
    /// would be the one dishonest thing this tool could do.
    func testALargerResultIsNotOffered() async {
        await withCompressPDF { engine, model in
            model.load(sample("Typed.pdf", bytes: 10_000), pageCount: 3)
            engine.compressResult = PDFCompression.Result(
                outcome: .init(originalBytes: 0, compressedBytes: 0, pageCount: 3, pagesReencoded: 0),
                data: Data(count: 10_400))
            await model.run()
            XCTAssertNil(model.currentOutput)
            XCTAssertEqual(model.currentOutcome?.headline, "No reduction")
        }
    }

    func testChangingTheLevelWithdrawsTheResultMadeAtTheOldOne() async {
        await withCompressPDF { engine, model in
            model.load(sample("Bundle.pdf", bytes: 10_000), pageCount: 3)
            engine.compressResult = PDFCompression.Result(
                outcome: .init(originalBytes: 0, compressedBytes: 0, pageCount: 3, pagesReencoded: 3),
                data: Data(count: 3_000))
            await model.run()
            XCTAssertNotNil(model.currentOutput)
            model.level = PDFCompression.levels[0]
            XCTAssertNil(model.currentOutput)
            XCTAssertNil(model.currentOutcome)
        }
    }

    // MARK: - Compress image

    func testAnImageOverTheLimitIsRefusedBeforeAnythingRuns() async {
        await withCompressImage { _, model in
            model.load(sample("Huge.png", bytes: ImageCompression.maxSourceBytes + 1))
            XCTAssertNil(model.source)
            XCTAssertNotNil(model.notice)
        }
    }

    func testCompressImageSendsTheTargetInKibibytes() async {
        await withCompressImage { engine, model in
            model.load(sample("Exhibit.png", bytes: 1_000_000))
            model.choosePreset(200)
            await model.run()
            XCTAssertEqual(engine.imageTargets, [204_800])
            XCTAssertEqual(model.output?.name, "Exhibit_compressed.jpg")
            XCTAssertEqual(model.resultCaption, "91% smaller")
        }
    }

    func testAMissedTargetIsSaidOutLoud() async {
        await withCompressImage { engine, model in
            engine.imageReport = ImageCompression.Report(
                originalWidth: 100, originalHeight: 100,
                result: .init(data: Data(count: 500), width: 30, height: 30, quality: 0.05, hitTarget: false))
            model.load(sample("Exhibit.png", bytes: 1_000))
            await model.run()
            XCTAssertTrue(model.resultCaption?.contains("smallest this image could reach") == true)
        }
    }

    func testANonsenseTargetIsRefusedWithoutRunning() async {
        await withCompressImage { engine, model in
            model.load(sample("Exhibit.png", bytes: 1_000))
            model.targetKB = "lots"
            await model.run()
            XCTAssertTrue(engine.imageTargets.isEmpty)
            XCTAssertEqual(model.notice, "Enter a target size in KB.")
        }
    }

    // MARK: - Image to PDF

    func testImagesKeepTheUsersOrderAndOnlyImagesAreTaken() async {
        await withImageToPDF { engine, model in
            let first = sample("IMG_2.HEIC"), second = sample("IMG_1.jpg")
            let skipped = model.add([first, sample("notes.pdf"), second])
            XCTAssertEqual(skipped, 1)
            XCTAssertEqual(model.images.map(\.name), ["IMG_2.HEIC", "IMG_1.jpg"], "never sorted")
            model.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)
            XCTAssertEqual(model.images.map(\.name), ["IMG_1.jpg", "IMG_2.HEIC"])
            XCTAssertEqual(model.outputName, "IMG_1_images.pdf")

            model.pageSize = .legal
            await model.run()
            XCTAssertEqual(engine.imageBatches.first?.urls, [second.url, first.url])
            XCTAssertEqual(engine.imageBatches.first?.size, .legal)
            XCTAssertNotNil(model.output)

            model.pageSize = .a4
            XCTAssertNil(model.output, "a PDF built on Legal is not the A4 one now asked for")
        }
    }

    func testMovingLaterImagesEarlierKeepsEveryImage() async {
        await withImageToPDF { _, model in
            model.add(["a.jpg", "b.jpg", "c.jpg", "d.jpg"].map { sample($0) })
            model.move(fromOffsets: IndexSet([0, 2]), toOffset: 4)
            XCTAssertEqual(model.images.map(\.name), ["b.jpg", "d.jpg", "a.jpg", "c.jpg"])
            model.remove(model.images[0].id)
            XCTAssertEqual(model.images.map(\.name), ["d.jpg", "a.jpg", "c.jpg"])
        }
    }
}

// MARK: - Helpers

private func sample(_ name: String, bytes: Int = 1_000) -> PickedFile {
    PickedFile(url: URL(fileURLWithPath: "/tmp/\(name)"), name: name, bytes: bytes)
}

@MainActor
private func withRearrange(
    _ body: @MainActor (FakeDocumentToolEngine, RearrangeViewModel) async -> Void
) async {
    let engine = FakeDocumentToolEngine()
    await body(engine, RearrangeViewModel(engine: engine))
}

@MainActor
private func withCompressPDF(
    _ body: @MainActor (FakeDocumentToolEngine, CompressPDFViewModel) async -> Void
) async {
    let engine = FakeDocumentToolEngine()
    await body(engine, CompressPDFViewModel(engine: engine))
}

@MainActor
private func withCompressImage(
    _ body: @MainActor (FakeDocumentToolEngine, CompressImageViewModel) async -> Void
) async {
    let engine = FakeDocumentToolEngine()
    await body(engine, CompressImageViewModel(engine: engine))
}

@MainActor
private func withImageToPDF(
    _ body: @MainActor (FakeDocumentToolEngine, ImageToPDFViewModel) async -> Void
) async {
    let engine = FakeDocumentToolEngine()
    await body(engine, ImageToPDFViewModel(engine: engine))
}
