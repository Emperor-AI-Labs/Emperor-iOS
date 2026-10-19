import SwiftUI

/// The Devil's Advocate report on a phone, in the web's order: the verdict, the case in one
/// minute, the weak spots, the questions to expect, the missing papers, the authorities against,
/// and the checklist.
struct DevilsAdvocateResultView: View {
    let report: DevilsAdvocateResult

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            DevilsAdvocateVerdict(report: report)
            AnalysisNote(
                title: "A first draft to check, not advice.",
                text: "This report was written by an AI from your documents. It can misread a clause, slip on a figure or assume a fact that is not in your papers. Check every point against the documents and your own judgment before you rely on it.")
            DevilsAdvocateOneMinute(paragraphs: report.oneMinute)
            DevilsAdvocateCategories(report: report)
            DevilsAdvocateWeakSpots(spots: report.weakSpots)
            DevilsAdvocateQuestions(report: report)
            DevilsAdvocateDocGaps(gaps: report.docGaps)
            DevilsAdvocateAuthorities(authorities: report.authorities)
            DevilsAdvocateChecklist(items: report.checklist)
        }
    }
}

// MARK: - The verdict

struct DevilsAdvocateVerdict: View {
    @Environment(\.theme) private var theme
    let report: DevilsAdvocateResult

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("DEVIL'S ADVOCATE REPORT")
                .font(.brand(size: 10.5, weight: .bold, relativeTo: .caption2))
                .tracking(0.8)
                .foregroundStyle(theme.textTertiary)
            Text(report.matter.title.isEmpty ? "Your matter" : report.matter.title)
                .font(.display(size: 24, relativeTo: .title2))
                .foregroundStyle(theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            ForEach(report.matterFacts, id: \.label) { fact in
                ValueRow(fact.label, value: fact.value)
                    .font(.brand(.footnote))
            }
            DevilsAdvocateGauge(report: report)
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }
}

/// "Moderate exposure", the score on a three-band bar, and the spots by severity.
struct DevilsAdvocateGauge: View {
    @Environment(\.theme) private var theme
    let report: DevilsAdvocateResult

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("OVERALL EXPOSURE")
                .font(.brand(size: 10.5, weight: .bold, relativeTo: .caption2))
                .tracking(0.8)
                .foregroundStyle(theme.textTertiary)
            Text("\(report.band.rawValue) exposure")
                .font(.display(size: 28, relativeTo: .title))
                .foregroundStyle(theme.textPrimary)
            Text(report.severityLine)
                .font(.brand(.footnote))
                .foregroundStyle(theme.textSecondary)
            ProgressView(value: Double(report.exposureScore), total: 100)
                .tint(tint)
            HStack {
                Text("Low")
                Spacer()
                Text("Moderate")
                Spacer()
                Text("High")
            }
            .font(.brand(.caption2))
            .foregroundStyle(theme.textTertiary)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Exposure \(report.exposureScore) out of 100, \(report.band.rawValue). \(report.severityLine)."))
    }

    private var tint: Color {
        switch report.band {
        case .low: return theme.success
        case .moderate: return theme.warning
        case .high: return theme.danger
        }
    }
}

struct DevilsAdvocateOneMinute: View {
    @Environment(\.theme) private var theme
    let paragraphs: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            AnalysisSectionTitle(title: "In one minute")
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, paragraph in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                    Text("\(index + 1)")
                        .font(.brand(.footnote, weight: .bold))
                        .foregroundStyle(theme.accentText)
                    Text(paragraph)
                        .font(.brand(.subheadline))
                        .foregroundStyle(theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Where the weak spots sit — one bar per category, heaviest first.
struct DevilsAdvocateCategories: View {
    @Environment(\.theme) private var theme
    let report: DevilsAdvocateResult

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            AnalysisSectionTitle(title: "The picture at a glance")
            let heaviest = max(1, report.categoryRows.first?.weight ?? 1)
            ForEach(report.categoryRows) { row in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(row.category.label)
                        Spacer()
                        Text("\(row.count)")
                            .monospacedDigit()
                    }
                    .font(.brand(.footnote, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    ProgressView(value: Double(row.weight), total: Double(heaviest))
                        .tint(row.serious > 0 ? theme.danger : row.moderate > 0 ? theme.warning : theme.accent)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("\(row.category.label): \(row.serious) serious, \(row.moderate) moderate, \(row.minor) minor"))
            }
        }
    }
}

// MARK: - Weak spots

struct DevilsAdvocateWeakSpots: View {
    let spots: [DevilsAdvocateResult.WeakSpot]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            AnalysisSectionTitle(
                title: "Your weak spots, ranked", detail: "\(spots.count)",
                subtitle: "Most serious first. Open one to see why it hurts, where it sits in your papers, what they will say and how to close the gap.")
            ForEach(spots) { spot in
                DevilsAdvocateSpotCard(spot: spot, startsOpen: spot.id == spots.first?.id)
            }
        }
    }
}

struct DevilsAdvocateSpotCard: View {
    @Environment(\.theme) private var theme
    let spot: DevilsAdvocateResult.WeakSpot
    let startsOpen: Bool

    @State private var isOpen: Bool?

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { isOpen ?? startsOpen }, set: { isOpen = $0 })) {
            VStack(alignment: .leading, spacing: Spacing.md) {
                part("Why it hurts", spot.why)
                if !spot.where.isEmpty { part("Where in your papers", spot.where.joined(separator: " · ")) }
                if !spot.say.isEmpty { part("What they will say", "“\(spot.say)”") }
                part("How to close the gap", spot.fix)
            }
            .padding(.top, Spacing.sm)
        } label: {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.xs) {
                    StatusPill(text: "#\(spot.id) \(spot.severity.label)", tone: Self.tone(spot.severity))
                    StatusPill(text: spot.category.label)
                }
                Text(spot.title)
                    .font(.brand(.subheadline, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .multilineTextAlignment(.leading)
            }
        }
        .tint(theme.textSecondary)
        .padding(Spacing.md)
        .background(
            Self.tone(spot.severity) == .danger ? theme.dangerBg.opacity(0.5) : theme.surface,
            in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(theme.separator, lineWidth: 1))
    }

    private func part(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.brand(size: 10.5, weight: .bold, relativeTo: .caption2))
                .tracking(0.6)
                .foregroundStyle(theme.textTertiary)
            Text(text)
                .font(.brand(.subheadline))
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    static func tone(_ severity: DevilsAdvocateResult.Severity) -> StatusPill.Tone {
        switch severity {
        case .serious: return .danger
        case .moderate: return .warning
        case .minor: return .accent
        }
    }
}

// MARK: - Questions

struct DevilsAdvocateQuestions: View {
    @Environment(\.theme) private var theme
    let report: DevilsAdvocateResult

    @State private var filter: DevilsAdvocateResult.Readiness?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            AnalysisSectionTitle(
                title: "Questions you should expect", detail: "\(report.questions.count)",
                subtitle: "What the other side's lawyer is likely to ask, why, and the best answer or document to have in hand.")
            if report.questions.isEmpty {
                AnalysisEmptyLine(text: "No likely questions were listed.")
            } else {
                Picker("Readiness", selection: $filter) {
                    Text("All \(report.questions.count)").tag(DevilsAdvocateResult.Readiness?.none)
                    ForEach(DevilsAdvocateResult.Readiness.allCases, id: \.self) { readiness in
                        Text("\(readiness.label) \(report.count(readiness))").tag(Optional(readiness))
                    }
                }
                .pickerStyle(.segmented)
                ForEach(Array(report.questions(filter).enumerated()), id: \.offset) { _, question in
                    DevilsAdvocateQuestionCard(question: question)
                }
            }
        }
    }
}

struct DevilsAdvocateQuestionCard: View {
    @Environment(\.theme) private var theme
    let question: DevilsAdvocateResult.Question

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            AdaptiveStack(verticalAlignment: .firstTextBaseline, spacing: Spacing.sm) {
                Text("“\(question.q)”")
                    .font(.brand(.subheadline, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                StatusPill(text: question.readiness.label, tone: Self.tone(question.readiness))
            }
            if !question.why.isEmpty {
                Text("Why they ask: \(question.why)")
                    .font(.brand(.footnote))
                    .foregroundStyle(theme.textSecondary)
            }
            if !question.answer.isEmpty {
                Text("Your best answer: \(question.answer)\(question.spot.map { " (weak spot #\($0))" } ?? "")")
                    .font(.brand(.footnote))
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
        .accessibilityElement(children: .combine)
    }

    static func tone(_ readiness: DevilsAdvocateResult.Readiness) -> StatusPill.Tone {
        switch readiness {
        case .ready: return .success
        case .work: return .warning
        case .gap: return .danger
        }
    }
}

// MARK: - Papers and authorities

struct DevilsAdvocateDocGaps: View {
    @Environment(\.theme) private var theme
    let gaps: [DevilsAdvocateResult.DocGap]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            AnalysisSectionTitle(
                title: "Papers you are missing", detail: "\(gaps.count)",
                subtitle: "Documents that would close a weak spot, who holds them and how to get them.")
            if gaps.isEmpty {
                AnalysisEmptyLine(text: "No missing papers were identified.")
            }
            ForEach(Array(gaps.enumerated()), id: \.offset) { _, gap in
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(gap.doc)
                        .font(.brand(.subheadline, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                    if !gap.who.isEmpty { ValueRow("Who has it", value: gap.who) }
                    if !gap.how.isEmpty { ValueRow("How to get it", value: gap.how) }
                    if !gap.when.isEmpty { ValueRow("By when", value: gap.when) }
                    if let spot = gap.spot { ValueRow("Closes", value: "Weak spot #\(spot)") }
                }
                .font(.brand(.footnote))
                .padding(Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .panel()
            }
        }
    }
}

struct DevilsAdvocateAuthorities: View {
    @Environment(\.theme) private var theme
    let authorities: [DevilsAdvocateResult.Authority]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            AnalysisSectionTitle(
                title: "Authorities that cut against you", detail: "\(authorities.count)",
                subtitle: "Decisions the other side is likely to cite, what they say in general terms, and a way to answer each.")
            if authorities.isEmpty {
                AnalysisEmptyLine(text: "No adverse authorities were listed.")
            }
            ForEach(Array(authorities.enumerated()), id: \.offset) { _, authority in
                DevilsAdvocateAuthorityCard(authority: authority)
            }
            AnalysisNote(
                title: "Verify before citing.",
                text: "These are general descriptions written by an AI, not citations. Anything marked Verify was not found in your papers. Read the judgment, check it is still good law, and confirm the exact holding and paragraph before relying on it in court.")
        }
    }
}

struct DevilsAdvocateAuthorityCard: View {
    @Environment(\.theme) private var theme
    let authority: DevilsAdvocateResult.Authority

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            (Text("See e.g. ").foregroundStyle(theme.textTertiary) + Text(authority.name))
                .font(.brand(.subheadline, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if !authority.whereLine.isEmpty {
                Text(authority.whereLine)
                    .font(.brand(.caption))
                    .foregroundStyle(theme.textTertiary)
            }
            if authority.verify {
                StatusPill(text: "Verify before citing: not found in your papers", tone: .warning, systemImage: "exclamationmark.triangle")
            }
            if !authority.holds.isEmpty {
                Text("What it generally holds: \(authority.holds)")
                    .font(.brand(.footnote))
                    .foregroundStyle(theme.textSecondary)
            }
            if !authority.distinguish.isEmpty {
                Text("How to distinguish it: \(authority.distinguish)")
                    .font(.brand(.footnote))
                    .foregroundStyle(theme.textPrimary)
            }
            if let against = authority.against {
                Text("Hurts weak spot #\(against)")
                    .font(.brand(.caption, weight: .semibold))
                    .foregroundStyle(theme.danger)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Checklist

/// Ticks live on this screen only, as on the web — they reset with each run.
struct DevilsAdvocateChecklist: View {
    @Environment(\.theme) private var theme
    let items: [DevilsAdvocateResult.ChecklistItem]

    @State private var ticked: Set<String>?

    var body: some View {
        let done = ticked ?? Set(items.filter(\.done).map(\.id))
        VStack(alignment: .leading, spacing: Spacing.sm) {
            AnalysisSectionTitle(
                title: "Your preparation checklist",
                detail: items.isEmpty ? nil : "\(done.count) of \(items.count) done",
                subtitle: "Tick items off as you close them.")
            if items.isEmpty {
                AnalysisEmptyLine(text: "No checklist items were suggested.")
            }
            ForEach(items) { item in
                Button {
                    var next = done
                    if next.contains(item.id) { next.remove(item.id) } else { next.insert(item.id) }
                    ticked = next
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                        Image(systemName: done.contains(item.id) ? "checkmark.square.fill" : "square")
                            .foregroundStyle(done.contains(item.id) ? theme.success : theme.textTertiary)
                            .accessibilityHidden(true)
                        Text(item.text)
                            .font(.brand(.subheadline))
                            .foregroundStyle(theme.textPrimary)
                            .strikethrough(done.contains(item.id))
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(done.contains(item.id) ? .isSelected : [])
            }
        }
    }
}
