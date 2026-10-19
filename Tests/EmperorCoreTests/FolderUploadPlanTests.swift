import XCTest
@testable import EmperorCore

/// `UploadJunk` and `FolderUploadPlan.destination` held to the platform's own JavaScript.
///
/// `Resources/upload-folder/upload-folder.json` is produced by running `src/lib/junkNames.js` and
/// `src/lib/uploadDuplicates.js` under Node (`scripts/generate-upload-junk-fixtures.mjs`). When
/// this fails after a platform change, regenerate the fixture and bring the Swift to it.
final class UploadFolderGoldenTests: XCTestCase {

    private struct Fixture: Decodable {
        struct Junk: Decodable {
            let path: String
            let isJunkPath: Bool
            let pathReason: String?
            let isJunkName: Bool
            let nameReason: String?
        }
        struct Destination: Decodable {
            let relativePath: String
            let name: String
            let folder: String
            let folderName: String
            let fileName: String
        }
        struct Norm: Decodable {
            let raw: String
            let normalized: String
        }
        let junk: [Junk]
        let destinations: [Destination]
        let normFolder: [Norm]
    }

    private func fixture() throws -> Fixture {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "upload-folder", withExtension: "json", subdirectory: "upload-folder"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    func testJunkIsRecognisedExactlyAsTheWebRecognisesIt() throws {
        let cases = try fixture().junk
        XCTAssertGreaterThan(cases.count, 20)
        for item in cases {
            XCTAssertEqual(UploadJunk.isJunkPath(item.path), item.isJunkPath, item.path.debugDescription)
            XCTAssertEqual(UploadJunk.pathReason(item.path), item.pathReason, item.path.debugDescription)
            XCTAssertEqual(UploadJunk.isJunkName(item.path), item.isJunkName, item.path.debugDescription)
            XCTAssertEqual(UploadJunk.nameReason(item.path), item.nameReason, item.path.debugDescription)
        }
    }

    func testEachFileLandsWhereTheWebWouldPutIt() throws {
        for item in try fixture().destinations {
            let got = FolderUploadPlan.destination(
                forRelativePath: item.relativePath, name: item.name, in: item.folder)
            XCTAssertEqual(got.folderName, item.folderName, item.relativePath)
            XCTAssertEqual(got.fileName, item.fileName, item.relativePath)
        }
    }

    func testFolderNamesCompareAsTheWebComparesThem() throws {
        for item in try fixture().normFolder {
            XCTAssertEqual(FolderUploadPlan.normFolder(item.raw), item.normalized, item.raw)
        }
    }
}

final class FolderUploadPlanTests: XCTestCase {

    private func source(_ path: String, _ size: Int = 1_000) -> FolderUploadPlan.Source {
        FolderUploadPlan.Source(relativePath: path, size: size)
    }

    func testTheFoldersStructureIsKeptUnderTheDestination() {
        let plan = FolderUploadPlan(sources: [
            source("Wadhwa/Plaint.pdf", 2_000),
            source("Wadhwa/Orders/2025-01-04.pdf", 3_000),
            source("Wadhwa/Orders/Interim/Stay.docx", 500),
        ], destination: "Clients")

        XCTAssertEqual(plan.destination, "Clients")
        XCTAssertEqual(plan.pickedFolderName, "Wadhwa")
        XCTAssertEqual(plan.entries.map(\.folderName), [
            "Clients/Wadhwa", "Clients/Wadhwa/Orders", "Clients/Wadhwa/Orders/Interim",
        ])
        XCTAssertEqual(plan.entries.map(\.fileName), ["Plaint.pdf", "2025-01-04.pdf", "Stay.docx"])
        XCTAssertEqual(plan.totalBytes, 5_500)
        XCTAssertEqual(plan.folderNames.count, 3)
        // None lands directly in Clients: the picked folder keeps its own name.
        XCTAssertEqual(plan.entries.map(\.isTopLevel), [false, false, false])
    }

    /// At the top level a folder brings its own name, and lands under it.
    func testAtTheTopLevelTheFolderLandsUnderItsOwnName() {
        let plan = FolderUploadPlan(sources: [
            source("Wadhwa/Plaint.pdf"),
            source("Wadhwa/Orders/Order.pdf"),
        ], destination: "")

        XCTAssertEqual(plan.destination, "Wadhwa")
        XCTAssertEqual(plan.entries.map(\.folderName), ["Wadhwa", "Wadhwa/Orders"])
        XCTAssertEqual(plan.entries.map(\.isTopLevel), [true, false])
        XCTAssertTrue(plan.confirmMessage.contains("a new folder at the top of My Files"))
    }

    /// Re-dropping a folder onto a folder of the same name does not nest it inside itself.
    func testDroppingAFolderOntoItsNamesakeDoesNotNestIt() {
        let plan = FolderUploadPlan(
            sources: [source("Wadhwa/Plaint.pdf")], destination: "Clients/Wadhwa")
        XCTAssertEqual(plan.entries.first?.folderName, "Clients/Wadhwa")
        XCTAssertEqual(plan.entries.first?.isTopLevel, true)
    }

    func testJunkIsDroppedWithoutAWord() {
        let plan = FolderUploadPlan(sources: [
            source("Wadhwa/.DS_Store"),
            source("Wadhwa/._Plaint.pdf"),
            source("Wadhwa/__MACOSX/Plaint.pdf"),
            source("Wadhwa/Thumbs.db"),
            source("Wadhwa/Plaint.pdf"),
        ], destination: "Clients")

        XCTAssertEqual(plan.entries.map(\.relativePath), ["Wadhwa/Plaint.pdf"])
        XCTAssertEqual(plan.junkCount, 4)
        XCTAssertTrue(plan.skipped.isEmpty)
        XCTAssertNil(plan.skippedNotice)
    }

    /// A junk directory never names the picked folder.
    func testThePickedFolderIsNamedByAFileThatIsNotJunk() {
        let plan = FolderUploadPlan(sources: [
            source("__MACOSX/Wadhwa/._Plaint.pdf"),
            source("Wadhwa/Plaint.pdf"),
        ], destination: "")
        XCTAssertEqual(plan.pickedFolderName, "Wadhwa")
    }

    func testWhatCannotGoIsSaidAndCounted() {
        let plan = FolderUploadPlan(sources: [
            source("Wadhwa/notes.exe"),
            source("Wadhwa/Huge.pdf", FolderUploadPlan.maxFileBytes + 1),
            source("Wadhwa/Plaint.pdf"),
            source("Wadhwa/README"),
            source("Wadhwa/Scan.tiff"),
        ], destination: "Clients")

        XCTAssertEqual(plan.entries.map(\.fileName), ["Plaint.pdf"])
        XCTAssertEqual(plan.skipped.map(\.reason), [.unsupportedType, .tooLarge, .unsupportedType, .unsupportedType])
        XCTAssertEqual(
            plan.skippedNotice,
            "4 files were left out: notes.exe (not a type the library holds), Huge.pdf (over 500 MB), "
                + "README (not a type the library holds) and 1 more.")
    }

    func testNoMoreThanTwoHundredFilesGoInOneUpload() {
        let sources = (0..<205).map { source(String(format: "Wadhwa/Doc%03d.pdf", $0)) }
        let plan = FolderUploadPlan(sources: sources, destination: "Clients")
        XCTAssertEqual(plan.entries.count, FolderUploadPlan.maxFileCount)
        XCTAssertEqual(plan.skipped.count, 5)
        XCTAssertTrue(plan.skipped.allSatisfy { $0.reason == .overLimit })
        XCTAssertEqual(plan.skipped.first?.fileName, "Doc200.pdf")
    }

    func testAnEmptyFolderSaysSo() {
        XCTAssertEqual(
            FolderUploadPlan(sources: [], destination: "Clients").emptyMessage,
            "That folder has no documents in it.")
        let onlyOdd = FolderUploadPlan(sources: [source("Wadhwa/a.exe")], destination: "Clients")
        XCTAssertTrue(onlyOdd.isEmpty)
        XCTAssertEqual(
            onlyOdd.emptyMessage,
            "Nothing in that folder can go into the library. 1 file was left out: a.exe (not a type the library holds).")
    }

    func testTheConfirmationNamesTheCountThePlaceAndTheSize() {
        let plan = FolderUploadPlan(sources: [
            source("Wadhwa_Matter/Plaint.pdf", 1024 * 1024),
            source("Wadhwa_Matter/Orders/Order.pdf", 1024 * 1024),
        ], destination: "Clients/Active_Matters")
        XCTAssertEqual(plan.confirmTitle, "Upload “Wadhwa Matter”?")
        XCTAssertEqual(
            plan.confirmMessage,
            "2 documents across 2 folders will be uploaded to Clients / Active Matters, keeping the "
                + "folder’s structure. 2.0 MB in all.")
        XCTAssertEqual(plan.confirmLabel, "Upload 2")
        XCTAssertEqual(plan.folderByRelativePath["Wadhwa_Matter/Orders/Order.pdf"], "Clients/Active_Matters/Wadhwa_Matter/Orders")
    }

    // MARK: - The duplicate question

    private func result(
        hash: String, status: DuplicateCheck.Status, heldIn: [DuplicateCheck.Placement]? = nil,
        conflict: DuplicateCheck.Conflict? = nil
    ) -> DuplicateCheck.Result {
        DuplicateCheck.Result(name: "x", hash: hash, status: status, heldIn: heldIn, nameConflict: conflict)
    }

    private func stored(_ path: String, size: Int? = 10) -> FileNode.StoredFile {
        FileNode.StoredFile(
            name: String(path.split(separator: "/").last!), path: path, size: size,
            modified: nil, status: "ready", progress: nil, favorite: nil)
    }

    /// The server's "would replace" is trusted only for a file that lands directly in the
    /// destination, as the web trusts it.
    func testAServerNameClashCountsOnlyForAFileLandingInTheDestination() {
        let plan = FolderUploadPlan(sources: [
            source("Wadhwa/Plaint.pdf"),
            source("Wadhwa/Orders/Order.pdf"),
        ], destination: "")
        let conflict = DuplicateCheck.Conflict(folder: "Wadhwa", fileName: "Plaint.pdf", size: 9)
        let decisions = plan.decisions(
            hashes: ["a", "b"],
            results: [
                result(hash: "a", status: .nameConflict, conflict: conflict),
                result(hash: "b", status: .nameConflict, conflict: conflict),
            ],
            existing: [])
        XCTAssertEqual(decisions, [.wouldOverwrite(conflict), .upload])
    }

    /// Below the destination, the library as last read says whether a document of that name is
    /// already in that very folder.
    func testBelowTheDestinationTheLibraryShowsANameClash() {
        let plan = FolderUploadPlan(sources: [
            source("Wadhwa/Orders/Order 1.pdf"),
            source("Wadhwa/Orders/Order 2.pdf"),
        ], destination: "Clients")
        let decisions = plan.decisions(
            hashes: [nil, "b"], results: [],
            existing: [stored("Clients/Wadhwa/Orders/Order_1.pdf", size: 44), stored("Clients/Order_2.pdf")])
        XCTAssertEqual(decisions, [
            .wouldOverwrite(DuplicateCheck.Conflict(
                folder: "Clients/Wadhwa/Orders", fileName: "Order_1.pdf", size: 44)),
            .upload,
        ])
    }

    /// The same bytes filed anywhere are asked about wherever the new copy lands.
    func testACopyAlreadyFiledIsAskedAboutAtAnyDepth() {
        let plan = FolderUploadPlan(sources: [source("Wadhwa/Orders/Order.pdf")], destination: "Clients")
        let placement = DuplicateCheck.Placement(folder: "Bakshi", fileName: "Order.pdf")
        let decisions = plan.decisions(
            hashes: ["a"], results: [result(hash: "a", status: .duplicate, heldIn: [placement])],
            existing: [stored("Clients/Wadhwa/Orders/Order.pdf")])
        XCTAssertEqual(decisions, [.alreadyHeld([placement])])
    }

    /// A failed check asks nothing and uploads everything.
    func testAFailedCheckBlocksNothing() {
        let plan = FolderUploadPlan(sources: [
            source("Wadhwa/Plaint.pdf"), source("Wadhwa/Orders/Order.pdf"),
        ], destination: "Clients")
        XCTAssertEqual(
            plan.decisions(hashes: [nil, nil], results: [], existing: []),
            [.upload, .upload])
    }
}
