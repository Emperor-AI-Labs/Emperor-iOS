import XCTest
@testable import EmperorCore

/// The court, item, coram and note a cause-list row prints, held to the platform's own
/// `src/lib/causeList.js` by `CauseListDisplayGolden` (regenerate with
/// `node scripts/generate-cause-list-fixtures.mjs <platform>`).
final class CauseListDisplayTests: XCTestCase {

    private struct GoldenCase: Decodable {
        struct Expected: Decodable {
            let courtNo: String?
            let itemNo: String?
            let coram: String?
            let time: String?
            let note: String?
        }
        let name: String
        let listing: CauseListing
        let expected: Expected
    }

    private static func goldenCases() throws -> [GoldenCase] {
        try JSONDecoder().decode([GoldenCase].self, from: Data(CauseListDisplayGolden.json.utf8))
    }

    private func decode(_ json: String) throws -> CauseListing {
        try JSONDecoder().decode(CauseListing.self, from: Data(json.utf8))
    }

    // MARK: - The platform's answers

    /// Every case, every field. A single mismatch names the case, so a regenerated fixture that
    /// moves one rule points straight at it.
    func testEveryGoldenCaseMatchesThePlatform() throws {
        let cases = try Self.goldenCases()
        XCTAssertGreaterThan(cases.count, 30, "the fixture lost its cases")
        for golden in cases {
            let listing = golden.listing
            XCTAssertEqual(
                CauseListText.courtRoom(listing), golden.expected.courtNo, "\(golden.name): court")
            XCTAssertEqual(
                CauseListText.itemNumber(listing), golden.expected.itemNo, "\(golden.name): item")
            XCTAssertEqual(
                CauseListText.coram(listing), golden.expected.coram, "\(golden.name): coram")
            XCTAssertEqual(
                CauseListText.time(listing), golden.expected.time, "\(golden.name): time")
            XCTAssertEqual(
                CauseListText.listingNote(listing), golden.expected.note, "\(golden.name): note")
        }
    }

    // MARK: - The rules, said out loud

    /// The one that sends people to the wrong door. A court-published row's bench "Court 236" is
    /// a roster code and its purpose a roster line; only its own `courtNo` is a room.
    func testACourtPublishedRowNeverReadsARoomOrItemOutOfItsText() throws {
        let listing = try decode("""
            {"date":"2026-09-14","caseId":"c1","title":"X v. Y","scraped":true,
             "courtNo":null,"itemNo":null,"bench":"Court 236",
             "purpose":"TO BE LISTED IN COURT NO.270 AT ITEM 7","stage":"Item 9"}
            """)
        XCTAssertNil(listing.display.room)
        XCTAssertNil(listing.display.item)
    }

    /// The same text on a hand-entered row is still read, as the web reads it.
    func testAHandEnteredRowStillReadsItsOwnText() throws {
        let listing = try decode("""
            {"date":"2026-09-14","caseId":"c1","title":"X v. Y","scraped":false,
             "purpose":"TO BE LISTED IN COURT NO. 1 AT ITEM NO. 15"}
            """)
        XCTAssertEqual(listing.display.room, "Court 1")
        XCTAssertEqual(listing.display.item, "15")
    }

    /// No fallback to the row's position: an unnumbered matter prints no number.
    func testAnUnnumberedListingHasNoItemRatherThanItsPosition() throws {
        let listing = try decode("""
            {"date":"2026-09-14","caseId":"c1","title":"X v. Y","purpose":"Next hearing",
             "source":"next"}
            """)
        XCTAssertNil(listing.display.item)
        XCTAssertNil(listing.display.room)
        XCTAssertNil(listing.display.note, "'Next hearing' is a placeholder, not a purpose")
    }

    func testARegistrarCourtIsNotCourtOne() throws {
        let listing = try decode("""
            {"date":"2026-09-14","caseId":"c1","scraped":true,"courtNo":"Registrar Court No. 1"}
            """)
        XCTAssertEqual(listing.display.room, "Registrar Court 1")
        XCTAssertNil(listing.display.roomNumber, "it does not fit the numbered badge")
        XCTAssertEqual(listing.display.roomInFull, "Registrar Court 1")
        XCTAssertEqual(
            listing.display.forum(courtName: "Supreme Court of India"),
            "Supreme Court of India · Registrar Court 1", "so it is said on the forum line")
    }

    func testTheSpokenRowLeadsWithWhereItIsHeard() throws {
        let listing = try decode("""
            {"date":"2026-09-14","caseId":"c1","title":"X v. Y","courtName":"Delhi High Court",
             "scraped":true,"courtNo":"Court 4","itemNo":"12","coram":"Justice A",
             "caseNumber":"1","caseYear":"2024","remarks":"Part-heard"}
            """)
        XCTAssertEqual(
            listing.display.spoken(listing),
            "Item 12, Court 4. X v. Y. Delhi High Court · Justice A. 1/2024. Part-heard")
    }

    func testANumberedRoomFitsTheBadge() throws {
        let listing = try decode("""
            {"date":"2026-09-14","caseId":"c1","scraped":true,"courtNo":"COURT NO.270","itemNo":"12"}
            """)
        XCTAssertEqual(listing.display.roomNumber, "270")
        XCTAssertNil(listing.display.roomInFull)
        XCTAssertEqual(listing.display.spokenLocation, "Item 12, Court 270")
    }

    func testTheCoramIsNeverTheForumItself() throws {
        let listing = try decode("""
            {"date":"2026-09-14","caseId":"c1","courtName":"State Commission",
             "coram":"State Commission","bench":"State Commission"}
            """)
        XCTAssertNil(listing.display.coram)
        XCTAssertEqual(listing.display.forum(courtName: listing.courtName), "State Commission")
    }

    /// A stage reading "Item 12" under a badge already saying item 12 is dropped, not doubled.
    func testANoteThatOnlyRestatesTheItemIsDropped() throws {
        let listing = try decode("""
            {"date":"2026-09-14","caseId":"c1","source":"next","purpose":"Next hearing",
             "stage":"Item 12","itemNo":"12"}
            """)
        XCTAssertEqual(CauseListText.listingNote(listing), "Item 12", "the platform's note")
        XCTAssertNil(listing.display.note, "but the row does not print it twice")
    }

    func testTheDetailLineCarriesNumberTimeAndCounsel() throws {
        let listing = try decode("""
            {"date":"2026-09-14","caseId":"c1","caseNumber":"1234","caseYear":"2024",
             "time":"10:30 AM","advocates":"P: A. Rao | R: B. Sen","scraped":true}
            """)
        XCTAssertEqual(listing.display.detailLine, "1234/2024 · 10:30 AM · P: A. Rao | R: B. Sen")
    }

    func testTheCaseNumberFallsBackToTheCNROrDiaryNumber() throws {
        let listing = try decode("""
            {"date":"2026-09-14","caseId":"c1","cnr":"12852/2024"}
            """)
        XCTAssertEqual(listing.display.reference, "12852/2024")
    }

    func testRomanRoomsSortByValue() {
        XCTAssertEqual(CauseListText.romanValue("II"), 2)
        XCTAssertEqual(CauseListText.romanValue("iv"), 4)
        XCTAssertEqual(CauseListText.romanValue("XL"), 40)
        XCTAssertNil(CauseListText.romanValue("A"))
    }

    // MARK: - Decoding

    /// A hearing entry as `/cause-list` now builds it, every key present.
    func testAHearingEntryDecodesTheNewCourtFields() throws {
        let listing = try decode("""
            {"date":"2026-09-14","caseId":"case_1","teamId":"team_1","title":"Menon vs. Union of India",
             "parties":"Menon vs. Union of India","caseType":"W.P.(C)","category":null,
             "diaryNumber":null,"courtName":"Delhi High Court","courtType":"hc",
             "caseNumber":"1234","caseYear":"2024","cnr":"DLHC010012342024","judge":null,
             "coram":"HON'BLE MR. JUSTICE PRATEEK JALAN","ndoh":"2026-10-01",
             "purpose":"For final disposal","bench":"HON'BLE MR. JUSTICE PRATEEK JALAN",
             "courtNo":"Court 30","itemNo":"12","listType":"Supplementary List",
             "time":"10:30 AM","scraped":true,"advocates":"P: A. Rao | R: B. Sen",
             "stage":null,"remarks":null,"source":"causelist"}
            """)
        XCTAssertEqual(listing.courtNo, "Court 30")
        XCTAssertEqual(listing.itemNo, "12")
        XCTAssertEqual(listing.coram, "HON'BLE MR. JUSTICE PRATEEK JALAN")
        XCTAssertEqual(listing.time, "10:30 AM")
        XCTAssertEqual(listing.scraped, true)
        XCTAssertEqual(listing.listType, "Supplementary List")
        XCTAssertEqual(listing.advocates, "P: A. Rao | R: B. Sen")
        XCTAssertEqual(listing.caseType, "W.P.(C)")
        XCTAssertEqual(listing.ndoh, "2026-10-01")
    }

    /// A next-hearing entry omits `bench`, `remarks`, `listType`, `time` and `scraped`
    /// entirely. Every one of them must be optional, or one such case blanks the whole list.
    func testANextHearingEntryDecodesWithItsAbsentKeys() throws {
        let listing = try decode("""
            {"date":"2026-09-14","caseId":"case_1","teamId":"team_1","title":"X v. Y",
             "parties":null,"caseType":null,"category":null,"diaryNumber":null,
             "courtName":"Delhi High Court","courtType":"hc","caseNumber":"1","caseYear":"2024",
             "cnr":null,"judge":"Justice Navin Chawla","coram":"Justice Navin Chawla",
             "ndoh":"2026-09-14","purpose":"Next hearing","stage":"Arguments","source":"next",
             "courtNo":"Court 30","itemNo":null,"advocates":null}
            """)
        XCTAssertNil(listing.scraped)
        XCTAssertNil(listing.time)
        XCTAssertNil(listing.bench)
        XCTAssertEqual(listing.display.room, "Court 30")
    }

    /// A list cached by an older build has none of the new keys, and must still load.
    func testAnOlderCachedListingStillDecodes() throws {
        let listing = try decode("""
            {"date":"2026-09-14","caseId":"case_1","title":"X v. Y","bench":"Court 4",
             "itemNo":"3","source":"hearing"}
            """)
        XCTAssertNil(listing.courtNo)
        XCTAssertEqual(listing.display.item, "3")
        XCTAssertEqual(listing.display.room, "Court 4", "read from a hand-entered bench, as before")
    }

    /// The bench, purpose and room are copied out of stored JSON blobs without coercion, so a
    /// blob holding a number puts a number on the wire. One odd row must not cost the list.
    func testANumberWhereTextIsExpectedDoesNotFailTheWholeList() throws {
        let response = try JSONDecoder().decode(CauseListResponse.self, from: Data("""
            {"success":true,"listings":[
              {"date":"2026-09-14","caseId":"c1","bench":4,"courtNo":4,"itemNo":7,"time":1030,
               "scraped":1},
              {"date":"2026-09-14","caseId":"c2","title":"Fine"}
            ]}
            """.utf8))
        let listings = try XCTUnwrap(response.listings)
        XCTAssertEqual(listings.count, 2)
        XCTAssertEqual(listings[0].bench, "4")
        XCTAssertEqual(listings[0].itemNo, "7")
        XCTAssertEqual(listings[0].scraped, true)
        XCTAssertEqual(listings[0].display.room, "Court 4")
    }

    func testARowWithoutItsDateOrCaseIsStillRefused() {
        XCTAssertThrowsError(try decode(#"{"caseId":"c1"}"#))
        XCTAssertThrowsError(try decode(#"{"date":"2026-09-14"}"#))
    }

    /// The cache writes with the synthesised encoder and reads with the lenient decoder; the two
    /// must agree on every key, or a cached list would come back missing its rooms.
    func testAListingSurvivesTheCacheRoundTrip() throws {
        let original = try decode("""
            {"date":"2026-09-14","caseId":"c1","courtNo":"Court 4","itemNo":"12","coram":"J",
             "time":"10:30 AM","scraped":true,"listType":"Daily","advocates":"A",
             "parties":"P","caseType":"T","category":"C","diaryNumber":"D","ndoh":"2026-09-20"}
            """)
        let roundTripped = try JSONDecoder().decode(
            CauseListing.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(roundTripped, original)
    }
}
