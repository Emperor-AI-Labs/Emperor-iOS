import Foundation
#if canImport(Darwin)
import Observation
#endif

// New matter, as the web's dialog has it (`src/components/projects/NewMatterDialog.jsx`): a name,
// a banner, a folder colour, then the court case — found in the court records, "Not filed yet",
// or "Add it later". A found case is tracked first (`POST /save-case`, or the copy the user
// already tracks) and the matter is then made from it (`POST /project-from-case`), which fills in
// the court, the number, the next hearing and a practice area. Everything else is the workspace's
// job once the matter is open.

/// The folder colours a matter can carry (`src/lib/projectColors.js`), in the web's order, with
/// the names each swatch is read out by.
enum MatterFolderColor {
    static let options: [MatterVocabulary.Option] = [
        ("indigo", "Indigo"), ("violet", "Violet"), ("fuchsia", "Fuchsia"), ("rose", "Rose"),
        ("amber", "Amber"), ("green", "Green"), ("teal", "Teal"), ("sky", "Sky"),
    ]

    /// A stored colour if it is one of the keys, else none — the server stores anything else as
    /// no colour too.
    static func normalized(_ raw: String?) -> String? {
        let key = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return options.contains { $0.key == key } ? key : nil
    }

    static func label(_ key: String?) -> String {
        options.first { $0.key == normalized(key) }?.label ?? "No colour"
    }

    /// `#RRGGBB` for each key: the swatch ink the web's theme cuts for it (`--ex-proj-<key>` in
    /// `src/ui/theme.css`), each measured there to read against that theme's surfaces.
    static func ink(_ key: String, dark: Bool) -> String? {
        (dark ? darkInk : lightInk)[key]
    }

    private static let lightInk: [String: String] = [
        "indigo": "#4F46E5", "sky": "#0369A1", "teal": "#0F766E", "green": "#15803D",
        "amber": "#B45309", "rose": "#BE123C", "violet": "#7C3AED", "fuchsia": "#A21CAF",
    ]
    private static let darkInk: [String: String] = [
        "indigo": "#818CF8", "sky": "#38BDF8", "teal": "#2DD4BF", "green": "#4ADE80",
        "amber": "#FBBF24", "rose": "#FB7185", "violet": "#C084FC", "fuchsia": "#E879F9",
    ]
}

/// The three answers to "which court case is this?".
enum NewMatterCourtChoice: String, CaseIterable, Identifiable, Sendable {
    case find
    case notFiled = "not_filed"
    case later

    var id: String { rawValue }

    var label: String {
        switch self {
        case .find: return "Find the case"
        case .notFiled: return "Not filed yet"
        case .later: return "Add later"
        }
    }
}

/// A court case the user picked, matched against the cases they already track — so a matter for
/// a case on the dashboard links that copy rather than filing a second one (`trackCase.js`).
enum TrackedCaseLookup {
    /// The tracked case that is this card, or `nil`. Matched on the CNR (or the diary number,
    /// which the tracker keeps in the same column for the Supreme Court and the tribunals), else
    /// on the same number, year and type in the same court. A card with neither a number nor a
    /// CNR has no identity and matches nothing.
    static func find(_ pick: CourtSearchResult, in cases: [LegalCase]) -> LegalCase? {
        let cnr = canon(nonBlank(pick.cnr) ?? nonBlank(pick.diaryNumber))
        let number = canon(pick.caseNumber)
        guard !cnr.isEmpty || !number.isEmpty else { return nil }
        if !cnr.isEmpty, let hit = cases.first(where: { canon($0.cnr) == cnr || canon($0.diaryNumber) == cnr }) {
            return hit
        }
        guard !number.isEmpty else { return nil }
        return cases.first { kase in
            canon(kase.caseNumber) == number
                && canon(kase.caseYear) == canon(pick.caseYear)
                && canon(kase.caseType) == canon(pick.caseType)
                && ((!canon(pick.courtCode).isEmpty && canon(kase.courtCode) == canon(pick.courtCode))
                    || canon(kase.courtName) == canon(pick.courtName))
        }
    }

    /// Upper-cased letters and digits only, so "W.P.(C)" and "WP(C)" are one type.
    static func canon(_ text: String?) -> String {
        String((text ?? "").uppercased().unicodeScalars
            .filter { ("A"..."Z").contains($0) || ("0"..."9").contains($0) }
            .map(Character.init))
    }

    private static func nonBlank(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Tracks a picked court case: the copy the user already tracks, else a new one in their own
/// team (`trackCase.js`). Shared by New matter and Edit details, which must agree on what "the
/// same case" is or one of them files a second copy.
struct CaseTracker {
    let cases: any CaseProviding
    let courts: any CourtSearching

    enum Result: Equatable {
        case success(String)
        case failure(String)
    }

    /// A save refused as a duplicate is looked up again — if the case is there now, it is the one
    /// to use.
    func track(_ pick: CourtSearchResult, title: String) async -> Result {
        let known = try? await cases.cases()
        if let hit = known.flatMap({ TrackedCaseLookup.find(pick, in: $0) }) { return .success(hit.id) }

        var card = pick
        // A court searched only as a preview gives no cause title: the matter's name reads better
        // in the tracked cases than the server's "Untitled Case".
        if (card.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty, !title.isEmpty {
            card.title = title
        }
        var refusal: String?
        do {
            switch try await courts.save(card) {
            case .saved(let id): return .success(id)
            case .alreadySaved(let message), .refusedAsIndistinguishable(let message): refusal = message
            }
        } catch {
            refusal = DisplayText.message(for: error)
        }
        if let again = try? await cases.cases(), let hit = TrackedCaseLookup.find(pick, in: again) {
            return .success(hit.id)
        }
        return .failure(refusal ?? NewMatterViewModel.Copy.couldNotTrack)
    }
}

/// The New matter sheet.
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class NewMatterViewModel {

    enum Copy {
        static let title = "New matter"
        static let namePlaceholder = "Ankit Bhalla v. Vinod Kumari — partition suit"
        static let namedAfterCase = "Left blank, the matter is named after the cause title."
        static let footnote = "Files, chats and drafts you add later stay inside this matter."
        static let chooseTheCase =
            "Search the court records and choose the case — or pick “Not filed yet” or “Add later”."
        static let needsAName = "Give the matter a name."
        static let addingTheCase = "Adding the case… fetching its record from the court"
        static let creating = "Creating the matter…"
        static let created = "Matter created"
        static let existed = "You already have a matter for this case — opening it."
        static let couldNotTrack = "The case could not be added to your tracked cases."
        static let notFiledNote =
            "No case number yet. Once it is filed, find the case in court records from the matter and tracking starts."
        static let laterNote = "The matter is made without a court case. Link one from its Court section when you have it."
        static let findNote =
            "The case is tracked from the court from now on, and the matter is filled in from it."
    }

    var name = ""
    var banner: BannerPreset
    /// A folder colour key, or `nil` for none.
    var color: String?
    var court: NewMatterCourtChoice = .find
    /// The case chosen in the court search.
    var pick: CourtSearchResult?

    /// What the create is doing now; `nil` when idle.
    private(set) var busy: String?
    var error: String?
    /// Said once the matter exists — the web's toast.
    private(set) var toast: String?

    private let projects: any ProjectProviding
    private let cases: any CaseProviding
    private let courts: any CourtSearching

    /// - Parameter existing: the user's matters, to give a new one the banner they have used
    ///   least — so a fresh list is not eight navy cards in a row.
    init(
        projects: any ProjectProviding, cases: any CaseProviding, courts: any CourtSearching,
        existing: [Project] = []
    ) {
        self.projects = projects
        self.cases = cases
        self.courts = courts
        self.banner = Self.leastUsedBanner(existing)
    }

    /// The preset the fewest matters wear; the first in the web's order on a tie.
    static func leastUsedBanner(_ projects: [Project]) -> BannerPreset {
        var used: [BannerPreset: Int] = [:]
        for preset in MatterListing.bannerOrder { used[preset] = 0 }
        for project in projects {
            if let banner = project.banner, let preset = BannerPreset(rawValue: banner) { used[preset, default: 0] += 1 }
        }
        return MatterListing.bannerOrder.reduce(MatterListing.bannerOrder[0]) { best, preset in
            (used[preset] ?? 0) < (used[best] ?? 0) ? preset : best
        }
    }

    // MARK: - What the sheet shows

    var isFinding: Bool { court == .find }
    /// Still looking for the case: Create would only earn an error about it.
    var isSearching: Bool { isFinding && pick == nil }

    /// A found case names the matter after its cause title when the name is left blank, tidied
    /// as the server will write it.
    var titleFromCase: String? {
        guard isFinding, let title = pick?.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return nil }
        return CourtNames.tidy(title, title: true)
    }

    var typedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// What the banner preview reads.
    var shownName: String {
        if !typedName.isEmpty { return typedName }
        return titleFromCase ?? Copy.title
    }

    var namePlaceholder: String { titleFromCase ?? Copy.namePlaceholder }
    var showsNamedAfterCase: Bool { titleFromCase != nil && typedName.isEmpty }
    var isBusy: Bool { busy != nil }
    var canCreate: Bool { !isBusy && !isSearching && (!typedName.isEmpty || titleFromCase != nil) }

    var courtNote: String {
        switch court {
        case .find: return Copy.findNote
        case .notFiled: return Copy.notFiledNote
        case .later: return Copy.laterNote
        }
    }

    func choose(_ choice: NewMatterCourtChoice) {
        court = choice
        error = nil
    }

    func usePick(_ result: CourtSearchResult) {
        pick = result
        error = nil
    }

    func clearPick() { pick = nil }

    func clearToast() { toast = nil }

    // MARK: - Creating

    /// Makes the matter and returns its id, or `nil` with `error` set. A found case is tracked
    /// first and the matter made from it; otherwise the matter is made on its own, "Not filed
    /// yet" saying so.
    func create() async -> String? {
        guard !isBusy else { return nil }
        if isSearching {
            error = Copy.chooseTheCase
            return nil
        }
        let typed = typedName
        if typed.isEmpty, titleFromCase == nil {
            error = Copy.needsAName
            return nil
        }
        error = nil
        defer { busy = nil }

        if isFinding, let pick {
            busy = Copy.addingTheCase
            let caseID: String
            switch await track(pick, title: typed) {
            case .success(let id): caseID = id
            case .failure(let message):
                error = message
                return nil
            }
            busy = Copy.creating
            do {
                let seed = MatterSeed(name: typed.isEmpty ? nil : typed, banner: banner.rawValue, color: color)
                let made = try await projects.projectFromCase(caseID: caseID, seed: seed)
                toast = made.existed ? Copy.existed : Copy.created
                return made.project.id
            } catch {
                self.error = "The case is now tracked, but the matter could not be created: "
                    + "\(Self.reason(error)). Try again — the case will not be added twice."
                return nil
            }
        }

        busy = Copy.creating
        do {
            let draft = MatterDraft(
                name: typed, color: color, banner: banner.rawValue,
                courtStatus: court == .notFiled ? "not_filed" : nil)
            let made = try await projects.create(draft)
            toast = Copy.created
            return made.id
        } catch {
            self.error = DisplayText.message(for: error)
            return nil
        }
    }

    func track(_ pick: CourtSearchResult, title: String) async -> CaseTracker.Result {
        await CaseTracker(cases: cases, courts: courts).track(pick, title: title)
    }

    private static func reason(_ error: Error) -> String {
        let text = DisplayText.message(for: error).trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = text.hasSuffix(".") ? String(text.dropLast()) : text
        return trimmed.isEmpty ? "the server refused it" : trimmed
    }
}
