import SwiftUI
import UIKit

/// Puts `AppLock`'s cover over the whole app, and tells the lock what it needs to know: the
/// scene's phase, and whether anyone is signed in. When to cover is the core's; this draws it.
///
/// ## Why a window of its own
///
/// A cover drawn inside the root view sits *under* anything presented from it. A sheet, an alert
/// or a confirmation dialog is put above the view that presented it, in a layer of its own — so
/// a cover in `RootView`'s overlay would hide the tab bar and leave the matter open in a sheet on
/// top of it, in plain view in the app switcher. `.fullScreenCover` is no better: it can only be
/// presented from a view that is not already presenting something, so it fails exactly when a
/// sheet is up.
///
/// A second `UIWindow` in the same scene, at a level above alerts, is above all of that — it is
/// what the system's own privacy screens are made of. While it shows:
/// - the app's window is hidden from VoiceOver, sheets included, since they are drawn inside it;
/// - every touch lands on the cover, which is opaque and fills the scene;
/// - when locked, it takes the keyboard focus, and the app's keyboard is put away — the keyboard
///   is drawn in a window of its own, above this one, and would otherwise float over the lock.
struct AppLockShield: ViewModifier {
    @Environment(AppLock.self) private var lock
    @Environment(Session.self) private var session
    @Environment(\.scenePhase) private var scenePhase

    let theme: Theme

    @State private var window = AppLockWindow()

    func body(content: Content) -> some View {
        content
            .background(WindowReader { appWindow in
                window.attach(to: appWindow, lock: lock, theme: theme)
            })
            .onChange(of: scenePhase, initial: true) { _, phase in
                lock.scenePhaseChanged(to: AppLock.Phase(phase))
                // At once, not on the next pass through `cover` below: the app switcher takes
                // its picture of the app as it leaves.
                window.show(lock.cover, theme: theme)
                if phase == .active {
                    Task { await lock.promptIfDue() }
                }
            }
            .onChange(of: signedIn, initial: true) { _, signedIn in
                lock.sessionChanged(isSignedIn: signedIn)
            }
            .onChange(of: lock.cover, initial: true) { _, cover in
                window.show(cover, theme: theme)
                if cover == .locked {
                    Task { await lock.promptIfDue() }
                }
            }
    }

    /// `nil` while the session is still being read from the device.
    private var signedIn: Bool? {
        switch session.state {
        case .loading: return nil
        case .signedOut: return false
        case .signedIn: return true
        }
    }
}

extension View {
    /// The app lock and the privacy cover — see `AppLockShield`. Applied once, at the root.
    func appLockShield(theme: Theme) -> some View {
        modifier(AppLockShield(theme: theme))
    }
}

private extension AppLock.Phase {
    init(_ phase: SwiftUI.ScenePhase) {
        switch phase {
        case .active: self = .active
        case .background: self = .background
        // Inactive, and any phase a later SwiftUI adds: not in front, so covered.
        default: self = .inactive
        }
    }
}

// MARK: - The window

/// The cover's window, laid over the scene the app is drawn in.
@MainActor
final class AppLockWindow {
    private var overlay: UIWindow?
    private weak var appWindow: UIWindow?
    private var shown: AppLock.Cover?

    /// Made once per app window, the first time the app's views are in one.
    func attach(to window: UIWindow, lock: AppLock, theme: Theme) {
        guard window !== appWindow, window !== overlay, let scene = window.windowScene else {
            return
        }
        overlay?.isHidden = true
        appWindow = window

        let host = UIHostingController(rootView: AppLockCoverView(lock: lock, theme: theme))
        host.view.backgroundColor = .clear
        // VoiceOver stays inside the cover. The app's window is hidden from it as well (`show`):
        // this alone only hides siblings within the same window.
        host.view.accessibilityViewIsModal = true

        let overlay = UIWindow(windowScene: scene)
        overlay.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
        overlay.rootViewController = host
        overlay.isHidden = true
        self.overlay = overlay
        shown = nil
        show(lock.cover, theme: theme)
    }

    func show(_ cover: AppLock.Cover?, theme: Theme) {
        guard let overlay, let appWindow else { return }
        let wasLocked = shown == .locked
        shown = cover

        guard let cover else {
            appWindow.accessibilityElementsHidden = false
            if overlay.isKeyWindow { appWindow.makeKey() }
            overlay.isHidden = true
            if wasLocked { UIAccessibility.post(notification: .screenChanged, argument: nil) }
            return
        }

        // Opaque from its very first frame, before SwiftUI has drawn anything into it.
        overlay.backgroundColor = UIColor(theme.canvas)
        appWindow.accessibilityElementsHidden = true
        switch cover {
        case .locked:
            if !wasLocked { appWindow.endEditing(true) }
            overlay.makeKeyAndVisible()
            if !wasLocked { UIAccessibility.post(notification: .screenChanged, argument: nil) }
        case .privacy:
            // Shown, not made key: the app is coming straight back, and its keyboard focus with it.
            overlay.isHidden = false
        }
    }
}

/// Hands over the `UIWindow` the app is drawn in, once it is in one.
private struct WindowReader: UIViewRepresentable {
    let onWindow: (UIWindow) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.onWindow = onWindow
        return view
    }

    func updateUIView(_ view: ReaderView, context: Context) {
        view.onWindow = onWindow
    }

    final class ReaderView: UIView {
        var onWindow: ((UIWindow) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}

// MARK: - The cover

/// What the cover draws: the brand alone while the app is out of sight, and when it is locked,
/// the brand, what is locked, and the way back in.
///
/// Hosted in its own window, so it is handed the theme rather than finding it in the environment.
struct AppLockCoverView: View {
    let lock: AppLock
    let theme: Theme

    var body: some View {
        AppLockCoverContent(lock: lock)
            .environment(\.theme, theme)
            .preferredColorScheme(theme.colorScheme)
            .tint(theme.accent)
    }
}

private struct AppLockCoverContent: View {
    @Environment(\.theme) private var theme
    let lock: AppLock

    var body: some View {
        let isLocked = lock.cover == .locked
        let titleStyle: Font.TextStyle = isLocked ? .title2 : .largeTitle
        // Centred while it fits, scrolling once Dynamic Type makes it taller than the screen —
        // the Unlock button must stay reachable at every text size. `EmptyStateView`'s shape.
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: Spacing.xxl) {
                    // The sign-in screen's mark, so the cover reads as the app, not a blank.
                    VStack(spacing: Spacing.lg) {
                        Image("EmperorMark")
                            .resizable()
                            .scaledToFit()
                            .frame(height: 56)
                            .accessibilityHidden(true)
                        Text(isLocked ? AppLockCopy.lockedTitle : "Emperor")
                            .font(.brand(titleStyle, weight: .bold))
                            .foregroundStyle(theme.textPrimary)
                            .multilineTextAlignment(.center)
                            .accessibilityAddTraits(.isHeader)
                    }

                    if isLocked {
                        VStack(spacing: Spacing.xl) {
                            Text(AppLockCopy.unlockHint(lock.biometry))
                                .font(.brand(.subheadline))
                                .foregroundStyle(theme.textSecondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)

                            Button {
                                Task { await lock.unlock() }
                            } label: {
                                Label(AppLockCopy.unlock, systemImage: lock.biometry.systemImage)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.primaryAction)
                            .disabled(lock.isAuthenticating)
                            .frame(maxWidth: 320)
                            .accessibilityIdentifier("app-lock-unlock")
                        }
                    }
                }
                .frame(maxWidth: 440)
                .padding(.horizontal, Spacing.xxl)
                .padding(.vertical, Spacing.xxxl)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
        .background(theme.canvas.ignoresSafeArea())
    }
}
