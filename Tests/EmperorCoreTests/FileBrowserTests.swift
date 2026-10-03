import XCTest
@testable import EmperorCore

// MARK: - Builders

/// A document as `/user-files` lists it: a relative path, a size, a status, and the two fields
/// the browser orders and filters on.
private func doc(
    _ path: String, modified: String? = nil, favorite: Bool = false, status: String = "ready"
) -> FileNode {
    .file(FileNode.StoredFile(
        name: String(path.split(separator: "/").last ?? ""),
        path: path,
        size: 2048,
        modified: modified,
        status: status,
        favorite: favorite))
}

private func dir(_ path: String, created: String? = nil, _ children: [FileNode] = []) -> FileNode {
    .folder(FileNode.Folder(
        name: String(path.split(separator: "/").last ?? ""),
        path: path,
        created: created,
        files: children))
}

/// A practice's library, shaped the way the server nests it: folders hold sub-folders and
/// documents in one array, and a loose document can sit at the top level.
private let library: [FileNode] = [
    dir("Bakshi", created: "2026-09-01T10:00:00.000Z", [
        doc("Bakshi/Plaint.pdf", modified: "2026-09-02T09:00:00.000Z"),
        doc("Bakshi/Annexure_10.pdf", modified: "2026-09-03T09:00:00.000Z", favorite: true),
        doc("Bakshi/Annexure_2.pdf", modified: "2026-09-03T08:00:00.000Z"),
        dir("Bakshi/2025", created: "2026-09-05T10:00:00.000Z", [
            doc("Bakshi/2025/Order.pdf", modified: "2026-10-01T09:00:00.000Z", favorite: true),
            dir("Bakshi/2025/Writs", created: "2026-09-06T10:00:00.000Z", [
                doc("Bakshi/2025/Writs/WP_1234.pdf"),
            ]),
        ]),
        dir("Bakshi/Empty", created: "2026-09-04T10:00:00.000Z"),
    ]),
    dir("Arora", created: "2026-09-20T10:00:00.000Z", [
        doc("Arora/Notice.pdf", modified: "2026-09-21T09:00:00.000Z"),
    ]),
    doc("Loose.pdf", modified: "2026-09-10T09:00:00.000Z"),
]

final class FileBrowserTests: XCTestCase {

    // MARK: - Walking the tree

    func testTheRootListsTopLevelFoldersAndLooseDocuments() throws {
        let listing = try XCTUnwrap(FileBrowser.listing(at: "", in: library))
        XCTAssertEqual(listing.folders.map(\.path), ["Arora", "Bakshi"])
        XCTAssertEqual(listing.files.map(\.name), ["Loose.pdf"])
    }

    func testANestedFolderIsFoundByItsPath() throws {
        let listing = try XCTUnwrap(FileBrowser.listing(at: "Bakshi/2025", in: library))
        XCTAssertEqual(listing.folders.map(\.path), ["Bakshi/2025/Writs"])
        XCTAssertEqual(listing.files.map(\.name), ["Order.pdf"])
    }

    /// A folder renamed or deleted on the web is *gone*, which a screen showing it must say. An
    /// empty listing here would tell the user the folder exists and holds nothing.
    func testAFolderThatIsNoLongerThereIsNilRatherThanEmpty() {
        XCTAssertNil(FileBrowser.listing(at: "Bakshi/Gone", in: library))
        XCTAssertNotNil(FileBrowser.listing(at: "Bakshi/Empty", in: library))
        XCTAssertEqual(FileBrowser.listing(at: "Bakshi/Empty", in: library)?.isEmpty, true)
    }

    /// `Bakshi` is a prefix of `BakshiTwo`. Walking by string prefix without the separator would
    /// look for one inside the other.
    func testAPrefixOfAnotherFolderNameIsNotMistakenForItsParent() {
        let tree = [dir("Bakshi", [doc("Bakshi/a.pdf")]), dir("BakshiTwo", [doc("BakshiTwo/b.pdf")])]
        XCTAssertEqual(FileBrowser.listing(at: "BakshiTwo", in: tree)?.files.map(\.name), ["b.pdf"])
    }

    func testAPathWithStraySeparatorsStillFindsItsFolder() {
        XCTAssertNotNil(FileBrowser.listing(at: "/Bakshi/2025/", in: library))
        XCTAssertNotNil(FileBrowser.listing(at: "./Bakshi", in: library))
    }

    // MARK: - Counting what a deletion takes

    /// `delete-folder` is recursive, so the count has to be too.
    func testAFolderCountsEveryDocumentBeneathIt() throws {
        let bakshi = try XCTUnwrap(FileBrowser.folder(at: "Bakshi", in: library))
        XCTAssertEqual(bakshi.documentCount, 5)
        XCTAssertEqual(bakshi.subfolderCount, 3, "2025, 2025/Writs and Empty")
        XCTAssertEqual(bakshi.childFolderCount, 2, "only 2025 and Empty sit directly inside")
    }

    func testTheRowSummaryCountsDocumentsDeepAndFoldersShallow() throws {
        let bakshi = try XCTUnwrap(FileBrowser.folder(at: "Bakshi", in: library))
        XCTAssertEqual(bakshi.contentsSummary, "5 documents · 2 folders")
        let writs = try XCTUnwrap(FileBrowser.folder(at: "Bakshi/2025/Writs", in: library))
        XCTAssertEqual(writs.contentsSummary, "1 document")
        let empty = try XCTUnwrap(FileBrowser.folder(at: "Bakshi/Empty", in: library))
        XCTAssertEqual(empty.contentsSummary, "Empty")
    }

    /// The root is not a folder and has no summary of its own.
    func testTheRootIsNotAFolder() {
        XCTAssertNil(FileBrowser.folder(at: "", in: library))
        XCTAssertNil(FileBrowser.folder(at: "/", in: library))
    }

    // MARK: - Ordering

    /// Newest folder first, as the web's store orders every level (`store.js:202-207`).
    func testFoldersAreNewestFirst() throws {
        let listing = try XCTUnwrap(FileBrowser.listing(at: "Bakshi", in: library))
        XCTAssertEqual(listing.folders.map(\.name), ["2025", "Empty"])
    }

    func testFoldersWithNoDateFollowDatedOnesByName() {
        let tree = [dir("b"), dir("a"), dir("c", created: "2026-09-01T00:00:00.000Z")]
        XCTAssertEqual(FileBrowser.listing(at: "", in: tree)?.folders.map(\.name), ["c", "a", "b"])
    }

    /// Annexures are numbered. A-2 comes after A-1, not after A-19.
    func testDocumentsAreInNumberAwareNameOrder() throws {
        let listing = try XCTUnwrap(FileBrowser.listing(at: "Bakshi", in: library))
        XCTAssertEqual(listing.files.map(\.name), ["Annexure_2.pdf", "Annexure_10.pdf", "Plaint.pdf"])
    }

    func testMoveDestinationsListParentsBeforeChildren() {
        XCTAssertEqual(
            FileBrowser.allFolders(in: library).map(\.path),
            ["Arora", "Bakshi", "Bakshi/2025", "Bakshi/2025/Writs", "Bakshi/Empty"])
    }

    // MARK: - Recent

    func testRecentIsNewestFirstAcrossEveryFolder() {
        let recent = FileBrowser.recent(in: library)
        XCTAssertEqual(recent.files.prefix(4).map(\.name), [
            "Order.pdf", "Notice.pdf", "Loose.pdf", "Annexure_10.pdf",
        ])
    }

    /// A document with no date cannot be placed in date order. It sinks to the end, by name,
    /// and the count of such documents is reported so the screen can say why.
    func testUndatedDocumentsSinkToTheEndAndAreCounted() {
        let recent = FileBrowser.recent(in: library)
        XCTAssertEqual(recent.files.last?.name, "WP_1234.pdf")
        XCTAssertEqual(recent.undatedCount, 1)
    }

    func testTheFooterSaysWhyAndHowMany() {
        let recent = FileBrowser.recent(in: library)
        XCTAssertEqual(recent.undatedNote, "One document has no date, so it is listed last, by name.")
        XCTAssertNil(recent.truncationNote, "seven documents fit under the cap")
        let capped = FileBrowser.recent(in: library, limit: 3)
        XCTAssertEqual(
            capped.truncationNote,
            "Showing the 3 most recent of 7. Search, or open the folder, to reach the rest.")
        XCTAssertNil(capped.undatedNote, "the undated one is past the cap")
    }

    func testUndatedDocumentsAreOrderedByNameAmongThemselves() {
        let tree = [doc("z.pdf"), doc("a.pdf"), doc("m.pdf", modified: "2026-01-01T00:00:00.000Z")]
        XCTAssertEqual(FileBrowser.recent(in: tree).files.map(\.name), ["m.pdf", "a.pdf", "z.pdf"])
    }

    /// A date the parser cannot read is the same as no date. Treating it as the epoch would put
    /// it at the bottom of the dated run, which is a claim about when it was written.
    func testAnUnreadableDateIsTreatedAsNoDate() {
        let tree = [doc("odd.pdf", modified: "yesterday-ish"), doc("ok.pdf", modified: "2026-01-01T00:00:00.000Z")]
        let recent = FileBrowser.recent(in: tree)
        XCTAssertEqual(recent.files.map(\.name), ["ok.pdf", "odd.pdf"])
        XCTAssertEqual(recent.undatedCount, 1)
    }

    /// The cap is stated, not silently applied.
    func testRecentIsCappedAndSaysSo() {
        let many = (1...60).map { doc(String(format: "f%02d.pdf", $0), modified: "2026-09-\(String(format: "%02d", ($0 % 28) + 1))T00:00:00.000Z") }
        let recent = FileBrowser.recent(in: many)
        XCTAssertEqual(recent.files.count, FileBrowser.recentLimit)
        XCTAssertEqual(recent.totalMatched, 60)
        XCTAssertTrue(recent.isTruncated)
    }

    func testRecentSearchMatchesTheFolderToo() {
        let recent = FileBrowser.recent(in: library, matching: "arora")
        XCTAssertEqual(recent.files.map(\.name), ["Notice.pdf"])
        XCTAssertEqual(recent.totalMatched, 1)
    }

    // MARK: - Favorites

    /// Starred documents grouped by where they live, then by name.
    func testFavoritesAreEverythingStarredByFolderThenName() {
        XCTAssertEqual(
            FileBrowser.favorites(in: library).map(\.path),
            ["Bakshi/Annexure_10.pdf", "Bakshi/2025/Order.pdf"])
        XCTAssertTrue(FileBrowser.hasFavorites(in: library))
    }

    /// `favorite` is absent on an older server's listing. Absent is not starred.
    func testAMissingFlagIsNotAStar() {
        let tree: [FileNode] = [.file(FileNode.StoredFile(name: "a.pdf", path: "a.pdf", status: "ready"))]
        XCTAssertTrue(FileBrowser.favorites(in: tree).isEmpty)
        XCTAssertFalse(FileBrowser.hasFavorites(in: tree))
    }

    // MARK: - Searching inside a folder

    /// The phone shows one folder at a time, so a search from a folder reaches everything under
    /// it — a document two levels down is still found.
    func testSearchingAFolderReachesItsWholeSubtree() {
        let results = FileBrowser.search("wp 1234", under: "Bakshi", in: library)
        XCTAssertEqual(results.files.map(\.path), ["Bakshi/2025/Writs/WP_1234.pdf"])
    }

    /// Searching inside a matter for the matter's own name must not return every document in it.
    func testTheFoldersOwnNameDoesNotMatchEverythingInIt() {
        let results = FileBrowser.search("bakshi", under: "Bakshi", in: library)
        XCTAssertTrue(results.files.isEmpty)
    }

    func testSearchFindsFoldersByName() {
        let results = FileBrowser.search("writ", under: "", in: library)
        XCTAssertEqual(results.folders.map(\.path), ["Bakshi/2025/Writs"])
        XCTAssertEqual(results.files.map(\.path), ["Bakshi/2025/Writs/WP_1234.pdf"])
    }

    func testSearchStaysInsideTheFolder() {
        let results = FileBrowser.search("notice", under: "Bakshi", in: library)
        XCTAssertTrue(results.isEmpty, "Arora/Notice.pdf is not under Bakshi")
    }

    func testAnEmptyQueryFindsNothingRatherThanEverything() {
        XCTAssertTrue(FileBrowser.search("   ", under: "", in: library).isEmpty)
    }

    // MARK: - Wording

    func testALooseDocumentLivesInMyFiles() {
        let loose = FileNode.StoredFile(name: "Loose.pdf", path: "Loose.pdf")
        XCTAssertEqual(FileBrowser.location(of: loose), "My Files")
        let nested = FileNode.StoredFile(name: "WP.pdf", path: "Bakshi_v_State/2025/WP.pdf")
        XCTAssertEqual(FileBrowser.location(of: nested), "Bakshi v State / 2025")
    }

    /// Two folders can share a name at different depths; the breadcrumb tells them apart.
    func testAFoldersBreadcrumbNamesEveryLevel() throws {
        let writs = try XCTUnwrap(FileBrowser.folder(at: "Bakshi/2025/Writs", in: library))
        XCTAssertEqual(writs.breadcrumb, "Bakshi / 2025 / Writs")
    }

    func testCountsAreSingularForOne() {
        XCTAssertEqual(FileBrowser.count(1, "document"), "1 document")
        XCTAssertEqual(FileBrowser.count(0, "document"), "0 documents")
        XCTAssertEqual(FileBrowser.count(2, "sub-folder"), "2 sub-folders")
    }
}

/// "Today", "Yesterday" or the date, checked against the platform's own `relDay` and `fmtDate`
/// as Node renders them. The cases are generated by `scripts/generate-file-date-fixtures.mjs`
/// into `FileDateGolden.swift`, not typed here.
final class FileDateGoldenTests: XCTestCase {

    func testEveryLabelMatchesThePlatform() {
        let now = Date(timeIntervalSince1970: FileDateGolden.nowMillis / 1000)
        XCTAssertFalse(FileDateGolden.cases.isEmpty)
        for (millis, expected) in FileDateGolden.cases {
            let date = Date(timeIntervalSince1970: millis / 1000)
            XCTAssertEqual(
                FileBrowser.dayLabel(for: date, now: now), expected,
                "\(ISO8601DateFormatter().string(from: date))")
        }
    }

    /// September is "Sept" in `en-IN`, which is the month a formatter is likeliest to get wrong.
    func testSeptemberIsSpelledTheWayThePlatformSpellsIt() {
        XCTAssertTrue(FileDateGolden.cases.contains { $0.label.contains("Sept") })
    }
}
