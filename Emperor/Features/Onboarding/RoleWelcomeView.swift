import SwiftUI

/// The one question asked after a first sign-in on this device: what do you practise as?
///
/// The web asks it the same way, on one screen, before anything else (`src/pages/Onboarding.jsx`).
/// It is optional by design — "Skip for now" leaves the default role in force, because an
/// advocate who signed in to look at a matter should reach the matter, not a form. When it is
/// shown, and that it is shown only once, is `RoleWelcome`'s; this lays it out.
///
/// A full screen rather than a sheet: it replaces the app until answered, which is what the web
/// does, and a sheet invites a swipe that would leave the question neither answered nor skipped.
struct RoleWelcomeView: View {
    @Environment(\.theme) private var theme

    /// The account's name, for the greeting.
    let name: String?
    /// The role chosen, or `nil` for "Skip for now".
    let onFinish: (PractitionerRole?) -> Void

    @State private var chosen: PractitionerRole?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(RoleWelcome.greeting(for: name))
                            .font(.system(.title, design: .serif, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                            .accessibilityAddTraits(.isHeader)
                        Text(RoleWelcome.prompt)
                            .font(.brand(.callout))
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(spacing: 10) {
                        ForEach(RoleWelcome.roles) { role in
                            option(role)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 32)
                .padding(.bottom, 24)
            }

            VStack(spacing: 6) {
                Button {
                    onFinish(chosen)
                } label: {
                    Text(RoleWelcome.continueLabel)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.primaryAction)
                // As on the web: Continue needs a choice, and the way past without one is
                // "Skip for now", said as such.
                .disabled(chosen == nil)

                Button(RoleWelcome.skipLabel) {
                    onFinish(nil)
                }
                .font(.brand(.subheadline))
                .foregroundStyle(theme.textSecondary)
                .padding(.vertical, 8)
            }
            .padding(.horizontal, 24)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .background(theme.canvas)
        }
        .background(theme.canvas.ignoresSafeArea())
    }

    private func option(_ role: PractitionerRole) -> some View {
        let isSelected = chosen == role
        return Button {
            chosen = role
        } label: {
            RoleOptionLabel(role: role, isSelected: isSelected)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .panel(tinted: isSelected)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(isSelected ? "Selected" : "Choose this role")
        .accessibilityIdentifier("role-\(role.rawValue)")
    }
}
