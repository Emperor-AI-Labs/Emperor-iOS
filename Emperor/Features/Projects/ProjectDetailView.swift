import SwiftUI

/// One matter: its facts, its own timeline, and — when it is linked to a scraped case — that
/// case's hearing and order history.
///
/// - Important: **the two records are two sections, not one chronology.**
///
///   The server merges them into a single response precisely so a client *can* interleave, and
///   the web does: `updates` and `courtHistory` are concatenated, sorted by date, and drawn down
///   one spine. This follows Android instead and keeps them apart.
///
///   The reason is that the interleaved view reads as one chronology when it is two. An update is
///   something the user typed — it can be wrong, backdated, or a note-to-self. A court-history
///   row was scraped from a registry and is a fact about the record. Give them one rule, one
///   spine and one date column and the eye stops distinguishing them within about three rows, at
///   which point "order received, sent to counsel" and "Order dated 12.08.2026" carry equal
///   weight. They do not: one is evidence of what the court did, the other of what the user
///   believed. Two headings cost one extra scroll and make provenance unmissable, which is what
///   this screen is read for.
///
/// - Important: read-only. There is no "add an update" here — see `ProjectService`.
struct ProjectDetailView: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session

    let projectID: String

    @State private var model: ProjectDetailViewModel?

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
        ListStateView(presentation: model.presentation, retry: { await model.load() }) {
            List {
                facts(model)
                updates(model)
                courtRecord(model)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.canvas)
        } empty: {
            // Unreachable in practice — a load that returns without a project throws instead, so
            // the failure branch catches it. Present because `ListStateView` requires both
            // closures, and because "empty" must never silently render as blank content.
            ContentUnavailableView(
                "Matter unavailable",
                systemImage: "questionmark.folder",
                description: Text(ProjectService.projectGoneMessage))
        }
        .refreshable { await model.load() }
    }

    // MARK: - Sections

    @ViewBuilder
    private func facts(_ model: ProjectDetailViewModel) -> some View {
        if !model.facts.isEmpty {
            Section {
                ForEach(model.facts) { fact in
                    LabeledContent(fact.label) {
                        // Weight spelled out rather than `? .semibold : nil` — an implicit
                        // member on the wrapped side of an `Optional` ternary is exactly the
                        // shape `swiftc -parse` accepts and the type checker then argues with.
                        let weight: Font.Weight? = fact.isEmphasised ? Font.Weight.semibold : nil
                        Text(fact.value)
                            .font(.brand(.subheadline, weight: weight))
                            .foregroundStyle(
                                fact.isEmphasised ? theme.accentText : theme.textPrimary)
                            .multilineTextAlignment(.trailing)
                    }
                }
            } header: {
                SectionHeader(title: "This matter")
            }
        }
    }

    /// The matter's own timeline. Headed "Updates" — the user's word for it on the web — and
    /// counted, so the heading states the size of what is under it.
    @ViewBuilder
    private func updates(_ model: ProjectDetailViewModel) -> some View {
        if !model.updates.isEmpty {
            Section {
                ForEach(model.updates) { update in
                    record(
                        tag: update.kind,
                        title: update.title,
                        body: update.body,
                        day: update.day)
                }
            } header: {
                SectionHeader(title: "Updates", detail: "\(model.updates.count)")
            } footer: {
                Text("Entries recorded on this matter by hand.")
                    .font(.brand(.caption2))
                    .foregroundStyle(theme.textTertiary)
            }
        }
    }

    /// The linked case's scraped rows — a separate section, never merged into the one above.
    @ViewBuilder
    private func courtRecord(_ model: ProjectDetailViewModel) -> some View {
        if !model.courtHistory.isEmpty {
            Section {
                ForEach(model.courtHistory) { item in
                    record(
                        tag: item.sectionLabel,
                        title: item.title,
                        body: item.subtitle,
                        day: item.itemDate)
                }
            } header: {
                SectionHeader(
                    title: "From the court record", detail: "\(model.courtHistory.count)")
            } footer: {
                Text("Synced from the court for the case this matter is linked to.")
                    .font(.brand(.caption2))
                    .foregroundStyle(theme.textTertiary)
            }
        } else if let caveat = model.courtRecordCaveat {
            // A link with nothing behind it says so. Showing nothing at all invites the reader to
            // conclude the link itself failed.
            Section {
                Text(caveat)
                    .font(.brand(.caption))
                    .foregroundStyle(theme.textSecondary)
            } header: {
                SectionHeader(title: "From the court record")
            }
        }
    }

    private func record(tag: String?, title: String?, body: String?, day: Date?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let tag, !tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(tag.capitalized)
                    .font(.brand(.caption2, weight: .semibold))
                    .foregroundStyle(theme.accentText)
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
