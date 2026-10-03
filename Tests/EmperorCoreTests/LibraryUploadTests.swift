import XCTest
@testable import EmperorCore

final class LibraryUploadTests: XCTestCase {

    // MARK: - What the library holds

    /// Pinned against the web's upload dialog (`UploadModal.jsx:569`) and the types `/user-files`
    /// lists. Anything else uploads and then never appears.
    func testTheAcceptedTypesAreTheWebs() {
        XCTAssertEqual(
            Set(LibraryUpload.acceptedExtensions),
            ["pdf", "txt", "docx", "doc", "odt", "rtf", "csv", "png", "jpg", "jpeg"])
    }

    func testTheExtensionIsReadCaseInsensitively() {
        XCTAssertTrue(LibraryUpload.isAccepted(fileName: "ORDER.PDF"))
        XCTAssertTrue(LibraryUpload.isAccepted(fileName: "Reply.Docx"))
        XCTAssertTrue(LibraryUpload.isAccepted(fileName: "scan.jpeg"))
    }

    /// A photo straight from the library is HEIC. It would upload and never be listed.
    func testAPhotoLibraryFormatIsRefused() {
        XCTAssertFalse(LibraryUpload.isAccepted(fileName: "IMG_0001.HEIC"))
        XCTAssertFalse(LibraryUpload.isAccepted(fileName: "clip.gif"))
    }

    func testANameWithNoExtensionIsRefused() {
        XCTAssertFalse(LibraryUpload.isAccepted(fileName: "README"))
        XCTAssertFalse(LibraryUpload.isAccepted(fileName: ".pdf"), "a dotfile, not a PDF")
        XCTAssertFalse(LibraryUpload.isAccepted(fileName: "archive.pdf.zip"))
    }

    func testRefusedDocumentsAreNamedInOneSentence() {
        XCTAssertNil(LibraryUpload.refusal(for: ["a.pdf", "b.docx"]))
        let one = LibraryUpload.refusal(for: ["a.pdf", "IMG_1.HEIC"])
        XCTAssertTrue(one?.hasPrefix("IMG_1.HEIC was not added.") == true, one ?? "")
        let two = LibraryUpload.refusal(for: ["x.gif", "y.heic"])
        XCTAssertTrue(two?.hasPrefix("x.gif and y.heic were not added.") == true, two ?? "")
    }

    // MARK: - Matching verdicts

    private func verdict(_ name: String, hash: String, status: DuplicateCheck.Status, in folder: String = "Bakshi") -> DuplicateCheck.Result {
        DuplicateCheck.Result(
            name: name, hash: hash, status: status,
            heldIn: status == .duplicate ? [.init(folder: folder, fileName: name)] : nil,
            nameConflict: status == .nameConflict ? .init(folder: folder, fileName: name, size: 10) : nil)
    }

    /// Matched by hash, not position — a short answer must not shift verdicts onto the wrong file.
    func testVerdictsAreMatchedByHashNotPosition() {
        let decisions = LibraryUpload.decisions(
            forHashes: ["h1", "h2", "h3"],
            results: [verdict("c.pdf", hash: "h3", status: .duplicate)])
        XCTAssertEqual(decisions[0], .upload)
        XCTAssertEqual(decisions[1], .upload)
        XCTAssertEqual(decisions[2], .alreadyHeld([.init(folder: "Bakshi", fileName: "c.pdf")]))
    }

    /// A file that could not be hashed was never asked about. It uploads; the check is a courtesy.
    func testAnUnhashableFileUploadsWithoutAQuestion() {
        let decisions = LibraryUpload.decisions(
            forHashes: [nil], results: [verdict("a.pdf", hash: "h1", status: .duplicate)])
        XCTAssertEqual(decisions, [.upload])
    }

    func testNoAnswerAtAllMeansNoQuestions() {
        XCTAssertEqual(LibraryUpload.decisions(forHashes: ["h1", "h2"], results: []), [.upload, .upload])
    }

    func testANameConflictAsksBeforeOverwriting() {
        let decisions = LibraryUpload.decisions(
            forHashes: ["h1"], results: [verdict("a.pdf", hash: "h1", status: .nameConflict)])
        guard case .wouldOverwrite = decisions[0] else {
            return XCTFail("expected an overwrite question, got \(decisions[0])")
        }
    }

    // MARK: - Naming a photo

    /// India's clock, and only characters that survive the server's sanitiser unchanged.
    func testAPhotoIsNamedForWhenItWasAddedInIndia() {
        // 2026-10-02 20:15:07 UTC is 01:45:07 on the 3rd in India.
        let date = Date(timeIntervalSince1970: 1_790_972_107)
        let name = LibraryUpload.photoFileName(at: date)
        XCTAssertEqual(name, "Photo_2026-10-03_014507.jpg")
        XCTAssertEqual(UploadService.sanitize(fileName: name), name)
        XCTAssertTrue(LibraryUpload.isAccepted(fileName: name))
    }

    /// Photos picked together share a second. Without the index they would overwrite each other.
    func testPhotosPickedTogetherGetDistinctNames() {
        let date = Date(timeIntervalSince1970: 1_790_972_107)
        let names = (0..<3).map { LibraryUpload.photoFileName(at: date, index: $0) }
        XCTAssertEqual(Set(names).count, 3)
        XCTAssertEqual(names[1], "Photo_2026-10-03_014507_2.jpg")
    }
}
