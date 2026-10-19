import SwiftUI

/// Drafts, inside a matter: the documents and tables its conversations produced, newest first,
/// opened in the same reader the general drafts list uses. They are kept here, not in the
/// general list — `DraftHistoryViewModel`'s matter mode keeps only this matter's rows.
struct MatterDraftsSection: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session

    let projectID: String
    /// Opens Ask Emperor, where a new draft is asked for.
    let onDraftNew: () -> Void

    @State private var model: DraftHistoryViewModel?

    var body: some View {
        Section {
            if let model {
                rows(model)
            } else {
                ProgressView()
            }
        } header: {
            SectionHeader(title: "Drafts", detail: model.map { $0.items.isEmpty ? nil : "\($0.items.count)" } ?? nil)
        } footer: {
            Label("Documents and tables drafted in this matter's conversations. They are kept here, not with your other drafts.",
                  systemImage: "lock")
                .font(.brand(.caption2))
                .foregroundStyle(theme.textTertiary)
        }
        .listRowBackground(theme.surface)
        .task {
            if model == nil { model = DraftHistoryViewModel(service: session.drafts, projectID: projectID) }
            await model?.load()
        }
        .fullScreenCover(item: Binding(
            get: { model?.opened },
            set: { if $0 == nil { model?.close() } }
        )) { opened in
            DraftReaderView(draft: opened)
        }
        .alert("Couldn't open that", isPresented: Binding(
            get: { model?.errorMessage != nil },
            set: { if !$0 { model?.errorMessage = nil } }
        )) {
            Button("OK") { model?.errorMessage = nil }
        } message: {
            Text(model?.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func rows(_ model: DraftHistoryViewModel) -> some View {
        if let notice = model.partialNotice {
            Label(notice, systemImage: "exclamationmark.triangle")
                .font(.brand(.footnote))
                .foregroundStyle(theme.warning)
        }
        if let failure = model.state.failure {
            Label(failure.message, systemImage: "exclamationmark.triangle")
                .font(.brand(.footnote))
                .foregroundStyle(theme.warning)
            Button("Try again") { Task { await model.load() } }
        } else if model.presentation.showsLoadingPlaceholder {
            ProgressView()
        } else if model.items.isEmpty {
            Text("No drafts yet. Ask Emperor to draft a pleading, notice, reply or list of dates in this matter, and the draft is kept here.")
                .font(.brand(.footnote))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Draft something new", action: onDraftNew)
        } else {
            ForEach(model.items) { item in
                row(item, model)
            }
        }
    }

    private func row(_ item: DraftedItem, _ model: DraftHistoryViewModel) -> some View {
        let isTable = item.type == DraftKind.table.rawValue
        return Button {
            model.open(item)
        } label: {
            HStack(spacing: Spacing.md) {
                IconTile(systemImage: isTable ? DraftKind.table.systemImage : DraftKind.document.systemImage)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayTitle)
                        .font(.brand(.subheadline, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                        .dynamicLineLimit(2)
                    Text(subtitle(item, isTable: isTable))
                        .font(.brand(.caption2))
                        .foregroundStyle(theme.textTertiary)
                        .dynamicLineLimit(1)
                }
                Spacer(minLength: 0)
                if model.loadingID == item.id {
                    ProgressView().controlSize(.small)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(isTable ? "Table" : "Document")
    }

    private func subtitle(_ item: DraftedItem, isTable: Bool) -> String {
        var parts = [isTable ? "Table" : "Document"]
        if let created = item.createdAt { parts.append(DisplayText.relative(created)) }
        return parts.joined(separator: " · ")
    }
}
