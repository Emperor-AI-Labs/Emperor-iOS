import SwiftUI

/// "Plan & usage": the account's plan, its standing, this month's allowances — and, where the
/// build allows it, the way to the plans page.
///
/// The app takes no money. "View plans" opens the web app's plans page in the browser, where the
/// plan is bought on the same account; coming back reads the account and the allowances again,
/// so the new plan shows here without signing in again. See `WebPlans` for the build switch that
/// removes the button.
struct PlanUsageSection: View {
    @Environment(Session.self) private var session
    @Environment(\.theme) private var theme
    @Environment(\.scenePhase) private var scenePhase

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

            if session.webPlans.isOffered {
                ViewPlansButton(style: .row)
            }
        } header: {
            SectionHeader(title: "Plan & usage")
        } footer: {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                if let line = model?.renewalLine {
                    Text(line)
                }
                if session.webPlans.isOffered {
                    Text(WebPlans.settingsNote)
                }
            }
            .font(.brand(.caption))
            .foregroundStyle(theme.textSecondary)
        }
        .listRowBackground(theme.surface)
        .task {
            if model == nil { model = AccountUsageViewModel(service: session.usage) }
            await model?.load()
        }
        // Back from the plans page in the browser: the allowances may be a new plan's.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { reload() }
        }
        .onChange(of: session.currentUser?.planLabel) { _, _ in reload() }
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
            AdaptiveStack(verticalAlignment: .firstTextBaseline, spacing: Spacing.xs) {
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
            // The bar's colour, said in words — for VoiceOver, which reads this row as one, and
            // for anyone who cannot tell the red from the amber.
            if let status = meter.statusLabel {
                Label(status, systemImage: meter.isExhausted
                      ? "exclamationmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.brand(.caption, weight: .semibold))
                    .foregroundStyle(meter.isExhausted ? theme.danger : theme.warning)
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
