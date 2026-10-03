import Foundation
#if canImport(Darwin)
import Observation
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The role the user practises in — one app-wide choice, kept in step with the account.
///
/// App-level rather than per-conversation, which is how the platform treats it: a role scopes the
/// toolkit and seeds what the model is told, and neither of those is a decision to retake on
/// every question. The per-conversation "Acting as" picker in the chat's own menu still overrides
/// what a single answer is asked for, and deliberately offers the three wire values rather than
/// these seven — see `PractitionerRole.wireRole` for why those are different lists.
///
/// ## Two copies, one choice
///
/// The account holds the role (`practice_role`), so switching on the phone switches the web and
/// the other way round. The device holds a copy, because the toolkit has to be drawn before the
/// account has been read and with no connection at all. The rules for keeping them together:
///
/// - **A choice made here is sent to the account at once**, and until the account has it the
///   device's copy is marked unsent. An unsent choice is newer than anything the account can be
///   holding, so it is sent again rather than overwritten the next time the account is read.
/// - **Otherwise the account wins.** A role switched on the web arrives with the next reading of
///   the account (`Session.refreshAccount`) and replaces the device's.
/// - **An account with no role is given this device's**, if a role was ever actually chosen
///   here. The default is not a choice and is never sent.
/// - **A role this app does not carry is left alone** — the web's Devil's Advocate. The device
///   keeps its own and nothing is written back, so the web stays as its owner set it.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class Practice {
    private(set) var role: PractitionerRole

    /// Sends a choice to the account, by its web id. `nil` keeps the role on this device alone.
    var accountWriter: (@Sendable (String) async throws -> Void)?
    /// Told once the account holds a choice made here, so the signed-in copy of the account
    /// agrees with it and the next reading is not taken for a change made elsewhere.
    var onAccountWritten: ((String) -> Void)?

    private let store: any PreferenceStore
    /// Writes go one at a time, in the order they were chosen, so two quick switches cannot
    /// reach the server the wrong way round and leave the account on the first.
    private var lastWrite: Task<Void, Never>?

    static let unsentKey = "practitioner.role.unsent.v1"

    init(store: any PreferenceStore) {
        self.store = store
        self.role = PractitionerRole.stored(in: store)
    }

    /// Whether a role has ever been chosen on this device, as opposed to the default applying.
    var hasChosen: Bool { store.string(for: PractitionerRole.storageKey) != nil }

    /// Whether the account has yet to receive the role chosen here.
    var isUnsent: Bool { store.bool(for: Self.unsentKey) }

    /// The user chose a role: take it here at once, and send it to the account.
    @discardableResult
    func select(_ role: PractitionerRole) -> Task<Void, Never>? {
        self.role = role
        role.save(to: store)
        store.setBool(true, for: Self.unsentKey)
        return send(role)
    }

    /// Brings this device into line with the account, as just read. `nil` is an account with no
    /// role yet. See the type's notes for the rules.
    @discardableResult
    func reconcile(withAccountRole webID: String?) -> Task<Void, Never>? {
        if isUnsent { return send(role) }
        guard let webID, !webID.isEmpty else {
            return hasChosen ? send(role) : nil
        }
        guard let adopted = PractitionerRole(webID: webID) else { return nil }
        if adopted != role || !hasChosen {
            role = adopted
            adopted.save(to: store)
        }
        return nil
    }

    /// Connects to a signed-in session: choices are written to its account, and the account it
    /// holds learns of them.
    func link(to session: Session) {
        let service = session.practiceRoles
        accountWriter = { webID in try await service.save(webID) }
        onAccountWritten = { [weak session] webID in session?.noteAccountRole(webID) }
    }

    private func send(_ role: PractitionerRole) -> Task<Void, Never>? {
        guard let accountWriter else { return nil }
        let previous = lastWrite
        let webID = role.webID
        let task = Task { [weak self] in
            await previous?.value
            do {
                try await accountWriter(webID)
            } catch {
                // Left marked unsent, and sent again the next time the account is read.
                return
            }
            guard let self else { return }
            // A later choice may have been made while this one was on its way; that one is
            // still unsent until its own write lands.
            if self.role == role {
                self.store.setBool(false, for: Self.unsentKey)
            }
            self.onAccountWritten?(webID)
        }
        lastWrite = task
        return task
    }
}

/// Where the account's role is written.
///
/// A route of its own rather than a field on the profile update, for the reason the platform
/// gives for the starting model's: it is written on every switch, and a single-purpose route
/// cannot disturb the name, title or organisation beside it.
struct PracticeRoleService: Sendable {
    let client: APIClient

    private struct Payload: Encodable {
        let userId: String
        let role: String
    }

    private struct Reply: Decodable {
        let success: Bool?
    }

    func save(_ webID: String) async throws {
        guard let credentials = await client.currentCredentials() else {
            throw APIError.notAuthenticated
        }
        let request = try await client.makeRequest(
            "POST", "/set-practice-role",
            body: Payload(userId: credentials.userIDString, role: webID))
        let reply = try await client.send(request, as: Reply.self)
        // A 200 that says it did not save is not saved: the choice stays unsent.
        if reply.success == false {
            throw APIError.server(status: 200, message: "The role was not saved.")
        }
    }
}
