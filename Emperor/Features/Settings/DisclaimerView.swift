import SwiftUI

/// The legal-advice disclaimer, shown once before the app is used and available afterwards
/// from Settings.
///
/// Presented as a gate rather than a dismissible sheet: this is a product that answers
/// questions about live matters in a voice that reads as advice, and "I understand" should be
/// a deliberate act rather than something swiped past.
struct DisclaimerGateView: View {
    @Environment(\.theme) private var theme
    let onAcknowledge: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    IconCircle(systemImage: "exclamationmark.shield")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, Spacing.xxxl)

                    // The brand face, as every other heading in the app — this one was a serif,
                    // the only one, on the first screen anybody sees.
                    Text(Disclaimer.title)
                        .font(.brand(.title2, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .accessibilityAddTraits(.isHeader)

                    Text(Disclaimer.body)
                        .font(.brand(.callout))
                        .foregroundStyle(theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Spacing.xl)
                        .panel()
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, Spacing.xxl)
                .padding(.bottom, Spacing.xxl)
                .frame(maxWidth: .infinity)
            }

            Button(action: onAcknowledge) {
                Text(Disclaimer.acknowledgement)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.primaryAction)
            .frame(maxWidth: 560)
            .padding(.horizontal, Spacing.xxl)
            .padding(.top, Spacing.sm)
            .padding(.bottom, Spacing.lg)
        }
        .background(theme.canvas.ignoresSafeArea())
    }
}

/// The same text, as a reference page rather than a gate.
struct DisclaimerReferenceView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            Text(Disclaimer.body)
                .font(.brand(.callout))
                .foregroundStyle(theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.xl)
                .panel()
                .frame(maxWidth: 640)
                .padding(Spacing.lg)
                .frame(maxWidth: .infinity)
        }
        .background(theme.canvas)
        .navigationTitle(Disclaimer.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
