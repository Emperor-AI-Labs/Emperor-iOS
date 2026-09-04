import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The project operations a view model needs.
protocol ProjectProviding: Sendable {
    func projects(includeArchived: Bool) async throws -> [Project]
    func project(id: String) async throws -> ProjectDetail
}

/// One matter and everything hanging off it.
struct ProjectDetail: Equatable, Sendable {
    var project: Project
    var updates: [ProjectUpdate]
    /// The linked case's scraped hearing and order rows, merged in server-side. Empty when
    /// `Project.linkedCaseID` is unset — and also when the linked case has since been deleted
    /// by the sync that owns it, which the route swallows rather than 500s on
    /// (`sync-server.js:9973-9982`).
    var courtHistory: [CaseItem]

    /// The most recent update, which is what the list screen's "last activity" refers to. The
    /// server already sorted them, so this is the first rather than a fresh comparison.
    var latestUpdate: ProjectUpdate? { updates.first }
}

/// `GET /projects` and `GET /project` — hand-made matters.
///
/// ## Read-only, deliberately
///
/// The platform has `POST /project`, `POST /project-update`, `POST /project-file` and
/// `POST /project-chat`, and this client calls **none of them**. Projects are still being
/// trialled on the web — the row is routed but unlinked from its own sidebar — so the shape of a
/// matter, and of an update on one, is not yet settled. Writing rows against a schema that is
/// still moving would leave a user's own notes stranded in a shape the web later stops rendering,
/// and there is no migration story for hand-typed content.
///
/// Reading is safe on the same terms: an unmodelled column is simply not shown. So this ships as
/// a viewer for matters opened on the web, and the writes land when the web settles.
///
/// ## Ordering is the server's, not ours
///
/// The list arrives sorted by priority, then next hearing, then last update
/// (`sync-server.js:9926-9929`). It is not re-sorted here. Re-deciding it would put the phone and
/// the browser in disagreement about which matter is most urgent, which is the one thing a
/// priority field exists to settle — and it is the opposite call from `CaseListViewModel`, which
/// *does* re-sort because `/cases` orders by `updated_at DESC` and adding a note there moves a
/// matter to the top of the docket.
///
/// ## Archived is excluded unless asked for
///
/// `includeArchived=1` is the route's own opt-in, and the exclusion happens in the `WHERE`
/// clause. The default matches the web, and an archived matter appearing on a phone but not in a
/// browser would read as a sync fault.
struct ProjectService: ProjectProviding {
    let client: APIClient

    /// Every matter this user owns.
    ///
    /// - Parameter includeArchived: whether to ask for archived matters too. This is a
    ///   **different request**, not a filter over what is already held: the rows simply are not
    ///   in hand otherwise, so filtering locally would show an empty archive to someone who has
    ///   one.
    func projects(includeArchived: Bool = false) async throws -> [Project] {
        // Sent only when true. The route tests `=== '1'`, so `includeArchived=0` is read as
        // false anyway — but omitting it keeps the request identical to the web's.
        let query = includeArchived ? ["includeArchived": "1"] : [:]

        let response = try await withRetry {
            let request = try await client.makeRequest("GET", "/projects", query: query)
            return try await client.send(request, as: ProjectListResponse.self)
        }
        try CaseService.throwIfUnsuccessful(success: response.success, error: response.error)
        return response.projects ?? []
    }

    /// One matter, its own timeline, and the linked case's court record.
    ///
    /// - Important: a missing matter and someone else's matter are the **same answer**. The
    ///   query is `WHERE id = ? AND user_id = ?` (`sync-server.js:9949`) and both fall into the
    ///   one 404, so they are indistinguishable from here by design. The wording covers both
    ///   honestly rather than guessing which — and it is rewritten at this layer rather than in
    ///   the view model so it reaches the screen through `LoadFailure` like every other message.
    ///
    ///   The server's own word is the bare string `"Project not found"`, which read on its own
    ///   says nothing about what to do next.
    func project(id: String) async throws -> ProjectDetail {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw APIError.server(status: 404, message: Self.projectGoneMessage)
        }

        do {
            let response = try await withRetry {
                let request = try await client.makeRequest(
                    "GET", "/project", query: ["id": trimmed])
                return try await client.send(request, as: ProjectDetailResponse.self)
            }
            try CaseService.throwIfUnsuccessful(success: response.success, error: response.error)
            guard let project = response.project else {
                throw APIError.server(status: 404, message: Self.projectGoneMessage)
            }
            // Filtered here rather than in the view, so a section header's count and the number
            // of rows beneath it cannot disagree.
            return ProjectDetail(
                project: project,
                updates: (response.updates ?? []).filter(\.isRenderable),
                courtHistory: (response.courtHistory ?? []).filter(\.isRenderable))
        } catch let error as APIError {
            throw Self.rewriting(error, status: 404, as: Self.projectGoneMessage)
        }
    }

    static let projectGoneMessage =
        "This matter no longer exists, or belongs to another account."

    /// Replaces the server's terse refusal on one status with wording a reader can act on,
    /// leaving every other failure exactly as it was. The twin of `AuctionService.rewriting`.
    private static func rewriting(
        _ error: APIError, status: Int, as message: String
    ) -> APIError {
        guard case .server(let received, _) = error, received == status else { return error }
        return .server(status: status, message: message)
    }
}
