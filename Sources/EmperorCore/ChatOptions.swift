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

    /// The mode's name in the Record design's composer and answer-mode sheet.
    var modeName: String {
        switch self {
        case .fast: return "Fast"
        case .thinking: return "Deep thinking"
        }
    }

    /// What the mode is for, under its name in the answer-mode sheet.
    var modeDescription: String {
        switch self {
        case .fast: return "Quick answers from your record. Best for most questions."
        case .thinking: return "Slower; reasons through long records. Counts against your deep-thinking allowance."
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

/// The answer mode a new question starts in, chosen on this device under You → Default mode.
///
/// The account has a preferred model of its own (`PreferredModelResponse`), which this client
/// reads and never writes — a setting that exists in one client and nowhere else is worse than
/// none. So the choice here is the device's: "Account" (nothing stored) follows the account, and
/// Fast or Deep thinking wins over it for questions started on this phone.
enum AnswerModeDefault {
    static let storageKey = "answer.default-mode.v1"

    /// The mode chosen on this device, or `nil` to follow the account.
    static func stored(in store: any PreferenceStore) -> ChatModel? {
        store.string(for: storageKey).flatMap(ChatModel.init(rawValue:))
    }

    /// Saves a choice; `nil` goes back to following the account.
    static func save(_ model: ChatModel?, to store: any PreferenceStore) {
        store.setString(model?.rawValue ?? "", for: storageKey)
    }

    /// The mode to start a question in: this device's choice, else the account's, else Fast.
    static func resolve(stored: ChatModel?, account: String?) -> ChatModel {
        stored ?? ChatModel.fromPreference(account)
    }
}

/// Whether a draft shows its citation numbers, remembered per account on this device.
///
/// A display choice only: the stored draft is never rewritten by it, and every download asks
/// again whether to carry them (`DocumentExportMenu`).
enum DraftCitationsPreference {
    static func key(forUser userID: Int?) -> String {
        "draft.show-citations.v1.\(userID.map(String.init) ?? "anonymous")"
    }

    /// On unless this account has turned them off here.
    static func showsCitations(in store: any PreferenceStore, userID: Int?) -> Bool {
        store.string(for: key(forUser: userID)) != "off"
    }

    static func save(_ shows: Bool, to store: any PreferenceStore, userID: Int?) {
        store.setString(shows ? "on" : "off", for: key(forUser: userID))
    }
}
