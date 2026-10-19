import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Observation
#endif

// Teams: who shares tracked court cases. A tracked case belongs to a team (`cases.team_id`), and
// every member of that team sees it under Matters and hears about its new hearings. Every account
// has a team of its own — the server makes it on first ask — which is where a case tracked from
// New matter goes. The web's Matters page carries a "Team" button for this; so does the Matters
// tab here.

/// A team the caller belongs to, as `GET /teams` lists it.
struct Team: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var name: String?
    var ownerUserID: String?
    /// The caller's role in it: `owner`, `admin` or `member`. Absent from a server that does not
    /// send one.
    var role: String?
    var memberCount: Int?

    var displayName: String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Untitled team" : trimmed
    }

    /// Only owners and admins may add members. A row with no role is let through and the server
    /// decides, as the web does.
    var canInvite: Bool {
        guard let role = role?.lowercased(), !role.isEmpty else { return true }
        return role == "owner" || role == "admin"
    }

    /// Shared with someone else — the only case in which naming the team on a row says anything.
    var isShared: Bool { (memberCount ?? 0) > 1 }

    /// The picker's wording: "Litigation · 3 members", or the bare name for a team of one.
    var optionLabel: String {
        guard let memberCount, memberCount > 1 else { return displayName }
        return "\(displayName) · \(memberCount) members"
    }

    enum CodingKeys: String, CodingKey {
        case id, name, role
        case ownerUserID = "owner_user_id"
        case memberCount = "member_count"
    }

    init(id: String, name: String? = nil, ownerUserID: String? = nil, role: String? = nil, memberCount: Int? = nil) {
        self.id = id
        self.name = name
        self.ownerUserID = ownerUserID
        self.role = role
        self.memberCount = memberCount
    }

    /// `owner_user_id` is TEXT written from a number, and `member_count` is a SQLite `COUNT(*)`;
    /// either may arrive as the other type.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeFlexibleString(forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name)
        ownerUserID = try c.decodeFlexibleString(forKey: .ownerUserID)
        role = try c.decodeIfPresent(String.self, forKey: .role)
        if let count = try? c.decodeIfPresent(Int.self, forKey: .memberCount) {
            memberCount = count
        } else {
            memberCount = (try c.decodeFlexibleString(forKey: .memberCount)).flatMap { Int($0) }
        }
    }
}

struct TeamListResponse: Codable, Sendable {
    var success: Bool?
    var teams: [Team]?
    var error: String?
}

struct TeamCreateResponse: Codable, Sendable {
    var success: Bool?
    var id: String?
    var error: String?

    enum CodingKeys: String, CodingKey { case success, id, error }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        success = try c.decodeIfPresent(Bool.self, forKey: .success)
        id = try c.decodeFlexibleString(forKey: .id)
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }
}

/// The team operations the Teams sheet needs.
protocol TeamProviding: Sendable {
    func teams() async throws -> [Team]
    /// A new team with the caller as its owner. Returns its id.
    func createTeam(named name: String) async throws -> String
    /// Adds an existing account to a team, by its email address.
    func addMember(teamID: String, email: String) async throws
}

/// `GET /teams`, `POST /teams` and `POST /team-invite`.
///
/// There is no route that lists a team's members or removes one, and the web offers neither; the
/// list carries each team's member count instead.
struct TeamService: TeamProviding {
    let client: APIClient

    func teams() async throws -> [Team] {
        let response = try await withRetry {
            let request = try await client.makeRequest("GET", "/teams")
            return try await client.send(request, as: TeamListResponse.self)
        }
        try CaseService.throwIfUnsuccessful(success: response.success, error: response.error)
        return (response.teams ?? []).filter { !$0.id.isEmpty }
    }

    func createTeam(named name: String) async throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw APIError.server(status: 400, message: "Give the team a name.")
        }
        let body = try await signed(["name": .string(trimmed)])
        let request = try await client.makeRequest("POST", "/teams", body: body)
        let response = try await client.send(request, as: TeamCreateResponse.self)
        try CaseService.throwIfUnsuccessful(success: response.success, error: response.error)
        guard let id = response.id, !id.isEmpty else {
            throw APIError.server(status: 500, message: "The server did not return the new team.")
        }
        return id
    }

    /// The address is trimmed; the server compares it lower-cased. A 404 means no account has that
    /// address, and its own words say so.
    func addMember(teamID: String, email: String) async throws {
        let body = try await signed([
            "teamId": .string(teamID),
            "email": .string(email.trimmingCharacters(in: .whitespacesAndNewlines)),
        ])
        let request = try await client.makeRequest("POST", "/team-invite", body: body)
        let response = try await client.send(request, as: WriteResponse.self)
        try CaseService.throwIfUnsuccessful(success: response.success, error: response.error)
    }

    private func signed(_ fields: [String: JSONValue]) async throws -> [String: JSONValue] {
        guard let credentials = await client.currentCredentials() else {
            throw APIError.notAuthenticated
        }
        var body = fields
        body["userId"] = .string(credentials.userIDString)
        return body
    }
}

/// The Teams sheet: make a team, and add someone to one — the web's Team dialog.
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class TeamsViewModel {

    enum Copy {
        static let title = "Teams"
        static let createHeading = "Create a new team"
        static let createPlaceholder = "e.g. Litigation Team"
        static let emailPlaceholder = "teammate@email.com"
        static let footnote =
            "The person must already have an Emperor AI account. They will see this team’s tracked cases under Matters."
        static let teamCreated = "Team created."
        static let teamNotCreated = "Could not create team."
        static let memberAdded = "Member added."
        static let memberNotAdded = "Could not add member."
    }

    private(set) var teams: [Team] = []
    private(set) var state: LoadState = .idle
    private(set) var isWorking = false

    var newTeamName = ""
    var email = ""
    /// The team chosen to add to; `nil` is the default below.
    var pickedTeamID: String?
    /// The last outcome, said under the form.
    private(set) var message: String?
    /// Whether that outcome was a success, for its tint.
    private(set) var messageIsSuccess = false
    /// A short word for a toast — the web's toast text, without the full stop.
    private(set) var toast: String?

    private let service: any TeamProviding

    init(service: any TeamProviding) {
        self.service = service
    }

    /// Only the teams the caller may add to.
    var invitable: [Team] { teams.filter(\.canInvite) }

    /// What was picked, else the first invitable team — the user's own firm.
    var inviteTeamID: String? {
        [pickedTeamID, invitable.first?.id]
            .compactMap { $0 }
            .first { id in invitable.contains { $0.id == id } }
    }

    var inviteTeam: Team? { invitable.first { $0.id == inviteTeamID } }

    /// A picker only when there is a choice to make.
    var offersTeamPicker: Bool { invitable.count > 1 }

    var inviteHeading: String {
        if offersTeamPicker { return "Invite a member to" }
        guard let team = inviteTeam else { return "Invite a member" }
        return "Invite a member to “\(team.displayName)”"
    }

    var canCreate: Bool { !isWorking && !newTeamName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var canInvite: Bool {
        !isWorking && inviteTeamID != nil && !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func load() async {
        state = .loading
        do {
            teams = try await service.teams()
            state = .loaded
        } catch {
            state = .failed(LoadFailure(error))
        }
    }

    func create() async {
        let name = newTeamName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let id = try await service.createTeam(named: name)
            say(Copy.teamCreated, success: true)
            newTeamName = ""
            // A team just made is the one about to be filled.
            pickedTeamID = id
            await load()
        } catch {
            say(Copy.teamNotCreated, success: false)
        }
    }

    func invite() async {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, let teamID = inviteTeamID, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await service.addMember(teamID: teamID, email: address)
            say(Copy.memberAdded, success: true)
            email = ""
            await load()
        } catch {
            // The server's own words when it gave any — "No user with that email".
            let text = Self.serverWords(error)
            say(text ?? Copy.memberNotAdded, success: false, toastText: text ?? "Could not add member")
        }
    }

    func clearToast() { toast = nil }

    private func say(_ text: String, success: Bool, toastText: String? = nil) {
        message = text
        messageIsSuccess = success
        toast = toastText ?? (text.hasSuffix(".") ? String(text.dropLast()) : text)
    }

    private static func serverWords(_ error: Error) -> String? {
        if case APIError.server(_, let message) = error, !message.isEmpty,
           !message.hasPrefix("The server returned status") {
            return message
        }
        return nil
    }
}
