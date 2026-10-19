import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The matter operations a view model needs.
///
/// The two reads are what every stand-in has to implement. The writes have default
/// implementations that refuse — a stand-in written for the read-only screens keeps compiling,
/// and a view model that reaches a write through such a stand-in sees a plain refusal rather
/// than a crash. `ProjectService` implements every one.
protocol ProjectProviding: Sendable {
    func projects(includeArchived: Bool) async throws -> [Project]
    func project(id: String) async throws -> ProjectDetail

    // MARK: Matters (docs/projects.md)

    /// The caller's matter for a tracked case — made on the spot when there is none.
    func projectFromCase(caseID: String) async throws -> (project: Project, existed: Bool)
    /// The same, with what New matter chose: the name (blank lets the server name it after the
    /// cause title), the banner and the folder colour. Used only when the matter is made.
    func projectFromCase(caseID: String, seed: MatterSeed) async throws -> (project: Project, existed: Bool)
    func create(_ draft: MatterDraft) async throws -> Project
    /// `POST /project` with the matter's `id`: the Edit details form. Only the fields present
    /// change — see `MatterEditDraft.fields(comparedWith:)`.
    func update(projectID: String, fields: [String: JSONValue]) async throws -> Project
    /// A partial update: only the fields named change.
    func patch(projectID: String, fields: [String: JSONValue]) async throws -> Project

    func saveTask(projectID: String, id: String?, draft: TaskDraft) async throws -> ProjectTask
    func deleteTask(id: String) async throws
    func saveLedgerEntry(projectID: String, id: String?, draft: LedgerDraft) async throws -> LedgerEntry
    func deleteLedgerEntry(id: String) async throws
    func savePerson(projectID: String, id: String?, draft: PersonDraft) async throws -> ProjectPerson
    func deletePerson(id: String) async throws
    func saveUpdate(projectID: String, id: String?, draft: UpdateDraft) async throws -> String
    func deleteUpdate(id: String) async throws

    /// The matter's own storage tree, in `/user-files`' item shape.
    func projectFiles(projectID: String) async throws -> [FileNode]
    /// Copies finished My Files documents into the matter. Never an upload.
    func attach(projectID: String, files: [ChatAttachment], subfolder: String?) async throws -> [AttachedFile]

    func linkCase(projectID: String, caseID: String?) async throws -> Project
    /// Asks the court again for the linked case. At most once in five minutes per case.
    func refreshLinkedCase(projectID: String) async throws

    // MARK: The workspace's AI, conversations, banner and deletion

    /// Puts a conversation into the matter (or, with `attached: false`, takes it out).
    func attachChat(projectID: String, chatID: String, attached: Bool) async throws
    /// Reads the matter's documents — all of them, or `files` — and proposes dated events.
    /// Proposals only: nothing is saved.
    func extractChronology(projectID: String, files: [ChatAttachment]?) async throws -> ChronologyExtraction
    /// The uploaded banner picture, or `nil` when the matter has none.
    func bannerImage(projectID: String) async throws -> Data?
    /// Stores a banner picture, given as a data URL (`BannerImage.dataURL`).
    func uploadBanner(projectID: String, dataURL: String) async throws
    /// Removes the banner picture; the matter falls back to its preset.
    func deleteBanner(projectID: String) async throws
    /// Deletes the matter and everything in it. `confirm` must be its exact name.
    func deleteProject(id: String, confirm: String) async throws
}

extension ProjectProviding {
    private var notOffered: APIError {
        .server(status: 501, message: "This action is not available here.")
    }
    func projectFromCase(caseID: String) async throws -> (project: Project, existed: Bool) { throw notOffered }
    func create(_ draft: MatterDraft) async throws -> Project { throw notOffered }
    func update(projectID: String, fields: [String: JSONValue]) async throws -> Project { throw notOffered }
    /// A stand-in that knows only the plain form is asked that, and the seed is dropped.
    func projectFromCase(caseID: String, seed: MatterSeed) async throws -> (project: Project, existed: Bool) {
        try await projectFromCase(caseID: caseID)
    }
    func patch(projectID: String, fields: [String: JSONValue]) async throws -> Project { throw notOffered }
    func saveTask(projectID: String, id: String?, draft: TaskDraft) async throws -> ProjectTask { throw notOffered }
    func deleteTask(id: String) async throws { throw notOffered }
    func saveLedgerEntry(projectID: String, id: String?, draft: LedgerDraft) async throws -> LedgerEntry { throw notOffered }
    func deleteLedgerEntry(id: String) async throws { throw notOffered }
    func savePerson(projectID: String, id: String?, draft: PersonDraft) async throws -> ProjectPerson { throw notOffered }
    func deletePerson(id: String) async throws { throw notOffered }
    func saveUpdate(projectID: String, id: String?, draft: UpdateDraft) async throws -> String { throw notOffered }
    func deleteUpdate(id: String) async throws { throw notOffered }
    func projectFiles(projectID: String) async throws -> [FileNode] { throw notOffered }
    func attach(projectID: String, files: [ChatAttachment], subfolder: String?) async throws -> [AttachedFile] { throw notOffered }
    func linkCase(projectID: String, caseID: String?) async throws -> Project { throw notOffered }
    func refreshLinkedCase(projectID: String) async throws { throw notOffered }
    func attachChat(projectID: String, chatID: String, attached: Bool) async throws { throw notOffered }
    func extractChronology(projectID: String, files: [ChatAttachment]?) async throws -> ChronologyExtraction { throw notOffered }
    func bannerImage(projectID: String) async throws -> Data? { throw notOffered }
    func uploadBanner(projectID: String, dataURL: String) async throws { throw notOffered }
    func deleteBanner(projectID: String) async throws { throw notOffered }
    func deleteProject(id: String, confirm: String) async throws { throw notOffered }
}

/// One matter and everything hanging off it.
struct ProjectDetail: Equatable, Sendable {
    var project: Project
    var updates: [ProjectUpdate]
    /// The linked case's scraped hearing and order rows, merged in server-side. Empty when
    /// `Project.linkedCaseID` is unset — and also when the linked case has since been deleted
    /// by the sync that owns it, which the route swallows rather than 500s on.
    var courtHistory: [CaseItem]
    var linkedCase: LinkedCaseSummary?
    var tasks: [ProjectTask]
    var ledger: [LedgerEntry]
    var people: [ProjectPerson]
    var totals: LedgerTotals
    /// The matter's own conversations, as the server lists them.
    var chats: [ProjectChatRow]

    init(
        project: Project, updates: [ProjectUpdate], courtHistory: [CaseItem],
        linkedCase: LinkedCaseSummary? = nil, tasks: [ProjectTask] = [],
        ledger: [LedgerEntry] = [], people: [ProjectPerson] = [], totals: LedgerTotals = .zero,
        chats: [ProjectChatRow] = []
    ) {
        self.project = project
        self.updates = updates
        self.courtHistory = courtHistory
        self.linkedCase = linkedCase
        self.tasks = tasks
        self.ledger = ledger
        self.people = people
        self.totals = totals
        self.chats = chats
    }

    /// The most recent update, which is what the list screen's "last activity" refers to. The
    /// server already sorted them, so this is the first rather than a fresh comparison.
    var latestUpdate: ProjectUpdate? { updates.first }
}

/// The matter routes (docs/projects.md): `GET /projects`, `GET /project`, and the writes the
/// Matters workspace is made of.
///
/// ## Ordering and filtering are the list's, as on the web
///
/// The route sorts by priority, then next hearing, then last update. The web's Matters page then
/// re-orders the whole list by its own Sort menu (recent activity by default) and filters it by
/// status locally, and `ProjectListViewModel` does the same — see `MatterListing`.
///
/// ## Archived is excluded unless asked for
///
/// `includeArchived=1` is the route's own opt-in, and the exclusion happens in the `WHERE`
/// clause. The Matters list always asks for them: a tracked case is listed only while no matter
/// links it, and an archived matter still links its case — without the archived ones, every case
/// whose matter was archived would come back as a "tracked case".
///
/// ## Writes send only what changed
///
/// Every save route creates without an `id` and edits with one, and on an edit changes only the
/// fields present in the body. So a draft's `nil` is **omitted**, never sent as `null` — sent,
/// it would clear the stored value.
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
    /// - Important: a missing matter and someone else's matter are the **same answer**: both are
    ///   the one 404, so they are indistinguishable from here by design. The wording covers both
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
                courtHistory: (response.courtHistory ?? []).filter(\.isRenderable),
                linkedCase: response.linkedCase,
                tasks: response.tasks ?? [],
                ledger: response.ledger ?? [],
                people: response.people ?? [],
                totals: response.totals ?? .zero,
                chats: (response.chats ?? []).filter { !$0.id.isEmpty })
        } catch let error as APIError {
            throw Self.rewriting(error, status: 404, as: Self.projectGoneMessage)
        }
    }

    static let projectGoneMessage =
        "This matter no longer exists, or belongs to another account."

    // MARK: - A matter from a case

    /// `POST /project-from-case`: idempotent per user and case, so opening a tracked case's
    /// matter twice gives the same matter. A 403 means the caller is not on the case's team.
    func projectFromCase(caseID: String) async throws -> (project: Project, existed: Bool) {
        try await projectFromCase(caseID: caseID, seed: MatterSeed())
    }

    func projectFromCase(caseID: String, seed: MatterSeed) async throws -> (project: Project, existed: Bool) {
        var fields: [String: JSONValue] = ["caseId": .string(caseID)]
        put(&fields, "name", seed.name)
        put(&fields, "banner", seed.banner)
        put(&fields, "color", seed.color)
        let body = try await signed(fields)
        let request = try await client.makeRequest("POST", "/project-from-case", body: body)
        let response = try await client.send(request, as: ProjectFromCaseResponse.self)
        try CaseService.throwIfUnsuccessful(success: response.success, error: response.error)
        guard let project = response.project else {
            throw APIError.server(status: 500, message: "The matter could not be opened.")
        }
        return (project, response.existed ?? false)
    }

    /// `POST /project` with no `id`: a new matter with its five standard folders.
    func create(_ draft: MatterDraft) async throws -> Project {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw APIError.server(status: 400, message: "Give the matter a name.")
        }
        var fields: [String: JSONValue] = ["name": .string(name)]
        put(&fields, "client", draft.client)
        put(&fields, "practiceArea", draft.practiceArea)
        put(&fields, "ourSide", draft.ourSide)
        put(&fields, "oppositeParty", draft.oppositeParty)
        put(&fields, "color", draft.color)
        put(&fields, "banner", draft.banner)
        put(&fields, "courtStatus", draft.courtStatus)
        let request = try await client.makeRequest("POST", "/project", body: try await signed(fields))
        return try await unwrapProject(try await client.send(request, as: ProjectWriteResponse.self))
    }

    /// `POST /project` with `id`: the Edit details form's save. `fields` are the web's camelCase
    /// keys; the route changes only those present, and reads a `null` or a blank as "clear it".
    func update(projectID: String, fields: [String: JSONValue]) async throws -> Project {
        var body = fields
        body["id"] = .string(projectID)
        if let name = body["name"], case .string(let text) = name,
           text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw APIError.server(status: 400, message: "Give the matter a name.")
        }
        let request = try await client.makeRequest("POST", "/project", body: try await signed(body))
        return try await unwrapProject(try await client.send(request, as: ProjectWriteResponse.self))
    }

    /// `POST /project-patch`: `fields` in the web's camelCase, a subset of the project fields.
    func patch(projectID: String, fields: [String: JSONValue]) async throws -> Project {
        let body = try await signed(["projectId": .string(projectID), "fields": .object(fields)])
        let request = try await client.makeRequest("POST", "/project-patch", body: body)
        return try await unwrapProject(try await client.send(request, as: ProjectWriteResponse.self))
    }

    // MARK: - Tasks, money, people, chronology

    func saveTask(projectID: String, id: String?, draft: TaskDraft) async throws -> ProjectTask {
        var fields: [String: JSONValue] = ["projectId": .string(projectID), "title": .string(draft.title)]
        put(&fields, "id", id)
        put(&fields, "notes", draft.notes)
        put(&fields, "dueDate", draft.dueDate)
        put(&fields, "kind", draft.kind)
        put(&fields, "priority", draft.priority)
        put(&fields, "status", draft.status)
        let request = try await client.makeRequest("POST", "/project-task", body: try await signed(fields))
        let response = try await client.send(request, as: ProjectTaskResponse.self)
        try CaseService.throwIfUnsuccessful(success: response.success, error: response.error)
        guard let task = response.task else { throw Self.noRow("task") }
        return task
    }

    func deleteTask(id: String) async throws { try await delete("/project-task", id: id) }

    func saveLedgerEntry(projectID: String, id: String?, draft: LedgerDraft) async throws -> LedgerEntry {
        var fields: [String: JSONValue] = [
            "projectId": .string(projectID),
            "kind": .string(draft.kind.rawValue),
            // Rupees as a number; the server stores paise.
            "amount": .number(draft.amount),
        ]
        put(&fields, "id", id)
        put(&fields, "title", draft.title)
        put(&fields, "entryDate", draft.entryDate)
        put(&fields, "mode", draft.mode)
        put(&fields, "reference", draft.reference)
        put(&fields, "category", draft.category)
        put(&fields, "notes", draft.notes)
        let request = try await client.makeRequest("POST", "/project-ledger", body: try await signed(fields))
        let response = try await client.send(request, as: ProjectLedgerResponse.self)
        try CaseService.throwIfUnsuccessful(success: response.success, error: response.error)
        guard let entry = response.entry else { throw Self.noRow("entry") }
        return entry
    }

    func deleteLedgerEntry(id: String) async throws { try await delete("/project-ledger", id: id) }

    func savePerson(projectID: String, id: String?, draft: PersonDraft) async throws -> ProjectPerson {
        var fields: [String: JSONValue] = [
            "projectId": .string(projectID), "role": .string(draft.role), "name": .string(draft.name),
        ]
        put(&fields, "id", id)
        put(&fields, "phone", draft.phone)
        put(&fields, "email", draft.email)
        put(&fields, "address", draft.address)
        put(&fields, "notes", draft.notes)
        let request = try await client.makeRequest("POST", "/project-person", body: try await signed(fields))
        let response = try await client.send(request, as: ProjectPersonResponse.self)
        try CaseService.throwIfUnsuccessful(success: response.success, error: response.error)
        guard let person = response.person else { throw Self.noRow("person") }
        return person
    }

    func deletePerson(id: String) async throws { try await delete("/project-person", id: id) }

    /// `POST /project-update`. `source` is the draft's — `manual` unless it says otherwise, and
    /// `ai` for an extracted event the user accepted, with the page it was read from in
    /// `sourceRef`. Returns the entry's id.
    func saveUpdate(projectID: String, id: String?, draft: UpdateDraft) async throws -> String {
        let source = draft.source?.trimmingCharacters(in: .whitespacesAndNewlines)
        var fields: [String: JSONValue] = [
            "projectId": .string(projectID), "kind": .string(draft.kind),
            "title": .string(draft.title),
            "source": .string((source?.isEmpty ?? true) ? "manual" : source!),
        ]
        put(&fields, "id", id)
        put(&fields, "body", draft.body)
        put(&fields, "eventDate", draft.eventDate)
        put(&fields, "sourceRef", draft.sourceRef)
        let request = try await client.makeRequest("POST", "/project-update", body: try await signed(fields))
        let response = try await client.send(request, as: ProjectUpdateWriteResponse.self)
        try CaseService.throwIfUnsuccessful(success: response.success, error: response.error)
        return response.id ?? id ?? ""
    }

    func deleteUpdate(id: String) async throws { try await delete("/project-update", id: id) }

    // MARK: - Files

    /// `GET /project-files`: the matter's folders (with their files) and its loose files, as one
    /// tree so `FileService.allFiles` and the folder views read it unchanged.
    func projectFiles(projectID: String) async throws -> [FileNode] {
        let response = try await withRetry {
            let request = try await client.makeRequest(
                "GET", "/project-files", query: ["projectId": projectID])
            return try await client.send(request, as: ProjectFilesResponse.self)
        }
        try CaseService.throwIfUnsuccessful(success: response.success, error: response.error)
        return (response.folders ?? []) + (response.files ?? [])
    }

    /// `POST /project-attach`: at most 25 documents, each named as `/user-files` names it. A
    /// loose file at the root of My Files is sent with `folderName: "."`, the way `/view-file`
    /// spells the root.
    func attach(projectID: String, files: [ChatAttachment], subfolder: String?) async throws -> [AttachedFile] {
        guard !files.isEmpty else { return [] }
        guard files.count <= Self.attachLimit else {
            throw APIError.server(
                status: 400,
                message: "Attach up to \(Self.attachLimit) documents at a time.")
        }
        var fields: [String: JSONValue] = [
            "projectId": .string(projectID),
            "files": .array(files.map { file in
                .object([
                    "folderName": .string((file.folderName?.isEmpty ?? true) ? "." : file.folderName!),
                    "fileName": .string(file.name),
                ])
            }),
        ]
        put(&fields, "subfolder", subfolder)
        var request = try await client.makeRequest("POST", "/project-attach", body: try await signed(fields))
        // The route copies the bytes and their page rows before it answers.
        request.timeoutInterval = 120
        let response = try await client.send(request, as: ProjectAttachResponse.self)
        try CaseService.throwIfUnsuccessful(success: response.success, error: response.error)
        return response.files ?? []
    }

    static let attachLimit = 25

    // MARK: - The court case

    func linkCase(projectID: String, caseID: String?) async throws -> Project {
        let body = try await signed([
            "projectId": .string(projectID),
            "caseId": caseID.map { .string($0) } ?? .null,
        ])
        let request = try await client.makeRequest("POST", "/project-link-case", body: body)
        return try await unwrapProject(try await client.send(request, as: ProjectWriteResponse.self))
    }

    /// A 429 carries `retryAfter` in seconds; it is worded here, because "Too many requests"
    /// says nothing about the five-minute rule behind it.
    func refreshLinkedCase(projectID: String) async throws {
        var request = try await client.makeRequest(
            "POST", "/project-case-refresh", body: try await signed(["projectId": .string(projectID)]))
        request.timeoutInterval = 120
        let (data, http) = try await client.perform(request)
        let decoded = try? JSONDecoder().decode(ProjectCaseRefreshResponse.self, from: data)
        if http.statusCode == 429 {
            let minutes = max(1, Int((Double(decoded?.retryAfter ?? 300) / 60).rounded(.up)))
            throw APIError.server(
                status: 429,
                message: "The court was asked recently. Try again in about \(minutes) minute\(minutes == 1 ? "" : "s").")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.classify(status: http.statusCode, body: data)
        }
        try CaseService.throwIfUnsuccessful(success: decoded?.success, error: decoded?.error)
    }

    // MARK: - Conversations

    /// `POST /project-chat`. A turn sent with the matter's id already files its conversation
    /// under the matter; this is the explicit form, for a conversation registered before its
    /// first question.
    func attachChat(projectID: String, chatID: String, attached: Bool) async throws {
        let body = try await signed([
            "projectId": .string(projectID), "chatId": .string(chatID), "attached": .bool(attached),
        ])
        let request = try await client.makeRequest("POST", "/project-chat", body: body)
        let response = try await client.send(request, as: WriteResponse.self)
        try CaseService.throwIfUnsuccessful(success: response.success, error: response.error)
    }

    // MARK: - Chronology from the documents

    /// `POST /project-chronology-extract`. `files` omitted reads every document in the matter;
    /// otherwise each is named as a turn names it, `{folderName, fileName}`, inside the matter.
    ///
    /// It is a set of paid model calls, so a plan refusal (402 `QUERY_LIMIT`) arrives as one,
    /// worded by `DisplayText`. The route may take minutes on a large matter.
    func extractChronology(projectID: String, files: [ChatAttachment]?) async throws -> ChronologyExtraction {
        var fields: [String: JSONValue] = ["projectId": .string(projectID)]
        if let files, !files.isEmpty {
            fields["files"] = .array(files.map { file in
                .object(["folderName": .string(file.folderName ?? ""), "fileName": .string(file.name)])
            })
        }
        var request = try await client.makeRequest(
            "POST", "/project-chronology-extract", body: try await signed(fields))
        // The server bounds the whole read at six minutes.
        request.timeoutInterval = 420
        let response = try await client.send(request, as: ChronologyExtractResponse.self)
        try CaseService.throwIfUnsuccessful(success: response.success, error: response.error)
        return ChronologyExtraction(
            events: response.events ?? [], files: response.files, skipped: response.skipped ?? [],
            partial: response.partial ?? false, message: response.message)
    }

    // MARK: - Banner

    /// `GET /project-banner`: the picture's bytes. A 404 is "no picture", not a failure.
    func bannerImage(projectID: String) async throws -> Data? {
        var request = try await client.makeRequest("GET", "/project-banner", query: ["id": projectID])
        // A new upload keeps the same address, so a cached copy would show the old picture.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, http) = try await client.perform(request)
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.classify(status: http.statusCode, body: data)
        }
        return data.isEmpty ? nil : data
    }

    /// `POST /project-banner` with a PNG, JPEG or WebP data URL of at most 2 MB.
    func uploadBanner(projectID: String, dataURL: String) async throws {
        let body = try await signed(["projectId": .string(projectID), "dataUrl": .string(dataURL)])
        var request = try await client.makeRequest("POST", "/project-banner", body: body)
        request.timeoutInterval = 120
        let response = try await client.send(request, as: WriteResponse.self)
        try CaseService.throwIfUnsuccessful(success: response.success, error: response.error)
    }

    func deleteBanner(projectID: String) async throws { try await delete("/project-banner", id: projectID) }

    // MARK: - Deleting the matter

    /// `DELETE /project`. `confirm` must be the matter's exact stored name — the screen asks for
    /// it to be typed, and refuses locally before this is reached (`deleteMatter(confirmName:)`).
    func deleteProject(id: String, confirm: String) async throws {
        var request = try await client.makeRequest(
            "DELETE", "/project", query: ["id": id, "confirm": confirm])
        request.timeoutInterval = 120
        let response = try await client.send(request, as: WriteResponse.self)
        try CaseService.throwIfUnsuccessful(success: response.success, error: response.error)
    }

    // MARK: - Plumbing

    /// Every POST body carries the caller, as every other write on this API does.
    private func signed(_ fields: [String: JSONValue]) async throws -> Payload {
        guard let credentials = await client.currentCredentials() else {
            throw APIError.notAuthenticated
        }
        var body = fields
        body["userId"] = .string(credentials.userIDString)
        return Payload(body: body)
    }

    private struct Payload: Encodable {
        let body: [String: JSONValue]
        func encode(to encoder: Encoder) throws { try body.encode(to: encoder) }
    }

    /// Adds a text field only when it has something in it. A blank is omitted, never sent as an
    /// empty string or null — on an edit that would clear the stored value.
    private func put(_ fields: inout [String: JSONValue], _ key: String, _ value: String?) {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
        else { return }
        fields[key] = .string(value)
    }

    private func delete(_ path: String, id: String) async throws {
        let request = try await client.makeRequest("DELETE", path, query: ["id": id])
        let response = try await client.send(request, as: WriteResponse.self)
        try CaseService.throwIfUnsuccessful(success: response.success, error: response.error)
    }

    private func unwrapProject(_ response: ProjectWriteResponse) async throws -> Project {
        try CaseService.throwIfUnsuccessful(success: response.success, error: response.error)
        guard let project = response.project else { throw Self.noRow("matter") }
        return project
    }

    private static func noRow(_ what: String) -> APIError {
        .server(status: 500, message: "The server did not return the saved \(what).")
    }

    /// Replaces the server's terse refusal on one status with wording a reader can act on,
    /// leaving every other failure exactly as it was. The twin of `AuctionService.rewriting`.
    private static func rewriting(
        _ error: APIError, status: Int, as message: String
    ) -> APIError {
        guard case .server(let received, _) = error, received == status else { return error }
        return .server(status: status, message: message)
    }
}
