import SwiftUI

/// The You tab: the account, its plan and allowances, how answers start, the role, appearance,
/// notifications, the tools that are not tabs, privacy and storage, and signing out.
///
/// What was Settings is here, row for row — role, appearance, notifications, profile, plan and
/// usage, app lock, search, offline storage, the disclaimer — beside the Record design's own:
/// the default answer mode and the Tools rows that were the More tab.
struct YouView: View {
    @Environment(Session.self) private var session
    @Environment(\.theme) private var theme
    @Environment(\.practice) private var practice

    @State private var tool: ToolDestination?
    @State private var isConfirmingSignOut = false

    private let preferences = Preferences()

    var body: some View {
        NavigationStack {
            List {
                if let user = session.currentUser {
                    Section {
                        NavigationLink {
                            EditProfileView()
                        } label: {
                            profile(user)
                        }
                        .accessibilityIdentifier("edit-profile")
                    }
                    .listRowBackground(theme.surface)

                    PlanUsageSection()
                }

                Section {
                    // A fact, not a setting: every launch starts on Fast, and deep thinking only on
                    // the top plan tier. The composer's mode chip switches a single question.
                    IconRowLabel(
                        title: "Default mode", systemImage: "bolt",
                        value: currentDefaultMode.modeName)
                        .accessibilityElement(children: .combine)

                    NavigationLink {
                        RolePickerView()
                    } label: {
                        IconRowLabel(
                            title: "Role", systemImage: practice.role.systemImage,
                            value: practice.role.label)
                    }
                    .accessibilityIdentifier("Role selector")
                } header: {
                    SectionHeader(title: "Answers")
                } footer: {
                    footnote("New questions start on Fast; deep thinking is the default only on the top plan, and any question can be switched from the composer. The role changes the suggestions on Ask and how answers are written, and is saved to your account, so the web opens in the same role.")
                }
                .listRowBackground(theme.surface)

                Section {
                    RecordSegmentedControl(
                        label: "Appearance",
                        options: ThemePreference.allCases.map { (value: $0, title: $0.label) },
                        selection: Binding(
                            get: { theme.preference },
                            set: { theme.select($0) }))
                        .listRowInsets(EdgeInsets(top: Spacing.sm, leading: Spacing.md, bottom: Spacing.sm, trailing: Spacing.md))
                } header: {
                    SectionHeader(title: "Appearance")
                }
                .listRowBackground(theme.surface)

                Section {
                    NavigationLink {
                        NotificationSettingsView()
                    } label: {
                        IconRowLabel(title: "Notifications", systemImage: "bell")
                    }
                    .accessibilityIdentifier("notifications-settings")
                } header: {
                    SectionHeader(title: "Notifications")
                } footer: {
                    footnote("The daily cause list, hearing reminders on this device, and an email copy.")
                }
                .listRowBackground(theme.surface)

                ToolsSections(destination: $tool)

                AppLockSettingsSection()

                Section {
                    let isIndexing = AppSpotlight.shared.coordinator.isEnabled
                    Toggle(isOn: Binding(
                        get: { isIndexing },
                        set: {
                            Haptics.selection()
                            AppSpotlight.shared.setEnabled($0)
                        }
                    )) {
                        IconRowLabel(title: SpotlightCoordinator.Copy.toggle, systemImage: "magnifyingglass")
                    }
                    .tint(theme.accentText)
                    .accessibilityIdentifier("spotlight-toggle")
                } header: {
                    SectionHeader(title: "Search")
                } footer: {
                    footnote(SpotlightCoordinator.Copy.footer)
                }
                .listRowBackground(theme.surface)

                OfflineStorageSection()

                Section {
                    NavigationLink {
                        DisclaimerReferenceView()
                    } label: {
                        IconRowLabel(title: Disclaimer.title, systemImage: "exclamationmark.shield")
                    }
                    .accessibilityIdentifier("settings-disclaimer")
                } header: {
                    SectionHeader(title: "More")
                } footer: {
                    footnote("Emperor is not a lawyer, and what it produces is not legal advice.")
                }
                .listRowBackground(theme.surface)

                Section {
                    Button {
                        Haptics.warning()
                        isConfirmingSignOut = true
                    } label: {
                        Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.destructiveAction)
                    .accessibilityIdentifier("Sign out")
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                } footer: {
                    VStack(spacing: Spacing.xs) {
                        Text("Signing out removes your credentials and every matter cached on this device.")
                        Text(versionLine)
                            .monospacedDigit()
                    }
                    .font(.brand(.caption))
                    .foregroundStyle(theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, Spacing.sm)
                }
            }
            .font(.brand(.body))
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.groupedBackground)
            .navigationTitle("You")
            .navigationBarTitleDisplayMode(.large)
            .sheet(item: $tool) { chosen in
                chosen.screen
                    .pageSizedSheet()
            }
            .confirmationDialog(
                "Sign out of Emperor?",
                isPresented: $isConfirmingSignOut,
                titleVisibility: .visible
            ) {
                Button("Sign out", role: .destructive) {
                    Task { await session.signOut() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Cached matters on this device will be removed.")
            }
        }
    }

    // MARK: - Profile

    private func profile(_ user: User) -> some View {
        HStack(spacing: 14) {
            AccountAvatar(
                photo: ProfilePhoto.source(of: user.avatar),
                monogram: ProfilePhoto.monogram(name: user.name, email: user.email),
                size: 64)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(displayName(user))
                    .font(.brand(size: 19, weight: .semibold, relativeTo: .title3))
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(roleLine(user))
                    .font(.brand(.footnote))
                    .foregroundStyle(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if let email = user.email {
                    Text(email)
                        .font(.brand(.footnote))
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Spacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("account-profile")
    }

    private func displayName(_ user: User) -> String {
        let name = user.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "Your account" : name
    }

    /// "Advocate · Litigator" — the title the account gives, then the role practised in.
    private func roleLine(_ user: User) -> String {
        let parts = [user.title, user.organization]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return (parts + [practice.role.label]).joined(separator: " · ")
    }

    // MARK: - Answers

    private var currentDefaultMode: ChatModel {
        AnswerModeDefault.starting(feeTier: session.currentUser?.feeTier)
    }


    private var versionLine: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "—"
        let build = info["CFBundleVersion"] as? String ?? "—"
        return "Emperor \(version) (\(build))"
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.brand(.caption))
            .foregroundStyle(theme.textTertiary)
    }
}
