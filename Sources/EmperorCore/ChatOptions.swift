import Foundation

/// The generation modes a client may ask for.
///
/// `LLM_PROVIDER=openrouter`, so these resolve through `OpenRouterProvider.modelMap`
/// (`src/providers/OpenRouterProvider.js:181-186`). Resolution is a *fallthrough*, not a
/// whitelist — `BaseProvider.resolveModel` forwards an unrecognised string to OpenRouter
/// verbatim — so the server will not reject a typo, it will send it upstream. Keeping the
/// wire values in an enum is what prevents that.
///
/// The web UI offers only Quick and Thinking. Neither is plan-gated: the comment at
/// `sync-server.js:3106-3110` is explicit that a plan's model is "a DEFAULT, not a
/// restriction", so a Lite account may select Thinking.
enum ChatModel: String, CaseIterable, Identifiable, Codable {
    case fast
    case thinking

    var id: String { rawValue }

    /// The label the platform's own UI uses, so the two products agree.
    var label: String {
        switch self {
        case .fast: return "Quick"
        case .thinking: return "Thinking"
        }
    }

    var detail: String {
        switch self {
        case .fast: return "Faster"
        case .thinking: return "Deeper"
        }
    }

    /// Omitting `model` server-side defaults to `fast` (`sync-server.js:7779`), but the client
    /// always sends it explicitly rather than relying on that.
    static let `default` = ChatModel.fast

    /// Maps `users.preferred_model` from the login response onto a selection.
    ///
    /// The stored column is only ever `"fast"` or `"thinking"` — `POST /set-preferred-model`
    /// clamps anything else — and it is purely a seed for the picker: the per-request `model`
    /// wins unconditionally, since `preferred_model` never enters the generation path.
    static func fromPreference(_ raw: String?) -> ChatModel {
        ChatModel(rawValue: raw ?? "") ?? .default
    }
}

/// The persona the answer is written in.
///
/// - Warning: **this enum is the entire allowed set.** The value reaches the model's leading
///   instructions, so it must never be populated from free text or from anything a user typed.
///
/// The platform's seven UI roles collapse to these three on the wire
/// (`src/roles/roleConfig.js:10-107`), so matching them keeps answers identical to the web app.
enum ChatRole: String, CaseIterable, Identifiable, Codable {
    case litigator = "Litigator"
    case corporateCounsel = "Corporate Counsel"
    case judicialOfficer = "Judicial Officer"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .litigator: return "Litigator"
        case .corporateCounsel: return "Corporate Counsel"
        case .judicialOfficer: return "Arbitrator or Judge"
        }
    }

    var detail: String {
        switch self {
        case .litigator: return "Advocate handling cases"
        case .corporateCounsel: return "In-house and corporate advisory"
        case .judicialOfficer: return "Neutral adjudication"
        }
    }

    static let `default` = ChatRole.litigator

    /// The value to put on the wire.
    ///
    /// - Important: never send `null` or `""`. `getLeadingIdentity` has a JavaScript default
    ///   parameter, which fires only on `undefined` — an empty string sails past it and the
    ///   model is told it is "a top-tier, highly experienced " with nothing after it, while
    ///   `null` yields the literal word "null". Omitting the key entirely is the only safe
    ///   way to take the default, which is what a `nil` here produces.
    var wireValue: String { rawValue }
}
