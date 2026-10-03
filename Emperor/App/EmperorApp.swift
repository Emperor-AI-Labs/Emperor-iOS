import SwiftUI

@main
struct EmperorApp: App {
    /// Present only to receive `handleEventsForBackgroundURLSession` — see `AppDelegate`.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// The Keychain and the response cache are supplied here because they are the parts of
    /// `Session` that cannot exist in the tested core — everything else about sign-in and
    /// caching lives there.
    /// The Keychain, and a cache whose teardown also wipes the temporary directory share
    /// sheets write PDFs into — those would otherwise outlive the session that fetched them.
    @State private var session = EmperorApp.makeSession()

    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Before any view exists, so the first navigation bar drawn already wears the brand.
        BrandAppearance.apply()

        #if DEBUG
        if UITestSupport.isActive {
            // Both directions have to be set, not just one. `UserDefaults` survives between
            // launches of the same simulator, so a run that acknowledged the gate leaves it
            // acknowledged for every run after it — which is exactly how the gate test first
            // failed, having been made to pass by whichever test ran before it.
            //
            // The gate is a one-per-install decision, so it is pre-acknowledged by default,
            // and `-UITestDisclaimer` actively clears it to test the gate itself.
            let wantsGate = ProcessInfo.processInfo.arguments.contains("-UITestDisclaimer")
            Preferences().setBool(!wantsGate, for: Disclaimer.key)
            // The same rule for appearance: set it every launch, or the screenshot tour's light
            // pass would leave every later run light. Dark is the app's own default.
            let light = ProcessInfo.processInfo.arguments.contains("-UITestLight")
            Preferences().setString(
                (light ? ThemePreference.light : ThemePreference.dark).rawValue,
                for: ThemePreference.storageKey)

            // The first-sign-in role choice, on the same terms: every test signs in through the
            // real login screen, so it would appear in front of all of them. Answered by
            // default; `-UITestRoleWelcome` clears it, and the role with it, to test it.
            let wantsRoleWelcome = ProcessInfo.processInfo.arguments.contains("-UITestRoleWelcome")
            Preferences().setBool(!wantsRoleWelcome, for: RoleWelcome.completedKey)
            Preferences().setBool(false, for: RoleWelcome.pendingKey)
            if wantsRoleWelcome {
                UserDefaults.standard.removeObject(forKey: PractitionerRole.storageKey)
            }
        }
        #endif
    }

    private static func makeSession() -> Session {
        #if DEBUG
        if UITestSupport.isActive {
            // In-memory everywhere: no Keychain prompt, and no state carried between test runs.
            // Sign-in is not faked — the tests drive the real login screen and the stub answers
            // `/login`, so the whole authentication path is exercised.
            let session = Session(
                store: InMemoryCredentialStore(),
                cache: ResponseCache(store: InMemoryCacheStore()),
                urlSession: UITestSupport.makeSession())
            // `-UITestSocial` draws the provider buttons so the screenshot tour can show them;
            // the client id is a placeholder and nothing here can complete a real sign-in.
            if ProcessInfo.processInfo.arguments.contains("-UITestSocial") {
                session.signInFlow.social = SocialSignInConfig(
                    isEnabled: true, googleClientID: "0000-uitest.apps.googleusercontent.com")
            }
            return session
        }
        #endif
        let session = Session(
            store: Keychain(),
            cache: ResponseCache(
                store: FileCacheStore(directory: FileCacheStore.defaultDirectory()),
                onClear: { ShareableFile.clear() }))
        // Off unless the build is configured for it — see `SocialSignInConfig`.
        session.signInFlow.social = SocialSignInConfig(info: Bundle.main.infoDictionary ?? [:])
        return session
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .task {
                    await session.restore()
                    // The stored account can be weeks old, and the token is renewed by reading
                    // it — see `Session.refreshAccount`.
                    await session.refreshAccount()
                    #if DEBUG
                    // A background `URLSession` does not consult `URLProtocol`, so the UI
                    // tests' stub transport cannot reach it — touching the uploader here would
                    // put real requests on the wire from a test run. It is left uncreated
                    // instead, which is also why background upload has no UI test.
                    if UITestSupport.isActive { return }
                    #endif
                    // The uploader outlives every screen, so it is given the client here rather
                    // than by whichever view happened to start a transfer.
                    BackgroundUploader.shared.client = session.client
                    await BackgroundUploader.shared.resume()
                }
                // Becoming active is the moment to re-enqueue anything the system dropped and
                // to poll ingestion for uploads whose bytes all landed while the app was away.
                // It is also when the user is present and most likely back on a usable
                // connection, which is the right time to retry.
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    // A plan bought on the web, or a pause lifted, reaches a phone that was
                    // left open — at most every half hour.
                    Task { await session.refreshAccountIfDue() }
                    #if DEBUG
                    if UITestSupport.isActive { return }
                    #endif
                    Task { await BackgroundUploader.shared.resume() }
                }
        }
    }
}

struct RootView: View {
    @Environment(Session.self) private var session
    /// The device's own setting, so a `.system` preference can resolve.
    @Environment(\.colorScheme) private var systemColorScheme

    private let preferences = Preferences()
    @State private var theme = Theme(store: Preferences())
    /// The role the toolkit is scoped to. Beside the theme because it is the same kind of
    /// thing: one app-wide choice, read by screens that must not disagree about it.
    @State private var practice = Practice(store: Preferences())
    /// `nil` until read. Read before anything else is shown, so the gate cannot flash past.
    @State private var hasAcknowledgedDisclaimer: Bool?
    /// Set once the first-sign-in role choice is answered, so the screen gives way at once. The
    /// stored flags are the record; this only redraws.
    @State private var hasAnsweredRoleWelcome = false

    var body: some View {
        Group {
            if let acknowledged = hasAcknowledgedDisclaimer {
                if acknowledged {
                    signedInContent
                } else {
                    DisclaimerGateView {
                        Disclaimer.acknowledge(preferences)
                        withAnimation { hasAcknowledgedDisclaimer = true }
                    }
                }
            } else {
                ProgressView().controlSize(.large)
            }
        }
        .environment(\.theme, theme)
        .environment(\.practice, practice)
        // Dark unless the user has said otherwise — `ThemePreference.default` is `.dark`.
        .preferredColorScheme(theme.colorScheme)
        .tint(theme.accent)
        .background(theme.canvas.ignoresSafeArea())
        .onAppear { recordDeviceAppearance(systemColorScheme) }
        .onChange(of: systemColorScheme) { _, new in recordDeviceAppearance(new) }
        // Also on the way *into* "Match device", not only when the scheme moves. Releasing the
        // override need not change `systemColorScheme` at all — a dark phone held on an explicit
        // dark leaves it exactly where it was — and then no change fires and the recorded value
        // is whatever it last was. This asks the question again at the one moment the answer
        // starts to matter.
        .onChange(of: theme.preference) { _, _ in recordDeviceAppearance(systemColorScheme) }
        .task {
            if hasAcknowledgedDisclaimer == nil {
                hasAcknowledgedDisclaimer = Disclaimer.hasAcknowledged(preferences)
            }
        }
    }

    /// Record what the *device* asks for, which is not always what this environment reports.
    ///
    /// `preferredColorScheme` above propagates to the window, and the window's override comes
    /// straight back down as `\.colorScheme` — including to this view, which is the one setting
    /// it. So under a `.dark` or `.light` preference `systemColorScheme` echoes our own choice,
    /// and writing it through would file that echo as the device's setting. Pick dark on a light
    /// phone, then switch to "Match device", and the app stays dark until something else moves.
    ///
    /// `Theme.colorScheme` is `nil` exactly when no override is in force, so it doubles as the
    /// test for whether the reading means anything — and that is also the only state in which
    /// `systemIsDark` is ever consulted.
    private func recordDeviceAppearance(_ scheme: ColorScheme) {
        guard theme.colorScheme == nil else { return }
        theme.systemIsDark = scheme == .dark
    }

    @ViewBuilder
    private var signedInContent: some View {
        switch session.state {
        case .loading:
            ProgressView().controlSize(.large)
        case .signedOut:
            LoginView()
                // Whoever signs in from here signs in on this device, which is what makes them
                // owed the role choice — a session restored from the Keychain never passes
                // through this screen. See `RoleWelcome`.
                .onAppear { RoleWelcome.noteSignInShown(preferences) }
        case .signedIn(let user):
            // Read from the store as the state changes rather than in an `onChange`, so the tab
            // bar never draws for a frame in front of the question.
            if !hasAnsweredRoleWelcome && RoleWelcome.shouldShow(preferences, isSignedIn: true) {
                RoleWelcomeView(name: user.name) { chosen in
                    if let chosen { practice.select(chosen) }
                    RoleWelcome.finish(choosing: chosen, in: preferences)
                    withAnimation { hasAnsweredRoleWelcome = true }
                }
            } else {
                MainTabView()
            }
        }
    }
}
