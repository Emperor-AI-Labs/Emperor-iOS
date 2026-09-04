import Foundation
#if canImport(Darwin)
import Observation
#endif

/// Finding a case at the court and putting it on the dashboard.
///
/// Until this existed the app could only show matters someone had already added on the web,
/// which made it a viewer rather than a client. Everything hard about it is about *honesty*:
/// the routes answer 200 for failures, mask bad input as an outage, and answer a refused save
/// with the same 409 they use for "already there" — none of which the user has any way to see.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class CourtSearchViewModel {
    var query = CourtSearchQuery(forum: .supremeCourt) {
        didSet {
            guard query != oldValue else { return }
            // **Any** change, not just the forum. The results describe the query that produced
            // them, and every field here is a live binding: someone who searches diary 52650,
            // reads the card, then corrects the number to 52651 would otherwise still be
            // looking at 52650's case with an enabled "Add to my cases" under it — and nothing
            // on screen would say so. An earlier version cleared only on a forum change, which
            // left exactly that hole.
            results = []
            hasSearched = false
            errorMessage = nil
            notice = nil
        }
    }

    private(set) var results: [CourtSearchResult] = []
    private(set) var isSearching = false
    /// Which result is being saved, if any. Drives a per-row spinner rather than a global one,
    /// because saving one case should not freeze the list.
    private(set) var savingID: String?
    private(set) var savedIDs: Set<String> = []
    var errorMessage: String?
    var notice: String?
    /// True once a lookup has completed, so "no results" can be told from "not searched yet".
    private(set) var hasSearched = false

    private let service: CourtSearching
    /// Called after a case is pinned, so the dashboard behind this screen refreshes.
    private let onSaved: (() -> Void)?

    #if canImport(Darwin)
    @ObservationIgnored private var task: Task<Void, Never>?
    #else
    private var task: Task<Void, Never>?
    #endif

    init(service: CourtSearching, onSaved: (() -> Void)? = nil) {
        self.service = service
        self.onSaved = onSaved
    }

    var canSearch: Bool { !isSearching && query.isComplete }

    /// What to show under a form that is not yet sendable.
    ///
    /// Shown rather than swallowed because the server will not tell them: an incomplete body
    /// throws server-side, is caught, and returns "Could not reach the Supreme Court site" —
    /// so without this the user retries a form that can never work, blaming the court.
    var incompleteNotice: String? {
        let missing = query.missingFields
        guard !missing.isEmpty else { return nil }
        return "Add \(DisplayText.list(missing.map { $0.lowercased() })) to search."
    }

    /// Whether a lookup here is the slow kind, so the wait can be explained rather than endured.
    var expectsLongWait: Bool { query.forum.solvesCaptcha }

    // MARK: - Searching

    func search() {
        guard canSearch else { return }
        task?.cancel()
        task = Task { await runSearch() }
    }

    func runSearch() async {
        guard canSearch else { return }
        isSearching = true
        errorMessage = nil
        notice = nil
        defer { isSearching = false }

        do {
            let found = try await service.search(query)
            results = found
            hasSearched = true
        } catch is CancellationError {
            return
        } catch {
            results = []
            hasSearched = true
            errorMessage = DisplayText.message(for: error)
        }
    }

    /// What to say when a search came back with nothing.
    ///
    /// A High Court lookup reaches this after its captcha was solved and the site still
    /// returned no rows — indistinguishable from "no such case" — so the wording has to admit
    /// both possibilities rather than assert the case does not exist.
    var emptyMessage: String {
        query.forum.solvesCaptcha
            ? """
              No case came back for that number. The court's site sometimes returns nothing \
              even when the case exists — it is worth trying again before concluding it is not \
              there.
              """
            : "No case at the \(query.forum.name) matches that number."
    }

    // MARK: - Saving

    func save(_ result: CourtSearchResult) {
        guard savingID == nil, !savedIDs.contains(result.id) else { return }
        Task { await runSave(result) }
    }

    func runSave(_ result: CourtSearchResult) async {
        guard savingID == nil else { return }
        savingID = result.id
        errorMessage = nil
        notice = nil
        defer { savingID = nil }

        do {
            switch try await service.save(result) {
            case .saved:
                savedIDs.insert(result.id)
                notice = "\(result.displayTitle) is now on your dashboard."
                onSaved?()
            case .alreadySaved(let message):
                // Already there is the outcome they wanted. Marking it saved stops them
                // pressing again and getting the same message.
                savedIDs.insert(result.id)
                notice = message
            case .refusedAsIndistinguishable(let message):
                // The case is NOT on the dashboard. It must not be marked saved and it must
                // not be coloured as success: the whole failure mode here is that the user
                // walks away believing a matter is on their docket when it is not.
                errorMessage = message
            }
        } catch {
            errorMessage = DisplayText.message(for: error)
        }
    }

    /// Warns, before the save, that this case may be refused.
    ///
    /// The hazard is the opposite of a duplicate. A card with no case number is filed under
    /// `courtCode|||`, which is a perfectly good unique key — so it does not quietly make a
    /// second row, it *collides* with whatever unrelated matter is already filed there and is
    /// rejected. Since the rejection arrives as the same 409 that means "already saved", the
    /// only honest thing is to say so before the button is pressed.
    ///
    /// - Note: this is unavoidable from the client. Fixing it properly means the server
    ///   including `diaryNumber` in `ext_id`.
    func collisionWarning(for result: CourtSearchResult) -> String? {
        guard !result.hasDistinguishingNumber else { return nil }
        return "The \(query.forum.name) has not given this case a number yet, so it can only "
            + "be added if you are not already keeping another numberless matter from here."
    }

    func isSaved(_ result: CourtSearchResult) -> Bool { savedIDs.contains(result.id) }

    func dismissNotice() { notice = nil }

    enum Copy {
        static let title = "Find a case"
        static let searchButton = "Search the court"
        static let searching = "Asking the court…"
        /// Said out loud because ten seconds of silence reads as a hang.
        static let captchaWait = """
            High Court lookups go through the court's own security check, which usually takes \
            a few seconds and sometimes longer.
            """
        static let saveButton = "Add to my cases"
        static let savedLabel = "On your dashboard"
    }
}
