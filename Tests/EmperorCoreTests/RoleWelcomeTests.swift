import XCTest
@testable import EmperorCore

/// When the first-sign-in role choice appears, and that it appears only once.
final class RoleWelcomeTests: XCTestCase {

    /// A fresh install: the sign-in screen is shown, the user signs in, and is asked.
    func testAFirstSignInOnThisDeviceIsAsked() {
        let store = InMemoryPreferenceStore()
        XCTAssertFalse(RoleWelcome.shouldShow(store, isSignedIn: false))
        RoleWelcome.noteSignInShown(store)
        XCTAssertFalse(RoleWelcome.shouldShow(store, isSignedIn: false), "not while still signed out")
        XCTAssertTrue(RoleWelcome.shouldShow(store, isSignedIn: true))
    }

    /// A session restored from the Keychain never passed the sign-in screen. Someone already
    /// using the app is not greeted as new.
    func testARestoredSessionIsNotAsked() {
        let store = InMemoryPreferenceStore()
        XCTAssertFalse(RoleWelcome.shouldShow(store, isSignedIn: true))
    }

    func testChoosingSettlesItAndSavesTheRole() {
        let store = InMemoryPreferenceStore()
        RoleWelcome.noteSignInShown(store)
        RoleWelcome.finish(choosing: .corporateCounsel, in: store)

        XCTAssertFalse(RoleWelcome.shouldShow(store, isSignedIn: true))
        XCTAssertEqual(PractitionerRole.stored(in: store), .corporateCounsel)
    }

    /// Skipping is an answer too, and leaves the default in force.
    func testSkippingSettlesItAndLeavesTheDefault() {
        let store = InMemoryPreferenceStore()
        RoleWelcome.noteSignInShown(store)
        RoleWelcome.finish(choosing: nil, in: store)

        XCTAssertFalse(RoleWelcome.shouldShow(store, isSignedIn: true))
        XCTAssertEqual(PractitionerRole.stored(in: store), .default)
    }

    /// Answered once, never asked again — including after signing out and back in, which shows
    /// the sign-in screen a second time.
    func testItIsNotAskedAgainAfterSigningOutAndIn() {
        for choice in [PractitionerRole.paralegal, nil] {
            let store = InMemoryPreferenceStore()
            RoleWelcome.noteSignInShown(store)
            RoleWelcome.finish(choosing: choice, in: store)

            RoleWelcome.noteSignInShown(store)
            XCTAssertFalse(
                RoleWelcome.shouldShow(store, isSignedIn: true),
                "asked again after \(choice.map(\.label) ?? "skipping")")
        }
    }

    /// Leaving the app with the question on screen does not answer it.
    func testAnUnansweredQuestionIsStillOwedNextLaunch() {
        let store = InMemoryPreferenceStore()
        RoleWelcome.noteSignInShown(store)
        // The app is closed here; the next launch restores the session without the sign-in
        // screen, and the stored flags are all that carries over.
        XCTAssertTrue(RoleWelcome.shouldShow(store, isSignedIn: true))
    }

    /// A role chosen in Settings is an answer.
    func testARoleChosenInSettingsIsAnAnswer() {
        let store = InMemoryPreferenceStore()
        PractitionerRole.student.save(to: store)
        RoleWelcome.noteSignInShown(store)
        XCTAssertFalse(RoleWelcome.shouldShow(store, isSignedIn: true))
        // Settled for good, not merely hidden while the role happens to be stored.
        XCTAssertTrue(store.bool(for: RoleWelcome.completedKey))
    }

    func testARoleChosenInSettingsWhileOwedAlsoSettlesIt() {
        let store = InMemoryPreferenceStore()
        RoleWelcome.noteSignInShown(store)
        PractitionerRole.adjudicator.save(to: store)
        XCTAssertFalse(RoleWelcome.shouldShow(store, isSignedIn: true))
    }

    // MARK: - What it offers

    /// The web's eight roles, Devil's Advocate last, as the web's onboarding lists them.
    func testItOffersTheWebsEightRoles() {
        XCTAssertEqual(RoleWelcome.roles, PractitionerRole.allCases)
        XCTAssertEqual(RoleWelcome.roles.count, 8)
        XCTAssertEqual(RoleWelcome.roles.last, .devilsAdvocate)
    }

    func testTheGreetingUsesTheFirstName() {
        XCTAssertEqual(RoleWelcome.greeting(for: "Asha  Mehta"), "Welcome, Asha.")
        XCTAssertEqual(RoleWelcome.greeting(for: "  Ravi"), "Welcome, Ravi.")
        XCTAssertEqual(RoleWelcome.greeting(for: nil), "Welcome.")
        XCTAssertEqual(RoleWelcome.greeting(for: "   "), "Welcome.")
    }
}
