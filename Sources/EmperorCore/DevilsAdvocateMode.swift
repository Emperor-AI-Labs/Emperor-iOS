import Foundation

/// Which side the Devil's Advocate role is attacking — the web's `devilMode`.
///
/// A surfacing toggle, like Legal Aid's Beneficiary / Advocacy: it decides which half of the deck
/// is in view (`src/roles/devilCards.js`, `MODES`), and it is also named at the foot of every tool
/// prompt run while the role is active, so the model knows whose case it is breaking
/// (`devilLine` in `src/tools/ToolWorkspace.jsx`).
///
/// This is the role's deck, not the server-run "Devil's Advocate" analysis under Analysis tools
/// (`DevilsAdvocateResult`). The two share a name on the web too, and stay separate there.
///
/// Kept on the device, as the web keeps it in the browser; the account holds only the role.
enum DevilsAdvocateMode: String, CaseIterable, Identifiable, Sendable {
    /// Building or breaking the opponent's case.
    case opposition
    /// Red-teaming our own.
    case ourSide = "our-side"

    var id: String { rawValue }

    static let `default` = DevilsAdvocateMode.opposition

    /// `MODE_LABEL` on the web — also the text the prompt carries, so it is never reworded here.
    var label: String {
        switch self {
        case .opposition: return "The Other Side"
        case .ourSide: return "Our Own Case"
        }
    }

    // MARK: - Prompts

    /// `ADVERSARIAL_SCOPE` — written into every card's prompt so the role does not drift into
    /// helping the side it is meant to be attacking.
    static let adversarialScope = "Adversarial stance: your ONLY task is to find the argument that defeats the case. Assume you are the best-resourced advocate on the other side. Never bolster the position under attack, never soften a fatal flaw into a survivable one, and never invent authority, evidence or a fact the record does not carry — a candid gap is worth more than a fabricated citation. If the position is sound, say so plainly and identify what would still be needed to break it."

    /// The role-wide guardrail the web appends to every tool prompt while Devil's Advocate is the
    /// role, naming the side under attack. Without it the model defaults to being helpful about
    /// the user's own case, which is the opposite of what the role is for.
    ///
    /// Pinned to the platform's `devilLine` by `DevilsAdvocateRoleTests`.
    var guardrail: String {
        "\n\nDEVIL'S ADVOCATE GUARDRAIL: Your ONLY task is to find the argument that defeats the case — act as the best-resourced advocate on the other side. Do NOT bolster the position under attack, do NOT soften a fatal flaw into a survivable one, and do NOT draft the reply, the cure or the winning argument unless the advocate asks for it. Never invent authority, evidence or a fact the record does not carry; a candid gap beats a fabricated citation. Rank weaknesses by severity and state plainly where the position is genuinely sound. Attacking: \(label)."
    }

    // MARK: - Storage

    static let storageKey = "practitioner.devil.mode.v1"

    /// The stored mode, or the default for an absent or unrecognised value — the web's
    /// `setDevilMode` clamps anything but `our-side` to `opposition` the same way.
    static func stored(in store: any PreferenceStore) -> DevilsAdvocateMode {
        store.string(for: storageKey).flatMap(DevilsAdvocateMode.init(rawValue:)) ?? .default
    }

    func save(to store: any PreferenceStore) {
        store.setString(rawValue, for: Self.storageKey)
    }
}
