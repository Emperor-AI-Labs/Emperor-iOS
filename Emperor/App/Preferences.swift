import Foundation

/// The real `PreferenceStore`, backed by `UserDefaults`.
///
/// Nothing secret goes here — the token is in the Keychain, and cached matters are in the
/// response cache and wiped on sign-out. This holds only "has this person seen the disclaimer",
/// which is why plain defaults are appropriate and why the privacy manifest declares
/// `NSPrivacyAccessedAPICategoryUserDefaults` with reason `CA92.1` (the app's own defaults,
/// read and written only by this app).
struct Preferences: PreferenceStore {
    // `UserDefaults` is not `Sendable`, but `PreferenceStore` is — and this one is thread-safe
    // by contract. Without this the struct will not compile under Swift 6 (verified).
    nonisolated(unsafe) private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func bool(for key: String) -> Bool { defaults.bool(forKey: key) }
    func setBool(_ value: Bool, for key: String) { defaults.set(value, forKey: key) }
    func string(for key: String) -> String? { defaults.string(forKey: key) }
    func setString(_ value: String, for key: String) { defaults.set(value, forKey: key) }
}
