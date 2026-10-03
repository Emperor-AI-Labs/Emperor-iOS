import SwiftUI

// `Practice` itself — the role, and how it is kept in step with the account — lives in the core
// (`Sources/EmperorCore/Practice.swift`), where it is tested. This hands it down the view tree.
//
// Shaped after `Theme` for the same reason: one object in the environment, so a screen cannot
// quietly read a different role from the one the rest of the app is using.

/// Classic `EnvironmentKey` rather than `@Entry`, which is iOS 18 — the deployment target is 17.
private struct PracticeKey: @preconcurrency EnvironmentKey {
    /// Defaults to the default role, so a preview or a detached view has a toolkit rather than
    /// an empty one.
    @MainActor static let defaultValue = Practice(store: InMemoryPreferenceStore())
}

extension EnvironmentValues {
    var practice: Practice {
        get { self[PracticeKey.self] }
        set { self[PracticeKey.self] = newValue }
    }
}
