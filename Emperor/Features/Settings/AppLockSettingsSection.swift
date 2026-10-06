import SwiftUI

/// "Security": the app lock — Face ID, Touch ID, Optic ID or the passcode, whichever this device
/// will ask for — and how long the app may be away before it asks again.
///
/// Turning it on asks first, so nobody can lock themselves out with a face the device does not
/// recognise; turning it off does not. The rules are `AppLock`'s; this lays them out. The privacy
/// cover in the app switcher is always on and has no switch, so the footer says so rather than
/// offering one.
struct AppLockSettingsSection: View {
    @Environment(AppLock.self) private var lock
    @Environment(\.theme) private var theme
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Section {
            Toggle(isOn: Binding(
                get: { lock.switchIsOn },
                set: { on in Task { await lock.setEnabled(on) } }
            )) {
                IconRowLabel(
                    title: lock.biometry.requireTitle, systemImage: lock.biometry.systemImage,
                    hue: .steel)
            }
            .disabled(lock.isAuthenticating)
            .accessibilityIdentifier("app-lock-toggle")

            if lock.isEnabled {
                Picker(selection: Binding(
                    get: { lock.timeout },
                    set: { lock.setTimeout($0) }
                )) {
                    ForEach(AppLockTimeout.allCases) { option in
                        Text(option.label).tag(option)
                    }
                } label: {
                    HStack(spacing: Spacing.md) {
                        IconTile(systemImage: "timer", hue: .indigo)
                        Text(AppLockCopy.timeoutTitle)
                            .font(.brand(.body))
                            .foregroundStyle(theme.textPrimary)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("app-lock-timeout")
            }
        } header: {
            SectionHeader(title: AppLockCopy.sectionTitle)
        } footer: {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                if let notice = lock.notice {
                    Text(notice)
                        .foregroundStyle(theme.warning)
                        .accessibilityIdentifier("app-lock-notice")
                }
                Text(AppLockCopy.footer(isEnabled: lock.isEnabled, biometry: lock.biometry))
                    .foregroundStyle(theme.textSecondary)
            }
            .font(.brand(.caption))
        }
        .listRowBackground(theme.surface)
        // Why the lock could not be turned on lands in the footer, below the switch VoiceOver is
        // on — so it is said as well.
        .onChange(of: lock.notice) { _, notice in
            if let notice { VoiceOver.announce(notice) }
        }
        // Face ID enrolled, or a passcode set, in the Settings app since this screen last looked.
        .onAppear { lock.refreshAvailability() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { lock.refreshAvailability() }
        }
    }
}
