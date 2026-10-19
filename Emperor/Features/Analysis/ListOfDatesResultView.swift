import SwiftUI

/// List of Dates on a phone: the matter, the limitation line, what is coming up, the rules and
/// orders as they came, then the events year by year with whose side each is on, and the
/// "In sum" paragraph.
struct ListOfDatesResultView: View {
    @Environment(\.theme) private var theme
    let list: ListOfDatesResult

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            ListOfDatesHeader(list: list)
            if !list.upcoming.isEmpty {
                AnalysisSectionTitle(title: "Coming up")
                ForEach(list.upcoming) { entry in
                    ListOfDatesEntryRow(list: list, entry: entry, highlighted: true)
                }
            }
            if !list.rules.isEmpty {
                AnalysisSectionTitle(
                    title: "Rules, contract terms and orders",
                    detail: "\(list.rules.count)",
                    subtitle: "As they came.")
                ForEach(list.rules) { entry in
                    ListOfDatesEntryRow(list: list, entry: entry)
                }
            }
            AnalysisSectionTitle(title: "What happened", detail: "\(list.events.count) events")
            ForEach(list.eventsByYear) { group in
                ListOfDatesYear(list: list, group: group)
            }
            ListOfDatesInSum(list: list)
        }
    }
}

struct ListOfDatesHeader: View {
    @Environment(\.theme) private var theme
    let list: ListOfDatesResult

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(list.matter.title.isEmpty ? "List of Dates" : list.matter.title)
                .font(.display(size: 24, relativeTo: .title2))
                .foregroundStyle(theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            if !list.matterTail.isEmpty {
                Text(list.matterTail)
                    .font(.brand(.subheadline))
                    .foregroundStyle(theme.textSecondary)
            }
            Text(list.summaryLine)
                .font(.brand(.footnote, weight: .semibold))
                .foregroundStyle(theme.textTertiary)
            if let limitation = list.limitation {
                ListOfDatesLimitation(limitation: limitation)
            }
        }
    }
}

struct ListOfDatesLimitation: View {
    @Environment(\.theme) private var theme
    let limitation: ListOfDatesResult.Limitation

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Label {
                Text("Limitation watch").bold() + Text(" · \(limitation.headline)")
            } icon: {
                Image(systemName: "hourglass")
                    .foregroundStyle(theme.warning)
            }
            .font(.brand(.footnote))
            .foregroundStyle(theme.textPrimary)
            if !limitation.note.isEmpty {
                Text(limitation.note)
                    .font(.brand(.caption))
                    .foregroundStyle(theme.textSecondary)
            }
            Text("Check with your advocate.")
                .font(.brand(.caption))
                .foregroundStyle(theme.textTertiary)
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.warnBg, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// One year of events.
struct ListOfDatesYear: View {
    @Environment(\.theme) private var theme
    let list: ListOfDatesResult
    let group: ListOfDatesResult.YearGroup

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(group.year)
                .font(.brand(.footnote, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(theme.textTertiary)
                .accessibilityAddTraits(.isHeader)
            ForEach(group.entries) { entry in
                ListOfDatesEntryRow(list: list, entry: entry)
            }
        }
    }
}

/// One rule or event: its date, whose side, and the line with its bold terms.
struct ListOfDatesEntryRow: View {
    @Environment(\.theme) private var theme
    let list: ListOfDatesResult
    let entry: ListOfDatesResult.Entry
    var highlighted = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            AdaptiveStack(verticalAlignment: .firstTextBaseline, spacing: Spacing.sm) {
                Text(entry.dateLabel)
                    .font(.brand(.footnote, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(highlighted ? theme.accentText : theme.textPrimary)
                StatusPill(text: list.sideTag(entry.cat), tone: Self.tone(entry.cat))
            }
            RichText.text(entry.runs)
                .font(.brand(.subheadline))
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(tinted: highlighted)
        .accessibilityElement(children: .combine)
    }

    static func tone(_ category: ListOfDatesResult.Category) -> StatusPill.Tone {
        switch category {
        case .rules: return .accent
        case .ours: return .warning
        case .others: return .success
        case .adverse: return .danger
        }
    }
}

struct ListOfDatesInSum: View {
    @Environment(\.theme) private var theme
    let list: ListOfDatesResult

    var body: some View {
        (Text("In sum: ").bold() + RichText.text(list.inSumRuns))
            .font(.brand(.subheadline))
            .foregroundStyle(theme.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel()
            .textSelection(.enabled)
    }
}
