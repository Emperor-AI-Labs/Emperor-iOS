import XCTest
@testable import EmperorCore

// MARK: - Fakes

/// Records every edit, in order, so a test can assert both what was sent and that nothing else
/// was. A deletion that reaches this when it should not have is the failure these tests exist
/// to catch.
private final class RecordingManager: FileManaging, @unchecked Sendable {
    var failure: Error?
    var renameResult: FileOperationResult?
    var favoriteEcho: Bool?
    var renamedFolderPath: String?

    private(set) var calls: [String] = []
    private(set) var deleted: [(name: String, folder: String?)] = []
    private(set) var deletedFolders: [String] = []
    private(set) var favorited: [(value: Bool, name: String, folder: String?)] = []
    private(set) var renamed: [(name: String, folder: String?, to: String)] = []
    private(set) var renamedFolders: [(path: String, to: String)] = []
    private(set) var created: [String] = []
    private(set) var moved: [(name: String, from: String?, to: String?)] = []

    func delete(name: String, folderName: String?) async throws {
        calls.append("delete")
        if let failure { throw failure }
        deleted.append((name, folderName))
    }

    func rename(name: String, in folderName: String?, to newName: String) async throws -> FileOperationResult {
        calls.append("rename")
        if let failure { throw failure }
        renamed.append((name, folderName, newName))
        return renameResult ?? FileOperationResult(fileName: newName, folderName: folderName ?? "")
    }

    func move(name: String, from folderName: String?, to destination: String?) async throws {
        calls.append("move")
        if let failure { throw failure }
        moved.append((name, folderName, destination))
    }

    func setFavorite(_ favorite: Bool, name: String, folderName: String?) async throws -> Bool {
        calls.append("favorite")
        if let failure { throw failure }
        favorited.append((favorite, name, folderName))
        return favoriteEcho ?? favorite
    }

    func createFolder(named path: String) async throws {
        calls.append("createFolder")
        if let failure { throw failure }
        created.append(path)
    }

    func renameFolder(at path: String, to newName: String) async throws -> String {
        calls.append("renameFolder")
        if let failure { throw failure }
        renamedFolders.append((path, newName))
        return renamedFolderPath ?? newName
    }

    func deleteFolder(named path: String) async throws {
        calls.append("deleteFolder")
        if let failure { throw failure }
        deletedFolders.append(path)
    }
}

// MARK: - Builders

private func file(
    _ path: String, modified: String? = nil, favorite: Bool = false
) -> FileNode.StoredFile {
    FileNode.StoredFile(
        name: String(path.split(separator: "/").last ?? ""),
        path: path, size: 1024, modified: modified, status: "ready", favorite: favorite)
}

private func dir(_ path: String, _ children: [FileNode] = []) -> FileNode {
    .folder(FileNode.Folder(
        name: String(path.split(separator: "/").last ?? ""), path: path, files: children))
}

private let matter: [FileNode] = [
    dir("Bakshi", [
        .file(file("Bakshi/Plaint.pdf", modified: "2026-10-02T09:00:00.000Z")),
        .file(file("Bakshi/Reply.pdf", favorite: true)),
        dir("Bakshi/2025", [
            .file(file("Bakshi/2025/Order.pdf")),
            dir("Bakshi/2025/Writs", [.file(file("Bakshi/2025/Writs/WP.pdf"))]),
        ]),
    ]),
    dir("Arora"),
]

/// 3 October 2026, noon in India.
private let fixedNow = Date(timeIntervalSince1970: 1_791_009_000)

@MainActor
private func withMyFiles(
    tree: [FileNode] = matter,
    _ body: @MainActor (FakeFiles, RecordingManager, MyFilesViewModel) async -> Void
) async {
    let files = FakeFiles()
    files.tree = tree
    let manager = RecordingManager()
    let model = MyFilesViewModel(service: files, manager: manager, now: { fixedNow })
    await model.load()
    await body(files, manager, model)
}

// MARK: - The confirmation

final class FileDeletionTests: XCTestCase {

    private func summary(_ path: String, in tree: [FileNode] = matter) -> FolderSummary {
        FileBrowser.folder(at: path, in: tree)!
    }

    /// The confirmation names the document, in the form its row shows it.
    func testADocumentsConfirmationNamesItAndItsFolder() {
        let plan = FileDeletion(file: file("Bakshi_v_State/Final_Order.pdf"))
        XCTAssertEqual(plan.title, "Delete “Final Order.pdf”?")
        XCTAssertTrue(plan.message.contains("from Bakshi v State"))
        XCTAssertTrue(plan.message.contains("cannot be undone"))
        XCTAssertEqual(plan.confirmLabel, "Delete document")
        XCTAssertEqual(plan.documentCount, 1)
    }

    /// A folder deletion takes everything beneath it, so the sentence says how much — the
    /// documents at every depth and the sub-folders they sit in.
    func testAFoldersConfirmationSaysHowManyDocumentsGoWithIt() throws {
        let plan = try XCTUnwrap(FileDeletion(folder: summary("Bakshi")))
        XCTAssertEqual(plan.title, "Delete the folder “Bakshi”?")
        XCTAssertTrue(plan.message.contains("4 documents in 2 sub-folders"), plan.message)
        XCTAssertTrue(plan.message.contains("built from them"))
        XCTAssertEqual(plan.confirmLabel, "Delete 4 documents")
        XCTAssertEqual(plan.documentCount, 4)
    }

    func testOneDocumentIsSingularThroughout() throws {
        let plan = try XCTUnwrap(FileDeletion(folder: summary("Bakshi/2025/Writs")))
        XCTAssertTrue(plan.message.contains("1 document will be"), plan.message)
        XCTAssertFalse(plan.message.contains("sub-folder"), "Writs has none")
        XCTAssertTrue(plan.message.contains("built from it."))
        XCTAssertEqual(plan.confirmLabel, "Delete 1 document")
    }

    /// Never "Delete 0 documents", and never a warning about documents that do not exist.
    func testAnEmptyFolderSaysNothingIsLost() throws {
        let plan = try XCTUnwrap(FileDeletion(folder: summary("Arora")))
        XCTAssertTrue(plan.message.contains("It is empty"))
        XCTAssertEqual(plan.confirmLabel, "Delete folder")
    }

    func testAFolderOfEmptyFoldersSaysSo() throws {
        let tree = [dir("A", [dir("A/B"), dir("A/C")])]
        let plan = try XCTUnwrap(FileDeletion(folder: summary("A", in: tree)))
        XCTAssertTrue(plan.message.contains("2 sub-folders and no documents"), plan.message)
        XCTAssertEqual(plan.confirmLabel, "Delete folder")
    }

    /// The storage root is how `.` and the empty string read on these routes. It is not a folder
    /// anyone made, and no confirmation for it can be built.
    func testTheStorageRootCannotBeOfferedForDeletion() {
        for path in ["", ".", "/", "./", "//"] {
            let root = FolderSummary(
                name: "", path: path, created: nil,
                documentCount: 9, subfolderCount: 3, childFolderCount: 3)
            XCTAssertNil(FileDeletion(folder: root), "\(path) must be refused")
        }
    }
}

// MARK: - The screen

final class MyFilesViewModelTests: XCTestCase {

    // MARK: Loading

    func testSectionsOpenOnRecentAsTheWebDoes() async {
        await withMyFiles { _, _, model in
            XCTAssertEqual(model.section, .recent)
            XCTAssertEqual(MyFilesViewModel.Section.allCases.map(\.title), ["Recent", "Folders", "Favorites"])
        }
    }

    /// "We could not ask" must never render as "you have nothing".
    func testAFailedLoadIsNotAnEmptyLibrary() async {
        let files = FakeFiles()
        files.treeError = APIError.transport("The Internet connection appears to be offline.")
        let model = await MyFilesViewModel(service: files, manager: RecordingManager())
        await model.load()

        let presentation = await model.presentation(for: .recent)
        XCTAssertTrue(presentation.showsFailureState)
        XCTAssertFalse(presentation.showsEmptyState)
    }

    func testAFailedRefreshKeepsTheLibraryOnScreen() async {
        await withMyFiles { files, _, model in
            files.treeError = APIError.transport("The network connection was lost.")
            await model.load()

            XCTAssertTrue(model.presentation(for: .folders).showsStaleBanner)
            XCTAssertEqual(model.listing(at: "")?.folders.count, 2)
        }
    }

    func testAnEmptyLibraryIsEmptyOnlyOnceTheServerHasSaidSo() async {
        let files = FakeFiles()
        let model = await MyFilesViewModel(service: files, manager: RecordingManager())
        let before = await model.presentation(for: .folders)
        XCTAssertFalse(before.showsEmptyState, "nothing has been asked yet")
        await model.load()
        let after = await model.presentation(for: .folders)
        XCTAssertTrue(after.showsEmptyState)
    }

    /// The library has documents; the search matched none. A different sentence.
    func testNoSearchMatchIsNotAnEmptyLibrary() async {
        await withMyFiles { _, _, model in
            model.query = "zzz"
            XCTAssertTrue(model.presentation(for: .recent).showsEmptyState)
            XCTAssertTrue(model.showsNoSearchResults(in: .recent))
            XCTAssertTrue(model.showsNoSearchResults(in: .favorites))
            model.query = ""
            XCTAssertFalse(model.showsNoSearchResults(in: .recent))
        }
    }

    func testNothingStarredIsSaidAsSuch() async {
        await withMyFiles(tree: [dir("A", [.file(file("A/x.pdf"))])]) { _, _, model in
            XCTAssertTrue(model.presentation(for: .favorites).showsEmptyState)
            XCTAssertFalse(model.showsNoSearchResults(in: .favorites))
            XCTAssertEqual(model.emptyCopy(for: .favorites).title, "Nothing starred yet")
        }
    }

    /// A folder deleted on the web while its screen was open is gone, not empty.
    func testAFolderThatVanishedIsNotDescribedAsEmpty() async {
        await withMyFiles { _, _, model in
            XCTAssertEqual(model.emptyCopy(forFolder: "Arora").title, "This folder is empty")
            XCTAssertEqual(model.emptyCopy(forFolder: "Gone").title, "This folder is no longer here")
        }
    }

    func testDatesAreLabelledAgainstIndiasDay() async {
        await withMyFiles { _, _, model in
            XCTAssertEqual(model.dateLabel(for: file("a.pdf", modified: "2026-10-02T09:00:00.000Z")), "Yesterday")
            XCTAssertEqual(model.dateLabel(for: file("a.pdf", modified: "2026-10-02T19:00:00.000Z")), "Today")
            XCTAssertNil(model.dateLabel(for: file("a.pdf")), "no date is no label, not a guess")
        }
    }

    // MARK: Deleting

    /// Asking does nothing on its own. Only confirming sends.
    func testRequestingADeletionSendsNothing() async {
        await withMyFiles { _, manager, model in
            model.requestDeletion(of: file("Bakshi/Plaint.pdf"))
            XCTAssertNotNil(model.pendingDeletion)
            model.cancelDeletion()
            await model.confirmDeletion()
            XCTAssertTrue(manager.calls.isEmpty)
        }
    }

    /// `delete-file` answers 200 whether or not the file was there, so the library is re-read
    /// rather than patched.
    func testConfirmingADocumentDeletesItAndRefetches() async {
        await withMyFiles { files, manager, model in
            let before = files.treeCallCount
            model.requestDeletion(of: file("Bakshi/Plaint.pdf"))
            await model.confirmDeletion()

            XCTAssertEqual(manager.deleted.map(\.name), ["Plaint.pdf"])
            XCTAssertEqual(manager.deleted.first?.folder, "Bakshi")
            XCTAssertEqual(files.treeCallCount, before + 1)
            XCTAssertNil(model.pendingDeletion)
            XCTAssertEqual(model.actionNotice, "Plaint.pdf was deleted.")
        }
    }

    /// A document at the top level has no folder, and the service spells the root for the route.
    func testALooseDocumentIsSentWithNoFolder() async {
        await withMyFiles(tree: [.file(file("Loose.pdf"))]) { _, manager, model in
            model.requestDeletion(of: file("Loose.pdf"))
            await model.confirmDeletion()
            XCTAssertEqual(manager.deleted.first?.folder, "")
        }
    }

    func testConfirmingAFolderDeletesItByPathAndRefetches() async {
        await withMyFiles { files, manager, model in
            let before = files.treeCallCount
            model.requestDeletion(of: model.folder(at: "Bakshi/2025")!)
            await model.confirmDeletion()

            XCTAssertEqual(manager.deletedFolders, ["Bakshi/2025"])
            XCTAssertEqual(files.treeCallCount, before + 1)
            XCTAssertEqual(model.actionNotice, "2025 and the 2 documents in it were deleted.")
        }
    }

    /// An alert clears its binding after the button's action runs, so the plan has to survive
    /// `pendingDeletion` being cleared before the deletion starts.
    func testAPlanCapturedBeforeTheAlertClosesIsStillCarriedOut() async {
        await withMyFiles { _, manager, model in
            model.requestDeletion(of: file("Bakshi/Plaint.pdf"))
            let plan = model.pendingDeletion!
            model.cancelDeletion()          // what the alert's binding does as it closes
            await model.confirm(plan)
            XCTAssertEqual(manager.deleted.map(\.name), ["Plaint.pdf"])
        }
    }

    /// The count is taken when the user asks, from the tree as it is then — not from whatever
    /// summary the row was drawn with.
    func testTheConfirmationCountsTheLiveTree() async {
        await withMyFiles { _, _, model in
            let stale = FolderSummary(
                name: "Bakshi", path: "Bakshi", created: nil,
                documentCount: 1, subfolderCount: 0, childFolderCount: 0)
            model.requestDeletion(of: stale)
            XCTAssertEqual(model.pendingDeletion?.documentCount, 4)
        }
    }

    /// The last line of defence before a recursive deletion: the root never reaches the server,
    /// however the request was built.
    func testTheRootIsNeverSentForDeletion() async {
        await withMyFiles { _, manager, model in
            let root = FolderSummary(
                name: "", path: ".", created: nil,
                documentCount: 4, subfolderCount: 3, childFolderCount: 2)
            model.requestDeletion(of: root)
            XCTAssertNil(model.pendingDeletion)
            await model.confirmDeletion()
            XCTAssertTrue(manager.calls.isEmpty)
        }
    }

    /// A refusal is reported, and the library is still re-read: after a failure part-way through
    /// a folder, what is left is only known by asking.
    func testAFailedDeletionIsReportedAndStillRefetches() async {
        await withMyFiles { files, manager, model in
            manager.failure = APIError.server(status: 403, message: "You do not have access to that account’s data")
            let before = files.treeCallCount
            model.requestDeletion(of: file("Bakshi/Plaint.pdf"))
            await model.confirmDeletion()

            XCTAssertEqual(model.actionError, "You do not have access to that account’s data")
            XCTAssertNil(model.actionNotice)
            XCTAssertEqual(files.treeCallCount, before + 1)
        }
    }

    // MARK: Starring

    /// `favorite-file` stars anything that is not an explicit `false`. Unstarring has to send
    /// `false`; sending nothing would star it.
    func testUnstarringSendsAnExplicitFalse() async {
        await withMyFiles { _, manager, model in
            await model.toggleFavorite(file("Bakshi/Reply.pdf", favorite: true))
            XCTAssertEqual(manager.favorited.first?.value, false)
            XCTAssertEqual(manager.favorited.first?.folder, "Bakshi")
        }
    }

    func testStarringSendsTrueAndShowsWhatTheServerStored() async {
        await withMyFiles { files, manager, model in
            let before = files.treeCallCount
            await model.toggleFavorite(file("Bakshi/2025/Order.pdf"))
            XCTAssertEqual(manager.favorited.first?.value, true)
            XCTAssertEqual(manager.favorited.first?.folder, "Bakshi/2025")
            XCTAssertTrue(model.favorites.contains { $0.path == "Bakshi/2025/Order.pdf" })
            XCTAssertEqual(files.treeCallCount, before, "a star's answer is exact; no tree walk")
        }
    }

    /// The database is right. If it disagrees with what was asked, the star shows the database.
    func testTheStoredValueWinsOverTheRequestedOne() async {
        await withMyFiles { _, manager, model in
            manager.favoriteEcho = false
            await model.toggleFavorite(file("Bakshi/2025/Order.pdf"))
            XCTAssertFalse(model.favorites.contains { $0.path == "Bakshi/2025/Order.pdf" })
        }
    }

    // MARK: Renaming

    /// The name typed is a request. The one shown is the one the server echoed.
    func testARenameShowsTheEchoedName() async {
        await withMyFiles { files, manager, model in
            manager.renameResult = FileOperationResult(fileName: "Written_Statement.pdf", folderName: "Bakshi")
            let before = files.treeCallCount
            await model.rename(file("Bakshi/Reply.pdf"), to: "Written Statement")

            XCTAssertEqual(manager.renamed.first?.to, "Written Statement")
            XCTAssertEqual(model.actionNotice, "Saved as Written_Statement.pdf — the original file type is kept.")
            XCTAssertEqual(files.treeCallCount, before + 1)
        }
    }

    func testRenamingToTheSameNameOrToNothingSendsNothing() async {
        await withMyFiles { _, manager, model in
            await model.rename(file("Bakshi/Reply.pdf"), to: "Reply.pdf")
            await model.rename(file("Bakshi/Reply.pdf"), to: "   ")
            XCTAssertTrue(manager.calls.isEmpty)
        }
    }

    func testAFolderRenameShowsTheServersName() async {
        await withMyFiles { _, manager, model in
            manager.renamedFolderPath = "Bakshi/Writ_Petitions"
            await model.renameFolder(model.folder(at: "Bakshi/2025")!, to: "Writ Petitions")
            XCTAssertEqual(manager.renamedFolders.first?.path, "Bakshi/2025")
            XCTAssertEqual(model.actionNotice, "Saved as Writ_Petitions.")
        }
    }

    /// A slash would move the folder rather than rename it, and the server refuses it.
    func testAFolderRenameWithASlashIsRefusedLocally() async {
        await withMyFiles { _, manager, model in
            await model.renameFolder(model.folder(at: "Arora")!, to: "2026/Arora")
            XCTAssertTrue(manager.calls.isEmpty)
            XCTAssertNotNil(model.actionError)
        }
    }

    // MARK: Folders and moving

    func testANewFolderIsMadeInsideTheFolderOnScreen() async {
        await withMyFiles { _, manager, model in
            await model.createFolder(named: "Interim orders", in: "Bakshi/2025")
            XCTAssertEqual(manager.created, ["Bakshi/2025/Interim orders"])
            XCTAssertEqual(model.actionNotice, "Created as Interim_orders.")
        }
    }

    func testANewFolderAtTheTopIsMadeAtTheTop() async {
        await withMyFiles { _, manager, model in
            await model.createFolder(named: "Kapoor", in: "")
            XCTAssertEqual(manager.created, ["Kapoor"])
        }
    }

    func testAnUncreatableFolderNameIsRefusedLocally() async {
        await withMyFiles { _, manager, model in
            await model.createFolder(named: "...", in: "Bakshi")
            XCTAssertTrue(manager.calls.isEmpty)
            XCTAssertNotNil(model.actionError)
        }
    }

    func testMovingSendsBothFoldersAndRefetches() async {
        await withMyFiles { files, manager, model in
            let before = files.treeCallCount
            await model.move(file("Bakshi/Plaint.pdf"), to: model.folder(at: "Arora")!)
            XCTAssertEqual(manager.moved.first?.from, "Bakshi")
            XCTAssertEqual(manager.moved.first?.to, "Arora")
            XCTAssertEqual(model.actionNotice, "Moved Plaint.pdf to Arora.")
            XCTAssertEqual(files.treeCallCount, before + 1)
        }
    }

    /// A document's own folder is not somewhere to move it to, and neither is the root.
    func testMoveDestinationsLeaveOutWhereItAlreadyIs() async {
        await withMyFiles { _, _, model in
            let destinations = model.moveDestinations(for: file("Bakshi/Plaint.pdf")).map(\.path)
            XCTAssertFalse(destinations.contains("Bakshi"))
            XCTAssertFalse(destinations.contains(""))
            XCTAssertTrue(destinations.contains("Bakshi/2025"))
        }
    }

    // MARK: Sharing

    func testSharingHandsOverTheDocumentsOwnBytesUnderItsOwnName() async {
        await withMyFiles { files, _, model in
            files.data["Plaint.pdf"] = Data("%PDF-1.7".utf8)
            await model.prepareShare(file("Bakshi/Plaint.pdf"))
            XCTAssertEqual(model.sharing?.fileName, "Plaint.pdf")
            XCTAssertEqual(model.sharing?.data, Data("%PDF-1.7".utf8))
        }
    }

    func testAFailedFetchIsReportedRatherThanSharingNothing() async {
        await withMyFiles { files, _, model in
            files.dataError = APIError.server(status: 404, message: "That document is no longer in your library.")
            await model.prepareShare(file("Bakshi/Plaint.pdf"))
            XCTAssertNil(model.sharing)
            XCTAssertEqual(model.actionError, "That document is no longer in your library.")
        }
    }

    // MARK: Uploading

    /// Inside a folder, into it; at the top, into the picker's own folder, because the web does
    /// not file a loose document at the root.
    func testUploadsLandInTheFolderOnScreen() {
        XCTAssertEqual(MyFilesViewModel.uploadDestination(for: "Bakshi/2025"), "Bakshi/2025")
        XCTAssertEqual(MyFilesViewModel.uploadDestination(for: ""), FileLibraryViewModel.uploadFolder)
        XCTAssertEqual(MyFilesViewModel.uploadDestination(for: "/"), FileLibraryViewModel.uploadFolder)
    }

    func testAFinishedUploadRereadsTheLibrary() async {
        await withMyFiles { files, _, model in
            let before = files.treeCallCount
            await model.uploadDidFinish()
            XCTAssertEqual(files.treeCallCount, before + 1)
        }
    }
}
