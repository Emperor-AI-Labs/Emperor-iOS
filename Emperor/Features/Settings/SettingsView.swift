import SwiftUI

/// Account, reference and sign-out.
///
/// Deliberately thin. There is no pricing or upgrade surface anywhere in this app: the product
/// takes no money in-app today, and the moment an in-app path to a paid plan exists, StoreKit
/// obligations attach. Keeping that surface absent is what keeps the submission simple.
struct SettingsView: View {
    @Environment(Session.self) private var session
    @Environment(\.theme) private var theme
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
                    Text("Emperor opens dark by default, matching the web dashboard.")
                }

                if let user = session.currentUser {
                    Section("Account") {
                        LabeledContent("Name", value: user.name ?? "—")
                        LabeledContent("Email", value: user.email ?? "—")
                    }
                }

                Section {
                    NavigationLink {
                        DisclaimerReferenceView()
                    } label: {
                        Label(Disclaimer.title, systemImage: "exclamationmark.shield")
                    }
                } header: {
                    Text("Important")
                } footer: {
                    Text("Emperor is not a lawyer, and what it produces is not legal advice.")
                }

                Section {
                    Button(role: .destructive) {
                        isConfirmingSignOut = true
                    } label: {
                        Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } footer: {
                    // Honest about what signing out does and does not do. The token cannot be
                    // revoked server-side — there is no logout route — so the only protection
                    // is that the device forgets it, along with everything cached.
                    Text("Signing out removes your credentials and every matter cached on this device.")
                }
            }
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
}
