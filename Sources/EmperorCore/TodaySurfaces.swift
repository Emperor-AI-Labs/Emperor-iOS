import Foundation

// The app's side of "what's listed today" outside the app: the snapshot the Today widget reads,
// and where the app's own links lead. The widget's side — reading the snapshot and deciding what
// to draw — is in `Today/`, which the widget compiles; this file is the app's alone, because it
// reads cause-list rows the widget never sees.

// MARK: - From the cause list

extension TodayMatter {
    /// A cause-list row, reduced to what a widget line or a Siri answer says — the room, item and
    /// time the app's own row prints (`CauseListingDisplay`), never more.
    init(_ listing: CauseListing) {
        let display = listing.display
        self.init(
            caseID: listing.caseID,
            title: TodayMatter.clipped(listing.displayTitle),
            court: listing.courtName.flatMap(CauseListText.trimmed),
            room: display.room,
            item: display.item,
            time: display.time)
    }

    /// The longest title kept. A cause title can run to a paragraph, and no widget line or spoken
    /// answer shows more than this; the file stays small for it.
    static let titleLength = 120

    static func clipped(_ title: String) -> String {
        guard title.count > titleLength else { return title }
        return title.prefix(titleLength - 1).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}

extension TodaySnapshot {
    /// The snapshot for these listings: the days from today in India through the horizon, each in
    /// the order it will run.
    ///
    /// The cause list alone, as the hearing notifications use it (`NotificationPlanner`) — the
    /// docket's next dates are merged in by the Calendar from a separate cache entry the widget's
    /// moment of writing does not have. On a fresh pair of responses the two agree, because the
    /// cause list already carries every case's next date (`CalendarListings`).
    static func make(
        listings: [CauseListing], fetchedAt: Date?, now: Date,
        horizonDays: Int = horizonDays, mattersPerDay: Int = mattersPerDay
    ) -> TodaySnapshot {
        let today = IndianDay.key(now)
        let lastDay = IndianDay.adding(max(1, horizonDays) - 1, to: today) ?? today
        // Narrowed first: the cause list is the whole hearing history, and ordering a day runs a
        // dozen regular expressions per row.
        let window = listings.filter { $0.date >= today && $0.date <= lastDay }
        let byDay = CalendarListings.byDay(causeList: window, cases: [])
        let days = byDay.keys.sorted().compactMap { key -> TodayDay? in
            guard let rows = byDay[key], !rows.isEmpty else { return nil }
            return TodayDay(
                day: key, total: rows.count,
                matters: rows.prefix(max(0, mattersPerDay)).map(TodayMatter.init))
        }
        return TodaySnapshot(
            isSignedIn: true, generatedAt: now, fetchedAt: fetchedAt,
            firstDay: today, lastDay: lastDay, days: days)
    }
}

// MARK: - Keeping the widget's snapshot current

/// Writes the Today widget's snapshot whenever what it should show changes, and asks the widget
/// to redraw.
///
/// ## When it writes
///
/// - **The cause list was saved** — by any screen, or by a background refresh (`publish`). The
///   cache's write hook is the one place every fetch passes through (`NotifyingCacheStore`).
/// - **The app came back, or someone signed in** (`refresh`) — only when the stored snapshot no
///   longer speaks for today, or for the wrong sign-in state. Coming back on a new day with no
///   new fetch still moves the week along, without decoding the whole cause list on every return.
/// - **Signing out** (`signedOut`) — an empty, signed-out snapshot replaces the account's.
///
/// ## When it does not
///
/// - **No app group** (`store` is `nil`): sideloaded without the entitlement, say. Nothing is
///   written and nothing fails; the widget shows "Open Emperor to load your listings".
/// - **Nothing changed**: the same days, re-fetched within the hour, are not rewritten. A widget
///   reload from the background counts against the system's daily allowance for it, and the
///   hourly background refresh would otherwise spend it on identical pictures.
/// - **No cause list cached**: an account that has never loaded one has nothing to say, and an
///   empty week written for it would read as a free week.
///
/// See `ChatViewModel` for why `@Observable` is not applied; nothing observes this.
@MainActor
final class TodaySnapshotPublisher {

    /// How long an identical snapshot is left alone before it is rewritten anyway, so the
    /// widget's "Updated …" stays roughly true.
    nonisolated static let rewriteAfter: TimeInterval = 60 * 60

    private let store: TodaySnapshotStore?
    private let reload: @MainActor () -> Void
    private let now: @Sendable () -> Date

    init(
        store: TodaySnapshotStore?,
        reload: @escaping @MainActor () -> Void,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.reload = reload
        self.now = now
    }

    /// The cause list was saved. Returns whether a new snapshot was written.
    @discardableResult
    func publish(listings: [CauseListing]?, fetchedAt: Date?) -> Bool {
        guard let store, let listings else { return false }
        let next = TodaySnapshot.make(listings: listings, fetchedAt: fetchedAt, now: now())
        if let stored = store.read(), stored.showsTheSameAs(next),
           !isNewerByMoreThanAnHour(next.fetchedAt, than: stored.fetchedAt) {
            return false
        }
        return write(next, to: store)
    }

    /// The app came back, or the account changed. Rewrites only when the stored snapshot is not
    /// today's, or not for this sign-in state; `cached` is read only then.
    @discardableResult
    func refresh(
        isSignedIn: Bool, cached: () -> (listings: [CauseListing], fetchedAt: Date?)?
    ) -> Bool {
        guard let store else { return false }
        guard isSignedIn else { return signedOut() }
        if let stored = store.read(), stored.isSignedIn,
           stored.firstDay == IndianDay.key(now()) {
            return false
        }
        guard let cached = cached() else { return false }
        return publish(listings: cached.listings, fetchedAt: cached.fetchedAt)
    }

    /// Signed out: the account's listings are replaced by nothing. Returns whether anything was
    /// written — not when the stored one already says signed out.
    @discardableResult
    func signedOut() -> Bool {
        guard let store else { return false }
        if let stored = store.read(), !stored.isSignedIn, stored.days.isEmpty { return false }
        return write(.signedOut(at: now()), to: store)
    }

    private func write(_ snapshot: TodaySnapshot, to store: TodaySnapshotStore) -> Bool {
        guard store.write(snapshot) else { return false }
        reload()
        return true
    }

    private func isNewerByMoreThanAnHour(_ fresh: Date?, than stored: Date?) -> Bool {
        guard let fresh else { return false }
        guard let stored else { return true }
        return fresh.timeIntervalSince(stored) > Self.rewriteAfter
    }
}

// MARK: - Links into the app

extension EmperorLink {
    /// Where the link leads, as the tap inbox carries it (`NotificationInbox`): the same two
    /// places a notification opens, so a widget tap and a notification tap take one path. A
    /// calendar link with no day opens on today, in India.
    func target(now: Date) -> NotificationTarget {
        switch self {
        case .calendar(let day): return .calendar(day: day ?? IndianDay.key(now))
        case .updates: return .updates
        }
    }
}
