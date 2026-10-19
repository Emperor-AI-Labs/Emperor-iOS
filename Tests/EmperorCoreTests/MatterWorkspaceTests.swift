import XCTest
@testable import EmperorCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The Matters workspace (docs/projects.md): the rest of a matter beyond its timeline — tasks,
// money, people, the linked case, the setup strip, the one sentence about where things stand —
// and the writes that fill it in. Each test is named for what a person sees when the rule it
// pins is broken.

// MARK: - Builders

private func aProject(
    _ id: String = "prj_1", name: String? = "Helios v. Northgrid", client: String? = nil,
    ourSide: String? = nil, oppositeParty: String? = nil, practiceArea: String? = nil,
    linkedCaseID: String? = nil, courtStatus: String? = nil, nextHearing: String? = nil,
    fileCount: Int? = nil
) -> Project {
    var project = Project(id: id, name: name, client: client, nextHearingDateRaw: nextHearing,
                          linkedCaseID: linkedCaseID, fileCount: fileCount)
    project.ourSide = ourSide
    project.oppositeParty = oppositeParty
    project.practiceArea = practiceArea
    project.courtStatus = courtStatus
    return project
}

private func person(_ role: String, _ name: String, phone: String? = nil, email: String? = nil) -> ProjectPerson {
    ProjectPerson(id: "pp_\(name)", role: role, name: name, phone: phone, email: email)
}

private func task(_ id: String, _ title: String, due: String? = nil, status: String = "open") -> ProjectTask {
    ProjectTask(id: id, title: title, dueDateRaw: due, kind: "task", status: status)
}

private func entry(_ id: String, _ kind: String, _ rupees: Double, title: String? = nil, mode: String? = nil, category: String? = nil) -> LedgerEntry {
    LedgerEntry(id: id, kind: kind, title: title, amount: rupees, amountPaise: Int((rupees * 100).rounded()),
                mode: mode, category: category)
}

private let fullPayload = #"""
{"success":true,
 "project":{"id":"prj_1","name":"Helios v. Northgrid","client":"Helios Renewables","practice_area":"arbitration",
            "our_side":"petitioner","opposite_party":"Northgrid Power","court_status":null,"linked_case_id":"c9",
            "status":"active","priority":"normal","next_hearing_date":"2026-10-28"},
 "updates":[{"id":"u1","kind":"event","title":"Invoice 14 raised","event_date":"2026-03-02","source":"ai","source_ref":"Plaint.pdf, p. 4"},
            {"id":"u2","kind":"hearing","title":"Listed for arguments","event_date":"2026-09-10","source":"court"}],
 "courtHistory":[{"id":"ci1","section":"orders","title":"Order dated 10.09.2026","item_date":"2026-09-10"},
                 {"id":"ci2","section":"hearings","title":"Arguments heard","item_date":"2026-09-10"}],
 "linkedCase":{"id":"c9","title":"Helios v. Northgrid","court_name":"Delhi High Court","court_type":"hc",
               "case_type":"ARB.P.","case_number":112,"case_year":2025,"cnr":null,"next_hearing_date":"2026-10-28",
               "stage":"Arguments","status":"Pending","last_synced_at":"2026-10-18 06:30:00"},
 "tasks":[{"id":"t1","title":"File rejoinder","due_date":"2026-10-20","kind":"filing","priority":"high","status":"open"},
          {"id":"t2","title":"Certified copy","due_date":"2026-10-01","kind":"certified_copy","priority":"normal","status":"done","completed_at":"2026-10-02T04:00:00.000Z"}],
 "ledger":[{"id":"l1","kind":"fee","title":"Drafting fee","amount":100000,"amount_paise":10000000,"entry_date":"2026-09-01"},
           {"id":"l2","kind":"payment","amount":40000.5,"amount_paise":4000050,"entry_date":"2026-09-15","mode":"upi","reference":"UPI-7781"},
           {"id":"l3","kind":"expense","amount":1250,"amount_paise":125000,"category":"court_fee"}],
 "people":[{"id":"p1","role":"client","name":"Helios Renewables","phone":"+91 98100 00000"},
           {"id":"p2","role":"opposing_counsel","name":"R. Mehta"}],
 "totals":{"billed":100000,"received":40000.5,"outstanding":59999.5,"expenses":1250}}
"""#

// MARK: - Fake

private final class FakeMatters: ProjectProviding, @unchecked Sendable {
    var list: [Project] = []
    var detail: ProjectDetail?
    var files: [FileNode] = []
    var error: Error?
    var refreshError: Error?
    var attachAnswer: [AttachedFile] = []
    private(set) var savedTasks: [(id: String?, draft: TaskDraft)] = []
    private(set) var savedEntries: [LedgerDraft] = []
    private(set) var savedPeople: [PersonDraft] = []
    private(set) var savedUpdates: [UpdateDraft] = []
    private(set) var patches: [[String: JSONValue]] = []
    private(set) var attached: [(files: [ChatAttachment], subfolder: String?)] = []
    private(set) var created: [MatterDraft] = []
    private(set) var fromCase: [String] = []
    private(set) var loads = 0
    private(set) var fileLoads = 0

    func projects(includeArchived: Bool) async throws -> [Project] { if let error { throw error }; return list }
    func project(id: String) async throws -> ProjectDetail {
        loads += 1
        if let error { throw error }
        guard let detail else { throw APIError.server(status: 404, message: ProjectService.projectGoneMessage) }
        return detail
    }
    func projectFromCase(caseID: String) async throws -> (project: Project, existed: Bool) {
        fromCase.append(caseID)
        if let error { throw error }
        return (aProject("prj_from_\(caseID)"), true)
    }
    func create(_ draft: MatterDraft) async throws -> Project {
        created.append(draft)
        if let error { throw error }
        return aProject("prj_new", name: draft.name)
    }
    func patch(projectID: String, fields: [String: JSONValue]) async throws -> Project {
        patches.append(fields); if let error { throw error }; return aProject()
    }
    func saveTask(projectID: String, id: String?, draft: TaskDraft) async throws -> ProjectTask {
        savedTasks.append((id, draft)); if let error { throw error }
        return task(id ?? "t_new", draft.title, due: draft.dueDate, status: draft.status ?? "open")
    }
    func deleteTask(id: String) async throws { if let error { throw error } }
    func saveLedgerEntry(projectID: String, id: String?, draft: LedgerDraft) async throws -> LedgerEntry {
        savedEntries.append(draft); if let error { throw error }
        return entry("l_new", draft.kind.rawValue, draft.amount)
    }
    func deleteLedgerEntry(id: String) async throws { if let error { throw error } }
    func savePerson(projectID: String, id: String?, draft: PersonDraft) async throws -> ProjectPerson {
        savedPeople.append(draft); if let error { throw error }
        return person(draft.role, draft.name)
    }
    func deletePerson(id: String) async throws { if let error { throw error } }
    func saveUpdate(projectID: String, id: String?, draft: UpdateDraft) async throws -> String {
        savedUpdates.append(draft); if let error { throw error }; return "u_new"
    }
    func deleteUpdate(id: String) async throws { if let error { throw error } }
    func projectFiles(projectID: String) async throws -> [FileNode] { fileLoads += 1; if let error { throw error }; return files }
    func attach(projectID: String, files: [ChatAttachment], subfolder: String?) async throws -> [AttachedFile] {
        attached.append((files, subfolder)); if let error { throw error }; return attachAnswer
    }
    func linkCase(projectID: String, caseID: String?) async throws -> Project { if let error { throw error }; return aProject() }
    func refreshLinkedCase(projectID: String) async throws { if let refreshError { throw refreshError } }
}

@MainActor
private func withWorkspace(
    today: String = "2026-10-19",
    _ body: @MainActor (FakeMatters, ProjectDetailViewModel) async -> Void
) async {
    let fake = FakeMatters()
    await body(fake, ProjectDetailViewModel(projectID: "prj_1", service: fake, todayKey: { today }))
}

private func decodedDetail() throws -> ProjectDetail {
    let response = try JSONDecoder().decode(ProjectDetailResponse.self, from: Data(fullPayload.utf8))
    return ProjectDetail(
        project: response.project!, updates: response.updates ?? [], courtHistory: response.courtHistory ?? [],
        linkedCase: response.linkedCase, tasks: response.tasks ?? [], ledger: response.ledger ?? [],
        people: response.people ?? [], totals: response.totals ?? .zero)
}

// MARK: - The wire

final class MatterWireTests: XCTestCase {

    func testTheWholeWorkspaceDecodesFromOneAnswer() throws {
        let detail = try decodedDetail()
        XCTAssertEqual(detail.project.practiceAreaLabel, "Arbitration")
        XCTAssertEqual(detail.project.ourSideLabel, "Petitioner")
        XCTAssertEqual(detail.project.oppositeParty, "Northgrid Power")
        XCTAssertEqual(detail.tasks.map(\.id), ["t1", "t2"])
        XCTAssertEqual(detail.tasks[0].kindLabel, "Filing")
        XCTAssertTrue(detail.tasks[1].isDone)
        XCTAssertEqual(detail.people[0].contactLine, "+91 98100 00000")
        XCTAssertEqual(detail.people[1].roleLabel, "Opposing counsel")
        XCTAssertEqual(detail.totals.outstanding, 59999.5)
        XCTAssertEqual(detail.updates[0].sourceLabel, "From Plaint.pdf, p. 4")
        XCTAssertEqual(detail.updates[1].sourceLabel, "From the court")
        XCTAssertEqual(detail.updates[0].kindLabel, "Event")
    }

    /// `case_number` is a TEXT column that a JSON writer sent as a number. Refusing it would
    /// drop the whole linked case from the screen with no error.
    func testTheLinkedCaseReadsNumericCaseNumbers() throws {
        let linked = try XCTUnwrap(try decodedDetail().linkedCase)
        XCTAssertEqual(linked.caseNumber, "112")
        XCTAssertEqual(linked.caseYear, "2025")
        XCTAssertEqual(linked.courtName, "Delhi High Court")
        XCTAssertNotNil(linked.lastSyncedAt)
    }

    /// Paise is the stored truth; `amount` is a JavaScript number made from it.
    func testMoneyPrefersTheExactPaise() throws {
        let ledger = try decodedDetail().ledger
        XCTAssertEqual(ledger[1].rupees, 40000.5)
        XCTAssertEqual(ledger[1].detail, "UPI · UPI-7781")
        XCTAssertEqual(ledger[2].displayTitle, "Court fee")
        XCTAssertNil(ledger[2].detail)
        XCTAssertEqual(ledger[0].displayTitle, "Drafting fee")
    }

    func testTheListRouteCountsDecode() throws {
        let response = try JSONDecoder().decode(
            ProjectListResponse.self,
            from: Data(#"{"success":true,"projects":[{"id":"p1","name":"A","open_tasks":3,"next_task_due":"2026-10-21","billed":5000,"received":2000,"file_count":4}]}"#.utf8))
        let project = try XCTUnwrap(response.projects?.first)
        XCTAssertEqual(project.openTasks, 3)
        XCTAssertEqual(project.outstanding, 3000)
        XCTAssertNotNil(project.nextTaskDue)
    }

    func testAnUnknownVocabularyValueStillLabelsItself() {
        XCTAssertEqual(MatterVocabulary.label(for: "hearing_prep", in: MatterVocabulary.taskKinds), "Hearing prep")
        XCTAssertEqual(MatterVocabulary.label(for: "site_visit", in: MatterVocabulary.taskKinds), "Site Visit")
        XCTAssertNil(MatterVocabulary.label(for: "  ", in: MatterVocabulary.taskKinds))
    }
}

final class MatterMoneyTests: XCTestCase {

    func testIndianGroupingAndPaise() {
        XCTAssertEqual(MatterMoney.inr(0), "₹0")
        XCTAssertEqual(MatterMoney.inr(999), "₹999")
        XCTAssertEqual(MatterMoney.inr(1000), "₹1,000")
        XCTAssertEqual(MatterMoney.inr(125000), "₹1,25,000")
        XCTAssertEqual(MatterMoney.inr(12345678), "₹1,23,45,678")
        XCTAssertEqual(MatterMoney.inr(125000.5), "₹1,25,000.50")
        XCTAssertEqual(MatterMoney.inr(40000.5), "₹40,000.50")
        XCTAssertEqual(MatterMoney.inr(-250), "-₹250")
        // A float that is a whole rupee in disguise prints as one.
        XCTAssertEqual(MatterMoney.inr(99.999), "₹100")
    }
}

// MARK: - Setup and standing

final class MatterSetupTests: XCTestCase {

    func testNothingSetUpIsZeroWithEveryStepMissing() {
        let setup = MatterSetup(project: aProject(), people: [], fileCount: 0)
        XCTAssertEqual(setup.percent, 0)
        XCTAssertEqual(setup.missing.map(\.key), [.court, .side, .parties, .practice, .documents, .contact])
        XCTAssertFalse(setup.isComplete)
    }

    func testEveryStepDoneIsComplete() {
        let project = aProject(client: "Helios", ourSide: "petitioner", oppositeParty: "Northgrid",
                               practiceArea: "arbitration", linkedCaseID: "c9")
        let setup = MatterSetup(project: project, people: [person("client", "Helios", email: "a@b.c")], fileCount: 2)
        XCTAssertTrue(setup.isComplete)
        XCTAssertEqual(setup.percent, 100)
        XCTAssertEqual(setup.summary, "Set up")
    }

    /// "Not filed yet" is the user's own answer to the court step, and counts as done.
    func testNotFiledYetCountsAsTheCourtStep() {
        let setup = MatterSetup(project: aProject(courtStatus: "not_filed"), people: [], fileCount: 0)
        XCTAssertEqual(setup.steps.first { $0.key == .court }?.done, true)
    }

    /// The document count is unknown until the files have been listed. A step that cannot be
    /// known is neither done nor missing — but still part of the total, so the figure never
    /// drops when the listing arrives.
    func testUnknownDocumentsIsNeitherDoneNorMissing() {
        let setup = MatterSetup(project: aProject(ourSide: "respondent"), people: [], fileCount: nil)
        XCTAssertNil(setup.steps.first { $0.key == .documents }?.done)
        XCTAssertFalse(setup.missing.contains { $0.key == .documents })
        XCTAssertEqual(setup.percent, 17)
        XCTAssertFalse(setup.isComplete)
    }

    /// A client with no phone and no email is not a contact.
    func testAClientWithoutAWayToReachThemIsNotAContact() {
        let unreachable = MatterSetup(project: aProject(), people: [person("client", "Helios")], fileCount: 0)
        XCTAssertEqual(unreachable.steps.first { $0.key == .contact }?.done, false)
        let witness = MatterSetup(project: aProject(), people: [person("witness", "X", phone: "1")], fileCount: 0)
        XCTAssertEqual(witness.steps.first { $0.key == .contact }?.done, false)
    }

    func testTheSummaryNamesWhatIsLeft() {
        let project = aProject(client: "Helios", ourSide: "petitioner", oppositeParty: "Northgrid",
                               practiceArea: "arbitration", linkedCaseID: "c9")
        let setup = MatterSetup(project: project, people: [], fileCount: 0)
        XCTAssertEqual(setup.summary, "67% set up · Documents and Client contact still to do")
    }
}

final class MatterStandingTests: XCTestCase {

    private func standing(
        project: Project = aProject(), linked: LinkedCaseSummary? = nil,
        next: String? = nil, last: String? = nil, today: String = "2026-10-19"
    ) -> MatterStanding {
        MatterStanding(project: project, linkedCase: linked, nextHearingKey: next, lastHearingKey: last, todayKey: today)
    }

    func testADateAheadSaysHowFar() {
        XCTAssertEqual(standing(next: "2026-10-19").headline, "The case is in court today.")
        XCTAssertEqual(standing(next: "2026-10-20").headline, "The case is in court tomorrow.")
        let later = standing(linked: LinkedCaseSummary(courtName: "Delhi High Court"), next: "2026-10-28")
        XCTAssertEqual(later.headline, "Next in court in 9 days.")
        XCTAssertEqual(later.detail, "Wednesday, 28 October 2026 · Delhi High Court")
        XCTAssertTrue(later.offers.isEmpty)
    }

    func testNotFiledOffersToFindTheCaseLater() {
        let s = standing(project: aProject(courtStatus: "not_filed"))
        XCTAssertEqual(s.headline, "Not filed in court yet.")
        XCTAssertEqual(s.offers, [.findCase])
    }

    func testALinkedCaseWithoutADateWaits() {
        let waiting = standing(linked: LinkedCaseSummary(id: "c9"), last: "2026-09-10")
        XCTAssertEqual(waiting.headline, "Waiting for the next date.")
        XCTAssertEqual(waiting.detail, "Last heard on Thursday, 10 September 2026. The new date appears here as soon as the court gives one.")
        let fresh = standing(linked: LinkedCaseSummary(id: "c9"))
        XCTAssertEqual(fresh.headline, "No hearing date yet.")
    }

    func testNoCaseAtAllOffersBothWaysIn() {
        let s = standing()
        XCTAssertEqual(s.headline, "Add the court case to follow it here.")
        XCTAssertEqual(s.offers, [.findCase, .addDate])
    }

    /// A date in the past is not "next": the sentence falls through to the linked-case branch.
    func testAPastDateIsNotNext() {
        let s = standing(linked: LinkedCaseSummary(id: "c9"), next: "2026-10-01", last: "2026-10-01")
        XCTAssertEqual(s.headline, "Waiting for the next date.")
    }
}

// MARK: - The view model

final class MatterWorkspaceViewModelTests: XCTestCase {

    func testTheOverviewReadsEverySectionOffOneLoad() async throws {
        let detail = try decodedDetail()
        await withWorkspace { fake, model in
            fake.detail = detail
            await model.load()
            XCTAssertEqual(model.tasksSummary, "1 open")
            XCTAssertEqual(model.feesSummary, "₹40,000.50 of ₹1,00,000 received")
            XCTAssertEqual(model.moneyFacts.map(\.label), ["Billed", "Received", "Outstanding", "Expenses"])
            XCTAssertEqual(model.amountLabel(for: detail.ledger[1]), "+₹40,000.50")
            XCTAssertEqual(model.amountLabel(for: detail.ledger[2]), "−₹1,250")
            XCTAssertEqual(model.peopleByRole.map(\.role), ["Client", "Opposing counsel"])
            XCTAssertEqual(model.nextHearingKey, "2026-10-28")
            XCTAssertEqual(model.standing?.headline, "Next in court in 9 days.")
            XCTAssertEqual(model.latestOrder?.id, "ci1")
            XCTAssertEqual(model.courtSyncLine?.hasPrefix("Synced from the court"), true)
            XCTAssertEqual(model.facts.map(\.label), ["Client", "Your side", "Opposite party", "Case", "Forum", "Practice area", "Stage", "Next hearing"])
            XCTAssertEqual(model.facts.first { $0.label == "Case" }?.value, "ARB.P. 112/2025")
        }
    }

    func testOverdueIsCountedAgainstIndiasDay() async {
        await withWorkspace(today: "2026-10-19") { fake, model in
            fake.detail = ProjectDetail(project: aProject(), updates: [], courtHistory: [], tasks: [
                task("t1", "Late", due: "2026-10-18"), task("t2", "Today", due: "2026-10-19"),
                task("t3", "Done late", due: "2026-10-01", status: "done"),
            ])
            await model.load()
            XCTAssertEqual(model.overdueTasks.map(\.id), ["t1"])
            XCTAssertEqual(model.tasksSummary, "2 open · 1 overdue")
            XCTAssertEqual(model.dueLabel(for: model.tasks[0]), "Overdue since Sun 18 Oct")
            XCTAssertEqual(model.dueLabel(for: model.tasks[1]), "Due today")
            XCTAssertEqual(model.dueLabel(for: model.tasks[2]), "Was due Thu 1 Oct")
        }
    }

    /// The strip disappears once there is nothing left — a finished checklist is noise.
    func testTheSetupStripGoesAwayWhenComplete() async {
        await withWorkspace { fake, model in
            let project = aProject(client: "Helios", ourSide: "petitioner", oppositeParty: "Northgrid",
                                   practiceArea: "arbitration", linkedCaseID: "c9", fileCount: 3)
            fake.detail = ProjectDetail(project: project, updates: [], courtHistory: [],
                                        people: [person("client", "Helios", phone: "1")])
            await model.load()
            XCTAssertNil(model.setup)
        }
    }

    /// The detail route does not count files; the list route does. Until the matter's files are
    /// listed, the documents step reads from the list count, then from the listing.
    func testTheDocumentsStepReadsTheListingOnceItHasOne() async {
        await withWorkspace { fake, model in
            fake.detail = ProjectDetail(project: aProject(fileCount: 0), updates: [], courtHistory: [])
            fake.files = [folder("_projects/prj_1/Pleadings", [.file(readyFile("_projects/prj_1/Pleadings/Plaint.pdf"))])]
            await model.load()
            XCTAssertEqual(model.setup?.steps.first { $0.key == .documents }?.done, false)
            await model.loadFiles()
            XCTAssertEqual(model.knownFileCount, 1)
            XCTAssertEqual(model.setup?.steps.first { $0.key == .documents }?.done, true)
            XCTAssertEqual(model.folders.map(\.name), ["Pleadings"])
            XCTAssertEqual(model.attachDestinations.prefix(5).map { $0 }, MatterVocabulary.standardFolders)
        }
    }

    func testAWriteReloadsTheMatterSoEveryTotalAgreesWithTheServer() async {
        await withWorkspace { fake, model in
            fake.detail = ProjectDetail(project: aProject(), updates: [], courtHistory: [])
            await model.load()
            XCTAssertEqual(fake.loads, 1)
            let ok = await model.addTask(TaskDraft(title: "File rejoinder", dueDate: "2026-10-20", kind: "filing"))
            XCTAssertTrue(ok)
            XCTAssertEqual(fake.savedTasks.count, 1)
            XCTAssertEqual(fake.savedTasks[0].draft.kind, "filing")
            XCTAssertEqual(fake.loads, 2)
            XCTAssertNil(model.writeError)
        }
    }

    /// Ticking a task sends its status and nothing that could clear a field.
    func testTickingATaskSendsOnlyTheStatus() async {
        await withWorkspace { fake, model in
            fake.detail = ProjectDetail(project: aProject(), updates: [], courtHistory: [], tasks: [task("t1", "X", due: "2026-10-20")])
            await model.load()
            await model.setDone(model.tasks[0], true)
            XCTAssertEqual(fake.savedTasks[0].id, "t1")
            XCTAssertEqual(fake.savedTasks[0].draft.status, "done")
            XCTAssertNil(fake.savedTasks[0].draft.dueDate)
            XCTAssertNil(fake.savedTasks[0].draft.kind)
        }
    }

    func testAZeroAmountIsRefusedBeforeItIsSent() async {
        await withWorkspace { fake, model in
            fake.detail = ProjectDetail(project: aProject(), updates: [], courtHistory: [])
            await model.load()
            let ok = await model.addLedgerEntry(LedgerDraft(kind: .fee, amount: 0))
            XCTAssertFalse(ok)
            XCTAssertEqual(model.writeError, "Enter an amount.")
            XCTAssertTrue(fake.savedEntries.isEmpty)
        }
    }

    func testAFailedWriteSaysWhyAndKeepsTheMatter() async {
        await withWorkspace { fake, model in
            fake.detail = ProjectDetail(project: aProject(), updates: [], courtHistory: [])
            await model.load()
            fake.error = APIError.server(status: 400, message: "dueDate must be a date (YYYY-MM-DD)")
            let ok = await model.addTask(TaskDraft(title: "X", dueDate: "20/10/26"))
            XCTAssertFalse(ok)
            XCTAssertEqual(model.writeError, "dueDate must be a date (YYYY-MM-DD)")
            XCTAssertNotNil(model.project)
        }
    }

    func testAttachingReportsEachDocumentAndRelistsTheFiles() async {
        await withWorkspace { fake, model in
            fake.detail = ProjectDetail(project: aProject(), updates: [], courtHistory: [])
            fake.attachAnswer = [
                AttachedFile(name: "Plaint.pdf", folder: "_projects/prj_1/Pleadings", status: "indexing"),
                AttachedFile(name: "Plaint.pdf", folder: nil, status: "skipped", reason: "Already in this matter (Pleadings/Plaint.pdf)"),
            ]
            await model.load()
            let ok = await model.attach([ChatAttachment(name: "Plaint.pdf", folderName: "Chat_Uploads")], into: "Pleadings")
            XCTAssertTrue(ok)
            XCTAssertEqual(fake.attached[0].subfolder, "Pleadings")
            XCTAssertEqual(model.attachSummary, "1 attached · 1 skipped")
            XCTAssertEqual(model.attachReport?[1].line, "Plaint.pdf — Already in this matter (Pleadings/Plaint.pdf)")
            XCTAssertEqual(fake.fileLoads, 1)
        }
    }

    /// Being told to wait is not a failure: the five-minute rule lands as a notice.
    func testACourtRefreshToldToWaitIsANoticeNotAnError() async {
        await withWorkspace { fake, model in
            fake.detail = ProjectDetail(project: aProject(linkedCaseID: "c9"), updates: [], courtHistory: [])
            await model.load()
            fake.refreshError = APIError.server(status: 429, message: "The court was asked recently. Try again in about 4 minutes.")
            await model.refreshFromCourt()
            XCTAssertEqual(model.notice, "The court was asked recently. Try again in about 4 minutes.")
            XCTAssertNil(model.writeError)
            fake.refreshError = nil
            await model.refreshFromCourt()
            XCTAssertEqual(model.notice, "Asked the court. The record below is what it holds now.")
        }
    }
}

// MARK: - The list, and the case that opens its matter

@MainActor
private func withMatterList(_ body: @MainActor (FakeMatters, ProjectListViewModel) async -> Void) async {
    let fake = FakeMatters()
    await body(fake, ProjectListViewModel(service: fake))
}

final class MatterListCreateTests: XCTestCase {

    func testANewMatterNeedsOnlyANameAndOpensItself() async {
        await withMatterList { fake, model in
            let id = await model.create(named: "  Helios v. Northgrid  ")
            XCTAssertEqual(id, "prj_new")
            XCTAssertEqual(fake.created.first?.name, "Helios v. Northgrid")
            XCTAssertNil(model.createError)
        }
    }

    func testABlankNameIsRefusedWithoutARequest() async {
        await withMatterList { fake, model in
            let id = await model.create(named: "   ")
            XCTAssertNil(id)
            XCTAssertEqual(model.createError, "Give the matter a name.")
            XCTAssertTrue(fake.created.isEmpty)
        }
    }
}

@MainActor
private func withCase(
    projects: FakeMatters?, _ body: @MainActor (FakeCases, CaseDetailViewModel) async -> Void
) async {
    let fake = FakeCases()
    fake.detail = CaseDetail(legalCase: LegalCase(id: "c9"), events: [], items: [])
    await body(fake, CaseDetailViewModel(caseID: "c9", service: fake, projects: projects))
}

final class CaseOpensItsMatterTests: XCTestCase {

    func testACaseOpensTheMatterMadeForIt() async {
        let matters = FakeMatters()
        await withCase(projects: matters) { _, model in
            await model.load()
            XCTAssertTrue(model.canOpenMatter)
            let id = await model.openMatter()
            XCTAssertEqual(id, "prj_from_c9")
            XCTAssertEqual(matters.fromCase, ["c9"])
        }
    }

    /// Without the matter routes wired there is no button to press.
    func testNoMatterRoutesMeansNoButton() async {
        await withCase(projects: nil) { _, model in
            await model.load()
            XCTAssertFalse(model.canOpenMatter)
            let id = await model.openMatter()
            XCTAssertNil(id)
        }
    }

    func testARefusalIsWordedNotSwallowed() async {
        let matters = FakeMatters()
        matters.error = APIError.server(status: 403, message: "You are not a member of the team that tracks that case")
        await withCase(projects: matters) { _, model in
            await model.load()
            let id = await model.openMatter()
            XCTAssertNil(id)
            XCTAssertEqual(model.matterError, "You are not a member of the team that tracks that case")
        }
    }
}

// MARK: - The wire, request by request

final class MatterServiceWireTests: XCTestCase {

    private static let config = APIConfig(baseURL: URL(string: "https://example.test/api")!)

    override func setUp() { super.setUp(); HTTPStub.reset() }
    override func tearDown() { HTTPStub.reset(); super.tearDown() }

    private func makeService() async -> ProjectService {
        let client = APIClient(config: Self.config, session: HTTPStub.session())
        await client.setCredentials(Credentials(token: "tok-abc", userID: 42))
        return ProjectService(client: client)
    }

    private func body(_ request: URLRequest?) throws -> [String: Any] {
        let data = try XCTUnwrap(request?.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testAMatterFromACaseSendsTheCallerAndTheCase() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":true,"project":{"id":"prj_7","name":"X"},"existed":true}"#))
        let result = try await service.projectFromCase(caseID: "c9")
        XCTAssertEqual(result.project.id, "prj_7")
        XCTAssertTrue(result.existed)
        let sent = try body(HTTPStub.lastRequest)
        XCTAssertEqual(sent["userId"] as? String, "42")
        XCTAssertEqual(sent["caseId"] as? String, "c9")
        XCTAssertEqual(HTTPStub.lastRequest?.url?.path, "/api/project-from-case")
    }

    /// A blank is omitted, never sent as `""` or `null` — on an edit that would clear the field.
    func testATaskSendsOnlyWhatItHas() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":true,"task":{"id":"t1","title":"X","status":"open"}}"#))
        _ = try await service.saveTask(projectID: "prj_1", id: nil, draft: TaskDraft(title: "X", notes: "  ", dueDate: nil, kind: "filing"))
        let sent = try body(HTTPStub.lastRequest)
        XCTAssertEqual(Set(sent.keys), ["userId", "projectId", "title", "kind"])
        _ = try await service.saveTask(projectID: "prj_1", id: "t1", draft: TaskDraft(title: "X", status: "done"))
        let edit = try body(HTTPStub.lastRequest)
        XCTAssertEqual(edit["id"] as? String, "t1")
        XCTAssertEqual(edit["status"] as? String, "done")
    }

    func testMoneyGoesAsRupeesInANumber() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":true,"entry":{"id":"l1","kind":"payment","amount":40000.5,"amount_paise":4000050}}"#))
        let entry = try await service.saveLedgerEntry(
            projectID: "prj_1", id: nil,
            draft: LedgerDraft(kind: .payment, amount: 40000.5, entryDate: "2026-09-15", mode: "upi", reference: "UPI-7781"))
        XCTAssertEqual(entry.rupees, 40000.5)
        let sent = try body(HTTPStub.lastRequest)
        XCTAssertEqual(sent["amount"] as? Double, 40000.5)
        XCTAssertEqual(sent["kind"] as? String, "payment")
        XCTAssertEqual(sent["mode"] as? String, "upi")
    }

    /// A loose file at the root of My Files is named with the root folder the file routes use.
    func testAttachNamesFilesAsMyFilesDoesAndTheRootAsADot() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":true,"folder":"_projects/prj_1/Pleadings","files":[{"name":"Plaint.pdf","folder":"_projects/prj_1/Pleadings","status":"indexing"}]}"#))
        let report = try await service.attach(
            projectID: "prj_1",
            files: [ChatAttachment(name: "Plaint.pdf", folderName: "Chat_Uploads"), ChatAttachment(name: "Loose.pdf", folderName: nil)],
            subfolder: "Pleadings")
        XCTAssertEqual(report.first?.status, "indexing")
        let sent = try body(HTTPStub.lastRequest)
        let files = try XCTUnwrap(sent["files"] as? [[String: Any]])
        XCTAssertEqual(files[0]["folderName"] as? String, "Chat_Uploads")
        XCTAssertEqual(files[1]["folderName"] as? String, ".")
        XCTAssertEqual(sent["subfolder"] as? String, "Pleadings")
    }

    func testAttachRefusesMoreThanTheServerTakesWithoutARequest() async {
        let service = await makeService()
        let many = (0..<26).map { ChatAttachment(name: "f\($0).pdf", folderName: "A") }
        do {
            _ = try await service.attach(projectID: "prj_1", files: many, subfolder: nil)
            XCTFail("expected a refusal")
        } catch let error as APIError {
            XCTAssertEqual(error, .server(status: 400, message: "Attach up to 25 documents at a time."))
        } catch { XCTFail("\(error)") }
        XCTAssertTrue(HTTPStub.seen.isEmpty)
    }

    func testADeleteCarriesTheIdInTheQuery() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":true}"#))
        try await service.deletePerson(id: "pp_1")
        let request = try XCTUnwrap(HTTPStub.lastRequest)
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.url?.path, "/api/project-person")
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "id" }?.value, "pp_1")
        XCTAssertEqual(items.first { $0.name == "userId" }?.value, "42")
    }

    func testTheProjectFilesTreeJoinsFoldersAndLooseFiles() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":true,"root":"_projects/prj_1","folders":[{"name":"Pleadings","path":"_projects/prj_1/Pleadings","type":"folder","files":[{"name":"Plaint.pdf","path":"_projects/prj_1/Pleadings/Plaint.pdf","type":"file","status":"ready"}]}],"files":[{"name":"Note.pdf","path":"_projects/prj_1/Note.pdf","type":"file","status":"ready"}]}"#))
        let tree = try await service.projectFiles(projectID: "prj_1")
        XCTAssertEqual(FileService.allFiles(in: tree).map(\.name), ["Plaint.pdf", "Note.pdf"])
    }

    func testARefreshToldToWaitIsWordedInMinutes() async {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":false,"error":"Too many requests","retryAfter":200}"#, status: 429))
        do {
            try await service.refreshLinkedCase(projectID: "prj_1")
            XCTFail("expected 429")
        } catch let error as APIError {
            XCTAssertEqual(error, .server(status: 429, message: "The court was asked recently. Try again in about 4 minutes."))
        } catch { XCTFail("\(error)") }
    }

    func testAPatchSendsItsFieldsAsAnObject() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":true,"project":{"id":"prj_1","name":"X","our_side":"respondent"}}"#))
        let project = try await service.patch(projectID: "prj_1", fields: ["ourSide": .string("respondent")])
        XCTAssertEqual(project.ourSideLabel, "Respondent")
        let sent = try body(HTTPStub.lastRequest)
        XCTAssertEqual((sent["fields"] as? [String: Any])?["ourSide"] as? String, "respondent")
    }
}
