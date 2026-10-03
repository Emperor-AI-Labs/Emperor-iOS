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

    /// The sign-in screen's state. Owned here so it survives the screen being rebuilt, and is
    /// wiped by `signOut` so the next person to hold the phone starts clean.
    let signInFlow: SignInFlow

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
    /// The dropdown catalogues behind the court search form — which bench, which case type.
    let courtMetadata: CourtMetadataService
    let fileManagement: FileManagementService
    let drafts: DraftHistoryService
    let auctions: AuctionService
    /// Built and reachable, with **no caller in the app** — see `ChatMetadataService` for why
    /// renaming a used conversation through `/sync` is not something this client will do.
    let chatMetadata: ChatMetadataService
    let duplicates: DuplicateCheckService
    let preferredModel: PreferredModelService
    let officePreview: OfficePreviewService
    /// Hand-made matters. Read-only — see `ProjectService` for why the writes are held back.
    let projects: ProjectService
    /// The in-app report channel for a generated answer. Both stores require one.
    let feedback: FeedbackService
    /// This month's allowances and usage, for Settings. Read only.
    let usage: UsageService
    /// The statutory deadlines behind the Corporate Calendar.
    let complianceCalendar: ComplianceCalendarService
    /// The private calendar-subscription link. Takes the base URL because the route answers a
    /// path that has to be resolved against it.
    let calendarFeed: CalendarFeedService

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
        self.usage = UsageService(client: client)
        self.courtSearch = CourtSearchService(client: client)
        self.courtMetadata = CourtMetadataService(client: client)
        self.fileManagement = FileManagementService(client: client)
        self.drafts = DraftHistoryService(client: client)
        self.auctions = AuctionService(client: client)
        self.projects = ProjectService(client: client)
        self.chatMetadata = ChatMetadataService(client: client)
        self.duplicates = DuplicateCheckService(client: client)
        self.preferredModel = PreferredModelService(client: client)
        self.officePreview = OfficePreviewService(client: client)
        self.complianceCalendar = ComplianceCalendarService(client: client)
        self.calendarFeed = CalendarFeedService(client: client, baseURL: config.baseURL)
        self.store = store
        self.cache = cache
        self.signInFlow = SignInFlow(auth: auth)

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
            await client.setRefusalObserver { refusal in
                Task { @MainActor in box.session?.note(refusal) }
            }
        }
        signInFlow.onSignedIn = { [weak self] response in
            await self?.completeSignIn(response)
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

    /// Re-reads the account's starting model and plan.
    ///
    /// The model itself already arrives with the login response and is already applied, so this
    /// is not about making the feature work — it is about the *stored user going stale*.
    /// `restore()` trusts what is on disk because there is no endpoint that validates a token,
    /// and a token lasts long enough that someone who signed in weeks ago and never signed out
    /// is running on whatever their plan was then. Moving an account to a better plan would
    /// change the web immediately and the phone not at all, which reads as the phone being
    /// broken.
    ///
    /// `/preferred-model` is the closest thing the platform has to a `/me`, so this is the one
    /// place that refresh can happen.
    ///
    /// Deliberately silent on failure. It runs at launch, it is not something the user asked
    /// for, and the stored values are a perfectly good answer — surfacing an error here would
    /// put a failure in front of someone who was simply opening the app.
    func refreshPreferredModel() async {
        guard case .signedIn(var user) = state else { return }
        guard let response = try? await preferredModel.preferredModel() else { return }
        // An unrecognised model means a mode this build does not have. Leaving the stored value
        // alone keeps the app on something it can actually render.
        guard let model = response.model else { return }

        user.preferredModel = model.rawValue
        if let plan = response.plan { user.plan = plan }
        if let label = response.planLabel { user.planLabel = label }

        persist(user)
        state = .signedIn(user)
    }

    // MARK: - Account standing

    /// Why new work would be refused, if it would be — shown as a banner rather than discovered
    /// one failed question at a time.
    enum Standing: Equatable, Sendable {
        /// The account has no active plan: new AI work and uploads are refused.
        case noPlan
        /// An administrator has paused the account. Reading still works.
        case suspended
    }

    /// From the account as last read: at sign-in, at launch (`refreshAccount`), and whenever the
    /// server refuses something for one of these two reasons.
    var standing: Standing? {
        guard let user = currentUser else { return nil }
        if user.suspended == true { return .suspended }
        if user.needsPlan == true { return .noPlan }
        return nil
    }

    /// Learns from a refusal the server just gave. A plan bought on the web, or a pause lifted,
    /// is learned the same way in reverse: from `refreshAccount` at the next launch.
    func note(_ refusal: Refusal) {
        guard case .signedIn(var user) = state else { return }
        switch refusal.code {
        case .planRequired: user.needsPlan = true
        case .accountSuspended: user.suspended = true
        default: return
        }
        persist(user)
        state = .signedIn(user)
    }

    /// Re-reads the account from the server and renews the token.
    ///
    /// Prefers `/auth/session`, which returns the whole account and a fresh token. Falls back to
    /// `/preferred-model` against a server without it — older deployments still answer that, and
    /// the starting model is the part of the account that most visibly goes stale.
    ///
    /// Silent on failure for the same reason as `refreshPreferredModel`: it runs at launch,
    /// unasked, and the stored account is a perfectly good answer. The one failure that does
    /// act is a 401, which ends the session through the client's usual path.
    func refreshAccount() async {
        guard case .signedIn(let current) = state else { return }
        lastAccountRefresh = Date()
        do {
            let response = try await auth.currentSession()
            // A different account behind the same token would be a server fault; refusing to
            // adopt it keeps one user's data from appearing under another's name.
            guard response.user.id == current.id, case .signedIn = state else { return }
            var refreshed = response.user
            // A model this build does not know keeps the stored one, as `refreshPreferredModel`
            // does — the app must stay on a mode it can render.
            if refreshed.preferredModel.flatMap(ChatModel.init(rawValue:)) == nil {
                refreshed.preferredModel = current.preferredModel
            }
            if !response.token.isEmpty {
                store.set(response.token, for: Self.tokenKey)
                await client.setCredentials(Credentials(token: response.token, userID: refreshed.id))
            }
            persist(refreshed)
            state = .signedIn(refreshed)
        } catch let error as APIError where error == .invalidCredentials {
            // Already handled: the client's authentication-lost handler is signing out.
            return
        } catch {
            await refreshPreferredModel()
        }
    }

    /// When the account was last re-read, so coming back to the app does not do it every time.
    private(set) var lastAccountRefresh: Date?

    /// How long an account reading stays good enough. Half an hour: a plan bought on the web
    /// shows up the next time the phone is picked up, without a request on every glance.
    nonisolated static let accountRefreshInterval: TimeInterval = 30 * 60

    /// `refreshAccount`, unless it ran recently. For the app becoming active again.
    func refreshAccountIfDue(now: Date = Date()) async {
        if let last = lastAccountRefresh, now.timeIntervalSince(last) < Self.accountRefreshInterval {
            return
        }
        await refreshAccount()
    }

    /// Stores a successful sign-in and moves the app to signed-in.
    func completeSignIn(_ response: AuthResponse) async {
        // A sign-in is as fresh a reading of the account as there is.
        lastAccountRefresh = Date()
        store.set(response.token, for: Self.tokenKey)
        persist(response.user)
        await client.setCredentials(
            Credentials(token: response.token, userID: response.user.id))
        state = .signedIn(response.user)
    }

    private func persist(_ user: User) {
        if let encoded = try? JSONEncoder().encode(user),
           let json = String(data: encoded, encoding: .utf8) {
            store.set(json, for: Self.userKey)
        }
    }

    /// Signs out.
    ///
    /// The server is told (`POST /logout`, best-effort — see `AuthService.signOut`), but it keeps
    /// no list of revoked tokens a client can add to, so clearing everything here is still the
    /// protection the next person to hold the phone gets: the cached matters go with the token,
    /// and the sign-in screen forgets the address that was typed into it.
    func signOut() async {
        store.remove(Self.tokenKey)
        store.remove(Self.userKey)
        cache.clear()
        await auth.signOut()
        signInFlow.reset()
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
