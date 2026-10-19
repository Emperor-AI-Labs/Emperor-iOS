import XCTest
@testable import EmperorCore

/// The day's cause list as downloaded, held to the web's own export of the same listings: the
/// courts and their order, every cell, the date line and the CSV byte for byte.
final class CauseListExportTests: XCTestCase {

    private struct Golden: Decodable {
        struct Group: Decodable {
            let courtName: String
            let rows: [Row]
        }
        struct Row: Decodable {
            let caseId: String
            let courtNo, item, parties, appealOrCaseNo, category, coram, advocates, suppl, time, note: String
        }
        let day: String
        let longDay: String
        let groups: [Group]
        let csv: String
    }

    private static func golden() throws -> Golden {
        try JSONDecoder().decode(Golden.self, from: Data(CauseListExportGolden.json.utf8))
    }

    /// The fixture's `entries`, decoded the way `/cause-list` is.
    private static func listings() throws -> [CauseListing] {
        struct Entries: Decodable { let entries: [CauseListing] }
        return try JSONDecoder().decode(Entries.self, from: Data(CauseListExportGolden.json.utf8)).entries
    }

    func testTheCourtsComeInTheHierarchysOrder() throws {
        let groups = CauseListExport.groups(try Self.listings())
        XCTAssertEqual(groups.map(\.courtName), try Self.golden().groups.map(\.courtName))
    }

    func testEveryCellMatchesThePlatform() throws {
        let groups = CauseListExport.groups(try Self.listings())
        let expected = try Self.golden().groups
        XCTAssertEqual(groups.count, expected.count)
        for (group, want) in zip(groups, expected) {
            XCTAssertEqual(group.rows.map(\.caseID), want.rows.map(\.caseId), group.courtName)
            for (row, cell) in zip(group.rows, want.rows) {
                let label = "\(group.courtName) / \(cell.caseId)"
                XCTAssertEqual(row.courtNo, cell.courtNo, label)
                XCTAssertEqual(row.item, cell.item, label)
                XCTAssertEqual(row.parties, cell.parties, label)
                XCTAssertEqual(row.appealOrCaseNo, cell.appealOrCaseNo, label)
                XCTAssertEqual(row.category, cell.category, label)
                XCTAssertEqual(row.coram, cell.coram, label)
                XCTAssertEqual(row.advocates, cell.advocates, label)
                XCTAssertEqual(row.suppl, cell.suppl, label)
                XCTAssertEqual(row.time, cell.time, label)
                XCTAssertEqual(row.note, cell.note, label)
            }
        }
    }

    func testTheCSVIsTheWebsByteForByte() throws {
        XCTAssertEqual(CauseListExport.csv(try Self.listings()), try Self.golden().csv)
    }

    func testTheDateLineIsTheWebs() throws {
        let golden = try Self.golden()
        XCTAssertEqual(CauseListExport.longDay(golden.day), golden.longDay)
    }

    func testTheFileNamesAreTheWebs() {
        XCTAssertEqual(CauseListExport.fileName(day: "2026-10-19", format: .csv), "cause-list-2026-10-19.csv")
        XCTAssertEqual(CauseListExport.fileName(day: "2026-10-19", format: .docx), "cause-list-2026-10-19.docx")
        XCTAssertEqual(CauseListExport.fileName(day: "2026-10-19", format: .pdf), "cause-list-2026-10-19.pdf")
        XCTAssertEqual(CauseListExport.Format.allCases.map(\.label), ["PDF", "Word (.docx)", "CSV"])
    }

    func testTheDocumentHasTheColumnsAHeadingPerCourtAndTheDisclaimer() throws {
        let listings = try Self.listings()
        let html = CauseListExport.html(day: "2026-10-19", listings: listings, format: .docx)
        XCTAssertTrue(html.hasPrefix("<h1>Daily Cause List</h1>"))
        XCTAssertTrue(html.contains("Mon, 19 Oct 2026 — \(listings.count) matters across 10 courts"))
        XCTAssertTrue(html.contains("<th>Court No.</th><th>Item</th><th>Cause Title</th><th>CORAM</th><th>Advocate(s)</th><th>SUPPL</th>"))
        XCTAssertTrue(html.contains("<h2>Supreme Court of India (3 matters)</h2>"))
        XCTAssertTrue(html.contains("Quote &quot;test&quot;, comma, and more"))
        XCTAssertTrue(html.contains(CauseListExport.wordDisclaimer))
        XCTAssertTrue(CauseListExport.html(day: "2026-10-19", listings: listings).contains(CauseListExport.pdfDisclaimer))
    }

    func testTheWordFileIsAnArchiveWithTheTable() throws {
        let data = DocxDocument.make(fromHTML: CauseListExport.html(day: "2026-10-19", listings: try Self.listings(), format: .docx))
        XCTAssertEqual(Array(data.prefix(2)), [0x50, 0x4B])
    }
}
