import XCTest
@testable import EmperorCore

private final class FakeDraftHistory: DraftHistoryProviding, @unchecked Sendable {
    var byKind: [DraftKind: [DraftedItem]] = [:]
    var content = "# Writ Petition\n\nIn the matter of…"
    var listFailure: Error?
    var contentFailure: Error?
    private(set) var requestedKinds: [DraftKind] = []
    private(set) var requestedIDs: [String] = []

    func drafts(_ kind: DraftKind) async throws -> [DraftedItem] {
        requestedKinds.append(kind)
        if let listFailure { throw listFailure }
        return byKind[kind] ?? []
    }

    func content(id: String) async throws -> String {
        requestedIDs.append(id)
        if let contentFailure { throw contentFailure }
        return content
    }
}

private func item(
    _ id: String, title: String? = "Writ Petition Draft", chat: String? = "Bail matter",
    chatID: String? = "ch12", created: String? = "2026-07-14T09:00:00.000Z"
) -> DraftedItem {
    DraftedItem(
        id: id, chatID: chatID, title: title, type: "doc",
        createdAtRaw: created, chatTitle: chat)
}

@MainActor
private func withHistory(
    _ body: @MainActor (FakeDraftHistory, DraftHistoryViewModel) async -> Void
) async {
    let fake = FakeDraftHistory()
    await body(fake, DraftHistoryViewModel(service: fake))
}

final class DraftedItemTests: XCTestCase {

    /// **Two encodings on one field.** Ordinary writes are JavaScript ISO 8601 with
    /// milliseconds; migrated rows and the column default are SQLite's zoneless
    /// `YYYY-MM-DD HH:MM:SS`. One `dateDecodingStrategy` cannot read both.
    func testBothTimestampEncodingsParse() {
        XCTAssertNotNil(item("a", created: "2026-07-14T09:00:00.000Z").createdAt)
        XCTAssertNotNil(item("b", created: "2026-07-14 09:00:00").createdAt)
    }

    func testAMissingTimestampIsNotAFailure() {
        XCTAssertNil(item("a", created: nil).createdAt)
    }

    func testWireKeysAreSnakeCase() throws {
        let json = """
            {"id":"doc_1","chat_id":"ch12","user_id":"7","title":"Writ Petition Draft",
             "type":"doc","created_at":"2026-07-14T09:00:00.000Z","chat_title":"Bail matter"}
            """
        let decoded = try JSONDecoder().decode(DraftedItem.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.chatID, "ch12")
        XCTAssertEqual(decoded.chatTitle, "Bail matter")
        XCTAssertEqual(decoded.displayTitle, "Writ Petition Draft")
    }

    /// The server COALESCEs a missing chat title to `""`, never null — so emptiness, not nil,
    /// is what says the conversation is gone.
    func testADeletedConversationIsSaidPlainly() {
        let orphan = item("a", chat: "")
        XCTAssertNil(orphan.openableChatID, "there is nothing to navigate to")
        XCTAssertTrue(orphan.sourceLabel.contains("since deleted"))
    }

    func testALiveConversationCanBeOpened() {
        XCTAssertEqual(item("a").openableChatID, "ch12")
        XCTAssertEqual(item("a").sourceLabel, "From Bail matter")
    }

    func testAnUntitledDraftStillHasALabel() {
        XCTAssertEqual(item("a", title: "  ").displayTitle, "Untitled")
        XCTAssertEqual(item("a", title: nil).displayTitle, "Untitled")
    }

    // MARK: - The two-keys response

    /// The route returns the **same array under both keys**. On `/tables` the `documents` key
    /// contains tables, so keying off the name would silently show the wrong list — or an
    /// empty one.
    func testEitherResponseKeyIsAccepted() throws {
        let asDocuments = #"{"success":true,"documents":[{"id":"d1"}],"tables":[{"id":"d1"}]}"#
        let decoded = try JSONDecoder().decode(
            DraftListResponse.self, from: Data(asDocuments.utf8))
        XCTAssertEqual(decoded.documents?.first?.id, "d1")
        XCTAssertEqual(decoded.tables?.first?.id, "d1")
    }

    func testTheTwoKindsAreDifferentRoutes() {
        XCTAssertEqual(DraftKind.document.path, "/documents")
        XCTAssertEqual(DraftKind.table.path, "/tables")
    }
}

final class DraftHistoryViewModelTests: XCTestCase {

    func testDraftsAreListed() async {
        await withHistory { fake, model in
            fake.byKind[.document] = [item("d1"), item("d2")]
            await model.load()

            XCTAssertEqual(model.items.count, 2)
            XCTAssertEqual(model.state, .loaded)
        }
    }

    /// Drafts and tables are separate lists behind separate routes. Leaving one on screen while
    /// the picker says the other is worse than a spinner.
    func testSwitchingKindClearsTheOldList() async {
        await withHistory { fake, model in
            fake.byKind[.document] = [item("d1")]
            await model.load()
            XCTAssertFalse(model.items.isEmpty)

            model.kind = .table
            XCTAssertTrue(model.items.isEmpty)
            XCTAssertEqual(model.state, .idle)
        }
    }

    func testSwitchingKindAsksTheOtherRoute() async {
        await withHistory { fake, model in
            fake.byKind[.table] = [item("t1")]
            model.kind = .table
            await model.load()

            XCTAssertEqual(fake.requestedKinds, [.table])
            XCTAssertEqual(model.items.count, 1)
        }
    }

    func testAFailedLoadIsReportedAndLeavesNothingStale() async {
        await withHistory { fake, model in
            fake.byKind[.document] = [item("d1")]
            await model.load()

            fake.listFailure = APIError.transport("offline")
            await model.load()

            XCTAssertTrue(model.items.isEmpty)
            if case .failed = model.state {} else { XCTFail("expected a failure state") }
        }
    }

    // MARK: - Searching

    func testSearchMatchesTheDraftTitle() async {
        await withHistory { fake, model in
            fake.byKind[.document] = [
                item("d1", title: "Writ Petition Draft"),
                item("d2", title: "Bail Application"),
            ]
            await model.load()
            model.query = "bail app"

            XCTAssertEqual(model.visible.map(\.id), ["d2"])
        }
    }

    /// Someone hunting for "the Bakshi petition" may remember the conversation rather than
    /// what the draft ended up being called.
    func testSearchAlsoMatchesTheConversationItCameFrom() async {
        await withHistory { fake, model in
            fake.byKind[.document] = [
                item("d1", title: "Untitled", chat: "Bakshi partition suit"),
                item("d2", title: "Bail Application", chat: "Other"),
            ]
            await model.load()
            model.query = "bakshi"

            XCTAssertEqual(model.visible.map(\.id), ["d1"])
        }
    }

    func testNoSearchResultsIsDistinctFromAnEmptyLibrary() async {
        await withHistory { fake, model in
            fake.byKind[.document] = [item("d1", title: "Writ")]
            await model.load()

            model.query = "nothing matches this"
            XCTAssertTrue(model.showsNoSearchResults)

            model.query = ""
            XCTAssertFalse(model.showsNoSearchResults)
        }
    }

    // MARK: - Grouping

    /// A draft written at 11pm IST is that day's work. Bucketing against the device's zone
    /// files it under the next day for anyone travelling.
    func testDraftsAreGroupedByTheDayInIndia() async {
        await withHistory { fake, model in
            fake.byKind[.document] = [
                // 2026-07-14 23:30 IST == 18:00Z the same day.
                item("d1", created: "2026-07-14T18:00:00.000Z"),
                // 2026-07-14 05:59 IST == 00:29Z the same day.
                item("d2", created: "2026-07-14T00:29:00.000Z"),
            ]
            await model.load()

            XCTAssertEqual(model.groups.count, 1, "both are the same working day in India")
        }
    }

    func testTwoDaysMakeTwoGroups() async {
        await withHistory { fake, model in
            fake.byKind[.document] = [
                item("d1", created: "2026-07-15T06:00:00.000Z"),
                item("d2", created: "2026-07-14T06:00:00.000Z"),
            ]
            await model.load()
            XCTAssertEqual(model.groups.count, 2)
        }
    }

    /// A row whose timestamp did not parse still has to appear. A blank heading reads as a
    /// rendering fault, and dropping the row silently loses someone's work.
    func testAnUndatedDraftIsStillShown() async {
        await withHistory { fake, model in
            fake.byKind[.document] = [item("d1", created: nil)]
            await model.load()

            XCTAssertEqual(model.groups.count, 1)
            XCTAssertEqual(model.groups.first?.title, "Undated")
            XCTAssertEqual(model.groups.first?.items.count, 1)
        }
    }

    /// The server returns newest first and that order carries information. Grouping must not
    /// reshuffle it.
    func testTheServersOrderIsPreserved() async {
        await withHistory { fake, model in
            fake.byKind[.document] = [
                item("newest", created: "2026-07-16T06:00:00.000Z"),
                item("middle", created: "2026-07-15T06:00:00.000Z"),
                item("oldest", created: "2026-07-14T06:00:00.000Z"),
            ]
            await model.load()

            XCTAssertEqual(model.groups.flatMap { $0.items.map(\.id) },
                           ["newest", "middle", "oldest"])
        }
    }

    // MARK: - Opening

    func testOpeningADraftFetchesItsContent() async {
        await withHistory { fake, model in
            fake.content = "# Writ Petition"
            await model.runOpen(item("d1"))

            XCTAssertEqual(fake.requestedIDs, ["d1"])
            XCTAssertEqual(model.opened?.content, "# Writ Petition")
            XCTAssertNil(model.errorMessage)
        }
    }

    /// An unknown or deleted id answers `{"success":true,"content":""}` — the route ternaries
    /// a missing row to an empty string. Rendering that as a blank page tells someone their
    /// draft is empty when it is actually gone.
    func testAnEmptyBodyIsReportedAsAMissingDraftNotAnEmptyOne() async {
        await withHistory { fake, model in
            fake.contentFailure = APIError.server(
                status: 404, message: "That draft could not be opened.")
            await model.runOpen(item("d1"))

            XCTAssertNil(model.opened, "nothing should be presented")
            XCTAssertEqual(model.errorMessage, "That draft could not be opened.")
        }
    }

    func testOnlyOneDraftOpensAtATime() async {
        await withHistory { fake, model in
            await model.runOpen(item("d1"))
            model.close()
            XCTAssertNil(model.opened)
        }
    }
}

/// The service's own empty-content rule, exercised through the HTTP layer rather than a fake,
/// because the whole point is what it does with a *successful* response.
final class DraftHistoryServiceTests: XCTestCase {

    /// Before each test, not only after. `tearDown` alone leaves the **first** test in the class
    /// reading whatever the previous suite left in `HTTPStub.seen`. See `HTTPStub.reset`.
    override func setUp() {
        super.setUp()
        HTTPStub.reset()
    }

    override func tearDown() {
        HTTPStub.reset()
        super.tearDown()
    }

    private func makeClient() async -> APIClient {
        let client = APIClient(
            config: APIConfig(baseURL: URL(string: "https://example.test/api")!),
            session: HTTPStub.session())
        await client.setCredentials(Credentials(token: "tok", userID: 7))
        return client
    }

    func testAnEmptyContentBodyBecomesAnError() async throws {
        let client = await makeClient()
        HTTPStub.always(.json(#"{"success":true,"content":""}"#))

        do {
            _ = try await DraftHistoryService(client: client).content(id: "doc_gone")
            XCTFail("an empty body means the row is gone, not that the draft is empty")
        } catch let error as APIError {
            guard case .server(let status, _) = error else { return XCTFail("wrong error") }
            XCTAssertEqual(status, 404)
        }
    }

    func testRealContentComesBackIntact() async throws {
        let client = await makeClient()
        HTTPStub.always(.json(##"{"success":true,"content":"# Writ\n\nBody"}"##))

        let content = try await DraftHistoryService(client: client).content(id: "doc_1")
        XCTAssertEqual(content, "# Writ\n\nBody")
    }

    /// Both routes answer under both keys; the list must survive either.
    func testAListUnderTheTablesKeyIsStillRead() async throws {
        let client = await makeClient()
        HTTPStub.always(.json(#"{"success":true,"tables":[{"id":"t1","title":"Comparison"}]}"#))

        let items = try await DraftHistoryService(client: client).drafts(.table)
        XCTAssertEqual(items.map(\.id), ["t1"])
    }
}
