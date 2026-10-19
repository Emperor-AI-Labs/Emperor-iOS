import XCTest
@testable import EmperorCore

/// `case_items.data` is a JSON string on `GET /case` and an already-parsed object on
/// `GET /project`'s `courtHistory` (`lib/projects/store.js`, `courtHistoryOf`). Both must decode.
final class CourtHistoryDecodingTests: XCTestCase {

    func testAnObjectDataBlobDecodesAndReads() throws {
        let response = try JSONDecoder().decode(ProjectDetailResponse.self, from: Data("""
            {"success":true,"project":{"id":"p1","name":"M"},"updates":[],
             "courtHistory":[{"id":"i1","section":"hearings","title":"For arguments",
               "subtitle":null,"item_date":"2026-08-12","status":null,"source":"scrape",
               "data":{"courtNo":4,"itemNo":"12","coram":"Hon'ble Mr Justice A","purpose":"For arguments"}}]}
            """.utf8))
        let item = try XCTUnwrap(response.courtHistory?.first)
        XCTAssertEqual(item.dataString("coram"), "Hon'ble Mr Justice A")
        XCTAssertEqual(item.data["courtNo"]?.intValue, 4)
        XCTAssertEqual(item.source, "scrape")
    }

    func testAStringDataBlobStillDecodes() throws {
        let item = try JSONDecoder().decode(CaseItem.self, from: Data("""
            {"id":"i1","section":"orders","title":"Order","item_date":"2026-08-12",
             "data":"{\\"url\\":\\"https://example.test/o.pdf\\"}"}
            """.utf8))
        XCTAssertEqual(item.dataString("url"), "https://example.test/o.pdf")
    }

    func testANullOrMissingBlobIsNil() throws {
        let a = try JSONDecoder().decode(CaseItem.self, from: Data(#"{"id":"a","section":"orders","data":null}"#.utf8))
        let b = try JSONDecoder().decode(CaseItem.self, from: Data(#"{"id":"b","section":"orders"}"#.utf8))
        XCTAssertNil(a.dataRaw)
        XCTAssertNil(b.dataRaw)
        XCTAssertEqual(a.data, [:])
    }
}
