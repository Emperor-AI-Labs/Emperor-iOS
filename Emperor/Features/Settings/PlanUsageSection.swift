import SwiftUI

/// "Plan & usage": the account's plan, its standing, and this month's allowances.
///
/// **Informational only — there is nothing to buy here and nothing that points to where one
/// could.** The app takes no money, and a call to action leading to a purchase made elsewhere is
/// what App Review rejects. What this section is for is the question a refusal raises: how many
/// questions are left, and when do they renew.
struct PlanUsageSection: View {
    @Environment(Session.self) private var session
    @Environment(\.theme) private var theme

    @State private var model: AccountUsageViewModel?

    var body: some View {
        Section {
            LabeledContent("Plan") {
                Text(planLabel).foregroundStyle(theme.textPrimary)
            }

            if let standing = session.standing {
                standingRow(standing)
            }

            if let model {
                if let usage = model.usage {
                    ForEach(model.visibleMeters) { meter in
                        UsageMeterRow(meter: meter, isMetered: usage.isMetered)
                    }
                } else if let failure = model.state.failure {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Usage couldn't be loaded.")
                            .font(.brand(.subheadline, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                        Text(failure.message)
                            .font(.brand(.footnote))
                            .foregroundStyle(theme.textSecondary)
                        if failure.isRetryable {
                            Button("Try again") { reload() }
                                .font(.brand(.footnote, weight: .semibold))
                        }
                    }
                    .padding(.vertical, 4)
                } else {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading usage…")
                            .font(.brand(.footnote))
                            .foregroundStyle(theme.textSecondary)
                    }
                }
            }
        } header: {
            SectionHeader(title: "Plan & usage")
        } footer: {
            if let line = model?.renewalLine {
                Text(line)
                    .font(.brand(.caption))
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .listRowBackground(theme.surface)
        .task {
            if model == nil { model = AccountUsageViewModel(service: session.usage) }
            await model?.load()
        }
    }

    private var planLabel: String {
        model?.usage?.planLabel ?? session.currentUser?.planLabel ?? "—"
    }

    private func standingRow(_ standing: Session.Standing) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(standing == .suspended ? "Account paused" : "No active plan")
                    .font(.brand(.subheadline, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Text(standing == .suspended
                     ? "New work can't be started. Your history and documents are still here."
                     : "New questions and uploads are paused. Everything already in the account can still be opened and exported.")
                    .font(.brand(.footnote))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: standing == .suspended ? "pause.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(theme.warning)
        }
        .padding(.vertical, 2)
    }

    private func reload() {
        let model = model
        Task { await model?.load() }
    }
}

/// One allowance: what it is, how much is used, and a bar when there is a limit to measure.
struct UsageMeterRow: View {
    @Environment(\.theme) private var theme

    let meter: AccountUsage.Meter
    let isMetered: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm - 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(meter.title)
                    .font(.brand(.subheadline))
                    .foregroundStyle(theme.textPrimary)
                Spacer(minLength: 8)
                Text(meter.summary)
                    .font(.brand(.subheadline, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(meter.isExhausted ? theme.danger : theme.textSecondary)
            }
            if let fraction = meter.fraction {
                MeterBar(fraction: fraction, color: barColour)
                    .padding(.top, Spacing.xxs)
            }
            if let note = meter.note, isMetered {
                Text(note)
                    .font(.brand(.caption))
                    .foregroundStyle(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, Spacing.xs + 2)
        .accessibilityElement(children: .combine)
    }

    private var barColour: Color {
        if meter.isExhausted { return theme.danger }
        if meter.isRunningLow { return theme.warning }
        return theme.accent
    }
}
