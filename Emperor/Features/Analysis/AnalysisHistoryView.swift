import SwiftUI

/// Saved analysis runs, newest first — of one tool, or of every tool for `nil`. A row opens its
/// run; a swipe deletes it.
///
/// Lives inside a caller's `NavigationStack`: pushed from the hub, or in the tool screen's
/// History sheet.
struct AnalysisHistoryView: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session

    let tool: AnalysisJobTool?
    let onOpen: (AnalysisRunSummary) -> Void

    @State private var model: AnalysisHistoryViewModel?

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView()
            }
        }
        .background(theme.groupedBackground)
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if model == nil {
                model = AnalysisHistoryViewModel(tool: tool, service: session.analysis)
            }
            await model?.load()
        }
    }

    @ViewBuilder
    private func content(_ model: AnalysisHistoryViewModel) -> some View {
        @Bindable var bindable = model
        ListStateView(presentation: model.presentation, retry: { await model.load() }) {
            List {
                Section {
                    ForEach(model.visible) { run in
                        Button {
                            onOpen(run)
                        } label: {
                            AnalysisHistoryRow(run: run, showsTool: tool == nil)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                Task { await model.delete(run.id) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text(model.subtitle)
                        .font(.brand(.caption))
                        .foregroundStyle(theme.textTertiary)
                        .textCase(nil)
                } footer: {
                    if let error = model.actionError {
                        Text(error)
                            .font(.brand(.caption))
                            .foregroundStyle(theme.danger)
                    }
                }
                .listRowBackground(theme.surface)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        } empty: {
            EmptyStateView(
                "No saved runs", systemImage: "clock",
                message: AnalysisHistoryViewModel.emptyMessage, tone: .neutral)
        }
        .refreshable { await model.load() }
        .modifier(AnalysisHistorySearch(enabled: model.offersSearch, query: $bindable.query))
    }
}

/// Search, only once the list is long enough to need it — as the web does.
private struct AnalysisHistorySearch: ViewModifier {
    let enabled: Bool
    @Binding var query: String

    func body(content: Content) -> some View {
        if enabled {
            content.searchable(text: $query, prompt: "Search by title or file name")
        } else {
            content
        }
    }
}

struct AnalysisHistoryRow: View {
    @Environment(\.theme) private var theme
    let run: AnalysisRunSummary
    let showsTool: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            IconTile(systemImage: run.tool.systemImage, hue: TileHue.forTool(run.tool.rawValue), size: .small)
            VStack(alignment: .leading, spacing: 2) {
                Text(run.displayTitle)
                    .font(.brand(.subheadline, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .dynamicLineLimit(2)
                Text(run.metaLine(showsTool: showsTool))
                    .font(.brand(.caption))
                    .foregroundStyle(theme.textTertiary)
                    .dynamicLineLimit(2)
            }
            Spacer(minLength: 0)
            RowChevron()
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
