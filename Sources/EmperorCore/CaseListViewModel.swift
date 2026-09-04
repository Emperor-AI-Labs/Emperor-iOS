import Foundation
#if canImport(Darwin)
import Observation
#endif

/// The docket: every matter, grouped by when it is next in court.
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class CaseListViewModel {

    /// A heading in the list.
    struct Group: Identifiable, Equatable, Sendable {
        let key: String
        let title: String
        let cases: [LegalCase]
        var id: String { key }
    }

    private(set) var cases: [LegalCase] = []
    private(set) var state: LoadState = .idle
    private(set) var cachedAt: Date?
    var query = ""

    private let service: any CaseProviding
    private let cache: ResponseCache?
    private let now: @Sendable () -> Date

    init(
        service: any CaseProviding,
        cache: ResponseCache? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.service = service
        self.cache = cache
        self.now = now
    }

    var presentation: ListPresentation {
        ListPresentation(state: state, isEmpty: cases.isEmpty, cachedAt: cachedAt)
    }

    var showsNoSearchResults: Bool { !cases.isEmpty && visible.isEmpty }

    /// Matches on everything a practitioner might reach for: the matter name, the parties, the
    /// court, the case number and the CNR.
    var visible: [LegalCase] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return cases }
        return cases.filter { legalCase in
            let haystack = [
                legalCase.title, legalCase.parties, legalCase.courtName, legalCase.caseType,
                legalCase.caseNumber, legalCase.caseYear, legalCase.cnr, legalCase.diaryNumber,
                legalCase.judge, legalCase.status, legalCase.stage,
            ]
            .compactMap { $0 }
            .joined(separator: " ")
            return haystack.localizedCaseInsensitiveContains(trimmed)
        }
    }

    /// Grouped by when the matter is next in court — which is the only ordering that answers
    /// the question the screen is opened to answer.
    ///
    /// Deliberately not the server's `updated_at DESC` (`sync-server.js:9682`): under that
    /// ordering, adding a note to a matter moves it to the top of the docket.
    var groups: [Group] {
        let today = WireDate.dayKey(now())
        var overdue: [LegalCase] = []
        var upcoming: [LegalCase] = []
        var undated: [LegalCase] = []

        for legalCase in visible {
            guard let day = legalCase.nextHearingDateRaw?.prefix(10), !day.isEmpty else {
                undated.append(legalCase)
                continue
            }
            if String(day) < today { overdue.append(legalCase) } else { upcoming.append(legalCase) }
        }

        func byDate(_ list: [LegalCase], ascending: Bool) -> [LegalCase] {
            list.sorted {
                let left = $0.nextHearingDateRaw ?? ""
                let right = $1.nextHearingDateRaw ?? ""
                return ascending ? left < right : left > right
            }
        }

        var groups: [Group] = []
        if !upcoming.isEmpty {
            groups.append(Group(
                key: "upcoming", title: "Next in court",
                cases: byDate(upcoming, ascending: true)))
        }
        if !overdue.isEmpty {
            // Named "Last listed" rather than "Overdue": a past hearing date usually means the
            // matter was heard and the next date has not been synced yet, not that anything is
            // late. Calling it overdue would be an accusation the data cannot support.
            groups.append(Group(
                key: "past", title: "Last listed",
                cases: byDate(overdue, ascending: false)))
        }
        if !undated.isEmpty {
            groups.append(Group(
                key: "undated", title: "No hearing date",
                cases: undated.sorted {
                    $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle)
                        == .orderedAscending
                }))
        }
        return groups
    }

    func load() async {
        if state == .idle, cases.isEmpty,
           let cached = cache?.load([LegalCase].self, for: .caseList) {
            cases = cached.value
            cachedAt = cached.storedAt
        }

        state = .loading
        do {
            cases = try await service.cases()
            cachedAt = nil
            cache?.save(cases, for: .caseList)
            state = .loaded
        } catch {
            state = .failed(LoadFailure(error))
        }
    }
}
