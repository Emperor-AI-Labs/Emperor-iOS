import XCTest
@testable import EmperorCore

final class FileLibraryViewModelTests: XCTestCase {

    /// Computed rather than stored: `FileNode` is not `Sendable`, so a stored static would be
    /// shared mutable state as far as Swift 6 is concerned.
    private static var tree: [FileNode] { [
        folder("Partition_Suit", [
            .file(readyFile("Partition_Suit/Sale_Deed.pdf")),
            .file(readyFile("Partition_Suit/Award.pdf")),
        ]),
        folder("Arbitration", [
            .file(readyFile("Arbitration/Sale_Deed.pdf")),
        ]),
        // Files appear at the top level too, not only inside folders.
        .file(readyFile("Notes.txt")),
    ] }

    // MARK: - Loading and empty states

    func testLoadFlattensTheTree() async {
        await withLibrary { files, model in
            files.tree = Self.tree
            await model.load()

            XCTAssertEqual(model.files.count, 4)
            XCTAssertNil(model.failure?.message)
        }
    }

    /// "No documents yet" while the request is still in flight tells the user something false
    /// about their own account.
    func testEmptyStateIsNotShownWhileLoading() async {
        await withLibrary { _, model in
            XCTAssertFalse(model.presentation.showsEmptyState)
            await model.load()
            XCTAssertTrue(model.presentation.showsEmptyState, "an empty result does earn the empty state")
        }
    }

    /// A dropped connection is classified as offline, not as the server objecting — the two
    /// call for different words and different actions.
    func testLoadFailureIsSurfacedAsOffline() async {
        await withLibrary { files, model in
            files.treeError = APIError.transport("The network connection was lost.")
            await model.load()

            XCTAssertEqual(model.failure?.kind, .offline)
            XCTAssertEqual(model.failure?.message, DisplayText.offlineMessage)
            XCTAssertTrue(model.failure?.isRetryable == true)
        }
    }

    /// **The distinction this whole type exists for.** A failed load must never render as an
    /// empty library — that is the web bug at `store.js:1051-1055`, and on the cause list the
    /// same pattern tells a litigator their court day is clear.
    func testAFailedLoadIsNeverShownAsAnEmptyLibrary() async {
        await withLibrary { files, model in
            files.treeError = APIError.server(status: 500, message: "Database is locked")
            await model.load()

            XCTAssertTrue(model.presentation.showsFailureState)
            XCTAssertFalse(
                model.presentation.showsEmptyState,
                "'No documents yet' would be a lie — we never got an answer")
            XCTAssertFalse(model.presentation.showsLoadingPlaceholder)
        }
    }

    /// A refresh that fails over existing content keeps the content and says it may be stale,
    /// rather than blanking a screen the user was reading.
    func testAFailedRefreshKeepsTheContentAndFlagsItStale() async {
        await withLibrary { files, model in
            files.tree = Self.tree
            await model.load()
            XCTAssertEqual(model.files.count, 4)

            files.treeError = APIError.transport("offline")
            await model.load()

            XCTAssertEqual(model.files.count, 4, "the list survives a failed refresh")
            XCTAssertTrue(model.presentation.showsStaleBanner)
            XCTAssertFalse(model.presentation.showsFailureState)
        }
    }

    /// An expired session is not retryable — the only useful action is to sign in again.
    func testAnExpiredSessionIsClassifiedForReauthentication() async {
        await withLibrary { files, model in
            files.treeError = APIError.invalidCredentials
            await model.load()

            XCTAssertEqual(model.failure?.kind, .unauthenticated)
            XCTAssertFalse(model.failure?.isRetryable == true)
            XCTAssertTrue(model.state.requiresReauthentication)
        }
    }

    // MARK: - Grouping

    /// Grouped by matter, because that is how a practitioner thinks about a file.
    func testFilesAreGroupedByFolderInNameOrder() async {
        await withLibrary { files, model in
            files.tree = Self.tree
            await model.load()

            XCTAssertEqual(model.grouped.map(\.folder), ["", "Arbitration", "Partition_Suit"])
            XCTAssertEqual(
                model.grouped.last?.files.map(\.name), ["Award.pdf", "Sale_Deed.pdf"],
                "files sort by name within a matter")
        }
    }

    /// A blank section heading reads as a rendering fault rather than as "filed nowhere".
    func testRootLevelFilesAreTitledUnfiled() async {
        await withLibrary { files, model in
            files.tree = Self.tree
            await model.load()

            XCTAssertEqual(model.grouped.first?.title, "Unfiled")
        }
    }

    func testGroupTitlesAreShownWithoutUnderscores() async {
        await withLibrary { files, model in
            files.tree = Self.tree
            await model.load()

            XCTAssertEqual(model.grouped.last?.title, "Partition Suit")
        }
    }

    // MARK: - Search

    /// Names are underscore-sanitised on disk, so a user typing spaces must still match.
    func testSearchMatchesAcrossUnderscoresAndSpaces() async {
        await withLibrary { files, model in
            files.tree = Self.tree
            await model.load()
            model.query = "sale deed"

            XCTAssertEqual(model.visible.count, 2, "one in each matter")
        }
    }

    /// Matching the folder too means "partition" finds everything filed under that matter even
    /// when the word is not in the filename.
    func testSearchMatchesTheMatterName() async {
        await withLibrary { files, model in
            files.tree = Self.tree
            await model.load()
            model.query = "partition"

            XCTAssertEqual(model.visible.count, 2)
        }
    }

    /// A query that matches nothing is a different message from an empty library.
    func testNoSearchResultsIsDistinctFromAnEmptyLibrary() async {
        await withLibrary { files, model in
            files.tree = Self.tree
            await model.load()
            model.query = "nothing matches this"

            XCTAssertTrue(model.showsNoSearchResults)
            XCTAssertFalse(model.presentation.showsEmptyState)
        }
    }

    // MARK: - Selection

    func testTogglingSelectsAndDeselects() async {
        await withLibrary { files, model in
            files.tree = Self.tree
            await model.load()
            let file = readyFile("Partition_Suit/Award.pdf")

            model.toggle(file)
            XCTAssertTrue(model.isSelected(file))
            XCTAssertTrue(model.canAttach)

            model.toggle(file)
            XCTAssertFalse(model.isSelected(file))
            XCTAssertFalse(model.canAttach)
        }
    }

    /// A file still being ingested cannot answer questions yet, so attaching it would produce
    /// a turn the server refuses for reasons the user cannot see.
    func testAFileStillBeingReadCannotBeSelected() async {
        await withLibrary { files, model in
            var pending = readyFile("Partition_Suit/Award.pdf")
            pending.status = "Extracting text"
            files.tree = [folder("Partition_Suit", [.file(pending)])]
            await model.load()

            model.toggle(pending)

            XCTAssertFalse(model.isSelected(pending))
            XCTAssertFalse(model.canAttach)
        }
    }

    /// Reopening the sheet must show what the turn already carries, or the user re-attaches
    /// files that are already there.
    func testAlreadyAttachedFilesOpenSelected() async {
        let attached = [ChatAttachment(name: "Sale_Deed.pdf", folderName: "Partition_Suit")]
        await withLibrary(alreadyAttached: attached) { files, model in
            files.tree = Self.tree
            await model.load()

            XCTAssertEqual(model.selected, ["Partition_Suit/Sale_Deed.pdf"])
        }
    }

    /// The platform treats `{name, folderName}` as identity: the same filename in two matters
    /// is two different documents. Reconciling on name alone would select both.
    func testReconcilingMatchesOnFolderAsWellAsName() async {
        let attached = [ChatAttachment(name: "Sale_Deed.pdf", folderName: "Arbitration")]
        await withLibrary(alreadyAttached: attached) { files, model in
            files.tree = Self.tree
            await model.load()

            XCTAssertEqual(model.selected, ["Arbitration/Sale_Deed.pdf"])
            XCTAssertEqual(model.chosenAttachments, attached)
        }
    }

    /// A loose file at the storage root has an empty folder path, which composes to just the
    /// name rather than to "/Notes.txt".
    func testRootLevelAttachmentReconciles() async {
        let attached = [ChatAttachment(name: "Notes.txt", folderName: nil)]
        await withLibrary(alreadyAttached: attached) { files, model in
            files.tree = Self.tree
            await model.load()

            XCTAssertEqual(model.selected, ["Notes.txt"])
        }
    }

    /// What goes back to the composer must carry the folder, since the chat routes need both.
    func testChosenAttachmentsCarryTheirFolder() async {
        await withLibrary { files, model in
            files.tree = Self.tree
            await model.load()
            model.toggle(readyFile("Partition_Suit/Award.pdf"))

            XCTAssertEqual(
                model.chosenAttachments,
                [ChatAttachment(name: "Award.pdf", folderName: "Partition_Suit")])
        }
    }
}

@MainActor
private func withLibrary(
    alreadyAttached: [ChatAttachment] = [],
    _ body: @MainActor (FakeFiles, FileLibraryViewModel) async -> Void
) async {
    let files = FakeFiles()
    await body(files, FileLibraryViewModel(service: files, alreadyAttached: alreadyAttached))
}
