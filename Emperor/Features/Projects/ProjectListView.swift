import SwiftUI

/// The Matters list, as the web's Matters page has it: every matter, and every tracked court case
/// that has no matter yet, under a status scope (Active by default), a practice area, a search
/// and one of three orders. The rules are `ProjectListViewModel`'s and `MatterListing`'s.
///
/// The web also offers a grid/list toggle. A phone has room for one column either way, so this
/// keeps the list and leaves the toggle out.
///
/// - Important: owns its own `NavigationStack`, because `MoreView` **presents** rather than
///   pushes. Pushing this into that list's stack would nest two and give the screen two
///   navigation bars and a back button that unwinds the wrong one.
struct ProjectListView: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session

    @Environment(\.dismiss) private var dismiss

    @State private var model: ProjectListViewModel?
    @State private var path: [String] = []
    @State private var isCreatingMatter = false
    @State private var toast: String?
    @State private var editing: Project?

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let model {
                    content(model)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(ProjectListViewModel.Copy.title)
            .sheet(isPresented: $isCreatingMatter) {
                NewMatterSheet(existing: model?.projects ?? []) { projectID, message in
                    toast = message
                    path.append(projectID)
                    Task { await model?.load() }
                }
                .pageSizedSheet()
            }
            // On the root rather than inside `content`, so it is there in every state — including
            // the spinner before the first load returns, and the failure view if it never does.
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: String.self) { projectID in
                ProjectDetailView(projectID: projectID) {
                    Task { await model?.load() }
                }
            }
            .sheet(item: $editing) { project in
                EditMatterSheet(project: project) { saved, message in
                    toast = model?.notice(afterSaving: saved) ?? message
                    Task { await model?.load() }
                }
                .pageSizedSheet()
            }
            .recordToast($toast)
            .task {
                guard model == nil else { return }
                let created = ProjectListViewModel(
                    service: session.projects, cases: session.cases,
                    teams: TeamService(client: session.client))
                model = created
                await created.load()
            }
        }
    }

    @ViewBuilder
    private func content(_ model: ProjectListViewModel) -> some View {
        @Bindable var bindable = model

        ListStateView(presentation: model.presentation, retry: { await model.load() }) {
            List {
                Section {
                    ForEach(model.visible) { row in
                        rowLink(row, model: model)
                            .listRowBackground(theme.surface)
                    }
                } header: {
                    filterBar(model)
                } footer: {
                    if let error = model.openError {
                        Text(error).foregroundStyle(theme.danger)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.groupedBackground)
        } empty: {
            // "Nothing in view" belongs **here**, not in the content closure above.
            // `presentation.isEmpty` is measured against the *filtered* list, so a search that
            // matches nothing has already routed to this branch.
            VStack(spacing: Spacing.md) {
                filterBar(model)
                    .padding(.horizontal, Spacing.gutter)
                EmptyStateView(
                    model.emptyTitle, systemImage: "folder.badge.person.crop",
                    message: model.createError ?? model.emptyDetail
                ) {
                    emptyActions(model)
                }
            }
        }
        .searchable(text: $bindable.query, prompt: ProjectListViewModel.Copy.searchPrompt)
        .refreshable { await model.load() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isCreatingMatter = true
                } label: {
                    Label(ProjectListViewModel.Copy.newMatter, systemImage: "plus")
                }
            }
        }
    }

    @ViewBuilder
    private func emptyActions(_ model: ProjectListViewModel) -> some View {
        if model.showsNoSearchResults {
            if model.isFiltering {
                Button(ProjectListViewModel.Copy.clearFilters) { model.clearFilters() }
                    .buttonStyle(.secondaryAction)
            }
            if model.offersShowAllStatuses {
                Button(ProjectListViewModel.Copy.showAllStatuses) { model.showAllStatuses() }
                    .buttonStyle(.secondaryAction)
            }
        } else {
            Button {
                isCreatingMatter = true
            } label: {
                Label(ProjectListViewModel.Copy.newMatter, systemImage: "plus")
            }
            .buttonStyle(.primaryAction)
        }
    }

    // MARK: - Filters

    /// The web's three menus — status, practice area, sort — and the summary line beside them.
    private func filterBar(_ model: ProjectListViewModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if !model.summary.isEmpty {
                Text(model.summary)
                    .font(.brand(.footnote))
                    .foregroundStyle(theme.textSecondary)
                    .monospacedDigit()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.sm) {
                    statusMenu(model)
                    areaMenu(model)
                    sortMenu(model)
                }
            }
        }
        .textCase(nil)
    }

    private func statusMenu(_ model: ProjectListViewModel) -> some View {
        Menu {
            Picker("Status", selection: Binding(get: { model.statusFilter }, set: { model.statusFilter = $0 })) {
                ForEach(model.statusOptions) { option in
                    Text(option.label).tag(option.filter)
                }
            }
        } label: {
            FilterMenuLabel(title: model.statusFilter.label, systemImage: "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel("Status")
        .accessibilityValue(model.statusFilter.label)
    }

    private func areaMenu(_ model: ProjectListViewModel) -> some View {
        Menu {
            Picker("Practice area", selection: Binding(get: { model.practiceArea }, set: { model.practiceArea = $0 })) {
                ForEach(model.areaOptions) { option in
                    Text(option.label).tag(option.value)
                }
            }
        } label: {
            FilterMenuLabel(title: model.areaLabel, systemImage: "scalemass")
        }
        .accessibilityLabel("Practice area")
        .accessibilityValue(model.areaLabel)
    }

    private func sortMenu(_ model: ProjectListViewModel) -> some View {
        Menu {
            Picker("Sort", selection: Binding(get: { model.sort }, set: { model.sort = $0 })) {
                ForEach(MatterSort.allCases) { sort in
                    Text(sort.label).tag(sort)
                }
            }
        } label: {
            FilterMenuLabel(title: model.sort.label, systemImage: "arrow.up.arrow.down")
        }
        .accessibilityLabel("Sort")
        .accessibilityValue(model.sort.label)
    }

    // MARK: - Rows

    @ViewBuilder
    private func rowLink(_ row: MatterListRow, model: ProjectListViewModel) -> some View {
        if let caseID = row.trackedCaseID {
            Button {
                Task {
                    if let id = await model.openTrackedCase(caseID) { path.append(id) }
                }
            } label: {
                MatterListRowView(row: row, isOpening: model.openingCaseID == caseID)
            }
            .disabled(model.openingCaseID != nil)
            .accessibilityHint("Opens this tracked case as a matter")
        } else {
            NavigationLink(value: row.id) {
                MatterListRowView(row: row, isOpening: false)
            }
            // TODO: offer "Edit details" from the matter workspace's toolbar menu too, as the
            // web's workspace header does. That screen is being changed elsewhere; until then a
            // long press here is the way in.
            .contextMenu {
                if let project = row.project {
                    Button {
                        editing = project
                    } label: {
                        Label("Edit details", systemImage: "pencil")
                    }
                }
            }
        }
    }
}

/// A filter menu's face: its current choice and an icon, in a capsule.
private struct FilterMenuLabel: View {
    @Environment(\.theme) private var theme
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.brand(.caption, weight: .semibold))
            .foregroundStyle(theme.textPrimary)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 6)
            .background(theme.surface2, in: Capsule())
            .overlay(Capsule().strokeBorder(theme.border, lineWidth: 1))
    }
}

/// One row: a matter, or a tracked case that has none yet.
private struct MatterListRowView: View {
    @Environment(\.theme) private var theme
    let row: MatterListRow
    let isOpening: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            titleLine
            detailLine
            if let hearing = row.nextHearingRaw.flatMap(WireDate.parseDay) {
                Label(DisplayText.longDay(WireDate.dayKey(hearing)), systemImage: "calendar")
                    .font(.brand(.caption))
                    .foregroundStyle(theme.accentText)
            }
            if let counts = countsLine {
                Text(counts)
                    .font(.brand(.caption2))
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private var titleLine: some View {
        HStack(spacing: 6) {
            // A dot, not a coloured card: a list where several rows are red teaches the eye to
            // ignore red.
            if row.project?.isHighPriority == true {
                Circle()
                    .fill(theme.accentText)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel("High priority")
            }
            Text(row.name)
                .font(.brand(.headline))
                .dynamicLineLimit(2)
            Spacer(minLength: 0)
            if isOpening {
                ProgressView().controlSize(.small)
            } else if row.isTrackedCase {
                StatusPill(text: "Tracked case", tone: .neutral)
            } else if row.status != "active", let label = row.project?.statusLabel {
                StatusPill(text: label, tone: .neutral)
            }
        }
    }

    private var detailLine: some View {
        let parts = [row.project?.client, row.caseReference, row.forumName, row.sharedWith.map { "Shared · \($0)" }]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Text(parts.joined(separator: " · "))
            .font(.brand(.subheadline))
            .foregroundStyle(theme.textSecondary)
            .dynamicLineLimit(2)
    }

    /// Only where the route computed them — see `Project.fileCount`.
    private var countsLine: String? {
        guard let project = row.project else { return nil }
        var parts: [String] = []
        if let files = project.fileCount {
            parts.append("\(files) document\(files == 1 ? "" : "s")")
        }
        if let chats = project.chatCount {
            parts.append("\(chats) conversation\(chats == 1 ? "" : "s")")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
