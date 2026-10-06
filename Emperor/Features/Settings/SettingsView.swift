import SwiftUI

/// Role, appearance, account, usage, security, reference and sign-out.
///
/// The role selector leads, because it is the setting that changes the most about the app — the
/// toolkit, the home screen, what the model is told — and it is the one people switch.
///
/// The app takes no money. The plan and its allowances are shown (`PlanUsageSection`), and where
/// the build allows it a "View plans" button opens the web app in the browser to buy one there —
/// see `WebPlans`.
struct SettingsView: View {
    @Environment(Session.self) private var session
    @Environment(\.theme) private var theme
    @Environment(\.practice) private var practice
    @Environment(\.dismiss) private var dismiss

    @State private var isConfirmingSignOut = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        RolePickerView()
                    } label: {
                        RoleSelectorLabel(role: practice.role)
                    }
                    .accessibilityIdentifier("Role selector")
                } header: {
                    SectionHeader(title: "Role")
                } footer: {
                    footnote("\(practice.role.detail) Saved to your account, so the web app opens in the same role.")
                }
                .listRowBackground(theme.surface)

                Section {
                    Picker("Appearance", selection: Binding(
                        get: { theme.preference },
                        set: { theme.select($0) }
                    )) {
                        ForEach(ThemePreference.allCases, id: \.self) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    SectionHeader(title: "Appearance")
                } footer: {
                    footnote("Emperor opens dark by default, matching the web dashboard.")
                }
                .listRowBackground(theme.surface)

                // Hearing reminders on this device, and the account's daily email — see
                // `NotificationSettingsView`.
                Section {
                    NavigationLink {
                        NotificationSettingsView()
                    } label: {
                        IconRowLabel(title: "Notifications", systemImage: "bell", hue: .violet)
                    }
                    .accessibilityIdentifier("notifications-settings")
                } footer: {
                    footnote("Hearing reminders on this device, and the daily cause-list email.")
                }
                .listRowBackground(theme.surface)

                if let user = session.currentUser {
                    Section {
                        LabeledContent("Name") {
                            Text(user.name ?? "—").foregroundStyle(theme.textPrimary)
                        }
                        LabeledContent("Email") {
                            Text(user.email ?? "—").foregroundStyle(theme.textPrimary)
                        }
                        if let phone = user.phone, !phone.isEmpty {
                            LabeledContent("Mobile") {
                                Text("+91 " + IndianMobile.local(phone))
                                    .foregroundStyle(theme.textPrimary)
                            }
                        }
                    } header: {
                        SectionHeader(title: "Account")
                    }
                    .listRowBackground(theme.surface)

                    PlanUsageSection()
                }

                // The app lock — see `AppLockSettingsSection`.
                AppLockSettingsSection()

                Section {
                    NavigationLink {
                        DisclaimerReferenceView()
                    } label: {
                        IconRowLabel(
                            title: Disclaimer.title, systemImage: "exclamationmark.shield",
                            hue: .gold)
                    }
                } header: {
                    SectionHeader(title: "Important")
                } footer: {
                    footnote("Emperor is not a lawyer, and what it produces is not legal advice.")
                }
                .listRowBackground(theme.surface)

                Section {
                    Button(role: .destructive) {
                        isConfirmingSignOut = true
                    } label: {
                        // Danger-coloured words beside a rose tile: findable, not alarming.
                        IconRowLabel(
                            title: "Sign out", systemImage: "rectangle.portrait.and.arrow.right",
                            hue: .rose, titleColor: theme.danger)
                    }
                    .accessibilityLabel(Text("Sign out"))
                } footer: {
                    // What signing out actually does on this device, which is the part a person
                    // handing the phone to someone else needs to know.
                    footnote(
                        "Signing out removes your credentials and every matter cached on this device.")
                }
                .listRowBackground(theme.surface)
            }
            .font(.brand(.body))
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.canvas)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Sign out of Emperor?",
                isPresented: $isConfirmingSignOut,
                titleVisibility: .visible
            ) {
                Button("Sign out", role: .destructive) {
                    Task {
                        await session.signOut()
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Cached matters on this device will be removed.")
            }
        }
    }

    /// A section footer in the theme's own colours.
    ///
    /// This screen used to leave its footers, headers and row backgrounds to the system, which
    /// draws them from `preferredColorScheme` — while the `theme.canvas` behind them comes from
    /// `Theme.palette`. Those two agree only by coincidence. They diverge on "Match device",
    /// which resolves the palette through `Theme.systemIsDark` but hands `preferredColorScheme`
    /// a `nil` that releases the override; for a pass the page is painted half from each.
    ///
    /// Nowhere else does that show, because nowhere else can the appearance change under the
    /// screen you are looking at. Settings is the one page that repaints itself, so it is the
    /// one page that has to name every colour it uses.
    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.brand(.caption))
            .foregroundStyle(theme.textSecondary)
    }
}
