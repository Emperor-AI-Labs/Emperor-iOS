import Foundation
#if canImport(Darwin)
import Observation
#endif

/// The first-sign-in welcome's two steps: the role, then the chambers and designation — the web's
/// onboarding (`src/pages/Onboarding.jsx`), step 0 and step 1.
///
/// When the welcome appears, and that it appears once, is `RoleWelcome`'s. This is what happens
/// inside it:
///
/// - **Step 1, the role.** "Continue" needs a choice; "Skip for now" settles the whole welcome
///   with no role and no details, as the web's does.
/// - **Step 2, the details.** Chambers or firm, and designation — both optional, both shown on
///   drafts and filings. "Start working" saves them and finishes; "Skip" finishes without them;
///   "Back" returns to the roles with the choice kept.
///
/// The details are saved through `ProfileEditor`, so the save sends all four profile fields as the
/// account holds them (`POST /update-profile` clears what it is not sent). Nothing is sent when
/// nothing changed. A save that fails says why and stays on the step — "Skip" is always there, so
/// a failed write never keeps anyone out of the app; the same fields are in Edit profile.
///
/// The form starts from the account: a title or organisation already set, on the web or another
/// phone, is shown rather than blanked. An account with no name is asked for one here too, because
/// a profile save without a name is refused (`ProfileEditor.nameProblem`).
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class RoleWelcomeFlow {

    enum Step: Equatable, Sendable { case role, details }

    enum Copy {
        static let detailsTitle = "A couple of details."
        static let detailsPrompt = "These appear on drafts and filings. Both optional."
        static let organizationLabel = "Chambers / firm"
        static let organizationPlaceholder = "e.g. Chambers of …"
        static let titleLabel = "Designation"
        static let titlePlaceholder = "e.g. Advocate, Delhi High Court"
        static let nameLabel = "Your name"
        static let startLabel = "Start working"
        static let skipDetailsLabel = "Skip"
        static let backLabel = "Back"
    }

    private(set) var step: Step = .role
    var chosen: PractitionerRole?

    /// The profile save behind step 2, holding the fields as they are typed.
    let profile: ProfileEditor

    /// Whether the account has no name, so step 2 asks for one.
    let asksForName: Bool

    /// Why the last save failed. Cleared by the next attempt, and by going back.
    private(set) var saveError: String?

    init(user: User, service: any ProfileUpdating, adopt: @escaping @MainActor (User) -> Void) {
        profile = ProfileEditor(user: user, service: service, adopt: adopt)
        asksForName = (user.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Step 1

    /// The web's Continue: needs a role.
    var canContinue: Bool { chosen != nil }

    func continueToDetails() {
        guard canContinue else { return }
        step = .details
    }

    // MARK: - Step 2

    func back() {
        saveError = nil
        step = .role
    }

    var isSaving: Bool { profile.isSaving }

    /// "Start working". Saves the details when they changed, and reports whether the welcome is
    /// done. `false` means the save failed and `saveError` says why.
    func finishWithDetails() async -> Bool {
        guard !profile.isSaving else { return false }
        saveError = nil
        // Nothing typed, or nothing different from the account: nothing to write.
        guard profile.hasChanges else { return true }
        if await profile.save() { return true }
        saveError = profile.saveError ?? ProfileEditor.Copy.notSaved
        return false
    }
}
