import Foundation
#if canImport(Darwin)
import Observation
#endif

// MARK: - The choices

/// How long Emperor may be away before it asks again.
///
/// "Away" is the time since the app went to the **background** — not since it stopped being
/// active. Pulling down Notification Centre, or the system's own Face ID prompt, makes the app
/// inactive without leaving it, and a lock that fired on those would ask for Face ID every time
/// someone glanced at a banner.
enum AppLockTimeout: String, CaseIterable, Identifiable, Sendable {
    case immediately
    case oneMinute
    case fiveMinutes
    case fifteenMinutes
    case oneHour

    /// Long enough to answer a call or read a message without being asked again; short enough
    /// that a phone left on a desk is locked by the time anyone else picks it up.
    static let `default` = AppLockTimeout.oneMinute

    /// What a stored value this build cannot read is taken to mean.
    ///
    /// Not the default: a value this build does not know was written by one that offered a
    /// choice this one does not, and the only reading that cannot be looser than what the person
    /// chose is the strictest one. The picker then shows "Immediately", so what is in force is
    /// what is on screen.
    static let unreadable = AppLockTimeout.immediately

    static let storageKey = "applock.timeout.v1"

    var id: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .immediately: return 0
        case .oneMinute: return 60
        case .fiveMinutes: return 5 * 60
        case .fifteenMinutes: return 15 * 60
        case .oneHour: return 60 * 60
        }
    }

    var label: String {
        switch self {
        case .immediately: return "Immediately"
        case .oneMinute: return "After 1 minute"
        case .fiveMinutes: return "After 5 minutes"
        case .fifteenMinutes: return "After 15 minutes"
        case .oneHour: return "After 1 hour"
        }
    }
}

/// Whether the lock is on, and after how long.
///
/// A **device** setting, not an account one: it is about who is holding this phone, so it lives
/// in the device's preferences and survives signing out — `Session.signOut` clears the account,
/// the token and the cached matters, and leaves this alone. The next person to sign in on the
/// same phone finds it as it was left.
struct AppLockSettings: Equatable, Sendable {
    var isEnabled = false
    var timeout = AppLockTimeout.default

    static let enabledKey = "applock.enabled.v1"

    init(isEnabled: Bool = false, timeout: AppLockTimeout = .default) {
        self.isEnabled = isEnabled
        self.timeout = timeout
    }

    /// The stored choice. Off when nothing is stored; see `AppLockTimeout.unreadable` for a
    /// timeout this build cannot read.
    static func stored(in store: any PreferenceStore) -> AppLockSettings {
        let timeout: AppLockTimeout
        if let raw = store.string(for: AppLockTimeout.storageKey) {
            timeout = AppLockTimeout(rawValue: raw) ?? .unreadable
        } else {
            timeout = .default
        }
        return AppLockSettings(isEnabled: store.bool(for: enabledKey), timeout: timeout)
    }

    func save(to store: any PreferenceStore) {
        store.setBool(isEnabled, for: Self.enabledKey)
        store.setString(timeout.rawValue, for: AppLockTimeout.storageKey)
    }
}

// MARK: - The device

/// What unlocks the app on this device. The passcode stands behind every one of them —
/// `LAPolicy.deviceOwnerAuthentication` falls back to it — and `.none` is the passcode alone.
enum AppLockBiometry: String, Sendable {
    case faceID, touchID, opticID, none

    /// The switch in Settings, named for what the device will actually ask for.
    var requireTitle: String {
        switch self {
        case .faceID: return "Require Face ID"
        case .touchID: return "Require Touch ID"
        case .opticID: return "Require Optic ID"
        case .none: return "Require passcode"
        }
    }

    /// "Face ID", or "your passcode" — the thing asked for, as a sentence names it.
    var spokenName: String {
        switch self {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        case .none: return "your passcode"
        }
    }

    var systemImage: String {
        switch self {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        case .none: return "lock"
        }
    }
}

/// Whether this device can be asked who is holding it.
enum AppLockAvailability: Equatable, Sendable {
    case available(AppLockBiometry)
    /// No device passcode — so there is nothing for a lock to ask for, and no lock.
    case passcodeNotSet
    /// Anything else that stops the device asking, such as a management policy.
    case unavailable
}

/// How one prompt ended.
enum AppLockAuthOutcome: Equatable, Sendable {
    case success
    /// Dismissed — by the person, or by iOS as the app left the screen. Not a failure to report.
    case cancelled
    /// Asked and not satisfied.
    case failed
    case passcodeNotSet
    case unavailable
}

/// Asks the device who is holding it — `LocalAuthentication` in the app, a stand-in in the UI
/// tests and here.
@MainActor
protocol AppLockAuthenticating {
    func availability() -> AppLockAvailability
    /// Shows the system's prompt. `reason` is shown under Touch ID and the passcode; Face ID
    /// shows the app's `NSFaceIDUsageDescription` instead.
    func authenticate(reason: String) async -> AppLockAuthOutcome
}

// MARK: - The decision

/// Whether the app should be locked now. Pure, so every boundary can be tested.
enum AppLockPolicy {
    enum Moment: Equatable, Sendable {
        /// A cold start, with the session just read from the device.
        case launch
        /// Back from the background. `leftAt` is the `AppLockClock` reading taken as the app
        /// went, `nil` if that was never seen; `now` is the reading on return.
        case resume(leftAt: TimeInterval?, now: TimeInterval)
    }

    /// Never when the lock is off, never with nobody signed in — the login screen holds nothing
    /// to protect, and a lock in front of it would only stand between the owner and signing in.
    /// Always at launch. On return, once the app has been away for at least the timeout:
    /// exactly at it counts, as "after 1 minute" means.
    ///
    /// Anything that cannot be measured locks. A return with no record of leaving, a reading
    /// earlier than the one taken on the way out, or one that is not a number: each means the
    /// time away is unknown, and an unknown time away is not one known to be short.
    static func shouldLock(
        _ moment: Moment, isEnabled: Bool, timeout: AppLockTimeout, isSignedIn: Bool
    ) -> Bool {
        guard isEnabled, isSignedIn else { return false }
        switch moment {
        case .launch:
            return true
        case .resume(let leftAt, let now):
            guard let leftAt else { return true }
            let away = now - leftAt
            // Also false for NaN, so a reading that is not a number locks too.
            guard away >= 0 else { return true }
            return away >= timeout.seconds
        }
    }
}

/// The clock time away is measured on: seconds since an arbitrary point, on a clock that keeps
/// running while the phone sleeps and that changing the date and time in Settings does not move.
///
/// Not `Date`. A wall clock can be wound back — by hand, or by the network correcting it — and
/// winding it back to just after the app was left would make an hour away read as a minute.
/// `ContinuousClock` cannot be moved, and unlike the system's uptime it does not stop while the
/// device is asleep, which is most of the time a phone spends in a pocket.
enum AppLockClock {
    private static let origin = ContinuousClock.now

    static func now() -> TimeInterval {
        // `origin` first: it is set on first use, and reading it second would put it after the
        // instant it is subtracted from.
        let origin = Self.origin
        let parts = origin.duration(to: ContinuousClock.now).components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) * 1e-18
    }
}

// MARK: - Wording

enum AppLockCopy {
    static let lockedTitle = "Emperor is locked"
    static let unlock = "Unlock"
    static let sectionTitle = "Security"
    static let timeoutTitle = "Lock after"

    static func unlockHint(_ biometry: AppLockBiometry) -> String {
        "Unlock with \(biometry.spokenName) to see your matters."
    }

    /// Shown under Touch ID and the passcode when unlocking.
    static let unlockReason = "Unlock Emperor to see your matters."
    /// Shown when turning the lock on — which asks first, so nobody locks themselves out with a
    /// face or a passcode the device does not accept.
    static let turnOnReason = "Confirm it's you to lock Emperor."

    static let needsPasscode =
        "The lock needs a device passcode. Set one in the Settings app, then turn this on."
    static let notConfirmed = "That didn't confirm it was you, so the lock is still off."
    static let unavailable =
        "This device can't confirm who you are right now, so the lock is still off."
    static let turnedOffWithoutPasscode =
        "The lock was turned off because this device no longer has a passcode."

    static func footer(isEnabled: Bool, biometry: AppLockBiometry) -> String {
        if isEnabled {
            return "Emperor asks for \(biometry.spokenName) when it opens, and when you come back "
                + "after the time above. Your matters are always hidden in the app switcher."
        }
        return "Your matters are always hidden in the app switcher. Turn this on to also ask for "
            + "\(biometry.spokenName) whenever Emperor opens."
    }
}

// MARK: - The lock

/// The app lock, and the privacy cover drawn whenever the app is not in front.
///
/// ## Two covers
///
/// - **Locked**: a full-screen cover with an Unlock button, after a cold start with someone
///   signed in and on a return after the timeout. Lawyers keep privileged matters here; a phone
///   handed across a desk, or left on one, should not open onto them.
/// - **Privacy**: the brand alone, whenever the scene is not active, lock or no lock — so the
///   app switcher's picture of the app, and the screen as it slides away, never show a matter.
///
/// What is drawn, and over what, is the app layer's (`AppLockShield`). This decides **when**:
/// it is told the scene's phase and the session's state, and answers with `cover`.
///
/// ## The prompt is not the person leaving
///
/// iOS makes the app inactive while its own Face ID prompt is up. Turning the lock on from
/// Settings would otherwise slide the privacy cover over Settings for the length of the prompt,
/// and unlocking would count as a return. Neither happens: time away is measured from the
/// background, which a prompt never reaches, and the privacy cover waits out a prompt this app
/// asked for.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class AppLock {
    enum Phase: Sendable {
        case active, inactive, background
    }

    enum Cover: Equatable, Sendable {
        case locked
        case privacy
    }

    private(set) var settings: AppLockSettings
    private(set) var isLocked = false
    /// A prompt of this app's is on screen — to unlock, or to turn the lock on.
    private(set) var isAuthenticating = false
    /// Turning on is waiting on its prompt; the switch shows on meanwhile, rather than flicking
    /// back to off while the person looks at the camera.
    private(set) var isTurningOn = false
    private(set) var availability: AppLockAvailability
    /// Why the last attempt to turn the lock on did not, or why it was turned off — for Settings.
    private(set) var notice: String?

    /// Whether a lock that appears asks by itself. Off only in the UI tests, whose stand-in
    /// answers at once and would lift the lock before a test could see it.
    let promptsAutomatically: Bool

    private let store: any PreferenceStore
    private let authenticator: any AppLockAuthenticating
    private let clock: @MainActor () -> TimeInterval

    /// Inactive and never yet active: a scene still launching, which has drawn nothing to hide.
    private var phase = Phase.inactive
    private var hasBeenActive = false
    /// `nil` until the session has been read from the device; then whether anyone is signed in.
    private var isSignedIn: Bool?
    /// Whether the session's first reading — the launch — has been seen.
    private var hasSeenLaunch = false
    /// The `clock` reading taken as the app went to the background.
    private var leftAt: TimeInterval?
    /// The lock has been shown to someone and has not yet asked them by itself.
    private var isPromptDue = false
    /// From asking until the scene is active again — see "The prompt is not the person leaving".
    private var isAwaitingOwnPrompt = false

    init(
        store: any PreferenceStore,
        authenticator: any AppLockAuthenticating,
        clock: @escaping @MainActor () -> TimeInterval = { AppLockClock.now() },
        promptsAutomatically: Bool = true
    ) {
        self.store = store
        self.authenticator = authenticator
        self.clock = clock
        self.promptsAutomatically = promptsAutomatically
        self.settings = AppLockSettings.stored(in: store)
        self.availability = authenticator.availability()
    }

    var isEnabled: Bool { settings.isEnabled }
    var timeout: AppLockTimeout { settings.timeout }

    /// What this device asks for. The passcode alone where nothing else is set up.
    var biometry: AppLockBiometry {
        if case .available(let biometry) = availability { return biometry }
        return .none
    }

    /// What the switch in Settings shows: on while turning on waits for its prompt.
    var switchIsOn: Bool { settings.isEnabled || isTurningOn }

    /// What is drawn over the app, if anything.
    ///
    /// The privacy cover is not drawn over the login screen: with nobody signed in there is no
    /// matter to hide, and signing in with Apple or Google raises system prompts that would
    /// otherwise draw it behind them. Nor over a scene that is still launching — inactive and
    /// never yet active — which has drawn nothing, and where it would only flash the brand
    /// between the launch screen and the first frame.
    var cover: Cover? {
        if isLocked { return .locked }
        guard !isAwaitingOwnPrompt, isSignedIn != false else { return nil }
        switch phase {
        case .active: return nil
        case .inactive: return hasBeenActive ? .privacy : nil
        case .background: return .privacy
        }
    }

    func refreshAvailability() {
        availability = authenticator.availability()
    }

    // MARK: Settings

    /// Turns the lock on — only once the device has confirmed who is holding it, so nobody can
    /// lock themselves out with a face or a passcode it does not accept — or off, at once.
    func setEnabled(_ on: Bool) async {
        guard on else {
            notice = nil
            settings.isEnabled = false
            settings.save(to: store)
            return
        }
        guard !settings.isEnabled, !isAuthenticating else { return }
        notice = nil
        refreshAvailability()
        switch availability {
        case .passcodeNotSet:
            notice = AppLockCopy.needsPasscode
            return
        case .unavailable:
            notice = AppLockCopy.unavailable
            return
        case .available:
            break
        }

        isTurningOn = true
        let outcome = await authenticate(reason: AppLockCopy.turnOnReason)
        isTurningOn = false
        switch outcome {
        case .success:
            settings.isEnabled = true
            settings.save(to: store)
        case .cancelled:
            break
        case .failed:
            notice = AppLockCopy.notConfirmed
        case .passcodeNotSet:
            availability = .passcodeNotSet
            notice = AppLockCopy.needsPasscode
        case .unavailable:
            notice = AppLockCopy.unavailable
        }
    }

    func setTimeout(_ timeout: AppLockTimeout) {
        settings.timeout = timeout
        settings.save(to: store)
    }

    // MARK: What the app tells it

    /// The session's state: `nil` while it is still being read, then whether anyone is signed in.
    ///
    /// The first reading is the launch, and locks. A sign-in after that does not — whoever typed
    /// the password has just shown who they are. Signing out, by hand or because the account's
    /// credentials stopped working, lifts the lock: the login screen is never locked.
    func sessionChanged(isSignedIn signedIn: Bool?) {
        isSignedIn = signedIn
        guard let signedIn else { return }
        let isLaunch = !hasSeenLaunch
        hasSeenLaunch = true
        guard signedIn else {
            isLocked = false
            isPromptDue = false
            return
        }
        if isLaunch && AppLockPolicy.shouldLock(
            .launch, isEnabled: settings.isEnabled, timeout: settings.timeout, isSignedIn: true) {
            lock()
        }
    }

    /// The scene's phase — its first reading, and every change after.
    func scenePhaseChanged(to new: Phase) {
        let old = phase
        phase = new
        switch new {
        case .background:
            if old != .background { leftAt = clock() }
            // Whatever the prompt was, the person has now really left.
            isAwaitingOwnPrompt = false
        case .inactive, .active:
            if old == .background { returnedFromBackground() }
            if new == .active {
                hasBeenActive = true
                if !isAuthenticating { isAwaitingOwnPrompt = false }
            }
        }
    }

    /// Asks by itself, once each time the lock is put in front of someone — at launch, and on
    /// each return while it is up. Not again after a cancel: the system's prompt makes the scene
    /// inactive and active again, and asking on every return to active would put the prompt back
    /// the moment it was dismissed. The Unlock button asks after that.
    func promptIfDue() async {
        guard promptsAutomatically, isPromptDue, isLocked, phase == .active, !isAuthenticating
        else { return }
        isPromptDue = false
        await unlock()
    }

    /// The Unlock button, and the automatic prompt.
    func unlock() async {
        guard isLocked, !isAuthenticating else { return }
        let outcome = await authenticate(reason: AppLockCopy.unlockReason)
        switch outcome {
        case .success:
            isLocked = false
            isPromptDue = false
        case .passcodeNotSet:
            // The passcode was removed after the lock was turned on — which iOS allows only to
            // someone who has just entered it. There is nothing left to ask for, and staying
            // locked would shut the owner out of the app for good. Off, and said so in Settings.
            settings.isEnabled = false
            settings.save(to: store)
            availability = .passcodeNotSet
            notice = AppLockCopy.turnedOffWithoutPasscode
            isLocked = false
            isPromptDue = false
        case .cancelled, .failed, .unavailable:
            // Still locked, with the button.
            break
        }
    }

    // MARK: Private

    private func lock() {
        isLocked = true
        isPromptDue = true
    }

    private func returnedFromBackground() {
        let wentAt = leftAt
        leftAt = nil
        if isLocked {
            // Left while locked: they are back, so ask them.
            isPromptDue = true
            return
        }
        let shouldLock = AppLockPolicy.shouldLock(
            .resume(leftAt: wentAt, now: clock()),
            isEnabled: settings.isEnabled, timeout: settings.timeout,
            isSignedIn: isSignedIn == true)
        if shouldLock { lock() }
    }

    private func authenticate(reason: String) async -> AppLockAuthOutcome {
        isAuthenticating = true
        isAwaitingOwnPrompt = true
        let outcome = await authenticator.authenticate(reason: reason)
        isAuthenticating = false
        // Answered with the scene already back: nothing more to wait for. Otherwise the scene's
        // return to active clears it, so the cover does not flash in the gap between the two.
        if phase == .active { isAwaitingOwnPrompt = false }
        return outcome
    }
}
