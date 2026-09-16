import SwiftUI

/// Choosing what you practise as.
///
/// A pushed list rather than a menu or a segmented control: there are seven of these and each one
/// needs a sentence to tell it from its neighbours — Senior Counsel and Litigator are not
/// distinguishable from two words, and picking the wrong one quietly hands somebody the wrong
/// toolkit for the rest of their use of the app.
struct RolePickerView: View {
    @Environment(\.theme) private var theme
    @Environment(\.practice) private var practice
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                ForEach(PractitionerRole.allCases) { role in
                    row(role)
                }
            } footer: {
                // Said plainly, because the alternative reading — that choosing wrong locks a
                // tool away — is the one that would stop somebody choosing honestly.
                Text("Your role decides which tools are offered first. Every tool stays available to every role.")
                    .font(.brand(.caption))
                    .foregroundStyle(theme.textSecondary)
            }
            .listRowBackground(theme.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.canvas)
        .navigationTitle("Practising as")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ role: PractitionerRole) -> some View {
        let isSelected = practice.role == role
        return Button {
            practice.select(role)
            dismiss()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: role.systemImage)
                    .font(.brand(.title3))
                    .foregroundStyle(isSelected ? theme.accentText : theme.textSecondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(role.label)
                        .font(.brand(.subheadline, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                    Text(role.tagline)
                        .font(.brand(.caption))
                        .foregroundStyle(theme.textSecondary)
                    Text(role.detail)
                        .font(.brand(.caption2))
                        .foregroundStyle(theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.brand(.footnote, weight: .semibold))
                        .foregroundStyle(theme.accentText)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(isSelected ? "Selected" : "Choose this role")
    }
}
