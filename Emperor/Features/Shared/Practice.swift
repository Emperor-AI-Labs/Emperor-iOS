import SwiftUI

/// The role the user practises in, handed down the view tree.
///
/// App-level rather than per-conversation, which is how the platform treats it: a role scopes the
/// toolkit and seeds what the model is told, and neither of those is a decision to retake on
/// every question. The per-conversation "Acting as" picker in the chat's own menu still overrides
/// what a single answer is asked for, and deliberately offers the three wire values rather than
/// these seven — see `PractitionerRole.wireRole` for why those are different lists.
///
/// Shaped after `Theme` for the same reason: one object in the environment, so a screen cannot
/// quietly read a different role from the one the rest of the app is using.
@MainActor
@Observable
final class Practice {
    private(set) var role: PractitionerRole

    private let store: any PreferenceStore

    init(store: any PreferenceStore) {
        self.store = store
        self.role = PractitionerRole.stored(in: store)
    }

    func select(_ role: PractitionerRole) {
        self.role = role
        role.save(to: store)
    }
}

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
