import Foundation
import LocalAuthentication

/// Face ID, Touch ID or Optic ID, with the passcode behind it:
/// `LAPolicy.deviceOwnerAuthentication`.
///
/// That policy, not the biometrics-only one, because a lock that cannot fall back to the
/// passcode locks out anyone whose face is not recognised today: a mask, a bandage, a sensor
/// that is wet. iOS shows the passcode after failed attempts, and on its own where nothing else
/// is set up — which is what `AppLockBiometry.none` names.
///
/// What an answer means is decided in the core (`AppLock`); this only asks, and translates
/// LocalAuthentication's errors into `AppLockAuthOutcome`.
@MainActor
final class DeviceOwnerAuthenticator: AppLockAuthenticating {
    /// Kept while a prompt is up, so the context lives exactly as long as its prompt.
    private var context: LAContext?

    func availability() -> AppLockAvailability {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return Self.code(of: error) == .passcodeNotSet ? .passcodeNotSet : .unavailable
        }
        // Face ID that is not enrolled, or that this app has been refused, means the prompt will
        // be the passcode — so the switch says passcode. `biometryType` is only filled in after
        // a policy has been evaluated, which is why it is read after both checks.
        var biometricError: NSError?
        let biometricsUsable = context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics, error: &biometricError)
        if !biometricsUsable {
            switch Self.code(of: biometricError) {
            case .biometryNotEnrolled?, .biometryNotAvailable?:
                return .available(.none)
            default:
                // Locked out after too many attempts: still the device's biometry, back once
                // the passcode has been entered.
                break
            }
        }
        return .available(Self.biometry(context.biometryType))
    }

    func authenticate(reason: String) async -> AppLockAuthOutcome {
        let context = LAContext()
        self.context = context
        let outcome: AppLockAuthOutcome = await withCheckedContinuation { continuation in
            // `@Sendable`, so the reply is not inferred to be main-actor code: LocalAuthentication
            // calls it on a queue of its own, and Swift 6 traps a main-actor closure called from
            // anywhere else.
            context.evaluatePolicy(
                .deviceOwnerAuthentication, localizedReason: reason
            ) { @Sendable success, error in
                continuation.resume(returning: success ? .success : Self.outcome(for: error))
            }
        }
        self.context = nil
        return outcome
    }

    nonisolated private static func outcome(for error: (any Error)?) -> AppLockAuthOutcome {
        switch code(of: error) {
        case .userCancel?, .systemCancel?, .appCancel?, .userFallback?:
            return .cancelled
        case .authenticationFailed?:
            return .failed
        case .passcodeNotSet?:
            return .passcodeNotSet
        default:
            return .unavailable
        }
    }

    nonisolated private static func code(of error: (any Error)?) -> LAError.Code? {
        (error as? LAError)?.code
    }

    nonisolated private static func biometry(_ type: LABiometryType) -> AppLockBiometry {
        switch type {
        case .faceID: return .faceID
        case .touchID: return .touchID
        case .opticID: return .opticID
        case .none: return .none
        @unknown default: return .none
        }
    }
}

extension AppLock {
    /// The app's lock: this device's own Face ID or passcode, and the choice stored on it.
    ///
    /// In the UI tests the real `LAContext` is never touched — a stand-in recognises every face —
    /// and the lock is off unless `-UITestAppLock` asks for it, set every launch for the reason
    /// `EmperorApp.init` gives for its gates: `UserDefaults` outlives a test run.
    static func forThisDevice() -> AppLock {
        #if DEBUG
        if UITestSupport.isActive {
            let wantsLock = UITestSupport.wantsAppLock
            AppLockSettings(isEnabled: wantsLock, timeout: wantsLock ? .immediately : .default)
                .save(to: Preferences())
            return AppLock(
                store: Preferences(), authenticator: UITestAuthenticator(),
                promptsAutomatically: false)
        }
        #endif
        return AppLock(store: Preferences(), authenticator: DeviceOwnerAuthenticator())
    }
}

#if DEBUG
/// The UI tests' Face ID: a device that has it, and a face it always recognises. Answers at
/// once, which is why the lock waits for its Unlock button in UI-test mode — an automatic prompt
/// would lift the lock before a test could see it.
@MainActor
final class UITestAuthenticator: AppLockAuthenticating {
    func availability() -> AppLockAvailability { .available(.faceID) }
    func authenticate(reason: String) async -> AppLockAuthOutcome { .success }
}

extension UITestSupport {
    /// The lock on, set to lock immediately, with someone already signed in on the device — a
    /// cold start with a session, which is the moment the lock exists for.
    static let appLockArgument = "-UITestAppLock"

    static var wantsAppLock: Bool {
        ProcessInfo.processInfo.arguments.contains(appLockArgument)
    }

    /// What the in-memory credential store starts with: nothing — every other test signs in
    /// through the real login screen — except under `-UITestAppLock`, where a session restored
    /// at launch is the subject. Under `Session`'s own keys, holding the account the stub's
    /// `/login` answers with.
    static var storedCredentials: [String: String] {
        guard wantsAppLock else { return [:] }
        return [
            "auth.token": "ui-test-token",
            "auth.user": #"{"id":1,"name":"John Doe","email":"john.doe@firm.com","phone":"+919876543210"}"#,
        ]
    }
}
#endif
