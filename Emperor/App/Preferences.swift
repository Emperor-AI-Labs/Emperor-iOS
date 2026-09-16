import Foundation

/// The real `PreferenceStore`, backed by `UserDefaults`.
///
/// Nothing secret goes here — the token is in the Keychain, and cached matters are in the
/// response cache and wiped on sign-out. The standard suite holds the disclaimer
/// acknowledgement and the appearance choice, which is why plain defaults are appropriate and
/// why the privacy manifest declares `NSPrivacyAccessedAPICategoryUserDefaults` with reason
/// `CA92.1` (the app's own defaults, read and written only by this app).
///
/// One thing does name client material, and is kept in its own suite for that reason — see
/// `detachedDocuments`.
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

extension Preferences {
    /// Where `StoredDetachedDocuments` writes, in a suite of its own.
    ///
    /// This is the one thing the app remembers that names client material — a filename and the
    /// matter holding it. Keeping it separable means it can be reasoned about, and if it ever
    /// has to be, deleted, without disturbing the disclaimer acknowledgement or the appearance
    /// choice sitting beside it in the standard suite.
    static let detachedDocuments = Preferences(
        defaults: UserDefaults(suiteName: "com.emperorailabs.emperor.detached") ?? .standard)
}
