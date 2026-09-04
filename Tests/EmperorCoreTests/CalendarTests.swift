import XCTest
@testable import EmperorCore

final class CalendarTests: XCTestCase {

    /// 14 Sept 2026, 11:30 IST.
    private static let today = Date(timeIntervalSince1970: 1_789_365_600)

    private static func event(
        _ id: String, due: String?, status: String = "open",
        type: String = "filing", title: String = "File the rejoinder"
    ) -> ComplianceEvent {
        ComplianceEvent(
            id: id, teamID: "team_1", caseID: nil, title: title, type: type,
            dueDateRaw: due, status: status, notes: nil, remindDays: 3,
            createdByUserID: "42", createdAtRaw: "2026-08-26T09:41:02.318Z",
            updatedAtRaw: "2026-08-26T09:41:02.318Z")
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: - The promise the product cannot keep

    /// **No reminder picker.** `remind_days` is written, returned and rendered — and read by
    /// nothing. There is no scheduler scanning `compliance_events`, the `reminder` notification
    /// type has no producer, and the ICS feed emits no `VALARM`. A picker on the one screen
    /// whose purpose is not missing a limitation date would be the worst place in the app to
    /// make a promise that is not kept.
    func testRemindersAreKnownToBeInertSoNoPickerIsOffered() {
        XCTAssertTrue(CalendarService.remindersAreInert)
        // The field still decodes — the server returns it — it is simply never offered.
        let event = Self.event("e1", due: "2026-09-20")
        XCTAssertEqual(event.remindDays, 3)
    }

    /// A subscription URL is a standing credential for a whole calendar, so it is not offered
    /// to a share sheet until it can be issued as a rotatable token.
    func testTheICSFeedIsNotOfferedForSharing() {
        XCTAssertTrue(CalendarService.icsFeedIsUnsafeToShare)
    }

    // MARK: - Statutory markers

    /// Rows with a `stat:` id are bookkeeping written by the Corporate Calendar to record that
    /// an obligation was met — not to-dos. Showing them fills a practitioner's calendar with
    /// entries they never created; the web client filters them for the same reason.
    func testStatutoryMarkersAreRecognised() throws {
        let marker = try decode(
            ComplianceEvent.self,
            #"{"id":"stat:AOC4:2026-10-30","title":"AOC-4","due_date":"2026-10-30"}"#)
        let real = try decode(
            ComplianceEvent.self,
            #"{"id":"cmpl_1756201234567_a1b2c3","title":"Board meeting","due_date":"2026-09-14"}"#)

        XCTAssertTrue(marker.isStatutoryMarker)
        XCTAssertFalse(real.isStatutoryMarker)
    }

    // MARK: - Decoding

    /// `type` is an open string with no CHECK — the Corporate Calendar writes its own category
    /// names (`mca`, `gst`) into it. A closed enum would drop those rows.
    func testTypeIsAnOpenEnum() {
        XCTAssertEqual(ComplianceKind(wire: "filing"), .filing)
        XCTAssertEqual(ComplianceKind(wire: "mca"), .other("mca"))
        XCTAssertEqual(ComplianceKind(wire: nil), .custom)
        XCTAssertEqual(ComplianceKind(wire: "mca").wireValue, "mca", "round-trips unchanged")
        XCTAssertFalse(
            ComplianceKind.selectable.contains(.hearing),
            "hearings come from the court sync, not from this form")
    }

    /// `due_date` is stored verbatim with zero validation. A value that is not a date must not
    /// be forced into a bucket.
    func testAnUnparseableDueDateHasNoDayBucket() throws {
        XCTAssertNil(Self.event("e1", due: "14/09/2026").dayKey)
        XCTAssertNil(Self.event("e2", due: nil).dayKey)
        XCTAssertEqual(Self.event("e3", due: "2026-09-14").dayKey, "2026-09-14")
    }

    /// `created_at` is ISO8601 with milliseconds, despite the DDL claiming
    /// `DEFAULT CURRENT_TIMESTAMP` — the INSERT always binds `toISOString()`.
    func testTimestampsAreISO8601NotTheSQLiteDefaultForm() throws {
        let event = try decode(
            ComplianceEvent.self,
            #"{"id":"e1","updated_at":"2026-08-26T09:41:02.318Z"}"#)
        XCTAssertNotNil(event.updatedAt)
    }

    // MARK: - Combining both sources

    /// A calendar showing only obligations, or only hearings, is worse than none — the whole
    /// point is that the two together are the day.
    func testADayCombinesHearingsAndObligations() async {
        await withCalendar { calendar, cases, model in
            calendar.events = [Self.event("e1", due: "2026-09-14")]
            cases.cases = [Self.legalCase("c1", nextHearing: "2026-09-14")]
            await model.load()

            let day = model.day("2026-09-14")
            XCTAssertEqual(day.events.count, 1)
            XCTAssertEqual(day.hearings.count, 1)
            XCTAssertEqual(day.itemCount, 2)
            XCTAssertFalse(day.isEmpty)
        }
    }

    func testPopulatedDaysCoversBothSources() async {
        await withCalendar { calendar, cases, model in
            calendar.events = [Self.event("e1", due: "2026-09-20")]
            cases.cases = [Self.legalCase("c1", nextHearing: "2026-10-02")]
            await model.load()

            XCTAssertEqual(model.populatedDays, ["2026-09-20", "2026-10-02"])
        }
    }

    /// Overdue *is* a real category here, unlike on the docket: someone typed this date in as
    /// a thing they had to do by then.
    func testOverdueCoversOnlyOpenPastObligations() async {
        await withCalendar { calendar, _, model in
            calendar.events = [
                Self.event("past-open", due: "2026-08-01"),
                Self.event("past-done", due: "2026-08-02", status: "done"),
                Self.event("future", due: "2026-10-01"),
            ]
            await model.load()

            XCTAssertEqual(model.overdue.map(\.id), ["past-open"])
        }
    }

    func testUpcomingStartsFromTodayAndIsOrdered() async {
        await withCalendar { calendar, _, model in
            calendar.events = [
                Self.event("past", due: "2026-08-01"),
                Self.event("later", due: "2026-10-01"),
                Self.event("today", due: "2026-09-14"),
            ]
            await model.load()

            XCTAssertEqual(model.upcoming().map(\.key), ["2026-09-14", "2026-10-01"])
        }
    }

    // MARK: - Writing

    /// The upsert replaces every column it names, so a partial update NULLs the rest. Toggling
    /// "done" therefore has to send the whole row back.
    func testTogglingDoneResendsEveryField() async {
        await withCalendar { calendar, _, model in
            calendar.events = [
                Self.event("e1", due: "2026-09-20", title: "File the rejoinder"),
            ]
            await model.load()

            await model.toggleDone(model.events[0])

            let saved = try? XCTUnwrap(calendar.saved.first)
            XCTAssertEqual(saved?.id, "e1")
            XCTAssertEqual(saved?.title, "File the rejoinder", "title survives the toggle")
            XCTAssertEqual(saved?.kind, .filing, "so does the type")
            XCTAssertEqual(saved?.isDone, true)
        }
    }

    func testAnEmptyTitleIsNotSaved() async {
        await withCalendar { calendar, _, model in
            await model.save(ComplianceDraft(
                title: "   ", dueDate: Self.today))

            XCTAssertTrue(calendar.saved.isEmpty)
        }
    }

    func testMonthSteppingStaysOnTheSameDayNumber() async {
        await withCalendar { _, _, model in
            model.select(day: "2026-09-14")
            model.step(months: 1)
            XCTAssertEqual(model.selectedDay, "2026-10-14")
            model.step(months: -2)
            XCTAssertEqual(model.selectedDay, "2026-08-14")
        }
    }

    func testAFailedLoadIsAFailureNotAnEmptyCalendar() async {
        await withCalendar { calendar, _, model in
            calendar.error = APIError.transport("offline")
            await model.load()

            XCTAssertTrue(model.presentation.showsFailureState)
            XCTAssertFalse(model.presentation.showsEmptyState)
        }
    }

    /// The upsert's `ON CONFLICT` clause sets `remind_days=@remind` (`sync-server.js:10267`),
    /// so a payload that omits it NULLs whatever is stored. This app deliberately offers no
    /// reminder control — but the *web* client does, and silently destroying a value a user set
    /// there would be worse than ignoring the field.
    func testTogglingDonePreservesAReminderSetOnTheWeb() async {
        await withCalendar { calendar, _, model in
            var event = Self.event("e1", due: "2026-09-20")
            event.remindDays = 3
            calendar.events = [event]
            await model.load()

            await model.toggleDone(model.events[0])

            XCTAssertEqual(
                calendar.saved.first?.remindDays, 3,
                "the value round-trips untouched rather than being NULLed")
        }
    }

    /// A brand-new event has no reminder, and must not invent one.
    func testANewEventSendsNoReminder() async {
        await withCalendar { calendar, _, model in
            await model.save(ComplianceDraft(
                title: "File the rejoinder", dueDate: Self.today))

            XCTAssertNil(calendar.saved.first?.remindDays)
        }
    }

    // MARK: - Fixtures

    private static func legalCase(_ id: String, nextHearing: String?) -> LegalCase {
        LegalCase(
            id: id, teamID: "team_1", cnr: nil, courtType: "hc", courtCode: nil,
            caseNumber: "1234", caseYear: "2024", title: "Menon vs. Union of India",
            parties: nil, status: nil, stage: nil, nextHearingDateRaw: nextHearing,
            filingDateRaw: nil, judge: nil, courtName: "Delhi High Court",
            caseType: "W.P.(C)", diaryNumber: nil, category: nil, lastSyncedAtRaw: nil,
            createdAtRaw: nil, updatedAtRaw: nil, teamName: nil)
    }
}

@MainActor
private func withCalendar(
    _ body: @MainActor (FakeCalendar, FakeCases, CalendarViewModel) async -> Void
) async {
    let calendar = FakeCalendar()
    let cases = FakeCases()
    let stamp = Date(timeIntervalSince1970: 1_789_365_600)
    await body(calendar, cases, CalendarViewModel(
        calendar: calendar, caseService: cases, now: { stamp }))
}