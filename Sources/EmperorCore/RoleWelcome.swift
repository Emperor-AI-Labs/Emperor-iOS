import Foundation

/// The role choice offered once, after the first sign-in on this device.
///
/// The web asks a new account what kind of practitioner it is before anything else
/// (`src/pages/Onboarding.jsx`, step 0) and treats an unset role as "onboarding not done"
/// (`uiRole: null`, `src/lib/store.js:86`). This is the same question, asked the same way: one
/// screen, every option optional, and a "Skip for now" that leaves the default in force. It is
/// asked once per device and only of an account that has no role yet.
///
/// ## When it appears
///
/// - **Only after a sign-in made on this device.** The sign-in screen marks the question owed
///   when it is shown (`noteSignInShown`). A session restored from the Keychain never passes
///   through it, so someone who was already using the app is not greeted as new.
/// - **Only if no role has ever been chosen here.** A role picked in Settings is an answer.
/// - **Until it is answered, and never again.** Choosing and skipping both settle it. Leaving the
///   app with the question on screen does not: it is still owed on the next launch.
/// - **Not if the account already has a role.** The role is kept on the account now
///   (`Practice`), so someone who chose one on the web, or on another phone, has answered —
///   even when it is one this app does not carry.
///
/// The roles are this app's seven. The web's onboarding also offers "Devil's Advocate"; that
/// role is not part of this app.
enum RoleWelcome {
    static let pendingKey = "practitioner.role.welcome.pending.v1"
    static let completedKey = "practitioner.role.welcome.completed.v1"

    /// Every role this app has, in its own order.
    static var roles: [PractitionerRole] { PractitionerRole.allCases }

    /// The sign-in screen is on show, so whoever is signed in next signed in on this device.
    static func noteSignInShown(_ store: any PreferenceStore) {
        guard !store.bool(for: completedKey) else { return }
        if store.string(for: PractitionerRole.storageKey) != nil {
            // Chosen in Settings at some point. That is the answer; never ask it again.
            store.setBool(true, for: completedKey)
            store.setBool(false, for: pendingKey)
            return
        }
        store.setBool(true, for: pendingKey)
    }

    static func shouldShow(
        _ store: any PreferenceStore, isSignedIn: Bool, accountRole: String? = nil
    ) -> Bool {
        isSignedIn
            && (accountRole ?? "").isEmpty
            && store.bool(for: pendingKey)
            && !store.bool(for: completedKey)
            && store.string(for: PractitionerRole.storageKey) == nil
    }

    /// Settles the question. `nil` is "Skip for now", which leaves the default role in force
    /// without recording it as a choice — so a later build that changes the default still
    /// applies to someone who never picked.
    static func finish(choosing role: PractitionerRole?, in store: any PreferenceStore) {
        role?.save(to: store)
        store.setBool(true, for: completedKey)
        store.setBool(false, for: pendingKey)
    }

    // MARK: - Wording

    /// "Welcome, Asha." — the first word of the account's name, as the web greets
    /// (`src/pages/Onboarding.jsx:47`), or a plain "Welcome." when there is none.
    static func greeting(for name: String?) -> String {
        let first = (name ?? "")
            .split(whereSeparator: { $0.isWhitespace })
            .first.map(String.init) ?? ""
        return first.isEmpty ? "Welcome." : "Welcome, \(first)."
    }

    static let prompt = """
        What do you mostly work on? It decides which tools come first. Every tool stays \
        available, and you can change this any time in Settings.
        """

    static let continueLabel = "Continue"
    static let skipLabel = "Skip for now"
}
