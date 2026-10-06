import SwiftUI
import UIKit

/// Settings → Notifications: this device's hearing reminders, and the account's daily email.
///
/// The two are kept in separate sections because they are separate things. The reminders are
/// scheduled by this phone from the cause list and need iOS's permission; the email is the
/// platform's own briefing, switched for the whole account, web included. Every decision is the
/// view model's (`NotificationSettingsViewModel`); this lays it out.
struct NotificationSettingsView: View {
    @Environment(Session.self) private var session
    @Environment(\.theme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    @State private var model: NotificationSettingsViewModel?

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.canvas)
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if model == nil {
                model = NotificationSettingsViewModel(
                    coordinator: AppNotifications.shared.coordinator,
                    emailService: NotificationOptInService(client: session.client),
                    account: NotificationAccount(session: session),
                    emailAddress: session.currentUser?.email)
            }
            await model?.load()
        }
        // Back from iOS Settings, where permission may just have been given or taken away.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, let model else { return }
            Task { await model.refreshAuthorization() }
        }
    }

    private func content(_ model: NotificationSettingsViewModel) -> some View {
        List {
            deviceSection(model)
            if model.isOn {
                hearingsSection(model)
                updatesSection(model)
            }
            emailSection(model)
        }
        .font(.brand(.body))
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.canvas)
        .animation(.default, value: model.isOn)
    }

    // MARK: - This device

    private func deviceSection(_ model: NotificationSettingsViewModel) -> some View {
        Section {
            Toggle(isOn: Binding(
                get: { model.switchIsOn },
                set: { on in Task { await model.setEnabled(on) } }
            )) {
                IconRowLabel(title: "Allow notifications", systemImage: "bell", hue: .violet)
            }
            .disabled(model.isBusy)
            .accessibilityIdentifier("notifications-allow")

            if model.isBlocked {
                blockedRow
            }

            if model.isOn {
                Button {
                    Task { await model.sendTest() }
                } label: {
                    IconRowLabel(
                        title: "Send a test notification", systemImage: "paperplane", hue: .teal)
                }
                .disabled(model.isBusy)
                .accessibilityIdentifier("notifications-test")
            }
        } header: {
            SectionHeader(title: "This device")
        } footer: {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                if let notice = model.notice {
                    Text(notice)
                        .foregroundStyle(theme.textPrimary)
                        .accessibilityIdentifier("notifications-notice")
                }
                Text(NotificationSettingsViewModel.Copy.deviceFooter)
            }
            .font(.brand(.caption))
            .foregroundStyle(theme.textSecondary)
        }
        .listRowBackground(theme.surface)
    }

    /// iOS has refused, and only iOS Settings can change that — so say so, and go there.
    private var blockedRow: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Label {
                Text(NotificationSettingsViewModel.Copy.blocked)
                    .font(.brand(.subheadline))
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(theme.warning)
            }
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            }
            .font(.brand(.subheadline, weight: .semibold))
            .accessibilityIdentifier("notifications-open-settings")
        }
        .padding(.vertical, Spacing.xxs)
    }

    // MARK: - Hearings

    private func hearingsSection(_ model: NotificationSettingsViewModel) -> some View {
        Section {
            Toggle(isOn: Binding(
                get: { model.preferences.morningBriefing },
                set: { on in Task { await model.setMorningBriefing(on) } }
            )) {
                IconRowLabel(title: "Morning briefing", systemImage: "sun.max", hue: .gold)
            }
            .accessibilityIdentifier("notifications-briefing")

            if model.preferences.morningBriefing {
                timePicker(
                    "Briefing time (IST)",
                    selection: Binding(
                        get: { model.briefingTime },
                        set: { date in Task { await model.setBriefingTime(date) } }),
                    identifier: "notifications-briefing-time")
            }

            Toggle(isOn: Binding(
                get: { model.preferences.eveningReminder },
                set: { on in Task { await model.setEveningReminder(on) } }
            )) {
                IconRowLabel(title: "Evening before", systemImage: "moon", hue: .indigo)
            }
            .accessibilityIdentifier("notifications-evening")

            if model.preferences.eveningReminder {
                timePicker(
                    "Reminder time (IST)",
                    selection: Binding(
                        get: { model.reminderTime },
                        set: { date in Task { await model.setReminderTime(date) } }),
                    identifier: "notifications-evening-time")
            }
        } header: {
            SectionHeader(title: "Hearings")
        } footer: {
            footnote(NotificationSettingsViewModel.Copy.hearingsFooter)
        }
        .listRowBackground(theme.surface)
    }

    /// A time of day shown in India's zone, whatever the phone's: a court day's times are
    /// Indian times, and the label says so.
    private func timePicker(
        _ title: String, selection: Binding<Date>, identifier: String
    ) -> some View {
        DatePicker(selection: selection, displayedComponents: .hourAndMinute) {
            Text(title)
                .font(.brand(.body))
                .foregroundStyle(theme.textPrimary)
        }
        .environment(\.timeZone, WireDate.india)
        .accessibilityIdentifier(identifier)
    }

    // MARK: - Updates

    private func updatesSection(_ model: NotificationSettingsViewModel) -> some View {
        Section {
            Toggle(isOn: Binding(
                get: { model.preferences.updates },
                set: { on in Task { await model.setUpdates(on) } }
            )) {
                IconRowLabel(title: "Updates from Emperor", systemImage: "tray", hue: .aqua)
            }
            .accessibilityIdentifier("notifications-updates")
        } footer: {
            footnote(NotificationSettingsViewModel.Copy.updatesFooter)
        }
        .listRowBackground(theme.surface)
    }

    // MARK: - The account's email

    private func emailSection(_ model: NotificationSettingsViewModel) -> some View {
        Section {
            switch model.email {
            case .loading:
                HStack(spacing: Spacing.sm) {
                    ProgressView()
                    Text("Loading…")
                        .font(.brand(.footnote))
                        .foregroundStyle(theme.textSecondary)
                }
            case .failed(let message):
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(NotificationSettingsViewModel.Copy.emailFailed)
                        .font(.brand(.subheadline, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                    Text(message)
                        .font(.brand(.footnote))
                        .foregroundStyle(theme.textSecondary)
                    Button("Try again") {
                        Task { await model.loadEmail() }
                    }
                    .font(.brand(.footnote, weight: .semibold))
                }
                .padding(.vertical, Spacing.xxs)
            case .loaded:
                Toggle(isOn: Binding(
                    get: { model.emailSwitchIsOn },
                    set: { on in Task { await model.setEmailBriefing(on) } }
                )) {
                    IconRowLabel(title: "Email briefing", systemImage: "envelope", hue: .steel)
                }
                .disabled(model.isChangingEmail)
                .accessibilityIdentifier("notifications-email")

                if model.offersTestEmail {
                    Button {
                        Task { await model.sendTestEmail() }
                    } label: {
                        IconRowLabel(
                            title: "Send a test email", systemImage: "paperplane", hue: .steel)
                    }
                    .disabled(model.isChangingEmail)
                    .accessibilityIdentifier("notifications-test-email")
                }
            }
        } header: {
            SectionHeader(title: "Your account")
        } footer: {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                if let notice = model.emailNotice {
                    Text(notice)
                        .foregroundStyle(theme.textPrimary)
                }
                Text(model.emailFooter)
            }
            .font(.brand(.caption))
            .foregroundStyle(theme.textSecondary)
        }
        .listRowBackground(theme.surface)
    }

    /// A section footer in the theme's own colours — see `SettingsView.footnote` for why this
    /// screen names every colour it uses.
    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.brand(.caption))
            .foregroundStyle(theme.textSecondary)
    }
}
