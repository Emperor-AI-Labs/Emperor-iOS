import Foundation

/// The case listings the Calendar shows on each day: every matter the user is listed in, in the
/// order the day will run.
///
/// ## Two sources, one row per matter per day
///
/// The cause list (`GET /cause-list`) is the primary source. It already carries a `"next"` entry
/// for every case's next hearing date (`sync-server.js`, `/cause-list`, the second `pushEntry`
/// pass), so on a fresh pair of responses the docket adds nothing. It is merged in anyway because
/// the two are separate requests, cached separately: a matter added on the web between them, or
/// a cause list served from the cache while the docket is live, would otherwise leave a hearing
/// date the user can see on the Cases tab missing from the day it falls on.
///
/// De-duplication is per **matter and day**, never per matter. A matter with a listing on the
/// 14th and a next date on the 20th belongs on both days; collapsing by case alone would drop
/// whichever came second, and that is a hearing the calendar would then say is not happening.
///
/// ## Every date is a day in India
///
/// A listing's `date` is already the server's `YYYY-MM-DD` and is used as given. A case's
/// `next_hearing_date` is read the way the server's own `toDay` reads it when it builds the
/// `"next"` entry — the leading `YYYY-MM-DD`, with no zone conversion — so that the two sources
/// put one hearing on the same day and the de-duplication can see it. Converting a stored
/// timestamp through a zone here would move it to a day the cause list does not have it on, and
/// the same hearing would be printed twice, a day apart. Anything that is not an ISO date is left
/// to the cause list, which the server has already bucketed. See `WireDate` and README trap 9.
///
/// ## The order of a day
///
/// By sitting time, earliest first — the product owner's rule for this screen, because a day in
/// court is lived by the clock. A listing whose list printed no time comes after every timed one,
/// since "no time printed" is not "first thing in the morning". Ties, and the untimed rows, fall
/// through to the order Home walks a day in — forum, then courtroom by number, then item by
/// number (`CauseListViewModel.sortKey`) — so the two screens can never order the same matters
/// differently.
enum CalendarListings {

    // MARK: - Building the days

    /// Every day that has a listing, mapped to that day's listings in calendar order.
    ///
    /// Built once per load rather than per day asked for: the cause list is the whole hearing
    /// history, the grid asks about forty-odd days per render, and each row's sort key comes from
    /// a dozen regular expressions.
    static func byDay(causeList: [CauseListing], cases: [LegalCase]) -> [String: [CauseListing]] {
        var days: [String: [CauseListing]] = [:]
        var seen = Set<MatterDay>()

        // The cause list first, so that where both sources have a matter on a day, the row kept
        // is the one carrying the room, item and time that day's list printed. Within the cause
        // list the first entry wins, which is the server's own rule — its `seen` set keeps the
        // first `(case, date)` it pushes.
        for listing in causeList {
            let key = MatterDay(caseID: listing.caseID, day: listing.date)
            guard seen.insert(key).inserted else { continue }
            days[listing.date, default: []].append(listing)
        }
        for legalCase in cases {
            guard let day = hearingDay(of: legalCase) else { continue }
            let key = MatterDay(caseID: legalCase.id, day: day)
            guard seen.insert(key).inserted else { continue }
            days[day, default: []].append(listing(for: legalCase, on: day))
        }

        return days.mapValues(sorted)
    }

    /// The day a case's next hearing falls on, as the server's `/cause-list` reads it: the
    /// leading `YYYY-MM-DD` of the stored value, or nothing when the value does not start with a
    /// real date.
    static func hearingDay(of legalCase: LegalCase) -> String? {
        guard let raw = legalCase.nextHearingDateRaw?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            raw.count >= 10
        else { return nil }
        let prefix = String(raw.prefix(10))
        // Checked by round trip rather than by shape alone, so "2026-02-30" — which a lenient
        // reading would roll into March — is not a day.
        guard prefix.utf8.count == 10,
              let parsed = WireDate.parseDay(prefix),
              WireDate.dayKey(parsed) == prefix
        else { return nil }
        return prefix
    }

    /// A listing for a matter the cause list does not carry on that day, built from the case.
    ///
    /// The fields the server's own `"next"` entry carries for the same case
    /// (`sync-server.js`, `/cause-list`, pass 2), minus the `courtNo` and `itemNo` it derives
    /// from the case's bench and stage. This row does not come from any day's published list,
    /// and a case's bench can be a roster code rather than a room (Delhi's "Court 236"), so it
    /// sets neither: `CauseListingDisplay` applies its ordinary rules for a row that was not
    /// read off a court's list, and a bench that is only a room number is then neither a room nor
    /// a coram.
    static func listing(for legalCase: LegalCase, on day: String) -> CauseListing {
        var listing = CauseListing(date: day, caseID: legalCase.id)
        listing.teamID = legalCase.teamID
        listing.title = legalCase.displayTitle
        listing.parties = legalCase.parties
        listing.courtName = legalCase.courtName
        listing.courtType = legalCase.courtType
        listing.caseType = legalCase.caseType
        listing.caseNumber = legalCase.caseNumber
        listing.caseYear = legalCase.caseYear
        // The server folds the diary number into `cnr` when there is no CNR.
        listing.cnr = legalCase.cnr ?? legalCase.diaryNumber
        listing.diaryNumber = legalCase.diaryNumber
        listing.category = legalCase.category
        // `CauseListText.coram` drops a bench that is only a courtroom, or the forum's own name,
        // exactly as the server's `judgeAsCoram` does.
        listing.judge = legalCase.judge
        listing.coram = legalCase.judge
        listing.purpose = "Next hearing"
        listing.stage = legalCase.stage
        listing.source = "next"
        listing.ndoh = day
        return listing
    }

    // MARK: - Ordering

    /// One day's listings in calendar order. See the type's documentation for the rule.
    static func sorted(_ listings: [CauseListing]) -> [CauseListing] {
        listings
            .map { ($0, OrderKey($0)) }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    /// The sitting time a list printed, as minutes after midnight — or `nil` when there is none
    /// that can be read.
    ///
    /// Read for ordering only. The row prints the list's own words; nothing here is ever shown,
    /// because a time the list did not print is exactly the helpful guess that costs a matter.
    ///
    /// Court lists print "10:30 AM" (the Supreme Court's, as the platform's scraper writes it),
    /// and sometimes "10.30 a.m." or "Not before 2:30 P.M."; a 24-hour "14:30" is read as
    /// written. The first time in the text is the one used.
    static func minutes(fromSittingTime text: String?) -> Int? {
        guard let text, !text.isEmpty else { return nil }
        if let groups = Patterns.shared.twelveHour.groups(in: text),
           let hourText = groups[1], let hour = Int(hourText), (1...12).contains(hour) {
            let minute = groups[2].flatMap { Int($0) } ?? 0
            guard (0...59).contains(minute) else { return nil }
            let isAfternoon = groups[3]?.lowercased() == "p"
            return ((hour % 12) + (isAfternoon ? 12 : 0)) * 60 + minute
        }
        if let groups = Patterns.shared.twentyFourHour.groups(in: text),
           let hour = groups[1].flatMap({ Int($0) }), let minute = groups[2].flatMap({ Int($0) }),
           (0...23).contains(hour), (0...59).contains(minute) {
            return hour * 60 + minute
        }
        return nil
    }

    /// The key a day is sorted on: timed rows before untimed, then by time, then Home's order.
    ///
    /// Compared field by field rather than as one tuple, because Swift's tuple comparison stops
    /// at six elements and Home's key alone is six.
    private struct OrderKey: Comparable {
        let isUntimed: Bool
        let minutes: Int
        let home: (String, Int, String, Int, String, String)

        init(_ listing: CauseListing) {
            let minutes = CalendarListings.minutes(fromSittingTime: listing.display.time)
            isUntimed = minutes == nil
            self.minutes = minutes ?? 0
            home = CauseListViewModel.sortKey(listing)
        }

        static func < (lhs: OrderKey, rhs: OrderKey) -> Bool {
            if lhs.isUntimed != rhs.isUntimed { return !lhs.isUntimed }
            if lhs.minutes != rhs.minutes { return lhs.minutes < rhs.minutes }
            return lhs.home < rhs.home
        }

        static func == (lhs: OrderKey, rhs: OrderKey) -> Bool {
            lhs.isUntimed == rhs.isUntimed && lhs.minutes == rhs.minutes && lhs.home == rhs.home
        }
    }

    private struct MatterDay: Hashable {
        let caseID: String
        let day: String
    }

    /// ASCII digits only, as in `CauseListText`: ICU's `\d` also matches Devanagari digits.
    private struct Patterns: Sendable {
        static let shared = Patterns()

        /// "10:30 AM", "10.30 a.m.", "2 PM".
        let twelveHour = CauseListText.Pattern(
            #"(?<![0-9])([0-9]{1,2})(?:[:.]([0-9]{2}))?\s*([ap])\.?\s*m(?![a-z])"#)
        /// "14:30", "9.15".
        let twentyFourHour = CauseListText.Pattern(
            #"(?<![0-9])([0-9]{1,2})[:.]([0-9]{2})(?![0-9])"#)
    }
}

extension CauseListingDisplay {
    /// The small line under the title without the time, for a row that already leads with it.
    var detailLineWithoutTime: String? {
        let parts = [reference, advocates].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The whole row as one sentence for VoiceOver, for a row that leads with its sitting time:
    /// the time first, because that is what the Calendar orders the day by.
    func spokenLeadingWithTime(_ listing: CauseListing) -> String {
        let rest = [
            spokenLocation, listing.displayTitle, forum(courtName: listing.courtName),
            detailLineWithoutTime, note, listing.remarks.flatMap { CauseListText.trimmed($0) },
        ]
        return ([time] + rest).compactMap { $0 }.joined(separator: ". ")
    }
}

/// What a cell of the month grid says about its day.
enum CalendarDayMark: Equatable, Sendable {
    /// Nothing on it.
    case clear
    /// Only the user's own diary entries.
    case diary
    /// At least one of the user's matters is listed — whatever else is on the day.
    case listed

    /// For VoiceOver, which cannot see the dot's colour.
    var spoken: String {
        switch self {
        case .clear: return "Nothing scheduled"
        case .diary: return "Diary entries"
        case .listed: return "Cases listed"
        }
    }
}
