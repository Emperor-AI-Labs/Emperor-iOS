import XCTest
@testable import EmperorCore

// MARK: - Stand-ins

/// A matter whose only content is its files.
private final class MatterWithFiles: ProjectProviding, @unchecked Sendable {
    var files: [FileNode] = []
    private(set) var fileLoads = 0

    func projects(includeArchived: Bool) async throws -> [Project] { [] }
    func project(id: String) async throws -> ProjectDetail {
        throw APIError.server(status: 404, message: ProjectService.projectGoneMessage)
    }
    func projectFiles(projectID: String) async throws -> [FileNode] {
        fileLoads += 1
        return files
    }
}

/// Records the edits sent for a matter's documents.
private final class MatterFileEdits: FileManaging, @unchecked Sendable {
    var failure: Error?
    var renameEcho: String?
    private(set) var deleted: [(name: String, folder: String?)] = []
    private(set) var renamed: [(name: String, folder: String?, to: String)] = []

    func delete(name: String, folderName: String?) async throws {
        if let failure { throw failure }
        deleted.append((name, folderName))
    }
    func rename(name: String, in folderName: String?, to newName: String) async throws -> FileOperationResult {
        if let failure { throw failure }
        renamed.append((name, folderName, newName))
        return FileOperationResult(fileName: renameEcho ?? newName, folderName: folderName ?? "")
    }
    func move(name: String, from folderName: String?, to destination: String?) async throws { XCTFail("no move from a matter") }
    func setFavorite(_ favorite: Bool, name: String, folderName: String?) async throws -> Bool { favorite }
    func createFolder(named path: String) async throws { XCTFail("no folder from here") }
    func renameFolder(at path: String, to newName: String) async throws -> String { newName }
    func deleteFolder(named path: String) async throws { XCTFail("no folder deletion from here") }
}

private func matterFile(_ path: String) -> FileNode.StoredFile {
    FileNode.StoredFile(
        name: String(path.split(separator: "/").last ?? ""), path: path, size: 10,
        modified: nil, status: "ready", progress: nil, favorite: nil)
}

private let plaint = matterFile("_projects/prj_1/Pleadings/Plaint.pdf")
private let loose = matterFile("_projects/prj_1/Note.pdf")

@MainActor
private func withMatter(
    manager: MatterFileEdits? = MatterFileEdits(),
    _ body: @MainActor (ProjectDetailViewModel, MatterWithFiles, MatterFileEdits?) async -> Void
) async {
    let matter = MatterWithFiles()
    matter.files = [
        .folder(FileNode.Folder(
            name: "Pleadings", path: "_projects/prj_1/Pleadings", created: nil, files: [.file(plaint)])),
        .file(loose),
    ]
    let model = ProjectDetailViewModel(projectID: "prj_1", service: matter, fileManager: manager)
    await model.loadFiles()
    await body(model, matter, manager)
}

// MARK: - Tests

final class MatterFileEditTests: XCTestCase {

    /// The confirmation speaks of the matter, as the web's matter Files section does.
    func testTheConfirmationIsWordedForTheMatter() {
        let plan = FileDeletion(matterFile: plaint)
        XCTAssertEqual(plan.title, "Delete “Plaint.pdf”?")
        XCTAssertEqual(
            plan.message,
            "It will be permanently deleted from this matter, with the text and search index built "
                + "from it. Conversations that already quoted it keep what they said. This cannot be undone.")
        XCTAssertEqual(plan.confirmLabel, "Delete document")
        XCTAssertEqual(plan.doneNotice, "Plaint.pdf was deleted.")
        // My Files' own wording is untouched.
        XCTAssertFalse(FileDeletion(file: plaint).message.contains("this matter"))
    }

    /// Deleted by the folder the matter lists it in, then the matter's files are read again.
    func testADeletionIsAddressedByTheMattersFolder() async {
        await withMatter { model, matter, manager in
            XCTAssertTrue(model.offersFileEditing)
            let loadsBefore = matter.fileLoads
            model.requestDeletion(of: plaint)
            let plan = try! XCTUnwrap(model.pendingFileDeletion)
            await model.confirmFileDeletion(plan)

            XCTAssertEqual(manager?.deleted.first?.name, "Plaint.pdf")
            XCTAssertEqual(manager?.deleted.first?.folder, "_projects/prj_1/Pleadings")
            XCTAssertNil(model.pendingFileDeletion)
            XCTAssertEqual(model.notice, "Plaint.pdf was deleted.")
            XCTAssertNil(model.writeError)
            XCTAssertEqual(matter.fileLoads, loadsBefore + 1)
            XCTAssertFalse(model.isWriting)
        }
    }

    func testADocumentAtTheMattersRootIsAddressedByTheMattersOwnFolder() async {
        await withMatter { model, _, manager in
            await model.confirmFileDeletion(FileDeletion(matterFile: loose))
            XCTAssertEqual(manager?.deleted.first?.folder, "_projects/prj_1")
        }
    }

    /// The name said afterwards is the one the server stored.
    func testARenameSaysTheStoredName() async {
        let manager = MatterFileEdits()
        manager.renameEcho = "Amended_Plaint.pdf"
        await withMatter(manager: manager) { model, matter, _ in
            let loadsBefore = matter.fileLoads
            await model.renameFile(plaint, to: "  Amended Plaint  ")
            XCTAssertEqual(manager.renamed.first?.name, "Plaint.pdf")
            XCTAssertEqual(manager.renamed.first?.folder, "_projects/prj_1/Pleadings")
            XCTAssertEqual(manager.renamed.first?.to, "Amended Plaint")
            XCTAssertEqual(model.notice, "Saved as Amended_Plaint.pdf — the original file type is kept.")
            XCTAssertEqual(matter.fileLoads, loadsBefore + 1)
        }
    }

    func testAnUnchangedNameSendsNothing() async {
        await withMatter { model, _, manager in
            await model.renameFile(plaint, to: "Plaint.pdf")
            await model.renameFile(plaint, to: "   ")
            XCTAssertEqual(manager?.renamed.count, 0)
        }
    }

    /// A refusal is said, and the files are still read again — the server is the record.
    func testARefusalIsSaidAndTheListIsReadAgain() async {
        let manager = MatterFileEdits()
        manager.failure = APIError.server(
            status: 409, message: "\"Plaint.pdf\" already exists in that folder — refusing to overwrite it")
        await withMatter(manager: manager) { model, matter, _ in
            let loadsBefore = matter.fileLoads
            await model.renameFile(loose, to: "Plaint")
            XCTAssertEqual(
                model.writeError,
                "\"Plaint.pdf\" already exists in that folder — refusing to overwrite it")
            XCTAssertNil(model.notice)
            XCTAssertEqual(matter.fileLoads, loadsBefore + 1)
        }
    }

    func testWithoutTheFileServiceNothingIsOffered() async {
        await withMatter(manager: nil) { model, _, _ in
            XCTAssertFalse(model.offersFileEditing)
            model.requestDeletion(of: plaint)
            XCTAssertNil(model.pendingFileDeletion)
        }
    }
}
