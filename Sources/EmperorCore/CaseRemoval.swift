import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Stop tracking a case: `DELETE /case?id=&userId=` → `{success:true}`, as the web's case
/// workspace does from its "Remove" button (`deleteCase`, `src/lib/store.js`).
///
/// A case belongs to a team — a solo practitioner's own, or a chamber's shared one — and only the
/// team's owner or an admin may remove it; anyone else is answered 403. The removal takes the case
/// and its timeline off every member's docket, and cannot be undone, which is why the app asks
/// first. A matter made from the case (`POST /project-from-case`) is not removed with it: the
/// matter keeps its own chronology, tasks, fees, people and documents, and simply stops showing
/// the court's record and the case's hearing dates.
///
/// A separate protocol from `CaseProviding` so the screens that never remove anything — the
/// calendar, the cause list, the notifications — are not asked to carry it.
protocol CaseRemoving: Sendable {
    func removeCase(id: String) async throws
}

extension CaseService: CaseRemoving {
    func removeCase(id: String) async throws {
        let request = try await client.makeRequest("DELETE", "/case", query: ["id": id])
        let (data, response) = try await client.perform(request)
        let reply = try? JSONDecoder().decode(WriteResponse.self, from: data)
        switch response.statusCode {
        case 200..<300:
            // A 200 that says it did not remove is not removed.
            guard reply?.success == true else {
                throw APIError.server(status: response.statusCode, message: CaseRemovalCopy.notRemoved)
            }
        case 403:
            throw APIError.server(status: 403, message: CaseRemovalCopy.teamCase)
        case 401:
            await client.noteAuthenticationLost()
            throw APIError.invalidCredentials
        default:
            if let refused = APIError.classify(status: response.statusCode, body: data).refusal {
                throw APIError.refused(refused)
            }
            throw APIError.server(status: response.statusCode, message: CaseRemovalCopy.notRemoved)
        }
    }
}

enum CaseRemovalCopy {
    static let action = "Stop tracking"
    static let confirmTitle = "Stop tracking this case?"
    /// Said before the removal, because it is shared and final.
    static let confirmMessage =
        "It is removed from the docket for everyone on its team, with its notes and timeline. This cannot be undone. A matter made from it is kept."
    static let failedTitle = "Could not stop tracking"
    /// The 403, worded here: the server's sentence names roles rather than what to do.
    static let teamCase =
        "This case is on a team's docket, and only the team's owner or an admin can stop tracking it. Ask one of them to remove it."
    static let notRemoved = "The case wasn't removed. Try again in a moment."
}
