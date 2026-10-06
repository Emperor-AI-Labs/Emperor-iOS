import XCTest
@testable import EmperorCore

/// Stands in for Face ID: answers from a queue, `.success` once it runs out, and can act while
/// its prompt is "on screen" — which is where iOS makes the scene inactive.
@MainActor
final class FakeAppLockAuthenticator: AppLockAuthenticating {
    var available: AppLockAvailability = .available(.faceID)
    var outcomes: [AppLockAuthOutcome] = []
    /// Runs while the prompt is up, before it answers.
    var whilePrompting: (() -> Void)?
    /// Keeps the prompt up until `answerHeldPrompt()`, so a test can act while it is.
    var holdsPrompts = false
    private(set) var reasons: [String] = []
    private var held: CheckedContinuation<Void, Never>?

    var prompts: Int { reasons.count }
    var isHoldingPrompt: Bool { held != nil }

    func availability() -> AppLockAvailability { available }

    func authenticate(reason: String) async -> AppLockAuthOutcome {
        reasons.append(reason)
        whilePrompting?()
        if holdsPrompts {
            await withCheckedContinuation { held = $0 }
        }
        return outcomes.isEmpty ? .success : outcomes.removeFirst()
    }

    func answerHeldPrompt() {
        held?.resume()
        held = nil
    }
}

/// A clock a test can move — forwards, or back.
@MainActor
final class FakeAppLockClock {
    var now: TimeInterval = 10_000
}

// MARK: - The decision

/// "Should the app lock now?" — every boundary, with nothing else involved.
final class AppLockPolicyTests: XCTestCase {

    private func resume(
        away: TimeInterval, timeout: AppLockTimeout = .oneMinute,
        isEnabled: Bool = true, isSignedIn: Bool = true
    ) -> Bool {
        AppLockPolicy.shouldLock(
            .resume(leftAt: 500, now: 500 + away),
            isEnabled: isEnabled, timeout: timeout, isSignedIn: isSignedIn)
    }

    func testALaunchWithSomeoneSignedInLocks() {
        XCTAssertTrue(AppLockPolicy.shouldLock(
            .launch, isEnabled: true, timeout: .oneHour, isSignedIn: true))
    }

    /// Off is off: not at launch, not after a day away.
    func testTheLockOffNeverLocks() {
        XCTAssertFalse(AppLockPolicy.shouldLock(
            .launch, isEnabled: false, timeout: .immediately, isSignedIn: true))
        XCTAssertFalse(resume(away: 86_400, timeout: .immediately, isEnabled: false))
        XCTAssertFalse(AppLockPolicy.shouldLock(
            .resume(leftAt: nil, now: 0), isEnabled: false, timeout: .immediately, isSignedIn: true))
    }

    /// The login screen is never locked: nothing behind it to protect.
    func testNobodySignedInNeverLocks() {
        XCTAssertFalse(AppLockPolicy.shouldLock(
            .launch, isEnabled: true, timeout: .immediately, isSignedIn: false))
        XCTAssertFalse(resume(away: 86_400, timeout: .immediately, isSignedIn: false))
    }

    /// "After 1 minute" means a minute away locks — exactly at it, not only past it.
    func testExactlyAtTheTimeoutLocks() {
        XCTAssertFalse(resume(away: 59.999))
        XCTAssertTrue(resume(away: 60))
        XCTAssertTrue(resume(away: 60.001))
    }

    func testEveryTimeoutAtItsBoundary() {
        for timeout in AppLockTimeout.allCases {
            XCTAssertTrue(resume(away: timeout.seconds, timeout: timeout), "\(timeout) at the timeout")
            XCTAssertTrue(resume(away: timeout.seconds + 1, timeout: timeout), "\(timeout) past it")
            if timeout != .immediately {
                XCTAssertFalse(
                    resume(away: timeout.seconds - 0.5, timeout: timeout), "\(timeout) just short")
            }
        }
    }

    /// Immediately: any return from the background at all — even one the clock cannot measure.
    func testImmediatelyLocksOnEveryReturn() {
        XCTAssertTrue(resume(away: 0, timeout: .immediately))
        XCTAssertTrue(resume(away: 0.001, timeout: .immediately))
    }

    /// A reading earlier than the one taken on leaving means the time away is unknown, and an
    /// unknown time away is not one known to be short.
    func testAClockGoingBackwardsLocks() {
        XCTAssertTrue(resume(away: -1, timeout: .oneHour))
        XCTAssertTrue(resume(away: -86_400, timeout: .oneHour))
    }

    func testAReturnWithNoRecordOfLeavingLocks() {
        XCTAssertTrue(AppLockPolicy.shouldLock(
            .resume(leftAt: nil, now: 500), isEnabled: true, timeout: .oneHour, isSignedIn: true))
    }

    func testAReadingThatIsNotANumberLocks() {
        XCTAssertTrue(AppLockPolicy.shouldLock(
            .resume(leftAt: 500, now: .nan), isEnabled: true, timeout: .oneHour, isSignedIn: true))
        XCTAssertTrue(AppLockPolicy.shouldLock(
            .resume(leftAt: .nan, now: 500), isEnabled: true, timeout: .oneHour, isSignedIn: true))
    }

    /// The clock time away is measured on only moves forward.
    func testTheClockNeverRunsBackwards() {
        let first = AppLockClock.now()
        let second = AppLockClock.now()
        XCTAssertGreaterThanOrEqual(first, 0)
        XCTAssertGreaterThanOrEqual(second, first)
    }
}

// MARK: - What is stored

final class AppLockSettingsTests: XCTestCase {

    /// A fresh install: off, and a minute when it is turned on.
    func testNothingStoredIsOffWithTheDefaultTimeout() {
        let settings = AppLockSettings.stored(in: InMemoryPreferenceStore())
        XCTAssertFalse(settings.isEnabled)
        XCTAssertEqual(settings.timeout, .oneMinute)
        XCTAssertEqual(AppLockTimeout.default, .oneMinute)
    }

    func testAChoiceIsReadBackAsWritten() {
        let store = InMemoryPreferenceStore()
        for timeout in AppLockTimeout.allCases {
            AppLockSettings(isEnabled: true, timeout: timeout).save(to: store)
            XCTAssertEqual(
                AppLockSettings.stored(in: store), AppLockSettings(isEnabled: true, timeout: timeout))
        }
        AppLockSettings(isEnabled: false, timeout: .fiveMinutes).save(to: store)
        XCTAssertEqual(
            AppLockSettings.stored(in: store), AppLockSettings(isEnabled: false, timeout: .fiveMinutes))
    }

    /// Written by a build that offered a choice this one does not: read as the strictest, so a
    /// downgrade can never loosen the lock.
    func testAnUnknownTimeoutReadsAsTheStrictest() {
        let store = InMemoryPreferenceStore([AppLockSettings.enabledKey: true])
        for raw in ["fourHours", "", "ONE_MINUTE", "60"] {
            store.setString(raw, for: AppLockTimeout.storageKey)
            let settings = AppLockSettings.stored(in: store)
            XCTAssertTrue(settings.isEnabled, "an unreadable timeout must not switch the lock off")
            XCTAssertEqual(settings.timeout, .immediately, "“\(raw)”")
        }
    }

    /// These are written to the device. Renaming one would silently reset everyone's choice.
    func testTheStoredValuesArePinned() {
        XCTAssertEqual(AppLockSettings.enabledKey, "applock.enabled.v1")
        XCTAssertEqual(AppLockTimeout.storageKey, "applock.timeout.v1")
        XCTAssertEqual(
            AppLockTimeout.allCases.map(\.rawValue),
            ["immediately", "oneMinute", "fiveMinutes", "fifteenMinutes", "oneHour"])
    }

    func testTheChoicesAreTheOnesOffered() {
        XCTAssertEqual(
            AppLockTimeout.allCases.map(\.label),
            ["Immediately", "After 1 minute", "After 5 minutes", "After 15 minutes", "After 1 hour"])
        XCTAssertEqual(AppLockTimeout.allCases.map(\.seconds), [0, 60, 300, 900, 3_600])
    }

    /// The switch is named for what the device will actually ask for.
    func testTheSwitchIsNamedForTheDevice() {
        XCTAssertEqual(AppLockBiometry.faceID.requireTitle, "Require Face ID")
        XCTAssertEqual(AppLockBiometry.touchID.requireTitle, "Require Touch ID")
        XCTAssertEqual(AppLockBiometry.opticID.requireTitle, "Require Optic ID")
        XCTAssertEqual(AppLockBiometry.none.requireTitle, "Require passcode")
        XCTAssertEqual(AppLockCopy.unlockHint(.none), "Unlock with your passcode to see your matters.")
        XCTAssertEqual(AppLockCopy.unlockHint(.faceID), "Unlock with Face ID to see your matters.")
        XCTAssertTrue(AppLockCopy.footer(isEnabled: false, biometry: .touchID).contains("Touch ID"))
        XCTAssertTrue(AppLockCopy.footer(isEnabled: true, biometry: .none).contains("your passcode"))
    }
}

// MARK: - The lock

@MainActor
final class AppLockTests: XCTestCase {

    private struct Harness {
        let lock: AppLock
        let auth: FakeAppLockAuthenticator
        let clock: FakeAppLockClock
        let store: InMemoryPreferenceStore
    }

    /// A lock in a scene that is up and active, the lock set as given.
    private func harness(
        enabled: Bool = true, timeout: AppLockTimeout = .oneMinute,
        promptsAutomatically: Bool = true, active: Bool = true
    ) -> Harness {
        let store = InMemoryPreferenceStore()
        AppLockSettings(isEnabled: enabled, timeout: timeout).save(to: store)
        let auth = FakeAppLockAuthenticator()
        let clock = FakeAppLockClock()
        let lock = AppLock(
            store: store, authenticator: auth, clock: { clock.now },
            promptsAutomatically: promptsAutomatically)
        if active { lock.scenePhaseChanged(to: .active) }
        return Harness(lock: lock, auth: auth, clock: clock, store: store)
    }

    /// Signed in, unlocked, and in front — where every return test starts.
    private func signedInAndUnlocked(
        timeout: AppLockTimeout = .oneMinute
    ) async -> Harness {
        let h = harness(timeout: timeout)
        h.lock.sessionChanged(isSignedIn: nil)
        h.lock.sessionChanged(isSignedIn: true)
        await h.lock.promptIfDue()
        XCTAssertFalse(h.lock.isLocked, "setup: the launch prompt unlocks")
        return h
    }

    /// Away to the background for `seconds`, then back to active.
    private func goAway(_ h: Harness, for seconds: TimeInterval) {
        h.lock.scenePhaseChanged(to: .inactive)
        h.lock.scenePhaseChanged(to: .background)
        h.clock.now += seconds
        h.lock.scenePhaseChanged(to: .inactive)
        h.lock.scenePhaseChanged(to: .active)
    }

    // MARK: Launch

    func testALaunchWithASessionOpensLocked() {
        let h = harness(promptsAutomatically: false)
        h.lock.sessionChanged(isSignedIn: nil)
        XCTAssertFalse(h.lock.isLocked, "nothing is decided while the session is read")
        h.lock.sessionChanged(isSignedIn: true)
        XCTAssertTrue(h.lock.isLocked)
        XCTAssertEqual(h.lock.cover, .locked)
    }

    /// The session can already be read by the time the lock first hears of it.
    func testASessionAlreadyReadAtFirstSightIsStillTheLaunch() {
        let h = harness(promptsAutomatically: false)
        h.lock.sessionChanged(isSignedIn: true)
        XCTAssertTrue(h.lock.isLocked)
    }

    func testTheLockOffOpensUnlocked() {
        let h = harness(enabled: false)
        h.lock.sessionChanged(isSignedIn: true)
        XCTAssertFalse(h.lock.isLocked)
        XCTAssertNil(h.lock.cover)
    }

    /// Signed out at launch: the login screen, never locked — and whoever then signs in has just
    /// typed the password, so is not asked for Face ID on top of it.
    func testTheLoginScreenIsNeverLockedNorIsSigningInFromIt() {
        let h = harness(timeout: .immediately)
        h.lock.sessionChanged(isSignedIn: false)
        XCTAssertFalse(h.lock.isLocked)
        h.lock.sessionChanged(isSignedIn: true)
        XCTAssertFalse(h.lock.isLocked, "signing in is not a launch")
        XCTAssertEqual(h.auth.prompts, 0)
    }

    /// The same session read twice is one launch, not two.
    func testOnlyTheFirstReadingIsTheLaunch() async {
        let h = await signedInAndUnlocked()
        h.lock.sessionChanged(isSignedIn: true)
        XCTAssertFalse(h.lock.isLocked)
    }

    // MARK: Asking

    /// The lock asks by itself the moment it is in front of someone, and success lifts it.
    func testTheLockAsksByItselfAndUnlocks() async {
        let h = harness()
        h.lock.sessionChanged(isSignedIn: true)
        await h.lock.promptIfDue()
        XCTAssertEqual(h.auth.reasons, [AppLockCopy.unlockReason])
        XCTAssertFalse(h.lock.isLocked)
        XCTAssertNil(h.lock.cover)
        XCTAssertFalse(h.lock.isAuthenticating)
    }

    /// Dismissed, or not recognised: still locked, with the button. And not asked again by
    /// itself — the prompt's own coming and going makes the scene active again, and asking on
    /// that would put the prompt straight back.
    func testACancelledOrFailedPromptLeavesItLockedAndDoesNotAskAgainByItself() async {
        for outcome in [AppLockAuthOutcome.cancelled, .failed, .unavailable] {
            let h = harness()
            h.auth.outcomes = [outcome]
            h.auth.whilePrompting = { [lock = h.lock] in lock.scenePhaseChanged(to: .inactive) }
            h.lock.sessionChanged(isSignedIn: true)
            await h.lock.promptIfDue()
            h.auth.whilePrompting = nil
            h.lock.scenePhaseChanged(to: .active)
            await h.lock.promptIfDue()

            XCTAssertTrue(h.lock.isLocked, "\(outcome)")
            XCTAssertEqual(h.lock.cover, .locked)
            XCTAssertEqual(h.auth.prompts, 1, "\(outcome): asked again by itself")
            XCTAssertNil(h.lock.notice, "nothing to report on the lock screen")

            // The button asks again, and this time it works.
            await h.lock.unlock()
            XCTAssertFalse(h.lock.isLocked, "\(outcome)")
            XCTAssertEqual(h.auth.prompts, 2)
        }
    }

    /// Decided while the scene is still coming up: the prompt waits until it is in front.
    func testItDoesNotAskUntilTheSceneIsActive() async {
        let h = harness(active: false)
        h.lock.sessionChanged(isSignedIn: true)
        await h.lock.promptIfDue()
        XCTAssertEqual(h.auth.prompts, 0)
        XCTAssertTrue(h.lock.isLocked)

        h.lock.scenePhaseChanged(to: .active)
        await h.lock.promptIfDue()
        XCTAssertEqual(h.auth.prompts, 1)
        XCTAssertFalse(h.lock.isLocked)
    }

    /// The UI tests' stand-in answers at once, so there the lock waits for its button.
    func testWithoutAutomaticPromptsOnlyTheButtonAsks() async {
        let h = harness(promptsAutomatically: false)
        h.lock.sessionChanged(isSignedIn: true)
        await h.lock.promptIfDue()
        XCTAssertEqual(h.auth.prompts, 0)
        XCTAssertTrue(h.lock.isLocked)
        await h.lock.unlock()
        XCTAssertFalse(h.lock.isLocked)
    }

    /// A second tap on Unlock while the prompt is up is not a second prompt.
    func testOnePromptAtATime() async {
        let h = harness(promptsAutomatically: false)
        h.lock.sessionChanged(isSignedIn: true)
        h.auth.holdsPrompts = true
        let first = Task { await h.lock.unlock() }
        var turns = 0
        while !h.auth.isHoldingPrompt && turns < 1_000 {
            await Task.yield()
            turns += 1
        }
        XCTAssertTrue(h.lock.isAuthenticating)

        await h.lock.unlock()
        await h.lock.promptIfDue()
        XCTAssertEqual(h.auth.prompts, 1)

        h.auth.answerHeldPrompt()
        await first.value
        XCTAssertFalse(h.lock.isAuthenticating)
        XCTAssertFalse(h.lock.isLocked)
    }

    /// Unlocked already: nothing to ask.
    func testUnlockingAnUnlockedAppAsksNothing() async {
        let h = await signedInAndUnlocked()
        await h.lock.unlock()
        XCTAssertEqual(h.auth.prompts, 1, "only the launch prompt")
    }

    // MARK: Coming back

    func testComingBackBeforeTheTimeoutStaysUnlocked() async {
        let h = await signedInAndUnlocked(timeout: .fiveMinutes)
        goAway(h, for: 299)
        XCTAssertFalse(h.lock.isLocked)
        XCTAssertNil(h.lock.cover)
    }

    func testComingBackAtTheTimeoutLocksAndAsks() async {
        let h = await signedInAndUnlocked(timeout: .fiveMinutes)
        goAway(h, for: 300)
        XCTAssertTrue(h.lock.isLocked)
        await h.lock.promptIfDue()
        XCTAssertEqual(h.auth.prompts, 2, "asked again on return")
        XCTAssertFalse(h.lock.isLocked)
    }

    /// Locked the moment it returns, before it is active again — so the first thing drawn on the
    /// way back is the lock, not the matter.
    func testTheLockIsInPlaceBeforeTheSceneIsActive() async {
        let h = await signedInAndUnlocked(timeout: .immediately)
        h.lock.scenePhaseChanged(to: .inactive)
        h.lock.scenePhaseChanged(to: .background)
        h.lock.scenePhaseChanged(to: .inactive)
        XCTAssertEqual(h.lock.cover, .locked)
    }

    /// Notification Centre, or Control Centre, held down for an hour: inactive, never in the
    /// background — so never away.
    func testInactiveWithoutTheBackgroundIsNotAway() async {
        let h = await signedInAndUnlocked(timeout: .immediately)
        h.lock.scenePhaseChanged(to: .inactive)
        h.clock.now += 3_600
        h.lock.scenePhaseChanged(to: .active)
        XCTAssertFalse(h.lock.isLocked)
    }

    func testAClockGoingBackwardsWhileAwayLocks() async {
        let h = await signedInAndUnlocked(timeout: .oneHour)
        goAway(h, for: -120)
        XCTAssertTrue(h.lock.isLocked)
    }

    /// Left while still locked: on return it asks by itself again, once.
    func testLeavingWhileLockedAsksAgainOnReturn() async {
        let h = harness()
        h.auth.outcomes = [.cancelled, .cancelled]
        h.lock.sessionChanged(isSignedIn: true)
        await h.lock.promptIfDue()
        XCTAssertEqual(h.auth.prompts, 1)

        goAway(h, for: 1)
        XCTAssertTrue(h.lock.isLocked)
        await h.lock.promptIfDue()
        XCTAssertEqual(h.auth.prompts, 2)
        await h.lock.promptIfDue()
        XCTAssertEqual(h.auth.prompts, 2)
    }

    /// Turned off before leaving: the return does not lock, however long it was.
    func testTurnedOffWhileAwayNothingLocksOnReturn() async {
        let h = await signedInAndUnlocked(timeout: .immediately)
        await h.lock.setEnabled(false)
        goAway(h, for: 3_600)
        XCTAssertFalse(h.lock.isLocked)
    }

    // MARK: The privacy cover

    /// Whenever the scene is not active, lock or no lock, the brand covers the app — so the app
    /// switcher's picture never shows a matter.
    func testThePrivacyCoverIsUpWheneverTheSceneIsNot() {
        let h = harness(enabled: false)
        h.lock.sessionChanged(isSignedIn: true)
        XCTAssertNil(h.lock.cover)
        h.lock.scenePhaseChanged(to: .inactive)
        XCTAssertEqual(h.lock.cover, .privacy)
        h.lock.scenePhaseChanged(to: .background)
        XCTAssertEqual(h.lock.cover, .privacy)
        h.lock.scenePhaseChanged(to: .inactive)
        XCTAssertEqual(h.lock.cover, .privacy)
        h.lock.scenePhaseChanged(to: .active)
        XCTAssertNil(h.lock.cover)
    }

    /// A scene still launching has drawn nothing; covering it would only flash the brand.
    func testNoCoverWhileTheSceneIsStillLaunching() {
        let h = harness(enabled: false, active: false)
        XCTAssertNil(h.lock.cover)
        h.lock.sessionChanged(isSignedIn: true)
        XCTAssertNil(h.lock.cover)
        // A launch straight into the background is covered, though.
        h.lock.scenePhaseChanged(to: .background)
        XCTAssertEqual(h.lock.cover, .privacy)
    }

    func testNoPrivacyCoverOverTheLoginScreen() {
        let h = harness()
        h.lock.sessionChanged(isSignedIn: false)
        h.lock.scenePhaseChanged(to: .inactive)
        XCTAssertNil(h.lock.cover)
        h.lock.scenePhaseChanged(to: .background)
        XCTAssertNil(h.lock.cover)
    }

    /// Before the session is read, the cover is drawn: unknown is not known to be safe.
    func testThePrivacyCoverIsUpWhileTheSessionIsUnread() {
        let h = harness()
        h.lock.scenePhaseChanged(to: .inactive)
        XCTAssertEqual(h.lock.cover, .privacy)
    }

    /// Turning the lock on raises this app's own prompt, which makes the scene inactive. The
    /// cover must not slide over Settings for it — whether the answer comes before the scene is
    /// active again or after.
    func testThisAppsOwnPromptDoesNotDrawTheCover() async {
        for answersFirst in [true, false] {
            let h = harness(enabled: false)
            h.lock.sessionChanged(isSignedIn: true)
            var coversDuringPrompt: [AppLock.Cover?] = []
            h.auth.whilePrompting = { [lock = h.lock] in
                lock.scenePhaseChanged(to: .inactive)
                coversDuringPrompt.append(lock.cover)
                if !answersFirst { lock.scenePhaseChanged(to: .active) }
            }
            await h.lock.setEnabled(true)
            XCTAssertEqual(coversDuringPrompt, [nil], "covered during the prompt")
            XCTAssertNil(h.lock.cover, "covered between the answer and the scene's return")
            h.lock.scenePhaseChanged(to: .active)
            XCTAssertNil(h.lock.cover)

            // Once the prompt is over, the next time the scene steps back it is covered again.
            h.lock.scenePhaseChanged(to: .inactive)
            XCTAssertEqual(h.lock.cover, .privacy, "answersFirst: \(answersFirst)")
        }
    }

    /// Leaving the app with the prompt up is really leaving: covered.
    func testLeavingDuringThisAppsPromptIsCovered() async {
        let h = harness(enabled: false)
        h.lock.sessionChanged(isSignedIn: true)
        h.auth.outcomes = [.cancelled]
        h.auth.whilePrompting = { [lock = h.lock] in
            lock.scenePhaseChanged(to: .inactive)
            lock.scenePhaseChanged(to: .background)
        }
        await h.lock.setEnabled(true)
        XCTAssertEqual(h.lock.cover, .privacy)
        XCTAssertFalse(h.lock.isEnabled)
    }

    // MARK: Turning it on and off

    /// On only after the device has confirmed who is holding it.
    func testTurningOnAsksFirstAndIsStored() async {
        let h = harness(enabled: false)
        var switchDuringPrompt = false
        h.auth.whilePrompting = { [lock = h.lock] in switchDuringPrompt = lock.switchIsOn }
        await h.lock.setEnabled(true)

        XCTAssertEqual(h.auth.reasons, [AppLockCopy.turnOnReason])
        XCTAssertTrue(switchDuringPrompt, "the switch shows on while the prompt is up")
        XCTAssertTrue(h.lock.isEnabled)
        XCTAssertTrue(h.lock.switchIsOn)
        XCTAssertFalse(h.lock.isTurningOn)
        XCTAssertTrue(AppLockSettings.stored(in: h.store).isEnabled)
        XCTAssertFalse(h.lock.isLocked, "turning it on does not lock the app in front of you")
    }

    func testACancelledPromptLeavesItOffAndSaysNothing() async {
        let h = harness(enabled: false)
        h.auth.outcomes = [.cancelled]
        await h.lock.setEnabled(true)
        XCTAssertFalse(h.lock.isEnabled)
        XCTAssertFalse(h.lock.switchIsOn, "the switch goes back to off")
        XCTAssertFalse(AppLockSettings.stored(in: h.store).isEnabled)
        XCTAssertNil(h.lock.notice)
    }

    func testAFailedPromptLeavesItOffAndSaysWhy() async {
        let h = harness(enabled: false)
        h.auth.outcomes = [.failed]
        await h.lock.setEnabled(true)
        XCTAssertFalse(h.lock.isEnabled)
        XCTAssertEqual(h.lock.notice, AppLockCopy.notConfirmed)
    }

    /// No device passcode: the lock would have nothing to ask for. Said so, left off, and the
    /// device is not even asked.
    func testNoPasscodeLeavesItOffWithoutAsking() async {
        let h = harness(enabled: false)
        h.auth.available = .passcodeNotSet
        await h.lock.setEnabled(true)
        XCTAssertEqual(h.auth.prompts, 0)
        XCTAssertFalse(h.lock.isEnabled)
        XCTAssertEqual(h.lock.notice, AppLockCopy.needsPasscode)
        XCTAssertFalse(AppLockSettings.stored(in: h.store).isEnabled)
    }

    /// The passcode removed between the check and the prompt.
    func testAPromptThatFindsNoPasscodeLeavesItOff() async {
        let h = harness(enabled: false)
        h.auth.outcomes = [.passcodeNotSet]
        await h.lock.setEnabled(true)
        XCTAssertFalse(h.lock.isEnabled)
        XCTAssertEqual(h.lock.notice, AppLockCopy.needsPasscode)
        XCTAssertEqual(h.lock.biometry, .none)
    }

    func testUnavailableLeavesItOffAndSaysWhy() async {
        let h = harness(enabled: false)
        h.auth.available = .unavailable
        await h.lock.setEnabled(true)
        XCTAssertEqual(h.auth.prompts, 0)
        XCTAssertFalse(h.lock.isEnabled)
        XCTAssertEqual(h.lock.notice, AppLockCopy.unavailable)
    }

    /// Off at once, without a prompt.
    func testTurningOffDoesNotAsk() async {
        let h = harness(enabled: true)
        await h.lock.setEnabled(false)
        XCTAssertEqual(h.auth.prompts, 0)
        XCTAssertFalse(h.lock.isEnabled)
        XCTAssertFalse(AppLockSettings.stored(in: h.store).isEnabled)
    }

    /// A notice is about the last attempt; the next touch of the switch clears it.
    func testTheNoticeGoesWithTheNextAttempt() async {
        let h = harness(enabled: false)
        h.auth.outcomes = [.failed]
        await h.lock.setEnabled(true)
        XCTAssertNotNil(h.lock.notice)
        await h.lock.setEnabled(false)
        XCTAssertNil(h.lock.notice)

        h.auth.outcomes = [.failed]
        await h.lock.setEnabled(true)
        await h.lock.setEnabled(true)
        XCTAssertNil(h.lock.notice, "the second attempt succeeded")
        XCTAssertTrue(h.lock.isEnabled)
    }

    func testTurningOnWhenOnAsksNothing() async {
        let h = harness(enabled: true)
        await h.lock.setEnabled(true)
        XCTAssertEqual(h.auth.prompts, 0)
    }

    func testTheTimeoutIsStored() {
        let h = harness()
        h.lock.setTimeout(.fifteenMinutes)
        XCTAssertEqual(h.lock.timeout, .fifteenMinutes)
        XCTAssertEqual(AppLockSettings.stored(in: h.store).timeout, .fifteenMinutes)
    }

    /// The switch and the lock screen say what this device will ask for.
    func testWhatIsAskedForFollowsTheDevice() {
        let h = harness()
        XCTAssertEqual(h.lock.biometry, .faceID)
        h.auth.available = .available(.touchID)
        h.lock.refreshAvailability()
        XCTAssertEqual(h.lock.biometry, .touchID)
        h.auth.available = .passcodeNotSet
        h.lock.refreshAvailability()
        XCTAssertEqual(h.lock.biometry, .none)
        XCTAssertEqual(h.lock.biometry.requireTitle, "Require passcode")
    }

    // MARK: Signing out

    /// Signed out — by hand, or because the account's credentials stopped working — the lock is
    /// lifted: the login screen is never locked.
    func testSigningOutLiftsTheLock() {
        let h = harness(promptsAutomatically: false)
        h.lock.sessionChanged(isSignedIn: true)
        XCTAssertTrue(h.lock.isLocked)
        h.lock.sessionChanged(isSignedIn: false)
        XCTAssertFalse(h.lock.isLocked)
        XCTAssertNil(h.lock.cover)
    }

    /// The setting belongs to the device, not the account: it outlives signing out, and the next
    /// person to sign in here finds it as it was left.
    func testTheSettingSurvivesSigningOut() async {
        let h = await signedInAndUnlocked(timeout: .fifteenMinutes)
        h.lock.sessionChanged(isSignedIn: false)
        XCTAssertEqual(
            AppLockSettings.stored(in: h.store), AppLockSettings(isEnabled: true, timeout: .fifteenMinutes))

        // A new lock reading the same store — the next launch — is still on, and locks.
        let next = AppLock(store: h.store, authenticator: h.auth, promptsAutomatically: false)
        next.scenePhaseChanged(to: .active)
        next.sessionChanged(isSignedIn: true)
        XCTAssertTrue(next.isEnabled)
        XCTAssertTrue(next.isLocked)
    }

    // MARK: A passcode removed while locked

    /// The passcode was removed after the lock went on — which iOS allows only to someone who has
    /// just entered it. There is nothing left to ask for; staying locked would shut the owner out
    /// for good. Unlocked, turned off, and said so.
    func testAPasscodeRemovedWhileLockedTurnsTheLockOff() async {
        let h = harness(promptsAutomatically: false)
        h.lock.sessionChanged(isSignedIn: true)
        h.auth.outcomes = [.passcodeNotSet]
        await h.lock.unlock()
        XCTAssertFalse(h.lock.isLocked)
        XCTAssertFalse(h.lock.isEnabled)
        XCTAssertFalse(AppLockSettings.stored(in: h.store).isEnabled)
        XCTAssertEqual(h.lock.notice, AppLockCopy.turnedOffWithoutPasscode)
    }
}
