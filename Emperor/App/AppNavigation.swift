import SwiftUI

/// The signed-in app's `AppNavigator`, handed down the view tree by `MainTabView`.
///
/// A classic `EnvironmentKey` rather than `@Entry`, which is iOS 18 — the deployment target is
/// 17 — and the same shape as `Practice`'s. The default is a navigator nothing listens to, so a
/// screen drawn outside the tab bar still has one to talk to; a request made through it simply
/// goes nowhere rather than crashing the app for want of an environment object.
private struct AppNavigatorKey: @preconcurrency EnvironmentKey {
    @MainActor static let defaultValue = AppNavigator()
}

extension EnvironmentValues {
    var navigator: AppNavigator {
        get { self[AppNavigatorKey.self] }
        set { self[AppNavigatorKey.self] = newValue }
    }
}
