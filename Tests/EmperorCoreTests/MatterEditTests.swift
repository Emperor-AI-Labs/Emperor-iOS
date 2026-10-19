import XCTest
@testable import EmperorCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Edit details saves through `POST /project` with the matter's `id`. The route changes only the
// fields it is sent, so what goes in the body is the whole contract: every filled field, in the
// web's camelCase; a blank left out; a field the user emptied sent as null.

private func aMatter() -> Project {
    var p = Project(id: "prj_1", name: "Bhalla v. Kumari")
    p.client = "Ankit Bhalla"
    p.ourSide = "Caveator"
    p.practiceArea = "property"
    p.forumType = "high_court"
    p.forumName = "Delhi High Court"
    p.caseType = "CS(OS)"
    p.caseNumber = "55"
    p.caseYear = "2018"
    p.status = "active"
    p.priority = "high"
    p.nextHearingDateRaw = "2026-11-03T00:00:00.000Z"
    p.notes = "Partition of the Defence Colony house."
    p.color = "amber"
    p.banner = "gold"
    return p
}

final class MatterEditDraftTests: XCTestCase {

    func testTheFormOpensOnTheMatterAsTheWebReadsIt() {
        let draft = MatterEditDraft(aMatter())
        XCTAssertEqual(draft.ourSide, "other")
        XCTAssertEqual(draft.ourSideText, "Caveator")
        XCTAssertEqual(draft.nextHearingDate, "2026-11-03")
        XCTAssertEqual(draft.description, "Partition of the Defence Colony house.")
        XCTAssertEqual(draft.banner, "gold")
        XCTAssertEqual(draft.color, "amber")
        XCTAssertFalse(draft.notFiled)
    }

    func testAMatterWithNoBannerOpensOnThePresetNearestItsColour() {
        var p = aMatter()
        p.banner = nil
        p.color = "teal"
        XCTAssertEqual(MatterEditDraft(p).banner, "teal")
    }

    func testAnUnchangedSaveSendsEveryFilledFieldInCamelCaseAndNoBlanks() {
        let original = MatterEditDraft(aMatter())
        let fields = original.fields(comparedWith: original)
        XCTAssertEqual(fields["name"], .string("Bhalla v. Kumari"))
        XCTAssertEqual(fields["ourSide"], .string("Caveator"))
        XCTAssertEqual(fields["practiceArea"], .string("property"))
        XCTAssertEqual(fields["forumType"], .string("high_court"))
        XCTAssertEqual(fields["caseNumber"], .string("55"))
        XCTAssertEqual(fields["nextHearingDate"], .string("2026-11-03"))
        XCTAssertEqual(fields["description"], .string("Partition of the Defence Colony house."))
        XCTAssertEqual(fields["color"], .string("amber"))
        XCTAssertNil(fields["oppositeParty"])
        XCTAssertNil(fields["cnr"])
        XCTAssertNil(fields["courtStatus"])
        XCTAssertNil(fields["opposite_party"])
        XCTAssertNil(fields["id"])
    }

    func testAFieldTheUserEmptiedIsSentAsNull() {
        let original = MatterEditDraft(aMatter())
        var edited = original
        edited.client = "   "
        edited.color = nil
        edited.nextHearingDate = ""
        let fields = edited.fields(comparedWith: original)
        XCTAssertEqual(fields["client"], .null)
        XCTAssertEqual(fields["color"], .null)
        XCTAssertEqual(fields["nextHearingDate"], .null)
    }

    func testValuesAreTrimmedAndAKnownSideIsItsKey() {
        let original = MatterEditDraft(aMatter())
        var edited = original
        edited.oppositeParty = "  Vinod Kumari "
        edited.ourSide = "plaintiff"
        let fields = edited.fields(comparedWith: original)
        XCTAssertEqual(fields["oppositeParty"], .string("Vinod Kumari"))
        XCTAssertEqual(fields["ourSide"], .string("plaintiff"))
    }

    func testOtherWithNoWordsSavesAsOther() {
        var draft = MatterEditDraft()
        draft.ourSide = "other"
        XCTAssertEqual(draft.ourSideValue, "other")
    }

    func testNotFiledYetIsSentAndTakingItBackClearsIt() {
        var p = aMatter()
        p.courtStatus = "not_filed"
        let original = MatterEditDraft(p)
        XCTAssertEqual(original.fields(comparedWith: original)["courtStatus"], .string("not_filed"))
        var edited = original
        edited.notFiled = false
        XCTAssertEqual(edited.fields(comparedWith: original)["courtStatus"], .null)
    }

    func testAFoundCaseOverwritesTheCourtFieldsButNotTheUsersName() {
        var draft = MatterEditDraft(aMatter())
        var pick = CourtSearchResult()
        pick.courtType = "nclt"
        pick.courtName = "NCLT New Delhi Bench-III"
        pick.caseNumber = "IB-112"
        pick.caseYear = "2025"
        pick.diaryNumber = "D-998"
        pick.title = "SOMETHING VS. OTHER"
        pick.nextHearingDate = "2026-12-01"
        draft.adopt(pick)
        XCTAssertEqual(draft.forumType, "tribunal")
        XCTAssertEqual(draft.forumName, "NCLT New Delhi Bench-III")
        XCTAssertEqual(draft.cnr, "D-998")
        XCTAssertEqual(draft.caseType, "")
        XCTAssertEqual(draft.name, "Bhalla v. Kumari")
        // The user's own next date wins over the registry's.
        XCTAssertEqual(draft.nextHearingDate, "2026-11-03")
    }
}

// MARK: - The sheet's model

private final class EditFakes: ProjectProviding, CaseProviding, CourtSearching, @unchecked Sendable {
    var updateError: Error?
    var linkError: Error?
    var tracked: [LegalCase] = []
    private(set) var updates: [(id: String, fields: [String: JSONValue])] = []
    private(set) var links: [(projectID: String, caseID: String?)] = []
    private(set) var bannerDeletes: [String] = []

    func projects(includeArchived: Bool) async throws -> [Project] { [] }
    func project(id: String) async throws -> ProjectDetail { throw APIError.server(status: 404, message: "no") }
    func update(projectID: String, fields: [String: JSONValue]) async throws -> Project {
        if let updateError { throw updateError }
        updates.append((projectID, fields))
        var p = aMatter()
        if case .string(let status) = fields["status"] { p.status = status }
        return p
    }
    func linkCase(projectID: String, caseID: String?) async throws -> Project {
        if let linkError { throw linkError }
        links.append((projectID, caseID))
        var p = aMatter()
        p.linkedCaseID = caseID
        return p
    }
    func deleteBanner(projectID: String) async throws { bannerDeletes.append(projectID) }

    func cases() async throws -> [LegalCase] { tracked }
    func caseDetail(id: String) async throws -> CaseDetail { throw APIError.server(status: 404, message: "no") }
    func causeList() async throws -> [CauseListing] { [] }
    func addNote(caseID: String, title: String?, body: String) async throws {}
    func addTask(caseID: String, title: String, dueDate: Date?) async throws {}
    func orderDocument(for item: CaseItem, in legalCase: LegalCase) async throws -> Data { Data() }

    func search(_ query: CourtSearchQuery) async throws -> [CourtSearchResult] { [] }
    func startCaptchaSession() async throws -> SupremeCourtCaptcha { throw APIError.transport("no") }
    func submitCaptcha(_ answer: String, for query: CourtSearchQuery, session: String) async throws -> CaptchaOutcome {
        throw APIError.transport("no")
    }
    func save(_ result: CourtSearchResult) async throws -> SaveCaseOutcome { .saved(id: "case_new") }
}

@MainActor
private func withEdit(
    project: Project = aMatter(), _ body: @MainActor (EditFakes, EditMatterViewModel) async -> Void
) async {
    let fake = EditFakes()
    let tracker = CaseTracker(cases: fake, courts: fake)
    await body(fake, EditMatterViewModel(project: project, service: fake, tracker: tracker))
}

final class EditMatterViewModelTests: XCTestCase {

    func testSavingSendsTheMattersIdAndSaysSo() async {
        await withEdit { fake, model in
            model.draft.stage = "Evidence"
            let saved = await model.save()
            XCTAssertNotNil(saved)
            XCTAssertEqual(fake.updates.first?.id, "prj_1")
            XCTAssertEqual(fake.updates.first?.fields["stage"], .string("Evidence"))
            XCTAssertEqual(model.toast, "Changes saved")
            XCTAssertTrue(fake.links.isEmpty)
        }
    }

    func testABlankNameIsRefusedWithoutARequest() async {
        await withEdit { fake, model in
            model.draft.name = "  "
            let saved = await model.save()
            XCTAssertNil(saved)
            XCTAssertEqual(model.error, "Give the matter a name.")
            XCTAssertTrue(fake.updates.isEmpty)
        }
    }

    func testARefusedSaveShowsTheServersWords() async {
        await withEdit { fake, model in
            fake.updateError = APIError.server(status: 400, message: "caseYear is too long")
            let saved = await model.save()
            XCTAssertNil(saved)
            XCTAssertEqual(model.error, "caseYear is too long")
        }
    }

    func testAFoundCaseIsTrackedAndLinkedAfterTheSave() async {
        await withEdit { fake, model in
            var pick = CourtSearchResult()
            pick.caseNumber = "55"
            pick.caseYear = "2018"
            model.usePick(pick)
            XCTAssertFalse(model.offersNotFiled)
            _ = await model.save()
            XCTAssertEqual(fake.links.first?.caseID, "case_new")
            XCTAssertEqual(model.toast, "Changes saved")
        }
    }

    func testALinkThatFailsKeepsTheSaveAndSaysWhatToDo() async {
        await withEdit { fake, model in
            fake.linkError = APIError.server(status: 403, message: "You are not a member of the team that tracks that case.")
            var pick = CourtSearchResult()
            pick.cnr = "DLHC010012342018"
            model.usePick(pick)
            let saved = await model.save()
            XCTAssertNotNil(saved)
            XCTAssertEqual(
                model.toast,
                "Saved, but the court case was not linked (You are not a member of the team that tracks that case) — link it from the matter's Court section.")
        }
    }

    func testChoosingAPresetOverAPictureRemovesThePicture() async {
        var p = aMatter()
        p.banner = "image"
        await withEdit(project: p) { fake, model in
            XCTAssertTrue(model.hasImageBanner)
            model.pickPreset(.teal)
            _ = await model.save()
            XCTAssertEqual(fake.bannerDeletes, ["prj_1"])
            XCTAssertEqual(fake.updates.first?.fields["banner"], .string("teal"))
        }
    }

    func testAKeyTheVocabularyDoesNotKnowStaysSelectable() async {
        var p = aMatter()
        p.practiceArea = "maritime"
        await withEdit(project: p) { _, model in
            XCTAssertEqual(model.practiceAreaOptions.last?.key, "maritime")
            XCTAssertEqual(model.practiceAreaOptions.first?.label, "Not set")
        }
    }
}

final class MatterEditNoticeTests: XCTestCase {

    func testAnEditThatMovesAMatterOutOfViewSaysWhereItWent() async {
        await noticeCheck()
    }
}

@MainActor
private func noticeCheck() async {
    let model = ProjectListViewModel(service: EditFakes())
    var p = aMatter()
    p.status = "on_hold"
    XCTAssertEqual(model.notice(afterSaving: p), "“Bhalla v. Kumari” is now On hold — switch Status to see it.")
    p.status = "active"
    XCTAssertNil(model.notice(afterSaving: p))
}

final class ProjectUpdateWireTests: XCTestCase {

    private static let config = APIConfig(baseURL: URL(string: "https://example.test/api")!)

    override func setUp() {
        super.setUp()
        HTTPStub.reset()
    }

    override func tearDown() {
        HTTPStub.reset()
        super.tearDown()
    }

    private func makeService() async -> ProjectService {
        let client = APIClient(config: Self.config, session: HTTPStub.session())
        await client.setCredentials(Credentials(token: "tok-abc", userID: 42))
        return ProjectService(client: client)
    }

    func testAnEditIsAPostToProjectCarryingItsIdAndNulls() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":true,"project":{"id":"prj_1","name":"Bhalla"}}"#))
        _ = try await service.update(projectID: "prj_1", fields: ["name": .string("Bhalla"), "client": .null])
        let sent = try XCTUnwrap(HTTPStub.lastRequest)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.path, "/api/project")
        XCTAssertEqual(sent.bodyJSON["id"] as? String, "prj_1")
        XCTAssertEqual(sent.bodyJSON["userId"] as? String, "42")
        XCTAssertEqual(sent.bodyJSON["name"] as? String, "Bhalla")
        XCTAssertTrue(sent.bodyJSON["client"] is NSNull)
    }

    func testABlankNameIsRefusedWithoutARequest() async {
        let service = await makeService()
        do {
            _ = try await service.update(projectID: "prj_1", fields: ["name": .string("  ")])
            XCTFail("expected a refusal")
        } catch {}
        XCTAssertTrue(HTTPStub.seen.isEmpty)
    }

    func testAMatterFromACaseCarriesOnlyTheSeedThatWasGiven() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":true,"existed":false,"project":{"id":"prj_9","name":"X"}}"#))
        _ = try await service.projectFromCase(caseID: "c9", seed: MatterSeed(name: nil, banner: "wine", color: "rose"))
        let sent = try XCTUnwrap(HTTPStub.lastRequest)
        XCTAssertEqual(sent.path, "/api/project-from-case")
        XCTAssertEqual(sent.bodyJSON["caseId"] as? String, "c9")
        XCTAssertEqual(sent.bodyJSON["banner"] as? String, "wine")
        XCTAssertEqual(sent.bodyJSON["color"] as? String, "rose")
        XCTAssertNil(sent.bodyJSON["name"])
    }
}
