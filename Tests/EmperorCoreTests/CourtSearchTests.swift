import XCTest
@testable import EmperorCore

private final class FakeCourtSearch: CourtSearching, @unchecked Sendable {
    var results: [CourtSearchResult] = []
    var searchFailure: Error?
    var saveOutcome: SaveCaseOutcome = .saved(id: "case_1")
    var saveFailure: Error?
    private(set) var searched: [CourtSearchQuery] = []
    private(set) var saved: [CourtSearchResult] = []

    // MARK: Captcha
    var captcha = SupremeCourtCaptcha(sessionID: "scs_1", image: Data([0x89, 0x50]))
    var captchaFailure: Error?
    var captchaOutcome: CaptchaOutcome = .results([])
    private(set) var sessionsStarted = 0
    private(set) var submitted: [(answer: String, session: String)] = []

    func search(_ query: CourtSearchQuery) async throws -> [CourtSearchResult] {
        searched.append(query)
        if let searchFailure { throw searchFailure }
        return results
    }

    func startCaptchaSession() async throws -> SupremeCourtCaptcha {
        sessionsStarted += 1
        if let captchaFailure { throw captchaFailure }
        return captcha
    }

    func submitCaptcha(
        _ answer: String, for query: CourtSearchQuery, session: String
    ) async throws -> CaptchaOutcome {
        submitted.append((answer, session))
        if let captchaFailure { throw captchaFailure }
        return captchaOutcome
    }

    func save(_ result: CourtSearchResult) async throws -> SaveCaseOutcome {
        saved.append(result)
        if let saveFailure { throw saveFailure }
        return saveOutcome
    }
}

@MainActor
private func withSearch(
    _ body: @MainActor (FakeCourtSearch, CourtSearchViewModel) async -> Void
) async {
    let fake = FakeCourtSearch()
    await body(fake, CourtSearchViewModel(service: fake))
}

private func card(
    cnr: String? = nil, courtCode: String? = nil, caseType: String? = nil,
    caseNumber: String? = nil, caseYear: String? = nil, title: String? = "A vs. B"
) -> CourtSearchResult {
    CourtSearchResult(
        courtCode: courtCode, caseType: caseType, caseNumber: caseNumber,
        caseYear: caseYear, cnr: cnr, title: title)
}

final class CourtSearchQueryTests: XCTestCase {

    // MARK: - Completeness

    /// The server does not report a validation failure as one — a missing `year` throws, is
    /// caught, and comes back as "Could not reach the Supreme Court site". So an incomplete
    /// form is indistinguishable from a court outage unless the client checks first.
    func testSupremeCourtNeedsADiaryNumberAndYear() {
        var query = CourtSearchQuery(forum: .supremeCourt, mode: .diaryNumber, number: "12345")
        XCTAssertFalse(query.isComplete)
        XCTAssertEqual(query.missingFields, ["Year"])
        query.year = "2025"
        XCTAssertTrue(query.isComplete)
    }

    func testTribunalsNeedABenchAndFilingNumber() {
        for forum in [CourtForum.nclt, .nclat] {
            var query = CourtSearchQuery(forum: forum, mode: .diaryNumber, number: "CP/123/2024")
            XCTAssertFalse(query.isComplete, "\(forum) should need a bench")
            query.bench = "Mumbai"
            XCTAssertTrue(query.isComplete)
        }
    }

    func testHighCourtNeedsTheWholeCourtIdentity() {
        var query = CourtSearchQuery(forum: .highCourt, mode: .diaryNumber, number: "1234", year: "2025")
        XCTAssertEqual(query.missingFields, ["State", "Court", "Case type"])
        query.stateCode = "1"
        query.courtCode = "2"
        query.caseType = "WP"
        XCTAssertTrue(query.isComplete)
    }

    func testWhitespaceOnlyIsNotAValue() {
        let query = CourtSearchQuery(forum: .supremeCourt, mode: .diaryNumber, number: "  ", year: "\n")
        XCTAssertFalse(query.isComplete)
    }

    // MARK: - Bodies

    /// Non-digits are stripped server-side. Doing it here as well means the request matches
    /// what the field shows, rather than quietly looking up something else.
    func testSupremeCourtDiaryNumberIsReducedToDigits() {
        let query = CourtSearchQuery(forum: .supremeCourt, mode: .diaryNumber, number: "D-12345/25", year: "2025")
        XCTAssertEqual(query.body["diaryNumber"], .string("1234525"))
        XCTAssertEqual(query.body["year"], .string("2025"))
    }

    /// A filing number read off a paperbook is routinely typed with spaces.
    func testTribunalFilingNumberDropsWhitespace() {
        let query = CourtSearchQuery(forum: .nclt, mode: .diaryNumber, number: "CP 123 / 2024", bench: "Mumbai")
        XCTAssertEqual(query.body["filingNo"], .string("CP123/2024"))
        XCTAssertEqual(query.body["bench"], .string("Mumbai"))
    }

    /// The server defaults it to `courtCode`, which is right far more often than a guess.
    func testCourtComplexCodeIsOmittedWhenUnknown() {
        var query = CourtSearchQuery(forum: .highCourt, mode: .diaryNumber, number: "1", year: "2025")
        query.stateCode = "1"; query.courtCode = "2"; query.caseType = "WP"
        XCTAssertNil(query.body["courtComplexCode"])
        query.courtComplexCode = "3"
        XCTAssertEqual(query.body["courtComplexCode"], .string("3"))
    }

    func testEachForumSendsOnlyItsOwnKeys() {
        var query = CourtSearchQuery(forum: .supremeCourt, mode: .diaryNumber, number: "1", year: "2025")
        query.bench = "Mumbai"          // set, but meaningless at the Supreme Court
        XCTAssertNil(query.body["bench"])
        XCTAssertNil(query.body["filingNo"])
        XCTAssertEqual(Set(query.body.keys), ["diaryNumber", "year"])
    }

    /// Without this, `hcRowToCase` stamps every High Court card `"hc"`, so a CNR-less
    /// `WP 1234/2025` from Delhi and one from Madras compute the same `ext_id` and the second
    /// save is refused. It also routes refresh through the general aggregator instead of the
    /// six courts that have their own portal adapter.
    func testHighCourtLookupsIdentifyWhichHighCourt() {
        var query = CourtSearchQuery(forum: .highCourt, mode: .diaryNumber, number: "1234", year: "2025")
        query.stateCode = "26"; query.courtCode = "1"; query.caseType = "WP"
        XCTAssertEqual(query.body["courtId"], .string("hc-delhi"))

        query.stateCode = "10"
        XCTAssertEqual(query.body["courtId"], .string("hc-madras"))
    }

    /// The route does not validate `courtId` — it is persisted verbatim as the case's
    /// `court_code` — so an unrecognised state code must send nothing rather than a guess.
    func testAnUnknownStateCodeSendsNoCourtId() {
        var query = CourtSearchQuery(forum: .highCourt, mode: .diaryNumber, number: "1", year: "2025")
        query.stateCode = "99"; query.courtCode = "1"; query.caseType = "WP"
        XCTAssertNil(query.body["courtId"])
    }

    /// A bijection: two High Courts sharing an id would reintroduce the collision this fixes.
    func testEveryHighCourtIdIsDistinct() {
        let ids = CourtSearchQuery.highCourtIDsByStateCode.values
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(ids.count, 25)
    }

    /// Only the High Court needs it; sending it elsewhere would stamp a tribunal as a court.
    func testOtherForumsSendNoCourtId() {
        XCTAssertNil(CourtSearchQuery(forum: .nclat, mode: .diaryNumber, number: "1", bench: "Delhi").body["courtId"])
        XCTAssertNil(CourtSearchQuery(forum: .supremeCourt, mode: .diaryNumber, number: "1", year: "2025").body["courtId"])
    }

    func testEachForumHasItsOwnDiaryRoute() {
        XCTAssertEqual(CourtForum.supremeCourt.path(for: .diaryNumber), "/court/sc/diary")
        XCTAssertEqual(CourtForum.highCourt.path(for: .diaryNumber), "/court/hc/diary")
        XCTAssertEqual(CourtForum.nclt.path(for: .diaryNumber), "/court/nclt/diary")
        XCTAssertEqual(CourtForum.nclat.path(for: .diaryNumber), "/court/nclat/diary")
    }

    /// The Supreme Court is the odd one out: `auto` rather than `search`, because that route's
    /// job is to attempt the captcha itself and hand it back only if it cannot.
    func testCaseNumberSearchUsesADifferentRoutePerForum() {
        XCTAssertEqual(CourtForum.supremeCourt.path(for: .caseNumber), "/court/sc/auto")
        XCTAssertEqual(CourtForum.highCourt.path(for: .caseNumber), "/court/hc/search")
        XCTAssertEqual(CourtForum.nclt.path(for: .caseNumber), "/court/nclt/search")
        XCTAssertEqual(CourtForum.nclat.path(for: .caseNumber), "/court/nclat/search")
    }

    // MARK: - Case-number mode

    /// The Supreme Court takes no case type for a diary lookup and requires one for a case
    /// number, so the same forum asks for different fields depending on the mode.
    func testTheSupremeCourtNeedsACaseTypeOnlyInCaseNumberMode() {
        var query = CourtSearchQuery(
            forum: .supremeCourt, mode: .caseNumber, number: "1234", year: "2025")
        XCTAssertEqual(query.missingFields, ["Case type"])
        query.caseType = "SLP(C)"
        XCTAssertTrue(query.isComplete)

        query.mode = .diaryNumber
        XCTAssertTrue(query.isComplete, "a diary lookup never needed the case type")
    }

    /// `/search` filters the bench's listing on an exact number **and** year, so a missing year
    /// is not a laxer search — it rejects every row and returns an empty list, which reads to
    /// the user as "no such case".
    func testTribunalsNeedAYearForACaseNumberButNotForAFilingNumber() {
        for forum in [CourtForum.nclt, .nclat] {
            var query = CourtSearchQuery(
                forum: forum, mode: .caseNumber, number: "123", bench: "Mumbai")
            query.caseType = "CP"
            XCTAssertEqual(query.missingFields, ["Year"], "\(forum)")

            query.mode = .diaryNumber
            XCTAssertTrue(query.isComplete, "\(forum) filing lookup takes no year")
        }
    }

    /// The one difference between the two High Court routes. Same five fields, and the number
    /// travels under a different key.
    func testTheHighCourtRenamesTheNumberFieldPerMode() {
        var query = CourtSearchQuery(forum: .highCourt, mode: .caseNumber, number: "1", year: "2025")
        query.stateCode = "1"; query.courtCode = "2"; query.caseType = "WP"

        XCTAssertEqual(query.body["caseNumber"], .string("1"))
        XCTAssertNil(query.body["filingNo"])

        query.mode = .diaryNumber
        XCTAssertEqual(query.body["filingNo"], .string("1"))
        XCTAssertNil(query.body["caseNumber"])
    }

    /// A number, not a string, comes back as a number in `caseYear` — which is `String?` — and
    /// the decode throws on a search that otherwise worked.
    func testTheYearIsAlwaysSentAsAString() {
        for mode in CourtSearchMode.allCases {
            var query = CourtSearchQuery(
                forum: .supremeCourt, mode: mode, number: "1", year: "2025")
            query.caseType = "SLP(C)"
            XCTAssertEqual(query.body["year"], .string("2025"), "\(mode)")
        }
    }

    func testTheSupremeCourtSendsCaseKeysNotDiaryKeys() {
        var query = CourtSearchQuery(
            forum: .supremeCourt, mode: .caseNumber, number: "1234", year: "2025")
        query.caseType = "SLP(C)"
        XCTAssertEqual(Set(query.body.keys), ["caseType", "caseNumber", "year"])
        XCTAssertNil(query.body["diaryNumber"])
    }
}

final class CourtSearchResultTests: XCTestCase {

    /// `ext_id = cnr || courtCode|caseType|caseNumber|caseYear` sits under a UNIQUE index on
    /// `(team_id, ext_id)` (`sync-server.js:9619`, `:3492`). A CNR distinguishes a matter.
    func testACNRDistinguishesACase() {
        XCTAssertTrue(card(cnr: "DLHC010012342024").hasDistinguishingNumber)
    }

    func testACaseNumberDistinguishesACase() {
        XCTAssertTrue(card(caseNumber: "1234").hasDistinguishingNumber)
    }

    /// **The bug this replaced.** `courtCode` is constant per forum and `caseType`/`caseYear`
    /// name a *class* of case, so a card with those and nothing else does not identify anything.
    /// The previous rule accepted any non-empty field, which made this return `true` for every
    /// card the four routes can produce — and turned the warning it guards into dead code.
    func testCourtCodeAndCaseTypeAloneDoNotDistinguishACase() {
        XCTAssertFalse(
            card(courtCode: "trib-nclt", caseType: "CP", caseYear: "2024")
                .hasDistinguishingNumber)
    }

    /// The shape every NCLAT lookup actually returns: `bundleToCard` (`sync-server.js:4115`)
    /// reads `caseType`/`caseNumber`/`caseYear` off a bundle whose `emptyBundle()` has no such
    /// keys, and NCLAT sets `cnr = ''` outright. Every one of these computes
    /// `ext_id = "trib-nclat|||"`, so the second one a team saves collides with the first.
    func testTheShapeEveryNCLATLookupReturnsIsFlagged() {
        let nclat = CourtSearchResult(
            courtType: "trib-nclat", courtCode: "trib-nclat", courtName: "NCLAT",
            caseType: nil, caseNumber: nil, caseYear: nil, cnr: nil,
            diaryNumber: "12345", registrationNo: "12345", title: "ABC Ltd vs. Bakshi")
        XCTAssertFalse(nclat.hasDistinguishingNumber)
    }

    func testBlankFieldsDoNotCountAsIdentity() {
        XCTAssertFalse(card(cnr: "  ", courtCode: "sc", caseNumber: " ").hasDistinguishingNumber)
    }

    /// `"[]"` is the platform's own sentinel for "no parties", written as a two-character
    /// string. Rendering it would title a matter `[]`.
    func testTheEmptyArraySentinelIsNotUsedAsATitle() {
        var result = card(title: "[]")
        result.parties = "[]"
        result.registrationNo = "C.A. 1234/2025"
        XCTAssertEqual(result.displayTitle, "C.A. 1234/2025")
    }

    func testTitleFallsBackToParties() {
        var result = card(title: nil)
        result.parties = "ABC Ltd vs. Rajiv Bakshi"
        XCTAssertEqual(result.displayTitle, "ABC Ltd vs. Rajiv Bakshi")
    }

    func testReferenceIsComposedWhenTheCourtGivesNoRegistrationNumber() {
        let result = card(caseType: "W.P.(C)", caseNumber: "1234", caseYear: "2024")
        XCTAssertEqual(result.reference, "W.P.(C) 1234/2024")
    }

    func testIdentityPrefersTheCNR() {
        XCTAssertEqual(card(cnr: "DLHC01").id, "DLHC01")
    }

    /// Two different cases from one lookup must not collide, or `ForEach` drops one.
    func testTwoDifferentCardsGetDifferentIdentities() {
        let a = card(courtCode: "sc", caseNumber: "1", caseYear: "2025")
        let b = card(courtCode: "sc", caseNumber: "2", caseYear: "2025")
        XCTAssertNotEqual(a.id, b.id)
    }

    // MARK: - Decoding

    /// Every field is optional because four different scrapers feed this. A response missing
    /// most of them must still decode rather than failing the whole lookup.
    func testASparseCardDecodes() throws {
        let json = #"{"success":true,"results":[{"title":"A vs. B"}]}"#
        let response = try JSONDecoder().decode(
            CourtSearchResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.results?.count, 1)
        XCTAssertEqual(response.results?.first?.displayTitle, "A vs. B")
    }

    /// `scrapeRef` is an opaque object on the tribunal routes and a differently-shaped one on
    /// the High Court route. It is carried, never interpreted.
    func testScrapeRefSurvivesAsOpaqueJSON() throws {
        let json = """
            {"success":true,"results":[
              {"title":"A","scrapeRef":{"bench":"Mumbai","filingNo":"CP/1/2024"}}]}
            """
        let response = try JSONDecoder().decode(
            CourtSearchResponse.self, from: Data(json.utf8))
        XCTAssertEqual(
            response.results?.first?.scrapeRef?["bench"]?.stringValue, "Mumbai")
    }

    /// SC cards carry no `scrapeRef` at all.
    func testAMissingScrapeRefIsNotAnError() throws {
        let json = #"{"success":true,"results":[{"title":"A","scrapeRef":null}]}"#
        let response = try JSONDecoder().decode(
            CourtSearchResponse.self, from: Data(json.utf8))
        XCTAssertNotNil(response.results?.first)
    }
}

final class CourtSearchViewModelTests: XCTestCase {

    func testAFoundCaseIsListed() async {
        await withSearch { fake, model in
            fake.results = [card(cnr: "X1", title: "ABC Ltd vs. Bakshi")]
            model.query = CourtSearchQuery(forum: .supremeCourt, mode: .diaryNumber, number: "123", year: "2025")
            await model.runSearch()

            XCTAssertEqual(model.results.count, 1)
            XCTAssertNil(model.errorMessage)
            XCTAssertTrue(model.hasSearched)
        }
    }

    func testAnIncompleteFormIsNotSent() async {
        await withSearch { fake, model in
            model.query = CourtSearchQuery(forum: .supremeCourt, mode: .diaryNumber, number: "123")
            await model.runSearch()

            XCTAssertTrue(fake.searched.isEmpty, "must not spend a court round trip on this")
            XCTAssertFalse(model.hasSearched)
        }
    }

    /// Without this the user is told the court is unreachable and retries a form that can
    /// never work — because that is exactly what the server would say.
    func testAnIncompleteFormSaysWhatIsMissing() async {
        await withSearch { _, model in
            model.query = CourtSearchQuery(forum: .highCourt, mode: .diaryNumber, number: "1")
            XCTAssertEqual(
                model.incompleteNotice,
                "Add state, court, case type and year to search.")
        }
    }

    func testACompleteFormHasNoNotice() async {
        await withSearch { _, model in
            model.query = CourtSearchQuery(forum: .nclt, mode: .diaryNumber, number: "CP/1/2024", bench: "Mumbai")
            XCTAssertNil(model.incompleteNotice)
            XCTAssertTrue(model.canSearch)
        }
    }

    /// `success: true` with an empty array means the court had nothing. Normal, not an error.
    func testNoResultsIsNotAnError() async {
        await withSearch { fake, model in
            fake.results = []
            model.query = CourtSearchQuery(forum: .supremeCourt, mode: .diaryNumber, number: "1", year: "2025")
            await model.runSearch()

            XCTAssertTrue(model.results.isEmpty)
            XCTAssertNil(model.errorMessage)
            XCTAssertTrue(model.hasSearched)
        }
    }

    /// A High Court lookup reaching zero rows may mean the captcha was solved and the site
    /// still said nothing, which is not the same as the case not existing. Asserting otherwise
    /// would send someone away believing their own matter is not on the register.
    func testTheHighCourtEmptyMessageAdmitsTheSiteMayBeAtFault() async {
        await withSearch { _, model in
            model.query = CourtSearchQuery(forum: .highCourt, mode: .diaryNumber)
            XCTAssertTrue(model.emptyMessage.contains("worth trying again"))

            model.query = CourtSearchQuery(forum: .supremeCourt, mode: .diaryNumber)
            XCTAssertFalse(model.emptyMessage.contains("worth trying again"))
        }
    }

    func testHighCourtIsFlaggedAsTheSlowOne() async {
        await withSearch { _, model in
            model.query = CourtSearchQuery(forum: .highCourt, mode: .diaryNumber)
            XCTAssertTrue(model.expectsLongWait)
            model.query = CourtSearchQuery(forum: .nclt, mode: .diaryNumber)
            XCTAssertFalse(model.expectsLongWait)
        }
    }

    /// Results describe the query that produced them. Leaving them up while the form says a
    /// different court is how someone saves the wrong case.
    func testChangingForumClearsTheOldResults() async {
        await withSearch { fake, model in
            fake.results = [card(cnr: "X1")]
            model.query = CourtSearchQuery(forum: .supremeCourt, mode: .diaryNumber, number: "1", year: "2025")
            await model.runSearch()
            XCTAssertFalse(model.results.isEmpty)

            model.query = CourtSearchQuery(forum: .nclt, mode: .diaryNumber)
            XCTAssertTrue(model.results.isEmpty)
        }
    }

    /// **Correcting a digit is the realistic case, not switching courts.** Search diary 52650,
    /// read the card, notice you wanted 52651, edit the field — and the previous case is still
    /// listed underneath with a live "Add to my cases". An earlier version cleared only on a
    /// forum change and left exactly that hole.
    func testEditingTheNumberClearsTheOldResults() async {
        await withSearch { fake, model in
            fake.results = [card(cnr: "X1", title: "Sharma v. State")]
            model.query = CourtSearchQuery(forum: .supremeCourt, mode: .diaryNumber, number: "52650", year: "2023")
            await model.runSearch()
            XCTAssertFalse(model.results.isEmpty)

            model.query.number = "52651"

            XCTAssertTrue(model.results.isEmpty, "the listed case is no longer the one asked for")
            XCTAssertFalse(model.hasSearched, "and the empty state must not claim a miss")
        }
    }

    /// Every field is a live binding, so each one has to clear.
    func testEditingAnyFieldClearsTheOldResults() async {
        await withSearch { fake, model in
            for mutate in [
                { (q: inout CourtSearchQuery) in q.year = "2024" },
                { (q: inout CourtSearchQuery) in q.bench = "Mumbai" },
                { (q: inout CourtSearchQuery) in q.stateCode = "1" },
                { (q: inout CourtSearchQuery) in q.caseType = "WP" },
            ] {
                fake.results = [card(cnr: "X1")]
                model.query = CourtSearchQuery(forum: .supremeCourt, mode: .diaryNumber, number: "1", year: "2025")
                await model.runSearch()
                XCTAssertFalse(model.results.isEmpty)

                mutate(&model.query)
                XCTAssertTrue(model.results.isEmpty)
            }
        }
    }

    func testASearchFailureIsReportedAndClearsStaleResults() async {
        await withSearch { fake, model in
            fake.results = [card(cnr: "X1")]
            model.query = CourtSearchQuery(forum: .supremeCourt, mode: .diaryNumber, number: "1", year: "2025")
            await model.runSearch()

            fake.searchFailure = APIError.server(status: 200, message: "Could not reach the site")
            await model.runSearch()

            XCTAssertTrue(model.results.isEmpty)
            XCTAssertEqual(model.errorMessage, "Could not reach the site")
        }
    }

    // MARK: - Saving

    func testSavingPinsTheCase() async {
        await withSearch { fake, model in
            let found = card(cnr: "X1", title: "ABC Ltd vs. Bakshi")
            fake.saveOutcome = .saved(id: "case_9")
            await model.runSave(found)

            XCTAssertEqual(fake.saved.count, 1)
            XCTAssertTrue(model.isSaved(found))
            XCTAssertEqual(model.notice, "ABC Ltd vs. Bakshi is now on your dashboard.")
            XCTAssertNil(model.errorMessage)
        }
    }

    /// A 409 means the matter is already where they wanted it. Colouring that as a failure
    /// tells someone their case is missing when it is not.
    func testAnAlreadyPinnedCaseReadsAsSuccess() async {
        await withSearch { fake, model in
            let found = card(cnr: "X1")
            fake.saveOutcome = .alreadySaved(message: "This case is already on the team dashboard")
            await model.runSave(found)

            XCTAssertTrue(model.isSaved(found))
            XCTAssertNil(model.errorMessage)
            XCTAssertEqual(model.notice, "This case is already on the team dashboard")
        }
    }

    func testSavingTheSameCaseTwiceIsRefused() async {
        await withSearch { fake, model in
            let found = card(cnr: "X1")
            await model.runSave(found)
            model.save(found)
            try? await Task.sleep(for: .milliseconds(20))

            XCTAssertEqual(fake.saved.count, 1)
        }
    }

    func testASaveFailureIsReported() async {
        await withSearch { fake, model in
            fake.saveFailure = APIError.server(status: 500, message: "Could not save")
            let found = card(cnr: "X1")
            await model.runSave(found)

            XCTAssertFalse(model.isSaved(found))
            XCTAssertEqual(model.errorMessage, "Could not save")
        }
    }

    /// A numberless card is filed under `courtCode|||`, which is a perfectly good unique key —
    /// so it collides with an unrelated matter rather than duplicating one, and is refused. The
    /// user is told before the button is pressed, because the refusal arrives as the same 409
    /// that means "already saved".
    func testANumberlessCardWarnsBeforeSaving() async {
        await withSearch { _, model in
            model.query = CourtSearchQuery(forum: .nclat, mode: .diaryNumber)
            XCTAssertNotNil(
                model.collisionWarning(for: card(courtCode: "trib-nclat", title: "A vs. B")))
            XCTAssertNil(model.collisionWarning(for: card(cnr: "X1")))
            XCTAssertNil(model.collisionWarning(for: card(caseNumber: "1234")))
        }
    }

    /// **The critical bug.** A 409 on a numberless card means an *unrelated* matter holds that
    /// key — the case was never stored. Reporting it as "already on your dashboard", in green,
    /// with the row ticked, leaves the user believing a matter is on their docket when it is
    /// not. That is the one outcome this screen must never produce.
    func testARefusedNumberlessSaveIsAnErrorNotATick() async {
        await withSearch { fake, model in
            let nclat = card(courtCode: "trib-nclat", title: "ABC Ltd vs. Bakshi")
            fake.saveOutcome = .refusedAsIndistinguishable(
                message: "ABC Ltd vs. Bakshi could not be added.")
            await model.runSave(nclat)

            XCTAssertFalse(model.isSaved(nclat), "it is not on the dashboard")
            XCTAssertNil(model.notice, "and must not be reported as though it were")
            XCTAssertEqual(model.errorMessage, "ABC Ltd vs. Bakshi could not be added.")
        }
    }

    /// The service, not the response, decides which of the two a 409 means — the server sends
    /// the same sentence either way.
    func testTheCollisionMessageDoesNotRepeatTheServersFalseClaim() {
        let nclat = CourtSearchResult(
            courtCode: "trib-nclat", courtName: "NCLAT", title: "ABC Ltd vs. Bakshi")
        let message = CourtSearchService.collisionMessage(for: nclat)

        XCTAssertFalse(message.localizedCaseInsensitiveContains("already on"))
        XCTAssertTrue(message.contains("NCLAT"))
        XCTAssertTrue(message.contains("ABC Ltd vs. Bakshi"))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("could not be added"))
    }

    /// The dashboard behind this screen is stale the moment a case is pinned.
    func testTheDashboardIsToldToRefresh() async {
        final class Counter: @unchecked Sendable { var value = 0 }
        let counter = Counter()
        let fake = FakeCourtSearch()
        let model = await CourtSearchViewModel(service: fake, onSaved: { counter.value += 1 })
        await model.runSave(card(cnr: "X1"))
        XCTAssertEqual(counter.value, 1)
    }

    /// An "already pinned" outcome changed nothing, so there is nothing to refresh.
    func testAnAlreadyPinnedCaseDoesNotRefreshTheDashboard() async {
        final class Counter: @unchecked Sendable { var value = 0 }
        let counter = Counter()
        let fake = FakeCourtSearch()
        fake.saveOutcome = .alreadySaved(message: "already there")
        let model = await CourtSearchViewModel(service: fake, onSaved: { counter.value += 1 })
        await model.runSave(card(cnr: "X1"))
        XCTAssertEqual(counter.value, 0)
    }
}

/// `CourtSearchService` against a stubbed transport.
///
/// The view-model tests above drive a fake service, so nothing there sees the actual wire. These
/// pin the two things the search routes do that the diary routes never did: they distinguish
/// their failures, and one of them can hand back a card the court never produced.
final class CourtSearchWireTests: XCTestCase {

    private static let config = APIConfig(baseURL: URL(string: "https://example.test/api")!)

    override func setUp() {
        super.setUp()
        HTTPStub.reset()
    }

    override func tearDown() {
        HTTPStub.reset()
        super.tearDown()
    }

    private func makeService() async -> CourtSearchService {
        let client = APIClient(config: Self.config, session: HTTPStub.session())
        await client.setCredentials(Credentials(token: "tok-abc", userID: 42))
        return CourtSearchService(client: client)
    }

    private func caseQuery() -> CourtSearchQuery {
        var query = CourtSearchQuery(
            forum: .supremeCourt, mode: .caseNumber, number: "1234", year: "2025")
        query.caseType = "SLP(C)"
        return query
    }

    // MARK: - The fabricated card

    /// `GET /court/search` answers for a court with no adapter by echoing the request back as a
    /// case record. Nothing here calls that route, so a `preview` row means the server started
    /// routing one of these forums through it — and once decoded it is indistinguishable from a
    /// scraped one. Showing a lawyer their own typing as a court record is not a thing to fail
    /// open on.
    func testAFabricatedCardIsDroppedRatherThanShown() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"""
        {"success":true,"results":[
          {"title":"WP 1/2025","caseNumber":"1","preview":true},
          {"title":"Real v Case","caseNumber":"2","cnr":"DLHC01"}
        ]}
        """#))

        let results = try await service.search(caseQuery())

        XCTAssertEqual(results.count, 1, "the preview row must not survive")
        XCTAssertEqual(results.first?.cnr, "DLHC01")
    }

    func testAResponseOfNothingButPreviewRowsComesBackEmpty() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":true,"results":[{"title":"X","preview":true}]}"#))

        let results = try await service.search(caseQuery())

        XCTAssertTrue(results.isEmpty, "an empty list is honest; a fabricated card is not")
    }

    // MARK: - Failures that mean different things

    /// The court answered and had nothing. That is the same outcome as an empty `results` on a
    /// success, and putting a red banner in front of someone who mistyped a digit is wrong.
    func testNotFoundIsAnEmptyResultRatherThanAnError() async throws {
        let service = await makeService()
        HTTPStub.always(.json(
            #"{"success":false,"notFound":true,"error":"No case found."}"#))

        let results = try await service.search(caseQuery())

        XCTAssertTrue(results.isEmpty)
    }

    /// The court's own site is down. Retrying now cannot help, and the wording has to say so
    /// rather than implying the case details were wrong.
    func testACourtOutageIsReportedAsAnError() async {
        let service = await makeService()
        HTTPStub.always(.json(#"""
        {"success":false,"portalDown":true,
         "error":"The High Court portal is not responding."}
        """#))

        do {
            _ = try await service.search(caseQuery())
            XCTFail("an outage must not read as an empty result")
        } catch {
            XCTAssertTrue(
                DisplayText.message(for: error).contains("not responding"),
                "the server's own wording names the court and should survive")
        }
    }

    func testTheServersWordingIsPreferredOverOurs() async {
        let service = await makeService()
        HTTPStub.always(.json(
            #"{"success":false,"error":"NCLAT is not accepting requests right now."}"#))

        do {
            _ = try await service.search(caseQuery())
            XCTFail("expected a failure")
        } catch {
            XCTAssertTrue(DisplayText.message(for: error).contains("NCLAT"))
        }
    }

    /// Both flags are absent on every diary response, so reading them must not turn a plain
    /// failure into a misclassified one.
    func testAFailureWithNoFlagsStillReportsSomethingSayable() async {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":false}"#))

        do {
            _ = try await service.search(caseQuery())
            XCTFail("expected a failure")
        } catch {
            XCTAssertFalse(DisplayText.message(for: error).isEmpty)
        }
    }

    // MARK: - The fields only search returns

    func testTheSearchOnlyFieldsDecode() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"""
        {"success":true,"results":[{
          "title":"A v B","stage":"Part Heard","judge":"Hon'ble Ms Justice R. Iyer",
          "nextHearingDate":"12-08-2026","petitioner":"A","respondent":"B","caseYear":"2025"
        }]}
        """#))

        let results = try await service.search(caseQuery())
        let result = try XCTUnwrap(results.first)

        XCTAssertEqual(result.stage, "Part Heard")
        XCTAssertEqual(result.judge, "Hon'ble Ms Justice R. Iyer")
        XCTAssertEqual(result.nextHearingDate, "12-08-2026")
        XCTAssertEqual(result.petitioner, "A")
        XCTAssertEqual(result.respondent, "B")
    }

    // MARK: - The captcha routes

    /// Only the Supreme Court has a manual route behind `fallback`. The High Court sets the same
    /// flag to mean "this search is not built yet" and has no session/submit pair, so offering a
    /// captcha sheet there would put up something that can never resolve.
    func testOnlyTheSupremeCourtTreatsFallbackAsACaptchaHandover() async {
        let service = await makeService()
        HTTPStub.always(.json(
            #"{"success":false,"fallback":true,"error":"Auto-search is still being set up."}"#))

        do {
            _ = try await service.search(caseQuery())
            XCTFail("expected the captcha handover")
        } catch {
            XCTAssertTrue(error is NeedsHumanCaptcha)
        }

        var highCourt = CourtSearchQuery(
            forum: .highCourt, mode: .caseNumber, number: "1", year: "2025")
        highCourt.stateCode = "26"; highCourt.courtCode = "1"; highCourt.caseType = "WP"
        do {
            _ = try await service.search(highCourt)
            XCTFail("expected a plain failure")
        } catch {
            XCTAssertFalse(
                error is NeedsHumanCaptcha,
                "the High Court has no session/submit pair to hand a person")
            XCTAssertTrue(DisplayText.message(for: error).contains("still being set up"))
        }
    }

    /// The diary routes never send `fallback`, and a diary lookup at the Supreme Court needs no
    /// captcha at all — so the handover must not fire for it.
    func testADiaryLookupNeverHandsBackACaptcha() async {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":false,"fallback":true,"error":"Nope."}"#))

        do {
            _ = try await service.search(
                CourtSearchQuery(
                    forum: .supremeCourt, mode: .diaryNumber, number: "1", year: "2025"))
            XCTFail("expected a plain failure")
        } catch {
            XCTAssertFalse(error is NeedsHumanCaptcha)
        }
    }

    func testAStartedSessionCarriesTheDecodedImage() async throws {
        let service = await makeService()
        let png = Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()
        HTTPStub.always(.json(#"""
        {"success":true,"sessionId":"scs_42","captcha":"data:image/png;base64,\#(png)"}
        """#))

        let captcha = try await service.startCaptchaSession()

        XCTAssertEqual(captcha.sessionID, "scs_42")
        XCTAssertEqual(captcha.image, Data([0x89, 0x50, 0x4E, 0x47]))
        XCTAssertEqual(HTTPStub.lastRequest?.path, "/api/court/sc/session")
    }

    /// **The one route in this whole set that fails with a status code.** Everything else
    /// answers 200 with `success: false`, so a check on `success` alone would read this 502's
    /// empty body as a malformed success.
    func testTheSessionRouteFailsWithAStatusCodeNotASuccessFlag() async {
        let service = await makeService()
        HTTPStub.always(.json(
            #"{"success":false,"error":"Could not reach the Supreme Court website."}"#,
            status: 502))

        do {
            _ = try await service.startCaptchaSession()
            XCTFail("a 502 must not read as a session")
        } catch {
            XCTAssertTrue(DisplayText.message(for: error).contains("Could not reach"))
        }
    }

    func testAnUndecodableImageIsRefusedRatherThanShownEmpty() async {
        let service = await makeService()
        HTTPStub.always(.json(
            #"{"success":true,"sessionId":"scs_1","captcha":"not-a-data-uri"}"#))

        do {
            _ = try await service.startCaptchaSession()
            XCTFail("expected a failure rather than a blank frame")
        } catch {
            XCTAssertFalse(DisplayText.message(for: error).isEmpty)
        }
    }

    func testSubmittingSendsTheSessionAndTheAnswerAlongsideTheQuery() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":true,"results":[{"cnr":"SC1"}]}"#))

        let outcome = try await service.submitCaptcha("42", for: caseQuery(), session: "scs_9")

        XCTAssertEqual(outcome, .results([CourtSearchResult(cnr: "SC1")]))
        let body = try XCTUnwrap(HTTPStub.lastRequest?.bodyJSON)
        XCTAssertEqual(body["sessionId"] as? String, "scs_9")
        XCTAssertEqual(body["captcha"] as? String, "42")
        XCTAssertEqual(body["caseType"] as? String, "SLP(C)")
        XCTAssertEqual(body["year"] as? String, "2025", "a string, not a number")
    }

    /// Both arrive as `success: false` and both mean the session is gone. Neither is an error
    /// the user can act on beyond reading the next image.
    func testAWrongOrExpiredCaptchaAsksForANewOneRatherThanThrowing() async throws {
        let service = await makeService()

        for payload in [
            #"{"success":false,"captchaError":true,"error":"Incorrect CAPTCHA."}"#,
            #"{"success":false,"expired":true,"error":"CAPTCHA expired — load a new one."}"#,
        ] {
            HTTPStub.always(.json(payload))
            let outcome = try await service.submitCaptcha("x", for: caseQuery(), session: "s")
            guard case .needsANewCaptcha = outcome else {
                return XCTFail("expected a new-captcha outcome for \(payload)")
            }
        }
    }

    /// The Supreme Court reports "no such case" as a **success** with an empty list and a
    /// `message` rather than an `error`. Reading that as a failure would put an error banner
    /// over a captcha the user solved correctly.
    func testACorrectCaptchaWithNoMatchIsAnEmptyResultNotAFailure() async throws {
        let service = await makeService()
        HTTPStub.always(.json(
            #"{"success":true,"results":[],"message":"No case found for that number."}"#))

        let outcome = try await service.submitCaptcha("42", for: caseQuery(), session: "s")

        XCTAssertEqual(outcome, .results([]))
    }

    /// The route this client calls sends `caseYear` as whatever the request's `year` was, so a
    /// numeric year would come back numeric and throw. The body always sends a string; this
    /// pins what happens if the server ever sends one anyway.
    func testANumericYearIsADecodeFailureNotASilentlyWrongCard() async {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":true,"results":[{"caseYear":2025}]}"#))

        do {
            _ = try await service.search(caseQuery())
            XCTFail("a numeric caseYear must not decode")
        } catch let error as APIError {
            guard case .decoding = error else {
                return XCTFail("expected a decoding error, got \(error)")
            }
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}

/// The Supreme Court captcha, end to end through the view model.
///
/// The rule these exist to hold still: **a session is spent by one submit, right or wrong.** The
/// server deletes it before it checks the answer, so "wrong answer" and "expired" are the same
/// state and both need a *new* image. A future change that retries against the same session
/// would look correct, pass a naive test, and tell the user their place had been lost.
/// A complete Supreme Court case-number query.
///
/// A free function rather than a method: `XCTestCase` is not `Sendable`, so referring to
/// `self.scQuery()` from inside the `@MainActor` closure below is rejected under Swift 6.
private func scQuery() -> CourtSearchQuery {
    var query = CourtSearchQuery(
        forum: .supremeCourt, mode: .caseNumber, number: "1234", year: "2025")
    query.caseType = "SLP(C)"
    return query
}

final class SupremeCourtCaptchaTests: XCTestCase {

    // MARK: - Decoding the image

    func testAPNGDataURIDecodes() {
        let payload = Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()
        let image = SupremeCourtCaptcha.decodeImage(
            fromDataURI: "data:image/png;base64,\(payload)")
        XCTAssertEqual(image, Data([0x89, 0x50, 0x4E, 0x47]))
    }

    /// The media type is not matched, only the `data:` scheme and the comma — a server that
    /// switched to JPEG would still work, and that is not a decision this client should block.
    func testADifferentMediaTypeStillDecodes() {
        let payload = Data([0xFF, 0xD8]).base64EncodedString()
        XCTAssertEqual(
            SupremeCourtCaptcha.decodeImage(fromDataURI: "data:image/jpeg;base64,\(payload)"),
            Data([0xFF, 0xD8]))
    }

    func testMalformedURIsAreRefusedRatherThanGuessed() {
        for bad in [
            "",
            "not-a-uri",
            "https://example.test/captcha.png",   // a URL, not a data URI
            "data:image/png;base64,",             // no payload
            "data:image/png;base64,!!!not base64!!!",
        ] {
            XCTAssertNil(
                SupremeCourtCaptcha.decodeImage(fromDataURI: bad),
                "\(bad.prefix(30)) should not produce an image")
        }
    }

    // MARK: - The flow

    /// The server's solver giving up is not a failure — it is the handover. Nothing red should
    /// appear, and the empty state must not claim the court had no such case, because at this
    /// point the court has not been asked.
    func testTheSolverGivingUpOpensTheSheetRatherThanReportingAnError() async {
        await withSearch { fake, model in
            fake.searchFailure = NeedsHumanCaptcha()
            model.query = scQuery()

            await model.runSearch()

            XCTAssertTrue(model.isShowingCaptcha)
            XCTAssertNil(model.errorMessage, "a captcha handover is not an error")
            XCTAssertFalse(model.hasSearched, "the court has not answered yet")
            XCTAssertEqual(fake.sessionsStarted, 1)
        }
    }

    func testASolvedCaptchaListsTheCaseAndClosesTheSheet() async {
        await withSearch { fake, model in
            fake.searchFailure = NeedsHumanCaptcha()
            model.query = scQuery()
            await model.runSearch()

            fake.captchaOutcome = .results([card(cnr: "SC1", title: "A vs. B")])
            model.captchaAnswer = "42"
            await model.submitCaptcha()

            XCTAssertEqual(model.results.count, 1)
            XCTAssertTrue(model.hasSearched)
            XCTAssertFalse(model.isShowingCaptcha, "the sheet closes once the court answers")
        }
    }

    /// **The rule.** A wrong answer must fetch a new image, never resubmit — the session it was
    /// answered against no longer exists server-side.
    func testAWrongAnswerFetchesANewCaptchaRatherThanRetrying() async {
        await withSearch { fake, model in
            fake.searchFailure = NeedsHumanCaptcha()
            model.query = scQuery()
            await model.runSearch()
            XCTAssertEqual(fake.sessionsStarted, 1)

            fake.captchaOutcome = .needsANewCaptcha(message: "Incorrect CAPTCHA.")
            model.captchaAnswer = "wrong"
            await model.submitCaptcha()

            XCTAssertEqual(fake.sessionsStarted, 2, "a new session, not a second submit")
            XCTAssertEqual(fake.submitted.count, 1, "the spent session is never reused")
            XCTAssertEqual(model.captchaError, "Incorrect CAPTCHA.")
            XCTAssertTrue(model.isShowingCaptcha, "the sheet stays up with the new image")
        }
    }

    /// An expired session is the same state as a wrong answer and takes the same path — the
    /// server cannot tell them apart either, because it deletes the session before looking.
    func testAnExpiredSessionAlsoFetchesANewCaptcha() async {
        await withSearch { fake, model in
            fake.searchFailure = NeedsHumanCaptcha()
            model.query = scQuery()
            await model.runSearch()

            fake.captchaOutcome = .needsANewCaptcha(message: "CAPTCHA expired — load a new one.")
            model.captchaAnswer = "42"
            await model.submitCaptcha()

            XCTAssertEqual(fake.sessionsStarted, 2)
            XCTAssertTrue(model.isShowingCaptcha)
        }
    }

    /// A stale answer left in the box next to a new image looks like it might still be right.
    func testANewImageClearsTheAnswerBox() async {
        await withSearch { fake, model in
            fake.searchFailure = NeedsHumanCaptcha()
            model.query = scQuery()
            await model.runSearch()

            fake.captchaOutcome = .needsANewCaptcha(message: "Incorrect CAPTCHA.")
            model.captchaAnswer = "wrong"
            await model.submitCaptcha()

            XCTAssertTrue(model.captchaAnswer.isEmpty)
            XCTAssertFalse(model.canSubmitCaptcha, "nothing typed yet against the new image")
        }
    }

    /// With no image there is no sheet, so a message inside it is a message nobody reads. The
    /// web client has exactly this bug.
    func testAFailureToLoadAnImageIsReportedOnTheFormNotInTheSheet() async {
        await withSearch { fake, model in
            fake.searchFailure = NeedsHumanCaptcha()
            fake.captchaFailure = APIError.server(status: 502, message: "Court unreachable.")
            model.query = scQuery()

            await model.runSearch()

            XCTAssertFalse(model.isShowingCaptcha)
            XCTAssertEqual(model.errorMessage, "Court unreachable.")
        }
    }

    func testAnEmptyAnswerIsNotSubmittable() async {
        await withSearch { fake, model in
            fake.searchFailure = NeedsHumanCaptcha()
            model.query = scQuery()
            await model.runSearch()

            model.captchaAnswer = "   "
            XCTAssertFalse(model.canSubmitCaptcha)
            await model.submitCaptcha()
            XCTAssertTrue(fake.submitted.isEmpty)
        }
    }
}

final class DisplayTextListTests: XCTestCase {
    func testListReadsAsASentence() {
        XCTAssertEqual(DisplayText.list([]), "")
        XCTAssertEqual(DisplayText.list(["year"]), "year")
        XCTAssertEqual(DisplayText.list(["state", "court"]), "state and court")
        XCTAssertEqual(
            DisplayText.list(["state", "court", "case type"]), "state, court and case type")
    }
}
