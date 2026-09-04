import Foundation

/// Asking the server whether a document is already in the library, before uploading it again.
///
/// The mess this prevents is specific and common: an advocate is sent the same order by the
/// clerk, by opposing counsel and by their own junior, and uploads it three times into three
/// different matters. The library then holds three copies, the assistant cites whichever it
/// retrieves, and nobody can tell which one the annexure numbering refers to.
///
/// ## This is advisory, and must stay advisory
///
/// The route requires a **verified** token rather than a client-supplied id, because its answer
/// discloses which folders an account holds a document in — that is not something a caller who
/// merely knows a file's hash should be able to ask about someone else.
///
/// The consequence for this client is the important part: **a failure here must never block the
/// upload.** A 401, a timeout, an offline phone — all of them mean "no prompt", not "no upload".
/// The server runs its own dedupe when the bytes arrive regardless, so the only thing lost is
/// the chance to ask the user first. Treating a failed check as a failed upload would turn an
/// expired token into "this app will not accept my documents any more".
enum DuplicateCheck {

    /// What the server says about one file.
    ///
    /// - Note: the wire values are `duplicate`, `name-conflict` and `new`. An earlier plan
    ///   recorded the first as `content-dupe`; the server has never sent that. Unknown values
    ///   decode to `new`, which is the safe direction — it prompts for nothing and uploads.
    enum Status: String, Codable, Equatable, Sendable {
        case duplicate
        case nameConflict = "name-conflict"
        case new

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Status(rawValue: raw) ?? .new
        }
    }

    /// Where a copy already lives. Folder only — never a path.
    struct Placement: Codable, Equatable, Sendable, Hashable {
        let folder: String
        let fileName: String?
    }

    struct Conflict: Codable, Equatable, Sendable {
        let folder: String?
        let fileName: String?
        let size: Int?
    }

    struct Result: Codable, Equatable, Sendable {
        let name: String
        let hash: String?
        let status: Status
        /// Absent rather than empty when the file is new, so this is optional.
        let heldIn: [Placement]?
        let nameConflict: Conflict?

        var placements: [Placement] { heldIn ?? [] }
    }

    struct Response: Codable, Equatable, Sendable {
        let results: [Result]?
    }

    struct Request: Encodable, Sendable {
        struct File: Encodable, Sendable {
            let name: String
            let hash: String
        }
        let userId: String
        let files: [File]
        let targetFolder: String?
    }

    /// What the app should do with one file, once the user has been asked.
    enum Decision: Equatable, Sendable {
        /// Nothing to ask about.
        case upload
        /// The same bytes are already filed somewhere. Worth asking, because the answer is
        /// usually "then I don't need it again".
        case alreadyHeld([Placement])
        /// A different document with the same name is in the destination. Replacing it would
        /// destroy the other one, so this always asks.
        case wouldOverwrite(Conflict)
    }

    static func decision(for result: Result) -> Decision {
        switch result.status {
        case .duplicate:
            // A `duplicate` with no placements is a server answer that contradicts itself.
            // Uploading is the safe reading: a prompt that cannot say *where* the copy is
            // gives the user nothing to decide with.
            let placements = result.placements
            return placements.isEmpty ? .upload : .alreadyHeld(placements)
        case .nameConflict:
            guard let conflict = result.nameConflict else { return .upload }
            return .wouldOverwrite(conflict)
        case .new:
            return .upload
        }
    }

    /// Human wording for the prompt.
    ///
    /// Written to be readable by someone holding a phone in a corridor, so it names the matter
    /// the copy is filed under rather than saying "a duplicate was detected".
    static func message(for decision: Decision, fileName: String) -> String? {
        switch decision {
        case .upload:
            return nil
        case .alreadyHeld(let placements):
            let folders = placements
                .map { $0.folder == "/" ? "the top level" : $0.folder }
                .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            switch folders.count {
            case 0: return nil
            case 1: return "\(fileName) is already in your library, filed under \(folders[0])."
            case 2: return "\(fileName) is already in your library, under \(folders[0]) and \(folders[1])."
            default:
                let head = folders.dropLast().joined(separator: ", ")
                return "\(fileName) is already in your library, under \(head) and \(folders[folders.count - 1])."
            }
        case .wouldOverwrite(let conflict):
            let place = conflict.folder.map { $0 == "/" ? "the top level" : $0 } ?? "that folder"
            return "A different document called \(conflict.fileName ?? fileName) is already in "
                + "\(place). Uploading this one would replace it."
        }
    }
}

/// Checks a batch of files before they are uploaded.
protocol DuplicateChecking: Sendable {
    func check(
        files: [(name: String, hash: String)], targetFolder: String?
    ) async throws -> [DuplicateCheck.Result]
}

struct DuplicateCheckService: DuplicateChecking {
    let client: APIClient

    /// - Returns: one result per file, in the order asked. An empty array means "could not
    ///   check" and callers must read it as "no prompt", never as "nothing to prompt about".
    func check(
        files: [(name: String, hash: String)], targetFolder: String?
    ) async throws -> [DuplicateCheck.Result] {
        guard let credentials = await client.currentCredentials() else {
            throw APIError.notAuthenticated
        }
        // The server caps the batch at 1000 and silently drops the rest, so a longer list would
        // come back short and every dropped file would read as absent rather than unchecked.
        let capped = files.prefix(1000)
        guard !capped.isEmpty else { return [] }

        let payload = DuplicateCheck.Request(
            userId: credentials.userIDString,
            files: capped.map { .init(name: $0.name, hash: $0.hash) },
            targetFolder: targetFolder)
        let request = try await client.makeRequest("POST", "/check-duplicates", body: payload)
        let response = try await client.send(request, as: DuplicateCheck.Response.self)
        return response.results ?? []
    }
}
