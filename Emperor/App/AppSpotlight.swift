import SwiftUI
import CoreSpotlight
import UniformTypeIdentifiers

/// The app's one link to the device's search: what to index, when, and where a tapped result
/// leads.
///
/// Process-wide, as `AppNotifications` is, because a tapped result can launch the app before any
/// screen exists, and the docket is learned from the response cache (`NotifyingCacheStore`) rather
/// than from whichever screen happened to load it. Every decision is `SpotlightCoordinator`'s;
/// this connects it to the session and the system.
@MainActor
final class AppSpotlight {
    static let shared = AppSpotlight()

    let coordinator: SpotlightCoordinator
    /// A tapped result, waiting for the tab view (`SpotlightRouting`).
    let inbox = SpotlightInbox()
    /// Handed over by `EmperorApp.makeSession()`.
    var session: Session?

    private init() {
        #if DEBUG
        // The UI tests never write to the simulator's real index.
        if UITestSupport.isActive {
            coordinator = SpotlightCoordinator(index: InertSpotlightIndex(), store: Preferences())
            return
        }
        #endif
        coordinator = SpotlightCoordinator(index: CoreSpotlightIndex(), store: Preferences())
    }

    private var isSignedIn: Bool { session?.currentUser != nil }

    /// Once the session has been restored at launch: empty the index if it should be empty, and
    /// otherwise index the docket as it was last cached, so the search is current before any
    /// screen has loaded anything.
    func launched() {
        coordinator.launched(isSignedIn: isSignedIn)
        caseListChanged()
    }

    /// The cached docket changed — written by whichever screen loaded it.
    func caseListChanged() {
        guard let cached = session?.cache.load([LegalCase].self, for: .caseList) else { return }
        coordinator.casesLoaded(cached.value, isSignedIn: isSignedIn)
    }

    /// My Files read the library.
    func libraryLoaded(_ tree: [FileNode]) {
        coordinator.documentsLoaded(tree, isSignedIn: isSignedIn)
    }

    /// The Settings switch.
    func setEnabled(_ enabled: Bool) {
        coordinator.setEnabled(enabled, isSignedIn: isSignedIn)
        if enabled { caseListChanged() }
    }

    /// The session ended: empty the index, and drop a tapped result still waiting — it was about
    /// that account's matters.
    func signedOut() {
        inbox.clear()
        coordinator.signedOut()
    }

    /// A result was tapped in the device's search.
    func open(_ activity: NSUserActivity) {
        guard let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String
        else { return }
        inbox.open(identifier: identifier)
    }
}

/// The device's search index, as `SpotlightIndexing` describes it.
///
/// An index of the app's own, created with **complete** file protection: its contents can only
/// be read while the device is unlocked, so a locked phone's search does not show a client's
/// name. Nothing here needs an entitlement, so it works the same in a build re-signed by a
/// sideloading tool; where indexing is not available at all, every call does nothing.
@MainActor
final class CoreSpotlightIndex: SpotlightIndexing {
    private let index = CSSearchableIndex(name: "com.emperorailabs.emperor", protectionClass: .complete)

    func replace(_ domain: SpotlightDomain, with entries: [SpotlightEntry]) async {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        let index = self.index
        // Errors are not reported: the search is a convenience, and the next load writes it again.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            index.deleteSearchableItems(withDomainIdentifiers: [domain.rawValue]) { _ in
                continuation.resume()
            }
        }
        guard !entries.isEmpty else { return }
        let items = entries.map(Self.item(for:))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            index.indexSearchableItems(items) { _ in
                continuation.resume()
            }
        }
    }

    func removeAll() async {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        let index = self.index
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            index.deleteAllSearchableItems { _ in
                continuation.resume()
            }
        }
    }

    private static func item(for entry: SpotlightEntry) -> CSSearchableItem {
        let type = entry.fileExtension.flatMap { UTType(filenameExtension: $0) } ?? .text
        let attributes = CSSearchableItemAttributeSet(contentType: type)
        attributes.title = entry.title
        attributes.contentDescription = entry.detail
        attributes.keywords = entry.keywords
        return CSSearchableItem(
            uniqueIdentifier: entry.identifier,
            domainIdentifier: entry.domain.rawValue,
            attributeSet: attributes)
    }
}

#if DEBUG
/// For the UI tests, which must not leave the stub's matters in the simulator's search.
@MainActor
final class InertSpotlightIndex: SpotlightIndexing {
    func replace(_ domain: SpotlightDomain, with entries: [SpotlightEntry]) async {}
    func removeAll() async {}
}
#endif

/// Opens a tapped search result: a case on the Cases tab, a document in My Files on its folder.
///
/// Applied by `MainTabView`, the one place that holds the `AppNavigator` — beside
/// `routesNotificationTaps`, and for the same reason: a result tapped while the app was closed is
/// waiting in the inbox before this view exists, so the change is observed with `initial: true`.
///
/// My Files is presented over whatever is showing (`TopPresenter`), not by a sheet from here — the
/// person may already be in one of More's screens when they search, and a second sheet from the
/// tab view would never appear.
struct SpotlightRouting: ViewModifier {
    let navigator: AppNavigator

    @Environment(Session.self) private var session
    @Environment(\.theme) private var theme
    @Environment(\.practice) private var practice

    @State private var presenter = TopPresenter()

    func body(content: Content) -> some View {
        content
            .onChange(of: AppSpotlight.shared.inbox.tapCount, initial: true) { _, _ in
                guard let target = AppSpotlight.shared.inbox.take() else { return }
                navigator.open(target)
            }
            .onChange(of: navigator.pendingDocument, initial: true) { _, _ in
                openDocument()
            }
    }

    private func openDocument() {
        guard let route = navigator.takePendingDocument() else { return }
        // A beat first: a result that launched the app arrives as the tab view does, and a
        // presentation in that same pass can land on a controller that is still being replaced.
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            present(route)
        }
    }

    private func present(_ route: DocumentRoute) {
        // One My Files from a search at a time: a second result replaces the first.
        let topPresenter = presenter
        topPresenter.dismiss(animated: false)
        topPresenter.present(
            MyFilesView(opening: route, onDone: { topPresenter.dismiss() })
                .environment(session)
                .environment(\.theme, theme)
                .environment(\.practice, practice)
                .environment(\.navigator, navigator)
                .preferredColorScheme(theme.colorScheme)
                .tint(theme.accent),
            modal: false)
    }
}

extension View {
    /// See `SpotlightRouting`.
    func routesSpotlightResults(to navigator: AppNavigator) -> some View {
        modifier(SpotlightRouting(navigator: navigator))
    }
}
