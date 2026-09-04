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
                VStack(alignment: .leading, spacing: 20) {
                    Image(systemName: "exclamationmark.shield")
                        .font(.system(size: 44))
                        .foregroundStyle(theme.accentText)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 32)

                    Text(Disclaimer.title)
                        .font(.system(.title, design: .serif, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .center)

                    Text(Disclaimer.body)
                        .font(.brand(.callout))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
            }

            Button(action: onAcknowledge) {
                Text(Disclaimer.acknowledgement)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 28)
            .padding(.bottom, 16)
        }
    }
}

/// The same text, as a reference page rather than a gate.
struct DisclaimerReferenceView: View {
    var body: some View {
        ScrollView {
            Text(Disclaimer.body)
                .font(.brand(.callout))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(Disclaimer.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
