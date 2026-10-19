import Foundation
#if canImport(Darwin)
import Observation
#endif

/// One matter's workspace: where things stand, what is set up, and the sections the web's
/// Matters page has — chronology, the court record, tasks, fees, people, files.
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class ProjectDetailViewModel {

    let projectID: String

    private(set) var detail: ProjectDetail?
    private(set) var state: LoadState = .idle

    /// The matter's own documents, listed separately (`/project-files`): `nil` until asked.
    private(set) var files: [FileNode]?
    private(set) var filesState: LoadState = .idle

    /// Set while a write is in flight, so the screen offers one at a time.
    private(set) var isWriting = false
    /// Why the last write failed, in the server's or this client's words. Cleared by the next.
    var writeError: String?
    /// What the last attach did, line by line — including the documents it skipped and why.
    var attachReport: [AttachedFile]?
    /// A line worth saying once: "The court was asked recently…".
    var notice: String?

    private let service: any ProjectProviding
    private let todayKey: () -> String

    init(
        projectID: String,
        service: any ProjectProviding,
        todayKey: @escaping () -> String = { WireDate.todayKey() }
    ) {
        self.projectID = projectID
        self.service = service
        self.todayKey = todayKey
    }

    var project: Project? { detail?.project }

    var presentation: ListPresentation {
        ListPresentation(state: state, isEmpty: detail == nil)
    }

    var title: String { project?.displayName ?? "Matter" }

    // MARK: - Sections

    /// The workspace's sections, in the web's order less the two this client does not open
    /// here (Ask and Drafts — a matter's conversations are scoped to it, see
    /// `ChatListViewModel.ownConversations`).
    enum Section: String, CaseIterable, Identifiable, Sendable {
        case overview, chronology, court, tasks, fees, people, files
        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview: return "Overview"
            case .chronology: return "Chronology"
            case .court: return "Court"
            case .tasks: return "Tasks"
            case .fees: return "Fees"
            case .people: return "People"
            case .files: return "Files"
            }
        }
    }

    var section: Section = .overview

    // MARK: - The two records

    // These are kept as **two sections, not one interleaved chronology**, and that is the single
    // decision on this screen worth arguing about.
    //
    // The server merges both into one response precisely so a client *can* interleave, and the
    // web does — `courtHistory` and `updates` are concatenated and sorted by date into a single
    // timeline. Android split them, and this follows Android.
    //
    // The reason is that the merged view reads as one chronology when it is two. A project update
    // is something the user typed: it can be wrong, backdated, or a note-to-self. A court-history
    // row was scraped from a registry and is a fact about the record. Interleaved, they share a
    // rule and a spine and a date column, and the eye stops distinguishing them within about
    // three rows — at which point "order received, uploaded to counsel" and "Order dated
    // 12.08.2026" carry the same weight. They do not. One is evidence of what the court did; the
    // other is evidence of what the user believed.
    //
    // Two headings cost one extra scroll and make the provenance unmissable, and provenance is
    // the thing this screen is read for.

    /// The matter's own timeline, newest first — already sorted and filtered by the server and
    /// `ProjectService` respectively.
    var updates: [ProjectUpdate] { detail?.updates ?? [] }

    /// The linked case's scraped rows. Empty when nothing is linked.
    var courtHistory: [CaseItem] { detail?.courtHistory ?? [] }

    var linkedCase: LinkedCaseSummary? { detail?.linkedCase }

    /// Whether this matter is joined to a case the court scrapers maintain.
    ///
    /// Not the same question as `courtHistory.isEmpty`: a link can be set to a case that has no
    /// items yet, or to one the sync has since deleted. Saying "linked, nothing on the record
    /// yet" is honest where showing nothing at all invites the reader to conclude the link
    /// failed.
    var isLinkedToCase: Bool { project?.hasLinkedCase ?? false }

    /// The line under the court-record heading, when there is a link but no rows behind it.
    var courtRecordCaveat: String? {
        guard isLinkedToCase, courtHistory.isEmpty else { return nil }
        return """
            This matter is linked to a case on your docket, but nothing has been synced from the \
            court for it yet.
            """
    }

    /// "Synced from the court 2 hours ago", for the Court section's head.
    var courtSyncLine: String? {
        guard isLinkedToCase else { return nil }
        guard let synced = linkedCase?.lastSyncedAt else { return "Not synced from the court yet." }
        return "Synced from the court \(DisplayText.relative(synced).lowercased())."
    }

    // MARK: - Tasks

    var tasks: [ProjectTask] { detail?.tasks ?? [] }
    /// Open first, soonest due first — the server's order, kept.
    var openTasks: [ProjectTask] { tasks.filter { !$0.isDone } }
    var doneTasks: [ProjectTask] { tasks.filter(\.isDone) }
    var overdueTasks: [ProjectTask] { openTasks.filter { $0.isOverdue(todayKey: todayKey()) } }

    /// The To do tile: "3 open · 1 overdue", "Nothing to do".
    var tasksSummary: String {
        let open = openTasks.count
        guard open > 0 else { return "Nothing to do" }
        var line = open == 1 ? "1 open" : "\(open) open"
        let overdue = overdueTasks.count
        if overdue > 0 { line += " · \(overdue) overdue" }
        return line
    }

    /// "Due today", "Due tomorrow", "Due Mon 12 Oct", "Overdue since 3 Oct".
    func dueLabel(for task: ProjectTask) -> String? {
        guard let due = task.dueDateRaw, !due.isEmpty else { return nil }
        let today = todayKey()
        if task.isDone { return "Was due \(MattersOverview.shortDay(due))" }
        if due < today { return "Overdue since \(MattersOverview.shortDay(due))" }
        let label = MattersOverview(listings: [], todayKey: today).dayLabel(due)
        // "Due today", "Due tomorrow", "Due Mon 12 Oct".
        return "Due \(label == "Today" || label == "Tomorrow" ? label.lowercased() : label)"
    }

    // MARK: - Money

    var ledger: [LedgerEntry] { detail?.ledger ?? [] }
    var totals: LedgerTotals { detail?.totals ?? .zero }

    /// The Fees tile: "₹40,000 of ₹1,00,000 received", "Nothing billed yet".
    var feesSummary: String {
        let billed = totals.billed ?? 0
        guard billed > 0 else {
            let expenses = totals.expenses ?? 0
            return expenses > 0 ? "\(MatterMoney.inr(expenses)) spent" : "Nothing billed yet"
        }
        return "\(MatterMoney.inr(totals.received ?? 0)) of \(MatterMoney.inr(billed)) received"
    }

    /// The four figures the Fees section heads with, in order, skipping zero expenses.
    var moneyFacts: [Fact] {
        var facts = [
            Fact(label: "Billed", value: MatterMoney.inr(totals.billed ?? 0)),
            Fact(label: "Received", value: MatterMoney.inr(totals.received ?? 0)),
            Fact(label: "Outstanding", value: MatterMoney.inr(totals.outstanding ?? 0),
                 isEmphasised: (totals.outstanding ?? 0) > 0),
        ]
        if (totals.expenses ?? 0) > 0 {
            facts.append(Fact(label: "Expenses", value: MatterMoney.inr(totals.expenses ?? 0)))
        }
        return facts
    }

    /// Signed for the row: a payment comes in, the rest goes out.
    func amountLabel(for entry: LedgerEntry) -> String {
        let figure = MatterMoney.inr(entry.rupees)
        switch entry.entryKind {
        case .payment: return "+\(figure)"
        case .expense: return "−\(figure)"
        default: return figure
        }
    }

    // MARK: - People

    var people: [ProjectPerson] { detail?.people ?? [] }

    /// People under their roles, in the server's role order.
    var peopleByRole: [(role: String, people: [ProjectPerson])] {
        var order: [String] = []
        var groups: [String: [ProjectPerson]] = [:]
        for person in people {
            let role = person.roleLabel
            if groups[role] == nil { order.append(role) }
            groups[role, default: []].append(person)
        }
        return order.map { (role: $0, people: groups[$0] ?? []) }
    }

    // MARK: - Files

    /// Every document in the matter, flattened, for the Files section and the setup count.
    var allFiles: [FileNode.StoredFile] { FileService.allFiles(in: files ?? []) }

    /// The matter's folders, in the order the server lists them.
    var folders: [FileNode.Folder] {
        (files ?? []).compactMap { if case .folder(let f) = $0 { return f } else { return nil } }
    }

    /// Loose files at the matter's root — rare; the web attaches into a folder.
    var looseFiles: [FileNode.StoredFile] {
        (files ?? []).compactMap { if case .file(let f) = $0 { return f } else { return nil } }
    }

    var filesPresentation: ListPresentation {
        ListPresentation(state: filesState, isEmpty: allFiles.isEmpty)
    }

    /// The count the setup strip reads: the listing's, else the list route's, else unknown.
    var knownFileCount: Int? {
        if files != nil { return allFiles.count }
        return project?.fileCount
    }

    /// Where an attach may go: the five standard folders first, then any other folder the matter
    /// already has.
    var attachDestinations: [String] {
        let standard = MatterVocabulary.standardFolders
        let others = folders.map(\.name).filter { !standard.contains($0) }
        return standard + others
    }

    // MARK: - Overview

    /// The setup strip — `nil` once everything is done, because a finished strip is noise.
    var setup: MatterSetup? {
        guard let project else { return nil }
        let setup = MatterSetup(project: project, people: people, fileCount: knownFileCount)
        return setup.isComplete ? nil : setup
    }

    /// The next hearing's day in India: the matter's own date, else the linked case's.
    var nextHearingKey: String? {
        let candidates = [project?.nextHearingDateRaw, linkedCase?.nextHearingDateRaw]
            .compactMap { WireDate.parseDay($0) }
            .map(WireDate.dayKey)
            .filter { $0 >= todayKey() }
        return candidates.min()
    }

    /// The latest hearing already held, from the court record, else from the chronology.
    var lastHearingKey: String? {
        let today = todayKey()
        let fromCourt = courtHistory
            .filter { $0.section == CaseSection.hearings.rawValue }
            .compactMap(\.itemDate).map(WireDate.dayKey)
        let fromUpdates = updates
            .filter { $0.kind?.lowercased() == "hearing" }
            .compactMap(\.day).map(WireDate.dayKey)
        return (fromCourt + fromUpdates).filter { $0 < today }.max()
    }

    /// Where things stand, in one sentence.
    var standing: MatterStanding? {
        guard let project else { return nil }
        return MatterStanding(
            project: project, linkedCase: linkedCase,
            nextHearingKey: nextHearingKey, lastHearingKey: lastHearingKey, todayKey: todayKey())
    }

    /// The latest order on the record, for the Overview tile.
    var latestOrder: CaseItem? {
        courtHistory.first { $0.section == CaseSection.orders.rawValue }
    }

    /// The facts panel, as label/value pairs, skipping everything the matter does not state.
    ///
    /// Assembled here rather than in the view so the "which fields, in which order, and which is
    /// emphasised" decision is testable — it is the part of this screen most likely to be edited
    /// by someone who cannot run it.
    var facts: [Fact] {
        guard let project else { return [] }
        var facts: [Fact] = []
        func add(_ label: String, _ value: String?, emphasised: Bool = false) {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else { return }
            facts.append(Fact(label: label, value: trimmed, isEmphasised: emphasised))
        }
        add("Client", project.client)
        add("Your side", project.ourSideLabel)
        add("Opposite party", project.oppositeParty)
        add("Case", project.caseReference ?? linkedCase.flatMap(Self.caseReference))
        add("Forum", project.forumLabel ?? linkedCase?.courtName)
        add("Practice area", project.practiceAreaLabel)
        add("Stage", project.stage ?? linkedCase?.stage)
        // The stored date, whatever today is — a fact the matter states. Whether it is still
        // ahead is `standing`'s question, not this panel's.
        if let hearing = project.nextHearingDate ?? linkedCase?.nextHearingDate {
            add("Next hearing", DisplayText.longDay(WireDate.dayKey(hearing)), emphasised: true)
        }
        if let filed = project.filingDate {
            add("Filed", DisplayText.longDay(WireDate.dayKey(filed)))
        }
        // "Active" is the default and says nothing; anything else is the reason a matter looks
        // the way it does and must be visible from inside it.
        if let status = project.statusLabel, status != "Active" { add("Status", status) }
        if project.isNotFiledYet { add("Court", "Not filed yet") }
        add("Notes", project.notes)
        return facts
    }

    private static func caseReference(_ linked: LinkedCaseSummary) -> String? {
        let number: String
        switch (linked.caseNumber?.nilIfEmpty, linked.caseYear?.nilIfEmpty, linked.cnr?.nilIfEmpty) {
        case (let n?, let y?, _): number = "\(n)/\(y)"
        case (let n?, nil, _): number = n
        case (nil, _, let cnr?): number = cnr
        default: return nil
        }
        guard let type = linked.caseType?.nilIfEmpty else { return number }
        return "\(type) \(number)"
    }

    struct Fact: Identifiable, Equatable, Sendable {
        let label: String
        let value: String
        var isEmphasised = false
        var id: String { label }
    }

    // MARK: - Loading

    func load() async {
        state = .loading
        do {
            detail = try await service.project(id: projectID)
            state = .loaded
        } catch {
            state = .failed(LoadFailure(error))
        }
    }

    /// Lists the matter's documents. Separate from `load()` because it is a storage walk the
    /// Overview does not need, and the Files section does.
    func loadFiles() async {
        filesState = .loading
        do {
            files = try await service.projectFiles(projectID: projectID)
            filesState = .loaded
        } catch {
            filesState = .failed(LoadFailure(error))
        }
    }

    // MARK: - Writes

    /// Runs one write, then re-reads the matter so every section — the totals, the setup strip,
    /// the next date — agrees with the server rather than with a local patch.
    private func write(_ action: () async throws -> Void) async -> Bool {
        guard !isWriting else { return false }
        isWriting = true
        writeError = nil
        defer { isWriting = false }
        do {
            try await action()
            await load()
            return true
        } catch {
            writeError = DisplayText.message(for: error)
            return false
        }
    }

    @discardableResult
    func addTask(_ draft: TaskDraft) async -> Bool {
        await write { _ = try await service.saveTask(projectID: projectID, id: nil, draft: draft) }
    }

    /// Ticks a task off, or reopens it. Sends only the status: the route keeps every field it is
    /// not sent, so the title and the date survive.
    @discardableResult
    func setDone(_ task: ProjectTask, _ done: Bool) async -> Bool {
        await write {
            _ = try await service.saveTask(
                projectID: projectID, id: task.id,
                draft: TaskDraft(title: task.displayTitle, status: done ? "done" : "open"))
        }
    }

    @discardableResult
    func deleteTask(_ task: ProjectTask) async -> Bool {
        await write { try await service.deleteTask(id: task.id) }
    }

    @discardableResult
    func addLedgerEntry(_ draft: LedgerDraft) async -> Bool {
        guard draft.amount > 0 else {
            writeError = "Enter an amount."
            return false
        }
        return await write { _ = try await service.saveLedgerEntry(projectID: projectID, id: nil, draft: draft) }
    }

    @discardableResult
    func deleteLedgerEntry(_ entry: LedgerEntry) async -> Bool {
        await write { try await service.deleteLedgerEntry(id: entry.id) }
    }

    @discardableResult
    func addPerson(_ draft: PersonDraft) async -> Bool {
        await write { _ = try await service.savePerson(projectID: projectID, id: nil, draft: draft) }
    }

    @discardableResult
    func deletePerson(_ person: ProjectPerson) async -> Bool {
        await write { try await service.deletePerson(id: person.id) }
    }

    @discardableResult
    func addUpdate(_ draft: UpdateDraft) async -> Bool {
        await write { _ = try await service.saveUpdate(projectID: projectID, id: nil, draft: draft) }
    }

    @discardableResult
    func deleteUpdate(_ update: ProjectUpdate) async -> Bool {
        await write { try await service.deleteUpdate(id: update.id) }
    }

    /// Sets one of the matter's own facts — the setup strip's chips do this.
    @discardableResult
    func setField(_ key: String, _ value: String) async -> Bool {
        await write { _ = try await service.patch(projectID: projectID, fields: [key: .string(value)]) }
    }

    /// Copies documents from My Files into the matter, then lists the matter's files again. The
    /// report says what happened to each, because a skip is silent otherwise.
    @discardableResult
    func attach(_ files: [ChatAttachment], into subfolder: String?) async -> Bool {
        guard !files.isEmpty else { return false }
        let ok = await write {
            attachReport = try await service.attach(projectID: projectID, files: files, subfolder: subfolder)
        }
        if ok { await loadFiles() }
        return ok
    }

    /// The attach report in one line: "2 attached · 1 skipped".
    var attachSummary: String? {
        guard let attachReport else { return nil }
        let attached = attachReport.filter(\.wasAttached).count
        let skipped = attachReport.count - attached
        var parts = [attached == 1 ? "1 attached" : "\(attached) attached"]
        if skipped > 0 { parts.append(skipped == 1 ? "1 skipped" : "\(skipped) skipped") }
        return parts.joined(separator: " · ")
    }

    /// Asks the court again. A 429's wording lands in `notice`, not `writeError`: being asked to
    /// wait is not a failure.
    func refreshFromCourt() async {
        guard !isWriting else { return }
        isWriting = true
        writeError = nil
        notice = nil
        defer { isWriting = false }
        do {
            try await service.refreshLinkedCase(projectID: projectID)
            await load()
            notice = "Asked the court. The record below is what it holds now."
        } catch let error as APIError {
            if case .server(429, let message) = error { notice = message } else {
                writeError = DisplayText.message(for: error)
            }
        } catch {
            writeError = DisplayText.message(for: error)
        }
    }

    /// Links a tracked case, or unlinks the current one.
    @discardableResult
    func link(caseID: String?) async -> Bool {
        await write { _ = try await service.linkCase(projectID: projectID, caseID: caseID) }
    }
}
