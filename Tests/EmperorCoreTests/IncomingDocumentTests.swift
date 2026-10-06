import XCTest
@testable import EmperorCore

/// Documents handed to the app from the share sheet or "Open in…": the name they are saved
/// under, the queue they wait in, and the sheet that files them.
@MainActor
final class IncomingDocumentTests: XCTestCase {

    /// A directory of this test's own, so no two tests — or two runs — share a store.
    nonisolated private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("IncomingDocumentTests-\(UUID().uuidString)", isDirectory: true)

    override func setUp() {
        super.setUp()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private var store: IncomingDocumentStore {
        IncomingDocumentStore(directory: root.appendingPathComponent("Store", isDirectory: true))
    }

    /// A file somewhere the system might have put it, with some bytes in it.
    private func handedOver(_ name: String, in folder: String = "Inbox", bytes: String = "%PDF-1.4") -> URL {
        let directory = root.appendingPathComponent(folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try? Data(bytes.utf8).write(to: url)
        return url
    }

    // MARK: - Naming

    func testTheNameAndTheTypeAreSplitAtTheLastDot() async {
        XCTAssertEqual(IncomingDocumentName.split("Order.final.pdf").base, "Order.final")
        XCTAssertEqual(IncomingDocumentName.split("Order.final.pdf").ext, "pdf")
        XCTAssertEqual(IncomingDocumentName.split("README").ext, "")
        XCTAssertEqual(IncomingDocumentName.split(".pdf").base, ".pdf", "a leading dot is a name")
    }

    /// The type is kept whatever the name becomes, and a HEIC photo becomes a JPEG on the way.
    func testTheTypeIsKeptAndHEICBecomesJPEG() async {
        XCTAssertEqual(IncomingDocumentName.uploadExtension(for: "Plaint.docx"), "docx")
        XCTAssertEqual(IncomingDocumentName.uploadExtension(for: "IMG_0042.HEIC"), "jpg")
        XCTAssertEqual(IncomingDocumentName.uploadExtension(for: "scan.heif"), "jpg")
        XCTAssertTrue(IncomingDocumentName.needsConversion("IMG_0042.HEIC"))
        XCTAssertFalse(IncomingDocumentName.needsConversion("photo.jpeg"))
        XCTAssertEqual(IncomingDocumentName.fileName(base: "  Vakalatnama ", ext: "pdf"), "Vakalatnama.pdf")
    }

    /// Spaces become underscores on the server and read back as spaces — no notice for those.
    /// Anything else the server will change is said before saving.
    func testWhatTheServerWillChangeIsSaidOnlyWhenItMatters() async {
        XCTAssertNil(IncomingDocumentName.savedAsNotice(for: "Interim Order.pdf"))
        XCTAssertNil(IncomingDocumentName.savedAsNotice(for: "Interim_Order-2.pdf"))
        XCTAssertEqual(
            IncomingDocumentName.savedAsNotice(for: "Order (final).pdf"),
            "It will be saved as Order__final_.pdf.")
    }

    // MARK: - Waiting on disk

    /// What iOS puts in the app's inbox is the app's to move; it is not left behind there.
    func testAnInboxCopyIsMovedIntoTheStore() async throws {
        let source = handedOver("Order.pdf")
        let document = try store.adopt(source, moving: true, now: Date(), sequence: 1)

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: document.url.path))
        XCTAssertEqual(document.originalName, "Order.pdf")
        XCTAssertEqual(try Data(contentsOf: document.url), Data("%PDF-1.4".utf8))
    }

    /// Anything not the app's own is copied, never moved — moving it would take it from its
    /// owner.
    func testAFileThatIsNotOursIsCopiedNotMoved() async throws {
        let source = handedOver("Order.pdf", in: "SomeoneElses")
        let document = try store.adopt(source, moving: false, now: Date(), sequence: 1)

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "the original stays")
        XCTAssertTrue(FileManager.default.fileExists(atPath: document.url.path))
    }

    /// Two documents with the same name each keep their own copy.
    func testSameNamedDocumentsDoNotCollide() async throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let first = try store.adopt(handedOver("Order.pdf", bytes: "one"), moving: true, now: now, sequence: 1)
        let second = try store.adopt(handedOver("Order.pdf", bytes: "two"), moving: true, now: now, sequence: 2)

        XCTAssertNotEqual(first.url, second.url)
        XCTAssertEqual(try Data(contentsOf: first.url), Data("one".utf8))
        XCTAssertEqual(try Data(contentsOf: second.url), Data("two".utf8))
    }

    /// The queue is rebuilt from disk in the order the documents came — the folder names, not
    /// file dates, carry the order.
    func testWaitingDocumentsAreReadBackOldestFirst() async throws {
        let early = Date(timeIntervalSince1970: 1_790_000_000)
        let late = early.addingTimeInterval(5)
        _ = try store.adopt(handedOver("Later.pdf"), moving: true, now: late, sequence: 1)
        _ = try store.adopt(handedOver("Earlier.pdf"), moving: true, now: early, sequence: 7)
        _ = try store.adopt(handedOver("Same-moment.pdf"), moving: true, now: early, sequence: 8)

        XCTAssertEqual(store.pending().map(\.originalName), ["Earlier.pdf", "Same-moment.pdf", "Later.pdf"])
    }

    func testFolderNamesSortAsTheirMomentsDo() async {
        let a = IncomingDocumentStore.folderName(for: Date(timeIntervalSince1970: 9), sequence: 1)
        let b = IncomingDocumentStore.folderName(for: Date(timeIntervalSince1970: 10), sequence: 1)
        let c = IncomingDocumentStore.folderName(for: Date(timeIntervalSince1970: 10), sequence: 2)
        XCTAssertLessThan(a, b, "9 s sorts before 10 s, which a bare number would not")
        XCTAssertLessThan(b, c)
    }

    /// A folder whose document has gone is tidied away rather than listed as a document.
    func testAnEmptyFolderIsTidiedAway() async throws {
        let document = try store.adopt(handedOver("Order.pdf"), moving: true, now: Date(), sequence: 1)
        try FileManager.default.removeItem(at: document.url)

        XCTAssertTrue(store.pending().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: document.url.deletingLastPathComponent().path))
    }

    /// Removing a document removes its folder — a converted photo made beside it included.
    func testRemovingADocumentRemovesWhatWasMadeFromIt() async throws {
        let document = try store.adopt(handedOver("IMG_1.HEIC"), moving: true, now: Date(), sequence: 1)
        let converted = document.url.deletingLastPathComponent()
            .appendingPathComponent("converted", isDirectory: true)
        try FileManager.default.createDirectory(at: converted, withIntermediateDirectories: true)
        try Data("jpeg".utf8).write(to: converted.appendingPathComponent("IMG_1.jpg"))

        XCTAssertEqual(store.pending().map(\.originalName), ["IMG_1.HEIC"], "the conversion is not a second document")
        store.remove(document)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: document.url.deletingLastPathComponent().path))
    }

    // MARK: - The queue

    /// Several arriving together are asked about one at a time, in the order they came.
    func testDocumentsAreAskedAboutOneAfterAnother() async {
        let queue = IncomingDocumentQueue(store: store)
        queue.receive(handedOver("One.pdf"), moving: true)
        queue.receive(handedOver("Two.docx"), moving: true)
        queue.receive(handedOver("Three.png"), moving: true)

        XCTAssertEqual(queue.current?.originalName, "One.pdf")
        XCTAssertEqual(queue.waitingCount, 2)

        let first = queue.current!
        queue.finish(first)
        XCTAssertEqual(queue.current?.originalName, "Two.docx")
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.url.path), "its copy is cleaned up")

        queue.finish(queue.current!)
        queue.finish(queue.current!)
        XCTAssertNil(queue.current)
        XCTAssertEqual(queue.waitingCount, 0)
        XCTAssertTrue(store.pending().isEmpty)
    }

    /// A document handed over while nobody is signed in survives the app closing: a new queue —
    /// the next launch — finds it waiting.
    func testAWaitingDocumentSurvivesARelaunch() async {
        let before = IncomingDocumentQueue(store: store)
        before.receive(handedOver("Order.pdf"), moving: true)

        let after = IncomingDocumentQueue(store: store)

        XCTAssertEqual(after.current?.originalName, "Order.pdf")
    }

    /// Signing out lets every waiting document go, from memory and from disk.
    func testSigningOutLetsEveryWaitingDocumentGo() async {
        let queue = IncomingDocumentQueue(store: store)
        queue.receive(handedOver("One.pdf"), moving: true)
        queue.receive(handedOver("Two.pdf"), moving: true)

        queue.discardAll()

        XCTAssertNil(queue.current)
        XCTAssertTrue(store.pending().isEmpty)
        XCTAssertNil(IncomingDocumentQueue(store: store).current, "nothing for the next person")
    }

    func testAFileThatCannotBeTakenSaysSo() async {
        let queue = IncomingDocumentQueue(store: store)
        let missing = root.appendingPathComponent("Inbox/Nowhere.pdf")

        XCTAssertNil(queue.receive(missing, moving: true))
        XCTAssertNil(queue.current)
        XCTAssertEqual(queue.receiveError, IncomingDocumentQueue.Copy.couldNotReceive)
    }

    // MARK: - Choosing where

    private static let tree: [FileNode] = [
        folder("Bakshi", [
            .file(readyFile("Bakshi/Plaint.pdf")),
            folder("Bakshi/Orders", [.file(readyFile("Bakshi/Orders/Interim_Order.pdf"))]),
        ]),
        folder("Uploads", []),
        folder("Arora_Holdings", []),
    ]

    private func model(
        _ name: String = "Interim Order.pdf", tree: [FileNode] = IncomingDocumentTests.tree,
        filer: FakeFiler = FakeFiler()
    ) throws -> (SaveIncomingDocumentModel, FakeFiler, FakeFiles) {
        let document = try store.adopt(handedOver(name), moving: true, now: Date(), sequence: 1)
        let files = FakeFiles()
        files.tree = tree
        return (SaveIncomingDocumentModel(document: document, files: files, filer: filer), filer, files)
    }

    /// The default folder leads, named; then every folder, parents above children. The default
    /// is not listed a second time when the library already has it.
    func testTheFoldersOfferedAreTheLibrarysWithTheDefaultFirst() async throws {
        let (model, _, _) = try model()
        await model.loadFolders()

        let offered = model.destinations
        XCTAssertEqual(offered.first?.path, "")
        XCTAssertEqual(offered.first?.title, "Uploads")
        XCTAssertEqual(Set(offered.dropFirst().map(\.path)), ["Bakshi", "Bakshi/Orders", "Arora_Holdings"])
        let orders = offered.first { $0.path == "Bakshi/Orders" }
        XCTAssertEqual(orders?.depth, 1)
        XCTAssertEqual(orders?.spokenLabel, "Bakshi / Orders")
        let bakshi = try XCTUnwrap(offered.firstIndex { $0.path == "Bakshi" })
        let ordersIndex = try XCTUnwrap(offered.firstIndex { $0.path == "Bakshi/Orders" })
        XCTAssertLessThan(bakshi, ordersIndex)
    }

    /// The top-level choice files into the default folder, as My Files' own Add does.
    func testTheTopLevelChoiceFilesIntoTheDefaultFolder() async throws {
        let (model, filer, _) = try model()
        await model.loadFolders()

        XCTAssertEqual(model.destinationFolder, FileLibraryViewModel.uploadFolder)
        await model.save()
        XCTAssertEqual(filer.uploads.first?.folder, "Uploads")
    }

    func testAChosenFolderIsWhereItGoes() async throws {
        let (model, filer, _) = try model()
        await model.loadFolders()
        let orders = try XCTUnwrap(model.destinations.first { $0.path == "Bakshi/Orders" })
        model.choose(orders)

        XCTAssertEqual(model.destinationTitle, "Orders")
        await model.save()

        XCTAssertEqual(filer.reviews.first?.folder, "Bakshi/Orders")
        XCTAssertEqual(filer.uploads.first?.folder, "Bakshi/Orders")
        XCTAssertEqual(model.phase, .saved(folder: "Bakshi/Orders"))
        XCTAssertEqual(model.savedHeadline, "Uploading to Orders")
    }

    /// With the library unreachable, the default folder is still offered, and saving still works.
    func testFoldersThatWillNotLoadLeaveTheDefault() async throws {
        let (model, filer, files) = try model()
        files.treeError = APIError.transport("offline")

        await model.loadFolders()

        XCTAssertEqual(model.destinations.map(\.path), [""])
        XCTAssertNotNil(model.foldersState.failure)
        await model.save()
        XCTAssertEqual(filer.uploads.count, 1)
    }

    /// A folder that has gone by the time the list is read again falls back to the default.
    func testAChosenFolderThatHasGoneFallsBackToTheDefault() async throws {
        let (model, _, files) = try model()
        await model.loadFolders()
        model.choose(try XCTUnwrap(model.destinations.first { $0.path == "Arora_Holdings" }))

        files.tree = [folder("Bakshi", [])]
        await model.loadFolders()

        XCTAssertEqual(model.destinationPath, "")
    }

    // MARK: - Naming it

    /// The name starts as it arrived, without its type, and the type is kept whatever is typed.
    func testTheNameIsEditableAndTheTypeIsKept() async throws {
        let (model, filer, _) = try model("Interim Order.pdf")
        XCTAssertEqual(model.baseName, "Interim Order")
        XCTAssertEqual(model.fileExtension, "pdf")

        model.baseName = "  Interim order dated 3 Oct  "
        XCTAssertEqual(model.fileName, "Interim order dated 3 Oct.pdf")
        await model.save()

        XCTAssertEqual(filer.uploads.first?.name, "Interim order dated 3 Oct.pdf")
    }

    func testANameIsRequired() async throws {
        let (model, filer, _) = try model()
        model.baseName = "   "

        XCTAssertEqual(model.nameProblem, SaveIncomingDocumentModel.Copy.nameRequired)
        XCTAssertFalse(model.canSave)
        await model.save()

        XCTAssertTrue(filer.prepared.isEmpty, "nothing is read or sent")
        XCTAssertEqual(model.errorMessage, SaveIncomingDocumentModel.Copy.nameRequired)
    }

    /// A HEIC photo is offered as a JPEG and converted on the way.
    func testAHEICPhotoIsSavedAsAJPEG() async throws {
        let (model, filer, _) = try model("IMG_0042.HEIC")
        XCTAssertEqual(model.fileExtension, "jpg")
        XCTAssertTrue(model.isConvertedPhoto)
        XCTAssertNil(model.refusal)

        await model.save()

        XCTAssertEqual(filer.prepared, ["IMG_0042.jpg"])
        XCTAssertEqual(filer.uploads.first?.name, "IMG_0042.jpg")
    }

    /// A type the library cannot hold is refused before anything is read.
    func testATypeTheLibraryCannotHoldIsRefused() async throws {
        let (model, filer, _) = try model("Brief.pages")
        XCTAssertNotNil(model.refusal)
        XCTAssertFalse(model.canSave)

        await model.save()

        XCTAssertTrue(filer.prepared.isEmpty)
    }

    func testAnUnreadableDocumentSaysSo() async throws {
        let filer = FakeFiler()
        filer.preparedURL = nil
        let (model, _, _) = try model(filer: filer)

        await model.save()

        XCTAssertEqual(model.errorMessage, SaveIncomingDocumentModel.Copy.unreadable)
        XCTAssertEqual(model.phase, .editing)
        XCTAssertTrue(filer.uploads.isEmpty)
    }

    // MARK: - Already in the library

    /// The duplicate check runs before the upload, and a document already held is asked about.
    func testADocumentAlreadyHeldIsAskedAboutFirst() async throws {
        let filer = FakeFiler()
        filer.decision = .alreadyHeld([DuplicateCheck.Placement(folder: "Bakshi", fileName: "Order.pdf")])
        let (model, _, _) = try model("Order.pdf", filer: filer)

        await model.save()

        XCTAssertEqual(model.phase, .confirming(filer.decision))
        XCTAssertTrue(filer.uploads.isEmpty, "not uploaded before the answer")
        XCTAssertEqual(model.confirmationMessage, "Order.pdf is already in your library, filed under Bakshi.")
        XCTAssertEqual(model.confirmationAction, "Save another copy")
        XCTAssertFalse(model.confirmationIsDestructive)

        await model.saveAnyway()
        XCTAssertEqual(filer.uploads.count, 1)
        XCTAssertEqual(model.phase, .saved(folder: "Uploads"))
    }

    /// Replacing a different document is the destructive answer, and is worded and coloured so.
    func testReplacingADifferentDocumentIsCalledWhatItIs() async throws {
        let filer = FakeFiler()
        filer.decision = .wouldOverwrite(DuplicateCheck.Conflict(folder: "Uploads", fileName: "Order.pdf", size: 10))
        let (model, _, _) = try model("Order.pdf", filer: filer)

        await model.save()

        XCTAssertEqual(model.confirmationAction, "Replace it")
        XCTAssertTrue(model.confirmationIsDestructive)
    }

    /// Choosing to change the name or folder instead sends nothing.
    func testReconsideringSendsNothing() async throws {
        let filer = FakeFiler()
        filer.decision = .alreadyHeld([DuplicateCheck.Placement(folder: "Bakshi", fileName: nil)])
        let (model, _, _) = try model(filer: filer)

        await model.save()
        model.reconsider()

        XCTAssertEqual(model.phase, .editing)
        XCTAssertTrue(filer.uploads.isEmpty)
        XCTAssertTrue(model.canSave)
    }

    /// A refused upload returns to the form with the reason, and can be tried again.
    func testAFailedUploadReturnsToTheFormWithTheReason() async throws {
        let filer = FakeFiler()
        filer.uploadFailure = "This account's storage is full, so this document wasn't uploaded."
        let (model, _, _) = try model(filer: filer)

        await model.save()

        XCTAssertEqual(model.phase, .editing)
        XCTAssertEqual(model.errorMessage, filer.uploadFailure)
        XCTAssertTrue(model.canSave)
    }
}

/// The device's part of filing, recorded. Test-only.
@MainActor
final class FakeFiler: IncomingDocumentFiling {
    var decision: DuplicateCheck.Decision = .upload
    var uploadFailure: String?
    var preparedURL: URL? = URL(fileURLWithPath: "/tmp/prepared")

    private(set) var prepared: [String] = []
    private(set) var reviews: [(name: String, folder: String)] = []
    private(set) var uploads: [(name: String, folder: String)] = []

    func prepare(_ document: IncomingDocument, as fileName: String) async -> URL? {
        prepared.append(fileName)
        return preparedURL
    }

    func review(_ file: URL, named fileName: String, into folder: String) async -> DuplicateCheck.Decision {
        reviews.append((fileName, folder))
        return decision
    }

    func upload(_ file: URL, named fileName: String, into folder: String) async -> String? {
        uploads.append((fileName, folder))
        return uploadFailure
    }
}
