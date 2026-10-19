import Foundation
#if canImport(Darwin)
import Observation
#endif

// "Edit matter details" — every field a matter has, in one form, as the web's `ProjectForm` has it
// (`src/components/projects/shared.jsx`). It saves through `POST /project` with the matter's `id`.

/// Where a matter is heard, as the form groups it (`FORUMS`).
enum MatterForum {
    static let options: [MatterVocabulary.Option] = [
        ("district", "District Court"), ("high_court", "High Court"), ("supreme_court", "Supreme Court"),
        ("tribunal", "Tribunal (NCLT / NCLAT / ITAT …)"), ("arbitration", "Arbitration"),
        ("other", "Other / Advisory"),
    ]

    /// A court result's `courtType` → the forum it is filed under. Consumer commissions have no
    /// forum of their own and fall to `other`; the forum name keeps the real one.
    static let byCourtType: [String: String] = [
        "sc": "supreme_court", "hc": "high_court", "district": "district",
        "tribunal": "tribunal", "nclt": "tribunal", "nclat": "tribunal", "forum": "other",
    ]
}

enum MatterPriority {
    static let options: [MatterVocabulary.Option] = [("high", "High"), ("normal", "Normal"), ("low", "Low")]
}

/// The form's state: every value a string a field can hold, as the web's draft is.
struct MatterEditDraft: Equatable, Sendable {
    var name = ""
    var client = ""
    var oppositeParty = ""
    /// A vocabulary key, `other` (with `ourSideText`), or blank.
    var ourSide = ""
    var ourSideText = ""
    var practiceArea = ""
    var forumType = "other"
    var forumName = ""
    var caseType = ""
    var caseNumber = ""
    var caseYear = ""
    var cnr = ""
    var stage = ""
    /// `YYYY-MM-DD` or blank.
    var nextHearingDate = ""
    var status = "active"
    var priority = "normal"
    var description = ""
    /// A preset key, or `image` while an uploaded picture is kept.
    var banner = BannerPreset.navy.rawValue
    /// A folder colour key, or `nil`.
    var color: String?
    /// The user's "Not filed yet".
    var notFiled = false

    init() {}

    /// The matter as the form opens on it. Our side in words ("Caveator") is shown as Other plus
    /// the words; a day stored as a full timestamp is cut to its day.
    init(_ project: Project) {
        name = project.name ?? ""
        client = project.client ?? ""
        oppositeParty = project.oppositeParty ?? ""
        let side = project.ourSide?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if side.isEmpty {
            ourSide = ""
        } else if MatterVocabulary.ourSides.contains(where: { $0.key == side }) {
            ourSide = side
        } else {
            ourSide = "other"
            ourSideText = side
        }
        practiceArea = project.practiceArea ?? ""
        forumType = Self.nonBlank(project.forumType) ?? "other"
        forumName = project.forumName ?? ""
        caseType = project.caseType ?? ""
        caseNumber = project.caseNumber ?? ""
        caseYear = project.caseYear ?? ""
        cnr = project.cnr ?? ""
        stage = project.stage ?? ""
        nextHearingDate = String((project.nextHearingDateRaw ?? "").prefix(10))
        status = Self.nonBlank(project.status) ?? "active"
        priority = Self.nonBlank(project.priority) ?? "normal"
        description = project.notes ?? ""
        banner = project.banner == "image" ? "image" : BannerPreset.preset(for: project).rawValue
        color = MatterFolderColor.normalized(project.color)
        notFiled = project.isNotFiledYet
    }

    /// What our side saves as: the key, or the words typed for Other.
    var ourSideValue: String {
        guard ourSide == "other" else { return ourSide }
        let words = ourSideText.trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty ? "other" : words
    }

    /// Every field the form shows, as `POST /project` names it, trimmed.
    var values: [String: String] {
        [
            "name": name, "client": client, "description": description, "forumType": forumType,
            "forumName": forumName, "caseType": caseType, "caseNumber": caseNumber, "caseYear": caseYear,
            "cnr": cnr, "stage": stage, "status": status, "priority": priority,
            "nextHearingDate": nextHearingDate, "practiceArea": practiceArea, "ourSide": ourSideValue,
            "oppositeParty": oppositeParty, "color": color ?? "", "banner": banner,
            "courtStatus": notFiled ? "not_filed" : "",
        ].mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// The body of the save, against the matter as the form opened on it.
    ///
    /// Every field with something in it is sent, as the web sends the whole form, so a save means
    /// "the matter now reads like this". A blank is **omitted** — the route keeps what it is not
    /// sent — unless the field held something when the form opened: then the user cleared it, and
    /// it goes as `null`, which the route stores as nothing.
    func fields(comparedWith original: MatterEditDraft) -> [String: JSONValue] {
        let before = original.values
        var out: [String: JSONValue] = [:]
        for (key, value) in values {
            if !value.isEmpty {
                out[key] = .string(value)
            } else if !(before[key] ?? "").isEmpty {
                out[key] = .null
            }
        }
        return out
    }

    /// Takes a case found in the court records: its identity overwrites the court fields, but the
    /// name and the next hearing are only filled in while empty — those are the user's own.
    mutating func adopt(_ pick: CourtSearchResult) {
        forumType = pick.courtType.flatMap { MatterForum.byCourtType[$0] } ?? "other"
        forumName = pick.courtName ?? ""
        caseNumber = pick.caseNumber ?? ""
        caseYear = pick.caseYear ?? ""
        caseType = pick.caseType ?? ""
        cnr = Self.nonBlank(pick.cnr) ?? pick.diaryNumber ?? ""
        stage = pick.stage ?? ""
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let title = Self.nonBlank(pick.title) {
            name = CourtNames.tidy(title, title: true)
        }
        if nextHearingDate.isEmpty, let next = pick.nextHearingDate,
           next.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil {
            nextHearingDate = String(next.prefix(10))
        }
        notFiled = false
    }

    private static func nonBlank(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// The Edit details sheet.
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class EditMatterViewModel {

    enum Copy {
        static let title = "Edit matter details"
        static let saved = "Changes saved"
        static let couldNotSave = "The matter could not be saved."
        static let saving = "Saving…"
        static let linking = "Adding the case… fetching its record from the court"
        static let linkedNote =
            "Linked to a tracked court case — its hearings and orders come from the court. Manage the link in the Court section."
        static let notFiledNote =
            "No case number yet — the court it will be filed in can still go below. Once it is filed, find the case in court records and tracking starts."
        static let attachedNote =
            "On saving, this case is tracked and linked here, so its hearings, orders and next date come from the court."
    }

    let project: Project
    let original: MatterEditDraft
    var draft: MatterEditDraft
    /// A case found in the court records in this sitting, to track and link on saving.
    private(set) var attached: CourtSearchResult?

    private(set) var busy: String?
    var error: String?
    /// The web's toast once saved — "Changes saved", or what did not land.
    private(set) var toast: String?

    private let service: any ProjectProviding
    private let tracker: CaseTracker?

    /// - Parameter tracker: tracks a case found in the court records. Without it the form edits
    ///   the fields only.
    init(project: Project, service: any ProjectProviding, tracker: CaseTracker? = nil) {
        self.project = project
        self.original = MatterEditDraft(project)
        self.draft = original
        self.service = service
        self.tracker = tracker
    }

    var isBusy: Bool { busy != nil }
    var canSave: Bool { !isBusy && !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var hasLinkedCase: Bool { project.hasLinkedCase }
    /// "Not filed yet" is not offered once a case is linked — the opposite fact.
    var offersNotFiled: Bool { !hasLinkedCase && attached == nil }
    var hasImageBanner: Bool { draft.banner == "image" }
    var canFindCase: Bool { tracker != nil }

    var practiceAreaOptions: [MatterVocabulary.Option] {
        var options: [MatterVocabulary.Option] = [("", "Not set")] + MatterVocabulary.practiceAreas
        // A key some other client stored stays selectable rather than showing as nothing.
        if !draft.practiceArea.isEmpty, !options.contains(where: { $0.key == draft.practiceArea }) {
            options.append((draft.practiceArea, draft.practiceArea))
        }
        return options
    }

    var ourSideOptions: [MatterVocabulary.Option] { [("", "Not set")] + MatterVocabulary.ourSides }

    var bannerPreset: BannerPreset {
        BannerPreset(rawValue: draft.banner) ?? BannerPreset.preset(for: project)
    }

    func pickPreset(_ preset: BannerPreset) { draft.banner = preset.rawValue }

    func usePick(_ result: CourtSearchResult) {
        draft.adopt(result)
        attached = result
        error = nil
    }

    func clearCase() {
        attached = nil
        draft.forumType = "other"
        for key in [\MatterEditDraft.forumName, \.caseNumber, \.caseYear, \.caseType, \.cnr, \.stage] {
            draft[keyPath: key] = ""
        }
    }

    func clearToast() { toast = nil }

    /// Saves, then — for a case found in this sitting — tracks it and links it. Returns the saved
    /// matter, or `nil` with `error` set. A link that fails does not undo the save; it is said.
    func save() async -> Project? {
        guard canSave else {
            if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                error = NewMatterViewModel.Copy.needsAName
            }
            return nil
        }
        error = nil
        defer { busy = nil }

        // Choosing a preset over an uploaded picture removes the picture. Not fatal: a stray
        // file is invisible once the row names a preset.
        if project.hasBannerImage, draft.banner != "image" {
            try? await service.deleteBanner(projectID: project.id)
        }

        busy = Copy.saving
        var saved: Project
        do {
            saved = try await service.update(projectID: project.id, fields: draft.fields(comparedWith: original))
        } catch {
            self.error = DisplayText.message(for: error)
            return nil
        }

        var warnings: [String] = []
        if let attached, let tracker {
            busy = Copy.linking
            switch await tracker.track(attached, title: draft.name.trimmingCharacters(in: .whitespacesAndNewlines)) {
            case .failure(let reason):
                warnings.append(Self.linkWarning(reason))
            case .success(let caseID):
                do {
                    saved = try await service.linkCase(projectID: project.id, caseID: caseID)
                } catch {
                    warnings.append(Self.linkWarning(DisplayText.message(for: error)))
                }
            }
        }
        toast = warnings.isEmpty ? Copy.saved : "Saved, but \(warnings.joined(separator: "; and "))."
        return saved
    }

    private static func linkWarning(_ reason: String) -> String {
        let text = reason.hasSuffix(".") ? String(reason.dropLast()) : reason
        return "the court case was not linked (\(text)) — link it from the matter's Court section"
    }
}

extension ProjectListViewModel {
    /// Said after an edit moves a matter out of the status in view: "“Bhalla” is now On hold —
    /// switch Status to see it."
    func notice(afterSaving project: Project) -> String? {
        guard statusFilter != .all, let status = project.status, !status.isEmpty,
              status != statusFilter.rawValue else { return nil }
        let label = MatterStatusFilter(rawValue: status)?.label ?? status
        return "“\(project.displayName)” is now \(label) — switch Status to see it."
    }
}
