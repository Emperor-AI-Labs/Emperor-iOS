import Foundation

/// One local notification, as the app means it — independent of `UserNotifications`, so what is
/// said and when can be tested without a device.
struct PlannedNotification: Equatable, Sendable {
    enum Kind: String, Sendable {
        /// The morning of a day with listings.
        case briefing
        /// The evening before one.
        case evening
        /// A new item in the account's notification feed.
        case update
        /// "Send a test notification", from Settings.
        case test
    }

    /// Stable for the thing it is about, so scheduling it again replaces it rather than adding a
    /// second copy — iOS keys pending requests by identifier.
    let identifier: String
    let kind: Kind
    let title: String
    let body: String
    /// When it should arrive, or `nil` for at once.
    let fireDate: Date?
    /// What tapping it opens — see `NotificationTarget`. `nil` opens the app where it was.
    let target: NotificationTarget?

    /// Groups a day's briefings apart from feed updates in Notification Centre.
    var threadIdentifier: String {
        switch kind {
        case .briefing, .evening: return "hearings"
        case .update: return "updates"
        case .test: return "test"
        }
    }
}

/// The local notifications to have pending, given the cause list.
///
/// ## Why the device schedules them
///
/// The platform's daily briefing goes by email and browser push (`lib/dailyNotify.js`); it has
/// no way to reach an iPhone. So the app schedules its own reminders from the cause list it
/// already holds, re-plans whenever it learns something new — at launch, on returning to it,
/// whenever a screen loads the cause list, and from a background refresh — and replaces what is
/// pending each time.
///
/// ## The rules
///
/// - **Only days with listings.** There is never a "nothing listed today" notification. This
///   list is the person's own matters, not the court's (`CauseListViewModel.Copy`), and a
///   message saying the day is clear is the one this product must never send.
/// - **Indian days.** A listing's `date` is India's `YYYY-MM-DD`, and a briefing at 08:00 is
///   08:00 in India — the instant is computed in IST and handed to the system as an instant, so a
///   device in another zone is told at the right moment rather than at its own 08:00.
/// - **Never in the past**, and never a day before today in India.
/// - **One identifier per day and kind** (`hearing.briefing.2026-10-14`), so re-planning replaces
///   rather than duplicates, and a changed time moves the notification instead of adding one.
/// - **Within iOS's limit.** The system keeps only the soonest 64 pending requests per app and
///   silently drops the rest. The plan stops short of that with a margin, and what it drops is
///   the furthest away — the next re-plan will pick those days up long before they are due.
enum NotificationPlanner {

    /// How far ahead to plan. Two weeks covers the next listing for nearly every matter, and a
    /// re-plan happens far more often than that.
    static let horizonDays = 14

    /// iOS keeps the soonest 64 pending requests; this leaves a margin under it.
    static let pendingLimit = 56

    /// Every identifier this planner issues starts with this, so a re-plan can find and remove
    /// the ones it no longer wants without touching anything else.
    static let identifierPrefix = "hearing."

    /// How many matters a notification names before saying how many more there are. A banner
    /// shows about four lines; the count is the headline.
    static let namedMatters = 3

    /// The longest case title printed in full. A title is often a whole cause title —
    /// "M/s. Something Private Limited & Ors. v. …" — and a banner would show nothing else.
    static let titleLength = 60

    static func identifier(_ kind: PlannedNotification.Kind, day: String) -> String {
        "\(identifierPrefix)\(kind.rawValue).\(day)"
    }

    /// What should be pending now, soonest first.
    ///
    /// Deterministic: the same listings, preferences and moment always give the same plan, in the
    /// same order, with the same identifiers — which is what lets the caller tell that nothing
    /// changed and leave the system's queue alone.
    static func plan(
        listings: [CauseListing],
        preferences: NotificationPreferences,
        now: Date,
        horizonDays: Int = horizonDays,
        limit: Int = pendingLimit
    ) -> [PlannedNotification] {
        guard preferences.isEnabled,
              preferences.morningBriefing || preferences.eveningReminder,
              horizonDays > 0, limit > 0
        else { return [] }

        let today = WireDate.dayKey(now)
        guard let todayStart = WireDate.parseDay(today) else { return [] }
        // The days in the window, as India's keys. Stepped in whole days from India's midnight,
        // which is exact because India keeps no daylight saving.
        let window = (0..<horizonDays).map {
            WireDate.dayKey(todayStart.addingTimeInterval(TimeInterval($0) * 86_400))
        }
        guard let lastDay = window.last else { return [] }

        // Narrowed before anything else: the cause list is the whole hearing history, and
        // ordering a day runs a dozen regular expressions per row.
        let upcoming = listings.filter { $0.date >= today && $0.date <= lastDay }
        // One row per matter per day, in the order the day will run — the Calendar's own rule,
        // so a briefing names matters in the order the Calendar it opens on lists them.
        let byDay = CalendarListings.byDay(causeList: upcoming, cases: [])

        var planned: [PlannedNotification] = []
        for day in window {
            guard let rows = byDay[day], !rows.isEmpty else { continue }
            if preferences.morningBriefing,
               let at = NotificationPreferences.instant(
                minutes: preferences.briefingMinutes, on: day),
               at > now {
                planned.append(PlannedNotification(
                    identifier: identifier(.briefing, day: day),
                    kind: .briefing,
                    title: "\(count(rows.count)) listed today",
                    body: summary(rows),
                    fireDate: at,
                    target: .calendar(day: day)))
            }
            if preferences.eveningReminder,
               let dayStart = WireDate.parseDay(day) {
                let at = dayStart.addingTimeInterval(
                    TimeInterval(preferences.reminderMinutes - 24 * 60) * 60)
                if at > now {
                    planned.append(PlannedNotification(
                        identifier: identifier(.evening, day: day),
                        kind: .evening,
                        title: "Tomorrow: \(count(rows.count)) listed",
                        body: summary(rows),
                        fireDate: at,
                        target: .calendar(day: day)))
                }
            }
        }

        // Soonest first, then by identifier so two at the same instant keep a fixed order.
        let ordered = planned.sorted {
            let lhs = $0.fireDate ?? now
            let rhs = $1.fireDate ?? now
            return lhs != rhs ? lhs < rhs : $0.identifier < $1.identifier
        }
        return Array(ordered.prefix(limit))
    }

    /// "1 matter", "12 matters".
    static func count(_ number: Int) -> String {
        number == 1 ? "1 matter" : "\(number) matters"
    }

    /// The first few matters of a day, one to a line, and how many more there are.
    static func summary(_ rows: [CauseListing]) -> String {
        var lines = rows.prefix(namedMatters).map(line)
        if rows.count > namedMatters {
            lines.append("and \(rows.count - namedMatters) more")
        }
        return lines.joined(separator: "\n")
    }

    /// "Bakshi v. State of Maharashtra — Court 12, item 7".
    ///
    /// The room and item are the ones the cause-list row prints (`CauseListingDisplay`), so the
    /// notification can never send someone to a different door from the one the app shows. A
    /// row that states neither is named alone — nothing is guessed to fill the gap.
    static func line(_ listing: CauseListing) -> String {
        let display = listing.display
        let location = [display.room, display.item.map { "item \($0)" }]
            .compactMap { $0 }
            .joined(separator: ", ")
        let title = clipped(listing.displayTitle)
        return location.isEmpty ? title : "\(title) — \(location)"
    }

    static func clipped(_ title: String) -> String {
        guard title.count > titleLength else { return title }
        let cut = title.prefix(titleLength - 1)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cut + "…"
    }

    /// What "Send a test notification" sends: what the real ones will be about, and when.
    static func test(preferences: NotificationPreferences) -> PlannedNotification {
        let when = NotificationPreferences.clock(preferences.briefingMinutes)
        return PlannedNotification(
            identifier: "test",
            kind: .test,
            title: "Notifications are on",
            body: "On days your matters are listed, the briefing arrives at \(when) IST.",
            fireDate: nil,
            target: nil)
    }
}

// MARK: - Feed updates

/// Which new items in the account's notification feed deserve a notification on this device.
///
/// The feed (`/notifications`) is the account's own — hearing dates the court sync found, orders,
/// team news — and the web shows it behind a bell. The phone has no push channel from the
/// server, so it looks at the feed itself, from a background refresh, and announces what arrived
/// since it last looked.
///
/// ## A first look announces nothing
///
/// With nothing remembered for this account — a new install, a new sign-in, updates just turned
/// on — the whole feed is taken as already seen. Otherwise the first refresh would fire one
/// notification per row of history, up to two hundred.
enum UpdateAlerts {
    /// The most announced in one look. Past that, the newest are announced and the rest wait in
    /// the Updates screen with its count — a stack of banners is noise, not news.
    static let cap = 3

    /// How many seen ids are remembered. The feed returns at most 200
    /// (`NotificationService.maximumLimit`); remembering more lets a short, unexpected answer —
    /// an empty list from a server having a bad moment — be told apart from a feed whose rows
    /// are all new when it recovers.
    static let rememberedLimit = 400

    /// What to announce, newest first, and the seen list to remember next.
    ///
    /// - Parameters:
    ///   - feed: the feed as the server ordered it, newest first. Never re-sorted: same-second
    ///     rows are ordered by a column the response does not carry (`NotificationService`).
    ///   - seen: what was remembered, or `nil` for a first look.
    static func diff(
        feed: [AppNotification], seen: [String]?
    ) -> (alerts: [AppNotification], seen: [String]) {
        let current = feed.map(\.id)
        guard let seen else {
            return ([], remembered(current, then: []))
        }
        let known = Set(seen)
        // Unread only: a row already read on the web has been seen by the person, if not here.
        let fresh = feed.filter { !known.contains($0.id) && !$0.isRead }
        return (Array(fresh.prefix(cap)), remembered(current, then: seen))
    }

    /// The current feed first, then what was remembered before and is no longer in it, without
    /// repeats, bounded.
    private static func remembered(_ current: [String], then earlier: [String]) -> [String] {
        var seen = Set<String>()
        var ids: [String] = []
        for id in current + earlier where seen.insert(id).inserted {
            ids.append(id)
            if ids.count == rememberedLimit { break }
        }
        return ids
    }

    static func identifier(for item: AppNotification) -> String { "update.\(item.id)" }

    /// The notification for one feed item: its own title and body, as the Updates screen shows
    /// them, falling back to what kind of update it is.
    static func notification(for item: AppNotification) -> PlannedNotification {
        let title = item.title.flatMap { CauseListText.trimmed($0) } ?? item.kind.label
        let body = item.body.flatMap { CauseListText.trimmed($0) } ?? ""
        return PlannedNotification(
            identifier: identifier(for: item),
            kind: .update,
            title: title,
            body: body,
            fireDate: nil,
            target: .updates)
    }
}

// MARK: - Taps

/// Where tapping a notification leads.
enum NotificationTarget: Equatable, Sendable {
    /// The Calendar, on a court day.
    case calendar(day: String)
    /// The Updates screen.
    case updates

    /// Carried in the notification's `userInfo`, which survives the app being killed between
    /// scheduling and the tap — so it is plain strings, read back by `init(userInfo:)`.
    var userInfo: [String: String] {
        switch self {
        case .calendar(let day): return ["target": "calendar", "day": day]
        case .updates: return ["target": "updates"]
        }
    }

    /// Reads a tapped notification's `userInfo`. `nil` for anything this build did not write,
    /// which is then simply opened to wherever the app was.
    init?(userInfo: [String: String]) {
        switch userInfo["target"] {
        case "calendar":
            // Checked by round trip, so a malformed day cannot open the Calendar somewhere odd.
            guard let day = userInfo["day"], let parsed = WireDate.parseDay(day),
                  WireDate.dayKey(parsed) == day
            else { return nil }
            self = .calendar(day: day)
        case "updates":
            self = .updates
        default:
            return nil
        }
    }
}
