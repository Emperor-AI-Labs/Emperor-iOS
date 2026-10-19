import XCTest
@testable import EmperorCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Teams share tracked court cases. The routes are small, but each answers its own way: the list
// comes back under `teams`, a new team's id is the only thing `POST /teams` says, and a refused
// invitation carries the server's own sentence ("No user with that email"), which is what the
// sheet shows.

private final class FakeTeams: TeamProviding, @unchecked Sendable {
    var list: [Team] = []
    var createError: Error?
    var inviteError: Error?
    private(set) var created: [String] = []
    private(set) var invited: [(teamID: String, email: String)] = []
    private(set) var loads = 0

    func teams() async throws -> [Team] {
        loads += 1
        return list
    }

    func createTeam(named name: String) async throws -> String {
        if let createError { throw createError }
        created.append(name)
        let team = Team(id: "team_new", name: name, role: "owner", memberCount: 1)
        list.append(team)
        return team.id
    }

    func addMember(teamID: String, email: String) async throws {
        if let inviteError { throw inviteError }
        invited.append((teamID, email))
    }
}

@MainActor
private func withTeams(_ body: @MainActor (FakeTeams, TeamsViewModel) async -> Void) async {
    let fake = FakeTeams()
    await body(fake, TeamsViewModel(service: fake))
}

final class TeamModelTests: XCTestCase {

    func testATeamDecodesWithNumbersWhereTextIsStored() throws {
        let json = #"{"success":true,"teams":[{"id":"team_1","name":"My Firm","owner_user_id":42,"role":"owner","member_count":"3"}]}"#
        let response = try JSONDecoder().decode(TeamListResponse.self, from: Data(json.utf8))
        let team = try XCTUnwrap(response.teams?.first)
        XCTAssertEqual(team.ownerUserID, "42")
        XCTAssertEqual(team.memberCount, 3)
        XCTAssertEqual(team.optionLabel, "My Firm · 3 members")
        XCTAssertTrue(team.isShared)
    }

    func testOnlyOwnersAndAdminsMayAddButAMissingRoleIsLetThrough() {
        XCTAssertTrue(Team(id: "a", role: "owner").canInvite)
        XCTAssertTrue(Team(id: "a", role: "admin").canInvite)
        XCTAssertFalse(Team(id: "a", role: "member").canInvite)
        XCTAssertTrue(Team(id: "a", role: nil).canInvite)
    }

    func testATeamOfOneIsLabelledByItsNameAlone() {
        XCTAssertEqual(Team(id: "a", name: "My Firm", memberCount: 1).optionLabel, "My Firm")
    }
}

final class TeamServiceWireTests: XCTestCase {

    private static let config = APIConfig(baseURL: URL(string: "https://example.test/api")!)

    override func setUp() {
        super.setUp()
        HTTPStub.reset()
    }

    override func tearDown() {
        HTTPStub.reset()
        super.tearDown()
    }

    private func makeService() async -> TeamService {
        let client = APIClient(config: Self.config, session: HTTPStub.session())
        await client.setCredentials(Credentials(token: "tok-abc", userID: 42))
        return TeamService(client: client)
    }

    func testTheListAsksWithTheCallerOnTheQueryString() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":true,"teams":[{"id":"team_1","name":"My Firm","role":"owner","member_count":1}]}"#))
        let teams = try await service.teams()
        XCTAssertEqual(teams.map(\.id), ["team_1"])
        let sent = try XCTUnwrap(HTTPStub.lastRequest)
        XCTAssertEqual(sent.httpMethod, "GET")
        XCTAssertEqual(sent.path, "/api/teams")
        XCTAssertEqual(sent.queryItems["userId"], "42")
    }

    func testCreatingSendsTheTrimmedNameAndReturnsTheId() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":true,"id":"team_9"}"#))
        let id = try await service.createTeam(named: "  Litigation Team ")
        XCTAssertEqual(id, "team_9")
        let sent = try XCTUnwrap(HTTPStub.lastRequest)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.path, "/api/teams")
        XCTAssertEqual(sent.bodyJSON["name"] as? String, "Litigation Team")
        XCTAssertEqual(sent.bodyJSON["userId"] as? String, "42")
    }

    func testABlankNameIsRefusedWithoutARequest() async {
        let service = await makeService()
        do {
            _ = try await service.createTeam(named: "   ")
            XCTFail("expected a refusal")
        } catch {}
        XCTAssertTrue(HTTPStub.seen.isEmpty)
    }

    func testAddingAMemberSendsTheTeamAndTheAddress() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":true}"#))
        try await service.addMember(teamID: "team_1", email: " asha@firm.in ")
        let sent = try XCTUnwrap(HTTPStub.lastRequest)
        XCTAssertEqual(sent.path, "/api/team-invite")
        XCTAssertEqual(sent.bodyJSON["teamId"] as? String, "team_1")
        XCTAssertEqual(sent.bodyJSON["email"] as? String, "asha@firm.in")
    }

    func testAnUnknownAddressCarriesTheServersWords() async {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":false,"error":"No user with that email"}"#, status: 404))
        do {
            try await service.addMember(teamID: "team_1", email: "nobody@x.in")
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(DisplayText.message(for: error), "No user with that email")
        }
    }
}

final class TeamsViewModelTests: XCTestCase {

    func testTheFirstInvitableTeamIsTheDefaultAndAMembersTeamIsNotOffered() async {
        await withTeams { fake, model in
            fake.list = [
                Team(id: "t_member", name: "Chambers", role: "member", memberCount: 4),
                Team(id: "t_own", name: "My Firm", role: "owner", memberCount: 1),
            ]
            await model.load()
            XCTAssertEqual(model.invitable.map(\.id), ["t_own"])
            XCTAssertEqual(model.inviteTeamID, "t_own")
            XCTAssertFalse(model.offersTeamPicker)
            XCTAssertEqual(model.inviteHeading, "Invite a member to “My Firm”")
        }
    }

    func testATeamJustMadeIsTheOneToFillAndTheWordingIsTheWebs() async {
        await withTeams { fake, model in
            fake.list = [Team(id: "t_own", name: "My Firm", role: "owner", memberCount: 1)]
            await model.load()
            model.newTeamName = " Litigation Team "
            await model.create()
            XCTAssertEqual(fake.created, ["Litigation Team"])
            XCTAssertEqual(model.message, "Team created.")
            XCTAssertEqual(model.toast, "Team created")
            XCTAssertEqual(model.newTeamName, "")
            XCTAssertEqual(model.inviteTeamID, "team_new")
            XCTAssertTrue(model.offersTeamPicker)
            XCTAssertEqual(model.inviteHeading, "Invite a member to")
        }
    }

    func testAFailedCreateSaysSoInTheWebsWords() async {
        await withTeams { fake, model in
            fake.createError = APIError.server(status: 500, message: "boom")
            model.newTeamName = "X"
            await model.create()
            XCTAssertEqual(model.message, "Could not create team.")
            XCTAssertEqual(model.toast, "Could not create team")
            XCTAssertFalse(model.messageIsSuccess)
        }
    }

    func testAddingAMemberClearsTheFieldAndReloadsTheCounts() async {
        await withTeams { fake, model in
            fake.list = [Team(id: "t_own", name: "My Firm", role: "owner", memberCount: 1)]
            await model.load()
            model.email = "asha@firm.in"
            await model.invite()
            XCTAssertEqual(fake.invited.first?.teamID, "t_own")
            XCTAssertEqual(model.message, "Member added.")
            XCTAssertEqual(model.toast, "Member added")
            XCTAssertEqual(model.email, "")
            XCTAssertEqual(fake.loads, 2)
        }
    }

    func testARefusedInvitationShowsTheServersSentence() async {
        await withTeams { fake, model in
            fake.list = [Team(id: "t_own", name: "My Firm", role: "owner", memberCount: 1)]
            await model.load()
            fake.inviteError = APIError.server(status: 404, message: "No user with that email")
            model.email = "nobody@x.in"
            await model.invite()
            XCTAssertEqual(model.message, "No user with that email")
            XCTAssertEqual(model.email, "nobody@x.in")
        }
    }

    func testNothingIsSentWithoutAnAddressOrATeam() async {
        await withTeams { fake, model in
            model.email = "asha@firm.in"
            XCTAssertFalse(model.canInvite)
            await model.invite()
            XCTAssertTrue(fake.invited.isEmpty)
        }
    }
}
