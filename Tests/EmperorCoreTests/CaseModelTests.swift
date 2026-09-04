import XCTest
@testable import EmperorCore

/// Decoding against the real payload shapes, with emphasis on the ones that fail *silently*
/// or fail the whole request rather than one field.
final class CaseModelTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: - The decode-breaking shapes

    /// **The one that takes the whole screen down.** On a `source: "next"` cause-list entry the
    /// server spreads a smaller object, so `bench`, `itemNo` and `remarks` are *absent keys*
    /// rather than nulls (`sync-server.js:9771` vs `:9760-9764`). A non-optional property here
    /// throws `keyNotFound` and fails the entire listings array — for exactly the users whose
    /// cases have next hearing dates.
    func testANextHearingListingDecodesDespiteThreeAbsentKeys() throws {
        let listing = try decode(CauseListing.self, """
            {"date":"2026-09-14","caseId":"case_1","teamId":"team_1",
             "title":"Menon vs. Union of India","courtName":"Delhi High Court",
             "courtType":"hc","caseNumber":"1234","caseYear":"2024",
             "cnr":"DLHC010012342024","judge":null,
             "purpose":"Next hearing","stage":"Arguments","source":"next"}
            """)

        XCTAssertEqual(listing.caseID, "case_1")
        XCTAssertNil(listing.bench)
        XCTAssertNil(listing.itemNo)
        XCTAssertNil(listing.remarks)
        XCTAssertEqual(listing.source, "next")
    }

    func testAHearingListingCarriesTheExtraKeys() throws {
        let listing = try decode(CauseListing.self, """
            {"date":"2026-09-14","caseId":"case_1","title":"X vs. Y",
             "purpose":"For final disposal","bench":"HON'BLE MR. JUSTICE A",
             "stage":"Final","itemNo":"12","remarks":"Part-heard","source":"hearing"}
            """)

        XCTAssertEqual(listing.bench, "HON'BLE MR. JUSTICE A")
        XCTAssertEqual(listing.itemNo, "12")
        XCTAssertEqual(listing.remarks, "Part-heard")
    }

    /// `case_number` and `case_year` are TEXT columns (`sync-server.js:3333-3334`), so a JSON
    /// number sent in comes back as a string. An `Int?` model would fail to decode.
    func testCaseNumberAndYearDecodeAsStrings() throws {
        let legalCase = try decode(LegalCase.self, """
            {"id":"case_1","case_number":"1234","case_year":"2024"}
            """)

        XCTAssertEqual(legalCase.caseNumber, "1234")
        XCTAssertEqual(legalCase.caseYear, "2024")
        XCTAssertEqual(legalCase.caseReference, "1234/2024")
    }

    /// A 500 body carries **no `success` key at all** (`sync-server.js:9687-9689`), unlike the
    /// 403/404/409 bodies. A non-optional `success` would fail to decode every server error.
    func testAnErrorEnvelopeWithNoSuccessKeyStillDecodes() throws {
        let response = try decode(CaseListResponse.self, #"{"error":"Missing userId"}"#)

        XCTAssertNil(response.success)
        XCTAssertEqual(response.error, "Missing userId")
        XCTAssertThrowsError(
            try CaseService.throwIfUnsuccessful(
                success: response.success, error: response.error))
    }

    func testSuccessEnvelopePasses() throws {
        XCTAssertNoThrow(try CaseService.throwIfUnsuccessful(success: true, error: nil))
        XCTAssertThrowsError(try CaseService.throwIfUnsuccessful(success: false, error: "Forbidden"))
    }

    // MARK: - The polymorphic `parties` column

    /// `parties` is variously a JSON array serialised into a string, the literal `"[]"`, or
    /// free prose written by the scraper. A case with no title would otherwise render as a
    /// matter literally called `[]` — the server's own cause list does exactly that
    /// (`sync-server.js:9739`).
    func testTheEmptyPartiesSentinelNeverBecomesATitle() throws {
        let legalCase = try decode(LegalCase.self, #"{"id":"c","title":null,"parties":"[]"}"#)
        XCTAssertEqual(legalCase.displayTitle, "Untitled case")
    }

    func testProsePartiesAreUsedWhenThereIsNoTitle() throws {
        let legalCase = try decode(LegalCase.self, """
            {"id":"c","title":null,"parties":"Ravindra Menon vs. Union of India"}
            """)
        XCTAssertEqual(legalCase.displayTitle, "Ravindra Menon vs. Union of India")
    }

    func testTitleWinsWhenPresent() throws {
        let legalCase = try decode(LegalCase.self, """
            {"id":"c","title":"Partition suit","parties":"A vs. B"}
            """)
        XCTAssertEqual(legalCase.displayTitle, "Partition suit")
    }

    // MARK: - Three timestamp encodings in one response

    /// `GET /case` ships ISO8601-with-milliseconds on the case, zoneless SQLite
    /// `CURRENT_TIMESTAMP` on events (the INSERT omits the column so the DDL default fires),
    /// and bare `YYYY-MM-DD` on date columns — all at once. One `dateDecodingStrategy` cannot
    /// read all three, which is why every timestamp is decoded as a string and parsed here.
    func testAllThreeTimestampEncodingsParse() throws {
        let legalCase = try decode(LegalCase.self, """
            {"id":"c","updated_at":"2026-08-26T04:15:09.882Z","next_hearing_date":"2026-09-14"}
            """)
        XCTAssertNotNil(legalCase.updatedAt, "ISO8601 with milliseconds")
        XCTAssertNotNil(legalCase.nextHearingDate, "bare YYYY-MM-DD")

        let event = try decode(CaseEvent.self, """
            {"id":"e","created_at":"2026-08-26 04:20:00","event_date":null}
            """)
        XCTAssertNotNil(event.eventDate, "zoneless SQLite CURRENT_TIMESTAMP")
    }

    /// A court date is a day in India. Parsing it in the device's zone shifts it by one for
    /// anyone west of IST.
    func testACourtDayIsParsedInIndiaNotTheDeviceZone() throws {
        let date = try XCTUnwrap(WireDate.parseDay("2026-09-14"))
        XCTAssertEqual(WireDate.dayKey(date), "2026-09-14", "round-trips through India")

        // Midnight IST on 14 Sept is 18:30 UTC on the 13th. Confirms the offset is applied.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(utc.component(.day, from: date), 13)
        XCTAssertEqual(utc.component(.hour, from: date), 18)
    }

    // MARK: - Scraped rows

    /// Every `source: "scrape"` row is deleted and re-inserted with a fresh id on each refresh
    /// (`court-scraper/materialize.js:59-69`), so an edit is silently discarded and a cached id
    /// dangles. The app must know not to offer the edit.
    func testScrapedRowsAreMarkedCourtOwned() throws {
        let scraped = try decode(CaseItem.self, """
            {"id":"i1","section":"hearings","source":"scrape","ext_key":"h-1x9abc"}
            """)
        XCTAssertTrue(scraped.isCourtOwned)
        XCTAssertEqual(scraped.extKey, "h-1x9abc")

        // A row created through the API omits `source`, so the DEFAULT 'user' fires.
        let userRow = try decode(CaseItem.self, #"{"id":"i2","section":"tasks","source":"user"}"#)
        XCTAssertFalse(userRow.isCourtOwned)
    }

    /// `data` arrives as a JSON object serialised **into a string** and must be parsed twice.
    func testTheDataBlobIsParsedFromItsString() throws {
        let item = try decode(CaseItem.self, """
            {"id":"i","section":"hearings",
             "data":"{\\"purpose\\":\\"For final disposal\\",\\"bench\\":\\"COURT NO. 258\\"}"}
            """)

        XCTAssertEqual(item.dataString("purpose"), "For final disposal")
        XCTAssertEqual(item.dataString("bench"), "COURT NO. 258")
    }

    /// A malformed blob must not take the whole row down — the row still carries a title, a
    /// date and a section that are worth showing.
    func testAMalformedDataBlobYieldsAnEmptyDictionaryRatherThanThrowing() throws {
        let item = try decode(CaseItem.self, """
            {"id":"i","section":"hearings","title":"Listed","data":"{not json"}
            """)
        XCTAssertTrue(item.data.isEmpty)
        XCTAssertEqual(item.title, "Listed")
    }

    // MARK: - Order PDFs

    /// All three court proxies answer **200 with an HTML error page** on every failure. A 200
    /// proves nothing; the bytes have to be sniffed.
    func testPDFDetectionUsesTheMagicBytes() {
        XCTAssertTrue(CaseService.looksLikePDF(Data("%PDF-1.4\n…".utf8)))
        XCTAssertFalse(CaseService.looksLikePDF(Data("<div style='padding:2rem'>No order</div>".utf8)))
        XCTAssertFalse(CaseService.looksLikePDF(Data()))
    }

    /// The server writes a real sentence inside that HTML. Recovering it beats "something went
    /// wrong" — it says whether the order is missing, or the matter is, or the portal is down.
    func testTheErrorPageSentenceIsRecovered() {
        let html = "<div style=\"padding:2rem;font-family:sans-serif\">The court portal has no order document available for this case.</div>"
        XCTAssertEqual(
            CaseService.messageFromErrorPage(Data(html.utf8)),
            "The court portal has no order document available for this case.")
    }

    func testAnUnparseableErrorPageStillProducesAMessage() {
        XCTAssertFalse(CaseService.messageFromErrorPage(Data()).isEmpty)
    }

    func testOrderPathsMapFromCourtType() {
        XCTAssertEqual(CaseService.orderPath(forCourtType: "hc"), "/court/hc/order")
        XCTAssertEqual(CaseService.orderPath(forCourtType: "tribunal"), "/court/tribunal/order")
        XCTAssertEqual(CaseService.orderPath(forCourtType: "forum"), "/court/forum/order")
        XCTAssertNil(CaseService.orderPath(forCourtType: "district"),
                     "district has no order proxy — the adapter is not wired")
        XCTAssertNil(CaseService.orderPath(forCourtType: "sc"))
    }

    /// **NCLT and NCLAT are tribunals, but the tribunal proxy will not serve them.** It rejects
    /// anything whose `court_type` is not literally `'tribunal'` (`sync-server.js:9282`), and
    /// those cases are stored as `'nclt'`/`'nclat'` (`:8876, 8919-8924`) — so routing them there
    /// could never succeed, and every tap returned an HTML page reading "available for tribunal
    /// cases only" to someone plainly looking at a tribunal case.
    func testNCLTAndNCLATAreNotRoutedToAProxyThatWillRejectThem() {
        XCTAssertNil(CaseService.orderPath(forCourtType: "nclt"))
        XCTAssertNil(CaseService.orderPath(forCourtType: "nclat"))
    }

    // MARK: - Sections

    /// `/cause-list` reads only `hearings` and `causelist` (`sync-server.js:9753`). A hearing
    /// filed under any other spelling is accepted with a 200 and then never appears.
    func testOnlyTwoSectionsReachTheCauseList() {
        XCTAssertEqual(CaseSection.causeListSections, ["hearings", "causelist"])
        XCTAssertFalse(CaseSection.causeListSections.contains("hearing"))
        XCTAssertFalse(CaseSection.causeListSections.contains("Hearings"))
    }
}
