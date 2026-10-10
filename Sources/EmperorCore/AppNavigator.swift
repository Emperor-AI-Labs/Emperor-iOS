import Foundation
#if canImport(Darwin)
import Observation
#endif

/// A matter pushed onto the Matters tab's navigation stack.
struct CaseRoute: Hashable, Sendable {
    let caseID: String
    /// Which request pushed it: `0` for a row tapped in the docket itself, otherwise the
    /// `AppNavigator` request that asked for it.
    ///
    /// Part of the value so that asking for the matter already on screen still gives a fresh
    /// screen. A stack whose only element is unchanged is left exactly as it was — scrolled to
    /// whichever section the reader left it on — and the request was to see the matter's
    /// overview.
    var request: Int = 0
}

/// A question another tab has asked the Ask tab to start — "Ask about it" on a hearing, "Ask
/// about this folder".
struct AskRequest: Hashable, Sendable {
    /// What goes into the composer. Not sent: the reader reads it, changes it, and sends it.
    let prompt: String
    /// The documents the question is about.
    let attachments: [ChatAttachment]
    var request: Int = 0
}

/// A document some other part of the app has asked My Files to open — a tapped search result.
struct DocumentRoute: Hashable, Sendable {
    /// The document's path in the library, `/`-joined as `/user-files` reports it.
    let path: String
    /// Which request asked for it, so asking again for the same document is still a change.
    var request: Int = 0

    /// The folder the document is filed in, `""` for the top level.
    var folderPath: String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[path.startIndex..<slash])
    }

    /// The folders to open on the way down to it, outermost first — `Bakshi`, then
    /// `Bakshi/Orders` — so Back from the document's folder climbs the library as it would had
    /// each folder been opened by hand.
    var folderStack: [String] {
        let parts = folderPath.split(separator: "/").map(String.init)
        return parts.indices.map { parts[0...$0].joined(separator: "/") }
    }
}

/// Navigation that crosses tabs: which tab is showing, and a case some other tab has asked the
/// Cases tab to open.
///
/// One per signed-in app, made by `MainTabView` and handed down the environment. A tab that wants
/// another tab to show something says so here rather than reaching into it, so neither has to
/// know how the other is built.
///
/// ## Opening a case from another tab
///
/// `openCase(_:)` records the request and switches to Cases. The Cases tab takes it with
/// `takePendingCaseStack()` — when it appears, or when the request changes while it is already
/// on screen — and replaces its stack with what that returns. Taking clears the request, so it is
/// applied once: coming back to the tab later must not push the case a second time.
///
/// The stack is **replaced, not appended to**. Whatever the Cases tab was last showing is not
/// what the user asked for, and Back from the case should land on the docket — the place the
/// case lives — rather than on a matter opened an hour ago.
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class AppNavigator {

    /// The tab bar, in order — the Record design's four destinations: **Ask · Matters · Files ·
    /// You**. See `MainTabView` for where everything else went.
    enum Tab: Hashable, Sendable {
        case ask, matters, files, you
    }

    var selectedTab: Tab

    /// A case another tab has asked to open, not yet taken by the Cases tab.
    private(set) var pendingCase: CaseRoute?

    /// Requests so far. Starts above zero, which is reserved for a row tapped in the docket.
    private var requestCount = 0

    init(selectedTab: Tab = .ask) {
        self.selectedTab = selectedTab
    }

    /// Shows a case on the Matters tab, opened on its overview.
    ///
    /// The latest request wins: a second one before the first is taken replaces it, because the
    /// user has since asked for something else.
    func openCase(_ caseID: String) {
        guard !caseID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        requestCount += 1
        pendingCase = CaseRoute(caseID: caseID, request: requestCount)
        selectedTab = .matters
    }

    /// The Cases tab's new stack, or `nil` when nothing is waiting. Taking the request clears it.
    func takePendingCaseStack() -> [CaseRoute]? {
        guard let route = pendingCase else { return nil }
        pendingCase = nil
        return [route]
    }

    // MARK: - Documents

    /// A document waiting to be shown in My Files, not yet taken.
    private(set) var pendingDocument: DocumentRoute?

    /// Shows a document: My Files, open on its folder, previewing it.
    ///
    /// The tab is left as it is. My Files is presented over whatever is showing rather than
    /// being a tab, so there is nothing to switch to — and closing it returns the person to where
    /// they were. The latest request wins, as with a case.
    func openDocument(path: String) {
        // Blank segments are dropped, so a stray or doubled slash still finds the document.
        let normalized = path.split(separator: "/")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "/")
        guard !normalized.isEmpty else { return }
        requestCount += 1
        pendingDocument = DocumentRoute(path: normalized, request: requestCount)
    }

    /// The waiting document, once. Taking it clears it.
    func takePendingDocument() -> DocumentRoute? {
        defer { pendingDocument = nil }
        return pendingDocument
    }

    // MARK: - Asking from another tab

    /// A question waiting for the Ask tab, not yet taken.
    private(set) var pendingQuestion: AskRequest?

    /// Switches to Ask with `prompt` in the composer and `attachments` on it. Nothing is sent:
    /// the question is the reader's to send. The latest request wins.
    func ask(_ prompt: String, about attachments: [ChatAttachment] = []) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        requestCount += 1
        pendingQuestion = AskRequest(prompt: trimmed, attachments: attachments, request: requestCount)
        selectedTab = .ask
    }

    /// The waiting question, once. Taking it clears it.
    func takePendingQuestion() -> AskRequest? {
        defer { pendingQuestion = nil }
        return pendingQuestion
    }

    // MARK: - Search results

    /// Opens where a tapped search result leads.
    func open(_ target: SpotlightTarget) {
        switch target {
        case .caseDetail(let id): openCase(id)
        case .document(let path): openDocument(path: path)
        }
    }

    // MARK: - Opening the Calendar on a day

    /// A day something outside the Calendar has asked it to show — a tapped hearing reminder, the
    /// Today widget, a link — not yet taken by it. India's `YYYY-MM-DD`.
    ///
    /// Taken the way the Cases tab takes `pendingCase`: by `takePendingDay()`, when the Calendar
    /// appears or when this changes while it is on screen, and cleared by taking.
    private(set) var pendingDay: String?

    /// A request for the Calendar not yet taken, numbered so a second request while the first
    /// waits is still a change. The Calendar lives on the Matters tab now, presented over it; the
    /// tab takes this and presents it, and the Calendar takes `pendingDay` itself.
    private(set) var calendarRequest: Int?

    /// Whether the Calendar was asked for. Taking clears the request.
    func takeCalendarRequest() -> Bool {
        guard calendarRequest != nil else { return false }
        calendarRequest = nil
        return true
    }

    /// Shows the Calendar — over the Matters tab — on `day` when that is a real day.
    ///
    /// The day is checked by round trip, as a notification's is (`NotificationTarget`), so a
    /// malformed one cannot open the Calendar somewhere odd; the Calendar then opens on whatever
    /// day it was showing. The latest request wins — including over an Updates screen still
    /// waiting to be shown, which would otherwise appear over the day just asked for.
    func openCalendar(on day: String?) {
        pendingDay = day.flatMap { IndianDay.isValid($0) ? $0 : nil }
        updatesRequest = nil
        requestCount += 1
        calendarRequest = requestCount
        selectedTab = .matters
    }

    /// The day the Calendar should select, or `nil` when nothing is waiting. Taking clears it.
    func takePendingDay() -> String? {
        defer { pendingDay = nil }
        return pendingDay
    }

    // MARK: - Opening Updates

    /// A request for the Updates screen not yet shown, numbered so a second request while the
    /// first waits is still a change to observe.
    ///
    /// **It does not switch tabs.** The screen is a sheet, and something else may be presented
    /// when the request arrives — a half-written diary entry, say. Whoever presents Updates waits
    /// until nothing is, then switches to Ask and shows it (`NotificationTapRouting`); an Updates
    /// screen already open takes the request itself and reloads. Switching tabs now could take
    /// the sheet the person is working in away with it.
    private(set) var updatesRequest: Int?

    /// Asks for the Updates screen.
    func openUpdates() {
        requestCount += 1
        updatesRequest = requestCount
    }

    /// Whether Updates was asked for. Taking clears the request, so it is shown once.
    func takeUpdatesRequest() -> Bool {
        guard updatesRequest != nil else { return false }
        updatesRequest = nil
        return true
    }
}
