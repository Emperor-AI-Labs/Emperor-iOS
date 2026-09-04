import XCTest
@testable import EmperorCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The auction feed's failure modes are all silent ones: a 200 that carries an error, a sort key
// the server ignores, a page ceiling it applies without saying so, a "live" filter cut in the
// wrong timezone, and offset paging over a table that moves underneath it. Each test below is
// named for what a user experiences when the rule it pins is broken.

// MARK: - Builders

private func notice(
    _ id: String,
    debtor: String? = "Bhandari Steel Ltd",
    cin: String? = "U27100MH2009PLC190000",
    type: String? = AuctionNoticeType.issueWire,
    auctionDay: String? = "2026-09-14",
    reserve: Int? = 45_000_000,
    fallback: Bool = false
) -> AuctionNotice {
    AuctionNotice(
        id: id,
        typeOfAN: type,
        corporateDebtor: debtor,
        cin: cin,
        auctionDateRaw: auctionDay,
        reservePrice: reserve,
        isFallbackRaw: fallback ? 1 : 0)
}

private func instant(_ iso: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: iso) ?? Date(timeIntervalSince1970: 0)
}

// MARK: - Fake

private final class FakeAuctions: AuctionProviding, @unchecked Sendable {
    var pages: [AuctionPage] = []
    var facets = AuctionFacets.empty
    var detail: AuctionNoticeDetail?
    var listError: Error?
    var detailError: Error?
    var writeError: Error?
    var watchlists: [AuctionWatchlist] = []

    private(set) var requests: [(filter: AuctionFilter, limit: Int, offset: Int)] = []
    private(set) var watched: [(cin: String?, keyword: String?)] = []
    private(set) var unwatched: [String] = []

    func notices(filter: AuctionFilter, limit: Int, offset: Int) async throws -> AuctionPage {
        requests.append((filter, limit, offset))
        if let listError { throw listError }
        let index = requests.count - 1
        return index < pages.count ? pages[index] : AuctionPage()
    }

    func facets() async throws -> AuctionFacets { facets }

    func notice(id: String) async throws -> AuctionNoticeDetail {
        if let detailError { throw detailError }
        guard let detail else {
            throw APIError.server(status: 404, message: AuctionService.noticeGoneMessage)
        }
        return detail
    }

    func watchlists() async throws -> [AuctionWatchlist] { watchlists }

    func watch(cin: String?, keyword: String?) async throws -> String {
        watched.append((cin, keyword))
        if let writeError { throw writeError }
        let id = "awl_\(watchlists.count + 1)"
        watchlists.append(AuctionWatchlist(id: id, cin: cin, keyword: keyword))
        return id
    }

    func unwatch(id: String) async throws {
        unwatched.append(id)
        if let writeError { throw writeError }
        watchlists.removeAll { $0.id == id }
    }
}

/// Linux XCTest cannot invoke a `@MainActor` test method, and an `XCTestCase` is not `Sendable`
/// so a `@MainActor` closure may not capture `self`. Hopping through a free function is the only
/// shape that works on both platforms — see `CourtSearchTests.withSearch`.
@MainActor
private func withAuctions(
    now: @escaping @Sendable () -> Date = { instant("2026-08-26T09:00:00Z") },
    _ body: @MainActor (FakeAuctions, AuctionListViewModel) async -> Void
) async {
    let fake = FakeAuctions()
    await body(fake, AuctionListViewModel(service: fake, now: now))
}

@MainActor
private func withDetail(
    noticeID: String = "an_1",
    now: @escaping @Sendable () -> Date = { instant("2026-08-26T09:00:00Z") },
    _ body: @MainActor (FakeAuctions, AuctionDetailViewModel) async -> Void
) async {
    let fake = FakeAuctions()
    await body(fake, AuctionDetailViewModel(noticeID: noticeID, service: fake, now: now))
}

// MARK: - Money

final class IndianMoneyTests: XCTestCase {

    /// A reserve price of ₹4,50,00,000 rendered as `450000000` differs from `45000000` by one
    /// character in the middle of nine. Lakh and crore put the magnitude first, where it is read.
    func testAReservePriceIsWrittenInLakhAndCrore() {
        XCTAssertEqual(IndianMoney.rupees(4_500_000), "₹45 lakh")
        XCTAssertEqual(IndianMoney.rupees(45_000_000), "₹4.5 crore")
        XCTAssertEqual(IndianMoney.rupees(450_000_000), "₹45 crore")
    }

    /// The distinction the whole format exists for: a factor of ten must be visible at a glance.
    func testAFactorOfTenIsNeverOneCharacterApart() {
        XCTAssertNotEqual(
            IndianMoney.rupees(125_000_000).prefix(4), IndianMoney.rupees(1_250_000_000).prefix(4))
        XCTAssertEqual(IndianMoney.rupees(125_000_000), "₹12.5 crore")
        XCTAssertEqual(IndianMoney.rupees(1_250_000_000), "₹125 crore")
    }

    func testTwoDecimalsAreKeptAndTrailingZerosAreNot() {
        XCTAssertEqual(IndianMoney.rupees(123_456_789), "₹12.35 crore")
        XCTAssertEqual(IndianMoney.rupees(10_500_000), "₹1.05 crore")
        XCTAssertEqual(IndianMoney.rupees(10_000_000), "₹1 crore")
    }

    /// ₹9,99,99,999 is ten crore to two decimals. Carrying wrongly would print "₹9.100 crore".
    func testRoundingCarriesIntoTheNextUnit() {
        XCTAssertEqual(IndianMoney.rupees(99_999_999), "₹10 crore")
    }

    /// Below a lakh the figure is exact, grouped the Indian way rather than in thousands.
    func testSmallAmountsKeepIndianDigitGrouping() {
        XCTAssertEqual(IndianMoney.rupees(99_999), "₹99,999")
        XCTAssertEqual(IndianMoney.rupees(100_000), "₹1 lakh")
        XCTAssertEqual(IndianMoney.rupees(450), "₹450")
        XCTAssertEqual(IndianMoney.digits(12_345_678), "1,23,45,678")
        XCTAssertEqual(IndianMoney.digits(1_000), "1,000")
    }

    /// A reserve price of zero is a real value in this feed and must not render as blank.
    func testZeroIsAFigureNotAnAbsence() {
        XCTAssertEqual(IndianMoney.rupees(0), "₹0")
    }
}

// MARK: - The notice itself

final class AuctionNoticeTests: XCTestCase {

    private func decode(_ json: String) throws -> AuctionListResponse {
        try JSONDecoder().decode(AuctionListResponse.self, from: Data(json.utf8))
    }

    /// **Trap: `is_fallback = 1` rows are parsed from the listing page alone.** Reserve price,
    /// CIN, platform, liquidator and the unique number are all routinely absent. A model that
    /// requires any of them fails to decode the whole page, so one thin row takes down every
    /// good one beside it.
    func testAFallbackRowWithAlmostEveryFieldNullStillDecodes() throws {
        let response = try decode("""
            {"success":true,"total":1,"notices":[{
              "id":"an_1","unique_number":"fallback:https://ibbi.gov.in/x.pdf",
              "type_of_an":null,"corporate_debtor":"Rajesh Textiles Pvt Ltd","cin":null,
              "insolvency_commencement_date":null,"liquidation_commencement_date":null,
              "process_number":null,"date_issued":null,"auction_date":null,"emd_last_date":null,
              "reserve_price":null,"emd_amount":null,"auction_platform":null,
              "auction_platform_url":null,"nature_of_assets":null,"asset_location":null,
              "liquidator_name":null,"ip_registration_number":null,
              "notice_pdf_url":"https://ibbi.gov.in/x.pdf","digital_pdf_url":null,
              "supersedes_unique_number":null,"is_fallback":1,
              "created_at":"2026-08-20 04:11:02","updated_at":"2026-08-20 04:11:02"}]}
            """)
        let row = try XCTUnwrap(response.notices?.first)

        XCTAssertTrue(row.isFallback)
        XCTAssertNotNil(row.provenanceCaveat, "a thin row must say it is thin")
        XCTAssertEqual(row.displayDebtor, "Rajesh Textiles Pvt Ltd")
        XCTAssertNil(row.reservePriceText)
        XCTAssertNotNil(row.documentURL, "the scanned notice is all such a row has")
    }

    /// **`is_fallback` is the number 0 or 1, not a boolean.** Decoding it as `Bool` throws
    /// `typeMismatch` and empties the entire list.
    func testTheFallbackFlagIsANumberNotABoolean() throws {
        let response = try decode(#"{"success":true,"total":1,"notices":[{"id":"a","is_fallback":0}]}"#)
        XCTAssertEqual(response.notices?.first?.isFallback, false)
    }

    /// `unique_number` on a fallback row is the ingest's own dedup key, `fallback:<pdf url>`.
    /// Rendering it puts a URL where a practitioner expects `Liq.AN/U27100MH…`.
    func testTheFallbackDedupKeyIsNeverShownAsAReferenceNumber() {
        var row = notice("an_1")
        row.uniqueNumber = "fallback:https://ibbi.gov.in/uploads/whatsnew/x.pdf"
        XCTAssertNil(row.displayReference)

        row.uniqueNumber = "Liq.AN/U27100MH2009PLC190000/1/IBBI-IPA-001/0826/3"
        XCTAssertEqual(row.displayReference, "Liq.AN/U27100MH2009PLC190000/1/IBBI-IPA-001/0826/3")
    }

    /// One row, two date encodings — a bare court day and a zoneless SQLite timestamp. A single
    /// `dateDecodingStrategy` reads one of them and silently loses the other.
    func testTheTwoDateEncodingsInOneRowAreBothRead() throws {
        let response = try decode("""
            {"success":true,"total":1,"notices":[{"id":"an_1",
             "auction_date":"2026-09-14","created_at":"2026-08-20 04:11:02"}]}
            """)
        let row = try XCTUnwrap(response.notices?.first)
        XCTAssertNotNil(row.auctionDate, "bare YYYY-MM-DD")
        XCTAssertNotNil(row.createdAt, "zoneless SQLite CURRENT_TIMESTAMP")
        XCTAssertEqual(row.auctionDayKey, "2026-09-14")
    }

    /// The auction day is a day in India. Comparing keys rather than instants is what keeps a
    /// device in London from calling today's auction yesterday's.
    func testAnAuctionHappeningTodayIsNotShownAsClosed() {
        let today = WireDate.dayKey(instant("2026-09-14T02:00:00Z"))
        XCTAssertEqual(notice("an_1", auctionDay: "2026-09-14").status(today: today), .today)
        XCTAssertEqual(notice("an_2", auctionDay: "2026-09-15").status(today: today), .upcoming)
        XCTAssertEqual(notice("an_3", auctionDay: "2026-09-13").status(today: today), .closed)
    }

    /// **Trap: a fallback row often has no auction date at all.** Treating "no date" as "in the
    /// past" greys out a live auction and hides it from the upcoming filter.
    func testANoticeWithNoAuctionDateIsNotAssumedToBeOver() {
        let status = notice("an_1", auctionDay: nil).status(today: "2026-09-14")
        XCTAssertEqual(status, .undated)
        XCTAssertNotEqual(status, .closed)
    }

    /// These columns hold whatever the IBBI page had in an `href`.
    func testOnlyAnHTTPDocumentLinkIsOffered() {
        var row = notice("an_1")
        row.digitalPDFURLRaw = "javascript:void(0)"
        row.noticePDFURLRaw = "/uploads/whatsnew/x.pdf"
        XCTAssertNil(row.documentURL)

        row.noticePDFURLRaw = "https://ibbi.gov.in/uploads/whatsnew/x.pdf"
        XCTAssertEqual(row.documentURL?.absoluteString, "https://ibbi.gov.in/uploads/whatsnew/x.pdf")
    }

    /// Every parsed figure on the screen came out of the digital notice, so that is the document
    /// to open first; the scanned one is offered separately rather than instead.
    func testTheDigitalNoticeIsPreferredOverTheScannedOne() {
        var row = notice("an_1")
        row.digitalPDFURLRaw = "https://ibbi.gov.in/digital.pdf"
        row.noticePDFURLRaw = "https://ibbi.gov.in/scan.pdf"
        XCTAssertEqual(row.documentURL?.absoluteString, "https://ibbi.gov.in/digital.pdf")
        XCTAssertEqual(row.scannedNoticeURL?.absoluteString, "https://ibbi.gov.in/scan.pdf")

        row.digitalPDFURLRaw = nil
        XCTAssertEqual(row.documentURL?.absoluteString, "https://ibbi.gov.in/scan.pdf")
        XCTAssertNil(row.scannedNoticeURL, "the same document must not be offered twice")
    }

    func testTheNoticeTypeIsReadCaseInsensitively() {
        XCTAssertEqual(AuctionNoticeType(wire: "Issue of Auction Notice"), .issue)
        XCTAssertEqual(AuctionNoticeType(wire: "corrigendum"), .corrigendum)
        XCTAssertEqual(AuctionNoticeType(wire: "Addendum"), .addendum)
        XCTAssertTrue(AuctionNoticeType(wire: "Corrigendum").amends)
        XCTAssertFalse(AuctionNoticeType(wire: "Issue of Auction Notice").amends)
        // Unfamiliar values are shown, not dropped.
        XCTAssertEqual(AuctionNoticeType(wire: "Withdrawal").label, "Withdrawal")
    }

    func testAnUnnamedDebtorSaysSoRatherThanRenderingBlank() {
        XCTAssertEqual(notice("an_1", debtor: "   ").displayDebtor, "Corporate debtor not named")
    }
}

// MARK: - The query

final class AuctionFilterTests: XCTestCase {

    /// **Trap: an unrecognised `sort` is not an error.** `SORT_MAP[sort] || SORT_MAP.auction_date_asc`
    /// silently falls back, so a typo yields a list that looks sorted by reserve price and is
    /// sorted by date. The enum is what makes that unreachable — if this set drifts from the
    /// server's whitelist, one of these orderings stops working with no symptom.
    func testOnlySortsTheServerRecognisesCanBeSent() {
        XCTAssertEqual(
            Set(AuctionSort.allCases.map(\.rawValue)),
            [
                "auction_date_asc", "auction_date_desc", "reserve_desc", "reserve_asc",
                "issued_desc", "debtor_asc",
            ])
        XCTAssertEqual(AuctionSort.serverDefault, .auctionDateAscending)
    }

    /// **Trap: `liveOnly=1` cuts the day in UTC.** At 23:30 UTC it is already the 27th in India,
    /// but `date('now')` still says the 26th — so the server would count the 26th's auctions as
    /// live, and at 05:30 IST, mid working morning, they would vanish from under the reader.
    func testLiveOnlyIsNeverSentAndTheCutoffFollowsIndia() {
        let lateInUTC = WireDate.dayKey(instant("2026-08-26T23:30:00Z"))
        XCTAssertEqual(lateInUTC, "2026-08-27", "IST is 5h30m ahead")

        let items = AuctionFilter(upcomingOnly: true).queryItems(todayInIndia: lateInUTC)
        XCTAssertNil(items["liveOnly"], "the server's own live filter must never be used")
        XCTAssertEqual(items["from"], "2026-08-27")
    }

    /// Both bounds are `auction_date >=`, so the later of the two is the one that satisfies both.
    func testAnExplicitStartDateIsNotWidenedByTheUpcomingFilter() {
        let filter = AuctionFilter(fromDay: "2026-12-01", upcomingOnly: true)
        XCTAssertEqual(filter.queryItems(todayInIndia: "2026-08-26")["from"], "2026-12-01")

        let past = AuctionFilter(fromDay: "2020-01-01", upcomingOnly: true)
        XCTAssertEqual(past.queryItems(todayInIndia: "2026-08-26")["from"], "2026-08-26")
    }

    /// An empty parameter is not the same as an absent one: `cin = ''` matches no row, so a
    /// blank field sent as a filter turns a working search into an empty screen.
    func testBlankFiltersAreOmittedRatherThanSentEmpty() {
        let items = AuctionFilter(cin: "  ", query: "", type: nil, platform: "\n")
            .queryItems(todayInIndia: "2026-08-26")
        XCTAssertEqual(Set(items.keys), ["sort"])
        XCTAssertFalse(AuctionFilter(query: "   ").isNarrowed)
    }

    func testEveryFilterReachesItsOwnParameterName() {
        let filter = AuctionFilter(
            cin: "U27100MH2009PLC190000", query: "machinery", type: "Corrigendum",
            platform: "NeSL", fromDay: "2026-01-01", toDay: "2026-12-31",
            minReserve: 100_000, maxReserve: 50_000_000, sort: .reserveHighest)
        let items = filter.queryItems(todayInIndia: "2026-08-26")

        XCTAssertEqual(items["cin"], "U27100MH2009PLC190000")
        XCTAssertEqual(items["q"], "machinery")
        XCTAssertEqual(items["typeOfAn"], "Corrigendum")
        XCTAssertEqual(items["platform"], "NeSL")
        XCTAssertEqual(items["from"], "2026-01-01")
        XCTAssertEqual(items["to"], "2026-12-31")
        XCTAssertEqual(items["minReserve"], "100000")
        XCTAssertEqual(items["maxReserve"], "50000000")
        XCTAssertEqual(items["sort"], "reserve_desc")
    }
}

// MARK: - The wire

final class AuctionServiceWireTests: XCTestCase {

    private static let config = APIConfig(baseURL: URL(string: "https://example.test/api")!)

    /// Before each test, not only after. `tearDown` alone leaves the **first** test in the class
    /// reading whatever the previous suite left in `HTTPStub.seen`. See `HTTPStub.reset`.
    override func setUp() {
        super.setUp()
        HTTPStub.reset()
    }

    override func tearDown() {
        HTTPStub.reset()
        super.tearDown()
    }

    private func makeService(
        now: @escaping @Sendable () -> Date = { instant("2026-08-26T09:00:00Z") }
    ) async -> AuctionService {
        let client = APIClient(config: Self.config, session: HTTPStub.session())
        await client.setCredentials(Credentials(token: "tok-abc", userID: 42))
        return AuctionService(client: client, now: now)
    }

    private static let emptyList = #"{"success":true,"total":0,"notices":[]}"#

    /// **Trap: the list route reports failure as `{"error": "..."}` with no `success` key at
    /// all.** A client that decoded the envelope and read `notices ?? []` would show "no auction
    /// notices" for a database error — the same conflation of "nothing" with "we could not ask"
    /// that `LoadState` exists to prevent.
    func testABodyCarryingOnlyAnErrorIsNotAnEmptyAuctionList() async {
        let service = await makeService()
        HTTPStub.always(.json(#"{"error":"no such table: auction_notices"}"#))

        do {
            _ = try await service.notices(filter: AuctionFilter(), limit: 50, offset: 0)
            XCTFail("a database error must not read as an empty feed")
        } catch let error as APIError {
            XCTAssertEqual(
                error, .server(status: 500, message: "no such table: auction_notices"))
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    /// The watchlist routes use the *other* shape — `{"success":false,...}` — so keying on the
    /// presence of `error` alone would miss it and keying on `success` alone would miss the one
    /// above. Both are covered by treating `success != true` as failure.
    func testAWatchlistRefusalIsRecognisedFromSuccessFalse() async {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":false,"error":"Forbidden"}"#, status: 403))

        do {
            try await service.unwatch(id: "awl_1")
            XCTFail("a refusal must not read as a successful delete")
        } catch let error as APIError {
            // "Forbidden" on its own tells the user nothing. A 403 here means the row is gone or
            // was never theirs, and the two are indistinguishable from the client.
            XCTAssertEqual(error, .server(status: 403, message: AuctionService.watchGoneMessage))
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    /// **Trap: `limit` is clamped to 200 with no signal.** Asking for 500 yields 200 rows and a
    /// `total` that still promises more, so a client trusting its own page size would compute
    /// every later offset 300 rows too far and skip most of the feed.
    func testAPageNeverAsksForMoreThanTheServerWillSilentlyGive() async throws {
        let service = await makeService()
        HTTPStub.always(.json(Self.emptyList))

        _ = try await service.notices(filter: AuctionFilter(), limit: 500, offset: 0)
        XCTAssertEqual(HTTPStub.lastRequest?.queryItems["limit"], "200")

        _ = try await service.notices(filter: AuctionFilter(), limit: 0, offset: -5)
        XCTAssertEqual(HTTPStub.lastRequest?.queryItems["limit"], "1")
        XCTAssertEqual(HTTPStub.lastRequest?.queryItems["offset"], "0")
    }

    /// The whole chain, not just the filter: nothing between the view model and the socket may
    /// reintroduce the server's UTC day boundary.
    func testTheRequestCarriesIndiasDayAndNoLiveOnlyFlag() async throws {
        let service = await makeService(now: { instant("2026-08-26T23:30:00Z") })
        HTTPStub.always(.json(Self.emptyList))

        _ = try await service.notices(
            filter: AuctionFilter(upcomingOnly: true), limit: 50, offset: 0)

        let sent = try XCTUnwrap(HTTPStub.lastRequest)
        XCTAssertNil(sent.queryItems["liveOnly"])
        XCTAssertEqual(sent.queryItems["from"], "2026-08-27")
        XCTAssertEqual(sent.path, "/api/auction-notices")
    }

    func testTheDetailCarriesItsAmendmentsOldestFirst() async throws {
        let service = await makeService()
        HTTPStub.always(.json("""
            {"success":true,
             "notice":{"id":"an_1","unique_number":"Liq.AN/X/1","type_of_an":"Issue of Auction Notice"},
             "amendments":[{"id":"an_2","type_of_an":"Corrigendum","supersedes_unique_number":"Liq.AN/X/1"},
                           {"id":"an_3","type_of_an":"Addendum","supersedes_unique_number":"Liq.AN/X/1"}]}
            """))

        let detail = try await service.notice(id: "an_1")
        XCTAssertEqual(detail.amendments.map(\.id), ["an_2", "an_3"])
        XCTAssertEqual(detail.latestAmendment?.id, "an_3")
        XCTAssertTrue(detail.isSuperseded)
    }

    /// The route's own word is the bare string "Not found", which says nothing about what was
    /// not found or whether it is worth retrying.
    func testAMissingNoticeReadsAsGoneRatherThanAsNotFound() async {
        let service = await makeService()
        HTTPStub.always(.json(#"{"error":"Not found"}"#, status: 404))

        do {
            _ = try await service.notice(id: "an_missing")
            XCTFail("expected a failure")
        } catch let error as APIError {
            XCTAssertEqual(error, .server(status: 404, message: AuctionService.noticeGoneMessage))
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    /// The route matches on `id` **or** `unique_number`, but every unique number contains
    /// slashes and the route's own path pattern is `[^/]+` — so that half is dead. Sending one
    /// anyway would address `/auction-notices/Liq.AN/X/1`, a path that matches no route at all.
    func testAUniqueNumberIsRefusedRatherThanSentAsAPath() async {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":true}"#))

        do {
            _ = try await service.notice(id: "Liq.AN/U27100MH2009PLC190000/1/0826/3")
            XCTFail("expected a refusal")
        } catch {
            XCTAssertTrue(HTTPStub.seen.isEmpty, "must not spend a round trip on a dead lookup")
        }
    }

    /// `userId` is required on this route and its absence is a **500**, not a 400 — which
    /// `RetryPolicy` would classify as transient and send twice more before giving up.
    func testTheWatchlistFetchAlwaysCarriesTheUserIdTheRouteDemands() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":true,"watchlists":[]}"#))

        _ = try await service.watchlists()
        XCTAssertEqual(HTTPStub.lastRequest?.queryItems["userId"], "42")
    }

    /// **The delete reads query parameters, never the body.** A JSON payload is ignored and the
    /// route answers 500 "Missing id or userId" — which reads as a server fault rather than a
    /// client mistake.
    func testTheDeleteSendsIdAndUserIdAsQueryParameters() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":true}"#))

        try await service.unwatch(id: "awl_7")

        let sent = try XCTUnwrap(HTTPStub.lastRequest)
        XCTAssertEqual(sent.httpMethod, "DELETE")
        XCTAssertEqual(sent.queryItems["id"], "awl_7")
        XCTAssertEqual(sent.queryItems["userId"], "42")
        XCTAssertNil(sent.httpBody)
    }

    func testAWatchCarriesTheUserIdInTheBody() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":true,"id":"awl_9"}"#))

        let id = try await service.watch(cin: nil, keyword: "  machinery  ")

        XCTAssertEqual(id, "awl_9")
        let body = try XCTUnwrap(HTTPStub.lastRequest?.bodyJSON)
        XCTAssertEqual(body["userId"] as? String, "42")
        XCTAssertEqual(body["keyword"] as? String, "machinery")
    }

    /// The server's own refusal for this is a 500, which `LoadFailure` presents as "the server
    /// is unhappy" and `RetryPolicy` retries — three round trips to learn the form was empty.
    func testAWatchWithNeitherCINNorKeywordNeverLeavesTheDevice() async {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":true,"id":"awl_9"}"#))

        do {
            _ = try await service.watch(cin: "   ", keyword: nil)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertTrue(HTTPStub.seen.isEmpty)
        }
    }

    func testFacetsWithNoValueAreNotOfferedAsFilters() async throws {
        let service = await makeService()
        HTTPStub.always(.json("""
            {"success":true,"types":[{"v":"Corrigendum","n":812},{"v":null,"n":3}],
             "platforms":[{"v":"NeSL","n":301}]}
            """))

        let facets = try await service.facets()
        XCTAssertEqual(facets.types.map(\.displayValue), ["Corrigendum"])
        XCTAssertEqual(facets.platforms.first?.count, 301)
    }
}

// MARK: - The list screen

final class AuctionListViewModelTests: XCTestCase {

    func testTheFirstPageLoads() async {
        await withAuctions { fake, model in
            fake.pages = [AuctionPage(notices: [notice("an_1"), notice("an_2")], total: 2)]
            await model.load()

            XCTAssertEqual(model.notices.map(\.id), ["an_1", "an_2"])
            XCTAssertEqual(model.total, 2)
            XCTAssertFalse(model.canLoadMore)
            XCTAssertEqual(model.resultSummary, "2 notices")
        }
    }

    /// "The feed has nothing matching" and "we could not ask" are different sentences, and this
    /// is the machinery that keeps them apart.
    func testAFailedLoadIsNotAnEmptyFeed() async {
        await withAuctions { fake, model in
            fake.listError = APIError.transport("The network connection was lost.")
            await model.load()

            XCTAssertTrue(model.presentation.showsFailureState)
            XCTAssertFalse(model.presentation.showsEmptyState)
            XCTAssertEqual(model.presentation.failure?.kind, .offline)
        }
    }

    func testAnEmptyResultIsAnAnswerNotAFailure() async {
        await withAuctions { fake, model in
            fake.pages = [AuctionPage(notices: [], total: 0)]
            await model.load()

            XCTAssertTrue(model.presentation.showsEmptyState)
            XCTAssertFalse(model.presentation.showsFailureState)
        }
    }

    /// **Trap: offset paging over a live table repeats rows.** A notice ingested between two
    /// requests shifts everything after it, and a duplicate id in a `ForEach` is a SwiftUI trap
    /// rather than a cosmetic one.
    func testARowRepeatedAcrossPagesIsNotAppendedTwice() async {
        await withAuctions { fake, model in
            fake.pages = [
                AuctionPage(notices: [notice("an_1"), notice("an_2")], total: 4),
                AuctionPage(notices: [notice("an_2"), notice("an_3")], total: 4),
            ]
            await model.load()
            await model.loadMore()

            XCTAssertEqual(model.notices.map(\.id), ["an_1", "an_2", "an_3"])
        }
    }

    /// The subtle half of the same trap. If the next offset were derived from the rows kept
    /// rather than the rows received, a page that was entirely duplicates would re-request the
    /// same window forever — no error, no new rows, and a spinner that never stops.
    func testAPageOfNothingButDuplicatesStillAdvancesTheOffset() async {
        await withAuctions { fake, model in
            fake.pages = [
                AuctionPage(notices: [notice("an_1"), notice("an_2")], total: 6),
                AuctionPage(notices: [notice("an_1"), notice("an_2")], total: 6),
                AuctionPage(notices: [notice("an_5"), notice("an_6")], total: 6),
            ]
            await model.load()
            await model.loadMore()
            XCTAssertEqual(fake.requests.last?.offset, 2)
            XCTAssertEqual(model.notices.count, 2, "nothing new was kept")

            await model.loadMore()
            XCTAssertEqual(fake.requests.last?.offset, 4, "but the window must still have moved")
            XCTAssertEqual(model.notices.map(\.id), ["an_1", "an_2", "an_5", "an_6"])
        }
    }

    /// A `total` that outlives the rows behind it — the table shrank — must stop the paging
    /// rather than drive an endless run of empty requests.
    func testAnEmptyPageStopsPagingEvenWhenTheTotalPromisesMore() async {
        await withAuctions { fake, model in
            fake.pages = [
                AuctionPage(notices: [notice("an_1")], total: 900),
                AuctionPage(notices: [], total: 900),
            ]
            await model.load()
            await model.loadMore()

            XCTAssertFalse(model.canLoadMore)
            XCTAssertEqual(model.total, 1)
        }
    }

    /// A dropped page is not a reason to blank a list someone is reading.
    func testAFailedPageLeavesTheLoadedRowsOnScreen() async {
        await withAuctions { fake, model in
            fake.pages = [AuctionPage(notices: [notice("an_1")], total: 5)]
            await model.load()
            fake.listError = APIError.transport("The network connection was lost.")
            await model.loadMore()

            XCTAssertEqual(model.notices.map(\.id), ["an_1"])
            XCTAssertTrue(model.state.hasLoaded)
            XCTAssertNotNil(model.actionError)
        }
    }

    /// Rows loaded under one search answer a different question from the one now on the form.
    /// Leaving them up under a new company name is how someone concludes an auction exists.
    func testChangingTheSearchClearsRowsThatAnsweredTheOldOne() async {
        await withAuctions { fake, model in
            fake.pages = [
                AuctionPage(notices: [notice("an_1")], total: 1),
                AuctionPage(notices: [], total: 0),
            ]
            await model.load()
            XCTAssertEqual(model.notices.count, 1)

            model.query = "something else"
            fake.listError = APIError.transport("The network connection was lost.")
            await model.load()

            XCTAssertTrue(model.notices.isEmpty)
            XCTAssertTrue(model.presentation.showsFailureState)
        }
    }

    /// A plain refresh gets the opposite treatment: the failure is a banner over the content,
    /// not a replacement for it.
    func testAFailedRefreshKeepsTheRowsAndSaysTheyMayBeStale() async {
        await withAuctions { fake, model in
            fake.pages = [AuctionPage(notices: [notice("an_1")], total: 1)]
            await model.load()
            fake.listError = APIError.transport("The network connection was lost.")
            await model.load()

            XCTAssertEqual(model.notices.count, 1)
            XCTAssertTrue(model.presentation.showsStaleBanner)
        }
    }

    /// The upcoming filter is on by default, so an empty result is very often an auction that
    /// has already happened. Not saying so leaves the reader believing there was never a notice.
    func testTheEmptyStateNamesTheFilterThatIsHidingResults() async {
        await withAuctions { fake, model in
            fake.pages = [AuctionPage(notices: [], total: 0)]
            model.query = "Bhandari"
            await model.load()

            XCTAssertTrue(model.emptyDetail.contains("Upcoming only"))
            model.upcomingOnly = false
            XCTAssertFalse(model.emptyDetail.contains("Upcoming only"))
        }
    }

    func testTheDefaultRequestAsksForUpcomingAuctionsInDateOrder() async {
        await withAuctions { fake, model in
            await model.load()
            let sent = fake.requests.first?.filter
            XCTAssertEqual(sent?.upcomingOnly, true)
            XCTAssertEqual(sent?.sort, .auctionDateAscending)
            XCTAssertEqual(fake.requests.first?.limit, AuctionService.pageSize)
        }
    }

    // MARK: - Watchlists

    /// The insert has no uniqueness constraint and no dedup, so a second identical POST creates
    /// a second row and the watcher is notified twice for every future notice — with nothing
    /// anywhere to explain why.
    func testWatchingTheSameCompanyTwiceIsRefusedLocally() async {
        await withAuctions { fake, model in
            fake.watchlists = [AuctionWatchlist(id: "awl_1", cin: "U27100MH2009PLC190000")]
            await model.load()
            // Explicit, because `load()` no longer fetches watchlists — the feature is held
            // back, and holding the UI while still calling it on every load would defeat the
            // point. The behaviour is still worth pinning: it is what the screen will do again
            // the day the feature returns.
            await model.reloadWatchlists()

            await model.watch(cin: "u27100mh2009plc190000")

            XCTAssertTrue(fake.watched.isEmpty, "must not create a second row")
            XCTAssertEqual(model.actionNotice, "You are already watching that.")
        }
    }

    func testWatchingAKeywordAddsItToTheList() async {
        await withAuctions { fake, model in
            await model.load()
            await model.watch(keyword: "machinery")

            XCTAssertEqual(fake.watched.count, 1)
            XCTAssertTrue(model.isWatching(keyword: "Machinery"))
            XCTAssertNil(model.actionError)
        }
    }

    /// Without this the confirmation is composed from an empty list and reads "Watching . New
    /// notices will appear in your updates." — a success message for a watch that matches
    /// nothing.
    func testAnEmptyWatchIsRefusedBeforeItIsSent() async {
        await withAuctions { fake, model in
            await model.load()
            await model.watch(cin: "  ", keyword: nil)

            XCTAssertTrue(fake.watched.isEmpty)
            XCTAssertNil(model.actionNotice)
            XCTAssertEqual(model.actionError, "Enter a company CIN or a keyword to watch for.")
        }
    }

    func testUnwatchingRemovesItFromTheList() async {
        await withAuctions { fake, model in
            fake.watchlists = [AuctionWatchlist(id: "awl_1", keyword: "machinery")]
            await model.load()
            await model.unwatch(fake.watchlists[0])

            XCTAssertEqual(fake.unwatched, ["awl_1"])
            XCTAssertTrue(model.watchlists.isEmpty)
        }
    }

    /// After a 403 the client cannot tell whether the row is gone or was never theirs, so the
    /// local copy is re-read rather than edited on a guess.
    func testAFailedUnwatchRereadsTheListInsteadOfGuessing() async {
        await withAuctions { fake, model in
            let watch = AuctionWatchlist(id: "awl_1", keyword: "machinery")
            fake.watchlists = [watch]
            await model.load()
            fake.writeError = APIError.server(
                status: 403, message: AuctionService.watchGoneMessage)
            await model.unwatch(watch)

            XCTAssertEqual(model.actionError, AuctionService.watchGoneMessage)
            XCTAssertEqual(model.watchlists.map(\.id), ["awl_1"], "re-read, not assumed removed")
        }
    }

    /// SwiftUI presents one alert per view. With a separate error alert and confirmation alert,
    /// whichever modifier was attached second never appears — and nothing anywhere says so.
    func testAnErrorAndAConfirmationShareOneAlertSurface() async {
        await withAuctions { fake, model in
            await model.load()
            await model.watch(keyword: "machinery")
            XCTAssertTrue(model.isShowingAnnouncement)
            XCTAssertEqual(model.announcementTitle, "Watchlist")

            model.dismissAnnouncement()
            XCTAssertFalse(model.isShowingAnnouncement)

            fake.writeError = APIError.server(status: 500, message: "That watch could not be saved.")
            await model.watch(keyword: "steel")
            XCTAssertEqual(model.announcementTitle, "Could not do that")
            XCTAssertEqual(model.announcementMessage, "That watch could not be saved.")
        }
    }

    /// The filter menu having no options is a smaller failure than the list reporting one.
    func testAFacetsFailureDoesNotTakeTheListDownWithIt() async {
        await withAuctions { fake, model in
            fake.pages = [AuctionPage(notices: [notice("an_1")], total: 1)]
            fake.facets = .empty
            await model.load()

            XCTAssertTrue(model.state.hasLoaded)
            XCTAssertTrue(model.facets.isEmpty)
        }
    }
}

// MARK: - The detail screen

final class AuctionDetailViewModelTests: XCTestCase {

    /// A corrigendum exists to change a figure — most often the reserve price or the auction
    /// date. Showing the original's numbers without saying one was issued presents superseded
    /// terms as current, which is the most expensive thing this screen could get wrong.
    func testACorrigendumWarnsThatTheFiguresBelowAreSuperseded() async {
        await withDetail { fake, model in
            fake.detail = AuctionNoticeDetail(
                notice: notice("an_1"),
                amendments: [notice("an_2", type: AuctionNoticeType.corrigendumWire)])
            await model.load()

            let warning = model.supersededWarning
            XCTAssertNotNil(warning)
            XCTAssertTrue(warning?.contains("corrigendum") == true)
            XCTAssertTrue(warning?.contains("reserve price") == true)
        }
    }

    func testSeveralAmendmentsAreCountedRatherThanNamedOneByOne() async {
        await withDetail { fake, model in
            fake.detail = AuctionNoticeDetail(
                notice: notice("an_1"),
                amendments: [
                    notice("an_2", type: AuctionNoticeType.corrigendumWire),
                    notice("an_3", type: AuctionNoticeType.addendumWire),
                ])
            await model.load()
            XCTAssertTrue(model.supersededWarning?.contains("2 later notices") == true)
        }
    }

    func testAnUnamendedNoticeCarriesNoWarning() async {
        await withDetail { fake, model in
            fake.detail = AuctionNoticeDetail(notice: notice("an_1"))
            await model.load()
            XCTAssertNil(model.supersededWarning)
        }
    }

    /// The earlier notice can only be addressed by its `unique_number`, and that lookup is
    /// unreachable through this API — so the reference is stated and never offered as a tap that
    /// would dead-end.
    func testANoticeThatAmendsAnEarlierOneSaysSoWithoutOfferingALink() async {
        await withDetail { fake, model in
            var corrigendum = notice("an_2", type: AuctionNoticeType.corrigendumWire)
            corrigendum.supersedesUniqueNumber = "Liq.AN/U27100MH2009PLC190000/1/0826/3"
            fake.detail = AuctionNoticeDetail(notice: corrigendum)
            await model.load()

            XCTAssertEqual(model.amendsReference, "Liq.AN/U27100MH2009PLC190000/1/0826/3")
            XCTAssertTrue(model.amendsExplanation?.contains("corrigendum amends") == true)
        }
    }

    /// **Trap: a fallback row has no CIN at all** — the listing page does not carry one. A watch
    /// keyed on a missing CIN would be stored happily and could never match a notice.
    func testAFallbackRowWithNoCINCannotBeWatchedByCompany() async {
        await withDetail { fake, model in
            fake.detail = AuctionNoticeDetail(
                notice: notice("an_1", cin: nil, auctionDay: nil, reserve: nil, fallback: true))
            await model.load()

            XCTAssertNil(model.watchableCIN)
            await model.watchCompany()
            XCTAssertTrue(fake.watched.isEmpty)
            XCTAssertNotNil(model.notice?.provenanceCaveat)
        }
    }

    func testWatchingTheCompanyFromANoticeUsesItsCIN() async {
        await withDetail { fake, model in
            fake.detail = AuctionNoticeDetail(notice: notice("an_1"))
            await model.load()
            await model.watchCompany()

            XCTAssertEqual(fake.watched.first?.cin, "U27100MH2009PLC190000")
            XCTAssertNil(model.actionError)
        }
    }

    /// A notice pulled from a stale notification link is gone, not blank.
    func testAMissingNoticeIsAFailureNotAnEmptyScreen() async {
        await withDetail { fake, model in
            fake.detailError = APIError.server(
                status: 404, message: AuctionService.noticeGoneMessage)
            await model.load()

            XCTAssertTrue(model.presentation.showsFailureState)
            XCTAssertEqual(model.presentation.failure?.message, AuctionService.noticeGoneMessage)
        }
    }

    func testTheStatusIsMeasuredAgainstIndiasDay() async {
        await withDetail(now: { instant("2026-09-13T23:30:00Z") }) { fake, model in
            // 23:30 UTC on the 13th is 05:00 IST on the 14th — the auction is today in India.
            fake.detail = AuctionNoticeDetail(notice: notice("an_1", auctionDay: "2026-09-14"))
            await model.load()
            XCTAssertEqual(model.status, .today)
            XCTAssertTrue(model.status.isOpen)
        }
    }
}
