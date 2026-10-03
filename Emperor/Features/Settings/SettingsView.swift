import SwiftUI

/// Account, usage, reference and sign-out.
///
/// There is no pricing or upgrade surface anywhere in this app: the product takes no money
/// in-app, and the moment an in-app path to a paid plan exists, StoreKit obligations attach.
/// The plan and its allowances are *shown* (`PlanUsageSection`) — that is information, not a
/// sale — but nothing here offers to change them or says where they could be changed.
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

                Section {
                    NavigationLink {
                        RolePickerView()
                    } label: {
                        LabeledContent("Practising as") {
                            Text(practice.role.label).foregroundStyle(theme.textPrimary)
                        }
                    }
                } header: {
                    SectionHeader(title: "Your work")
                } footer: {
                    footnote(practice.role.detail)
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
                    } header: {
                        SectionHeader(title: "Account")
                    }
                    .listRowBackground(theme.surface)

                    PlanUsageSection()
                }

                Section {
                    NavigationLink {
                        DisclaimerReferenceView()
                    } label: {
                        Label(Disclaimer.title, systemImage: "exclamationmark.shield")
                            .foregroundStyle(theme.textPrimary)
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
                        Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } footer: {
                    // What signing out actually does on this device, which is the part a person
                    // handing the phone to someone else needs to know.
                    footnote(
                        "Signing out removes your credentials and every matter cached on this device.")
                }
                .listRowBackground(theme.surface)
            }
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
