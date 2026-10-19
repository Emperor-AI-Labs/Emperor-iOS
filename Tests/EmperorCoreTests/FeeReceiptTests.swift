import XCTest
@testable import EmperorCore

/// The fee receipt against the web's own `receipt.js` and `inr.js`, run under Node (regenerate
/// with `node scripts/generate-fee-receipt-fixtures.mjs <platform>`).
final class FeeReceiptGoldenTests: XCTestCase {

    static func root() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "receipt", withExtension: "json", subdirectory: "fee-receipt"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    static func list(_ key: String) throws -> [[String: Any]] {
        try XCTUnwrap(root()[key] as? [[String: Any]], key)
    }

    /// Decodes a wire-shaped object, giving it an id when the fixture has none.
    static func decode<T: Decodable>(_ type: T.Type, _ object: Any?, id: Any = "x") throws -> T {
        var dict = (object as? [String: Any]) ?? [:]
        if dict["id"] == nil { dict["id"] = id }
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: dict))
    }

    static func people(_ object: Any?) throws -> [ProjectPerson] {
        try ((object as? [[String: Any]]) ?? []).enumerated().map { try decode(ProjectPerson.self, $1, id: "p\($0)") }
    }

    func testAmountsInWords() throws {
        for item in try Self.list("words") {
            let paise = try XCTUnwrap(item["paise"] as? NSNumber).int64Value
            XCTAssertEqual(RupeeText.words(paise: paise), item["text"] as? String, "\(paise)")
        }
    }

    func testFigures() throws {
        for item in try Self.list("figures") {
            let paise = try XCTUnwrap(item["paise"] as? NSNumber).int64Value
            XCTAssertEqual(RupeeText.figure(paise: paise), item["text"] as? String, "\(paise)")
        }
    }

    func testFinancialYears() throws {
        for item in try Self.list("financialYears") {
            let day = item["day"] as? String
            XCTAssertEqual(RupeeText.financialYear(day), item["text"] as? String, day ?? "nil")
        }
    }

    func testReceiptNumbers() throws {
        for item in try Self.list("receiptNumbers") {
            let entry = try XCTUnwrap(item["entry"] as? [String: Any])
            XCTAssertEqual(
                RupeeText.receiptNumber(
                    id: entry["id"] as? String, entryDate: entry["entry_date"] as? String,
                    createdAt: entry["created_at"] as? String),
                item["text"] as? String)
        }
    }

    func testCaseNumbersAndMatters() throws {
        for item in try Self.list("caseNumbers") {
            let project = try Self.decode(Project.self, item["project"])
            XCTAssertEqual(FeeReceipt.caseNumber(of: project), item["text"] as? String)
        }
        for item in try Self.list("matters") {
            let project = try Self.decode(Project.self, item["project"])
            let web = try XCTUnwrap(item["matter"] as? [String: String])
            let ours = FeeReceipt.matter(from: project)
            XCTAssertEqual([ours.title, ours.caseNo, ours.forum], [web["title"], web["caseNo"], web["forum"]])
        }
    }

    func testClientsAndAdvocates() throws {
        for item in try Self.list("clients") {
            let project = try Self.decode(Project.self, item["project"])
            let web = try XCTUnwrap(item["client"] as? [String: String])
            let ours = FeeReceipt.client(project: project, people: try Self.people(item["people"]))
            XCTAssertEqual([ours.name, ours.address], [web["name"], web["address"]])
        }
        for item in try Self.list("advocates") {
            let user = try Self.decode(User.self, item["user"])
            let web = try XCTUnwrap(item["advocate"] as? [String: String])
            let ours = FeeReceipt.advocate(from: user)
            XCTAssertEqual(
                [ours.name, ours.designation, ours.chambers, ours.phone, ours.email],
                [web["name"], web["designation"], web["chambers"], web["phone"], web["email"]])
        }
    }

    /// The whole document, byte for byte.
    func testEveryReceiptIsTheWebsDocument() throws {
        let receipts = try Self.list("receipts")
        XCTAssertEqual(receipts.count, 7)
        for item in receipts {
            let name = item["name"] as? String ?? "?"
            let project = try Self.decode(Project.self, item["project"])
            let entry = try Self.decode(LedgerEntry.self, item["entry"])
            let html = FeeReceipt.html(
                advocate: FeeReceipt.advocate(from: try Self.decode(User.self, item["user"])),
                client: FeeReceipt.client(project: project, people: try Self.people(item["people"])),
                matter: FeeReceipt.matter(from: project),
                entry: entry)
            let web = try XCTUnwrap(item["html"] as? String)
            if html != web {
                let ours = html.components(separatedBy: "\n"), theirs = web.components(separatedBy: "\n")
                for (index, pair) in zip(ours, theirs).enumerated() where pair.0 != pair.1 {
                    XCTFail("\(name) line \(index + 1):\n ours: \(pair.0)\n web:  \(pair.1)")
                    break
                }
                XCTAssertEqual(ours.count, theirs.count, name)
            }
        }
    }

    // MARK: - This client's own

    func testThePrintableCopyDropsTheBarAndAppliesThePrintRules() throws {
        let entry = LedgerEntry(id: "led_1", kind: "payment", amountPaise: 600_000, entryDateRaw: "2026-10-01", mode: "cash")
        let html = FeeReceipt.printableHTML(
            advocate: .init(name: "Asha Rao"), client: .init(name: "Acme"), matter: .init(title: "Acme v. Beta"),
            entry: entry)
        XCTAssertFalse(html.contains("receipt-print"))
        XCTAssertTrue(html.contains("  .sheet { width: auto; margin: 0; padding: 0; box-shadow: none; }\n</style>"))
        XCTAssertTrue(html.contains("Revenue<br>stamp"), "₹6,000 is above the stamp line")
        XCTAssertTrue(html.contains("Rupees Six Thousand Only"))
        XCTAssertEqual(FeeReceipt.fileName(for: entry), "Receipt 2026-27-LED1.pdf")
    }

    func testTheAttachedFileIsNamedByItsLastPart() {
        XCTAssertEqual(FeeReceipt.attachedFileName("_projects/p1/Receipts/slip.pdf"), "slip.pdf")
        XCTAssertEqual(FeeReceipt.attachedFileName("Receipts\\scan 2.jpg"), "scan 2.jpg")
        XCTAssertNil(FeeReceipt.attachedFileName(""))
        XCTAssertNil(FeeReceipt.attachedFileName(nil))
    }

    func testIndianGrouping() {
        XCTAssertEqual(RupeeText.indianGrouped(0), "0")
        XCTAssertEqual(RupeeText.indianGrouped(999), "999")
        XCTAssertEqual(RupeeText.indianGrouped(1000), "1,000")
        XCTAssertEqual(RupeeText.indianGrouped(125_000), "1,25,000")
        XCTAssertEqual(RupeeText.indianGrouped(12_345_678_901), "12,34,56,78,901")
    }
}
