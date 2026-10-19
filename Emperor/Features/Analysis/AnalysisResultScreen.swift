import SwiftUI

/// A finished result: where it came from, then the tool's own view of it.
struct AnalysisResultScreen: View {
    @Environment(\.theme) private var theme
    let outcome: AnalysisOutcome
    let onAgain: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.lg) {
                AnalysisProvenanceStrip(outcome: outcome, onAgain: onAgain)
                switch outcome.result {
                case .docIndex(let index):
                    DocIndexResultView(index: index)
                case .listOfDates(let list):
                    ListOfDatesResultView(list: list)
                case .devilsAdvocate(let report):
                    DevilsAdvocateResultView(report: report)
                }
            }
            .padding(Spacing.gutter)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

/// "From your history · 16 Oct" or "Read 3 documents: …", with the way back to the intake.
struct AnalysisProvenanceStrip: View {
    @Environment(\.theme) private var theme
    let outcome: AnalysisOutcome
    let onAgain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if outcome.isFromHistory {
                Label(historyLine, systemImage: "clock")
                    .font(.brand(.footnote, weight: .semibold))
                    .foregroundStyle(theme.accentText)
            }
            if !outcome.provenance.isEmpty {
                Text(outcome.provenance)
                    .font(.brand(.caption))
                    .foregroundStyle(theme.textTertiary)
            }
            Button(outcome.isFromHistory ? "Run again with new documents" : "Start over", action: onAgain)
                .font(.brand(.footnote, weight: .semibold))
                .buttonStyle(.borderless)
                .foregroundStyle(theme.accentText)
        }
    }

    private var historyLine: String {
        guard let savedAt = outcome.savedAt else { return "From your history" }
        return "From your history · \(DisplayText.relative(savedAt))"
    }
}

/// A heading for one part of a result, with an optional count.
struct AnalysisSectionTitle: View {
    @Environment(\.theme) private var theme
    let title: String
    var detail: String?
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            AdaptiveStack(verticalAlignment: .firstTextBaseline, spacing: Spacing.sm) {
                Text(title)
                    .font(.display(size: 21, relativeTo: .title3))
                    .foregroundStyle(theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                if let detail {
                    Text(detail)
                        .font(.brand(.footnote, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)
                }
            }
            if let subtitle {
                Text(subtitle)
                    .font(.brand(.footnote))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, Spacing.sm)
    }
}

/// A short, quiet line where a part of a result is empty.
struct AnalysisEmptyLine: View {
    @Environment(\.theme) private var theme
    let text: String

    var body: some View {
        Text(text)
            .font(.brand(.footnote))
            .foregroundStyle(theme.textTertiary)
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel()
    }
}

/// A note in the warning wash — "A first draft to check, not advice".
struct AnalysisNote: View {
    @Environment(\.theme) private var theme
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: "info.circle")
                .foregroundStyle(theme.warning)
                .accessibilityHidden(true)
            (Text(title + " ").bold() + Text(text))
                .font(.brand(.footnote))
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.warnBg, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// `**bold**` runs as one `Text`.
enum RichText {
    static func text(_ runs: [RichRun]) -> Text {
        runs.reduce(Text("")) { partial, run in
            partial + (run.bold ? Text(run.text).bold() : Text(run.text))
        }
    }
}
