import XCTest
@testable import EmperorCore

// New matter follows the web's dialog: validation first, then — for a found case — track it (or
// reuse the copy already tracked) and make the matter from it; otherwise make the matter alone.

private final class NewMatterFakes: ProjectProviding, CaseProviding, CourtSearching, @unchecked Sendable {
    var tracked: [LegalCase] = []
    var saveOutcome: SaveCaseOutcome = .saved(id: "case_new")
    var savedCaseAppears: LegalCase?
    var fromCaseError: Error?
    var existed = false
    private(set) var saved: [CourtSearchResult] = []
    private(set) var created: [MatterDraft] = []
    private(set) var fromCase: [(caseID: String, seed: MatterSeed)] = []

    // Projects
    func projects(includeArchived: Bool) async throws -> [Project] { [] }
    func project(id: String) async throws -> ProjectDetail { throw APIError.server(status: 404, message: "no") }
    func projectFromCase(caseID: String) async throws -> (project: Project, existed: Bool) {
        try await projectFromCase(caseID: caseID, seed: MatterSeed())
    }
    func projectFromCase(caseID: String, seed: MatterSeed) async throws -> (project: Project, existed: Bool) {
        if let fromCaseError { throw fromCaseError }
        fromCase.append((caseID, seed))
        return (Project(id: "prj_\(caseID)", name: seed.name ?? "From the case"), existed)
    }
    func create(_ draft: MatterDraft) async throws -> Project {
        created.append(draft)
        return Project(id: "prj_new", name: draft.name)
    }

    // Cases
    func cases() async throws -> [LegalCase] { tracked }
    func caseDetail(id: String) async throws -> CaseDetail { throw APIError.server(status: 404, message: "no") }
    func causeList() async throws -> [CauseListing] { [] }
    func addNote(caseID: String, title: String?, body: String) async throws {}
    func addTask(caseID: String, title: String, dueDate: Date?) async throws {}
    func orderDocument(for item: CaseItem, in legalCase: LegalCase) async throws -> Data { Data() }

    // Courts
    func search(_ query: CourtSearchQuery) async throws -> [CourtSearchResult] { [] }
    func startCaptchaSession() async throws -> SupremeCourtCaptcha { throw APIError.transport("no") }
    func submitCaptcha(_ answer: String, for query: CourtSearchQuery, session: String) async throws -> CaptchaOutcome {
        throw APIError.transport("no")
    }
    func save(_ result: CourtSearchResult) async throws -> SaveCaseOutcome {
        saved.append(result)
        if let savedCaseAppears { tracked.append(savedCaseAppears) }
        return saveOutcome
    }
}

private func card(
    title: String? = "ANKIT BHALLA VS. VINOD KUMARI", cnr: String? = nil, caseNumber: String? = "55",
    caseYear: String? = "2018", caseType: String? = "CS(OS)", courtName: String? = "Delhi High Court"
) -> CourtSearchResult {
    var result = CourtSearchResult()
    result.title = title
    result.cnr = cnr
    result.caseNumber = caseNumber
    result.caseYear = caseYear
    result.caseType = caseType
    result.courtName = courtName
    return result
}

@MainActor
private func withNewMatter(
    existing: [Project] = [], _ body: @MainActor (NewMatterFakes, NewMatterViewModel) async -> Void
) async {
    let fake = NewMatterFakes()
    await body(fake, NewMatterViewModel(projects: fake, cases: fake, courts: fake, existing: existing))
}

final class NewMatterViewModelTests: XCTestCase {

    func testCreateIsRefusedUntilACaseIsChosenWhileFinding() async {
        await withNewMatter { fake, model in
            model.name = "Bhalla"
            let id = await model.create()
            XCTAssertNil(id)
            XCTAssertEqual(model.error, NewMatterViewModel.Copy.chooseTheCase)
            XCTAssertTrue(fake.created.isEmpty)
        }
    }

    func testAMatterWithoutACaseNeedsAName() async {
        await withNewMatter { fake, model in
            model.choose(.later)
            let id = await model.create()
            XCTAssertNil(id)
            XCTAssertEqual(model.error, "Give the matter a name.")
            XCTAssertTrue(fake.created.isEmpty)
        }
    }

    func testNotFiledYetIsSaidOnTheMatter() async {
        await withNewMatter { fake, model in
            model.name = "  Bhalla — partition  "
            model.color = "teal"
            model.banner = .gold
            model.choose(.notFiled)
            let id = await model.create()
            XCTAssertEqual(id, "prj_new")
            XCTAssertEqual(fake.created.first, MatterDraft(
                name: "Bhalla — partition", color: "teal", banner: "gold", courtStatus: "not_filed"))
            XCTAssertEqual(model.toast, "Matter created")
        }
    }

    func testAddLaterMakesAPlainMatter() async {
        await withNewMatter { fake, model in
            model.name = "Bhalla"
            model.choose(.later)
            _ = await model.create()
            XCTAssertNil(fake.created.first?.courtStatus)
        }
    }

    func testAFoundCaseIsTrackedThenTheMatterIsMadeFromIt() async {
        await withNewMatter { fake, model in
            model.usePick(card())
            model.banner = .wine
            model.color = "rose"
            XCTAssertEqual(model.shownName, "Ankit Bhalla v. Vinod Kumari")
            XCTAssertTrue(model.showsNamedAfterCase)
            XCTAssertTrue(model.canCreate)

            let id = await model.create()
            XCTAssertEqual(id, "prj_case_new")
            XCTAssertEqual(fake.saved.count, 1)
            XCTAssertEqual(fake.fromCase.first?.caseID, "case_new")
            // Left blank, the server names the matter after the cause title.
            XCTAssertEqual(fake.fromCase.first?.seed, MatterSeed(name: nil, banner: "wine", color: "rose"))
            XCTAssertTrue(fake.created.isEmpty)
        }
    }

    func testACaseAlreadyTrackedIsLinkedRatherThanSavedAgain() async {
        await withNewMatter { fake, model in
            var known = LegalCase(id: "case_known")
            known.caseNumber = "55"
            known.caseYear = "2018"
            known.caseType = "CS (OS)"
            known.courtName = "Delhi High Court"
            fake.tracked = [known]
            model.name = "Bhalla"
            model.usePick(card())
            _ = await model.create()
            XCTAssertTrue(fake.saved.isEmpty)
            XCTAssertEqual(fake.fromCase.first?.caseID, "case_known")
            XCTAssertEqual(fake.fromCase.first?.seed.name, "Bhalla")
        }
    }

    func testARefusedSaveUsesTheCaseIfItIsThereNow() async {
        await withNewMatter { fake, model in
            var appears = LegalCase(id: "case_appeared")
            appears.cnr = "DLHC010012342018"
            fake.savedCaseAppears = appears
            fake.saveOutcome = .alreadySaved(message: "That case is already on your dashboard.")
            model.usePick(card(cnr: "DLHC010012342018"))
            let id = await model.create()
            XCTAssertEqual(id, "prj_case_appeared")
        }
    }

    func testARefusedSaveThatCannotBeFoundSaysWhy() async {
        await withNewMatter { fake, model in
            fake.saveOutcome = .refusedAsIndistinguishable(message: "Could not be added.")
            model.usePick(card(caseNumber: nil))
            let id = await model.create()
            XCTAssertNil(id)
            XCTAssertEqual(model.error, "Could not be added.")
            XCTAssertTrue(fake.fromCase.isEmpty)
        }
    }

    func testTrackedButNotMadeSaysItIsSafeToRetry() async {
        await withNewMatter { fake, model in
            fake.fromCaseError = APIError.server(status: 500, message: "Database is locked.")
            model.usePick(card())
            _ = await model.create()
            XCTAssertEqual(
                model.error,
                "The case is now tracked, but the matter could not be created: Database is locked. Try again — the case will not be added twice.")
        }
    }

    func testAMatterTheUserAlreadyHadIsOpenedAndSaidSo() async {
        await withNewMatter { fake, model in
            fake.existed = true
            model.usePick(card())
            _ = await model.create()
            XCTAssertEqual(model.toast, "You already have a matter for this case — opening it.")
        }
    }

    func testAPreviewCardWithNoTitleIsSavedUnderTheMattersName() async {
        await withNewMatter { fake, model in
            model.name = "Bhalla"
            model.usePick(card(title: nil))
            _ = await model.create()
            XCTAssertEqual(fake.saved.first?.title, "Bhalla")
        }
    }

    func testANewMatterWearsTheBannerUsedLeast() async {
        let worn = ["navy", "slate", "indigo", "teal", "forest", "wine", "sand"].enumerated().map { index, banner in
            var p = Project(id: "p\(index)", name: "M")
            p.banner = banner
            return p
        }
        await withNewMatter(existing: worn) { _, model in
            XCTAssertEqual(model.banner, .gold)
        }
        await withNewMatter { _, model in
            XCTAssertEqual(model.banner, .navy)
        }
    }
}

final class NewMatterVocabularyTests: XCTestCase {

    func testTheFolderColoursAreTheWebsEightAndAnythingElseIsNone() {
        XCTAssertEqual(MatterFolderColor.options.map(\.key), ["indigo", "violet", "fuchsia", "rose", "amber", "green", "teal", "sky"])
        XCTAssertEqual(MatterFolderColor.normalized(" Teal "), "teal")
        XCTAssertNil(MatterFolderColor.normalized("#ff0000"))
        XCTAssertEqual(MatterFolderColor.label(nil), "No colour")
        XCTAssertNotNil(MatterFolderColor.ink("sky", dark: true))
    }

    func testTheCourtChoicesAreTheWebs() {
        XCTAssertEqual(NewMatterCourtChoice.allCases.map(\.label), ["Find the case", "Not filed yet", "Add later"])
    }

    func testACardWithNoNumberAndNoCNRMatchesNothing() {
        var kase = LegalCase(id: "c")
        kase.courtName = "NCLAT"
        XCTAssertNil(TrackedCaseLookup.find(card(caseNumber: nil, courtName: "NCLAT"), in: [kase]))
    }

    func testTheDiaryNumberStandsInForTheCNR() {
        var kase = LegalCase(id: "c")
        kase.diaryNumber = "12852/2024"
        var pick = card(caseNumber: nil)
        pick.diaryNumber = "12852/2024"
        XCTAssertEqual(TrackedCaseLookup.find(pick, in: [kase])?.id, "c")
    }
}
