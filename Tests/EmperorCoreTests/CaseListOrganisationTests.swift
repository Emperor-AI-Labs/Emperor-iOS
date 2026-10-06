import XCTest
@testable import EmperorCore

/// How the docket is laid out: the court headings, the sorts, the groupings, the filters, the
/// search inside them, and what is remembered between launches.
///
/// One docket throughout, a case in every heading, with "today" pinned to 14 September 2026 in
/// India — so every expectation below can be checked by reading the fixture.
final class CaseListOrganisationTests: XCTestCase {

    // MARK: - The docket

    private static func legalCase(
        _ id: String, title: String, type: String? = nil, code: String? = nil,
        court: String? = nil, hearing: String? = nil, synced: Bool = false,
        updated: String? = nil, filed: String? = nil, cnr: String? = nil,
        diary: String? = nil, judge: String? = nil, stage: String? = nil,
        number: String? = nil, year: String? = nil, caseType: String? = nil
    ) -> LegalCase {
        LegalCase(
            id: id, teamID: "team_1", cnr: cnr, courtType: type, courtCode: code,
            caseNumber: number, caseYear: year, title: title, parties: nil, status: nil,
            stage: stage, nextHearingDateRaw: hearing, filingDateRaw: filed, judge: judge,
            courtName: court, caseType: caseType, diaryNumber: diary, category: nil,
            lastSyncedAtRaw: synced ? "2026-09-13T22:00:00.000Z" : nil, createdAtRaw: nil,
            updatedAtRaw: updated, teamName: "My Firm")
    }

    /// Hearings relative to 14 Sept: `forum` today, `hcDelhi` tomorrow, `sc` in six days,
    /// `district` next month; `nclt` and `hcBombay` past; the rest undated.
    static let docket: [LegalCase] = [
        legalCase(
            "sc", title: "Rao v. Union of India", type: "sc", code: "sc",
            court: "Supreme Court of India", hearing: "2026-09-20", synced: true,
            updated: "2026-09-10T08:00:00.000Z", filed: "2025-01-10",
            diary: "41207/2025", number: "8812", year: "2025", caseType: "SLP(C)"),
        legalCase(
            "hcDelhi", title: "Kapoor Textiles v. Commissioner of Customs", type: "hc",
            code: "hc-delhi", court: "High Court of Delhi", hearing: "2026-09-15", synced: true,
            updated: "2026-09-12 09:00:00", filed: "2024-06-01", cnr: "DLHC010104212024",
            judge: "Hon'ble Ms. Justice R. Menon", number: "10421", year: "2024",
            caseType: "W.P.(C)"),
        // No `court_type` at all, as the stub's own case arrives — placed by its name.
        legalCase(
            "hcBombay", title: "Bakshi v. State of Maharashtra", court: "Bombay High Court",
            hearing: "2026-08-01", number: "1234", year: "2025"),
        legalCase(
            "nclat", title: "Creditors of Sunrise Alloys v. Resolution Professional",
            type: "nclat", code: "trib-nclat",
            court: "National Company Law Appellate Tribunal, New Delhi", synced: true,
            updated: "2026-09-13T10:00:00.000Z", filed: "2025-05-05",
            stage: "Final arguments"),
        legalCase(
            "nclt", title: "Meridian Finance v. Prakash Infra Projects", type: "nclt",
            code: "trib-nclt", court: "NCLT Mumbai Bench", hearing: "2026-09-01",
            updated: "2026-08-01T00:00:00.000Z", filed: "2023-11-20"),
        legalCase(
            "drt", title: "Western Coast Bank v. Mehta Exports", type: "tribunal",
            code: "trib-drt", court: "Debts Recovery Tribunal-I, Mumbai"),
        legalCase(
            "district", title: "Desai v. Desai", type: "district", code: "dist-family",
            court: "Family Court, Bandra", hearing: "2026-10-01", filed: "2025-08-01"),
        legalCase(
            "forum", title: "Iyer v. Skyline Builders", type: "forum", code: "forum-scdrc",
            court: "State Consumer Disputes Redressal Commission, Maharashtra",
            hearing: "2026-09-14", synced: true),
        legalCase("other", title: "Ghosh v. Ghosh"),
    ]

    // MARK: - Court headings

    /// By court unless chosen otherwise, every heading in order of importance, each with only
    /// its own cases.
    func testTheDocketIsHeadedByCourtInOrderOfImportance() async {
        await withDocket { model in
            XCTAssertEqual(model.grouping, .court, "by court is the default")
            XCTAssertEqual(model.groups.map(\.key), [
                "sc", "hc", "nclat", "nclt", "tribunal", "district", "forum", "other",
            ])
            XCTAssertEqual(model.groups.map(\.title), [
                "Supreme Court", "High Courts", "NCLAT", "NCLT", "Tribunals", "District Courts",
                "Consumer Commissions", "Other courts",
            ])
            XCTAssertEqual(model.groups.map { $0.cases.map(\.id) }, [
                ["sc"], ["hcDelhi", "hcBombay"], ["nclat"], ["nclt"], ["drt"], ["district"],
                ["forum"], ["other"],
            ])
        }
    }

    func testACourtWithNoCasesHasNoHeading() async {
        await withDocket(Self.docket.filter { $0.id.hasPrefix("hc") }) { model in
            XCTAssertEqual(model.groups.map(\.key), ["hc"])
        }
    }

    /// Inside a heading the chosen sort holds: two High Courts, by name.
    func testEachHeadingKeepsTheChosenSort() async {
        await withDocket { model in
            XCTAssertEqual(model.groups[1].cases.map(\.id), ["hcDelhi", "hcBombay"],
                           "next hearing: upcoming before past")
            model.sort = .nameAscending
            XCTAssertEqual(model.groups[1].cases.map(\.id), ["hcBombay", "hcDelhi"],
                           "Bakshi before Kapoor")
        }
    }

    // MARK: - Sorts

    /// Soonest upcoming first (today counts as upcoming), then past most recent first, then the
    /// undated by name.
    func testNextHearingSortsUpcomingThenPastThenUndated() async {
        await withDocket { model in
            model.grouping = .none
            XCTAssertEqual(model.sort, .nextHearing, "the default")
            XCTAssertEqual(model.visible.map(\.id), [
                "forum", "hcDelhi", "sc", "district",
                "nclt", "hcBombay",
                "nclat", "other", "drt",
            ])
        }
    }

    /// Newest first, comparing moments rather than text — `hcDelhi`'s zoneless SQLite stamp is
    /// read as UTC — and the never-updated after, by name.
    func testRecentlyUpdatedSortsNewestFirst() async {
        await withDocket { model in
            model.grouping = .none
            model.sort = .recentlyUpdated
            XCTAssertEqual(model.visible.map(\.id), [
                "nclat", "hcDelhi", "sc", "nclt",
                "hcBombay", "district", "other", "forum", "drt",
            ])
        }
    }

    /// The case `updated_at`'s two encodings make for: compared as strings, the zoneless stamp
    /// sorts first because a space is less than a "T", though it is the later moment.
    func testRecentlyUpdatedComparesMomentsNotText() async {
        let docket = [
            Self.legalCase("iso", title: "A", updated: "2026-09-14T09:00:00.000Z"),
            Self.legalCase("sqlite", title: "B", updated: "2026-09-14 10:00:00"),
        ]
        await withDocket(docket) { model in
            model.sort = .recentlyUpdated
            XCTAssertEqual(model.visible.map(\.id), ["sqlite", "iso"])
        }
    }

    func testNameSortsBothWays() async {
        await withDocket { model in
            model.grouping = .none
            model.sort = .nameAscending
            let ascending = [
                "hcBombay", "nclat", "district", "other", "forum", "hcDelhi", "nclt", "sc", "drt",
            ]
            XCTAssertEqual(model.visible.map(\.id), ascending)
            model.sort = .nameDescending
            XCTAssertEqual(model.visible.map(\.id), ascending.reversed())
        }
    }

    /// Ignoring case, as a person reads a list.
    func testNameSortIgnoresCase() async {
        let docket = [
            Self.legalCase("upper", title: "Zeta v. State"),
            Self.legalCase("lower", title: "alpha v. State"),
        ]
        await withDocket(docket) { model in
            model.sort = .nameAscending
            XCTAssertEqual(model.visible.map(\.id), ["lower", "upper"])
        }
    }

    func testFilingDateSortsNewestFirstAndUndatedLast() async {
        await withDocket { model in
            model.grouping = .none
            model.sort = .filingDate
            XCTAssertEqual(model.visible.map(\.id), [
                "district", "nclat", "sc", "hcDelhi", "nclt",
                "hcBombay", "other", "forum", "drt",
            ])
        }
    }

    /// Two cases that tie on everything keep one order, refresh after refresh.
    func testTiesAreBrokenTheSameWayEveryTime() async {
        let docket = [
            Self.legalCase("b", title: "Same v. Same"),
            Self.legalCase("a", title: "Same v. Same"),
        ]
        await withDocket(docket) { model in
            for sort in CaseSort.allCases {
                model.sort = sort
                XCTAssertEqual(model.visible.map(\.id), sort == .nameDescending
                               ? ["b", "a"] : ["a", "b"], sort.rawValue)
            }
        }
    }

    // MARK: - Groupings

    func testHearingDateGroupingKeepsItsThreeHeadings() async {
        await withDocket { model in
            model.grouping = .hearingDate
            XCTAssertEqual(model.groups.map(\.key), ["upcoming", "past", "undated"])
            XCTAssertEqual(model.groups.map(\.title),
                           ["Next in court", "Last listed", "No hearing date"])
            XCTAssertEqual(model.groups.map { $0.cases.map(\.id) }, [
                ["forum", "hcDelhi", "sc", "district"], ["nclt", "hcBombay"],
                ["nclat", "other", "drt"],
            ])

            model.sort = .nameAscending
            XCTAssertEqual(model.groups[0].cases.map(\.id), ["district", "forum", "hcDelhi", "sc"],
                           "the chosen sort holds inside each heading")
        }
    }

    /// A hearing date that is not a real day is no date — not a string compared against today.
    func testAnUnreadableHearingDateCountsAsNoDate() async {
        let docket = [
            Self.legalCase("tba", title: "A", hearing: "TBA"),
            Self.legalCase("impossible", title: "B", hearing: "2026-02-30"),
        ]
        await withDocket(docket) { model in
            model.grouping = .hearingDate
            XCTAssertEqual(model.groups.map(\.key), ["undated"])
        }
    }

    func testNoGroupingIsOneList() async {
        await withDocket { model in
            model.grouping = .none
            XCTAssertEqual(model.groups.count, 1)
            XCTAssertEqual(model.groups.first?.title, "All cases")
            XCTAssertEqual(model.groups.first?.cases.count, Self.docket.count)

            model.query = "nothing like this"
            XCTAssertTrue(model.groups.isEmpty, "no heading over nothing")
        }
    }

    // MARK: - Filters

    func testTheCourtFilterKeepsOnlyTheChosenCourts() async {
        await withDocket { model in
            model.toggle(.court(.highCourt))
            XCTAssertEqual(Set(model.visible.map(\.id)), ["hcDelhi", "hcBombay"])
            XCTAssertEqual(model.groups.map(\.key), ["hc"])
        }
    }

    /// Two courts widen the list rather than emptying it.
    func testChoicesWithinAFilterWiden() async {
        await withDocket { model in
            model.toggle(.court(.supremeCourt))
            model.toggle(.court(.nclat))
            XCTAssertEqual(Set(model.visible.map(\.id)), ["sc", "nclat"])

            model.clearFilters()
            model.toggle(.hearing(.past))
            model.toggle(.hearing(.undated))
            XCTAssertEqual(Set(model.visible.map(\.id)),
                           ["nclt", "hcBombay", "nclat", "other", "drt"])
        }
    }

    func testTheHearingFilter() async {
        await withDocket { model in
            model.toggle(.hearing(.upcoming))
            XCTAssertEqual(Set(model.visible.map(\.id)), ["forum", "hcDelhi", "sc", "district"],
                           "today's hearing is upcoming")
            model.toggle(.hearing(.upcoming))
            model.toggle(.hearing(.past))
            XCTAssertEqual(Set(model.visible.map(\.id)), ["nclt", "hcBombay"])
            model.toggle(.hearing(.past))
            model.toggle(.hearing(.undated))
            XCTAssertEqual(Set(model.visible.map(\.id)), ["nclat", "other", "drt"])
        }
    }

    func testTheSourceFilter() async {
        await withDocket { model in
            model.toggle(.source(.court))
            XCTAssertEqual(Set(model.visible.map(\.id)), ["sc", "hcDelhi", "nclat", "forum"])
            model.toggle(.source(.court))
            model.toggle(.source(.manual))
            XCTAssertEqual(Set(model.visible.map(\.id)),
                           ["hcBombay", "nclt", "drt", "district", "other"])
        }
    }

    /// Across filters the choices narrow: High Courts, upcoming, from the court.
    func testFiltersNarrowInCombination() async {
        await withDocket { model in
            model.toggle(.court(.highCourt))
            model.toggle(.hearing(.upcoming))
            XCTAssertEqual(model.visible.map(\.id), ["hcDelhi"])

            model.toggle(.source(.manual))
            XCTAssertTrue(model.visible.isEmpty)
            XCTAssertEqual(model.noMatches?.title, "No cases match these filters")
            XCTAssertEqual(model.noMatches?.action, "Clear filters")
            XCTAssertFalse(model.presentation.showsEmptyState,
                           "a filtered-out docket is not an empty one")
        }
    }

    // MARK: - Search

    /// The search works inside the filters, not around them.
    func testTheSearchAppliesWithinTheFilters() async {
        await withDocket { model in
            model.toggle(.court(.highCourt))
            model.query = "bakshi"
            XCTAssertEqual(model.visible.map(\.id), ["hcBombay"])

            model.query = "rao"
            XCTAssertTrue(model.visible.isEmpty, "the Supreme Court case is filtered out")
            XCTAssertEqual(model.noMatches?.title, "No cases match these filters")
            XCTAssertEqual(model.noMatches?.message,
                           "Nothing under the filters you have chosen matches “rao”.")
            XCTAssertEqual(model.noMatches?.action, "Clear search and filters")

            model.clearSearchAndFilters()
            XCTAssertEqual(model.query, "")
            XCTAssertTrue(model.filters.isEmpty)
            XCTAssertEqual(model.visible.count, Self.docket.count, "everything is back")
            XCTAssertNil(model.noMatches)
        }
    }

    func testTheSearchFindsWhatAPractitionerReachesFor() async {
        await withDocket { model in
            let expectations: [(String, [String])] = [
                ("DLHC010104212024", ["hcDelhi"]),        // CNR
                ("41207/2025", ["sc"]),                   // diary number
                ("Menon", ["hcDelhi"]),                   // judge
                ("final arguments", ["nclat"]),           // stage
                ("W.P.(C)", ["hcDelhi"]),                 // case type
                ("10421/2024", ["hcDelhi"]),              // the reference as the row prints it
                ("NCLAT", ["nclat"]),                     // the heading, for a name spelt out
                ("Bandra", ["district"]),                 // the court's name
                ("Kapoor 2024", ["hcDelhi"]),             // words from different fields
                ("Kapoor 2025", []),
            ]
            for (query, want) in expectations {
                model.query = query
                XCTAssertEqual(Set(model.visible.map(\.id)), Set(want), query)
            }
        }
    }

    func testASearchAloneThatFindsNothingSaysSo() async {
        await withDocket { model in
            model.query = "  zzz  "
            XCTAssertTrue(model.showsNoSearchResults)
            XCTAssertEqual(model.noMatches?.title, "No cases match “zzz”")
            XCTAssertEqual(model.noMatches?.action, "Clear search")
            model.clearSearchAndFilters()
            XCTAssertNil(model.noMatches)
        }
    }

    /// An empty docket is the empty state, never "nothing matches".
    func testAnEmptyDocketIsNotANoMatch() async {
        await withDocket([]) { model in
            model.toggle(.court(.supremeCourt))
            model.query = "rao"
            XCTAssertFalse(model.showsNoSearchResults)
            XCTAssertNil(model.noMatches)
            XCTAssertTrue(model.presentation.showsEmptyState)
        }
    }

    // MARK: - Chips and the sheet

    func testEachFilterThatIsOnIsAChipInTheSheetsOrder() async {
        await withDocket { model in
            XCTAssertTrue(model.filterChips.isEmpty)
            XCTAssertEqual(model.filterSummary, "No filters")

            model.toggle(.source(.manual))
            model.toggle(.court(.nclt))
            model.toggle(.hearing(.past))
            model.toggle(.court(.supremeCourt))
            XCTAssertEqual(model.filterChips.map(\.label),
                           ["Supreme Court", "NCLT", "Past hearing", "Added by hand"])
            XCTAssertEqual(model.filterChips.map(\.id),
                           ["court-sc", "court-nclt", "hearing-past", "source-manual"])
            XCTAssertEqual(model.filterSummary, "4 filters on")

            model.remove(.court(.nclt))
            XCTAssertFalse(model.isOn(.court(.nclt)))
            XCTAssertEqual(model.filters.count, 3)

            model.clearFilters()
            XCTAssertTrue(model.filterChips.isEmpty)
        }
    }

    /// In the sheet a choice sits under a heading that names its filter; as a chip it stands on
    /// its own, so it has to say which filter it is.
    func testAChoiceIsWordedForWhereItIsShown() {
        XCTAssertEqual(CaseFilterChip.hearing(.undated).optionLabel, "No date")
        XCTAssertEqual(CaseFilterChip.hearing(.undated).label, "No hearing date")
        XCTAssertEqual(CaseFilterChip.hearing(.upcoming).label, "Upcoming hearing")
        XCTAssertEqual(CaseFilterChip.source(.manual).label, "Added by hand")
        XCTAssertEqual(CaseFilterChip.court(.nclat).optionLabel, "NCLAT")
    }

    func testTheSortsAndGroupingsOnOffer() {
        XCTAssertEqual(CaseSort.allCases.map(\.label), [
            "Next hearing", "Recently updated", "Name A–Z", "Name Z–A", "Filing date",
        ])
        XCTAssertEqual(CaseGrouping.allCases.map(\.label), ["Court", "Hearing date", "None"])
        XCTAssertEqual(CaseSort.default, .nextHearing)
        XCTAssertEqual(CaseGrouping.default, .court)
    }

    func testTheSheetCountsEachChoiceAcrossTheWholeDocket() async {
        await withDocket { model in
            model.toggle(.court(.supremeCourt))
            XCTAssertEqual(model.count(for: .court(.highCourt)), 2, "not just what is visible")
            XCTAssertEqual(model.count(for: .hearing(.upcoming)), 4)
            XCTAssertEqual(model.count(for: .hearing(.past)), 2)
            XCTAssertEqual(model.count(for: .hearing(.undated)), 3)
            XCTAssertEqual(model.count(for: .source(.court)), 4)
            XCTAssertEqual(model.count(for: .source(.manual)), 5)
        }
    }

    /// Only the courts the docket has are offered — plus a chosen one whose cases have gone, so
    /// it can still be turned off.
    func testOnlyCourtsOnTheDocketAreOfferedAsFilters() async {
        await withDocket(Self.docket.filter { ["sc", "nclt"].contains($0.id) }) { model in
            XCTAssertEqual(model.courtTierOptions, [.supremeCourt, .nclt])
            model.toggle(.court(.consumerCommission))
            XCTAssertEqual(model.courtTierOptions, [.supremeCourt, .nclt, .consumerCommission])
        }
    }

    func testResetReturnsEverythingButTheSearchToTheDefaults() async {
        await withDocket { model in
            XCTAssertTrue(model.isAtDefaults)
            model.sort = .filingDate
            XCTAssertFalse(model.isAtDefaults)
            model.grouping = .none
            model.toggle(.court(.highCourt))
            model.query = "kapoor"

            model.resetOptions()
            XCTAssertTrue(model.isAtDefaults)
            XCTAssertEqual(model.sort, .nextHearing)
            XCTAssertEqual(model.grouping, .court)
            XCTAssertTrue(model.filters.isEmpty)
            XCTAssertEqual(model.query, "kapoor", "the search has its own clear")
        }
    }

    // MARK: - Remembering

    /// Sort, grouping and filters survive a relaunch; the search does not.
    func testTheLayoutIsRememberedButTheSearchIsNot() async {
        let store = InMemoryPreferenceStore()
        await withDocket(store: store) { model in
            model.sort = .nameDescending
            model.grouping = .hearingDate
            model.toggle(.court(.highCourt))
            model.toggle(.court(.supremeCourt))
            model.toggle(.hearing(.undated))
            model.toggle(.source(.court))
            model.query = "kapoor"
        }
        await withDocket(store: store) { model in
            XCTAssertEqual(model.sort, .nameDescending)
            XCTAssertEqual(model.grouping, .hearingDate)
            XCTAssertEqual(model.filters.courts, [.highCourt, .supremeCourt])
            XCTAssertEqual(model.filters.hearings, [.undated])
            XCTAssertEqual(model.filters.sources, [.court])
            XCTAssertEqual(model.query, "")
        }
    }

    /// One key per choice, raw values in declaration order, so the stored form is stable.
    func testTheStoredFormIsStable() async {
        let store = InMemoryPreferenceStore()
        await withDocket(store: store) { model in
            model.toggle(.court(.consumerCommission))
            model.toggle(.court(.supremeCourt))
            model.sort = .filingDate
            model.grouping = .none
        }
        XCTAssertEqual(store.string(for: "cases.filter.courts.v1"), "sc,forum")
        XCTAssertEqual(store.string(for: "cases.filter.hearings.v1"), "")
        XCTAssertEqual(store.string(for: "cases.sort.v1"), "filing-date")
        XCTAssertEqual(store.string(for: "cases.grouping.v1"), "none")
    }

    func testClearingFiltersIsRememberedToo() async {
        let store = InMemoryPreferenceStore()
        await withDocket(store: store) { model in
            model.toggle(.court(.highCourt))
            model.clearFilters()
        }
        await withDocket(store: store) { model in
            XCTAssertTrue(model.filters.isEmpty)
        }
    }

    /// What a later build or a downgrade leaves behind falls back to the defaults; a filter keeps
    /// the values it recognises.
    func testUnrecognisedStoredValuesFallBackToTheDefaults() async {
        let store = InMemoryPreferenceStore()
        store.setString("by-moon-phase", for: CaseSort.storageKey)
        store.setString("by-judge", for: CaseGrouping.storageKey)
        store.setString("sc, bogus,hc,", for: CaseFilters.courtsKey)
        store.setString("someday", for: CaseFilters.hearingsKey)
        store.setString("", for: CaseFilters.sourcesKey)
        await withDocket(store: store) { model in
            XCTAssertEqual(model.sort, .nextHearing)
            XCTAssertEqual(model.grouping, .court)
            XCTAssertEqual(model.filters.courts, [.supremeCourt, .highCourt])
            XCTAssertTrue(model.filters.hearings.isEmpty)
            XCTAssertTrue(model.filters.sources.isEmpty)
        }
    }

    func testNothingStoredIsTheDefaults() async {
        await withDocket(store: InMemoryPreferenceStore()) { model in
            XCTAssertTrue(model.isAtDefaults)
        }
    }
}

/// See `ChatViewModelTests` for why this is a free function rather than a method.
@MainActor
private func withDocket(
    _ docket: [LegalCase] = CaseListOrganisationTests.docket,
    store: InMemoryPreferenceStore = InMemoryPreferenceStore(),
    _ body: @MainActor (CaseListViewModel) async -> Void
) async {
    let service = FakeCases()
    service.cases = docket
    // 14 Sept 2026, 11:30 IST.
    let stamp = Date(timeIntervalSince1970: 1_789_365_600)
    let model = CaseListViewModel(service: service, store: store, now: { stamp })
    await model.load()
    await body(model)
}
