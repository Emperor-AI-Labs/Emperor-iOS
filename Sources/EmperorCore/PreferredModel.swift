import Foundation

/// The model an account starts new conversations on.
///
/// The app has a per-chat toggle already, so this is only about the *starting* position. Before
/// this, every new conversation began on the client's own hardcoded default regardless of what
/// the account was actually entitled to — someone on a plan whose default is Thinking got Quick
/// on the phone and Thinking on the web, which reads as the phone being a lesser product.
///
/// ## Read only, deliberately
///
/// There is a setter route. Neither this client nor the web one calls it, and adding a writer
/// here would make the phone the only place the value can be changed — a setting that exists in
/// one client and nowhere else is worse than no setting.
///
/// ## The stored value is usually null, and that is not a missing answer
///
/// `preferred_model` is a per-user *override* that is normally unset, meaning "follow my plan".
/// The server resolves it through the plan before answering, so what arrives is always a usable
/// model rather than null. Applying the response verbatim is therefore correct, and falling back
/// to a local default when the field is present would make a plan change invisible on the phone.
struct PreferredModelResponse: Codable, Equatable, Sendable {
    let success: Bool?
    let preferredModel: String?
    let plan: String?
    let planLabel: String?
    let planDefaultModel: String?
    /// True when the user has overridden their plan's default for themselves.
    let isOverride: Bool?

    /// The model to start on, or `nil` if the server sent something this build does not know.
    ///
    /// An unrecognised value is `nil` rather than a guess: a future plan introducing a third
    /// mode should leave the phone on its existing default, not silently pick one of the two it
    /// happens to have.
    var model: ChatModel? {
        preferredModel.flatMap(ChatModel.init(rawValue:))
    }
}

protocol PreferredModelProviding: Sendable {
    func preferredModel() async throws -> PreferredModelResponse
}

struct PreferredModelService: PreferredModelProviding {
    let client: APIClient

    func preferredModel() async throws -> PreferredModelResponse {
        let request = try await client.makeRequest("GET", "/preferred-model")
        return try await client.send(request, as: PreferredModelResponse.self)
    }
}
