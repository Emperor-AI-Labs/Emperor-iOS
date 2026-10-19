import SwiftUI

/// Hand-made matters — the ones typed in rather than scraped.
///
/// The sibling of `CaseListView` and deliberately a separate screen. A case belongs to a team and
/// is maintained by the court scrapers; a project belongs to one user and is typed in by hand.
/// The web's rail puts them next to each other for the same reason, and merging them would put a
/// row whose hearing date a registry guarantees beside one whose hearing date somebody
/// half-remembered, under the same heading.
///
/// `+` starts a matter from a name alone, as the web's New matter does; everything else is
/// filled in from the workspace it opens. A tracked case opens its own workspace from its page.
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
    @State private var isNaming = false
    @State private var newName = ""

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
            .alert(ProjectListViewModel.Copy.newMatter, isPresented: $isNaming) {
                TextField("Name — Helios v. Northgrid", text: $newName)
                Button("Cancel", role: .cancel) { newName = "" }
                Button("Create") {
                    let name = newName
                    newName = ""
                    guard let model else { return }
                    Task {
                        if let id = await model.create(named: name) { path.append(id) }
                    }
                }
            } message: {
                Text("A name is all it needs. The court case, the client and the rest are added in the workspace.")
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
            .task {
                guard model == nil else { return }
                let created = ProjectListViewModel(service: session.projects)
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
                ForEach(model.visible) { project in
                    NavigationLink(value: project.id) {
                        row(project)
                    }
                    .listRowBackground(theme.surface)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.groupedBackground)
        } empty: {
            // "No search results" belongs **here**, not in the content closure above.
            // `presentation.isEmpty` is measured against the *filtered* list, so a search that
            // matches nothing has already routed to this branch — a check for it up there could
            // never be reached, and the reader would be shown a blank list with no explanation.
            EmptyStateView(
                model.emptyTitle, systemImage: "folder.badge.person.crop",
                message: model.createError ?? model.emptyDetail
            ) {
                Button {
                    isNaming = true
                } label: {
                    Label(ProjectListViewModel.Copy.newMatter, systemImage: "plus")
                }
                .buttonStyle(.primaryAction)
                if !model.includeArchived {
                    Button("Include archived matters") {
                        Task { await model.setIncludeArchived(true) }
                    }
                    .buttonStyle(.primaryAction)
                }
            }
        }
        .searchable(text: $bindable.query, prompt: "Filter your matters")
        .refreshable { await model.load() }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                filterMenu(model)
                Button {
                    isNaming = true
                } label: {
                    Label(ProjectListViewModel.Copy.newMatter, systemImage: "plus")
                }
                .disabled(model.isCreating)
            }
        }
        .onChange(of: model.createError) { _, error in
            if error != nil { isNaming = false }
        }
    }

    /// The archived switch.
    ///
    /// In the toolbar rather than as the last row of the list, which is where Android puts it.
    /// A row at the bottom of a `List` is unreachable in exactly the state it is most needed —
    /// when the list is empty and `ListStateView` has replaced it with the empty view. The empty
    /// state offers it too, for the same reason.
    private func filterMenu(_ model: ProjectListViewModel) -> some View {
        Menu {
            Toggle("Include archived matters", isOn: Binding(
                get: { model.includeArchived },
                set: { include in Task { await model.setIncludeArchived(include) } }))
        } label: {
            Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
        }
    }

    private func row(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                // A dot, not a coloured card. The list is already ordered by priority
                // server-side, so this confirms what the position implies rather than shouting
                // over it — and a list where several rows are red teaches the eye to ignore red.
                if project.isHighPriority {
                    Circle()
                        .fill(theme.accentText)
                        .frame(width: 7, height: 7)
                        .accessibilityLabel("High priority")
                }
                Text(project.displayName)
                    .font(.brand(.headline))
                    .dynamicLineLimit(2)
                Spacer(minLength: 0)
                if project.isArchived {
                    StatusPill(text: "Archived", tone: .neutral)
                }
            }

            HStack(spacing: 6) {
                if let client = project.client, !client.isEmpty {
                    Text(client).dynamicLineLimit(1)
                }
                if let reference = project.caseReference {
                    if project.client?.isEmpty == false { SeparatorDot() }
                    Text(reference)
                }
            }
            .font(.brand(.subheadline))
            .foregroundStyle(theme.textSecondary)

            if let forum = project.forumLabel {
                Text(forum)
                    .font(.brand(.caption))
                    .foregroundStyle(theme.textSecondary)
                    .dynamicLineLimit(1)
            }

            if let hearing = project.nextHearingDate {
                Label(
                    DisplayText.longDay(WireDate.dayKey(hearing)),
                    systemImage: "calendar")
                    .font(.brand(.caption))
                    .foregroundStyle(theme.accentText)
            }

            // Only where the route computed them. They are absent on the detail response, and
            // "0 documents" would be a claim where a blank is the honest answer — see
            // `Project.fileCount`.
            if let counts = countsLine(project) {
                Text(counts)
                    .font(.brand(.caption2))
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private func countsLine(_ project: Project) -> String? {
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
