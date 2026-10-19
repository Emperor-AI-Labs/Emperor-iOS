import Foundation
#if canImport(Darwin)
import Observation
#endif

/// One row of the web's research "Sources" menu (`src/tools/ResearchSourcesMenu.jsx`).
struct ResearchSource: Identifiable, Equatable, Sendable {
    enum Group: Equatable, Sendable { case web, jurisdiction, repository }

    let id: String
    let label: String
    let group: Group
    /// The flag the web leads a jurisdiction with, or nil where it draws an icon.
    let flag: String?
    /// The SF Symbol standing in for the web's lucide icon, where it draws one.
    let systemImage: String?
}

/// Which sources the research menu has switched on — the web's `researchSources`.
///
/// ## What reaches the server
///
/// Only **Web search**, and only from this client. On the web the whole selection is preference
/// state: its own comment says toggling a source "doesn't change what actually gets searched yet",
/// and neither the menu nor the store feeds the chat request. This client already had a way to
/// ask for a search on purpose — `ChatService.send(webSearch:)`, which sends `searchMode: "web"` —
/// so the `web` row is that switch, under one name, and the jurisdictions and repositories are
/// kept and shown exactly as the web keeps them: remembered, and sent nowhere. No wording may
/// claim they scope an answer.
///
/// ## The one default that differs
///
/// The web starts at `{ web: true, in: true }`. India on is copied. Web search starts **off**
/// here, because on this client the switch is real: on, every question would ask the server for a
/// web search, which the phone has never done by default and the web does not do at all. The
/// difference is pinned by `ResearchSourcesGoldenTests` so it stays deliberate.
///
/// Remembered for the account on this device. (The web keeps the selection for the open tab only
/// — `researchSources` is not among the keys its store persists.)
struct ResearchSources: Equatable, Sendable {
    /// The ids switched on.
    private(set) var selected: Set<String>

    init(selected: Set<String>) {
        self.selected = selected
    }

    static let webID = "web"

    /// The web's starting selection is `{ web: true, in: true }`; see the type's note for why web
    /// search starts off here.
    static let `default` = ResearchSources(selected: ["in"])

    // MARK: The menu

    /// The full-width row above both lists.
    static let web = ResearchSource(
        id: webID, label: "Web search", group: .web, flag: nil, systemImage: "magnifyingglass")

    /// In the web's order: the Americas, then EMEA, then APAC, India first.
    static let jurisdictions: [ResearchSource] = [
        ("in", "🇮🇳", "India"),
        ("us", "🇺🇸", "United States"),
        ("ca", "🇨🇦", "Canada"),
        ("br", "🇧🇷", "Brazil"),
        ("ae", "🇦🇪", "United Arab Emirates"),
        ("uk", "🇬🇧", "United Kingdom"),
        ("eu", "🇪🇺", "European Union"),
        ("sa", "🇸🇦", "Saudi Arabia"),
        ("sg", "🇸🇬", "Singapore"),
        ("jp", "🇯🇵", "Japan"),
    ].map { ResearchSource(id: $0.0, label: $0.2, group: .jurisdiction, flag: $0.1, systemImage: nil) }

    /// Named regulators and registries. Most have no natural flag, so the web draws an icon.
    static let repositories: [ResearchSource] = [
        ResearchSource(id: "corporate", label: "Corporate law", group: .repository, flag: nil, systemImage: "building.2"),
        ResearchSource(id: "securities", label: "Securities law", group: .repository, flag: nil, systemImage: "chart.line.uptrend.xyaxis"),
        ResearchSource(id: "rbi", label: "Reserve Bank of India", group: .repository, flag: nil, systemImage: "building.columns"),
        ResearchSource(id: "cci", label: "Competition Commission (CCI)", group: .repository, flag: nil, systemImage: "checkmark.shield"),
        ResearchSource(id: "income-tax", label: "Income tax", group: .repository, flag: nil, systemImage: "receipt"),
        ResearchSource(id: "canada-sc", label: "Canada SC — memorandums & facta", group: .repository, flag: "🇨🇦", systemImage: nil),
        ResearchSource(id: "tas-cas", label: "TAS / CAS arbitral awards", group: .repository, flag: nil, systemImage: "hammer"),
        ResearchSource(id: "nepal-sc", label: "Nepal Supreme Court", group: .repository, flag: nil, systemImage: "building.columns"),
    ]

    static var all: [ResearchSource] { [web] + jurisdictions + repositories }

    // MARK: Reading and toggling

    func isOn(_ id: String) -> Bool { selected.contains(id) }

    /// Whether a question asks the server for a web search — the one source that reaches it.
    var searchesWeb: Bool { isOn(Self.webID) }

    /// How many are on — the web's count badge on the "Sources" trigger.
    var activeCount: Int { selected.count }

    /// The web's `toggleResearchSource`: flips one id.
    mutating func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    mutating func set(_ id: String, on: Bool) {
        if on { selected.insert(id) } else { selected.remove(id) }
    }

    /// The footer the sheet shows. Says what is kept and what is sent, and claims nothing more.
    static let footer =
        "Your selection is kept for your account on this device. Web search is the one that reaches Emperor today: when it is on, each question asks for a web search as well. The jurisdictions and repositories are remembered but do not yet narrow what is searched."

    // MARK: Storage

    static func key(forUser userID: Int?) -> String {
        "research.sources.v1.\(userID.map(String.init) ?? "anonymous")"
    }

    /// The ids, comma-separated, under one key. An empty string is a stored empty selection
    /// (everything switched off), which is different from nothing stored. Ids this build does not
    /// know are dropped, so a retired source cannot linger switched on and uncountable.
    static func stored(in store: any PreferenceStore, userID: Int?) -> ResearchSources {
        guard let raw = store.string(for: key(forUser: userID)) else { return .default }
        let known = Set(all.map(\.id))
        let ids = raw.split(separator: ",").map(String.init).filter { known.contains($0) }
        return ResearchSources(selected: Set(ids))
    }

    func save(to store: any PreferenceStore, userID: Int?) {
        let ordered = Self.all.map(\.id).filter { selected.contains($0) }
        store.setString(ordered.joined(separator: ","), for: Self.key(forUser: userID))
    }
}

/// The research sources for one account on this device, saved on every change — what the
/// composer's Sources sheet and its "Always search the web" switch both read and write, so the
/// two can never disagree about the `web` row.
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class ResearchSourcesModel {
    private(set) var sources: ResearchSources
    private let store: any PreferenceStore
    private let userID: Int?

    init(store: any PreferenceStore, userID: Int?) {
        self.store = store
        self.userID = userID
        self.sources = ResearchSources.stored(in: store, userID: userID)
    }

    var searchesWeb: Bool { sources.searchesWeb }

    func isOn(_ id: String) -> Bool { sources.isOn(id) }

    func toggle(_ id: String) {
        sources.toggle(id)
        sources.save(to: store, userID: userID)
    }

    func setSearchesWeb(_ on: Bool) {
        sources.set(ResearchSources.webID, on: on)
        sources.save(to: store, userID: userID)
    }
}
