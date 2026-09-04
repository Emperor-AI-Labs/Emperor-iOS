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
