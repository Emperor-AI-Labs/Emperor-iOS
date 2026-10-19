import XCTest
@testable import EmperorCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The rest of the Matters workspace (docs/projects.md): the matter's own conversations and
// drafts, the chronology read from its documents, its banner, and deleting it. Each test is named
// for what a person sees when the rule it pins is broken.

// MARK: - Stand-ins

private struct Refused: Error, LocalizedError {
    var errorDescription: String? { "The server refused it." }
}

private final class FakeWorkspace: ProjectProviding, @unchecked Sendable {
    var detail: ProjectDetail?
    var tree: [FileNode] = []
    var extraction = ChronologyExtraction()
    var extractError: Error?
    /// Holds the read open this long, so a test can close the sheet while it is in flight.
    var extractDelay: Duration?
    /// The saves (1-based) that fail.
    var failingSaves: Set<Int> = []
    var banner: Data? = Data([0xFF, 0xD8, 0xFF])
    var deleteError: Error?

    private(set) var loads = 0
    private(set) var extracted: [[ChatAttachment]?] = []
    private(set) var saved: [UpdateDraft] = []
    private(set) var bannerFetches = 0
    private(set) var uploads: [String] = []
    private(set) var bannerDeletes = 0
    private(set) var deletes: [(id: String, confirm: String)] = []

    func projects(includeArchived: Bool) async throws -> [Project] { [] }
    func project(id: String) async throws -> ProjectDetail {
        loads += 1
        guard let detail else { throw APIError.server(status: 404, message: ProjectService.projectGoneMessage) }
        return detail
    }
    func projectFiles(projectID: String) async throws -> [FileNode] { tree }
    func extractChronology(projectID: String, files: [ChatAttachment]?) async throws -> ChronologyExtraction {
        extracted.append(files)
        if let extractDelay { try? await Task.sleep(for: extractDelay) }
        if let extractError { throw extractError }
        return extraction
    }
    func saveUpdate(projectID: String, id: String?, draft: UpdateDraft) async throws -> String {
        saved.append(draft)
        if failingSaves.contains(saved.count) { throw APIError.server(status: 400, message: "kind must be one of …") }
        return "u\(saved.count)"
    }
    func bannerImage(projectID: String) async throws -> Data? { bannerFetches += 1; return banner }
    func uploadBanner(projectID: String, dataURL: String) async throws { uploads.append(dataURL) }
    func deleteBanner(projectID: String) async throws { bannerDeletes += 1 }
    func deleteProject(id: String, confirm: String) async throws {
        deletes.append((id, confirm))
        if let deleteError { throw deleteError }
    }
}

private final class FakeMatterDrafts: DraftHistoryProviding, @unchecked Sendable {
    var documents: [DraftedItem] = []
    var tables: [DraftedItem] = []
    var documentsError: Error?
    var tablesError: Error?
    /// Both halves are asked for at once, so the record is kept behind a lock.
    private let lock = NSLock()
    private var _asked: [(kind: DraftKind, projectID: String?)] = []
    var asked: [(kind: DraftKind, projectID: String?)] { lock.withLock { _asked } }

    func drafts(_ kind: DraftKind) async throws -> [DraftedItem] { try await drafts(kind, projectID: nil) }
    func drafts(_ kind: DraftKind, projectID: String?) async throws -> [DraftedItem] {
        lock.withLock { _asked.append((kind, projectID)) }
        switch kind {
        case .document: if let documentsError { throw documentsError }; return documents
        case .table: if let tablesError { throw tablesError }; return tables
        }
    }
    func content(id: String) async throws -> String { "<p>Body</p>" }
}

/// Records the matter every turn names, through the seven-argument form.
private final class MatterRecordingChat: ChatProviding, @unchecked Sendable {
    private(set) var projectIDs: [String?] = []
    private(set) var histories: [[ChatMessage]] = []

    func messages(chatID: String) async throws -> [ChatMessage] { [] }
    func streamStatus(chatID: String) async throws -> StreamStatus { StreamStatus(active: false) }
    func send(
        history: [ChatMessage], chatID: String, model: ChatModel, role: ChatRole?,
        attachments: [ChatAttachment]?, webSearch: Bool
    ) async throws -> AsyncThrowingStream<ChatTurnEvent, Error> {
        XCTFail("a turn went out through the form that carries no matter")
        return AsyncThrowingStream { $0.finish() }
    }
    func send(
        history: [ChatMessage], chatID: String, model: ChatModel, role: ChatRole?,
        attachments: [ChatAttachment]?, webSearch: Bool, projectID: String?
    ) async throws -> AsyncThrowingStream<ChatTurnEvent, Error> {
        projectIDs.append(projectID)
        histories.append(history)
        return AsyncThrowingStream { continuation in
            continuation.yield(.content(StreamContent.parse("Answer")))
            continuation.finish()
        }
    }
}

/// Implements only the six-argument form, as every older stand-in does.
private final class SixArgumentChat: ChatProviding, @unchecked Sendable {
    private(set) var turns = 0
    func messages(chatID: String) async throws -> [ChatMessage] { [] }
    func streamStatus(chatID: String) async throws -> StreamStatus { StreamStatus(active: false) }
    func send(
        history: [ChatMessage], chatID: String, model: ChatModel, role: ChatRole?,
        attachments: [ChatAttachment]?, webSearch: Bool
    ) async throws -> AsyncThrowingStream<ChatTurnEvent, Error> {
        turns += 1
        return AsyncThrowingStream { continuation in
            continuation.yield(.content(StreamContent.parse("Answer")))
            continuation.finish()
        }
    }
}

// MARK: - Builders

private func matter(
    name: String? = "Helios v. Northgrid", banner: String? = nil, color: String? = nil, updatedAt: String? = "2026-10-18 06:30:00"
) -> Project {
    var project = Project(id: "prj_1", name: name, color: color, updatedAtRaw: updatedAt)
    project.banner = banner
    return project
}

private func detail(
    _ project: Project = matter(), updates: [ProjectUpdate] = [], chats: [ProjectChatRow] = []
) -> ProjectDetail {
    ProjectDetail(project: project, updates: updates, courtHistory: [], chats: chats)
}

private func draft(_ id: String, project: String?, created: String, type: String? = "doc") -> DraftedItem {
    DraftedItem(id: id, chatID: "c_\(id)", title: "Draft \(id)", type: type, createdAtRaw: created,
                chatTitle: "Chat", projectID: project)
}

@MainActor
private func withWorkspace(_ body: @MainActor (FakeWorkspace, ProjectDetailViewModel) async -> Void) async {
    let fake = FakeWorkspace()
    fake.detail = detail()
    await body(fake, ProjectDetailViewModel(projectID: "prj_1", service: fake, todayKey: { "2026-10-19" }))
}

@MainActor
private final class Counter { var value = 0 }

@MainActor
private func withBuild(
    updates: [ProjectUpdate] = [],
    _ body: @MainActor (FakeWorkspace, ChronologyBuildViewModel, () -> Int) async -> Void
) async {
    let fake = FakeWorkspace()
    let reloads = Counter()
    let model = ChronologyBuildViewModel(
        projectID: "prj_1", service: fake, updates: updates, reload: { reloads.value += 1 })
    await body(fake, model, { reloads.value })
}

@MainActor
private func settle(_ model: ChatViewModel) async {
    for _ in 0..<400 {
        if !model.isStreaming { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("stream did not settle")
}

// MARK: - Sections and conversations

final class MatterSectionsTests: XCTestCase {

    func testTheSectionsRunInTheWebsOrder() {
        XCTAssertEqual(
            ProjectDetailViewModel.Section.allCases.map(\.rawValue),
            ["overview", "ask", "files", "drafts", "chronology", "court", "tasks", "fees", "people"])
        XCTAssertEqual(ProjectDetailViewModel.Section.ask.title, "Ask Emperor")
    }

    func testTheMattersConversationsDecodeFromTheDetail() throws {
        let response = try JSONDecoder().decode(
            ProjectDetailResponse.self,
            from: Data(#"{"success":true,"project":{"id":"prj_1","name":"A"},"chats":[{"id":"c1","title":"New Chat","updated_at":"2026-10-17 09:00:00","linked_at":null},{"id":"c2","title":"Bail grounds","updated_at":"2026-10-18 09:00:00","linked_at":"2026-10-01T10:00:00.000Z"}]}"#.utf8))
        let chats = try XCTUnwrap(response.chats)
        XCTAssertEqual(chats.map(\.id), ["c1", "c2"])
        XCTAssertNil(chats[0].linkedAtRaw)
        XCTAssertNotNil(chats[1].lastActivity)
    }

    /// A conversation the server made before its first question is called "New Chat" there.
    func testAPlaceholderTitleReadsAsANewConversation() {
        for title in [nil, "", "  New chat ", "AI Chat", "Untitled", "untitled conversation", "Untitled session"] {
            XCTAssertEqual(ProjectChatRow(id: "c", title: title).displayTitle, "New conversation", "\(title ?? "nil")")
        }
        XCTAssertEqual(ProjectChatRow(id: "c", title: " Bail grounds ").displayTitle, "Bail grounds")
        XCTAssertEqual(ProjectChatRow(id: "c", title: "New chat about bail").displayTitle, "New chat about bail")
    }

    func testTheNewestConversationIsFirst() async {
        await withWorkspace { fake, model in
            fake.detail = detail(chats: [
                ProjectChatRow(id: "old", updatedAtRaw: "2026-10-01 09:00:00"),
                ProjectChatRow(id: "undated"),
                ProjectChatRow(id: "new", updatedAtRaw: "2026-10-18T09:00:00.000Z"),
                ProjectChatRow(id: "linked", linkedAtRaw: "2026-10-10 09:00:00"),
            ])
            await model.load()
            XCTAssertEqual(model.chats.map(\.id), ["new", "linked", "old", "undated"])
        }
    }

    func testANewConversationGetsAFreshIdEachTime() {
        let a = ProjectDetailViewModel.newConversationID()
        let b = ProjectDetailViewModel.newConversationID()
        XCTAssertFalse(a.isEmpty)
        XCTAssertNotEqual(a, b)
    }

    /// The folder a file is named by is its path less its name — `_projects/<id>/<sub>` — and a
    /// file at the matter's root is in the matter's root folder.
    func testAMattersFilesAreNamedByTheirFolderInsideTheMatter() async {
        await withWorkspace { fake, model in
            fake.tree = [
                folder("_projects/prj_1/Pleadings", [
                    .file(readyFile("_projects/prj_1/Pleadings/Plaint.pdf")),
                    .file(FileNode.StoredFile(name: "Reply.pdf", path: "_projects/prj_1/Pleadings/Reply.pdf", status: "Reading page 2")),
                ]),
                .file(FileNode.StoredFile(name: "Loose.pdf", path: "Loose.pdf", status: "scanned")),
            ]
            await model.loadFiles()
            let files = model.matterFiles
            XCTAssertEqual(files.map(\.folderName), ["_projects/prj_1/Pleadings", "_projects/prj_1/Pleadings", "_projects/prj_1"])
            XCTAssertEqual(files.map(\.sub), ["Pleadings", "Pleadings", ""])
            XCTAssertEqual(files[1].notReadyLine, "still processing")
            XCTAssertEqual(model.readyFiles.map(\.attachment), [
                ChatAttachment(name: "Plaint.pdf", folderName: "_projects/prj_1/Pleadings"),
                ChatAttachment(name: "Loose.pdf", folderName: "_projects/prj_1"),
            ])
        }
    }

    func testAFileThatFailedSaysSo() {
        let file = MatterFile.flatten([.file(FileNode.StoredFile(name: "X.pdf", path: "_projects/p/X.pdf", status: "ERROR: unreadable"))], projectID: "p")
        XCTAssertEqual(file.first?.notReadyLine, "could not be read")
    }
}

// MARK: - A turn in a matter

final class MatterConversationTurnTests: XCTestCase {

    func testEveryTurnInAMatterConversationNamesTheMatter() async {
        await runMatterTurns()
    }

    func testAnOrdinaryConversationNamesNoMatter() async {
        await runOrdinaryTurn()
    }

    /// A stand-in written before matters existed still receives the turn.
    func testAnOlderStandInStillGetsTheTurn() async {
        await runSixArgumentTurn()
    }
}

@MainActor
private func runMatterTurns() async {
    let fake = MatterRecordingChat()
    let model = ChatViewModel(chatID: "c1", service: fake, projectID: " prj_1 ")
    XCTAssertEqual(model.projectID, "prj_1")
    model.send("Summarise where this matter stands.")
    await settle(model)
    model.send("And the next hearing?")
    await settle(model)
    // An edit and re-answer is a turn too.
    if let first = model.messages.first { model.edit(first, to: "Summarise it briefly.") }
    await settle(model)
    XCTAssertEqual(fake.projectIDs, ["prj_1", "prj_1", "prj_1"])
    XCTAssertEqual(fake.histories.last?.count, 1)
}

@MainActor
private func runOrdinaryTurn() async {
    let fake = MatterRecordingChat()
    let model = ChatViewModel(chatID: "c1", service: fake, projectID: "  ")
    XCTAssertNil(model.projectID)
    model.send("Hello")
    await settle(model)
    XCTAssertEqual(fake.projectIDs, [nil])
}

@MainActor
private func runSixArgumentTurn() async {
    let fake = SixArgumentChat()
    let model = ChatViewModel(chatID: "c1", service: fake, projectID: "prj_1")
    model.send("Hello")
    await settle(model)
    XCTAssertEqual(fake.turns, 1)
}

// MARK: - Proposals

final class ChronologyProposalTests: XCTestCase {

    func testDatesAreReadAsTheWebReadsThem() {
        XCTAssertEqual(ChronologyProposal.parseDocDate("2019-03-05"), "2019-03-05")
        XCTAssertEqual(ChronologyProposal.parseDocDate("2019-3-5T10:00:00Z"), "2019-03-05")
        XCTAssertEqual(ChronologyProposal.parseDocDate(" 5.3.2019 "), "2019-03-05")
        XCTAssertEqual(ChronologyProposal.parseDocDate("05/03/2019"), "2019-03-05")
        XCTAssertEqual(ChronologyProposal.parseDocDate("29-02-2020"), "2020-02-29")
        XCTAssertNil(ChronologyProposal.parseDocDate("29-02-2019"), "no such day")
        XCTAssertNil(ChronologyProposal.parseDocDate("2019-13-01"))
        XCTAssertNil(ChronologyProposal.parseDocDate("March 2019"))
        XCTAssertNil(ChronologyProposal.parseDocDate("2019"))
        XCTAssertNil(ChronologyProposal.parseDocDate("05.03.2019 onwards"))
        XCTAssertNil(ChronologyProposal.parseDocDate("२०१९-०३-०५"), "only ASCII digits")
        XCTAssertNil(ChronologyProposal.parseDocDate(nil))
    }

    func testTheTitleRuleMatchesTheWebs() {
        XCTAssertEqual(ChronologyProposal.norm("  Notice u/s 138 — issued!! "), "notice u s 138 issued")
        XCTAssertTrue(ChronologyProposal.sameEvent("legal notice issued", "legal notice issued"))
        XCTAssertTrue(ChronologyProposal.sameEvent("legal notice issued to respondent", "legal notice issued"))
        XCTAssertFalse(ChronologyProposal.sameEvent("notice", "notice issued"), "under twelve characters must be equal")
        XCTAssertFalse(ChronologyProposal.sameEvent("", ""))
    }

    /// Building twice must not double the list: what is already recorded starts unticked.
    func testAnEventAlreadyOnTheRecordStartsUnticked() {
        let proposals = ChronologyProposal.proposals(
            from: [
                ExtractedEvent(date: "2026-03-02", title: "Invoice No. 14 raised on Northgrid", kind: "event", sourceRef: "Plaint.pdf, p. 4"),
                ExtractedEvent(date: "2026-03-03", title: "Invoice No. 14 raised on Northgrid"),
                ExtractedEvent(date: "2026-03-02", title: "Payment received"),
            ],
            known: [(day: "2026-03-02", title: "Invoice no 14 raised on Northgrid Power")])
        XCTAssertTrue(proposals[0].isDuplicate)
        XCTAssertFalse(proposals[0].isOn)
        XCTAssertFalse(proposals[1].isDuplicate, "another day is another event")
        XCTAssertTrue(proposals[1].isOn)
        XCTAssertFalse(proposals[2].isDuplicate)
        XCTAssertEqual(proposals[0].sourceRef, "Plaint.pdf, p. 4")
    }

    /// An event the model could not pin to a day is shown, never saved as a guess.
    func testAnUndatedEventIsShownButNotTicked() {
        let proposals = ChronologyProposal.proposals(
            from: [ExtractedEvent(date: "March 2019", title: "Agreement signed"), ExtractedEvent(title: "Undated thing"),
                   ExtractedEvent(date: "2019-03-05", title: "  ")],
            known: [])
        XCTAssertTrue(proposals[0].isUndated)
        XCTAssertFalse(proposals[0].isOn)
        XCTAssertFalse(proposals[0].isUsable)
        XCTAssertEqual(proposals[0].undatedLine, "Read as “March 2019”")
        XCTAssertEqual(proposals[1].undatedLine, "No date given")
        XCTAssertFalse(proposals[2].isOn, "no title, nothing to save")
    }

    /// The extractor's `notice` and `agreement` are not chronology kinds; they are events.
    func testAKindTheChronologyDoesNotKnowIsAnEvent() {
        let proposals = ChronologyProposal.proposals(
            from: ["notice", "agreement", "hearing", "filing", nil].map { ExtractedEvent(date: "2026-01-01", title: "X", kind: $0) },
            known: [])
        XCTAssertEqual(proposals.map(\.kind), ["event", "event", "hearing", "filing", "event"])
    }

    func testOneMalformedEventCostsOnlyThatEvent() throws {
        let response = try JSONDecoder().decode(
            ChronologyExtractResponse.self,
            from: Data(#"{"success":true,"events":[{"date":"2026-01-01","title":"Filed"},"garbage",{"date":20260102,"title":"Numbered"}],"files":2,"skipped":["Scan.pdf"],"partial":true}"#.utf8))
        XCTAssertEqual(response.events?.map(\.title), ["Filed", "Numbered"])
        XCTAssertEqual(response.skipped, ["Scan.pdf"])
        XCTAssertEqual(response.partial, true)
    }
}

// MARK: - Build from documents

final class ChronologyBuildTests: XCTestCase {

    func testReadingAllDocumentsSendsNoList() async {
        await withBuild { fake, model, _ in
            fake.extraction = ChronologyExtraction(events: [ExtractedEvent(date: "2026-01-01", title: "Filed")])
            XCTAssertTrue(model.canStart)
            await model.start()
            XCTAssertEqual(model.phase, .review)
            XCTAssertEqual(fake.extracted.count, 1)
            XCTAssertNil(fake.extracted[0] ?? nil)
            XCTAssertEqual(model.acceptTitle, "Add 1 event")
        }
    }

    func testChoosingDocumentsSendsOnlyTheReadyOnesTicked() async {
        await withBuild { fake, model, _ in
            fake.tree = [folder("_projects/prj_1/Orders", [
                .file(readyFile("_projects/prj_1/Orders/Order.pdf")),
                .file(FileNode.StoredFile(name: "Wip.pdf", path: "_projects/prj_1/Orders/Wip.pdf", status: "Reading")),
            ])]
            await model.chooseSome()
            XCTAssertFalse(model.canStart, "nothing chosen yet")
            let files = model.files ?? []
            model.toggle(files[1])
            XCTAssertFalse(model.isChosen(files[1]), "a file still being read cannot be chosen")
            model.toggle(files[0])
            XCTAssertEqual(model.readingCount, "1 file")
            await model.start()
            XCTAssertEqual(fake.extracted.first ?? nil, [ChatAttachment(name: "Order.pdf", folderName: "_projects/prj_1/Orders")])
        }
    }

    func testARefusalIsShownAndTheChoiceCanBeMadeAgain() async {
        await withBuild { fake, model, _ in
            fake.extractError = APIError.server(status: 503, message: "No AI provider is configured")
            await model.start()
            XCTAssertEqual(model.phase, .failed)
            XCTAssertEqual(model.failure, "No AI provider is configured")
            model.backToPick()
            XCTAssertEqual(model.phase, .pick)
        }
    }

    func testNothingFoundIsSaidPlainly() async {
        await withBuild { _, model, _ in
            await model.start()
            XCTAssertTrue(model.proposals.isEmpty)
            XCTAssertEqual(model.nothingFoundLine,
                           "No dated events were found in this matter’s documents. Scanned files that are still being read appear once processing finishes.")
        }
    }

    func testAPartialReadSaysTheListMayBeIncomplete() async {
        await withBuild { fake, model, _ in
            fake.extraction = ChronologyExtraction(events: [ExtractedEvent(date: "2026-01-01", title: "Filed")], partial: true)
            await model.start()
            XCTAssertNotNil(model.partialLine)
        }
    }

    /// One at a time, each an `ai` entry naming its page; a failure is counted and the rest go on.
    func testAcceptingSavesEachInTurnAndCountsWhatFailed() async {
        await withBuild { fake, model, reloads in
            fake.extraction = ChronologyExtraction(events: [
                ExtractedEvent(date: "2026-01-01", title: "Plaint filed", details: "Before the Commercial Court", kind: "filing", sourceRef: "Plaint.pdf, p. 1"),
                ExtractedEvent(date: "2026-01-05", title: "Notice issued", kind: "notice"),
                ExtractedEvent(date: "2026-02-01", title: "Reply filed"),
                ExtractedEvent(date: "June 2026", title: "Undated"),
            ])
            fake.failingSaves = [2]
            await model.start()
            XCTAssertEqual(model.countLine, "4 found · 3 ticked")
            await model.acceptProposals()
            XCTAssertEqual(fake.saved.count, 3, "the failure did not stop the rest")
            XCTAssertEqual(fake.saved[0], UpdateDraft(kind: "filing", title: "Plaint filed", body: "Before the Commercial Court",
                                                      eventDate: "2026-01-01", source: "ai", sourceRef: "Plaint.pdf, p. 1"))
            XCTAssertEqual(fake.saved[1].kind, "event")
            XCTAssertNil(fake.saved[1].sourceRef)
            XCTAssertEqual(model.progress.done, 3)
            XCTAssertEqual(model.phase, .done)
            XCTAssertTrue(model.summaryIsError)
            XCTAssertEqual(model.summary, "2 added; 1 could not be saved — kind must be one of ….")
            XCTAssertEqual(reloads(), 1)
        }
    }

    func testAllSavedSaysHowMany() async {
        await withBuild { fake, model, _ in
            fake.extraction = ChronologyExtraction(events: [ExtractedEvent(date: "2026-01-01", title: "Filed")])
            await model.start()
            await model.acceptProposals()
            XCTAssertEqual(model.summary, "1 event added to the chronology")
            XCTAssertFalse(model.summaryIsError)
        }
    }

    func testUntickingLeavesNothingToAdd() async {
        await withBuild { fake, model, _ in
            fake.extraction = ChronologyExtraction(events: [ExtractedEvent(date: "2026-01-01", title: "Filed"),
                                                            ExtractedEvent(date: "x", title: "Undated")])
            await model.start()
            model.untickAll()
            XCTAssertTrue(model.picked.isEmpty)
            await model.acceptProposals()
            XCTAssertTrue(fake.saved.isEmpty)
            XCTAssertEqual(model.phase, .review)
            model.tickAll()
            XCTAssertEqual(model.picked.count, 1, "the undated one cannot be ticked")
            model.setOn(model.proposals[1], true)
            XCTAssertEqual(model.picked.count, 1)
        }
    }

    func testTheRecordedChronologyMarksDuplicates() async {
        let recorded = ProjectUpdate(id: "u1", kind: "filing", title: "Plaint filed before the court", eventDateRaw: "2026-01-01")
        await withBuild(updates: [recorded]) { fake, model, _ in
            fake.extraction = ChronologyExtraction(events: [ExtractedEvent(date: "2026-01-01", title: "Plaint filed before the court")])
            await model.start()
            XCTAssertTrue(model.proposals[0].isDuplicate)
            XCTAssertTrue(model.picked.isEmpty)
        }
    }

    /// The sheet was closed while reading: the late answer opens no review.
    func testAnAbandonedReadDoesNotOpenAReview() async {
        await withBuild { fake, model, _ in
            fake.extraction = ChronologyExtraction(events: [ExtractedEvent(date: "2026-01-01", title: "Filed")])
            fake.extractDelay = .milliseconds(80)
            let reading = Task { await model.start() }
            for _ in 0..<200 where model.phase != .reading { await Task.yield() }
            XCTAssertEqual(model.phase, .reading)
            model.abandon()
            await reading.value
            XCTAssertEqual(model.phase, .pick)
            XCTAssertTrue(model.proposals.isEmpty)
        }
    }
}

// MARK: - Drafts

final class MatterDraftsTests: XCTestCase {

    func testAMattersDraftsMergeDocumentsAndTablesNewestFirst() async {
        await runMatterDraftsMerge()
    }

    func testOneHalfFailingStillShowsTheOther() async {
        await runMatterDraftsPartial()
    }

    func testTheGeneralListIsUnchanged() async {
        await runGeneralDrafts()
    }
}

@MainActor
private func runMatterDraftsMerge() async {
    let fake = FakeMatterDrafts()
    fake.documents = [
        draft("d1", project: "prj_1", created: "2026-10-10 09:00:00"),
        draft("d2", project: "prj_other", created: "2026-10-18 09:00:00"),
        draft("d3", project: nil, created: "2026-10-18 09:00:00"),
        draft("d4", project: "prj_1", created: "2026-10-17T09:00:00.000Z"),
    ]
    fake.tables = [draft("t1", project: "prj_1", created: "2026-10-12 09:00:00", type: nil),
                   draft("d1", project: "prj_1", created: "2026-10-10 09:00:00")]
    let model = DraftHistoryViewModel(service: fake, projectID: "prj_1")
    XCTAssertTrue(model.isMatterScoped)
    await model.load()
    XCTAssertEqual(model.items.map(\.id), ["d4", "t1", "d1"])
    XCTAssertEqual(model.items[1].type, "table")
    XCTAssertEqual(Set(fake.asked.map(\.kind)), [.document, .table])
    XCTAssertTrue(fake.asked.allSatisfy { $0.projectID == "prj_1" })
    XCTAssertNil(model.partialNotice)
}

@MainActor
private func runMatterDraftsPartial() async {
    let fake = FakeMatterDrafts()
    fake.documents = [draft("d1", project: "prj_1", created: "2026-10-10 09:00:00")]
    fake.tablesError = Refused()
    let model = DraftHistoryViewModel(service: fake, projectID: "prj_1")
    await model.load()
    XCTAssertEqual(model.items.map(\.id), ["d1"])
    XCTAssertEqual(model.partialNotice, "Tables could not be loaded.")
    XCTAssertEqual(model.state, .loaded)

    fake.documentsError = Refused()
    await model.load()
    XCTAssertNotNil(model.state.failure)
}

@MainActor
private func runGeneralDrafts() async {
    let fake = FakeMatterDrafts()
    fake.documents = [draft("d1", project: "prj_1", created: "2026-10-10 09:00:00"),
                      draft("d2", project: nil, created: "2026-10-10 09:00:00")]
    let model = DraftHistoryViewModel(service: fake)
    await model.load()
    XCTAssertEqual(model.items.map(\.id), ["d2"])
    XCTAssertEqual(fake.asked.map(\.kind), [.document])
}

// MARK: - Banner

final class MatterBannerTests: XCTestCase {

    func testThePresetFallsBackByFolderColourThenNavy() {
        XCTAssertEqual(BannerPreset.preset(for: matter(banner: "wine")), .wine)
        XCTAssertEqual(BannerPreset.preset(for: matter(banner: "image", color: "amber")), .gold)
        XCTAssertEqual(BannerPreset.preset(for: matter(color: "violet")), .indigo)
        XCTAssertEqual(BannerPreset.preset(for: matter(color: "sky")), .navy)
        XCTAssertEqual(BannerPreset.preset(for: matter(banner: "image")), .navy)
        XCTAssertEqual(BannerPreset.preset(for: matter(color: "chartreuse")), .navy)
        XCTAssertEqual(BannerPreset.preset(for: nil), .navy)
        XCTAssertTrue(matter(banner: "image").hasBannerImage)
        XCTAssertFalse(matter(banner: "teal").hasBannerImage)
    }

    func testEveryPresetHasTwoColours() {
        XCTAssertEqual(BannerPreset.allCases.map(\.rawValue), ["navy", "slate", "indigo", "teal", "forest", "wine", "gold", "sand"])
        XCTAssertEqual(BannerPreset.gold.hexColors.from, "#6A4C14")
        for preset in BannerPreset.allCases {
            XCTAssertNotNil(BannerPreset.components(preset.hexColors.from))
            XCTAssertNotNil(BannerPreset.components(preset.hexColors.to))
        }
        let navy = BannerPreset.components("#252A47")
        XCTAssertEqual(navy?.red ?? 0, Double(0x25) / 255, accuracy: 0.0001)
        XCTAssertNil(BannerPreset.components("#12345"))
    }

    /// Refused before the upload, with the size in the sentence.
    func testAPictureOverTwoMegabytesIsRefusedHere() {
        XCTAssertThrowsError(try BannerImage.dataURL(data: Data(count: BannerImage.maxBytes + 1), mime: "image/jpeg")) { error in
            XCTAssertEqual(DisplayText.message(for: error), "That image is 2.0 MB — a banner can be up to 2 MB.")
        }
        XCTAssertThrowsError(try BannerImage.dataURL(data: Data([1]), mime: "image/gif"))
        XCTAssertThrowsError(try BannerImage.dataURL(data: Data(), mime: "image/png"))
        let url = try? BannerImage.dataURL(data: Data([0xFF, 0xD8]), mime: "image/jpg")
        XCTAssertEqual(url, "data:image/jpeg;base64,/9g=")
        XCTAssertNoThrow(try BannerImage.dataURL(data: Data(count: BannerImage.maxBytes), mime: "image/png"))
    }

    func testThePictureIsFetchedOnlyWhenThereIsOneAndOncePerVersion() async {
        await withWorkspace { fake, model in
            await model.load()
            await model.loadBanner()
            XCTAssertEqual(fake.bannerFetches, 0, "a preset banner has no picture to fetch")

            fake.detail = detail(matter(banner: "image"))
            await model.load()
            await model.loadBanner()
            await model.loadBanner()
            XCTAssertEqual(fake.bannerFetches, 1)
            XCTAssertNotNil(model.bannerImage)

            fake.detail = detail(matter(banner: "image", updatedAt: "2026-10-19 06:30:00"))
            await model.load()
            await model.loadBanner()
            XCTAssertEqual(fake.bannerFetches, 2, "the matter changed, so the picture may have")
        }
    }

    func testUploadingAndRemovingReloadTheMatter() async {
        await withWorkspace { fake, model in
            fake.detail = detail(matter(banner: "image"))
            await model.load()
            let ok = await model.uploadBanner(data: Data([0xFF, 0xD8]), mime: "image/jpeg")
            XCTAssertTrue(ok)
            XCTAssertEqual(fake.uploads, ["data:image/jpeg;base64,/9g="])
            XCTAssertEqual(fake.loads, 2)
            XCTAssertEqual(fake.bannerFetches, 1)

            let removed = await model.removeBanner()
            XCTAssertTrue(removed)
            XCTAssertEqual(fake.bannerDeletes, 1)

            let tooBig = await model.uploadBanner(data: Data(count: BannerImage.maxBytes + 1), mime: "image/jpeg")
            XCTAssertFalse(tooBig)
            XCTAssertEqual(fake.uploads.count, 1)
            XCTAssertNotNil(model.writeError)
        }
    }
}

// MARK: - Deleting

final class MatterDeleteTests: XCTestCase {

    func testAMismatchedNameIsRefusedWithoutARequest() async {
        await withWorkspace { fake, model in
            await model.load()
            let deleted = await model.deleteMatter(confirmName: "Helios v Northgrid")
            XCTAssertFalse(deleted)
            XCTAssertTrue(fake.deletes.isEmpty)
            XCTAssertNotNil(model.deleteError)
            XCTAssertFalse(model.deleteConfirmationMatches(""))
            XCTAssertFalse(model.deleteConfirmationMatches("helios v. northgrid"))
        }
    }

    /// Surrounding spaces are forgiven; the server is sent the stored name.
    func testTheExactNameDeletesWithTheStoredName() async {
        await withWorkspace { fake, model in
            await model.load()
            let deleted = await model.deleteMatter(confirmName: "  Helios v. Northgrid ")
            XCTAssertTrue(deleted)
            XCTAssertEqual(fake.deletes.first?.id, "prj_1")
            XCTAssertEqual(fake.deletes.first?.confirm, "Helios v. Northgrid")
        }
    }

    func testAServerRefusalIsShown() async {
        await withWorkspace { fake, model in
            await model.load()
            fake.deleteError = APIError.server(status: 400, message: "To delete this project, send confirm= with its exact name")
            let deleted = await model.deleteMatter(confirmName: "Helios v. Northgrid")
            XCTAssertFalse(deleted)
            XCTAssertNotNil(model.deleteError)
            XCTAssertEqual(model.deleteConsequences.count, 3)
        }
    }
}

// MARK: - The wire

final class MatterParityWireTests: XCTestCase {

    private static let config = APIConfig(baseURL: URL(string: "https://example.test/api")!)

    override func setUp() { super.setUp(); HTTPStub.reset() }
    override func tearDown() { HTTPStub.reset(); super.tearDown() }

    private func client() async -> APIClient {
        let client = APIClient(config: Self.config, session: HTTPStub.session())
        await client.setCredentials(Credentials(token: "tok-abc", userID: 42))
        return client
    }

    private func body(_ request: URLRequest?) throws -> [String: Any] {
        let data = try XCTUnwrap(request?.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func query(_ request: URLRequest?) -> [String: String] {
        let items = request?.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    func testAttachingAConversationPostsTheMatterAndTheChat() async throws {
        let service = ProjectService(client: await client())
        HTTPStub.always(.json(#"{"success":true,"attached":true,"created":true}"#))
        try await service.attachChat(projectID: "prj_1", chatID: "c1", attached: true)
        let request = HTTPStub.lastRequest
        XCTAssertEqual(request?.httpMethod, "POST")
        XCTAssertEqual(request?.url?.path, "/api/project-chat")
        let sent = try body(request)
        XCTAssertEqual(Set(sent.keys), ["userId", "projectId", "chatId", "attached"])
        XCTAssertEqual(sent["attached"] as? Bool, true)
        XCTAssertEqual(sent["chatId"] as? String, "c1")
    }

    func testReadingTheChronologyNamesFilesOnlyWhenChosen() async throws {
        let service = ProjectService(client: await client())
        HTTPStub.always(.json(#"{"success":true,"events":[{"date":"2026-01-01","title":"Filed","details":"","kind":"filing","sourceRef":"Plaint.pdf, p. 1"}],"files":1,"skipped":[],"partial":false}"#))
        let all = try await service.extractChronology(projectID: "prj_1", files: nil)
        XCTAssertEqual(all.events.first?.sourceRef, "Plaint.pdf, p. 1")
        XCTAssertEqual(all.files, 1)
        XCTAssertEqual(HTTPStub.lastRequest?.url?.path, "/api/project-chronology-extract")
        XCTAssertEqual(Set(try body(HTTPStub.lastRequest).keys), ["userId", "projectId"])
        XCTAssertGreaterThanOrEqual(HTTPStub.lastRequest?.timeoutInterval ?? 0, 360)

        _ = try await service.extractChronology(
            projectID: "prj_1", files: [ChatAttachment(name: "Plaint.pdf", folderName: "_projects/prj_1/Pleadings")])
        let files = try XCTUnwrap(try body(HTTPStub.lastRequest)["files"] as? [[String: String]])
        XCTAssertEqual(files, [["folderName": "_projects/prj_1/Pleadings", "fileName": "Plaint.pdf"]])
    }

    func testAPlanRefusalOnTheChronologyIsARefusal() async {
        let service = ProjectService(client: await client())
        HTTPStub.always(.json(#"{"success":false,"error":"This month's chat queries are used up.","code":"QUERY_LIMIT"}"#, status: 402))
        do {
            _ = try await service.extractChronology(projectID: "prj_1", files: nil)
            XCTFail("expected a refusal")
        } catch let error as APIError {
            XCTAssertEqual(error.refusal?.code, .queryLimit)
        } catch { XCTFail("\(error)") }
    }

    func testTheBannerIsFetchedByIdAndAMissingOneIsNil() async throws {
        let service = ProjectService(client: await client())
        HTTPStub.always(Reply(status: 200, body: Data([0xFF, 0xD8, 0xFF]), headers: ["Content-Type": "image/jpeg"]))
        let bytes = try await service.bannerImage(projectID: "prj_1")
        XCTAssertEqual(bytes, Data([0xFF, 0xD8, 0xFF]))
        XCTAssertEqual(HTTPStub.lastRequest?.httpMethod, "GET")
        XCTAssertEqual(HTTPStub.lastRequest?.url?.path, "/api/project-banner")
        XCTAssertEqual(query(HTTPStub.lastRequest), ["id": "prj_1", "userId": "42"])

        HTTPStub.always(.json(#"{"success":false,"error":"This project has no banner image"}"#, status: 404))
        let missing = try await service.bannerImage(projectID: "prj_1")
        XCTAssertNil(missing)
    }

    func testUploadingABannerPostsTheDataURL() async throws {
        let service = ProjectService(client: await client())
        HTTPStub.always(.json(#"{"success":true,"banner":"image"}"#))
        try await service.uploadBanner(projectID: "prj_1", dataURL: "data:image/jpeg;base64,/9g=")
        XCTAssertEqual(HTTPStub.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(HTTPStub.lastRequest?.url?.path, "/api/project-banner")
        let sent = try body(HTTPStub.lastRequest)
        XCTAssertEqual(Set(sent.keys), ["userId", "projectId", "dataUrl"])
        XCTAssertEqual(sent["dataUrl"] as? String, "data:image/jpeg;base64,/9g=")
    }

    func testRemovingABannerDeletesByTheMattersId() async throws {
        let service = ProjectService(client: await client())
        HTTPStub.always(.json(#"{"success":true}"#))
        try await service.deleteBanner(projectID: "prj_1")
        XCTAssertEqual(HTTPStub.lastRequest?.httpMethod, "DELETE")
        XCTAssertEqual(HTTPStub.lastRequest?.url?.path, "/api/project-banner")
        XCTAssertEqual(query(HTTPStub.lastRequest), ["id": "prj_1", "userId": "42"])
    }

    func testDeletingAMatterSendsItsName() async throws {
        let service = ProjectService(client: await client())
        HTTPStub.always(.json(#"{"success":true}"#))
        try await service.deleteProject(id: "prj_1", confirm: "Helios v. Northgrid")
        XCTAssertEqual(HTTPStub.lastRequest?.httpMethod, "DELETE")
        XCTAssertEqual(HTTPStub.lastRequest?.url?.path, "/api/project")
        XCTAssertEqual(query(HTTPStub.lastRequest), ["id": "prj_1", "confirm": "Helios v. Northgrid", "userId": "42"])

        HTTPStub.always(.json(#"{"success":false,"error":"To delete this project, send confirm= with its exact name"}"#, status: 400))
        do {
            try await service.deleteProject(id: "prj_1", confirm: "x")
            XCTFail("expected a refusal")
        } catch {}
    }

    func testAnAcceptedEventIsSavedAsTheAIsWithItsPage() async throws {
        let service = ProjectService(client: await client())
        HTTPStub.always(.json(#"{"success":true,"id":"u9"}"#))
        let id = try await service.saveUpdate(
            projectID: "prj_1", id: nil,
            draft: UpdateDraft(kind: "filing", title: "Plaint filed", eventDate: "2026-01-01", source: "ai", sourceRef: "Plaint.pdf, p. 1"))
        XCTAssertEqual(id, "u9")
        let sent = try body(HTTPStub.lastRequest)
        XCTAssertEqual(sent["source"] as? String, "ai")
        XCTAssertEqual(sent["sourceRef"] as? String, "Plaint.pdf, p. 1")

        _ = try await service.saveUpdate(projectID: "prj_1", id: nil, draft: UpdateDraft(kind: "note", title: "Called client"))
        let typed = try body(HTTPStub.lastRequest)
        XCTAssertEqual(typed["source"] as? String, "manual")
        XCTAssertNil(typed["sourceRef"])
    }

    func testAMattersDraftsAreAskedForByTheMatter() async throws {
        let service = DraftHistoryService(client: await client())
        HTTPStub.always(.json(#"{"success":true,"documents":[{"id":"t1","type":"table","project_id":"prj_1","created_at":"2026-10-10 09:00:00"}],"tables":[]}"#))
        _ = try await service.drafts(.table, projectID: "prj_1")
        XCTAssertEqual(HTTPStub.lastRequest?.url?.path, "/api/tables")
        XCTAssertEqual(query(HTTPStub.lastRequest), ["projectId": "prj_1", "userId": "42"])
        _ = try await service.drafts(.document, projectID: "prj_1")
        XCTAssertEqual(HTTPStub.lastRequest?.url?.path, "/api/documents")
        XCTAssertEqual(query(HTTPStub.lastRequest)["projectId"], "prj_1")
        _ = try await service.drafts(.document)
        XCTAssertNil(query(HTTPStub.lastRequest)["projectId"])
    }
}

private typealias Reply = HTTPStub.Reply
