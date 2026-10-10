import XCTest
@testable import EmperorCore

/// The Matters tab and the Ask tab's "Next sitting" card, windowed from the cause list in
/// India's days.
final class MattersOverviewTests: XCTestCase {

    private func listing(
        _ date: String, case caseID: String, title: String = "A v. B", item: String? = nil,
        court: String? = "Delhi High Court", listType: String? = nil
    ) -> CauseListing {
        var listing = CauseListing(date: date, caseID: caseID)
        listing.title = title
        listing.itemNo = item
        listing.courtName = court
        listing.listType = listType
        listing.scraped = true
        return listing
    }

    func testTheNextSittingIsTheFirstListedDayFromToday() {
        let overview = MattersOverview(listings: [
            listing("2026-10-08", case: "old"),
            listing("2026-10-14", case: "b", item: "31"),
            listing("2026-10-12", case: "a", item: "14"),
            listing("2026-10-12", case: "c", item: "3"),
            listing("2026-10-22", case: "d"),
        ], todayKey: "2026-10-10")

        XCTAssertEqual(overview.nextSitting?.key, "2026-10-12")
        XCTAssertEqual(overview.nextSitting?.listings.map(\.caseID), ["c", "a"], "item 3 before item 14")
        XCTAssertEqual(overview.upcoming.map(\.key), ["2026-10-14", "2026-10-22"])
    }

    func testTodayCountsAsTheNextSitting() {
        let overview = MattersOverview(
            listings: [listing("2026-10-10", case: "a")], todayKey: "2026-10-10")
        XCTAssertEqual(overview.nextSitting?.key, "2026-10-10")
        XCTAssertEqual(overview.dayLabel("2026-10-10"), "Today")
        XCTAssertEqual(overview.dayLabel("2026-10-11"), "Tomorrow")
        XCTAssertEqual(overview.dayLabel("2026-10-12"), "Mon 12 Oct")
    }

    func testNothingAheadIsSaidPlainly() {
        let overview = MattersOverview(listings: [listing("2026-10-01", case: "a")], todayKey: "2026-10-10")
        XCTAssertNil(overview.nextSitting)
        XCTAssertTrue(overview.upcoming.isEmpty)
        XCTAssertEqual(overview.subtitle(trackedMatters: 14), "Nothing listed ahead · 14 matters tracked")
    }

    func testTheSubtitleNamesTheDay() {
        let overview = MattersOverview(listings: [
            listing("2026-10-12", case: "a"), listing("2026-10-12", case: "b"),
            listing("2026-10-12", case: "c"),
        ], todayKey: "2026-10-10")
        XCTAssertEqual(overview.subtitle(trackedMatters: 1), "3 listed on Monday · 1 matter tracked")
        XCTAssertEqual(overview.subtitle(trackedMatters: nil), "3 listed on Monday")
    }

    func testCalendarBlocks() {
        let block = MattersOverview.calendarBlock("2026-10-14")
        XCTAssertEqual(block.month, "OCT")
        XCTAssertEqual(block.day, "14")
    }

    func testSupplementaryLists() {
        XCTAssertTrue(MattersOverview.isSupplementary(listing("2026-10-12", case: "a", listType: "Supplementary List")))
        XCTAssertFalse(MattersOverview.isSupplementary(listing("2026-10-12", case: "a", listType: "Advance List")))
        XCTAssertFalse(MattersOverview.isSupplementary(listing("2026-10-12", case: "a")))
    }

    func testCourtShortNames() {
        XCTAssertEqual(MattersOverview.courtShortName("Supreme Court of India"), "SC")
        XCTAssertEqual(MattersOverview.courtShortName("Delhi High Court"), "DHC")
        XCTAssertEqual(MattersOverview.courtShortName("High Court of Bombay"), "BHC")
        XCTAssertEqual(MattersOverview.courtShortName("NCLT New Delhi"), "NCLT")
        XCTAssertEqual(MattersOverview.courtShortName("Debts Recovery Tribunal"), "DRT")
        XCTAssertNil(MattersOverview.courtShortName("  "))
    }

    func testHistoryIsTheCasesEarlierListingsLatestFirst() {
        let today = listing("2026-10-12", case: "a", item: "14")
        let all = [
            today,
            listing("2026-08-21", case: "a", item: "9"),
            listing("2026-07-09", case: "a"),
            listing("2026-09-01", case: "other", item: "2"),
            listing("2026-11-01", case: "a"),
        ]
        let history = MattersOverview.history(of: today, in: all)
        XCTAssertEqual(history.map(\.day), ["Fri 21 Aug", "Thu 9 Jul"])
        XCTAssertEqual(history.first?.text, "Listed · item 9")
    }

    func testAskingAboutAHearingNamesIt() {
        var hearing = listing("2026-10-12", case: "a", title: "Sharma Infra v. DDA", item: "14")
        hearing.courtNo = "Court No. 36"
        let prompt = MattersOverview.askPrompt(for: hearing)
        XCTAssertTrue(prompt.hasPrefix("Sharma Infra v. DDA"))
        XCTAssertTrue(prompt.contains("item 14"))
        XCTAssertTrue(prompt.contains("Court 36"))
        XCTAssertTrue(prompt.contains("Delhi High Court"))
        XCTAssertTrue(prompt.hasSuffix("what should I prepare for the hearing?"))
    }
}

/// The head of the Ask tab.
final class AskHomeTests: XCTestCase {

    func testTheGreetingFollowsTheClock() {
        XCTAssertEqual(AskHome.greeting(hour: 0), "Good morning")
        XCTAssertEqual(AskHome.greeting(hour: 11), "Good morning")
        XCTAssertEqual(AskHome.greeting(hour: 12), "Good afternoon")
        XCTAssertEqual(AskHome.greeting(hour: 16), "Good afternoon")
        XCTAssertEqual(AskHome.greeting(hour: 17), "Good evening")
        XCTAssertEqual(AskHome.greeting(hour: 23), "Good evening")
    }

    func testTheGreetingUsesAFirstNameOnly() {
        XCTAssertEqual(AskHome.greetingLine(hour: 9, name: "Aarti Kapoor"), "Good morning, Aarti.")
        XCTAssertEqual(AskHome.greetingLine(hour: 9, name: "Adv. Rohan Mehta"), "Good morning, Rohan.")
        XCTAssertEqual(AskHome.greetingLine(hour: 20, name: "aarti@kapoorlaw.in"), "Good evening.")
        XCTAssertEqual(AskHome.greetingLine(hour: 20, name: nil), "Good evening.")
    }

    func testTheDateLine() {
        let date = WireDate.parseDay("2026-10-10")!.addingTimeInterval(12 * 3600)
        XCTAssertEqual(
            AskHome.dateLine(date, timeZone: TimeZone(identifier: "Asia/Kolkata")!),
            "Saturday, 10 October")
    }

    /// Every role has four suggestions, each with a title, a symbol and a prompt, none repeated.
    func testEveryRoleHasFourSuggestions() {
        for role in PractitionerRole.allCases {
            let suggestions = AskHome.suggestions(for: role)
            XCTAssertEqual(suggestions.count, 4, "\(role)")
            XCTAssertEqual(Set(suggestions.map(\.title)).count, 4, "\(role)")
            for suggestion in suggestions {
                XCTAssertFalse(suggestion.prompt.isEmpty)
                XCTAssertFalse(suggestion.systemImage.isEmpty)
            }
        }
    }

    func testTheRecordModeNames() {
        XCTAssertEqual(ChatModel.fast.modeName, "Fast")
        XCTAssertEqual(ChatModel.thinking.modeName, "Deep thinking")
        XCTAssertNotEqual(ChatModel.fast.modeDescription, ChatModel.thinking.modeDescription)
    }
}

/// Preferences the Record screens keep on the device.
final class RecordPreferencesTests: XCTestCase {

    func testNewQuestionsStartOnFastUnlessTheAccountIsOnTheTopPlanTier() {
        XCTAssertEqual(AnswerModeDefault.starting(plan: "lite"), .fast)
        XCTAssertEqual(AnswerModeDefault.starting(plan: "premium"), .fast)
        XCTAssertEqual(AnswerModeDefault.starting(plan: "none"), .fast)
        XCTAssertEqual(AnswerModeDefault.starting(plan: nil), .fast)
        XCTAssertEqual(AnswerModeDefault.starting(plan: "ultra"), .thinking)
    }

    func testDraftCitationsAreRememberedPerAccount() {
        let store = InMemoryPreferenceStore()
        XCTAssertTrue(DraftCitationsPreference.showsCitations(in: store, userID: 7))
        DraftCitationsPreference.save(false, to: store, userID: 7)
        XCTAssertFalse(DraftCitationsPreference.showsCitations(in: store, userID: 7))
        XCTAssertTrue(DraftCitationsPreference.showsCitations(in: store, userID: 8), "another account")
        DraftCitationsPreference.save(true, to: store, userID: 7)
        XCTAssertTrue(DraftCitationsPreference.showsCitations(in: store, userID: 7))
    }
}

/// Hiding a draft's citation numbers is a display choice that never rewrites the draft.
final class DraftCitationsTests: XCTestCase {

    func testMarkersAreFound() {
        XCTAssertTrue(DraftCitations.hasMarkers("EESL is a joint venture [1]."))
        XCTAssertTrue(DraftCitations.hasMarkers("<p>Allowed in full<sup class=\"dc\">5</sup></p>"))
        XCTAssertFalse(DraftCitations.hasMarkers("Section 34 [of the Act] applies; 2023 [SC] 1."))
        XCTAssertFalse(DraftCitations.hasMarkers("A clean draft."))
    }

    func testMarkersAreTakenOutCleanly() {
        XCTAssertEqual(
            DraftCitations.withoutMarkers("EESL is a joint venture [1]. It appointed A-One [2, 3]."),
            "EESL is a joint venture. It appointed A-One.")
        XCTAssertEqual(
            DraftCitations.withoutMarkers("<p>Allowed in full<sup class=\"dc\">5</sup>.</p>"),
            "<p>Allowed in full.</p>")
        XCTAssertEqual(DraftCitations.withoutMarkers("Pages [3–5] show it"), "Pages show it")
        XCTAssertEqual(DraftCitations.withoutMarkers("No markers here."), "No markers here.")
    }
}
