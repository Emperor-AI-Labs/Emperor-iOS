import XCTest
@testable import EmperorCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Projects are hand-made matters — user-owned rows typed in by an advocate, as opposed to the
// team-owned rows the court scrapers fill in. Almost everything that can go wrong here goes wrong
// *silently*: a key spelled the way the rest of the API spells its keys decodes to nil, a count
// defaulted to zero states something the server never said, and a filter applied locally shows an
// empty archive to someone who has one. Each test below is named for what a user sees when the
// rule it pins is broken.

// MARK: - Builders

private func project(
    _ id: String = "p1",
    name: String? = "Suvarnapatnam v. Ashwatth",
    client: String? = "Suvarnapatnam Infra",
    caseType: String? = "ARB.P.",
    caseNumber: String? = "112",
    caseYear: String? = "2025",
    cnr: String? = nil,
    forumName: String? = "Delhi International Arbitration Centre",
    forumType: String? = "arbitration",
    priority: String? = "high",
    status: String? = nil,
    nextHearing: String? = "2026-09-18",
    linkedCaseID: String? = nil,
    fileCount: Int? = nil,
    chatCount: Int? = nil
) -> Project {
    Project(
        id: id, name: name, client: client, caseNumber: caseNumber, caseYear: caseYear,
        caseType: caseType, cnr: cnr, status: status, priority: priority,
        nextHearingDateRaw: nextHearing, linkedCaseID: linkedCaseID,
        fileCount: fileCount, chatCount: chatCount)
        .with { $0.forumName = forumName; $0.forumType = forumType }
}

private extension Project {
    func with(_ mutate: (inout Project) -> Void) -> Project {
        var copy = self
        mutate(&copy)
        return copy
    }
}

private func update(
    _ id: String = "u1",
    kind: String? = "note",
    title: String? = "Counter-claim filed",
    body: String? = "Served on the other side the same day.",
    eventDate: String? = "2026-08-30"
) -> ProjectUpdate {
    ProjectUpdate(id: id, kind: kind, title: title, body: body, eventDateRaw: eventDate)
}

private func courtRow(
    _ id: String = "i1",
    section: String = "hearings",
    title: String? = "Part-heard",
    subtitle: String? = "Before the sole arbitrator",
    date: String? = "2026-08-12"
) -> CaseItem {
    CaseItem(id: id, section: section, title: title, subtitle: subtitle, itemDateRaw: date)
}

/// A free function rather than a method on the test class, for the reason `withList` gives:
/// an `XCTestCase` is not `Sendable`, so calling `self.something()` from inside a `@MainActor`
/// closure is rejected by Swift 6 as sending task-isolated `self` across an isolation boundary.
private func projectDetail(
    project matter: Project = project(),
    updates: [ProjectUpdate] = [update()],
    courtHistory: [CaseItem] = [courtRow()]
) -> ProjectDetail {
    ProjectDetail(project: matter, updates: updates, courtHistory: courtHistory)
}

// MARK: - Fake

private final class FakeProjects: ProjectProviding, @unchecked Sendable {
    var list: [Project] = []
    var detail: ProjectDetail?
    var listError: Error?
    var detailError: Error?

    /// Every `includeArchived` value the view model actually asked the server for. The point of
    /// recording it is that "filtered locally" and "re-fetched" look identical on screen.
    private(set) var archivedRequests: [Bool] = []
    private(set) var detailRequests: [String] = []

    func projects(includeArchived: Bool) async throws -> [Project] {
        archivedRequests.append(includeArchived)
        if let listError { throw listError }
        return list
    }

    func project(id: String) async throws -> ProjectDetail {
        detailRequests.append(id)
        if let detailError { throw detailError }
        guard let detail else {
            throw APIError.server(status: 404, message: ProjectService.projectGoneMessage)
        }
        return detail
    }
}

/// Linux XCTest cannot invoke a `@MainActor` test method, and an `XCTestCase` is not `Sendable`
/// so a `@MainActor` closure may not capture `self`. Hopping through a free function is the only
/// shape that works on both platforms — see `ChatViewModelTests`.
@MainActor
private func withList(
    _ body: @MainActor (FakeProjects, ProjectListViewModel) async -> Void
) async {
    let fake = FakeProjects()
    await body(fake, ProjectListViewModel(service: fake))
}

@MainActor
private func withDetail(
    projectID: String = "p1",
    _ body: @MainActor (FakeProjects, ProjectDetailViewModel) async -> Void
) async {
    let fake = FakeProjects()
    await body(fake, ProjectDetailViewModel(projectID: projectID, service: fake))
}

// MARK: - The wire

final class ProjectModelTests: XCTestCase {

    private func decodeList(_ json: String) throws -> ProjectListResponse {
        try JSONDecoder().decode(ProjectListResponse.self, from: Data(json.utf8))
    }

    private func decodeDetail(_ json: String) throws -> ProjectDetailResponse {
        try JSONDecoder().decode(ProjectDetailResponse.self, from: Data(json.utf8))
    }

    /// The list route selects `p.*`, so every column the migration block ever added rides out
    /// whether this build knows it or not — and a matter typed in half-finished is the normal
    /// case, not the edge one. A model that required any of these would fail to decode the whole
    /// page because of one thin row.
    func testAMatterWithAlmostEveryFieldNullStillDecodes() throws {
        let response = try decodeList("""
            {"success":true,"projects":[{
              "id":"p1","user_id":"42","name":"Advisory brief","client":null,
              "description":null,"forum_type":"other","forum_name":null,"case_number":null,
              "case_year":null,"cnr":null,"stage":null,"status":"active","priority":"normal",
              "next_hearing_date":null,"filing_date":null,"linked_case_id":null,"color":null,
              "created_at":"2026-08-01T09:00:00.000Z","updated_at":"2026-08-01T09:00:00.000Z",
              "archived_at":null,"file_count":0,"chat_count":0,"update_count":0,
              "last_activity":null}]}
            """)
        let matter = try XCTUnwrap(response.projects?.first)
        XCTAssertEqual(matter.displayName, "Advisory brief")
        XCTAssertNil(matter.caseReference)
        XCTAssertEqual(matter.forumLabel, "other")
        XCTAssertEqual(matter.fileCount, 0)
    }

    /// **The one camelCase key in the feature.** `courtHistory` is built in JavaScript rather
    /// than selected from a column (`sync-server.js:9985`), so spelling it `court_history` the
    /// way every other key on this API is spelled decodes to nil with no error at all — and the
    /// linked case's entire hearing record vanishes from the screen.
    func testCourtHistoryIsCamelCaseUnlikeEveryOtherKey() throws {
        let response = try decodeDetail("""
            {"success":true,"project":{"id":"p1","name":"M"},
             "updates":[],"files":[],"chats":[],
             "courtHistory":[{"id":"i1","section":"hearings","title":"Part-heard",
                              "item_date":"2026-08-12"}]}
            """)
        XCTAssertEqual(response.courtHistory?.count, 1)
        XCTAssertEqual(response.courtHistory?.first?.title, "Part-heard")
    }

    /// `files` and `chats` come back on the detail route and are deliberately unmodelled. Their
    /// presence must not take the decode down with them.
    func testUnmodelledFilesAndChatsDoNotBreakTheDecode() throws {
        let response = try decodeDetail("""
            {"success":true,"project":{"id":"p1","name":"M"},"updates":[],
             "files":[{"id":"f1","file_name":"Award.pdf"}],
             "chats":[{"id":"c1","title":"Draft the reply"}],"courtHistory":[]}
            """)
        XCTAssertEqual(response.project?.id, "p1")
    }

    /// The counts exist only on the list route. Defaulting them to zero would make the detail
    /// screen claim "0 documents" about a matter with seven — the honest answer there is that
    /// the route did not say.
    func testTheComputedCountsAreAbsentRatherThanZeroOnTheDetailRoute() throws {
        let response = try decodeDetail("""
            {"success":true,"project":{"id":"p1","name":"M"},"updates":[],"courtHistory":[]}
            """)
        let matter = try XCTUnwrap(response.project)
        XCTAssertNil(matter.fileCount)
        XCTAssertNil(matter.chatCount)
        XCTAssertNil(matter.updateCount)
    }

    /// `case_number` and `case_year` are TEXT columns. A JSON number sent in round-trips out as
    /// a string, so an `Int?` model would fail on the way back.
    func testCaseNumberAndYearDecodeAsStrings() throws {
        let response = try decodeList("""
            {"success":true,"projects":[
              {"id":"p1","case_type":"W.P.(C)","case_number":"4683","case_year":"2023"}]}
            """)
        XCTAssertEqual(response.projects?.first?.caseReference, "W.P.(C) 4683/2023")
    }

    /// A 500 on this route carries no `success` key at all — the catch writes `{error}` only
    /// (`sync-server.js:9934-9936`). Absence has to read as failure, not as a missing field.
    func testAServerFailureCarriesNoSuccessKey() throws {
        let response = try decodeList(#"{"error":"Missing userId"}"#)
        XCTAssertNil(response.success)
        XCTAssertEqual(response.error, "Missing userId")
        XCTAssertThrowsError(
            try CaseService.throwIfUnsuccessful(
                success: response.success, error: response.error))
    }

    /// The wire key is `description`; the property is `notes`. If the mapping is dropped the
    /// field silently becomes nil and the matter's notes disappear.
    func testTheDescriptionColumnLandsOnNotes() throws {
        let response = try decodeList("""
            {"success":true,"projects":[{"id":"p1","description":"Section 34 challenge."}]}
            """)
        XCTAssertEqual(response.projects?.first?.notes, "Section 34 challenge.")
    }

    // MARK: - Derived reading

    /// A hand-typed matter is half-filled far more often than a scraped one. `LegalCase`'s rule
    /// would render a number with no year as the bare string "112", which reads as nothing —
    /// so a project draws the slash only when it has both halves.
    func testACaseNumberWithNoYearDoesNotGrowAStraySlash() {
        XCTAssertEqual(
            project(caseType: "ARB.P.", caseNumber: "112", caseYear: nil).caseReference,
            "ARB.P. 112")
        XCTAssertEqual(
            project(caseType: nil, caseNumber: "112", caseYear: "2025").caseReference,
            "112/2025")
    }

    /// The CNR is a fallback, not a suffix: a matter with neither a number nor a year is still
    /// addressable by it, and showing both would print the same matter twice.
    func testTheCNRStandsInWhenThereIsNoNumber() {
        XCTAssertEqual(
            project(caseType: nil, caseNumber: nil, caseYear: nil, cnr: "DLHC010012342026")
                .caseReference,
            "DLHC010012342026")
        XCTAssertNil(project(caseType: "ARB.P.", caseNumber: nil, caseYear: nil).caseReference)
    }

    /// Blank is not the same as absent. `POST /project` writes `b.client ?? null`, so a form
    /// submitted with a space in the field stores a space — which would render as a bullet with
    /// nothing after it.
    func testWhitespaceOnlyFieldsCountAsAbsent() {
        let blank = project(name: "   ", client: "  ", forumName: " ", forumType: "  ")
        XCTAssertEqual(blank.displayName, "Untitled matter")
        XCTAssertNil(blank.forumLabel)
    }

    /// The free-text forum name wins over the grouping key: "NCLT New Delhi Bench-III" is what
    /// an advocate recognises, `tribunal` is what a database does.
    func testTheForumNameWinsOverTheForumType() {
        XCTAssertEqual(
            project(forumName: "NCLT New Delhi Bench-III", forumType: "tribunal").forumLabel,
            "NCLT New Delhi Bench-III")
        XCTAssertEqual(project(forumName: nil, forumType: "tribunal").forumLabel, "tribunal")
    }

    /// `priority` and `status` are free strings with no server-side whitelist, and the web
    /// writes them from a `<select>` whose casing has changed once already.
    func testPriorityAndStatusAreComparedCaseInsensitively() {
        XCTAssertTrue(project(priority: "HIGH").isHighPriority)
        XCTAssertTrue(project(status: "Archived").isArchived)
        XCTAssertFalse(project(priority: "normal").isHighPriority)
        XCTAssertFalse(project(status: nil).isArchived)
    }

    /// `last_activity` is `COALESCE(event_date, created_at)`, so it is a bare day on some rows
    /// and a zoneless SQLite timestamp on others — in the same list, from the same query.
    func testLastActivityParsesBothEncodingsTheQueryCanProduce() {
        XCTAssertNotNil(project().with { $0.lastActivityRaw = "2026-08-30" }.lastActivity)
        XCTAssertNotNil(
            project().with { $0.lastActivityRaw = "2026-08-30 04:11:07" }.lastActivity)
        XCTAssertNil(project().with { $0.lastActivityRaw = "" }.lastActivity)
    }

    /// An update sorts on when the **thing** happened, falling back to when it was recorded —
    /// the same `COALESCE` the server's `ORDER BY` uses. Sorting on `created_at` alone would
    /// make backdating an order received last week reshuffle the whole file.
    func testAnUpdateFallsBackFromEventDateToCreatedAt() {
        XCTAssertNotNil(update(eventDate: "2026-08-30").day)
        let recordedOnly = ProjectUpdate(
            id: "u2", title: "Filed", eventDateRaw: nil,
            createdAtRaw: "2026-08-29 11:02:00")
        XCTAssertNotNil(recordedOnly.day)
    }

    /// A row with neither a title nor a body draws as a date beside blank space, which reads as
    /// a rendering fault rather than as an empty note.
    func testEmptyRowsAreNotRenderable() {
        XCTAssertFalse(update(title: nil, body: nil).isRenderable)
        XCTAssertFalse(update(title: "  ", body: "").isRenderable)
        XCTAssertTrue(update(title: nil, body: "Served.").isRenderable)
        XCTAssertFalse(courtRow(title: nil, subtitle: nil).isRenderable)
        XCTAssertTrue(courtRow(title: "Part-heard", subtitle: nil).isRenderable)
    }

    /// `section` is an open string with no server-side whitelist, so a value this build has not
    /// heard of must still label itself rather than render a blank heading.
    func testAnUnknownSectionStillLabelsItself() {
        XCTAssertEqual(courtRow(section: "hearings").sectionLabel, "Hearings")
        XCTAssertEqual(courtRow(section: "interim_applications").sectionLabel,
                       "Interim Applications")
        XCTAssertEqual(courtRow(section: "").sectionLabel, "Other")
    }
}

// MARK: - The routes

final class ProjectServiceWireTests: XCTestCase {

    private static let config = APIConfig(baseURL: URL(string: "https://example.test/api")!)

    override func tearDown() {
        HTTPStub.reset()
        super.tearDown()
    }

    private func makeService() async -> ProjectService {
        let client = APIClient(config: Self.config, session: HTTPStub.session())
        await client.setCredentials(Credentials(token: "tok-abc", userID: 42))
        return ProjectService(client: client)
    }

    /// The default must match the web's request exactly. The route tests `=== '1'`, so any
    /// other spelling — `true`, `0`, `yes` — is read as false; sending one would look like an
    /// opt-in that never takes effect.
    func testTheArchivedFlagIsOmittedByDefaultAndSentAsTheLiteralOne() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":true,"projects":[]}"#))

        _ = try await service.projects(includeArchived: false)
        XCTAssertEqual(HTTPStub.lastRequest?.path, "/api/projects")
        XCTAssertNil(HTTPStub.lastRequest?.queryItems["includeArchived"])

        _ = try await service.projects(includeArchived: true)
        XCTAssertEqual(HTTPStub.lastRequest?.queryItems["includeArchived"], "1")
    }

    /// Every route on this feature re-checks ownership from the DB, and `userId` is what it
    /// checks against. Without it the list route throws into its 500 handler.
    func testTheCallerIdentityRidesOnEveryProjectRequest() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":true,"projects":[]}"#))

        _ = try await service.projects(includeArchived: false)

        let sent = try XCTUnwrap(HTTPStub.lastRequest)
        XCTAssertEqual(sent.queryItems["userId"], "42")
        XCTAssertEqual(sent.header("Authorization"), "Bearer tok-abc")
    }

    func testTheDetailRouteAsksByIdOnTheQueryString() async throws {
        let service = await makeService()
        HTTPStub.always(.json("""
            {"success":true,"project":{"id":"p1","name":"M"},"updates":[],"courtHistory":[]}
            """))

        _ = try await service.project(id: "p1")

        let sent = try XCTUnwrap(HTTPStub.lastRequest)
        XCTAssertEqual(sent.path, "/api/project")
        XCTAssertEqual(sent.queryItems["id"], "p1")
    }

    /// `WHERE id = ? AND user_id = ?` means "gone" and "not yours" are the same 404 by design.
    /// The server's own word for it is the bare string "Project not found", which says nothing
    /// about what to do next — so it is rewritten once, here, rather than at each screen.
    func testAMissingOrForeignMatterGetsOneHonestSentence() async {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":false,"error":"Project not found"}"#, status: 404))

        do {
            _ = try await service.project(id: "p-someone-elses")
            XCTFail("expected a 404")
        } catch let error as APIError {
            XCTAssertEqual(
                error, .server(status: 404, message: ProjectService.projectGoneMessage))
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    /// An id that is blank never reaches the network: the route answers `Missing id or userId`
    /// as a **500**, which `RetryPolicy` classifies as transient — so an empty id would cost
    /// three attempts and ~1.8s of backoff before surfacing as "the server is unhappy".
    func testABlankIdIsRefusedWithoutASingleRequest() async {
        let service = await makeService()

        do {
            _ = try await service.project(id: "   ")
            XCTFail("expected a refusal")
        } catch let error as APIError {
            XCTAssertEqual(
                error, .server(status: 404, message: ProjectService.projectGoneMessage))
            XCTAssertTrue(HTTPStub.seen.isEmpty, "nothing should have gone on the wire")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    /// Filtering in the service rather than the view is what keeps a section header's count and
    /// the number of rows beneath it from disagreeing.
    func testUnrenderableRowsAreDroppedBeforeTheScreenEverSeesThem() async throws {
        let service = await makeService()
        HTTPStub.always(.json("""
            {"success":true,"project":{"id":"p1","name":"M"},
             "updates":[{"id":"u1","title":"Filed"},{"id":"u2","title":null,"body":"  "}],
             "courtHistory":[{"id":"i1","section":"orders","title":"Order dated 12.08.2026"},
                             {"id":"i2","section":"orders","title":null,"subtitle":null}]}
            """))

        let detail = try await service.project(id: "p1")

        XCTAssertEqual(detail.updates.count, 1)
        XCTAssertEqual(detail.courtHistory.count, 1)
    }

    /// A 200 whose body has no project is not a success. It reaches the same sentence as a 404
    /// rather than a decoding error about a matter that was deleted.
    func testASuccessfulResponseWithNoProjectIsStillAFailure() async {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":true,"updates":[],"courtHistory":[]}"#))

        do {
            _ = try await service.project(id: "p1")
            XCTFail("expected a refusal")
        } catch let error as APIError {
            XCTAssertEqual(
                error, .server(status: 404, message: ProjectService.projectGoneMessage))
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    /// The whole feature is a viewer. Nothing on either screen may reach a write route while the
    /// shape of a project is still moving on the web — see `ProjectService`. This pins that the
    /// only verbs in play are reads.
    func testTheFeatureNeverIssuesAWrite() async throws {
        let service = await makeService()
        HTTPStub.respond { request in
            request.path.hasSuffix("/projects")
                ? .json(#"{"success":true,"projects":[{"id":"p1","name":"M"}]}"#)
                : .json("""
                    {"success":true,"project":{"id":"p1","name":"M"},
                     "updates":[],"courtHistory":[]}
                    """)
        }

        _ = try await service.projects(includeArchived: true)
        _ = try await service.project(id: "p1")

        XCTAssertEqual(HTTPStub.seen.count, 2)
        for request in HTTPStub.seen {
            XCTAssertEqual(request.httpMethod, "GET", "\(request.path) must be a read")
            XCTAssertNil(request.httpBody)
        }
    }
}

// MARK: - The list screen

final class ProjectListViewModelTests: XCTestCase {

    /// The route orders by priority, then next hearing, then last update. Re-sorting here would
    /// put the phone and the browser in disagreement about which matter is most urgent — the one
    /// thing a priority field exists to settle.
    func testTheServersOrderIsKeptExactlyAsItArrived() async {
        await withList { fake, model in
            fake.list = [project("b", name: "B"), project("a", name: "A"), project("c", name: "C")]
            await model.load()
            XCTAssertEqual(model.visible.map(\.id), ["b", "a", "c"])
        }
    }

    /// Archived matters are excluded in the route's `WHERE` clause, so the rows are not in hand.
    /// A local filter would show an empty archive to someone who has one — and nothing on screen
    /// would say why.
    func testTurningOnArchivedRefetchesRatherThanFiltering() async {
        await withList { fake, model in
            fake.list = [project()]
            await model.load()
            XCTAssertEqual(fake.archivedRequests, [false])

            await model.setIncludeArchived(true)

            XCTAssertEqual(fake.archivedRequests, [false, true])
            XCTAssertTrue(model.includeArchived)
        }
    }

    /// Setting it to what it already is must not spend a request. The toggle is bound to a
    /// `Binding` that fires on every read-back, and a screen that re-fetches on redraw is a
    /// battery bug nobody sees.
    func testSettingTheFlagToItsCurrentValueIsANoOp() async {
        await withList { fake, model in
            await model.load()
            await model.setIncludeArchived(false)
            XCTAssertEqual(fake.archivedRequests, [false])
        }
    }

    /// "The server says you have nothing" is not "we could not ask". Collapsing them is how the
    /// web tells a litigator their day is clear when the request merely failed.
    func testAFailedLoadIsNeverPresentedAsAnEmptyList() async {
        await withList { fake, model in
            fake.listError = APIError.transport("The network connection was lost.")
            await model.load()

            XCTAssertTrue(model.presentation.showsFailureState)
            XCTAssertFalse(model.presentation.showsEmptyState)
        }
    }

    /// A dropped connection must not blank a list someone is reading.
    func testAFailedRefreshKeepsTheRowsAlreadyOnScreen() async {
        await withList { fake, model in
            fake.list = [project()]
            await model.load()

            fake.listError = APIError.transport("The network connection was lost.")
            await model.load()

            XCTAssertEqual(model.visible.count, 1)
            XCTAssertTrue(model.presentation.showsStaleBanner)
            XCTAssertFalse(model.presentation.showsFailureState)
        }
    }

    /// `presentation.isEmpty` is measured against the **filtered** list, which is what routes a
    /// fruitless search into the empty closure rather than into an empty content view.
    func testASearchThatMatchesNothingRoutesToTheEmptyState() async {
        await withList { fake, model in
            fake.list = [project()]
            await model.load()
            model.query = "zzzz"

            XCTAssertTrue(model.presentation.showsEmptyState)
            XCTAssertTrue(model.showsNoSearchResults)
            XCTAssertEqual(model.emptyTitle, "No matters match")
        }
    }

    /// The commonest reason a matter someone remembers is missing is that they archived it. A
    /// reader not told the filter exists concludes the matter is gone.
    func testTheFruitlessSearchNamesTheArchivedFilterWhileItIsOff() async {
        await withList { fake, model in
            fake.list = [project()]
            await model.load()
            model.query = "zzzz"
            XCTAssertTrue(model.emptyDetail.contains("Archived matters are not being shown"))

            await model.setIncludeArchived(true)
            model.query = "zzzz"
            XCTAssertFalse(model.emptyDetail.contains("Archived matters are not being shown"))
        }
    }

    /// An account with no matters at all is a different sentence from a fruitless search: this
    /// screen cannot create one, so it has to say where they come from.
    func testATrulyEmptyAccountIsToldWhereMattersComeFrom() async {
        await withList { _, model in
            await model.load()
            XCTAssertFalse(model.showsNoSearchResults)
            XCTAssertEqual(model.emptyTitle, "No matters yet")
            XCTAssertEqual(model.emptyDetail, ProjectListViewModel.Copy.openedOnTheWeb)
        }
    }

    /// A tribunal matter is very often remembered by its forum rather than its name, and the
    /// forum name is free text that appears nowhere else.
    func testTheFilterReachesTheForumTheClientAndTheReference() async {
        await withList { fake, model in
            fake.list = [
                project("a", name: "Rao — service matter", client: "K. Rao",
                        caseType: nil, caseNumber: nil, caseYear: nil,
                        forumName: "NCLT New Delhi Bench-III", forumType: "tribunal"),
                project("b", name: "Suvarnapatnam v. Ashwatth"),
            ]
            await model.load()

            model.query = "bench-iii"
            XCTAssertEqual(model.visible.map(\.id), ["a"])
            model.query = "k. rao"
            XCTAssertEqual(model.visible.map(\.id), ["a"])
            model.query = "ARB.P. 112/2025"
            XCTAssertEqual(model.visible.map(\.id), ["b"])
        }
    }

    /// `.idle` is separate from `.loading` because a view's `.task` runs after its first render.
    /// Keying the empty state on "not currently loading" flashes it on every cold open.
    func testNothingIsClaimedBeforeTheFirstLoadAnswers() async {
        await withList { _, model in
            XCTAssertTrue(model.presentation.showsLoadingPlaceholder)
            XCTAssertFalse(model.presentation.showsEmptyState)
        }
    }
}

// MARK: - The detail screen

final class ProjectDetailViewModelTests: XCTestCase {

    /// The decision this screen exists to get right: the matter's own timeline and the court's
    /// record stay **separate**. The server merges them into one response so a client *can*
    /// interleave, and the web does — but a note someone typed and a registry order are
    /// different kinds of fact, and merged they end up sharing one spine and one weight.
    func testTheTwoRecordsAreNeverMergedIntoOneChronology() async {
        await withDetail { fake, model in
            fake.detail = projectDetail(
                updates: [update("u1", title: "Order received", eventDate: "2026-08-13")],
                courtHistory: [courtRow("i1", title: "Order dated 12.08.2026",
                                        date: "2026-08-12")])
            await model.load()

            XCTAssertEqual(model.updates.map(\.id), ["u1"])
            XCTAssertEqual(model.courtHistory.map(\.id), ["i1"])
            // Interleaving by date would have put the court row between the two. Nothing on this
            // model offers a combined list at all — that is the point.
            XCTAssertEqual(model.updates.count + model.courtHistory.count, 2)
        }
    }

    /// A link can point at a case with no items yet, or at one the sync has since deleted.
    /// Showing nothing at all invites the reader to conclude the link failed.
    func testALinkWithNoRowsBehindItSaysSoRatherThanShowingNothing() async {
        await withDetail { fake, model in
            fake.detail = projectDetail(
                project: project(linkedCaseID: "case-99"), courtHistory: [])
            await model.load()

            XCTAssertTrue(model.isLinkedToCase)
            XCTAssertNotNil(model.courtRecordCaveat)
        }
    }

    /// An unlinked matter is a purely manual one — an arbitration, an advisory brief. There is
    /// no court record to caveat, so the section is absent rather than apologetic.
    func testAnUnlinkedMatterGetsNoCourtRecordSectionAtAll() async {
        await withDetail { fake, model in
            fake.detail = projectDetail(project: project(linkedCaseID: nil), courtHistory: [])
            await model.load()

            XCTAssertFalse(model.isLinkedToCase)
            XCTAssertNil(model.courtRecordCaveat)
        }
    }

    /// A blank link is not a link. `POST /project` writes `b.linkedCaseId ?? null`, and a form
    /// submitted with an empty select stores an empty string.
    func testABlankLinkedCaseIdIsNotTreatedAsALink() async {
        await withDetail { fake, model in
            fake.detail = projectDetail(project: project(linkedCaseID: "  "), courtHistory: [])
            await model.load()
            XCTAssertFalse(model.isLinkedToCase)
        }
    }

    /// The facts panel states only what the matter states. A row reading "Stage: —" is a claim
    /// that the field was checked and found blank, which is not what a null means.
    func testTheFactsPanelSkipsEverythingTheMatterDoesNotState() async {
        await withDetail { fake, model in
            fake.detail = projectDetail(
                project: project(client: nil, caseType: nil, caseNumber: nil, caseYear: nil,
                                 forumName: nil, forumType: nil, nextHearing: nil))
            await model.load()

            XCTAssertTrue(model.facts.isEmpty)
        }
    }

    /// The next hearing is the one fact this screen is opened to check, so it carries emphasis
    /// while the rest do not.
    func testTheNextHearingIsTheOneEmphasisedFact() async {
        await withDetail { fake, model in
            fake.detail = projectDetail()
            await model.load()

            // Read top-down: who it is for, what it is, where it is heard, when it is next on.
            XCTAssertEqual(
                model.facts.map(\.label), ["Client", "Case", "Forum", "Next hearing"])
            XCTAssertEqual(model.facts.filter(\.isEmphasised).map(\.label), ["Next hearing"])
        }
    }

    /// "Archived" is the reason a matter is not on the default list, so it has to be visible
    /// from inside the matter. "Active" is the default and says nothing, so it is not shown.
    func testOnlyTheArchivedStatusIsWorthARow() async {
        await withDetail { fake, model in
            fake.detail = projectDetail(project: project(status: "archived"))
            await model.load()
            XCTAssertTrue(model.facts.contains { $0.label == "Status" && $0.value == "Archived" })

            fake.detail = projectDetail(project: project(status: "active"))
            await model.load()
            XCTAssertFalse(model.facts.contains { $0.label == "Status" })
        }
    }

    /// A 404 must not read as an empty matter. The wording comes up from the service through
    /// `LoadFailure`, so the screen shows one honest sentence rather than a blank panel.
    func testAMissingMatterFailsRatherThanRenderingEmpty() async {
        await withDetail { fake, model in
            fake.detailError = APIError.server(
                status: 404, message: ProjectService.projectGoneMessage)
            await model.load()

            XCTAssertTrue(model.presentation.showsFailureState)
            XCTAssertEqual(model.state.failure?.message, ProjectService.projectGoneMessage)
            XCTAssertEqual(model.title, "Matter")
        }
    }

    func testTheTitleFallsBackWhileTheMatterIsStillLoading() async {
        await withDetail { fake, model in
            XCTAssertEqual(model.title, "Matter")
            fake.detail = projectDetail(project: project(name: "   "))
            await model.load()
            XCTAssertEqual(model.title, "Untitled matter")
        }
    }

    func testTheDetailRouteIsAskedForTheIdItWasGiven() async {
        await withDetail(projectID: "p-42") { fake, model in
            fake.detail = projectDetail()
            await model.load()
            XCTAssertEqual(fake.detailRequests, ["p-42"])
        }
    }
}

// MARK: - Wiring

final class ProjectSessionWiringTests: XCTestCase {

    /// The service has to hang off `Session`, and off the **same** client as everything else —
    /// a second `APIClient` would carry no credentials and 500 on every request.
    func testTheSessionExposesTheProjectServiceOnTheSharedClient() async {
        await withProjectSession { session in
            XCTAssertTrue(
                session.projects.client === session.client,
                "must share the one authenticated client")
        }
    }
}

/// Free function, not a method: an `XCTestCase` is not `Sendable`, so calling an instance helper
/// from a `@MainActor` closure makes Swift 6 reject the capture of `self`.
@MainActor
private func withProjectSession(_ body: @MainActor (Session) async -> Void) async {
    await body(Session(
        config: APIConfig(baseURL: URL(string: "https://example.test/api")!),
        store: InMemoryCredentialStore(),
        cache: ResponseCache(store: InMemoryCacheStore())))
}
