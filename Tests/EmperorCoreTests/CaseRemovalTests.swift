import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import EmperorCore

// MARK: - The wire

/// `DELETE /case?id=&userId=`: what goes out, and how each answer reads.
final class CaseRemovalWireTests: XCTestCase {

    private static let config = APIConfig(baseURL: URL(string: "https://example.test/api")!)

    override func setUp() {
        super.setUp()
        HTTPStub.reset()
    }

    override func tearDown() {
        HTTPStub.reset()
        super.tearDown()
    }

    private func makeService() async -> CaseService {
        let client = APIClient(config: Self.config, session: HTTPStub.session())
        await client.setCredentials(Credentials(token: "tok-abc", userID: 42))
        return CaseService(client: client)
    }

    func testARemovalIsADeleteCarryingTheCaseAndTheCaller() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":true}"#))

        try await service.removeCase(id: "case_17")

        let sent = try XCTUnwrap(HTTPStub.lastRequest)
        XCTAssertEqual(sent.httpMethod, "DELETE")
        XCTAssertEqual(sent.path, "/api/case")
        XCTAssertEqual(sent.queryItems["id"], "case_17")
        XCTAssertEqual(sent.queryItems["userId"], "42")
        XCTAssertEqual(sent.header("Authorization"), "Bearer tok-abc")
        XCTAssertNil(sent.httpBody)
    }

    func testATeamCaseIsWordedHere() async {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":false,"error":"Only team owners/admins can remove cases"}"#, status: 403))
        do {
            try await service.removeCase(id: "case_17")
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? APIError, .server(status: 403, message: CaseRemovalCopy.teamCase))
            XCTAssertFalse(DisplayText.message(for: error).contains("owners/admins"))
        }
    }

    func testA200ThatDidNotRemoveIsNotRemoved() async {
        let service = await makeService()
        for (status, body) in [(200, #"{"success":false}"#), (200, "not json"), (500, #"{"error":"SQLITE_BUSY"}"#), (400, #"{"success":false,"error":"Missing required parameter: id or userId"}"#)] {
            HTTPStub.always(.json(body, status: status))
            do {
                try await service.removeCase(id: "case_17")
                XCTFail("expected a failure for \(status) \(body)")
            } catch {
                XCTAssertEqual(DisplayText.message(for: error), CaseRemovalCopy.notRemoved, "\(status) \(body)")
            }
        }
    }
}

// MARK: - The screens

private final class FakeRemover: CaseRemoving, @unchecked Sendable {
    var error: Error?
    /// Called on a removal, so a test can change what the docket reads next.
    var onRemove: (String) -> Void = { _ in }
    private(set) var removed: [String] = []

    func removeCase(id: String) async throws {
        if let error { throw error }
        removed.append(id)
        onRemove(id)
    }
}

private func trackedCase(_ id: String) -> LegalCase {
    LegalCase(
        id: id, teamID: "team_1", cnr: nil, courtType: "hc", courtCode: nil,
        caseNumber: "1234", caseYear: "2024", title: "Menon vs. Union of India", parties: nil,
        status: "Pending", stage: nil, nextHearingDateRaw: nil,
        filingDateRaw: nil, judge: nil, courtName: "Delhi High Court",
        caseType: "W.P.(C)", diaryNumber: nil, category: nil,
        lastSyncedAtRaw: nil, createdAtRaw: nil, updatedAtRaw: nil,
        teamName: "My Firm")
}

final class CaseRemovalViewModelTests: XCTestCase {

    @MainActor
    private static func detailModel(
        cases: FakeCases, remover: FakeRemover?, offline: OfflineStore? = nil
    ) -> CaseDetailViewModel {
        CaseDetailViewModel(caseID: "case_1", service: cases, offline: offline, remover: remover)
    }

    func testTheCasePageRemovesItAndForgetsTheKeptCopy() async {
        let cases = FakeCases()
        cases.detail = CaseDetail(legalCase: trackedCase("case_1"), events: [], items: [])
        let remover = FakeRemover()
        let offline = OfflineStore(namespace: "a1.matters", budget: 1_000_000, store: InMemoryCacheStore())
        await runOnMain {
            let model = Self.detailModel(cases: cases, remover: remover, offline: offline)
            XCTAssertFalse(model.canRemove, "offered before the case was read")
            await model.load()
            XCTAssertTrue(offline.contains("case_1"))
            XCTAssertTrue(model.canRemove)

            let removed = await model.remove()

            XCTAssertTrue(removed)
            XCTAssertEqual(remover.removed, ["case_1"])
            XCTAssertFalse(offline.contains("case_1"), "the kept copy outlived the case")
            XCTAssertNil(model.removeError)
        }
    }

    func testARefusedRemovalSaysWhyAndKeepsTheCase() async {
        let cases = FakeCases()
        cases.detail = CaseDetail(legalCase: trackedCase("case_1"), events: [], items: [])
        let remover = FakeRemover()
        remover.error = APIError.server(status: 403, message: CaseRemovalCopy.teamCase)
        await runOnMain {
            let model = Self.detailModel(cases: cases, remover: remover)
            await model.load()
            let removed = await model.remove()
            XCTAssertFalse(removed)
            XCTAssertEqual(model.removeError, CaseRemovalCopy.teamCase)
            XCTAssertNotNil(model.detail)
        }
    }

    func testWithoutTheRouteNothingIsOffered() async {
        let cases = FakeCases()
        cases.detail = CaseDetail(legalCase: trackedCase("case_1"), events: [], items: [])
        await runOnMain {
            let model = Self.detailModel(cases: cases, remover: nil)
            await model.load()
            XCTAssertFalse(model.canRemove)
            let removed = await model.remove()
            XCTAssertFalse(removed)
        }
    }

    /// The docket is read again rather than the row dropped by hand.
    func testTheDocketIsReadAgainAfterARemoval() async {
        let cases = FakeCases()
        cases.cases = [trackedCase("case_1"), trackedCase("case_2")]
        let remover = FakeRemover()
        remover.onRemove = { id in cases.cases.removeAll { $0.id == id } }
        await runOnMain {
            let model = CaseListViewModel(service: cases, remover: remover)
            await model.load()
            XCTAssertTrue(model.canRemove)

            let removed = await model.removeCase(id: "case_1")

            XCTAssertTrue(removed)
            XCTAssertEqual(model.cases.map(\.id), ["case_2"])
            XCTAssertNil(model.removingID)
        }
    }

    func testAFailedRemovalLeavesTheDocketAsItWas() async {
        let cases = FakeCases()
        cases.cases = [trackedCase("case_1")]
        let remover = FakeRemover()
        remover.error = APIError.server(status: 403, message: CaseRemovalCopy.teamCase)
        await runOnMain {
            let model = CaseListViewModel(service: cases, remover: remover)
            await model.load()
            let removed = await model.removeCase(id: "case_1")
            XCTAssertFalse(removed)
            XCTAssertEqual(model.removeError, CaseRemovalCopy.teamCase)
            XCTAssertEqual(model.cases.map(\.id), ["case_1"])
            XCTAssertFalse(CaseListViewModel(service: cases).canRemove, "offered with no route")
        }
    }
}

@MainActor
private func runOnMain(_ body: @MainActor () async -> Void) async {
    await body()
}
