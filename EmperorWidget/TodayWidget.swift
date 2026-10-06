import SwiftUI
import WidgetKit

/// What is listed today, on the Home Screen and the Lock Screen.
///
/// ## Where its data comes from
///
/// Only the snapshot the app leaves in the shared app group (`TodaySnapshot`), read with no
/// network and no credential. The app writes it whenever it saves the cause list and clears it on
/// sign-out, and asks WidgetKit to reload then (`TodayWidgetBridge`); the widget itself never
/// fetches. Which day is "today" is decided at each entry's moment, in India (`TodayGlance`), and
/// the timeline has an entry at every Indian midnight of the week, so the widget moves on to the
/// next day with no app involved.
///
/// ## When there is nothing to read
///
/// No app group (a sideloaded build without the entitlement), no snapshot yet, nobody signed in,
/// or a snapshot older than the week it covers: the widget says "Open Emperor to load your
/// listings". It never says "nothing listed" about a day it knows nothing of.
///
/// ## Privacy
///
/// Matter rows are `.privacySensitive()`, so a Lock Screen widget on a locked phone shows them
/// redacted — counts and days stay, clients' names do not. The inline Lock Screen line carries
/// no names at all (`TodayCopy.inline`).
struct TodayWidget: Widget {
    let kind = "EmperorToday"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TodayProvider()) { entry in
            TodayWidgetView(entry: entry)
        }
        .configurationDisplayName("Listed Today")
        .description("Your matters listed today — or, on a quiet day, the next day that has any.")
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryInline,
        ])
    }
}

/// One moment of the widget: what it shows from then until the next entry.
struct TodayEntry: TimelineEntry {
    let date: Date
    let glance: TodayGlance
    /// When the listings were fetched, for "Updated 2 days ago".
    let fetchedAt: Date?

    init(date: Date, snapshot: TodaySnapshot?) {
        self.date = date
        self.glance = TodayGlance.decide(snapshot, now: date)
        self.fetchedAt = snapshot?.fetchedAt
    }

    /// The widget gallery's picture, and the placeholder WidgetKit draws redacted while it
    /// loads. Fictional matters, so a preview never shows anyone's real case.
    static func sample(at date: Date) -> TodayEntry {
        let today = IndianDay.key(date)
        let day = TodayDay(day: today, total: 3, matters: [
            TodayMatter(
                caseID: "sample-1", title: "Bakshi v. State of Maharashtra",
                court: "Bombay High Court", room: "Court 12", item: "7", time: "10:30 AM"),
            TodayMatter(
                caseID: "sample-2", title: "Kapoor Textiles Pvt. Ltd. v. Commissioner of Customs",
                court: "High Court of Delhi", room: "Court 4", item: "23", time: nil),
            TodayMatter(
                caseID: "sample-3", title: "Rao v. Union of India",
                court: "Supreme Court of India", room: "Court 3", item: "41", time: nil),
        ])
        let snapshot = TodaySnapshot(
            isSignedIn: true, generatedAt: date, fetchedAt: date,
            firstDay: today, lastDay: today, days: [day])
        return TodayEntry(date: date, snapshot: snapshot)
    }
}

/// Reads the snapshot once per timeline and lays out the week from it.
struct TodayProvider: TimelineProvider {

    func placeholder(in context: Context) -> TodayEntry {
        .sample(at: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        let now = Date()
        completion(context.isPreview
            ? .sample(at: now)
            : TodayEntry(date: now, snapshot: SharedSnapshot.read()))
    }

    /// Now, and each Indian midnight of the week, all from one read. Ends where the week does;
    /// the app asks for a new timeline whenever it writes a new snapshot long before that.
    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        let snapshot = SharedSnapshot.read()
        let entries = TodayTimeline.entryDates(now: Date())
            .map { TodayEntry(date: $0, snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

/// The snapshot in the app group, if there is a group and a snapshot in it.
///
/// The group is looked for the way the app looks for it (`AppGroup`): Info.plist's, then
/// `group.` + the containing app's bundle identifier as installed — read from the app's own
/// Info.plist two folders up, or failing that the widget's identifier less its last part. A
/// sideloading tool that renamed everything is followed; one that granted no group leaves this
/// `nil`, and the widget says to open the app.
enum SharedSnapshot {
    static func read() -> TodaySnapshot? {
        guard let container else { return nil }
        return TodaySnapshotStore(directory: container).read()
    }

    private static var container: URL? {
        let widget = Bundle.main
        let app = AppGroup.containingAppURL(ofExtensionAt: widget.bundleURL)
            .flatMap { Bundle(url: $0) }
        let host = AppGroup.hostBundleIdentifier(
            containingAppIdentifier: app?.bundleIdentifier,
            extensionIdentifier: widget.bundleIdentifier)
        let candidates = AppGroup.candidates(
            configured: widget.object(forInfoDictionaryKey: AppGroup.infoKey) as? String,
            hostBundleIdentifier: host)
        return AppGroup.resolve(candidates: candidates, container: AppGroup.systemContainer)?.url
    }
}
