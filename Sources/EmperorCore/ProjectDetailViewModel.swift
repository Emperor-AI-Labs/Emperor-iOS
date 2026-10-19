import Foundation
#if canImport(Darwin)
import Observation
#endif

/// One matter's workspace: where things stand, what is set up, and the sections the web's
/// Matters page has — its conversations, files, drafts, chronology, the court record, tasks,
/// fees and people.
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
    /// Rename and delete for the matter's own documents — the routes My Files uses, addressed by
    /// the matter's folder. Without it neither is offered.
    private let fileManager: (any FileManaging)?

    init(
        projectID: String,
        service: any ProjectProviding,
        todayKey: @escaping () -> String = { WireDate.todayKey() },
        fileManager: (any FileManaging)? = nil
    ) {
        self.projectID = projectID
        self.service = service
        self.todayKey = todayKey
        self.fileManager = fileManager
    }

    var project: Project? { detail?.project }

    var presentation: ListPresentation {
        ListPresentation(state: state, isEmpty: detail == nil)
    }

    var title: String { project?.displayName ?? "Matter" }

    // MARK: - Sections

    /// The workspace's sections, in the web's order (`SECTIONS` in the web's projects API).
    enum Section: String, CaseIterable, Identifiable, Sendable {
        case overview, ask, files, drafts, chronology, court, tasks, fees, people
        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview: return "Overview"
            case .ask: return "Ask Emperor"
            case .files: return "Files"
            case .drafts: return "Drafts"
            case .chronology: return "Chronology"
            case .court: return "Court"
            case .tasks: return "Tasks"
            case .fees: return "Fees"
            case .people: return "People"
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

    // MARK: - Ask Emperor

    /// The matter's conversations, newest first.
    var chats: [ProjectChatRow] { ProjectChatRow.newestFirst(detail?.chats ?? []) }

    /// An id for a new conversation in this matter — the same scheme every new conversation in
    /// the app uses, so the first turn creates it under the matter.
    nonisolated static func newConversationID() -> String { ChatListViewModel.newChatID() }

    /// The documents a new conversation in this matter starts with: every ready one, as the web
    /// attaches them. The user can change them before asking. Empty until the files are listed.
    var readyFiles: [MatterFile] { matterFiles.filter(\.isReady) }

    /// The matter's documents, flattened, as a conversation or the chronology reader names them.
    var matterFiles: [MatterFile] { MatterFile.flatten(files ?? [], projectID: projectID) }

    static let conversationsLockLine =
        "Conversations here stay with this matter and read only its files. They are not listed in History."

    // MARK: - Chronology from the documents

    /// A fresh "Build from documents" flow, checked against what the matter already records and
    /// re-reading the matter once it has saved anything.
    func chronologyBuilder() -> ChronologyBuildViewModel {
        ChronologyBuildViewModel(
            projectID: projectID, service: service, updates: updates, courtHistory: courtHistory,
            reload: { [weak self] in await self?.load() })
    }

    // MARK: - Banner

    /// The banner's preset: drawn on its own, or under the picture.
    var bannerPreset: BannerPreset { BannerPreset.preset(for: project) }

    /// The uploaded picture's bytes, once fetched.
    private(set) var bannerImage: Data?
    /// The `updated_at` the picture was fetched for: a matter that has changed since may have a
    /// new one.
    private var bannerKey: String?
    private(set) var isChangingBanner = false

    /// Fetches the picture when the matter has one and it is not already held for this version
    /// of the matter. A failure leaves the preset showing — a banner is decoration.
    func loadBanner(force: Bool = false) async {
        guard let project, project.hasBannerImage else {
            bannerImage = nil
            bannerKey = nil
            return
        }
        let key = project.updatedAtRaw ?? ""
        guard force || bannerImage == nil || bannerKey != key else { return }
        do {
            bannerImage = try await service.bannerImage(projectID: projectID)
            bannerKey = key
        } catch {
            // Kept as it was: the preset under it is the fallback.
        }
    }

    /// Uploads a picture (already shrunk by the view) as the banner, then re-reads the matter.
    @discardableResult
    func uploadBanner(data: Data, mime: String) async -> Bool {
        let dataURL: String
        do {
            dataURL = try BannerImage.dataURL(data: data, mime: mime)
        } catch {
            writeError = DisplayText.message(for: error)
            return false
        }
        return await changeBanner { try await self.service.uploadBanner(projectID: self.projectID, dataURL: dataURL) }
    }

    /// Takes the picture off; the preset shows again.
    @discardableResult
    func removeBanner() async -> Bool {
        await changeBanner { try await self.service.deleteBanner(projectID: self.projectID) }
    }

    private func changeBanner(_ action: () async throws -> Void) async -> Bool {
        guard !isChangingBanner else { return false }
        isChangingBanner = true
        writeError = nil
        defer { isChangingBanner = false }
        do {
            try await action()
            await load()
            await loadBanner(force: true)
            return true
        } catch {
            writeError = DisplayText.message(for: error)
            return false
        }
    }

    // MARK: - Deleting the matter

    private(set) var isDeleting = false
    /// Why the last delete was refused or failed.
    var deleteError: String?

    /// Whether what was typed is the matter's name — surrounding spaces forgiven, nothing else.
    func deleteConfirmationMatches(_ typed: String) -> Bool {
        let wanted = (project?.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let given = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return !given.isEmpty && given == wanted
    }

    /// Deletes the matter for good, once its name has been typed. Refused here, with no request,
    /// unless it matches; the server is sent the stored name. `true` means it is gone and the
    /// screen should close.
    func deleteMatter(confirmName typed: String) async -> Bool {
        guard !isDeleting, let project else { return false }
        guard deleteConfirmationMatches(typed) else {
            deleteError = "Type the matter’s name exactly as it appears to delete it."
            return false
        }
        isDeleting = true
        deleteError = nil
        defer { isDeleting = false }
        do {
            try await service.deleteProject(id: projectID, confirm: project.name ?? "")
            return true
        } catch {
            deleteError = DisplayText.message(for: error)
            return false
        }
    }

    /// What the delete sheet says goes with the matter.
    var deleteConsequences: [String] {
        var files = "Its files — they are not kept in My Files or anywhere else."
        if let count = knownFileCount, count > 0 { files = "Its files (\(count)) — they are not kept in My Files or anywhere else." }
        let chatCount = detail?.chats.count ?? 0
        let chats = chatCount > 0
            ? "Its Ask Emperor conversations (\(chatCount)) and the drafts made in them."
            : "Its Ask Emperor conversations and the drafts made in them."
        return [files, chats, "Its chronology, tasks, fees and people."]
    }

    static let deleteFootnote =
        "A court case linked to it stays tracked, and is listed under Matters again as a tracked case. This cannot be undone."

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

    // MARK: - The matter's documents: rename and delete

    /// Whether a matter's document can be renamed and deleted from here.
    var offersFileEditing: Bool { fileManager != nil }

    /// Non-nil while a deletion's confirmation is on screen.
    var pendingFileDeletion: FileDeletion?

    /// The document an edit is running against, so its row shows it.
    private(set) var busyFilePath: String?

    func isBusy(_ file: FileNode.StoredFile) -> Bool { busyFilePath == file.path }

    /// Asks before deleting, in the matter's own words (`FileDeletion.init(matterFile:)`).
    func requestDeletion(of file: FileNode.StoredFile) {
        guard fileManager != nil else { return }
        pendingFileDeletion = FileDeletion(matterFile: file)
    }

    func cancelFileDeletion() { pendingFileDeletion = nil }

    /// Deletes what the confirmation named, then lists the matter's files again.
    ///
    /// Addressed by the folder the server listed it in — `_projects/<id>/Pleadings` — exactly as
    /// the web's Files section addresses it, so a document of the same name in My Files or in
    /// another matter is never the one touched. The re-read is unconditional: the route answers
    /// success for a path that is not there, so only the listing says what the matter holds.
    func confirmFileDeletion(_ plan: FileDeletion) async {
        pendingFileDeletion = nil
        guard case .file(let file) = plan.target else { return }
        await editFile(file) { manager in
            try await manager.delete(name: file.name, folderName: file.folderPath)
            return plan.doneNotice
        }
    }

    /// Renames a matter's document where it stands.
    ///
    /// - Important: the name typed is a request. The server keeps the extension and sanitises the
    ///   rest, so what is said afterwards is the name it echoed (`FileEditWording`).
    func renameFile(_ file: FileNode.StoredFile, to newName: String) async {
        let requested = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty, requested != file.name else { return }
        await editFile(file) { manager in
            let result = try await manager.rename(name: file.name, in: file.folderPath, to: requested)
            return FileEditWording.renamed(result, requested: requested)
        }
    }

    private func editFile(
        _ file: FileNode.StoredFile, _ body: (any FileManaging) async throws -> String
    ) async {
        guard let fileManager, !isWriting else { return }
        isWriting = true
        busyFilePath = file.path
        writeError = nil
        notice = nil
        do {
            notice = try await body(fileManager)
        } catch {
            writeError = DisplayText.message(for: error)
        }
        isWriting = false
        busyFilePath = nil
        await loadFiles()
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
