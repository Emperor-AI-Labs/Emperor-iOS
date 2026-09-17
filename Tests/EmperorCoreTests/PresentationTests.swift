import XCTest
@testable import EmperorCore

/// The small display rules that used to be inlined at every call site.
final class PresentationTests: XCTestCase {

    // MARK: - Filenames

    /// Names are underscore-sanitised on disk, so what the server lists is not what the user
    /// typed. This is display-only and must never be fed back to the API.
    func testStoredFilenamesAreShownWithoutUnderscores() {
        XCTAssertEqual(DisplayText.fileName("Partition_Suit_Order.pdf"), "Partition Suit Order.pdf")
        XCTAssertEqual(DisplayText.fileName("Notes.txt"), "Notes.txt")
        XCTAssertEqual(DisplayText.fileName(""), "")
    }

    /// A row in the document list has to say which matter it belongs to. `{name, folderName}` is
    /// the platform's identity for a document, so two matters may each hold an `Order.pdf` and the
    /// name alone cannot tell a reader which one a Remove would take.
    func testAnAttachedDocumentIsNamedWithItsMatter() {
        XCTAssertEqual(
            DisplayText.attachmentTitle(
                ChatAttachment(name: "Order.pdf", folderName: "Kartar_v_Sundaram")),
            "Order.pdf — Kartar v Sundaram",
            "the folder is un-sanitised for display too, not left carrying its underscores")
    }

    /// A document at the storage root has no matter to name, and must not get a dangling dash.
    func testARootDocumentIsNamedOnItsOwn() {
        XCTAssertEqual(
            DisplayText.attachmentTitle(ChatAttachment(name: "Order.pdf", folderName: nil)),
            "Order.pdf")
        XCTAssertEqual(
            DisplayText.attachmentTitle(ChatAttachment(name: "Order.pdf", folderName: "")),
            "Order.pdf",
            "an empty folder reads the same as a missing one")
    }

    // MARK: - Error wording

    /// `APIError` carries wording written for this product; `localizedDescription` on the same
    /// value yields a generic framework string. Preferring the former is the whole point.
    func testAPIErrorsUseTheirOwnWording() {
        XCTAssertEqual(
            DisplayText.message(for: APIError.invalidCredentials),
            "That email and password did not match.")
        XCTAssertEqual(
            DisplayText.message(for: APIError.server(status: 500, message: "Database is locked")),
            "Database is locked")
    }

    /// Errors from outside our stack — `URLError`, the scanner — still have to say something.
    func testForeignErrorsFallBackToTheirDescription() {
        XCTAssertEqual(DisplayText.message(for: ScanError.noPages), "No pages were captured.")
        XCTAssertFalse(
            DisplayText.message(for: URLError(.notConnectedToInternet)).isEmpty)
    }

    // MARK: - Scan naming

    /// Colons are stripped here because the server sanitises them to `_` anyway — doing it
    /// first means the name shown in the composer is the name that lands on disk, rather than
    /// a near-miss the user has to reconcile.
    func testScanNamesSurviveSanitisationUnchanged() {
        let name = ScannedDocument.suggestedName(
            for: Date(timeIntervalSince1970: 1_787_000_000))

        XCTAssertTrue(name.hasPrefix("Scan-"))
        XCTAssertTrue(name.hasSuffix(".pdf"))
        XCTAssertFalse(name.contains(":"))
        XCTAssertEqual(
            UploadService.sanitize(fileName: name), name,
            "the name must survive the server's own sanitiser untouched")
    }

    /// The stamp is what distinguishes two scans taken minutes apart in the same folder.
    func testScansTakenAtDifferentTimesGetDifferentNames() {
        let first = ScannedDocument.suggestedName(for: Date(timeIntervalSince1970: 1_787_000_000))
        let second = ScannedDocument.suggestedName(for: Date(timeIntervalSince1970: 1_787_000_060))
        XCTAssertNotEqual(first, second)
    }

    // MARK: - Artifact wrapper

    /// Drafts arrive as fragments with no document shell of their own, so the wrapper has to
    /// supply one — and must not alter the model's markup on the way through.
    func testArtifactWrapperEmbedsTheFragmentVerbatim() {
        let fragment = "<h1 style=\"text-align:center\">IN THE HIGH COURT</h1>"
        let html = ArtifactDocument.html(wrapping: fragment)

        XCTAssertTrue(html.contains(fragment))
        XCTAssertTrue(html.hasPrefix("<!doctype html>"))
        XCTAssertTrue(html.contains("width=device-width"), "must be readable on a phone")
    }

    /// A wide table of contents has to scroll inside the page rather than force the whole
    /// document sideways.
    func testArtifactWrapperKeepsWideContentInsideItsOwnScroller() {
        let html = ArtifactDocument.html(wrapping: "<table><tr><td>x</td></tr></table>")
        XCTAssertTrue(html.contains("overflow-x: auto"))
        XCTAssertTrue(html.contains("class=\"scroll\""))
    }

    /// The reader's text size reaches the page. A web view honours none of Dynamic Type by
    /// itself, so a document set at a fixed pixel size stays that size however large the reader
    /// has asked for their text — which on this app's content is the difference between a
    /// readable pleading and one nobody can use.
    func testTheWrapperTakesTheSizeItIsGiven() {
        XCTAssertTrue(ArtifactDocument.html(wrapping: "<p>x</p>", pointSize: 24)
            .contains("font-size: 24.0px"))
        XCTAssertTrue(ArtifactDocument.html(wrapping: "<p>x</p>", pointSize: 17)
            .contains("font-size: 17.0px"))
    }

    /// **Export must not move with a phone setting.** A filed PDF is a fixed artefact, and the
    /// registry's copy should not run to a different number of pages because somebody enlarged
    /// their text. The default is what `AnswerPDF` uses, and it has to stay put.
    func testExportIsUnaffectedByTheReadersTextSize() {
        XCTAssertEqual(
            ArtifactDocument.html(wrapping: "<p>x</p>"),
            ArtifactDocument.html(wrapping: "<p>x</p>", pointSize: ArtifactDocument.basePointSize))
    }

    /// The tablet rule must sit above an A4 page's width, or an exported PDF would silently pick
    /// up the larger on-screen type. A4 is 595pt.
    func testTheTabletRuleCannotReachAPrintedPage() {
        let html = ArtifactDocument.html(wrapping: "<p>x</p>")
        XCTAssertTrue(html.contains("@media (min-width: 820px)"))
        XCTAssertGreaterThan(820, 595, "A4 at 595pt must never trigger the tablet rule")
    }

    /// Line length, not window width, is what decides whether a long document can be read. Run
    /// edge to edge on a 13-inch iPad and the eye loses its place returning to the left margin.
    func testTheColumnIsCappedAndCentred() {
        let html = ArtifactDocument.html(wrapping: "<p>x</p>")
        XCTAssertTrue(html.contains("max-width: 84ch"), "a measure in characters, not pixels")
        XCTAssertTrue(html.contains("margin: 0 auto"), "centred, so the cap reads as a page")
        XCTAssertTrue(html.contains("clamp(16px, 4vw, 44px)"), "gutter scales with the viewport")
    }

    /// A system metric is still an input. Type below about eleven points is not a document.
    func testAnAbsurdlySmallSizeIsFloored() {
        XCTAssertTrue(ArtifactDocument.html(wrapping: "<p>x</p>", pointSize: 2)
            .contains("font-size: 11.0px"))
    }

    // MARK: - Credential store

    func testInMemoryStoreRoundTripsAndRemoves() {
        let store = InMemoryCredentialStore()
        XCTAssertNil(store.string(for: "auth.token"))

        store.set("tok-abc", for: "auth.token")
        XCTAssertEqual(store.string(for: "auth.token"), "tok-abc")

        store.set("tok-def", for: "auth.token")
        XCTAssertEqual(store.string(for: "auth.token"), "tok-def", "writes replace")

        store.remove("auth.token")
        XCTAssertNil(store.string(for: "auth.token"))
    }
}
