import SwiftUI

/// Hand-made matters — the ones typed in rather than scraped.
///
/// The sibling of `CaseListView` and deliberately a separate screen. A case belongs to a team and
/// is maintained by the court scrapers; a project belongs to one user and is typed in by hand.
/// The web's rail puts them next to each other for the same reason, and merging them would put a
/// row whose hearing date a registry guarantees beside one whose hearing date somebody
/// half-remembered, under the same heading.
///
/// - Important: **read-only.** Nothing here creates or edits a matter. The write routes exist, and
///   the shape of a project is still moving on the web while the feature is trialled there — see
///   `ProjectService` for the full reasoning. That is also why the empty state has to say where
///   matters come from: there is no "+" to reach for.
///
/// - Important: owns its own `NavigationStack`, because `MoreView` **presents** rather than
///   pushes. Pushing this into that list's stack would nest two and give the screen two
///   navigation bars and a back button that unwinds the wrong one.
struct ProjectListView: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session

    @State private var model: ProjectListViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    content(model)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(ProjectListViewModel.Copy.title)
            .navigationDestination(for: String.self) { projectID in
                ProjectDetailView(projectID: projectID)
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
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.canvas)
        } empty: {
            // "No search results" belongs **here**, not in the content closure above.
            // `presentation.isEmpty` is measured against the *filtered* list, so a search that
            // matches nothing has already routed to this branch — a check for it up there could
            // never be reached, and the reader would be shown a blank list with no explanation.
            ContentUnavailableView {
                Label(model.emptyTitle, systemImage: "folder.badge.person.crop")
            } description: {
                Text(model.emptyDetail)
            } actions: {
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
            ToolbarItem(placement: .primaryAction) {
                filterMenu(model)
            }
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
                    .lineLimit(2)
                Spacer(minLength: 0)
                if project.isArchived {
                    StatusPill(text: "Archived", tone: .neutral)
                }
            }

            HStack(spacing: 6) {
                if let client = project.client, !client.isEmpty {
                    Text(client).lineLimit(1)
                }
                if let reference = project.caseReference {
                    if project.client?.isEmpty == false { Text("·") }
                    Text(reference)
                }
            }
            .font(.brand(.subheadline))
            .foregroundStyle(theme.textSecondary)

            if let forum = project.forumLabel {
                Text(forum)
                    .font(.brand(.caption))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
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
