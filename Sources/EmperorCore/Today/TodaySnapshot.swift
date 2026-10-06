import Foundation

/// What the Today widget is allowed to know: the next few days of the person's listings, and
/// nothing else.
///
/// ## Why a snapshot
///
/// A widget runs in its own process, on the system's schedule, often with the phone locked. It
/// cannot read the Keychain the token lives in, and it should not try to reach the server — a
/// widget that fetches is a widget that shows a spinner, burns battery and holds a credential. So
/// the app writes this small file into the shared app-group container whenever it saves the cause
/// list (`TodaySnapshotPublisher`), and the widget only ever reads it.
///
/// It carries **no token, no account details and no history** — only what the widget draws: the
/// matters listed over the next `TodaySnapshot.horizonDays` days, when the list was fetched, and
/// whether anyone is signed in. Signing out overwrites it with an empty, signed-out one.
///
/// Days are India's `YYYY-MM-DD` keys, as everywhere else (README trap 9). The widget decides
/// which of them is "today" when it draws (`TodayGlance`), so a snapshot written on Monday still
/// shows Tuesday's listings on Tuesday without the app having run.
struct TodaySnapshot: Codable, Equatable, Sendable {

    /// Bumped when the shape changes. A reader that finds another version treats the file as
    /// absent — the widget says to open the app, which writes a current one.
    static let currentVersion = 1

    /// How many days ahead it carries, today included. A week: enough to answer "when am I next
    /// in court" on a quiet day, short enough that a phone left unopened for a week stops showing
    /// listings rather than showing ones the court sync may since have moved.
    static let horizonDays = 7

    /// The most matters kept for one day. The large widget shows six; `TodayDay.total` keeps the
    /// real count for "and 4 more".
    static let mattersPerDay = 8

    var version: Int
    /// Whether someone was signed in when it was written. A signed-out snapshot has no days.
    var isSignedIn: Bool
    /// When it was written.
    var generatedAt: Date
    /// When the cause list it was made from came from the server — the age a person judges it
    /// by. `nil` when signed out.
    var fetchedAt: Date?
    /// The first and last days it speaks for. A day in that range with no entry in `days` has
    /// nothing listed; a day outside it is unknown, never "nothing listed".
    var firstDay: String
    var lastDay: String
    /// The days that have listings, soonest first, each in the order it will run.
    var days: [TodayDay]

    init(
        isSignedIn: Bool, generatedAt: Date, fetchedAt: Date?,
        firstDay: String, lastDay: String, days: [TodayDay]
    ) {
        self.version = Self.currentVersion
        self.isSignedIn = isSignedIn
        self.generatedAt = generatedAt
        self.fetchedAt = fetchedAt
        self.firstDay = firstDay
        self.lastDay = lastDay
        self.days = days
    }

    /// Nobody signed in: nothing about any account, and nothing for the widget to show.
    static func signedOut(at now: Date) -> TodaySnapshot {
        let today = IndianDay.key(now)
        return TodaySnapshot(
            isSignedIn: false, generatedAt: now, fetchedAt: nil,
            firstDay: today, lastDay: today, days: [])
    }

    /// Whether two snapshots would draw the same widget, ignoring when each was written and
    /// fetched — what decides whether a new one is worth a timeline reload.
    func showsTheSameAs(_ other: TodaySnapshot) -> Bool {
        isSignedIn == other.isSignedIn && firstDay == other.firstDay
            && lastDay == other.lastDay && days == other.days
    }
}

/// One day with listings.
struct TodayDay: Codable, Equatable, Sendable {
    /// India's `YYYY-MM-DD`.
    var day: String
    /// How many matters are listed — more than `matters` holds on a long day.
    var total: Int
    /// The first `TodaySnapshot.mattersPerDay` of them, in the order the day will run.
    var matters: [TodayMatter]
}

/// One listed matter, reduced to what a widget line or a Siri answer says.
///
/// Every field is the one the app's own row prints (`CauseListingDisplay`), so the widget can
/// never send someone to a different courtroom from the one the app shows. Nothing is guessed to
/// fill a gap: a row whose list printed no item has no item here.
struct TodayMatter: Codable, Equatable, Sendable, Identifiable {
    var caseID: String
    var title: String
    /// The forum — "Bombay High Court".
    var court: String?
    /// The courtroom as a label — "Court 12", "Registrar Court 1".
    var room: String?
    /// The item number in that day's list.
    var item: String?
    /// The sitting time, where the list printed one — "10:30 AM".
    var time: String?

    /// One matter appears once on a day (`CalendarListings`), so its case is its identity there.
    var id: String { caseID }
}

/// The snapshot on disk, in a directory — the app group's container, in practice.
///
/// Reads never throw: a missing, unreadable or foreign file is simply "no snapshot", which the
/// widget shows as "Open Emperor to load your listings". The widget must never crash over a file.
struct TodaySnapshotStore: Sendable {
    static let fileName = "today-snapshot.json"

    let directory: URL

    var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    func read() -> TodaySnapshot? {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? Self.decoder.decode(TodaySnapshot.self, from: data),
              snapshot.version == TodaySnapshot.currentVersion
        else { return nil }
        return snapshot
    }

    /// Replaces the file in one step, so the widget never reads half of one. Returns whether it
    /// was written.
    @discardableResult
    func write(_ snapshot: TodaySnapshot) -> Bool {
        guard let data = try? Self.encoder.encode(snapshot) else { return false }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        // Readable once the phone has been unlocked after starting up, which is when widgets
        // are drawn — `.complete` would leave a locked phone's widget with nothing to read. The
        // matter names are still encrypted at rest until that first unlock.
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        do {
            try data.write(to: fileURL, options: options)
            return true
        } catch {
            return false
        }
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
