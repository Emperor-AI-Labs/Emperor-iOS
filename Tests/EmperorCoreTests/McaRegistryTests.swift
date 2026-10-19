import XCTest
@testable import EmperorCore

/// The MCA Registry: companies gathered from auction notices exactly as the web's
/// `groupIntoCompanies` gathers them, the requests behind the page, and its wording.
final class McaRegistryTests: XCTestCase {

    private static func notice(
        _ id: String, debtor: String?, cin: String?, issued: String? = nil
    ) -> AuctionNotice {
        AuctionNotice(id: id, corporateDebtor: debtor, cin: cin, dateIssuedRaw: issued)
    }

    // MARK: - Grouping

    /// One company per CIN whatever its casing, keeping the casing the first notice stored —
    /// the lookup compares exactly.
    func testNoticesGroupByCinIgnoringCaseAndKeepTheStoredCasing() {
        let companies = McaRegistry.groupIntoCompanies([
            Self.notice("1", debtor: "HELIOS PRIVATE", cin: "u16001ap2005plc048552"),
            Self.notice("2", debtor: "HELIOS PRIVATE LIMITED", cin: " U16001AP2005PLC048552 "),
            Self.notice("3", debtor: "ARGUS LIMITED", cin: "L17110MH1973PLC019786"),
        ])
        XCTAssertEqual(companies.map(\.key), ["U16001AP2005PLC048552", "L17110MH1973PLC019786"])
        XCTAssertEqual(companies[0].cin, "u16001ap2005plc048552")
        XCTAssertEqual(companies[0].notices.map(\.id), ["1", "2"])
    }

    /// IBBI truncates names inconsistently, so the longest spelling wins — and any real name
    /// beats the fallback.
    func testTheLongestNameWins() {
        let companies = McaRegistry.groupIntoCompanies([
            Self.notice("1", debtor: "HINDUSTAN CONTROLS & EQUIPMENT PRIVATE LIMITED", cin: "C1"),
            Self.notice("2", debtor: "HINDUSTAN CONTROLS & EQUIPMENT PRIVATE", cin: "c1"),
            Self.notice("3", debtor: nil, cin: "C2"),
            Self.notice("4", debtor: "AB", cin: "C2"),
        ])
        XCTAssertEqual(companies[0].name, "HINDUSTAN CONTROLS & EQUIPMENT PRIVATE LIMITED")
        XCTAssertEqual(companies[1].name, "AB")
    }

    func testTheLatestIssueDateIsKept() {
        let companies = McaRegistry.groupIntoCompanies([
            Self.notice("1", debtor: "A", cin: "C1", issued: "2024-03-01"),
            Self.notice("2", debtor: "A", cin: "C1", issued: nil),
            Self.notice("3", debtor: "A", cin: "C1", issued: "2025-01-09"),
            Self.notice("4", debtor: "A", cin: "C1", issued: "2024-12-31"),
        ])
        XCTAssertEqual(companies[0].latestIssued, "2025-01-09")
        XCTAssertEqual(companies[0].noticesLine, "4 notices on this page · latest issued 9 Jan 2025")
    }

    /// No CIN: grouped by name in capitals. No name either: one "unnamed" company.
    func testNoticesWithoutACinGroupByNameAndANamelessOneIsSaidSo() {
        let companies = McaRegistry.groupIntoCompanies([
            Self.notice("1", debtor: "Orion Mills", cin: nil),
            Self.notice("2", debtor: "ORION MILLS", cin: ""),
            Self.notice("3", debtor: nil, cin: "  "),
            Self.notice("4", debtor: "", cin: nil),
        ])
        XCTAssertEqual(companies.map(\.key), ["name:ORION MILLS", "name:"])
        XCTAssertNil(companies[0].cin)
        XCTAssertEqual(companies[0].notices.count, 2)
        XCTAssertEqual(companies[1].name, McaRegistry.unnamed)
        XCTAssertEqual(companies[1].noticesLine, "2 notices on this page")
    }

    // MARK: - Decoded fields

    func testTheDecodedFieldsAreTheWebsSixInItsOrder() throws {
        let fields = try XCTUnwrap(Cin.parse("U16001AP2005PLC048552").fields)
        let rows = McaFieldRow.rows(for: fields)
        XCTAssertEqual(rows.map(\.label), [
            "Listing status", "Company class", "Registrar (ROC)", "Year of incorporation",
            "Industry (NIC division)", "Registration number",
        ])
        XCTAssertEqual(rows[4].hint, "Division 16 of \(Cin.nicSchemeLabel). The full code 16001 identifies a narrower sub-class that is not decoded here.")
        XCTAssertEqual(rows[5].value, fields.registration.label)
    }

    func testACityRegistrarSaysSo() throws {
        let fields = try XCTUnwrap(Cin.parse("U72200PN2010PTC135432").fields)
        XCTAssertTrue(fields.rocIsCityRegistrar)
        XCTAssertEqual(McaFieldRow.rows(for: fields)[2].hint,
                       "City registrar within \(fields.rocState ?? "") — the code is the ROC office, not the state.")
    }

    // MARK: - Requests

    func testBrowsingAsksForTheNewestAndSearchingSortsByName() {
        XCTAssertEqual(
            McaRegistry.browseFilter(search: "  ").queryItems(todayInIndia: "2026-10-19"),
            ["sort": "issued_desc"])
        XCTAssertEqual(
            McaRegistry.browseFilter(search: " helios ").queryItems(todayInIndia: "2026-10-19"),
            ["sort": "debtor_asc", "q": "helios"])
        XCTAssertEqual(
            McaRegistry.companyFilter(cin: "u16001ap2005plc048552").queryItems(todayInIndia: "2026-10-19"),
            ["sort": "auction_date_desc", "cin": "u16001ap2005plc048552"])
    }

    func testThePageAsksForTheCapAndSaysWhenItIsReached() async {
        await withRegistry { service, model in
            service.reply = { _ in
                AuctionPage(notices: [Self.notice("1", debtor: "A", cin: "C1"), Self.notice("2", debtor: "B", cin: "C2")], total: 1500)
            }
            await model.search("  argus ")
            XCTAssertEqual(service.requests.map(\.limit), [200])
            XCTAssertEqual(service.requests.first?.filter.query, "argus")
            XCTAssertEqual(service.requests.first?.filter.sort, .debtorName)
            XCTAssertEqual(model.countLine, "2 companies across 2 notices")
            XCTAssertEqual(model.capLine, "1,500 notices match in total; narrow the search to see companies beyond this page.")
            XCTAssertFalse(model.showsEmpty)
        }
    }

    func testAnEmptyPageAndAFailureAreWordedAsTheWebWordsThem() async {
        await withRegistry { service, model in
            await model.search("zzz")
            XCTAssertTrue(model.showsEmpty)
            XCTAssertNil(model.capLine)
            XCTAssertTrue(model.emptyMessage.hasPrefix("No company on record matches \"zzz\"."))
            service.error = APIError.transport("down")
            await model.load()
            XCTAssertEqual(model.loadError, McaRegistryViewModel.loadFailedMessage)
            XCTAssertFalse(model.showsEmpty)
        }
    }

    // MARK: - The decoder's record lookup

    /// The normalised CIN first, then the input as typed when it differs.
    func testALookupTriesTheNormalisedCinThenTheTypedOne() async {
        await withRegistry { service, model in
            service.reply = { filter in
                filter.cin == "u16001Ap2005plc048552"
                    ? AuctionPage(notices: [Self.notice("9", debtor: "HELIOS", cin: "u16001Ap2005plc048552")], total: 3)
                    : AuctionPage()
            }
            model.cinInput = "u16001Ap2005plc048552"
            XCTAssertTrue(model.showsDecode)
            XCTAssertTrue(model.canLookUpRecords)
            await model.lookUpRecords()
            XCTAssertEqual(service.requests.map(\.filter.cin), ["U16001AP2005PLC048552", "u16001Ap2005plc048552"])
            XCTAssertEqual(service.requests.map(\.filter.sort), [.auctionDateDescending, .auctionDateDescending])
            guard case .found(let company, let total) = model.recordLookup else { return XCTFail("\(model.recordLookup)") }
            XCTAssertEqual(company.name, "HELIOS")
            XCTAssertEqual(total, 3)
        }
    }

    func testAMissIsAbsentAndAnUnfinishedCinAsksNothing() async {
        await withRegistry { service, model in
            model.cinInput = "U16001AP2005"
            await model.lookUpRecords()
            XCTAssertEqual(model.recordLookup, .idle)
            XCTAssertTrue(service.requests.isEmpty)

            model.cinInput = "U16001AP2005PLC048552"
            await model.lookUpRecords()
            XCTAssertEqual(model.recordLookup, .absent)

            service.error = APIError.transport("down")
            await model.lookUpRecords()
            XCTAssertEqual(model.recordLookup, .failed)
        }
    }

    // MARK: - A company

    func testACompanyReReadsItsNoticesByItsStoredCin() async {
        await withRegistry { service, _ in
            let company = McaRegistry.groupIntoCompanies([Self.notice("1", debtor: "HELIOS", cin: "u16001ap2005plc048552")])[0]
            service.reply = { _ in
                AuctionPage(notices: (1...3).map { Self.notice("\($0)", debtor: "HELIOS", cin: "u16001ap2005plc048552") }, total: 7)
            }
            let model = McaCompanyViewModel(company: company, service: service)
            XCTAssertEqual(model.countLine, "loading…")
            await model.load()
            XCTAssertEqual(service.requests.last?.filter.cin, "u16001ap2005plc048552")
            XCTAssertEqual(service.requests.last?.filter.sort, .auctionDateDescending)
            XCTAssertEqual(model.notices.count, 3)
            XCTAssertEqual(model.countLine, "7 on record · showing the 3 most recent")
            XCTAssertEqual(model.cinLine, Cin.format("u16001ap2005plc048552"))
        }
    }

    /// A failed re-read keeps the notices the company came with; no CIN means nothing to ask.
    func testACompanyKeepsWhatItHadWhenTheReadFails() async {
        await withRegistry { service, _ in
            service.error = APIError.transport("down")
            let company = McaRegistry.groupIntoCompanies([Self.notice("1", debtor: "A", cin: "C1")])[0]
            let model = McaCompanyViewModel(company: company, service: service)
            await model.load()
            XCTAssertEqual(model.notices.map(\.id), ["1"])
            XCTAssertEqual(model.countLine, "1 on record")

            let nameless = McaRegistry.groupIntoCompanies([Self.notice("2", debtor: "B", cin: nil)])[0]
            let other = McaCompanyViewModel(company: nameless, service: service)
            XCTAssertFalse(other.isLoading)
            let before = service.requests.count
            await other.load()
            XCTAssertEqual(service.requests.count, before)
            XCTAssertEqual(other.cinLine, "No CIN recorded on these notices")
        }
    }
}

/// Answers each notices request with `reply`, and records what it was asked.
private final class FakeNotices: AuctionProviding, @unchecked Sendable {
    var reply: @Sendable (AuctionFilter) -> AuctionPage = { _ in AuctionPage() }
    var error: Error?
    private(set) var requests: [(filter: AuctionFilter, limit: Int, offset: Int)] = []

    func notices(filter: AuctionFilter, limit: Int, offset: Int) async throws -> AuctionPage {
        requests.append((filter, limit, offset))
        if let error { throw error }
        return reply(filter)
    }
    func facets() async throws -> AuctionFacets { .empty }
    func notice(id: String) async throws -> AuctionNoticeDetail { throw APIError.transport("unused") }
    func watchlists() async throws -> [AuctionWatchlist] { [] }
    func watch(cin: String?, keyword: String?) async throws -> String { throw APIError.transport("unused") }
    func unwatch(id: String) async throws { throw APIError.transport("unused") }
}

@MainActor
private func withRegistry(_ body: @MainActor (FakeNotices, McaRegistryViewModel) async -> Void) async {
    let service = FakeNotices()
    await body(service, McaRegistryViewModel(service: service))
}
