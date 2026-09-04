import XCTest
@testable import EmperorCore

private final class FakeFileManager: FileManaging, @unchecked Sendable {
    var renameResult = FileOperationResult(fileName: "renamed.pdf", folderName: "")
    var favoriteEcho: Bool?
    var failure: Error?

    private(set) var deleted: [(name: String, folder: String?)] = []
    private(set) var renamed: [(name: String, folder: String?, newName: String)] = []
    private(set) var favorited: [(favorite: Bool, name: String)] = []
    private(set) var createdFolders: [String] = []
    private(set) var deletedFolders: [String] = []
    private(set) var moved: [(name: String, from: String?, to: String?)] = []

    func delete(name: String, folderName: String?) async throws {
        if let failure { throw failure }
        deleted.append((name, folderName))
    }

    func rename(
        name: String, in folderName: String?, to newName: String
    ) async throws -> FileOperationResult {
        if let failure { throw failure }
        renamed.append((name, folderName, newName))
        return renameResult
    }

    func move(name: String, from folderName: String?, to destination: String?) async throws {
        if let failure { throw failure }
        moved.append((name, folderName, destination))
    }

    func setFavorite(_ favorite: Bool, name: String, folderName: String?) async throws -> Bool {
        if let failure { throw failure }
        favorited.append((favorite, name))
        return favoriteEcho ?? favorite
    }

    func createFolder(named path: String) async throws {
        if let failure { throw failure }
        createdFolders.append(path)
    }

    func deleteFolder(named path: String) async throws {
        if let failure { throw failure }
        deletedFolders.append(path)
    }
}

private final class FakeTree: FileProviding, @unchecked Sendable {
    var nodes: [FileNode] = []
    /// Fails only from the Nth fetch onward, so a test can load cleanly and then break the
    /// refresh that follows an edit.
    var failFromFetch: Int?
    private(set) var fetches = 0

    func tree() async throws -> [FileNode] {
        fetches += 1
        if let failFromFetch, fetches >= failFromFetch {
            throw APIError.transport("connection lost")
        }
        return nodes
    }

    func fileData(name: String, folderName: String?) async throws -> Data { Data() }
}

private func storedFile(
    _ name: String, folder: String = "", favorite: Bool? = nil
) -> FileNode.StoredFile {
    FileNode.StoredFile(
        name: name,
        path: folder.isEmpty ? name : "\(folder)/\(name)",
        status: "ready",
        favorite: favorite)
}

private func tree(_ files: [FileNode.StoredFile]) -> [FileNode] {
    var byFolder: [String: [FileNode.StoredFile]] = [:]
    for file in files { byFolder[file.folderPath, default: []].append(file) }
    return byFolder.map { folder, contents in
        folder.isEmpty
            ? .file(contents[0])
            : .folder(FileNode.Folder(name: folder, path: folder, files: contents.map { .file($0) }))
    }
}

@MainActor
private func withLibrary(
    files: [FileNode.StoredFile] = [storedFile("notice.pdf", folder: "Bakshi")],
    _ body: @MainActor (FakeTree, FakeFileManager, FileLibraryViewModel) async -> Void
) async {
    let treeService = FakeTree()
    treeService.nodes = tree(files)
    let manager = FakeFileManager()
    let model = FileLibraryViewModel(service: treeService, manager: manager)
    await model.load()
    await body(treeService, manager, model)
}

final class FolderNameTests: XCTestCase {

    /// `create-folder` mkdirs the storage root for a name that sanitises to nothing and
    /// answers `{"success":true}`. The user sees no folder, no error, and nothing to fix.
    func testANameThatSanitisesAwayIsRejected() {
        for name in [".", "..", "...", "/", "///", "   ", "", "./."] {
            XCTAssertFalse(FolderName.isCreatable(name), "\(name) should be refused")
        }
    }

    func testAnOrdinaryNameIsAccepted() {
        XCTAssertTrue(FolderName.isCreatable("Bakshi"))
        XCTAssertTrue(FolderName.isCreatable("2025/Writs"))
        XCTAssertTrue(FolderName.isCreatable("s.138 notices"))
    }

    /// Everything outside `[A-Za-z0-9._-]` becomes an underscore server-side. Showing the real
    /// name is what stops a folder appearing to be missing under the name that was typed.
    func testThePreviewShowsWhatWillActuallyExist() {
        XCTAssertEqual(FolderName.preview("s.138 notices"), "s.138_notices")
        XCTAssertEqual(FolderName.preview("ABC Ltd vs. Bakshi"), "ABC_Ltd_vs._Bakshi")
        XCTAssertEqual(FolderName.preview("2025/Writs"), "2025/Writs")
    }

    /// Devanagari is not in the allowed set, so a Hindi folder name becomes underscores —
    /// unusable, and worth refusing rather than creating a folder called `______`.
    func testANameOfOnlyNonLatinCharactersIsRefused() {
        XCTAssertFalse(FolderName.isCreatable("मामला"))
    }
}

final class FileOperationErrorTests: XCTestCase {

    /// `delete-folder` reports a failed deletion as "An error occurred while downloading
    /// files" (`sync-server.js:11427`). Passing that through tells someone their deletion
    /// failed because of a download.
    func testTheMislabelledDeleteFolderErrorIsNotShown() {
        var body = FileOperationBody()
        body.error = "An error occurred while downloading files"
        let message = FileManagementService.message(from: body, status: 500)
        XCTAssertFalse(message.localizedCaseInsensitiveContains("download"))
        XCTAssertTrue(message.contains("documents are unchanged"))
    }

    func testAUsefulServerMessageIsPassedThrough() {
        var body = FileOperationBody()
        body.error = #""award.pdf" was not found in Bakshi"#
        XCTAssertEqual(
            FileManagementService.message(from: body, status: 404),
            #""award.pdf" was not found in Bakshi"#)
    }

    func testAnEmptyBodyStillProducesWording() {
        XCTAssertFalse(FileManagementService.message(from: nil, status: 500).isEmpty)
    }
}

final class FileManagementViewModelTests: XCTestCase {

    // MARK: - Deleting

    func testDeletingAsksTheServerAndRefetches() async {
        await withLibrary { treeService, manager, model in
            let before = treeService.fetches
            await model.delete(storedFile("notice.pdf", folder: "Bakshi"))

            XCTAssertEqual(manager.deleted.count, 1)
            XCTAssertEqual(manager.deleted.first?.name, "notice.pdf")
            XCTAssertEqual(manager.deleted.first?.folder, "Bakshi")
            // `delete-file` answers 200 whether or not the file was there, so "it worked" is
            // not evidence of what the library now holds. Only a refetch is.
            XCTAssertEqual(treeService.fetches, before + 1)
        }
    }

    func testADeletionFailureIsReported() async {
        await withLibrary { _, manager, model in
            manager.failure = APIError.server(status: 403, message: "Refusing to operate on it")
            await model.delete(storedFile("notice.pdf", folder: "Bakshi"))

            XCTAssertEqual(model.actionError, "Refusing to operate on it")
        }
    }

    // MARK: - Renaming

    /// The server force-preserves the original extension, so `award.pdf` renamed to `award`
    /// stays `award.pdf`. Annexure citations match the exact on-disk name.
    func testTheServersFinalNameIsWhatIsShown() async {
        await withLibrary { _, manager, model in
            manager.renameResult = FileOperationResult(
                fileName: "final_award.pdf", folderName: "Bakshi")
            await model.rename(storedFile("award.pdf", folder: "Bakshi"), to: "final_award")

            XCTAssertEqual(manager.renamed.first?.newName, "final_award")
            XCTAssertNotNil(model.actionNotice)
            XCTAssertTrue(model.actionNotice!.contains("final_award.pdf"))
            XCTAssertTrue(model.actionNotice!.contains("original file type is kept"))
        }
    }

    func testANameThatSurvivesIntactIsNotFussedOver() async {
        await withLibrary { _, manager, model in
            manager.renameResult = FileOperationResult(fileName: "order.pdf", folderName: "Bakshi")
            await model.rename(storedFile("notice.pdf", folder: "Bakshi"), to: "order.pdf")

            XCTAssertFalse(model.actionNotice!.contains("original file type"))
        }
    }

    /// Disk and database moved; the search index did not. Left unsaid, the symptom is the
    /// assistant no longer finding a document that is plainly in the list.
    func testAStaleSearchIndexIsSaidOutLoud() async {
        await withLibrary { _, manager, model in
            manager.renameResult = FileOperationResult(
                fileName: "order.pdf", folderName: "Bakshi", searchIndexStale: true)
            await model.rename(storedFile("notice.pdf", folder: "Bakshi"), to: "order.pdf")

            XCTAssertTrue(model.actionNotice!.contains("Search may not find it"))
        }
    }

    func testRenamingToTheSameNameIsNotARoundTrip() async {
        await withLibrary { _, manager, model in
            await model.rename(storedFile("notice.pdf", folder: "Bakshi"), to: "notice.pdf")
            XCTAssertTrue(manager.renamed.isEmpty)
        }
    }

    func testRenamingToNothingIsRefused() async {
        await withLibrary { _, manager, model in
            await model.rename(storedFile("notice.pdf", folder: "Bakshi"), to: "   ")
            XCTAssertTrue(manager.renamed.isEmpty)
        }
    }

    // MARK: - Starring

    /// The server tests `favorite !== false`, so an absent key stars the document. Unstarring
    /// therefore has to send an explicit `false` — sending nothing does the opposite.
    func testUnstarringSendsAnExplicitFalse() async {
        await withLibrary(files: [storedFile("a.pdf", favorite: true)]) { _, manager, model in
            await model.toggleFavorite(storedFile("a.pdf", favorite: true))
            XCTAssertEqual(manager.favorited.first?.favorite, false)
        }
    }

    func testStarringSendsTrue() async {
        await withLibrary(files: [storedFile("a.pdf", favorite: false)]) { _, manager, model in
            await model.toggleFavorite(storedFile("a.pdf", favorite: false))
            XCTAssertEqual(manager.favorited.first?.favorite, true)
        }
    }

    /// The response carries the state read back out of the database. If it disagrees with what
    /// was asked for, the database is right and the star must show that.
    func testTheStateReadBackFromTheServerWins() async {
        await withLibrary(files: [storedFile("a.pdf", favorite: false)]) { _, manager, model in
            manager.favoriteEcho = false        // asked to star, server says it is not starred
            await model.toggleFavorite(storedFile("a.pdf", favorite: false))

            XCTAssertEqual(model.files.first(where: { $0.name == "a.pdf" })?.favorite, false)
        }
    }

    /// A star is the one edit whose result the response states exactly, so it does not need to
    /// pay for a full storage walk.
    func testStarringDoesNotRefetchTheWholeTree() async {
        await withLibrary(files: [storedFile("a.pdf")]) { treeService, _, model in
            let before = treeService.fetches
            await model.toggleFavorite(storedFile("a.pdf"))
            XCTAssertEqual(treeService.fetches, before)
        }
    }

    // MARK: - Folders

    func testCreatingAFolderThatWouldNotExistIsRefusedLocally() async {
        await withLibrary { _, manager, model in
            await model.createFolder(named: "...")

            XCTAssertTrue(manager.createdFolders.isEmpty, "must not spend a round trip on this")
            XCTAssertNotNil(model.actionError)
        }
    }

    func testCreatingAFolderSaysWhatItWillActuallyBeCalled() async {
        await withLibrary { _, manager, model in
            await model.createFolder(named: "ABC Ltd vs. Bakshi")

            XCTAssertEqual(manager.createdFolders, ["ABC Ltd vs. Bakshi"])
            XCTAssertTrue(model.actionNotice!.contains("ABC_Ltd_vs._Bakshi"))
        }
    }

    func testDeletingAFolderIsSent() async {
        await withLibrary { _, manager, model in
            await model.deleteFolder(named: "Bakshi")
            XCTAssertEqual(manager.deletedFolders, ["Bakshi"])
        }
    }

    /// The confirmation has to say how much goes with it. `delete-folder` is recursive and has
    /// no undo.
    func testTheFolderFileCountIsAvailableForTheConfirmation() async {
        let files = [
            storedFile("a.pdf", folder: "Bakshi"),
            storedFile("b.pdf", folder: "Bakshi"),
            storedFile("c.pdf", folder: "Other"),
        ]
        await withLibrary(files: files) { _, _, model in
            XCTAssertEqual(model.fileCount(inFolder: "Bakshi"), 2)
            XCTAssertEqual(model.fileCount(inFolder: "Other"), 1)
        }
    }

    /// A nested folder's documents go too, so they have to be counted.
    func testNestedFoldersAreCountedInTheConfirmation() async {
        let files = [
            storedFile("a.pdf", folder: "2025"),
            storedFile("b.pdf", folder: "2025/Writs"),
        ]
        await withLibrary(files: files) { _, _, model in
            XCTAssertEqual(model.fileCount(inFolder: "2025"), 2)
        }
    }

    /// A folder whose name is a prefix of another must not claim the other's documents.
    func testAPrefixMatchIsNotMistakenForANestedFolder() async {
        let files = [
            storedFile("a.pdf", folder: "Bakshi"),
            storedFile("b.pdf", folder: "BakshiTwo"),
        ]
        await withLibrary(files: files) { _, _, model in
            XCTAssertEqual(model.fileCount(inFolder: "Bakshi"), 1)
        }
    }

    // MARK: - Selection and modes

    /// A picker with no manager must not offer editing at all.
    func testAPickerWithoutAManagerCannotEdit() async {
        let treeService = FakeTree()
        treeService.nodes = tree([storedFile("a.pdf")])
        let model = await FileLibraryViewModel(service: treeService)
        await model.load()

        let canManage = await model.canManage
        XCTAssertFalse(canManage)
        await model.delete(storedFile("a.pdf"))
        let error = await model.actionError
        XCTAssertNil(error, "a no-op, not a failure")
    }

    /// The selection is the user's, not the server's. Deleting one document must not clear the
    /// files they had already ticked to attach.
    func testAnUnrelatedSelectionSurvivesAnEdit() async {
        let files = [storedFile("a.pdf"), storedFile("b.pdf")]
        await withLibrary(files: files) { treeService, _, model in
            model.selected = ["a.pdf", "b.pdf"]
            // The refetch after the delete no longer contains b.pdf.
            treeService.nodes = tree([storedFile("a.pdf")])
            await model.delete(storedFile("b.pdf"))

            XCTAssertEqual(model.selected, ["a.pdf"])
        }
    }

    /// The edit succeeded; only the refresh failed. The success must still be reported — a
    /// bare "connection lost" would tell someone their document is still there when it is not.
    func testAFailedRefreshDoesNotEraseTheEditsSuccess() async {
        await withLibrary { treeService, _, model in
            treeService.failFromFetch = treeService.fetches + 1
            await model.delete(storedFile("notice.pdf", folder: "Bakshi"))

            XCTAssertNotNil(model.actionNotice, "the deletion did happen and must say so")
            XCTAssertNotNil(model.actionError, "but the list on screen is now stale")
        }
    }

    func testACleanEditReportsNoError() async {
        await withLibrary { _, _, model in
            await model.delete(storedFile("notice.pdf", folder: "Bakshi"))
            XCTAssertNotNil(model.actionNotice)
            XCTAssertNil(model.actionError)
        }
    }
}
