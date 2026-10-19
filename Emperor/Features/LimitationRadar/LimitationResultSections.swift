import SwiftUI

/// The Radar's answer, as the web's result card lays it out: a tinted banner with the verdict and
/// the days line, the statutory framework, the findings, and the next steps. Every line is
/// worded by `LimitationAudit`; this only draws them.
struct LimitationResultSections: View {
    @Environment(\.theme) private var theme
    let audit: LimitationAudit

    var body: some View {
        Section {
            LimitationBanner(audit: audit)
        }
        .listRowBackground(theme.surface.overlay(bannerBackground))

        Section {
            Text(audit.statuteApplied)
                .font(.brand(.body))
                .foregroundStyle(theme.textPrimary)
            Text("Time runs from: \(audit.periodRunsFrom)")
                .font(.brand(.footnote))
                .foregroundStyle(theme.textSecondary)
            ValueRow("Last day to file", value: audit.lastDayLine)
            if let mediation = audit.mediationLine {
                ValueRow("Mediation excluded", value: mediation)
            }
            if let adjusted = audit.withExclusionLine {
                ValueRow("With the exclusion", value: adjusted)
            }
        } header: {
            SectionHeader(title: "Statutory framework")
        }
        .listRowBackground(theme.surface)

        Section {
            Text(audit.fatalFlaw)
                .font(.brand(.subheadline))
                .foregroundStyle(theme.textPrimary)
        } header: {
            SectionHeader(title: "Audit findings")
        }
        .listRowBackground(theme.surface)

        Section {
            ForEach(Array(audit.curativeStrategies.enumerated()), id: \.offset) { index, step in
                LimitationStepRow(number: index + 1, text: step)
            }
        } header: {
            SectionHeader(title: "Next steps")
        } footer: {
            Text(LimitationAudit.disclaimer)
                .font(.brand(.caption))
                .foregroundStyle(theme.textTertiary)
        }
        .listRowBackground(theme.surface)
    }

    private var bannerBackground: Color {
        switch audit.tone {
        case .emerald: return theme.successBg
        case .amber: return theme.warnBg
        case .red: return theme.dangerBg
        }
    }
}

/// The verdict and how many days it turns on, in the verdict's colour.
private struct LimitationBanner: View {
    @Environment(\.theme) private var theme
    let audit: LimitationAudit

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Label(audit.status, systemImage: symbol)
                .font(.brand(.headline))
                .foregroundStyle(tone)
            Label(audit.daysLine, systemImage: "clock")
                .font(.brand(.subheadline))
                .foregroundStyle(theme.textPrimary)
        }
        .padding(.vertical, Spacing.xs)
        .accessibilityElement(children: .combine)
    }

    private var tone: Color {
        switch audit.tone {
        case .emerald: return theme.success
        case .amber: return theme.warning
        case .red: return theme.danger
        }
    }

    private var symbol: String {
        switch audit.tone {
        case .emerald: return "checkmark.shield"
        case .amber: return "questionmark.diamond"
        case .red: return "exclamationmark.shield"
        }
    }
}

/// One numbered next step.
private struct LimitationStepRow: View {
    @Environment(\.theme) private var theme
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            Text("\(number)")
                .font(.brand(.caption, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(theme.accentText)
            Text(text)
                .font(.brand(.subheadline))
                .foregroundStyle(theme.textSecondary)
        }
    }
}
