import XCTest
@testable import EmperorCore

/// Duplicate check, preferred model, office preview.
///
/// The through-line in all three is that the server's failure shapes are unusual, and reading
/// them naively produces something worse than the feature not existing: an upload that will not
/// start, a plan change that never reaches the phone, or an empty viewer with no explanation.
final class P9Tests: XCTestCase {

    // MARK: - Duplicate check: decoding

    private func decodeResults(_ json: String) throws -> [DuplicateCheck.Result] {
        try JSONDecoder()
            .decode(DuplicateCheck.Response.self, from: Data(json.utf8))
            .results ?? []
    }

    func testTheThreeStatusesTheServerActuallySendsAreUnderstood() throws {
        let results = try decodeResults(#"""
        {"results":[
          {"name":"a.pdf","hash":"h1","status":"duplicate",
           "heldIn":[{"folder":"Kumar v State","fileName":"a.pdf"}],"nameConflict":null},
          {"name":"b.pdf","hash":"h2","status":"name-conflict","heldIn":[],
           "nameConflict":{"folder":"Matters","fileName":"b.pdf","size":120}},
          {"name":"c.pdf","hash":"h3","status":"new","heldIn":[],"nameConflict":null}
        ]}
        """#)

        XCTAssertEqual(results.map(\.status), [.duplicate, .nameConflict, .new])
    }

    /// The plan recorded this status as `content-dupe`; the server has never sent that. An
    /// unknown value must degrade to `new` — the direction that uploads rather than the one
    /// that blocks on a prompt nobody can answer.
    func testAnUnknownStatusDegradesToNewRatherThanFailingToDecode() throws {
        let results = try decodeResults(#"""
        {"results":[{"name":"a.pdf","hash":"h","status":"content-dupe","heldIn":[],"nameConflict":null}]}
        """#)

        XCTAssertEqual(results.first?.status, .new)
        XCTAssertEqual(DuplicateCheck.decision(for: try XCTUnwrap(results.first)), .upload)
    }

    /// `heldIn` and `nameConflict` are absent rather than empty on some answers.
    func testMissingOptionalFieldsStillDecode() throws {
        let results = try decodeResults(#"{"results":[{"name":"a.pdf","hash":null,"status":"new"}]}"#)

        XCTAssertEqual(results.first?.placements, [])
        XCTAssertNil(results.first?.nameConflict)
    }

    func testAnEmptyOrAbsentResultsArrayIsNotAnError() throws {
        XCTAssertEqual(try decodeResults(#"{"results":[]}"#).count, 0)
        XCTAssertEqual(try decodeResults(#"{}"#).count, 0)
    }

    // MARK: - Duplicate check: decisions

    func testADuplicateAsksAboutTheFoldersItIsAlreadyIn() throws {
        let results = try decodeResults(#"""
        {"results":[{"name":"order.pdf","hash":"h","status":"duplicate",
          "heldIn":[{"folder":"Kumar v State","fileName":"order.pdf"}],"nameConflict":null}]}
        """#)

        guard case .alreadyHeld(let placements) = DuplicateCheck.decision(for: results[0]) else {
            return XCTFail("expected alreadyHeld")
        }
        XCTAssertEqual(placements.first?.folder, "Kumar v State")
    }

    /// A `duplicate` with nowhere to point at is a self-contradicting answer. Prompting with
    /// "this is already filed under — nothing" gives the user no basis to decide, so it uploads.
    func testADuplicateWithNoPlacementsUploadsRatherThanPromptingWithNothing() throws {
        let results = try decodeResults(#"""
        {"results":[{"name":"a.pdf","hash":"h","status":"duplicate","heldIn":[],"nameConflict":null}]}
        """#)

        XCTAssertEqual(DuplicateCheck.decision(for: results[0]), .upload)
    }

    func testANameConflictWithNoDetailUploadsRatherThanPromptingWithNothing() throws {
        let results = try decodeResults(#"""
        {"results":[{"name":"a.pdf","hash":"h","status":"name-conflict","heldIn":[]}]}
        """#)

        XCTAssertEqual(DuplicateCheck.decision(for: results[0]), .upload)
    }

    func testANameConflictWarnsThatUploadingWouldReplaceTheOtherDocument() throws {
        let results = try decodeResults(#"""
        {"results":[{"name":"a.pdf","hash":"h","status":"name-conflict","heldIn":[],
          "nameConflict":{"folder":"Matters","fileName":"a.pdf","size":9}}]}
        """#)

        let message = DuplicateCheck.message(
            for: DuplicateCheck.decision(for: results[0]), fileName: "a.pdf")
        XCTAssertEqual(
            message,
            "A different document called a.pdf is already in Matters. Uploading this one would replace it.")
    }

    // MARK: - Duplicate check: wording

    func testTheStorageRootIsNamedInWordsRatherThanAsASlash() {
        let message = DuplicateCheck.message(
            for: .alreadyHeld([.init(folder: "/", fileName: "a.pdf")]), fileName: "a.pdf")
        XCTAssertEqual(message, "a.pdf is already in your library, filed under the top level.")
    }

    func testTwoFoldersAreJoinedWithAnAnd() {
        let message = DuplicateCheck.message(
            for: .alreadyHeld([
                .init(folder: "Kumar", fileName: nil), .init(folder: "Shah", fileName: nil),
            ]),
            fileName: "a.pdf")
        XCTAssertEqual(message, "a.pdf is already in your library, under Kumar and Shah.")
    }

    func testThreeFoldersReadAsAList() {
        let message = DuplicateCheck.message(
            for: .alreadyHeld([
                .init(folder: "A", fileName: nil), .init(folder: "B", fileName: nil),
                .init(folder: "C", fileName: nil),
            ]),
            fileName: "a.pdf")
        XCTAssertEqual(message, "a.pdf is already in your library, under A, B and C.")
    }

    /// One file can be claimed by several rows in the same folder. Saying the folder twice
    /// reads as a bug.
    func testARepeatedFolderIsNamedOnce() {
        let message = DuplicateCheck.message(
            for: .alreadyHeld([
                .init(folder: "Kumar", fileName: "a.pdf"),
                .init(folder: "Kumar", fileName: "a copy.pdf"),
            ]),
            fileName: "a.pdf")
        XCTAssertEqual(message, "a.pdf is already in your library, filed under Kumar.")
    }

    func testNothingToSayAboutAFileThatIsJustNew() {
        XCTAssertNil(DuplicateCheck.message(for: .upload, fileName: "a.pdf"))
    }

    // MARK: - Preferred model

    func testThePreferredModelIsAppliedVerbatim() throws {
        let response = try JSONDecoder().decode(
            PreferredModelResponse.self,
            from: Data(#"""
            {"success":true,"preferredModel":"thinking","plan":"pro","planLabel":"Pro",
             "planDefaultModel":"thinking","isOverride":false}
            """#.utf8))

        XCTAssertEqual(response.model, .thinking)
        XCTAssertEqual(response.isOverride, false)
    }

    /// A future plan introducing a third mode must leave the phone on its existing default
    /// rather than silently picking one of the two this build knows.
    func testAnUnknownModelIsNilRatherThanAGuess() throws {
        let response = try JSONDecoder().decode(
            PreferredModelResponse.self,
            from: Data(#"{"success":true,"preferredModel":"reasoning-max"}"#.utf8))

        XCTAssertNil(response.model)
    }

    func testAMissingModelIsNil() throws {
        let response = try JSONDecoder().decode(
            PreferredModelResponse.self, from: Data(#"{"success":true}"#.utf8))

        XCTAssertNil(response.model)
    }

    // MARK: - Office preview

    func testOnlyWordProcessorFormatsArePreviewable() {
        for name in ["brief.docx", "brief.doc", "brief.odt", "brief.rtf", "BRIEF.DOCX"] {
            XCTAssertTrue(OfficePreview.canPreview(fileName: name), name)
        }
        // A spreadsheet paginated onto A4 loses whatever falls off the right edge, which looks
        // like it worked. Declining is the better answer.
        for name in ["book.xlsx", "deck.pptx", "scan.pdf", "notes.txt", "noextension"] {
            XCTAssertFalse(OfficePreview.canPreview(fileName: name), name)
        }
    }

    func testAFileNamedOnlyWithADotIsNotPreviewable() {
        XCTAssertFalse(OfficePreview.canPreview(fileName: "."))
        XCTAssertFalse(OfficePreview.canPreview(fileName: ".docx.pdf"))
        XCTAssertTrue(OfficePreview.canPreview(fileName: "odd.name.docx"))
    }

    /// The route answers `200` with `success:false`. Branching on the status code would show
    /// an empty viewer and no explanation.
    func testAFailureArrivesAsSuccessFalseOnATwoHundred() throws {
        let response = try JSONDecoder().decode(
            OfficePreview.Response.self,
            from: Data(#"{"success":false,"reason":"too-big","error":"over 50 MB"}"#.utf8))

        XCTAssertEqual(response.success, false)
        XCTAssertEqual(
            OfficePreview.message(forReason: response.reason, fallback: response.error),
            "That document is too large to preview. Share it to open it elsewhere.")
    }

    /// The server's reasons are log tokens. None should reach a user as a bare token.
    ///
    /// Checking that the message merely does not *contain* the reason is too strict and was
    /// wrong: "That document is empty." is the right sentence for `empty`, and the word being
    /// in it is English rather than a leaked token. What matters is that it is a sentence.
    func testEveryKnownReasonIsRewrittenIntoSomethingAUserCanActOn() {
        for reason in ["unsupported", "missing", "empty", "too-big", "busy"] {
            let message = OfficePreview.message(forReason: reason, fallback: nil)
            XCTAssertNotEqual(message, reason, "\(reason) reached the user as a bare token")
            XCTAssertTrue(message.contains(" "), "\(reason) produced \(message), not a sentence")
            XCTAssertTrue(message.hasSuffix("."), "\(reason) produced \(message)")
        }
    }

    func testAnUnknownReasonFallsBackToTheServersOwnMessage() {
        XCTAssertEqual(
            OfficePreview.message(forReason: "something-new", fallback: "LibreOffice gave up"),
            "LibreOffice gave up")
    }

    func testAnUnknownReasonWithNoMessageStillSaysSomething() {
        XCTAssertFalse(OfficePreview.message(forReason: nil, fallback: nil).isEmpty)
    }

    func testASuccessfulPreviewCarriesItsPageCount() throws {
        let response = try JSONDecoder().decode(
            OfficePreview.Response.self,
            from: Data(#"{"success":true,"fileName":"a.docx","pages":12,"cached":true,"ms":4}"#.utf8))

        XCTAssertEqual(response.success, true)
        XCTAssertEqual(response.pages, 12)
        XCTAssertEqual(response.cached, true)
    }
}
