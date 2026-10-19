import SwiftUI

/// Where an analysis screen leads, within the hub's own stack.
enum AnalysisRoute: Hashable {
    case tool(AnalysisJobTool)
    case history
    /// A saved run, opened from the history.
    case saved(AnalysisJobTool, runID: String)
}

/// The server-run analysis tools — Devil's Advocate, Doc Index and List of Dates — and the
/// history of every run, as the web's Analysis hub has them.
///
/// - Important: owns its own `NavigationStack`, because You → Tools **presents** rather than
///   pushes; see `ToolDestination`.
struct AnalysisHubView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var path: [AnalysisRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    ForEach(AnalysisJobTool.allCases) { tool in
                        NavigationLink(value: AnalysisRoute.tool(tool)) {
                            AnalysisToolCard(tool: tool)
                        }
                    }
                } header: {
                    SectionHeader(title: "Analysis tools")
                } footer: {
                    Text("Pick documents from My Files and get a report, an index or a list of dates.")
                        .font(.brand(.caption))
                        .foregroundStyle(theme.textTertiary)
                }
                .listRowBackground(theme.surface)

                Section {
                    NavigationLink(value: AnalysisRoute.history) {
                        IconRowLabel(title: "History", systemImage: "clock.arrow.circlepath")
                    }
                } footer: {
                    Text("Every finished run is kept here, up to 50 for each tool.")
                        .font(.brand(.caption))
                        .foregroundStyle(theme.textTertiary)
                }
                .listRowBackground(theme.surface)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.groupedBackground)
            .navigationTitle("Analysis tools")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: AnalysisRoute.self) { route in
                destination(route)
            }
        }
    }

    @ViewBuilder
    private func destination(_ route: AnalysisRoute) -> some View {
        switch route {
        case .tool(let tool):
            AnalysisToolView(tool: tool)
        case .history:
            AnalysisHistoryView(tool: nil) { run in
                path.append(.saved(run.tool, runID: run.id))
            }
        case .saved(let tool, let runID):
            AnalysisToolView(tool: tool, openingRunID: runID)
        }
    }
}

/// One tool on the hub: its tile, its name and the web's line about it.
struct AnalysisToolCard: View {
    @Environment(\.theme) private var theme
    let tool: AnalysisJobTool

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            IconTile(systemImage: tool.systemImage, hue: TileHue.forTool(tool.rawValue))
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(tool.title)
                    .font(.brand(.body, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Text(tool.blurb)
                    .font(.brand(.footnote))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, Spacing.xs)
        .accessibilityElement(children: .combine)
    }
}
