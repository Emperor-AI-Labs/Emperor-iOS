import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Observation
#endif

/// App-wide auth state and the single shared `APIClient`.
///
/// `@Observable` is applied on Apple platforms only, for the reason given on `ChatViewModel`:
/// the Linux toolchain's `libswiftObservation.so` has an undefined symbol, so the macro
/// compiles there and then fails to link.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class Session {
    enum State: Equatable {
        case loading
        case signedOut
        case signedIn(User)
    }

    private(set) var state: State = .loading
    var signInError: String?
    var isWorking = false

    let client: APIClient
    let auth: AuthService
    let chats: ChatService
    let uploads: UploadService
    let files: FileService
    let cases: CaseService
    let notifications: NotificationService
    let ocr: OCRService
    let calendar: CalendarService
    let library: LibraryService
    let enhancer: EnhancerService
    let courtSearch: CourtSearchService
    let fileManagement: FileManagementService
    let drafts: DraftHistoryService
    let auctions: AuctionService
    /// Hand-made matters. Read-only — see `ProjectService` for why the writes are held back.
    let projects: ProjectService
    /// The in-app report channel for a generated answer. Both stores require one.
    let feedback: FeedbackService

    let cache: ResponseCache

    private let store: any CredentialStore

    private static let tokenKey = "auth.token"
    private static let userKey = "auth.user"

    /// - Parameters:
    ///   - store: where the token is persisted. Required rather than defaulted: a silent
    ///     fallback to in-memory storage would look like a working sign-in that simply forgets
    ///     itself on every launch, which is a tedious thing to diagnose from the outside.
    ///   - cache: the offline snapshot store. Defaults to disk; tests pass an in-memory one.
    /// - Parameter urlSession: injected only by tests. Without this seam nothing could stub
    ///   `Session`'s transport, so the sign-out-on-401 path had no way to be exercised.
    init(
        config: APIConfig = .current,
        store: any CredentialStore,
        cache: ResponseCache = ResponseCache(
            store: FileCacheStore(directory: FileCacheStore.defaultDirectory())),
        urlSession: URLSession? = nil
    ) {
        let client = APIClient(config: config, session: urlSession)
        self.client = client
        self.auth = AuthService(client: client)
        self.chats = ChatService(client: client)
        self.uploads = UploadService(client: client)
        self.files = FileService(client: client)
        self.cases = CaseService(client: client)
        self.notifications = NotificationService(client: client)
        self.ocr = OCRService(client: client)
        self.calendar = CalendarService(client: client)
        self.library = LibraryService(client: client)
        self.enhancer = EnhancerService(client: client)
        self.feedback = FeedbackService(client: client)
        self.courtSearch = CourtSearchService(client: client)
        self.fileManagement = FileManagementService(client: client)
        self.drafts = DraftHistoryService(client: client)
        self.auctions = AuctionService(client: client)
        self.projects = ProjectService(client: client)
        self.store = store
        self.cache = cache

        // Acted on, not merely classified. Without this an expired 30-day token leaves every
        // screen showing "Session expired" with no retry and no way back — the only escape
        // being to delete the app.
        //
        // Routed through a box because the handler the client stores is `@Sendable`, and a
        // `@Sendable` closure may not capture `self` here. The box carries a weak reference
        // instead, so nothing crosses the isolation boundary.
        weakSelf.session = self
        let box = weakSelf
        Task {
            await client.setAuthenticationLostHandler {
                Task { @MainActor in box.session?.handleAuthenticationLost() }
            }
        }
    }

    private let weakSelf = SessionBox()

    /// The server rejected our identity, so the token is spent. Sign out rather than leaving
    /// the app in a state where every screen fails and nothing offers a way forward.
    private func handleAuthenticationLost() {
        guard case .signedIn = state else { return }
        Task { await signOut() }
    }

    var currentUser: User? {
        if case .signedIn(let user) = state { return user }
        return nil
    }

    /// Restores a previous sign-in.
    ///
    /// The stored user is trusted without a server round-trip because there is no endpoint
    /// that validates a token — no `/me`, no refresh. An expired token surfaces as the first
    /// failing request instead.
    func restore() async {
        guard let token = store.string(for: Self.tokenKey),
              let data = store.string(for: Self.userKey)?.data(using: .utf8),
              let user = try? JSONDecoder().decode(User.self, from: data)
        else {
            state = .signedOut
            return
        }
        await client.setCredentials(Credentials(token: token, userID: user.id))
        state = .signedIn(user)
    }

    func signIn(email: String, password: String) async {
        isWorking = true
        signInError = nil
        defer { isWorking = false }
        do {
            let response = try await auth.login(
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password)
            await adopt(response)
        } catch {
            signInError = DisplayText.message(for: error)
        }
    }

    /// The confirmation shown after asking for a reset link.
    ///
    /// Deliberately unconditional and slightly hedged. The route answers 200 for an unknown
    /// address on purpose, mail delivery depends on SMTP that may not be configured, and
    /// accounts on this platform are created by an administrator rather than self-signup — so
    /// promising "check your inbox" would be three separate over-claims.
    nonisolated static let passwordResetNotice = """
        If an account exists for that address, a reset link is on its way. The link opens in \
        your browser.

        If nothing arrives, contact your administrator — Emperor accounts are created for you \
        rather than signed up for.
        """

    private(set) var passwordResetSent = false

    func requestPasswordReset(email: String) async {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isWorking else { return }
        isWorking = true
        signInError = nil
        defer { isWorking = false }
        do {
            try await auth.requestPasswordReset(email: trimmed)
            passwordResetSent = true
        } catch {
            signInError = DisplayText.message(for: error)
        }
    }

    func clearPasswordResetNotice() { passwordResetSent = false }

    func register(name: String, email: String, password: String) async {
        isWorking = true
        signInError = nil
        defer { isWorking = false }
        do {
            let response = try await auth.register(
                name: name,
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password)
            await adopt(response)
        } catch {
            signInError = DisplayText.message(for: error)
        }
    }

    private func adopt(_ response: AuthResponse) async {
        store.set(response.token, for: Self.tokenKey)
        if let encoded = try? JSONEncoder().encode(response.user),
           let json = String(data: encoded, encoding: .utf8) {
            store.set(json, for: Self.userKey)
        }
        await client.setCredentials(
            Credentials(token: response.token, userID: response.user.id))
        state = .signedIn(response.user)
    }

    /// Signing out is purely local, so clearing everything here is the *only* protection the
    /// next person to hold the phone gets — the cached matters go with the token, not just the
    /// token.
    func signOut() async {
        store.remove(Self.tokenKey)
        store.remove(Self.userKey)
        cache.clear()
        await auth.signOut()
        state = .signedOut
    }
}

/// Carries a weak `Session` into the `@Sendable` handler stored on the actor.
///
/// `@unchecked Sendable` is honest: the reference is written once during `Session.init` and
/// read only on the main actor, where `Session` itself lives.
private final class SessionBox: @unchecked Sendable {
    weak var session: Session?
}
