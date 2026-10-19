import XCTest
@testable import EmperorCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Stand-ins

/// Records each download asked for, and answers with a fixed file or a fixed failure.
private final class RecordingDownloads: FileDownloading, @unchecked Sendable {
    var failure: Error?
    private(set) var zips: [(files: [FileZipEntry], name: String?)] = []
    private(set) var searchables: [(name: String, folder: String?)] = []

    func zip(files: [FileZipEntry], suggestedName: String?) async throws -> DownloadedFile {
        zips.append((files, suggestedName))
        if let failure { throw failure }
        return DownloadedFile(
            fileName: suggestedName.map(FileDownloadWording.zipName(for:)) ?? "documents.zip",
            data: Data("PK".utf8))
    }

    func searchablePDF(name: String, folderName: String?) async throws -> DownloadedFile {
        searchables.append((name, folderName))
        if let failure { throw failure }
        return DownloadedFile(
            fileName: FileDownloadWording.searchableName(for: name), data: Data("%PDF".utf8))
    }
}

/// Nothing in these tests edits the library; any call is a failure.
private final class UntouchedManager: FileManaging, @unchecked Sendable {
    func delete(name: String, folderName: String?) async throws { XCTFail("unexpected delete") }
    func rename(name: String, in folderName: String?, to newName: String) async throws -> FileOperationResult {
        XCTFail("unexpected rename"); return FileOperationResult(fileName: newName, folderName: "")
    }
    func move(name: String, from folderName: String?, to destination: String?) async throws { XCTFail("unexpected move") }
    func setFavorite(_ favorite: Bool, name: String, folderName: String?) async throws -> Bool { favorite }
    func createFolder(named path: String) async throws {}
    func renameFolder(at path: String, to newName: String) async throws -> String { newName }
    func deleteFolder(named path: String) async throws { XCTFail("unexpected folder delete") }
}

private func zipStored(_ path: String) -> FileNode.StoredFile {
    FileNode.StoredFile(
        name: String(path.split(separator: "/").last ?? ""), path: path, size: 10,
        modified: nil, status: "ready", progress: nil, favorite: nil)
}

private func zipFolder(_ path: String, _ children: [FileNode]) -> FileNode {
    .folder(FileNode.Folder(
        name: String(path.split(separator: "/").last ?? ""), path: path, created: nil, files: children))
}

private let library: [FileNode] = [
    zipFolder("Bakshi", [
        .file(zipStored("Bakshi/Plaint.pdf")),
        zipFolder("Bakshi/2025", [.file(zipStored("Bakshi/2025/Order.pdf"))]),
    ]),
    zipFolder("Arora", [.file(zipStored("Arora/Notice.docx"))]),
    .file(zipStored("Loose.pdf")),
]

@MainActor
private func withLibrary(
    downloads: RecordingDownloads? = RecordingDownloads(),
    _ body: @MainActor (MyFilesViewModel, RecordingDownloads?) async -> Void
) async {
    let files = FakeFiles()
    files.tree = library
    let model = MyFilesViewModel(service: files, manager: UntouchedManager(), downloads: downloads)
    await model.load()
    await body(model, downloads)
}

// MARK: - My Files: selecting, zips and searchable copies

final class MyFilesDownloadTests: XCTestCase {

    func testSelectingCollectsDocumentsAndNamesTheButton() async {
        await withLibrary { model, _ in
            XCTAssertFalse(model.isSelecting)
            model.toggleSelection(zipStored("Bakshi/Plaint.pdf"))
            XCTAssertTrue(model.selectedPaths.isEmpty, "a tap outside selecting selects nothing")

            model.beginSelecting()
            XCTAssertEqual(model.selectionTitle, "Select documents")
            model.toggleSelection(zipStored("Bakshi/Plaint.pdf"))
            XCTAssertEqual(model.zipSelectionLabel, "Download as zip")
            model.toggleSelection(zipStored("Loose.pdf"))
            XCTAssertEqual(model.selectionTitle, "2 selected")
            XCTAssertEqual(model.zipSelectionLabel, "Download 2 as zip")
            XCTAssertTrue(model.isSelected(zipStored("Loose.pdf")))

            model.toggleSelection(zipStored("Loose.pdf"))
            XCTAssertEqual(model.selectedFiles.map(\.path), ["Bakshi/Plaint.pdf"])

            model.endSelecting()
            XCTAssertFalse(model.isSelecting)
            XCTAssertTrue(model.selectedPaths.isEmpty)
        }
    }

    /// The chosen documents go as `{folderName, fileName}` pairs, a loose one from `"."`, and the
    /// archive lands on the share sheet under the server's name.
    func testASelectionIsZippedAndShared() async {
        await withLibrary { model, downloads in
            model.beginSelecting()
            model.toggleSelection(zipStored("Bakshi/2025/Order.pdf"))
            model.toggleSelection(zipStored("Loose.pdf"))
            await model.downloadSelectionAsZip()

            XCTAssertEqual(downloads?.zips.count, 1)
            XCTAssertEqual(downloads?.zips.first?.files, [
                FileZipEntry(folderName: "Bakshi/2025", fileName: "Order.pdf"),
                FileZipEntry(folderName: ".", fileName: "Loose.pdf"),
            ])
            XCTAssertNil(downloads?.zips.first?.name)
            XCTAssertEqual(model.sharing?.fileName, "documents.zip")
            XCTAssertFalse(model.isSelecting, "selecting ends once the zip has arrived")
            XCTAssertNil(model.actionError)
        }
    }

    func testAnEmptySelectionAsksForADocumentAndSendsNothing() async {
        await withLibrary { model, downloads in
            model.beginSelecting()
            await model.downloadSelectionAsZip()
            XCTAssertEqual(model.actionError, "Choose at least one document to download.")
            XCTAssertEqual(downloads?.zips.count, 0)
        }
    }

    /// A failed zip keeps the selection, so it can be tried again.
    func testAFailedZipKeepsTheSelection() async {
        let downloads = RecordingDownloads()
        downloads.failure = FileDownloadWording.noneFound(count: 2)
        await withLibrary(downloads: downloads) { model, _ in
            model.beginSelecting()
            model.toggleSelection(zipStored("Bakshi/Plaint.pdf"))
            model.toggleSelection(zipStored("Loose.pdf"))
            await model.downloadSelectionAsZip()
            XCTAssertEqual(model.actionError, "None of those documents are in your library any more.")
            XCTAssertTrue(model.isSelecting)
            XCTAssertEqual(model.selectedPaths.count, 2)
            XCTAssertNil(model.sharing)
        }
    }

    /// A folder's zip holds everything beneath it, sub-folders included, and is named after it.
    func testAFoldersZipFlattensItsSubfoldersAndCarriesItsName() async {
        await withLibrary { model, downloads in
            let bakshi = FileBrowser.folder(at: "Bakshi", in: model.tree)!
            XCTAssertEqual(model.zipPlan(for: bakshi), [
                FileZipEntry(folderName: "Bakshi", fileName: "Plaint.pdf"),
                FileZipEntry(folderName: "Bakshi/2025", fileName: "Order.pdf"),
            ])
            await model.downloadAsZip(bakshi)
            XCTAssertEqual(downloads?.zips.first?.name, "Bakshi")
            XCTAssertEqual(model.sharing?.fileName, "Bakshi.zip")
        }
    }

    func testAnEmptyFolderIsNotZipped() async {
        let files = FakeFiles()
        files.tree = [zipFolder("Empty", [])]
        let downloads = RecordingDownloads()
        let model = await MyFilesViewModel(service: files, manager: UntouchedManager(), downloads: downloads)
        await model.load()
        let empty = await FileBrowser.folder(at: "Empty", in: model.tree)!
        await model.downloadAsZip(empty)
        let notice = await model.actionNotice
        XCTAssertEqual(notice, "Empty holds no documents to download.")
        XCTAssertEqual(downloads.zips.count, 0)
    }

    /// A choice whose document has left the library is let go when the library is read again.
    func testASelectionFollowsTheLibrary() async {
        let files = FakeFiles()
        files.tree = library
        let model = await MyFilesViewModel(service: files, manager: UntouchedManager(), downloads: RecordingDownloads())
        await model.load()
        await model.beginSelecting()
        await model.toggleSelection(zipStored("Arora/Notice.docx"))
        await model.toggleSelection(zipStored("Loose.pdf"))
        files.tree = [.file(zipStored("Loose.pdf"))]
        await model.load()
        let paths = await model.selectedPaths
        XCTAssertEqual(paths, ["Loose.pdf"])
    }

    func testOnlyAPDFOffersASearchableCopy() async {
        await withLibrary { model, downloads in
            XCTAssertTrue(model.offersSearchableCopy(of: zipStored("Bakshi/Plaint.pdf")))
            XCTAssertTrue(model.offersSearchableCopy(of: zipStored("Bakshi/SCAN.PDF")))
            XCTAssertFalse(model.offersSearchableCopy(of: zipStored("Arora/Notice.docx")))

            await model.shareSearchableCopy(of: zipStored("Bakshi/2025/Order.pdf"))
            XCTAssertEqual(downloads?.searchables.first?.name, "Order.pdf")
            XCTAssertEqual(downloads?.searchables.first?.folder, "Bakshi/2025")
            XCTAssertEqual(model.sharing?.fileName, "Order_searchable.pdf")
        }
    }

    func testWithoutTheServiceNoDownloadIsOffered() async {
        await withLibrary(downloads: nil) { model, _ in
            XCTAssertFalse(model.offersDownloads)
            XCTAssertFalse(model.offersSearchableCopy(of: zipStored("Bakshi/Plaint.pdf")))
        }
    }
}

// MARK: - The viewer's searchable copy

final class SearchableCopyViewModelTests: XCTestCase {

    @MainActor
    private static func run(
        _ downloads: RecordingDownloads, _ body: @MainActor (SearchableCopyViewModel) async -> Void
    ) async {
        await body(SearchableCopyViewModel(downloads: downloads))
    }

    func testAPDFsCopyArrivesForTheShareSheet() async {
        let downloads = RecordingDownloads()
        await Self.run(downloads) { model in
            await model.fetch(ChatAttachment(name: "Award.pdf", folderName: "Bakshi"))
            XCTAssertEqual(model.copy?.fileName, "Award_searchable.pdf")
            XCTAssertNil(model.errorMessage)
            XCTAssertFalse(model.isFetching)
        }
        XCTAssertEqual(downloads.searchables.first?.folder, "Bakshi")
    }

    func testAWordDocumentHasNone() async {
        let downloads = RecordingDownloads()
        XCTAssertFalse(SearchableCopyViewModel.isOffered(for: ChatAttachment(name: "Reply.docx", folderName: nil)))
        await Self.run(downloads) { model in
            await model.fetch(ChatAttachment(name: "Reply.docx", folderName: nil))
            XCTAssertNil(model.copy)
        }
        XCTAssertTrue(downloads.searchables.isEmpty)
    }

    func testAFailureIsWorded() async {
        let downloads = RecordingDownloads()
        downloads.failure = FileDownloadWording.searchableNotFound
        await Self.run(downloads) { model in
            await model.fetch(ChatAttachment(name: "Award.pdf", folderName: nil))
            XCTAssertEqual(model.errorMessage, "That document is no longer in your library.")
            XCTAssertNil(model.copy)
        }
    }
}

// MARK: - Names

final class FileDownloadWordingTests: XCTestCase {

    func testTheSearchableNameIsTheServers() {
        XCTAssertEqual(FileDownloadWording.searchableName(for: "Plaint.pdf"), "Plaint_searchable.pdf")
        XCTAssertEqual(FileDownloadWording.searchableName(for: "SCAN.PDF"), "SCAN_searchable.pdf")
        XCTAssertEqual(FileDownloadWording.searchableName(for: "Final Order.pdf"), "Final_Order_searchable.pdf")
    }

    func testAFoldersZipIsNamedAfterIt() {
        XCTAssertEqual(FileDownloadWording.zipName(for: "Bakshi"), "Bakshi.zip")
        XCTAssertEqual(FileDownloadWording.zipName(for: "Bakshi.zip"), "Bakshi.zip")
        XCTAssertEqual(FileDownloadWording.zipName(for: "  "), "documents.zip")
    }

    func testTheContentDispositionNameIsRead() {
        XCTAssertEqual(
            FileDownloadWording.filename(fromContentDisposition: #"attachment; filename="documents.zip""#),
            "documents.zip")
        XCTAssertEqual(
            FileDownloadWording.filename(fromContentDisposition: "attachment; filename=Plaint_searchable.pdf"),
            "Plaint_searchable.pdf")
        XCTAssertEqual(
            FileDownloadWording.filename(fromContentDisposition: #"attachment; filename="../etc/x.pdf""#),
            "x.pdf")
        XCTAssertNil(FileDownloadWording.filename(fromContentDisposition: "attachment"))
        XCTAssertNil(FileDownloadWording.filename(fromContentDisposition: nil))
    }

    /// A zip's end record, as an archiver writes it, holding `count` entries.
    private func zipBytes(entries count: UInt8, comment: String = "") -> Data {
        var bytes: [UInt8] = [0x50, 0x4B, 0x03, 0x04] + Array(repeating: 0, count: 40)
        bytes += [0x50, 0x4B, 0x05, 0x06, 0, 0, 0, 0, count, 0, count, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        let commentBytes = Array(comment.utf8)
        bytes += [UInt8(commentBytes.count), 0] + commentBytes
        return Data(bytes)
    }

    func testAZipsEntriesAreCounted() {
        XCTAssertEqual(FileDownloadWording.zipEntryCount(zipBytes(entries: 3)), 3)
        XCTAssertEqual(FileDownloadWording.zipEntryCount(zipBytes(entries: 2, comment: "made here")), 2)
        XCTAssertNil(FileDownloadWording.zipEntryCount(Data("PK".utf8)))
        XCTAssertNil(FileDownloadWording.zipEntryCount(Data(repeating: 1, count: 100)))
    }

    /// The route leaves out what it cannot find and still answers 200, so a short zip is said.
    func testAShortZipIsSaid() {
        let archive = DownloadedFile(fileName: "documents.zip", data: zipBytes(entries: 2))
        XCTAssertEqual(
            FileDownloadWording.shortfallNotice(asked: 3, archive: archive),
            "1 of the 3 documents was no longer in your library, so documents.zip holds 2.")
        XCTAssertNil(FileDownloadWording.shortfallNotice(asked: 2, archive: archive))
        XCTAssertNil(FileDownloadWording.shortfallNotice(
            asked: 5, archive: DownloadedFile(fileName: "x.zip", data: Data("PK".utf8))))
    }

    func testTheRootIsSpelledAsADot() {
        XCTAssertEqual(FileZipEntry(zipStored("Loose.pdf")).folderName, ".")
        XCTAssertEqual(FileZipEntry(zipStored("A/B/C.pdf")).folderName, "A/B")
    }
}

// MARK: - The wire

/// What goes on the wire for the two downloads, and how each answer is read.
final class FileDownloadWireTests: XCTestCase {

    private static let config = APIConfig(baseURL: URL(string: "https://example.test/api")!)

    override func setUp() {
        super.setUp()
        HTTPStub.reset()
    }

    override func tearDown() {
        HTTPStub.reset()
        super.tearDown()
    }

    private func service() async -> FileDownloadService {
        let client = APIClient(config: Self.config, session: HTTPStub.session())
        await client.setCredentials(Credentials(token: "tok-abc", userID: 42))
        return FileDownloadService(client: client)
    }

    private static let zipBytes = Data([0x50, 0x4B, 0x03, 0x04, 0x14, 0x00])

    private static func zipReply() -> HTTPStub.Reply {
        HTTPStub.Reply(
            status: 200, body: zipBytes,
            headers: [
                "Content-Type": "application/zip",
                "Content-Disposition": #"attachment; filename="documents.zip""#,
            ])
    }

    /// `POST /download-files` with `{userId, files:[{folderName,fileName}]}` and the bearer token.
    func testAZipIsAskedForByFolderAndName() async throws {
        HTTPStub.always(Self.zipReply())
        let archive = try await service().zip(files: [
            FileZipEntry(folderName: "Bakshi", fileName: "Plaint.pdf"),
            FileZipEntry(folderName: "", fileName: "Loose.pdf"),
        ], suggestedName: nil)

        let sent = try XCTUnwrap(HTTPStub.lastRequest)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.path, "/api/download-files")
        XCTAssertEqual(sent.header("Authorization"), "Bearer tok-abc")
        XCTAssertEqual(sent.bodyJSON["userId"] as? String, "42")
        let files = try XCTUnwrap(sent.bodyJSON["files"] as? [[String: String]])
        XCTAssertEqual(files, [
            ["folderName": "Bakshi", "fileName": "Plaint.pdf"],
            ["folderName": ".", "fileName": "Loose.pdf"],
        ])
        XCTAssertEqual(archive.fileName, "documents.zip")
        XCTAssertEqual(archive.data, Self.zipBytes)
    }

    func testAFoldersZipKeepsTheFoldersName() async throws {
        HTTPStub.always(Self.zipReply())
        let archive = try await service().zip(
            files: [FileZipEntry(folderName: "Bakshi", fileName: "Plaint.pdf")], suggestedName: "Bakshi")
        XCTAssertEqual(archive.fileName, "Bakshi.zip")
    }

    func testNothingToZipIsRefusedBeforeTheRoundTrip() async throws {
        HTTPStub.always(Self.zipReply())
        do {
            _ = try await service().zip(files: [], suggestedName: nil)
            XCTFail("an empty zip must not be asked for")
        } catch let error as APIError {
            XCTAssertEqual(error, FileDownloadWording.nothingToZip)
        }
        XCTAssertTrue(HTTPStub.seen.isEmpty)
    }

    func testA404SaysNoneWereFound() async throws {
        HTTPStub.always(.json(#"{"error":"None of the requested files were found"}"#, status: 404))
        do {
            _ = try await service().zip(
                files: [FileZipEntry(folderName: "A", fileName: "x.pdf")], suggestedName: nil)
            XCTFail("expected an error")
        } catch let error as APIError {
            XCTAssertEqual(error, FileDownloadWording.noneFound(count: 1))
        }
    }

    func testA400SaysNothingWasChosen() async throws {
        HTTPStub.always(.json(#"{"error":"Missing parameters"}"#, status: 400))
        do {
            _ = try await service().zip(
                files: [FileZipEntry(folderName: "A", fileName: "x.pdf")], suggestedName: nil)
            XCTFail("expected an error")
        } catch let error as APIError {
            XCTAssertEqual(error, FileDownloadWording.nothingToZip)
        }
    }

    /// A 200 that is not a zip is not a download.
    func testA200ThatIsNotAZipIsRefused() async throws {
        HTTPStub.always(.text("<html>gateway</html>"))
        do {
            _ = try await service().zip(
                files: [FileZipEntry(folderName: "A", fileName: "x.pdf")], suggestedName: nil)
            XCTFail("expected an error")
        } catch let error as APIError {
            XCTAssertEqual(error, FileDownloadWording.incomplete)
        }
    }

    func testADeadTokenIsASignOut() async throws {
        HTTPStub.always(.json(#"{"success":false,"error":"Authentication required"}"#, status: 401))
        do {
            _ = try await service().zip(
                files: [FileZipEntry(folderName: "A", fileName: "x.pdf")], suggestedName: nil)
            XCTFail("expected an error")
        } catch let error as APIError {
            XCTAssertEqual(error, .invalidCredentials)
        }
    }

    // MARK: download-searchable

    private static func pdfReply(named name: String) -> HTTPStub.Reply {
        HTTPStub.Reply(
            status: 200, body: Data("%PDF-1.7\n".utf8),
            headers: [
                "Content-Type": "application/pdf",
                "Content-Disposition": "attachment; filename=\"\(name)\"",
            ])
    }

    /// `GET /download-searchable?userId&folderName&fileName`, the root spelled `"."`.
    func testASearchableCopyIsAskedForByFolderAndName() async throws {
        HTTPStub.always(Self.pdfReply(named: "Loose_searchable.pdf"))
        let copy = try await service().searchablePDF(name: "Loose.pdf", folderName: nil)

        let sent = try XCTUnwrap(HTTPStub.lastRequest)
        XCTAssertEqual(sent.httpMethod, "GET")
        XCTAssertEqual(sent.path, "/api/download-searchable")
        XCTAssertEqual(sent.queryItems, ["userId": "42", "folderName": ".", "fileName": "Loose.pdf"])
        XCTAssertEqual(sent.header("Authorization"), "Bearer tok-abc")
        XCTAssertEqual(copy.fileName, "Loose_searchable.pdf")
    }

    func testTheNameFallsBackToTheServersRule() async throws {
        HTTPStub.always(HTTPStub.Reply(
            status: 200, body: Data("%PDF-1.4".utf8), headers: ["Content-Type": "application/pdf"]))
        let copy = try await service().searchablePDF(name: "Final Order.pdf", folderName: "Bakshi")
        XCTAssertEqual(copy.fileName, "Final_Order_searchable.pdf")
        XCTAssertEqual(HTTPStub.lastRequest?.queryItems["folderName"], "Bakshi")
    }

    func testAPlainText404SaysTheDocumentIsGone() async throws {
        HTTPStub.always(.text("File not found", status: 404))
        do {
            _ = try await service().searchablePDF(name: "Gone.pdf", folderName: "A")
            XCTFail("expected an error")
        } catch let error as APIError {
            XCTAssertEqual(error, FileDownloadWording.searchableNotFound)
        }
    }

    func testANonPDFIsNeverAskedFor() async throws {
        HTTPStub.always(Self.pdfReply(named: "x.pdf"))
        do {
            _ = try await service().searchablePDF(name: "Reply.docx", folderName: "A")
            XCTFail("expected an error")
        } catch let error as APIError {
            XCTAssertEqual(error, FileDownloadWording.notAPDF)
        }
        XCTAssertTrue(HTTPStub.seen.isEmpty)
    }

    func testAServerFailureCarriesItsSentence() async throws {
        HTTPStub.always(.text("disk full", status: 500))
        do {
            _ = try await service().searchablePDF(name: "A.pdf", folderName: "A")
            XCTFail("expected an error")
        } catch let error as APIError {
            XCTAssertEqual(error, .server(status: 500, message: "disk full"))
        }
    }
}
