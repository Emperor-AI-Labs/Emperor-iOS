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
        }
        #endif
    }

    private static func makeSession() -> Session {
        #if DEBUG
        if UITestSupport.isActive {
            // In-memory everywhere: no Keychain prompt, and no state carried between test runs.
            // Sign-in is not faked — the tests drive the real login screen and the stub answers
            // `/login`, so the whole authentication path is exercised.
            return Session(
                store: InMemoryCredentialStore(),
                cache: ResponseCache(store: InMemoryCacheStore()),
                urlSession: UITestSupport.makeSession())
        }
        #endif
        return Session(
            store: Keychain(),
            cache: ResponseCache(
                store: FileCacheStore(directory: FileCacheStore.defaultDirectory()),
                onClear: { ShareableFile.clear() }))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .task {
                    await session.restore()
                    // The stored user can be weeks old — see `refreshPreferredModel`.
                    await session.refreshPreferredModel()
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
    /// `nil` until read. Read before anything else is shown, so the gate cannot flash past.
    @State private var hasAcknowledgedDisclaimer: Bool?

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
        case .signedIn:
            MainTabView()
        }
    }
}
