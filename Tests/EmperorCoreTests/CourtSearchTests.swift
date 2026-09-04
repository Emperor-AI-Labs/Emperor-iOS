import XCTest
@testable import EmperorCore

private final class FakeCourtSearch: CourtSearching, @unchecked Sendable {
    var results: [CourtSearchResult] = []
    var searchFailure: Error?
    var saveOutcome: SaveCaseOutcome = .saved(id: "case_1")
    var saveFailure: Error?
    private(set) var searched: [CourtSearchQuery] = []
    private(set) var saved: [CourtSearchResult] = []

    func search(_ query: CourtSearchQuery) async throws -> [CourtSearchResult] {
        searched.append(query)
        if let searchFailure { throw searchFailure }
        return results
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
        var query = CourtSearchQuery(forum: .supremeCourt, number: "12345")
        XCTAssertFalse(query.isComplete)
        XCTAssertEqual(query.missingFields, ["Year"])
        query.year = "2025"
        XCTAssertTrue(query.isComplete)
    }

    func testTribunalsNeedABenchAndFilingNumber() {
        for forum in [CourtForum.nclt, .nclat] {
            var query = CourtSearchQuery(forum: forum, number: "CP/123/2024")
            XCTAssertFalse(query.isComplete, "\(forum) should need a bench")
            query.bench = "Mumbai"
            XCTAssertTrue(query.isComplete)
        }
    }

    func testHighCourtNeedsTheWholeCourtIdentity() {
        var query = CourtSearchQuery(forum: .highCourt, number: "1234", year: "2025")
        XCTAssertEqual(query.missingFields, ["State", "Court", "Case type"])
        query.stateCode = "1"
        query.courtCode = "2"
        query.caseType = "WP"
        XCTAssertTrue(query.isComplete)
    }

    func testWhitespaceOnlyIsNotAValue() {
        let query = CourtSearchQuery(forum: .supremeCourt, number: "  ", year: "\n")
        XCTAssertFalse(query.isComplete)
    }

    // MARK: - Bodies

    /// Non-digits are stripped server-side. Doing it here as well means the request matches
    /// what the field shows, rather than quietly looking up something else.
    func testSupremeCourtDiaryNumberIsReducedToDigits() {
        let query = CourtSearchQuery(forum: .supremeCourt, number: "D-12345/25", year: "2025")
        XCTAssertEqual(query.body["diaryNumber"], .string("1234525"))
        XCTAssertEqual(query.body["year"], .string("2025"))
    }

    /// A filing number read off a paperbook is routinely typed with spaces.
    func testTribunalFilingNumberDropsWhitespace() {
        let query = CourtSearchQuery(forum: .nclt, number: "CP 123 / 2024", bench: "Mumbai")
        XCTAssertEqual(query.body["filingNo"], .string("CP123/2024"))
        XCTAssertEqual(query.body["bench"], .string("Mumbai"))
    }

    /// The server defaults it to `courtCode`, which is right far more often than a guess.
    func testCourtComplexCodeIsOmittedWhenUnknown() {
        var query = CourtSearchQuery(forum: .highCourt, number: "1", year: "2025")
        query.stateCode = "1"; query.courtCode = "2"; query.caseType = "WP"
        XCTAssertNil(query.body["courtComplexCode"])
        query.courtComplexCode = "3"
        XCTAssertEqual(query.body["courtComplexCode"], .string("3"))
    }

    func testEachForumSendsOnlyItsOwnKeys() {
        var query = CourtSearchQuery(forum: .supremeCourt, number: "1", year: "2025")
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
        var query = CourtSearchQuery(forum: .highCourt, number: "1234", year: "2025")
        query.stateCode = "26"; query.courtCode = "1"; query.caseType = "WP"
        XCTAssertEqual(query.body["courtId"], .string("hc-delhi"))

        query.stateCode = "10"
        XCTAssertEqual(query.body["courtId"], .string("hc-madras"))
    }

    /// The route does not validate `courtId` — it is persisted verbatim as the case's
    /// `court_code` — so an unrecognised state code must send nothing rather than a guess.
    func testAnUnknownStateCodeSendsNoCourtId() {
        var query = CourtSearchQuery(forum: .highCourt, number: "1", year: "2025")
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
        XCTAssertNil(CourtSearchQuery(forum: .nclat, number: "1", bench: "Delhi").body["courtId"])
        XCTAssertNil(CourtSearchQuery(forum: .supremeCourt, number: "1", year: "2025").body["courtId"])
    }

    func testEachForumHasItsOwnRoute() {
        XCTAssertEqual(CourtForum.supremeCourt.path, "/court/sc/diary")
        XCTAssertEqual(CourtForum.highCourt.path, "/court/hc/diary")
        XCTAssertEqual(CourtForum.nclt.path, "/court/nclt/diary")
        XCTAssertEqual(CourtForum.nclat.path, "/court/nclat/diary")
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
            model.query = CourtSearchQuery(forum: .supremeCourt, number: "123", year: "2025")
            await model.runSearch()

            XCTAssertEqual(model.results.count, 1)
            XCTAssertNil(model.errorMessage)
            XCTAssertTrue(model.hasSearched)
        }
    }

    func testAnIncompleteFormIsNotSent() async {
        await withSearch { fake, model in
            model.query = CourtSearchQuery(forum: .supremeCourt, number: "123")
            await model.runSearch()

            XCTAssertTrue(fake.searched.isEmpty, "must not spend a court round trip on this")
            XCTAssertFalse(model.hasSearched)
        }
    }

    /// Without this the user is told the court is unreachable and retries a form that can
    /// never work — because that is exactly what the server would say.
    func testAnIncompleteFormSaysWhatIsMissing() async {
        await withSearch { _, model in
            model.query = CourtSearchQuery(forum: .highCourt, number: "1")
            XCTAssertEqual(
                model.incompleteNotice,
                "Add state, court, case type and year to search.")
        }
    }

    func testACompleteFormHasNoNotice() async {
        await withSearch { _, model in
            model.query = CourtSearchQuery(forum: .nclt, number: "CP/1/2024", bench: "Mumbai")
            XCTAssertNil(model.incompleteNotice)
            XCTAssertTrue(model.canSearch)
        }
    }

    /// `success: true` with an empty array means the court had nothing. Normal, not an error.
    func testNoResultsIsNotAnError() async {
        await withSearch { fake, model in
            fake.results = []
            model.query = CourtSearchQuery(forum: .supremeCourt, number: "1", year: "2025")
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
            model.query = CourtSearchQuery(forum: .highCourt)
            XCTAssertTrue(model.emptyMessage.contains("worth trying again"))

            model.query = CourtSearchQuery(forum: .supremeCourt)
            XCTAssertFalse(model.emptyMessage.contains("worth trying again"))
        }
    }

    func testHighCourtIsFlaggedAsTheSlowOne() async {
        await withSearch { _, model in
            model.query = CourtSearchQuery(forum: .highCourt)
            XCTAssertTrue(model.expectsLongWait)
            model.query = CourtSearchQuery(forum: .nclt)
            XCTAssertFalse(model.expectsLongWait)
        }
    }

    /// Results describe the query that produced them. Leaving them up while the form says a
    /// different court is how someone saves the wrong case.
    func testChangingForumClearsTheOldResults() async {
        await withSearch { fake, model in
            fake.results = [card(cnr: "X1")]
            model.query = CourtSearchQuery(forum: .supremeCourt, number: "1", year: "2025")
            await model.runSearch()
            XCTAssertFalse(model.results.isEmpty)

            model.query = CourtSearchQuery(forum: .nclt)
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
            model.query = CourtSearchQuery(forum: .supremeCourt, number: "52650", year: "2023")
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
                model.query = CourtSearchQuery(forum: .supremeCourt, number: "1", year: "2025")
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
            model.query = CourtSearchQuery(forum: .supremeCourt, number: "1", year: "2025")
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
            model.query = CourtSearchQuery(forum: .nclat)
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

final class DisplayTextListTests: XCTestCase {
    func testListReadsAsASentence() {
        XCTAssertEqual(DisplayText.list([]), "")
        XCTAssertEqual(DisplayText.list(["year"]), "year")
        XCTAssertEqual(DisplayText.list(["state", "court"]), "state and court")
        XCTAssertEqual(
            DisplayText.list(["state", "court", "case type"]), "state, court and case type")
    }
}
