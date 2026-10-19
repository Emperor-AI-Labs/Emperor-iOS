import SwiftUI
import UIKit

/// The welcome after a first sign-in on this device: what do you practise as, then a couple of
/// details for drafts and filings.
///
/// The web asks the same two things the same way (`src/pages/Onboarding.jsx`). Both are optional by
/// design — "Skip for now" on the roles leaves the default role in force and asks nothing more,
/// and "Skip" on the details finishes without them — because an advocate who signed in to look at
/// a matter should reach the matter, not a form. When it is shown, and that it is shown only once,
/// is `RoleWelcome`'s; the two steps and the profile save are `RoleWelcomeFlow`'s; this lays it out.
///
/// A full screen rather than a sheet: it replaces the app until answered, which is what the web
/// does, and a sheet invites a swipe that would leave the question neither answered nor skipped.
struct RoleWelcomeView: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session

    /// The signed-in account: its name for the greeting, its profile for the details.
    let user: User
    /// The role chosen, or `nil` for "Skip for now".
    let onFinish: (PractitionerRole?) -> Void

    @State private var flow: RoleWelcomeFlow?

    var body: some View {
        Group {
            if let flow {
                switch flow.step {
                case .role:
                    RoleWelcomeRoleStep(flow: flow, name: user.name, onFinish: onFinish)
                case .details:
                    RoleWelcomeDetailsStep(flow: flow, onFinish: onFinish)
                }
            } else {
                Color.clear
            }
        }
        .background(theme.canvas.ignoresSafeArea())
        .onAppear {
            guard flow == nil else { return }
            let session = session
            flow = RoleWelcomeFlow(
                user: user, service: session.profile,
                adopt: { session.adoptProfile($0) })
        }
    }
}

/// The page both steps share: a scrolling body, and a bar of buttons pinned under it.
private struct RoleWelcomePage<Content: View, Bar: View>: View {
    @Environment(\.theme) private var theme

    @ViewBuilder var content: () -> Content
    @ViewBuilder var bar: () -> Bar

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                content()
                    .frame(maxWidth: 560)
                    .padding(.horizontal, Spacing.xxl)
                    .padding(.top, Spacing.xxxl)
                    .padding(.bottom, Spacing.xxl)
                    .frame(maxWidth: .infinity)
            }

            VStack(spacing: Spacing.xs + 2) {
                bar()
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, Spacing.xxl)
            .padding(.top, Spacing.md)
            .padding(.bottom, Spacing.md)
            .frame(maxWidth: .infinity)
            .background(theme.canvas)
            .overlay(alignment: .top) {
                Rectangle().fill(theme.separator).frame(height: 0.5)
            }
        }
    }
}

/// A quiet text button under the primary one: "Skip for now", "Skip", "Back".
private struct RoleWelcomeQuietButton: View {
    @Environment(\.theme) private var theme
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.brand(.subheadline))
                .foregroundStyle(theme.textSecondary)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Step 1: the role

private struct RoleWelcomeRoleStep: View {
    @Environment(\.theme) private var theme

    let flow: RoleWelcomeFlow
    let name: String?
    let onFinish: (PractitionerRole?) -> Void

    var body: some View {
        RoleWelcomePage {
            VStack(alignment: .leading, spacing: Spacing.xxl) {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Image("EmperorMark")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 32)
                        .padding(.bottom, Spacing.sm)
                        .accessibilityHidden(true)
                    // The brand face, as the sign-in screen just before it — this was a
                    // serif, the only one in the app.
                    Text(RoleWelcome.greeting(for: name))
                        .font(.brand(.title, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text(RoleWelcome.prompt)
                        .font(.brand(.callout))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: Spacing.sm + 2) {
                    ForEach(RoleWelcome.roles) { role in
                        option(role)
                    }
                }
            }
        } bar: {
            Button {
                flow.continueToDetails()
            } label: {
                Text(RoleWelcome.continueLabel)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.primaryAction)
            // As on the web: Continue needs a choice, and the way past without one is
            // "Skip for now", said as such.
            .disabled(!flow.canContinue)

            RoleWelcomeQuietButton(title: RoleWelcome.skipLabel) { onFinish(nil) }
        }
    }

    private func option(_ role: PractitionerRole) -> some View {
        let isSelected = flow.chosen == role
        return Button {
            flow.chosen = role
        } label: {
            RoleOptionLabel(role: role, isSelected: isSelected)
                .padding(Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .panel(tinted: isSelected)
                // The chosen card is ringed in the accent, so the choice reads at a glance and
                // not only by its wash.
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .strokeBorder(isSelected ? theme.accent : Color.clear, lineWidth: 1.5))
                .contentShape(Rectangle())
                .animation(.easeOut(duration: 0.15), value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        // The choice as a trait — VoiceOver says "Selected" in its own voice, and a test can ask
        // `isSelected` — rather than as a hint, which is read last and only after a pause.
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityHint(isSelected ? "" : "Choose this role")
        .accessibilityIdentifier("role-\(role.rawValue)")
    }
}

// MARK: - Step 2: the details

private struct RoleWelcomeDetailsStep: View {
    @Environment(\.theme) private var theme

    let flow: RoleWelcomeFlow
    let onFinish: (PractitionerRole?) -> Void

    private typealias Copy = RoleWelcomeFlow.Copy

    var body: some View {
        RoleWelcomePage {
            VStack(alignment: .leading, spacing: Spacing.xxl) {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text(Copy.detailsTitle)
                        .font(.brand(.title, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text(Copy.detailsPrompt)
                        .font(.brand(.callout))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: Spacing.lg) {
                    if flow.asksForName {
                        RoleWelcomeField(
                            label: Copy.nameLabel, placeholder: ProfileEditor.Copy.namePlaceholder,
                            text: Binding(get: { flow.profile.name }, set: { flow.profile.name = $0 }),
                            id: "welcome-name", contentType: .name)
                    }
                    RoleWelcomeField(
                        label: Copy.organizationLabel, placeholder: Copy.organizationPlaceholder,
                        text: Binding(get: { flow.profile.organization }, set: { flow.profile.organization = $0 }),
                        id: "welcome-organization", contentType: .organizationName)
                    RoleWelcomeField(
                        label: Copy.titleLabel, placeholder: Copy.titlePlaceholder,
                        text: Binding(get: { flow.profile.title }, set: { flow.profile.title = $0 }),
                        id: "welcome-title", contentType: .jobTitle)
                }
                .padding(Spacing.lg)
                .panel()

                if let error = flow.saveError {
                    Text(error)
                        .font(.brand(.footnote))
                        .foregroundStyle(theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("welcome-save-error")
                }
            }
        } bar: {
            Button {
                let flow = flow
                let chosen = flow.chosen
                Task {
                    if await flow.finishWithDetails() { onFinish(chosen) }
                }
            } label: {
                Group {
                    if flow.isSaving {
                        ProgressView()
                    } else {
                        Text(Copy.startLabel)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.primaryAction)
            .disabled(flow.isSaving)
            .accessibilityLabel(Copy.startLabel)

            HStack(spacing: Spacing.xl) {
                RoleWelcomeQuietButton(title: Copy.backLabel) { flow.back() }
                RoleWelcomeQuietButton(title: Copy.skipDetailsLabel) { onFinish(flow.chosen) }
            }
            .disabled(flow.isSaving)
        }
        .onChange(of: flow.saveError) { _, error in
            if let error { VoiceOver.announce(error) }
        }
    }
}

/// A labelled field, the label kept above the text as Edit profile's are.
private struct RoleWelcomeField: View {
    @Environment(\.theme) private var theme

    let label: String
    let placeholder: String
    let text: Binding<String>
    let id: String
    let contentType: UITextContentType

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(label)
                .font(.brand(.caption, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                .accessibilityHidden(true)
            TextField(label, text: text, prompt: Text(verbatim: placeholder).foregroundStyle(theme.textTertiary))
                .font(.brand(.body))
                .foregroundStyle(theme.textPrimary)
                .textContentType(contentType)
                .submitLabel(.done)
                .accessibilityLabel(label)
                .accessibilityIdentifier(id)
        }
    }
}
