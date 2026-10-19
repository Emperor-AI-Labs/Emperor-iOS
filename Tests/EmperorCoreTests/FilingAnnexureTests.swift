import XCTest
@testable import EmperorCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - A stand-in registry

/// Answers every filing read from tables set by the test. Unset reads fail loudly, so a test
/// that reaches a route it did not expect says so.
final class FakeFiling: FilingAnnexureProviding, @unchecked Sendable {
    private let lock = NSLock()
    var list: Result<[FilingAnnexure], Error> = .success([])
    var originals: [String: Result<Data, Error>] = [:]
    var typed: [String: Result<TypedCopy, Error>] = [:]
    var pages: [String: Result<OriginalPages, Error>] = [:]
    private(set) var calls: [String] = []

    private func note(_ call: String) { lock.withLock { calls.append(call) } }

    func annexures(chatID: String) async throws -> [FilingAnnexure] {
        note("list:\(chatID)")
        return try list.get()
    }

    func original(chatID: String, mark: String) async throws -> Data {
        note("original:\(mark)")
        guard let result = originals[mark] else { throw APIError.server(status: 500, message: "unexpected") }
        return try result.get()
    }

    func typedCopy(chatID: String, mark: String) async throws -> TypedCopy {
        note("typed:\(mark)")
        guard let result = typed[mark] else { throw APIError.server(status: 500, message: "unexpected") }
        return try result.get()
    }

    func typedCopies(chatID: String) async throws -> TypedCopies {
        note("typedCopies")
        return TypedCopies(html: "", marks: [])
    }

    func originalPages(chatID: String, mark: String) async throws -> OriginalPages {
        note("pages:\(mark)")
        guard let result = pages[mark] else { throw APIError.server(status: 500, message: "unexpected") }
        return try result.get()
    }
}

private enum Sample {
    static let pdf = Data("%PDF-1.7\n1 0 obj\n".utf8)
    /// A 1×1 PNG: the signature and an IHDR, which is all `EmbeddedImage` reads.
    static let png: Data = {
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
                              0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52,
                              0, 0, 0, 1, 0, 0, 0, 1, 8, 2, 0, 0, 0]
        bytes += [UInt8](repeating: 0, count: 8)
        return Data(bytes)
    }()

    static let planRefusal = Refusal(
        code: .featureNotInPlan, status: 402,
        serverMessage: "Filing Ready is part of the paid plans. Upgrade to use it.")

    static func row(_ mark: String, _ treatment: FilingAnnexure.Treatment = .original,
                    sort: Int = 0, duplicateOf: String? = nil) -> FilingAnnexure {
        FilingAnnexure(id: mark, mark: mark, title: "Document \(mark)", treatment: treatment,
                       sortOrder: sort, duplicateOf: duplicateOf)
    }
}

// MARK: - The row

final class FilingAnnexureModelTests: XCTestCase {

    func testARegistryRowDecodesFromTheWire() throws {
        let json = #"""
        {"id":7,"user_id":"42","chat_id":"c1","mark":"P-2","title":"Order dated 3.4.2024",
         "source_file_path":"x","treatment":"typed","sort_order":2,"verify_status":"pending",
         "page_from":3,"page_to":5,"duplicate_of":"P-1"}
        """#
        let row = try JSONDecoder().decode(FilingAnnexure.self, from: Data(json.utf8))
        XCTAssertEqual(row.id, "7")
        XCTAssertEqual(row.mark, "P-2")
        XCTAssertEqual(row.treatment, .typed)
        XCTAssertEqual(row.sortOrder, 2)
        XCTAssertEqual(row.verifyStatus, "pending")
        XCTAssertEqual(row.pageLabel, "Pages 3–5")
        XCTAssertEqual(row.duplicateOf, "P-1")
        XCTAssertEqual(row.formLabel, "Typed copy")
    }

    /// The web reads anything other than `typed` as an original; so does this.
    func testAnUnknownTreatmentIsAnOriginal() throws {
        let json = #"{"id":"a","mark":"R-1","title":"Notice","treatment":"something-new","sort_order":null}"#
        let row = try JSONDecoder().decode(FilingAnnexure.self, from: Data(json.utf8))
        XCTAssertEqual(row.treatment, .original)
        XCTAssertEqual(row.sortOrder, 0)
        XCTAssertNil(row.pageLabel)
    }

    func testRowsSortBySortOrderThenMarkNumerically() {
        let rows = [Sample.row("P-10", sort: 1), Sample.row("R-1", sort: 1), Sample.row("P-2", sort: 1),
                    Sample.row("P-9", sort: 0)]
        XCTAssertEqual(FilingAnnexure.sorted(rows).map(\.mark), ["P-9", "P-2", "P-10", "R-1"])
    }
}

// MARK: - On the wire

final class FilingAnnexureWireTests: XCTestCase {

    private static let config = APIConfig(baseURL: URL(string: "https://example.test/api")!)

    override func setUp() {
        super.setUp()
        HTTPStub.reset()
    }

    override func tearDown() {
        HTTPStub.reset()
        super.tearDown()
    }

    private func makeService() async -> FilingAnnexureService {
        let client = APIClient(config: Self.config, session: HTTPStub.session())
        await client.setCredentials(Credentials(token: "tok-abc", userID: 42))
        return FilingAnnexureService(client: client)
    }

    func testTheListAsksByChatAndSortsTheRows() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"""
        {"success":true,"annexures":[
          {"id":2,"mark":"P-2","title":"B","treatment":"append","sort_order":2},
          {"id":1,"mark":"P-1","title":"A","treatment":"typed","sort_order":1}]}
        """#))

        let rows = try await service.annexures(chatID: "chat-9")

        XCTAssertEqual(rows.map(\.mark), ["P-1", "P-2"])
        let sent = try XCTUnwrap(HTTPStub.lastRequest)
        XCTAssertEqual(sent.path, "/api/filing/annexures")
        XCTAssertEqual(sent.queryItems["chatId"], "chat-9")
        XCTAssertEqual(sent.queryItems["userId"], "42")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer tok-abc")
    }

    /// The Free plan is refused Filing Ready with a coded 402. It must arrive as a refusal the
    /// app words itself — not a crash, and not "status 402".
    func testAFreePlanRefusalArrivesAsARefusal() async {
        let service = await makeService()
        HTTPStub.always(.json(
            #"{"error":"Filing Ready is part of the paid plans. Upgrade to use it.","code":"FEATURE_NOT_IN_PLAN"}"#,
            status: 402))

        do {
            _ = try await service.annexures(chatID: "c")
            XCTFail("expected a refusal")
        } catch let error as FilingAnnexureError {
            XCTAssertEqual(error.refusal?.code, .featureNotInPlan)
            XCTAssertFalse(error.localizedDescription.contains("Upgrade"))
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testAnOriginalIsReturnedAsBytesAndAsksByMark() async throws {
        let service = await makeService()
        HTTPStub.always(HTTPStub.Reply(status: 200, body: Sample.pdf, headers: ["Content-Type": "application/pdf"]))

        let data = try await service.original(chatID: "c1", mark: "P-3")

        XCTAssertEqual(data, Sample.pdf)
        let sent = try XCTUnwrap(HTTPStub.lastRequest)
        XCTAssertEqual(sent.path, "/api/filing/annexures/original")
        XCTAssertEqual(sent.queryItems["mark"], "P-3")
        XCTAssertEqual(sent.queryItems["chatId"], "c1")
    }

    func testAMissingOriginalIsWordedForThePerson() async {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":false,"error":"source file missing on disk"}"#, status: 404))

        do {
            _ = try await service.original(chatID: "c1", mark: "P-3")
            XCTFail("expected an error")
        } catch {
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("Annexure P-3"), text)
            XCTAssertFalse(text.contains("on disk"), "a log sentence reached the screen: \(text)")
        }
    }

    func testAnOriginalOfAKindThatCannotBeShownIsSaidSo() async {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":false,"error":"preview not available for .xlsx"}"#, status: 415))

        do {
            _ = try await service.original(chatID: "c1", mark: "R-1")
            XCTFail("expected an error")
        } catch let error as FilingAnnexureError {
            XCTAssertEqual(error, .unsupportedFile(mark: "R-1"))
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testARefusedOriginalIsARefusal() async {
        let service = await makeService()
        HTTPStub.always(.json(#"{"error":"x","code":"FEATURE_NOT_IN_PLAN"}"#, status: 402))

        do {
            _ = try await service.original(chatID: "c1", mark: "P-1")
            XCTFail("expected a refusal")
        } catch let error as FilingAnnexureError {
            XCTAssertEqual(error.refusal?.code, .featureNotInPlan)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testATypedCopyAndASkippedOne() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":true,"html":"<p>TRUE TYPED COPY</p>","mark":"P-1"}"#))
        let copy = try await service.typedCopy(chatID: "c", mark: "P-1")
        XCTAssertEqual(copy, .html("<p>TRUE TYPED COPY</p>"))
        XCTAssertEqual(HTTPStub.lastRequest?.path, "/api/filing/annexures/typed-copy")

        HTTPStub.always(.json(#"{"success":true,"skipped":true,"reason":"Annexure P-2 is an original document."}"#))
        let skipped = try await service.typedCopy(chatID: "c", mark: "P-2")
        XCTAssertEqual(skipped, .skipped(reason: "Annexure P-2 is an original document."))
    }

    /// The registry's own refusals are written for a person, and are shown.
    func testARegistrySentenceIsKept() async {
        let service = await makeService()
        HTTPStub.always(.json(
            #"{"success":false,"error":"no typed-copy text available for Annexure P-4 — the source document has not been OCR'd"}"#,
            status: 400))

        do {
            _ = try await service.typedCopy(chatID: "c", mark: "P-4")
            XCTFail("expected an error")
        } catch let error as FilingAnnexureError {
            guard case .declined(let mark, let message) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(mark, "P-4")
            XCTAssertTrue(message.hasPrefix("No typed-copy text available for Annexure P-4"), message)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testOriginalPagesDecodeAndADuplicateIsNamed() async throws {
        let service = await makeService()
        let encoded = Sample.png.base64EncodedString()
        HTTPStub.always(.json(#"{"success":true,"pages":[{"base64":"\#(encoded)","mime":"image/jpeg"}]}"#))
        let pages = try await service.originalPages(chatID: "c", mark: "P-1")
        XCTAssertEqual(pages, .pages([Sample.png]))
        XCTAssertEqual(HTTPStub.lastRequest?.path, "/api/filing/annexures/original-pages")
        XCTAssertEqual(HTTPStub.lastRequest?.queryItems["mark"], "P-1")

        HTTPStub.always(.json(#"{"success":true,"duplicate_of":"P-1","pages":[]}"#))
        let duplicate = try await service.originalPages(chatID: "c", mark: "P-3")
        XCTAssertEqual(duplicate, .duplicate(of: "P-1"))
    }

    func testTypedCopiesReadTheWholeBlock() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":true,"html":"<p>a</p><p>b</p>","marks":["P-1","P-2"]}"#))
        let all = try await service.typedCopies(chatID: "c")
        XCTAssertEqual(all, TypedCopies(html: "<p>a</p><p>b</p>", marks: ["P-1", "P-2"]))
        XCTAssertEqual(HTTPStub.lastRequest?.path, "/api/filing/annexures/typed-copies")
    }

    func testFileKindIsReadFromTheBytes() {
        XCTAssertEqual(AnnexureFileKind.of(Sample.pdf), .pdf)
        XCTAssertEqual(AnnexureFileKind.of(Sample.png), .image)
        XCTAssertEqual(AnnexureFileKind.of(Data("hello".utf8)), .unknown)
    }
}

// MARK: - The card

@MainActor
private func withList(
    _ fake: FakeFiling, _ body: @MainActor (AnnexureListViewModel) async -> Void
) async {
    await body(AnnexureListViewModel(chatID: "chat-1", service: fake))
}

final class AnnexureListViewModelTests: XCTestCase {

    func testTheCardIsHiddenUntilTheListHasRows() async {
        let fake = FakeFiling()
        await withList(fake) { model in
            XCTAssertFalse(model.isVisible)
            await model.load()
            XCTAssertEqual(model.listState, .loaded)
            XCTAssertFalse(model.isVisible, "nothing cited, so no card")
        }
    }

    func testRowsAreSortedBySortOrderThenMark() async {
        let fake = FakeFiling()
        fake.list = .success([Sample.row("P-10", sort: 1), Sample.row("P-2", sort: 1), Sample.row("R-1", sort: 0)])
        await withList(fake) { model in
            await model.load()
            XCTAssertTrue(model.isVisible)
            XCTAssertEqual(model.rows.map(\.mark), ["R-1", "P-2", "P-10"])
        }
    }

    func testAPlanRefusalHidesTheCardButIsKept() async {
        let fake = FakeFiling()
        fake.list = .failure(FilingAnnexureError.refused(Sample.planRefusal))
        await withList(fake) { model in
            await model.load()
            XCTAssertFalse(model.isVisible)
            XCTAssertEqual(model.refusal?.code, .featureNotInPlan)
        }
    }

    func testOpeningAnOriginalFetchesItsBytes() async {
        let fake = FakeFiling()
        let row = Sample.row("P-1")
        fake.list = .success([row])
        fake.originals["P-1"] = .success(Sample.pdf)
        await withList(fake) { model in
            await model.load()
            XCTAssertNil(model.state(for: row), "nothing is fetched until a row is opened")
            await model.open(row)
            XCTAssertEqual(model.state(for: row), .original(Sample.pdf, .pdf))
            await model.open(row)
            XCTAssertEqual(fake.calls.filter { $0 == "original:P-1" }.count, 1, "opened twice, fetched once")
        }
    }

    func testOpeningATypedCopyShowsItsHTMLOrTheSkippedReason() async {
        let fake = FakeFiling()
        let typed = Sample.row("P-1", .typed)
        let other = Sample.row("P-2", .typed)
        fake.typed["P-1"] = .success(.html("<p>copy</p>"))
        fake.typed["P-2"] = .success(.skipped(reason: "Attached as an original."))
        await withList(fake) { model in
            await model.open(typed)
            await model.open(other)
            XCTAssertEqual(model.state(for: typed), .typedCopy("<p>copy</p>"))
            XCTAssertEqual(model.state(for: other), .skipped("Attached as an original."))
            XCTAssertFalse(fake.calls.contains { $0.hasPrefix("original:") })
        }
    }

    func testAFailedOpenSaysWhichAnnexureAndCanBeRetried() async {
        let fake = FakeFiling()
        let row = Sample.row("P-5")
        fake.originals["P-5"] = .failure(APIError.server(status: 404, message: "annexure not found"))
        await withList(fake) { model in
            await model.open(row)
            guard case .failed(let message) = model.state(for: row) else { return XCTFail("not failed") }
            XCTAssertTrue(message.contains("Annexure P-5"), message)

            fake.originals["P-5"] = .success(Sample.pdf)
            await model.open(row)
            XCTAssertEqual(model.state(for: row), .original(Sample.pdf, .pdf))
        }
    }

    func testARefusedOpenIsARefusal() async {
        let fake = FakeFiling()
        let row = Sample.row("P-1")
        fake.originals["P-1"] = .failure(APIError.refused(Sample.planRefusal))
        await withList(fake) { model in
            await model.open(row)
            XCTAssertEqual(model.state(for: row), .refused(Sample.planRefusal))
        }
    }

    func testTheCardSitsUnderTheLastFinishedDraft() {
        let draft = "<canvas_content><h1>PETITION</h1><p>MOST RESPECTFULLY SHOWETH</p></canvas_content>"
        let first = ChatMessage(role: .assistant, content: draft, id: "a1")
        let question = ChatMessage(role: .user, content: "Now a short note", id: "q2")
        let note = ChatMessage(role: .assistant, content: "Here is a short note, no draft.", id: "a2")
        let messages = [first, question, note]

        XCTAssertEqual(AnnexureListViewModel.draftAnswerID(in: messages, isStreaming: false), "a1")
        XCTAssertNil(AnnexureListViewModel.draftAnswerID(in: messages, isStreaming: true))
        XCTAssertNil(AnnexureListViewModel.draftAnswerID(in: [question, note], isStreaming: false))
    }
}

// MARK: - The package

@MainActor
private func build(
    _ format: FilingPackage.Format, _ fake: FakeFiling, progress: ((Double) -> Void)? = nil
) async throws -> [FilingPackage.Piece] {
    try await FilingPackage.build(
        format: format, draftHTML: "<p>DRAFT</p>", chatID: "c1", service: fake,
        progress: progress ?? { _ in })
}

final class FilingPackageTests: XCTestCase {

    private func mixedRegistry() -> FakeFiling {
        let fake = FakeFiling()
        fake.list = .success([Sample.row("P-2", .typed, sort: 2), Sample.row("P-1", sort: 1),
                              Sample.row("P-3", sort: 3)])
        fake.originals["P-1"] = .success(Sample.pdf)
        fake.originals["P-3"] = .success(Sample.png)
        fake.typed["P-2"] = .success(.html("<p>TYPED P-2</p>"))
        fake.pages["P-1"] = .success(.pages([Sample.png]))
        fake.pages["P-3"] = .success(.pages([Sample.png, Sample.png]))
        return fake
    }

    func testTheDraftComesFirstThenEachAnnexureInOrder() async throws {
        let pieces = try await build(.pdf, mixedRegistry())

        XCTAssertEqual(pieces.first, .draft(html: "<p>DRAFT</p>"))
        guard case .listOfAnnexures(let list) = pieces[1] else { return XCTFail("no list") }
        XCTAssertTrue(list.contains("LIST OF ANNEXURES"))
        XCTAssertTrue(list.contains("Typed copy (attached below)"))
        XCTAssertEqual(pieces.compactMap(\.mark), ["P-1", "P-2", "P-3"])
        XCTAssertEqual(pieces[2], .original(mark: "P-1", data: Sample.pdf, kind: .pdf))
        XCTAssertEqual(pieces[3], .typedCopy(mark: "P-2", html: "<p>TYPED P-2</p>"))
        XCTAssertEqual(pieces[4], .original(mark: "P-3", data: Sample.png, kind: .image))
    }

    func testWordCarriesOriginalsAsPagePictures() async throws {
        let fake = mixedRegistry()
        let pieces = try await build(.word, fake)

        XCTAssertEqual(pieces[2], .originalPages(mark: "P-1", pages: [Sample.png]))
        XCTAssertFalse(fake.calls.contains { $0.hasPrefix("original:") }, "Word reads pages, not the PDF")
        let html = FilingPackage.wordHTML(pieces)
        XCTAssertTrue(html.hasPrefix("<p>DRAFT</p>"))
        XCTAssertTrue(html.contains("ANNEXURE P-1 (ORIGINAL)"))
        XCTAssertEqual(html.components(separatedBy: "data:image/png;base64,").count - 1, 3)
        XCTAssertLessThan(html.range(of: "P-1 (ORIGINAL)")!.lowerBound, html.range(of: "TYPED P-2")!.lowerBound)
    }

    func testASkippedTypedCopyIsNamedNotDropped() async throws {
        let fake = FakeFiling()
        fake.list = .success([Sample.row("P-1", .typed)])
        fake.typed["P-1"] = .success(.skipped(reason: "Annexure P-1 is an original document."))

        let pieces = try await build(.pdf, fake)

        XCTAssertEqual(pieces.last, .note(mark: "P-1", text: "Annexure P-1 is an original document."))
    }

    /// A typed copy whose document has not been read yet will not be ready on a retry either,
    /// so the package is made and the gap is named in it.
    func testATypedCopyTheRegistryCannotPrepareIsNamed() async throws {
        let fake = FakeFiling()
        fake.list = .success([Sample.row("P-1", .typed)])
        fake.typed["P-1"] = .failure(FilingAnnexureError.declined(mark: "P-1", message: "Not read yet."))

        let pieces = try await build(.word, fake)

        XCTAssertEqual(pieces.last, .note(mark: "P-1", text: "Not read yet."))
    }

    func testAFailedOriginalStopsWithAMessage() async {
        let fake = mixedRegistry()
        fake.originals["P-3"] = .failure(APIError.server(status: 500, message: "internal error: boom"))

        do {
            _ = try await build(.pdf, fake)
            XCTFail("the package was made without P-3")
        } catch let failure as FilingPackage.Failure {
            guard case .stopped(let message) = failure else { return XCTFail("\(failure)") }
            XCTAssertTrue(message.contains("Annexure P-3"), message)
            XCTAssertTrue(message.contains("not made"), message)
            XCTAssertFalse(message.contains("boom"), message)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testAnOriginalThatCannotBeAttachedIsNamed() async throws {
        let fake = FakeFiling()
        fake.list = .success([Sample.row("P-1")])
        fake.originals["P-1"] = .failure(FilingAnnexureError.unsupportedFile(mark: "P-1"))

        let pieces = try await build(.pdf, fake)

        guard case .note(let mark, let text) = pieces.last else { return XCTFail("no note") }
        XCTAssertEqual(mark, "P-1")
        XCTAssertTrue(text.contains("can't be attached"))
    }

    func testADuplicateIsNotAttachedTwice() async throws {
        let fake = FakeFiling()
        fake.list = .success([Sample.row("P-1", sort: 1), Sample.row("P-2", sort: 2, duplicateOf: "P-1")])
        fake.originals["P-1"] = .success(Sample.pdf)

        let pieces = try await build(.pdf, fake)

        XCTAssertEqual(pieces.last, .note(mark: "P-2", text: FilingPackage.duplicateSentence("P-1")))
        XCTAssertFalse(fake.calls.contains("original:P-2"))
    }

    func testARefusalSurfacesAsARefusal() async {
        let fake = FakeFiling()
        fake.list = .failure(FilingAnnexureError.refused(Sample.planRefusal))

        do {
            _ = try await build(.pdf, fake)
            XCTFail("expected a refusal")
        } catch let failure as FilingPackage.Failure {
            XCTAssertEqual(failure, .refused(Sample.planRefusal))
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testARefusalPartWayIsStillARefusal() async {
        let fake = mixedRegistry()
        fake.typed["P-2"] = .failure(FilingAnnexureError.refused(Sample.planRefusal))

        do {
            _ = try await build(.pdf, fake)
            XCTFail("expected a refusal")
        } catch let failure as FilingPackage.Failure {
            XCTAssertEqual(failure, .refused(Sample.planRefusal))
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testNoAnnexuresIsJustTheDraft() async throws {
        let pieces = try await build(.pdf, FakeFiling())
        XCTAssertEqual(pieces, [.draft(html: "<p>DRAFT</p>")])
    }

    func testProgressRisesAsTheWebReportsIt() async throws {
        let box = ProgressBox()
        _ = try await build(.pdf, mixedRegistry(), progress: { box.values.append($0) })

        XCTAssertEqual(box.values.first, FilingPackage.Progress.started)
        XCTAssertEqual(box.values.last ?? 0, FilingPackage.Progress.annexuresRead, accuracy: 0.0001)
        XCTAssertEqual(box.values, box.values.sorted(), "progress went backwards")
        XCTAssertEqual(box.values.count, 2 + 3)
    }

    func testPDFSegmentsJoinMarkupAndMergeOriginalsAfterTheirHeadings() async throws {
        let pieces = try await build(.pdf, mixedRegistry())
        let segments = FilingPackage.pdfSegments(pieces)

        guard segments.count == 4 else { return XCTFail("\(segments.count) segments") }
        guard case .html(let first) = segments[0] else { return XCTFail("draft is not markup") }
        XCTAssertTrue(first.hasPrefix("<p>DRAFT</p>"))
        XCTAssertTrue(first.hasSuffix("ANNEXURE P-1 (ORIGINAL)</u></strong></p>"))
        XCTAssertEqual(segments[1], .pdf(Sample.pdf))
        guard case .html(let middle) = segments[2] else { return XCTFail("no typed copy") }
        XCTAssertFalse(middle.hasPrefix(FilingPackage.pageBreak), "a leading break adds a blank page")
        XCTAssertTrue(middle.contains("TYPED P-2"))
        XCTAssertTrue(middle.contains("P-3 (ORIGINAL)"))
        XCTAssertEqual(segments[3], .image(Sample.png))
    }

    func testThePackageIsNamedAfterTheDraft() {
        XCTAssertEqual(FilingPackage.fileName(title: " Writ Petition ", format: .pdf),
                       "Writ Petition — filing package.pdf")
        XCTAssertEqual(FilingPackage.fileName(title: "", format: .word), "Document — filing package.docx")
    }

    func testTheListEscapesTitles() {
        let html = FilingPackage.listHTML([FilingAnnexure(
            id: "1", mark: "P-1", title: "Sale deed <A & B>", treatment: .original)])
        XCTAssertTrue(html.contains("Sale deed &lt;A &amp; B&gt;"))
    }
}

private final class ProgressBox: @unchecked Sendable {
    var values: [Double] = []
}

// MARK: - The download

@MainActor
private func withExport(
    _ fake: FakeFiling, _ body: @MainActor (FilingPackageExport) async -> Void
) async {
    await body(FilingPackageExport(chatID: "c1", service: fake))
}

final class FilingPackageExportTests: XCTestCase {

    func testAFinishedPackageIsReady() async {
        let fake = FakeFiling()
        fake.list = .success([Sample.row("P-1", .typed)])
        fake.typed["P-1"] = .success(.html("<p>t</p>"))
        await withExport(fake) { export in
            await export.start(.word, draftHTML: "<p>d</p>") { pieces in
                Data(FilingPackage.wordHTML(pieces).utf8)
            }
            guard case .ready(let data, .word) = export.phase else { return XCTFail("\(export.phase)") }
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("<p>t</p>"))
            export.reset()
            XCTAssertEqual(export.phase, .idle)
        }
    }

    func testARefusalIsShownAsARefusal() async {
        let fake = FakeFiling()
        fake.list = .failure(FilingAnnexureError.refused(Sample.planRefusal))
        await withExport(fake) { export in
            await export.start(.pdf, draftHTML: "") { _ in Data() }
            XCTAssertEqual(export.phase, .refused(Sample.planRefusal))
        }
    }

    func testAStoppedPackageCarriesItsMessage() async {
        let fake = FakeFiling()
        fake.list = .success([Sample.row("P-1")])
        fake.originals["P-1"] = .failure(APIError.transport("The Internet connection appears to be offline."))
        await withExport(fake) { export in
            await export.start(.pdf, draftHTML: "") { _ in Data() }
            guard case .failed(let message) = export.phase else { return XCTFail("\(export.phase)") }
            XCTAssertTrue(message.contains("Annexure P-1"))
            XCTAssertTrue(message.contains("offline"))
        }
    }
}
