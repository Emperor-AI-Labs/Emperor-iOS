import SwiftUI

/// One matter's workspace — the web's Matters page on a phone: where things stand, what is set
/// up, and the sections behind a row of chips: Ask Emperor, Files, Drafts, Chronology, Court,
/// Tasks, Fees, People. The newer sections are their own views (`MatterAskSection`,
/// `MatterDraftsSection`, `ChronologyBuildSheet`, `MatterBannerView`, `MatterDeleteSheet`).
///
/// Every rule on this screen lives in `ProjectDetailViewModel`; the view lays it out. Writes are
/// a sheet each (`MatterWriteSheet`) and every one is followed by a re-read, so a total or a
/// date here is always the server's.
///
/// - Important: **the two records stay two sections, never one chronology.** The court record is
///   evidence of what the court did; the chronology is what the user (or the AI, or the court
///   sync) recorded. Interleaved they would read with the same weight. See the view model.
struct ProjectDetailView: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session
    @Environment(\.navigator) private var navigator
    @Environment(\.dismiss) private var dismiss

    let projectID: String
    /// Told when the matter has been deleted from here, so the list behind it can refresh.
    var onDeleted: (() -> Void)?

    @State private var model: ProjectDetailViewModel?
    @State private var writing: MatterWriteSheet.Kind?
    @State private var isAttaching = false
    @State private var attachInto: String = MatterVocabulary.standardFolders[0]
    @State private var isFindingCase = false
    @State private var toast: String?
    /// The matter's conversation being opened from Ask Emperor.
    @State private var openChat: MatterChatRoute?
    /// "Build from documents", while its sheet is up.
    @State private var chronologyBuild: ChronologyBuildViewModel?
    @State private var isConfirmingDelete = false

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(model?.title ?? "Matter")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard model == nil else { return }
            let created = ProjectDetailViewModel(projectID: projectID, service: session.projects)
            model = created
            await created.load()
        }
    }

    @ViewBuilder
    private func content(_ model: ProjectDetailViewModel) -> some View {
        @Bindable var bindable = model

        ListStateView(presentation: model.presentation, retry: { await model.load() }) {
            List {
                sectionChips(model)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                if let error = model.writeError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.brand(.footnote))
                            .foregroundStyle(theme.warning)
                    }
                    .listRowBackground(theme.surface)
                }

                switch model.section {
                case .overview: overview(model)
                case .ask: MatterAskSection(model: model) { openChat = $0 }
                case .drafts: MatterDraftsSection(projectID: projectID) { model.section = .ask }
                case .chronology: chronology(model)
                case .court: court(model)
                case .tasks: tasks(model)
                case .fees: fees(model)
                case .people: people(model)
                case .files: files(model)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.groupedBackground)
        } empty: {
            // Unreachable in practice — a load that returns without a project throws instead, so
            // the failure branch catches it. Present because `ListStateView` requires both
            // closures, and because "empty" must never silently render as blank content.
            EmptyStateView(
                "Matter unavailable",
                systemImage: "questionmark.folder",
                message: ProjectService.projectGoneMessage,
                tone: .neutral)
        }
        .refreshable {
            await model.load()
            if model.section == .files { await model.loadFiles() }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                addMenu(model)
            }
        }
        .sheet(item: $writing) { kind in
            MatterWriteSheet(kind: kind, destinations: model.attachDestinations) { draft in
                await save(draft, on: model)
            }
            .pageSizedSheet()
        }
        .sheet(isPresented: $isAttaching) {
            // My Files, as the drawer sees it: only finished documents can be chosen, which is
            // also the server's rule for an attach.
            NavigationStack {
                FileLibraryView(alreadyAttached: []) { chosen in
                    isAttaching = false
                    let folder = attachInto
                    Task {
                        if await model.attach(chosen, into: folder) {
                            toast = model.attachSummary
                        }
                    }
                }
            }
            .pageSizedSheet()
        }
        .sheet(isPresented: $isFindingCase) {
            // Finds and tracks the case; linking it to this matter is the next step on the Court
            // section, where the tracked case can be chosen.
            CourtSearchView {
                Task { await model.load() }
            }
            .pageSizedSheet()
        }
        .recordToast($toast)
        .onChange(of: model.notice) { _, notice in
            if let notice { toast = notice }
        }
        .onChange(of: model.section) { _, section in
            // Ask needs the files too: a new conversation starts with the ready ones attached.
            if section == .files || section == .ask, model.files == nil {
                Task { await model.loadFiles() }
            }
        }
        .navigationDestination(item: $openChat) { route in
            ChatThreadView(
                chatID: route.chatID,
                initialAttachments: route.isNew ? model.readyFiles.map(\.attachment) : [],
                onTurnFinished: { Task { await model.load() } },
                projectID: projectID)
        }
        .sheet(isPresented: Binding(
            get: { chronologyBuild != nil },
            set: { if !$0 { chronologyBuild = nil } }
        )) {
            if let build = chronologyBuild {
                ChronologyBuildSheet(model: build) { summary in toast = summary }
                    .pageSizedSheet()
            }
        }
        .sheet(isPresented: $isConfirmingDelete) {
            MatterDeleteSheet(model: model) {
                onDeleted?()
                dismiss()
            }
        }
    }

    // MARK: - Chips

    private func sectionChips(_ model: ProjectDetailViewModel) -> some View {
        @Bindable var bindable = model
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.xs) {
                ForEach(ProjectDetailViewModel.Section.allCases) { section in
                    let selected = model.section == section
                    Button {
                        bindable.section = section
                    } label: {
                        Text(section.title)
                            .font(.brand(.footnote, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? theme.accentText : theme.textSecondary)
                            .padding(.horizontal, Spacing.md)
                            .padding(.vertical, 7)
                            .background(selected ? theme.accentWash : theme.surface, in: Capsule())
                            .overlay(Capsule().strokeBorder(selected ? theme.accentMuted : theme.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, Spacing.gutter)
            .padding(.vertical, Spacing.xs)
        }
    }

    private func addMenu(_ model: ProjectDetailViewModel) -> some View {
        Menu {
            Button { writing = .task } label: { Label("Add a task", systemImage: "checkmark.circle") }
            Button { writing = .event } label: { Label("Add to the chronology", systemImage: "calendar.badge.plus") }
            Button { writing = .fee } label: { Label("Record a fee", systemImage: "indianrupeesign") }
            Button { writing = .payment } label: { Label("Record a payment", systemImage: "arrow.down.circle") }
            Button { writing = .expense } label: { Label("Record an expense", systemImage: "arrow.up.circle") }
            Button { writing = .person } label: { Label("Add a person", systemImage: "person.badge.plus") }
            Divider()
            Button { isAttaching = true } label: { Label("Attach from My Files", systemImage: "doc.badge.plus") }
        } label: {
            Label("Add", systemImage: "plus")
        }
        .disabled(model.isWriting)
    }

    private func save(_ draft: MatterWriteSheet.Draft, on model: ProjectDetailViewModel) async {
        switch draft {
        case .task(let task): await model.addTask(task)
        case .event(let update): await model.addUpdate(update)
        case .ledger(let entry): await model.addLedgerEntry(entry)
        case .person(let person): await model.addPerson(person)
        }
    }

    // MARK: - Overview

    @ViewBuilder
    private func overview(_ model: ProjectDetailViewModel) -> some View {
        Section {
            MatterBannerView(model: model)
                .listRowInsets(EdgeInsets())
        }
        .listRowBackground(Color.clear)

        if let standing = model.standing {
            Section {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(standing.headline)
                        .font(.brand(.title3, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = standing.detail {
                        Text(detail)
                            .font(.brand(.subheadline))
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !standing.offers.isEmpty {
                        HStack(spacing: Spacing.sm) {
                            ForEach(standing.offers, id: \.self) { offer in
                                switch offer {
                                case .findCase:
                                    Button("Find the case") { isFindingCase = true }
                                        .buttonStyle(.primaryAction)
                                case .addDate:
                                    Button("Add a date myself") { writing = .event }
                                        .buttonStyle(.bordered)
                                }
                            }
                        }
                        .padding(.top, Spacing.xs)
                    }
                }
                .padding(.vertical, Spacing.xs)
            } header: {
                SectionHeader(title: "Where things stand")
            }
            .listRowBackground(theme.surface)
        }

        if let setup = model.setup {
            Section {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    ProgressView(value: Double(setup.percent), total: 100)
                        .tint(theme.accentText)
                    Text(setup.summary)
                        .font(.brand(.footnote))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    setupChips(setup, model)
                }
                .padding(.vertical, Spacing.xs)
            } header: {
                SectionHeader(title: "Setting up", detail: "\(setup.percent)%")
            }
            .listRowBackground(theme.surface)
        }

        Section {
            tile("To do", model.tasksSummary, systemImage: "checklist") { model.section = .tasks }
            tile("Fees", model.feesSummary, systemImage: "indianrupeesign.circle") { model.section = .fees }
            if let order = model.latestOrder {
                tile("Latest order",
                     [order.title, order.itemDate.map { DisplayText.longDay(WireDate.dayKey($0)) }]
                        .compactMap { $0 }.joined(separator: " · "),
                     systemImage: "doc.text") { model.section = .court }
            }
        }
        .listRowBackground(theme.surface)

        facts(model.facts, title: "This matter")

        MatterDeleteRow { isConfirmingDelete = true }
    }

    /// One chip per missing step. The ones a tap can settle do it here; the rest open the
    /// section where it is done.
    private func setupChips(_ setup: MatterSetup, _ model: ProjectDetailViewModel) -> some View {
        FlowChips {
            ForEach(setup.missing) { step in
                switch step.key {
                case .side:
                    Menu {
                        ForEach(MatterVocabulary.ourSides, id: \.key) { option in
                            Button(option.label) { Task { await model.setField("ourSide", option.key) } }
                        }
                    } label: { chipLabel(step.label) }
                case .practice:
                    Menu {
                        ForEach(MatterVocabulary.practiceAreas, id: \.key) { option in
                            Button(option.label) { Task { await model.setField("practiceArea", option.key) } }
                        }
                    } label: { chipLabel(step.label) }
                case .court:
                    Menu {
                        Button("Find the case") { isFindingCase = true }
                        Button("Not filed yet") { Task { await model.setField("courtStatus", "not_filed") } }
                    } label: { chipLabel(step.label) }
                case .parties:
                    Button { writing = .person } label: { chipLabel(step.label) }
                case .contact:
                    Button { writing = .person } label: { chipLabel(step.label) }
                case .documents:
                    Button { model.section = .files } label: { chipLabel(step.label) }
                }
            }
        }
    }

    private func chipLabel(_ text: String) -> some View {
        Label(text, systemImage: "plus")
            .font(.brand(.caption, weight: .medium))
            .foregroundStyle(theme.accentText)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, 5)
            .background(theme.accentWash, in: Capsule())
    }

    private func tile(_ title: String, _ value: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.sm) {
                IconRowLabel(title: title, systemImage: systemImage)
                Spacer(minLength: Spacing.sm)
                Text(value)
                    .font(.brand(.subheadline))
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.trailing)
                RowChevron()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(title): \(value)"))
    }

    @ViewBuilder
    private func facts(_ facts: [ProjectDetailViewModel.Fact], title: String) -> some View {
        if !facts.isEmpty {
            Section {
                ForEach(facts) { fact in
                    HStack(alignment: .firstTextBaseline) {
                        Text(fact.label)
                            .font(.brand(.subheadline))
                            .foregroundStyle(theme.textSecondary)
                        Spacer(minLength: Spacing.md)
                        // Weight spelled out rather than `? .semibold : nil` — an implicit
                        // member on the wrapped side of an `Optional` ternary is exactly the
                        // shape `swiftc -parse` accepts and the type checker then argues with.
                        let weight: Font.Weight? = fact.isEmphasised ? Font.Weight.semibold : nil
                        Text(fact.value)
                            .font(.brand(.subheadline, weight: weight))
                            .foregroundStyle(fact.isEmphasised ? theme.accentText : theme.textPrimary)
                            .multilineTextAlignment(.trailing)
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                SectionHeader(title: title)
            }
            .listRowBackground(theme.surface)
        }
    }

    // MARK: - Chronology

    @ViewBuilder
    private func chronology(_ model: ProjectDetailViewModel) -> some View {
        ChronologyBuildRow { chronologyBuild = model.chronologyBuilder() }

        if model.updates.isEmpty {
            Section {
                emptyLine("Nothing on the chronology yet. Add a date, or link the court case and its hearings fill in.")
            }
            .listRowBackground(theme.surface)
        } else {
            Section {
                ForEach(model.updates) { update in
                    record(tag: update.kindLabel, title: update.title, body: update.body,
                           day: update.day, source: update.sourceLabel)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await model.deleteUpdate(update) }
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                }
            } header: {
                SectionHeader(title: "Chronology", detail: "\(model.updates.count)")
            } footer: {
                Text("Dates and events on this matter: typed in, read from the documents, or taken from the court. The court's own record is under Court.")
                    .font(.brand(.caption2))
                    .foregroundStyle(theme.textTertiary)
            }
            .listRowBackground(theme.surface)
        }
    }

    // MARK: - Court

    @ViewBuilder
    private func court(_ model: ProjectDetailViewModel) -> some View {
        if let linked = model.linkedCase {
            Section {
                if let title = linked.title, !title.isEmpty {
                    Text(title).font(.brand(.headline))
                }
                if let court = linked.courtName, !court.isEmpty {
                    ValueRow("Court", value: court)
                }
                if let stage = linked.stage, !stage.isEmpty {
                    ValueRow("Stage", value: stage)
                }
                if let status = linked.status, !status.isEmpty {
                    ValueRow("Status", value: status)
                }
                if let id = linked.id, !id.isEmpty {
                    Button {
                        navigator.openCase(id)
                    } label: {
                        Label("Open the case page", systemImage: "arrow.up.right.square")
                    }
                }
                Button {
                    Task { await model.refreshFromCourt() }
                } label: {
                    Label("Refresh from court", systemImage: "arrow.clockwise")
                }
                .disabled(model.isWriting)
            } header: {
                SectionHeader(title: "Linked case")
            } footer: {
                if let line = model.courtSyncLine {
                    Text(line)
                        .font(.brand(.caption2))
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .listRowBackground(theme.surface)
        } else {
            Section {
                Text(model.project?.isNotFiledYet == true
                     ? "Not filed in court yet. Once it is, find the case and every hearing is tracked here."
                     : "No court case is linked. Find it by case number and its hearings, orders and next date fill in by themselves.")
                    .font(.brand(.footnote))
                    .foregroundStyle(theme.textSecondary)
                Button("Find the case") { isFindingCase = true }
                    .buttonStyle(.primaryAction)
            } header: {
                SectionHeader(title: "Court case")
            }
            .listRowBackground(theme.surface)
        }

        if !model.courtHistory.isEmpty {
            Section {
                ForEach(model.courtHistory) { item in
                    record(tag: item.sectionLabel, title: item.title, body: item.subtitle,
                           day: item.itemDate, source: nil)
                }
            } header: {
                SectionHeader(title: "From the court record", detail: "\(model.courtHistory.count)")
            } footer: {
                Text("Synced from the court for the case this matter is linked to.")
                    .font(.brand(.caption2))
                    .foregroundStyle(theme.textTertiary)
            }
            .listRowBackground(theme.surface)
        } else if let caveat = model.courtRecordCaveat {
            Section {
                Text(caveat)
                    .font(.brand(.caption))
                    .foregroundStyle(theme.textSecondary)
            } header: {
                SectionHeader(title: "From the court record")
            }
            .listRowBackground(theme.surface)
        }
    }

    // MARK: - Tasks

    @ViewBuilder
    private func tasks(_ model: ProjectDetailViewModel) -> some View {
        if model.tasks.isEmpty {
            Section {
                emptyLine("Nothing to do yet. Add a task, a filing or a limitation date.")
            }
            .listRowBackground(theme.surface)
        }
        if !model.openTasks.isEmpty {
            Section {
                ForEach(model.openTasks) { task in taskRow(task, model) }
            } header: {
                SectionHeader(title: "To do", detail: "\(model.openTasks.count)")
            }
            .listRowBackground(theme.surface)
        }
        if !model.doneTasks.isEmpty {
            Section {
                ForEach(model.doneTasks) { task in taskRow(task, model) }
            } header: {
                SectionHeader(title: "Done", detail: "\(model.doneTasks.count)")
            }
            .listRowBackground(theme.surface)
        }
    }

    private func taskRow(_ task: ProjectTask, _ model: ProjectDetailViewModel) -> some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Button {
                Task { await model.setDone(task, !task.isDone) }
            } label: {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.isDone ? theme.success : theme.textTertiary)
                    .imageScale(.large)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.isDone ? "Reopen" : "Mark done")
            .disabled(model.isWriting)

            VStack(alignment: .leading, spacing: 3) {
                Text(task.displayTitle)
                    .font(.brand(.subheadline, weight: task.isHighPriority ? .semibold : .regular))
                    .strikethrough(task.isDone)
                    .foregroundStyle(task.isDone ? theme.textSecondary : theme.textPrimary)
                HStack(spacing: 6) {
                    Text(task.kindLabel)
                        .font(.brand(.caption2, weight: .semibold))
                        .foregroundStyle(theme.accentText)
                    if let due = model.dueLabel(for: task) {
                        SeparatorDot()
                        Text(due)
                            .font(.brand(.caption2))
                            .foregroundStyle(task.isOverdue(todayKey: WireDate.todayKey()) ? theme.warning : theme.textTertiary)
                    }
                }
                if let notes = task.notes, !notes.isEmpty {
                    Text(notes).font(.brand(.caption)).foregroundStyle(theme.textSecondary)
                }
            }
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                Task { await model.deleteTask(task) }
            } label: { Label("Delete", systemImage: "trash") }
        }
    }

    // MARK: - Fees

    @ViewBuilder
    private func fees(_ model: ProjectDetailViewModel) -> some View {
        facts(model.moneyFacts, title: "Totals")
        if model.ledger.isEmpty {
            Section {
                emptyLine("No fees, payments or expenses recorded yet.")
            }
            .listRowBackground(theme.surface)
        } else {
            Section {
                ForEach(model.ledger) { entry in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.displayTitle).font(.brand(.subheadline))
                            HStack(spacing: 6) {
                                if let day = entry.entryDate {
                                    Text(DisplayText.longDay(WireDate.dayKey(day)))
                                }
                                if let detail = entry.detail {
                                    if entry.entryDate != nil { SeparatorDot() }
                                    Text(detail)
                                }
                            }
                            .font(.brand(.caption2))
                            .foregroundStyle(theme.textTertiary)
                        }
                        Spacer(minLength: Spacing.md)
                        Text(model.amountLabel(for: entry))
                            .font(.brand(.subheadline, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(entry.entryKind == .payment ? theme.success : theme.textPrimary)
                    }
                    .accessibilityElement(children: .combine)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task { await model.deleteLedgerEntry(entry) }
                        } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            } header: {
                SectionHeader(title: "Ledger", detail: "\(model.ledger.count)")
            }
            .listRowBackground(theme.surface)
        }
    }

    // MARK: - People

    @ViewBuilder
    private func people(_ model: ProjectDetailViewModel) -> some View {
        if model.people.isEmpty {
            Section {
                emptyLine("No one on this matter yet. Add the client, the other side and counsel.")
            }
            .listRowBackground(theme.surface)
        } else {
            ForEach(model.peopleByRole, id: \.role) { group in
                Section {
                    ForEach(group.people) { person in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(person.displayName).font(.brand(.subheadline))
                            if let contact = person.contactLine {
                                Text(contact).font(.brand(.caption)).foregroundStyle(theme.textSecondary)
                                    .textSelection(.enabled)
                            }
                            if let notes = person.notes, !notes.isEmpty {
                                Text(notes).font(.brand(.caption2)).foregroundStyle(theme.textTertiary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await model.deletePerson(person) }
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                } header: {
                    SectionHeader(title: group.role, detail: "\(group.people.count)")
                }
                .listRowBackground(theme.surface)
            }
        }
    }

    // MARK: - Files

    @ViewBuilder
    private func files(_ model: ProjectDetailViewModel) -> some View {
        Section {
            Picker("Attach into", selection: $attachInto) {
                ForEach(model.attachDestinations, id: \.self) { Text($0).tag($0) }
            }
            Button {
                isAttaching = true
            } label: {
                Label("Attach from My Files", systemImage: "doc.badge.plus")
            }
            .disabled(model.isWriting)
        } footer: {
            Text("Documents are added to a matter from My Files, where they are read and indexed first. Nothing is uploaded here.")
                .font(.brand(.caption2))
                .foregroundStyle(theme.textTertiary)
        }
        .listRowBackground(theme.surface)

        if let report = model.attachReport, !report.isEmpty {
            Section {
                ForEach(Array(report.enumerated()), id: \.offset) { _, line in
                    Label(line.line, systemImage: line.wasAttached ? "checkmark.circle" : "minus.circle")
                        .font(.brand(.caption))
                        .foregroundStyle(line.wasAttached ? theme.success : theme.textSecondary)
                }
            } header: {
                SectionHeader(title: "Last attached", detail: model.attachSummary)
            }
            .listRowBackground(theme.surface)
        }

        if let failure = model.filesState.failure {
            Section {
                Label(failure.message, systemImage: "exclamationmark.triangle")
                    .font(.brand(.footnote))
                    .foregroundStyle(theme.warning)
                Button("Try again") { Task { await model.loadFiles() } }
            }
            .listRowBackground(theme.surface)
        } else if model.filesPresentation.showsLoadingPlaceholder {
            Section { ProgressView() }.listRowBackground(theme.surface)
        } else if model.allFiles.isEmpty, model.filesState.hasLoaded {
            Section {
                emptyLine("No documents in this matter yet.")
            }
            .listRowBackground(theme.surface)
        } else {
            ForEach(model.folders, id: \.path) { folder in
                let files = FileService.allFiles(in: folder.files ?? [])
                if !files.isEmpty {
                    Section {
                        ForEach(files, id: \.path) { file in fileRow(file) }
                    } header: {
                        SectionHeader(title: folder.name, detail: "\(files.count)")
                    }
                    .listRowBackground(theme.surface)
                }
            }
            if !model.looseFiles.isEmpty {
                Section {
                    ForEach(model.looseFiles, id: \.path) { file in fileRow(file) }
                } header: {
                    SectionHeader(title: "Other", detail: "\(model.looseFiles.count)")
                }
                .listRowBackground(theme.surface)
            }
        }
    }

    private func fileRow(_ file: FileNode.StoredFile) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(DisplayText.fileName(file.name)).font(.brand(.subheadline))
            if !file.isReadable, let status = file.status, !status.isEmpty {
                Text(status).font(.brand(.caption2)).foregroundStyle(theme.textTertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Pieces

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(.brand(.footnote))
            .foregroundStyle(theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func record(tag: String?, title: String?, body: String?, day: Date?, source: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if let tag, !tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(tag.capitalized)
                        .font(.brand(.caption2, weight: .semibold))
                        .foregroundStyle(theme.accentText)
                }
                if let source {
                    SeparatorDot()
                    Text(source)
                        .font(.brand(.caption2))
                        .foregroundStyle(theme.textTertiary)
                }
            }
            if let title, !title.isEmpty {
                Text(title).font(.brand(.subheadline))
            }
            if let body, !body.isEmpty {
                Text(body).font(.brand(.caption)).foregroundStyle(theme.textSecondary)
            }
            if let day {
                Text(DisplayText.longDay(WireDate.dayKey(day)))
                    .font(.brand(.caption2))
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Chips that wrap onto the next line. A plain `HStack` clips the sixth chip on a phone.
private struct FlowChips<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        // iOS 16+ `Layout`-free approach: a lazy grid with adaptive columns reads as wrapped
        // chips without measuring text.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: Spacing.xs, alignment: .leading)],
                  alignment: .leading, spacing: Spacing.xs) {
            content()
        }
    }
}
