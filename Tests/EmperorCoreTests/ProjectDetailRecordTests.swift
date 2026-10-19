import XCTest
@testable import EmperorCore

/// The matter screen's receipt, receipt file, List of Dates and timeline, through its view model.
final class ProjectDetailRecordTests: XCTestCase {

    func testAPaymentPrintsAReceiptAndNothingElseDoes() async {
        await withRecord { model in
            let user = User(id: 1, email: "asha@example.test", name: "Asha Rao", title: "Advocate",
                            organization: "Rao Chambers", phone: "+919876543210")
            let payment = model.ledger[0]
            let receipt = try! XCTUnwrap(model.feeReceipt(for: payment, user: user))
            XCTAssertEqual(receipt.number, "2026-27/AB12CD")
            XCTAssertEqual(receipt.fileName, "Receipt 2026-27-AB12CD.pdf")
            XCTAssertTrue(receipt.html.contains("Received with thanks from <b>Acme Private Limited</b>, 12, Nehru Place, New Delhi,"))
            XCTAssertTrue(receipt.html.contains("in the\n    matter of <b>Acme v. Beta</b>, CS(OS) 512/2024, before the High Court of Delhi."))
            XCTAssertTrue(receipt.html.contains("+91 98765 43210 &middot; asha@example.test"))
            XCTAssertFalse(receipt.html.contains("receipt-print"), "the on-screen Print bar is not on paper")
            XCTAssertNil(model.feeReceipt(for: model.ledger[1], user: user), "a fee billed is not a receipt")
        }
    }

    func testTheAttachedSlipOpensByItsFolderAndName() async {
        await withRecord { model in
            XCTAssertEqual(model.receiptAttachment(for: model.ledger[0]),
                           ChatAttachment(name: "UPI slip.pdf", folderName: "_projects/p1/Receipts"))
            XCTAssertNil(model.receiptAttachment(for: model.ledger[1]))
        }
    }

    func testTheListOfDatesFollowsTheChosenGroups() async {
        await withRecord { model in
            let html = try! XCTUnwrap(model.listOfDates(groups: ChronologyExport.defaultGroups))
            XCTAssertTrue(html.hasPrefix("<p style=\"text-align:center\"><strong>IN THE HIGH COURT OF DELHI</strong></p>"))
            XCTAssertTrue(html.contains("<tr><td>15.01.2023</td><td><p>Agreement to sell executed</p></td></tr>"))
            XCTAssertFalse(html.contains("listed"), "listings are out by default")
            let all = try! XCTUnwrap(model.listOfDates(groups: Set(ChronologyExport.Group.allCases)))
            XCTAssertTrue(all.contains("<p>The matter was listed for For arguments before Justice A.</p>"))
        }
    }

    func testTheTimelineMergesBothRecordsAndSaysWhoseEachIs() async {
        await withRecord { model in
            let rows = model.timelineRows(today: "2026-10-19")
            XCTAssertEqual(rows.map(\.id), ["next", "y2026", "c:c1", "y2023", "u:u1"])
            XCTAssertEqual(rows[0].subtitle, "in 9 days")
            XCTAssertEqual(rows[2].kind, .entry(kind: "hearing", origin: .court))
            XCTAssertEqual(rows[4].kind, .entry(kind: "event", origin: .manual))
            XCTAssertEqual(rows.map(\.isFlipped), [false, true, false, true, false])
        }
    }
}

@MainActor
private func withRecord(_ body: @MainActor (ProjectDetailViewModel) async -> Void) async {
    let fake = RecordFake()
    var project = Project(id: "p1")
    project.name = "Acme v. Beta"
    project.client = "Acme Private Limited"
    project.forumName = "High Court of Delhi"
    project.caseType = "CS(OS)"
    project.caseNumber = "512"
    project.caseYear = "2024"
    fake.detail = ProjectDetail(
        project: project,
        updates: [ProjectUpdate(id: "u1", kind: "event", title: "Agreement to sell executed", eventDateRaw: "2023-01-15")],
        courtHistory: [CaseItem(id: "c1", section: "hearings", title: "For arguments", subtitle: "Justice A",
                                itemDateRaw: "2026-08-12")],
        linkedCase: LinkedCaseSummary(nextHearingDateRaw: "2026-10-28"),
        ledger: [
            LedgerEntry(id: "led_m3k9x2_ab12cd", kind: "payment", amountPaise: 2_500_000, entryDateRaw: "2026-10-01",
                        mode: "upi", reference: "41290031", receiptFile: "_projects/p1/Receipts/UPI slip.pdf"),
            LedgerEntry(id: "led_fee", kind: "fee", amountPaise: 5_000_000, entryDateRaw: "2026-09-01"),
        ],
        people: [ProjectPerson(id: "pp1", role: "client", name: "acme private limited", address: "12, Nehru Place, New Delhi")])
    let model = ProjectDetailViewModel(projectID: "p1", service: fake, todayKey: { "2026-10-19" })
    await model.load()
    await body(model)
}

private final class RecordFake: ProjectProviding, @unchecked Sendable {
    var detail: ProjectDetail?

    func projects(includeArchived: Bool) async throws -> [Project] { [] }

    func project(id: String) async throws -> ProjectDetail {
        guard let detail else { throw APIError.server(status: 404, message: "gone") }
        return detail
    }
}
