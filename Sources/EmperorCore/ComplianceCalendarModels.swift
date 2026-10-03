import Foundation

// The Corporate Calendar: statutory deadlines from the platform's compliance pipeline.
//
// The web page is `src/pages/ComplianceCalendar.jsx`, reached from the mobile bar's role-gated
// "Corporate" tab (`src/shell/MobileNav.jsx`); this app reaches it from More, for every role —
// see `MainTabView` for why the bar differs. Its dated rows come from
// `GET /compliance-calendar`, which serialises `lib/complianceCalendarFeed.js`'s
// `toCalendarEvent` for every row of the pipeline's `compliance_master` table. Everything below
// was read off that function and `db/schedule.js`, not off the page.

/// One tracked statutory obligation, with the next date it falls due.
///
/// The route answers a **bare JSON array** of these — no `success` envelope — and spells most
/// keys twice, once in the pipeline's own vocabulary and once in the web page's
/// (`name`/`title`, `government_body`/`authority`, `notes`/`description`,
/// `next_due_date`/`dateKey`). Both are decoded so the client keeps working whichever half a
/// later change drops.
///
/// Every field but `id` is optional: the row is built by hand in `toCalendarEvent`, and a
/// missing column there should cost one detail, not the whole calendar.
struct StatutoryDeadline: Codable, Equatable, Identifiable, Sendable {
    /// `stat:<compliance_id>:<YYYY-MM-DD>`, or `…:na` for a row with no date.
    ///
    /// The same shape the web uses for the marker row that records "done", which is how a
    /// marker is matched back to its deadline (`ComplianceCalendar.jsx`, the `overrides` map).
    let id: String
    var complianceID: String?
    var name: String?
    var title: String?
    /// The pipeline's own classification — `universal` or `conditional`. Not the UI category.
    var applicability: String?
    /// The web's category taxonomy (`mca`, `gst`, …), or `null` for a body the feed has no
    /// mapping for. Kept as a string: an unknown value must still decode.
    var uiCategory: String?
    var governmentBody: String?
    var authority: String?
    var frequency: String?
    var notes: String?
    var detail: String?
    /// The pipeline's computed date. **Not always a date**: rows that need company context
    /// carry prose such as `"N/A - no company context"`, and an hours-based deadline carries a
    /// full ISO instant (`db/schedule.js`, `daysAfterEvent`). Read `dateKey` instead.
    var nextDueDateRaw: String?
    /// `YYYY-MM-DD`, or `null` whenever `next_due_date` is not exactly that shape. The web drops
    /// every row without one, and so does this client.
    var dateKey: String?
    var deadlineType: String?
    var deadlineValue: String?
    /// A `YYYY-MM-DD`, or the literal `NEEDS_VERIFICATION`.
    var lastVerifiedDate: String?
    var status: String?

    enum CodingKeys: String, CodingKey {
        case id, name, title, frequency, notes, authority, dateKey, status
        case complianceID = "compliance_id"
        case applicability = "category"
        case uiCategory = "ui_category"
        case governmentBody = "government_body"
        case detail = "description"
        case nextDueDateRaw = "next_due_date"
        case deadlineType = "deadline_type"
        case deadlineValue = "deadline_value"
        case lastVerifiedDate = "last_verified_date"
    }
}

extension StatutoryDeadline {
    /// The day this falls due, if it is one.
    ///
    /// Re-validated rather than trusted: `dateKey` is the server's regex test, and a value that
    /// passes it but is not a calendar day (`2026-02-30`) would otherwise sort and bucket as a
    /// date that does not exist.
    var dueDay: String? {
        guard let dateKey, dateKey.count == 10, let parsed = WireDate.parseDay(dateKey),
              WireDate.dayKey(parsed) == dateKey
        else { return nil }
        return dateKey
    }

    var displayTitle: String {
        for candidate in [title, name, complianceID] {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return "Statutory deadline"
    }

    /// Who the obligation is owed to — "MCA", "CBIC", "Income Tax Dept".
    var regulator: String? {
        for candidate in [authority, governmentBody] {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    var category: ComplianceCategory? { uiCategory.flatMap(ComplianceCategory.init(rawValue:)) }

    /// The pipeline's note on the obligation, which is where its caveats live — "QRMP filers:
    /// due 13th instead", "extended to 07-31 by RBI circular".
    var note: String? {
        for candidate in [detail, notes] {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    var frequencyLabel: String? {
        guard let raw = frequency?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }
        switch raw.lowercased() {
        case "annual": return "Annual"
        case "monthly": return "Monthly"
        case "quarterly": return "Quarterly"
        case "half_yearly": return "Half-yearly"
        case "event_based": return "When an event occurs"
        case "ongoing": return "Ongoing"
        case "decennial": return "Every ten years"
        case "varies": return "Varies"
        default:
            let spaced = raw.replacingOccurrences(of: "_", with: " ")
            return spaced.prefix(1).uppercased() + spaced.dropFirst()
        }
    }

    var schedule: DeadlineSchedule? {
        DeadlineSchedule(type: deadlineType, value: deadlineValue)
    }

    var verification: DeadlineVerification {
        DeadlineVerification(raw: lastVerifiedDate)
    }

    /// Whether the date shown is not the one the obligation's usual rule produces.
    ///
    /// The pipeline never edits a rule. When a notification moves a deadline it writes a
    /// one-off `next_occurrence_override`, which the route then reports as the next date while
    /// `deadline_value` still describes the usual one (`db/schedule.js`, `computeNextDueDate`;
    /// `pipeline/publish.js`). The override itself is not in the response, so it is recognised
    /// by its effect: a fixed-date rule whose dates do not include this day, or a relative rule
    /// — "within 30 days of the AGM" — that has a date at all, which without company context it
    /// can only have been given.
    ///
    /// Said on screen because the alternative is a page reading "by the 20th of every month"
    /// directly above "due 25 October", with nothing to reconcile the two.
    var differsFromUsualSchedule: Bool {
        guard let day = dueDay, let schedule else { return false }
        switch schedule {
        case .monthly(let dayOfMonth):
            return Int(day.suffix(2)) != dayOfMonth
        case .annual(let date), .window(_, let date):
            return date.monthDay != String(day.suffix(5))
        case .fixedDates(let dates):
            return !dates.contains { $0.monthDay == String(day.suffix(5)) }
        case .afterAGM, .afterEvent, .afterFinancialYearEnd:
            return true
        }
    }
}

// MARK: - Category

/// The web's category taxonomy for statutory deadlines.
///
/// Labels and order are `CATEGORY_META` and `CATEGORY_ORDER` from
/// `src/lib/complianceSchedule.js`, which is what the page's filter chips are built from. The
/// colours there are not carried over: every colour in this app comes from the contrast-checked
/// `Palette`, so a category is told apart by its symbol instead — which also survives greyscale
/// and colour blindness, where twelve hues 30° apart do not.
enum ComplianceCategory: String, CaseIterable, Identifiable, Sendable {
    case mca, incometax, tds, gst, epf, labour, sebi, fema, cyber, trade, licensing, ip

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mca: return "MCA / ROC"
        case .incometax: return "Income Tax"
        case .tds: return "TDS / TCS"
        case .gst: return "GST"
        case .epf: return "EPF & ESI"
        case .labour: return "Labour & POSH"
        case .sebi: return "SEBI (listed)"
        case .fema: return "FEMA / RBI"
        case .cyber: return "Cyber & Data"
        case .trade: return "Trade / Exports"
        case .licensing: return "Sector Licensing"
        case .ip: return "IP / Trademark"
        }
    }

    /// Chosen to read as the web's `lucide` icon for the same category (`CATEGORY_ICONS`).
    var systemImage: String {
        switch self {
        case .mca: return "building.2"
        case .incometax: return "building.columns"
        case .tds: return "doc.text"
        case .gst: return "percent"
        case .epf: return "person.3"
        case .labour: return "checkmark.shield"
        case .sebi: return "chart.line.uptrend.xyaxis"
        case .fema: return "globe"
        case .cyber: return "exclamationmark.shield"
        case .trade: return "shippingbox"
        case .licensing: return "checklist"
        case .ip: return "c.circle"
        }
    }
}

// MARK: - Urgency

/// How pressing a deadline is — the web's `urgency()` and `urgencyLabel()`.
///
/// The thresholds are the platform's: anything past due and still open is overdue, and anything
/// due within seven days, today included, is due soon. Counted in India's days, because a
/// statutory date is a day in India wherever the reader is.
enum DeadlineUrgency: Equatable, Sendable {
    /// Marked done — on the web, which is where that is recorded.
    case done
    case overdue(days: Int)
    /// Due in 0...7 days.
    case dueSoon(days: Int)
    case upcoming(days: Int)

    /// How a screen should weight it. A core type rather than a colour, so the rule is tested
    /// here and the view only maps it to the theme.
    enum Emphasis: Equatable, Sendable { case neutral, success, warning, danger }

    static let dueSoonWindow = 7

    init(daysUntilDue days: Int, isDone: Bool) {
        if isDone {
            self = .done
        } else if days < 0 {
            self = .overdue(days: -days)
        } else if days <= Self.dueSoonWindow {
            self = .dueSoon(days: days)
        } else {
            self = .upcoming(days: days)
        }
    }

    var label: String {
        switch self {
        case .done: return "Done"
        case .overdue(let days): return days == 1 ? "1 day overdue" : "\(days) days overdue"
        case .dueSoon(0): return "Due today"
        case .dueSoon(1): return "Due tomorrow"
        case .dueSoon(let days): return "Due in \(days) days"
        case .upcoming(let days): return "In \(days) days"
        }
    }

    var emphasis: Emphasis {
        switch self {
        case .done: return .success
        case .overdue: return .danger
        case .dueSoon: return .warning
        case .upcoming: return .neutral
        }
    }

    var isOpenAndPast: Bool {
        if case .overdue = self { return true }
        return false
    }
}

// MARK: - Schedule

/// An obligation's usual rule, from `deadline_type` and `deadline_value`.
///
/// Every case is one `computeNextDueDate` in `db/schedule.js` handles, and the value formats are
/// the ones it parses. A value it would refuse (`"NA"`, an unknown type, a malformed list) is
/// `nil` here, so the screen says nothing rather than something invented.
enum DeadlineSchedule: Equatable, Sendable {
    struct MonthDay: Equatable, Sendable {
        let month: Int
        let day: Int

        /// `MM-DD`, the shape the rule is written in.
        var monthDay: String { String(format: "%02d-%02d", month, day) }

        var label: String { "\(day) \(CourtCalendar.monthNames[month - 1])" }

        init?(_ raw: Substring) {
            let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: "-")
            guard parts.count == 2, let month = Int(parts[0]), let day = Int(parts[1]),
                  (1...12).contains(month), (1...31).contains(day)
            else { return nil }
            self.month = month
            self.day = day
        }
    }

    case monthly(day: Int)
    case annual(MonthDay)
    /// Quarterly and half-yearly rules: a list of fixed dates each year.
    case fixedDates([MonthDay])
    /// A window each year; the deadline is its end.
    case window(opens: MonthDay, closes: MonthDay)
    case afterAGM(days: Int)
    case afterEvent(amount: Int, unit: Unit, event: String)
    case afterFinancialYearEnd(days: Int)

    enum Unit: Equatable, Sendable { case days, hours }

    init?(type: String?, value: String?) {
        guard let type, let value = value?.trimmingCharacters(in: .whitespaces),
              !value.isEmpty, value != "NA"
        else { return nil }
        switch type {
        case "monthly_fixed_day":
            guard let day = Int(value), (1...31).contains(day) else { return nil }
            self = .monthly(day: day)
        case "fixed_annual_date":
            guard let date = MonthDay(Substring(value)) else { return nil }
            self = .annual(date)
        case "quarterly_fixed_dates", "half_yearly_fixed_dates":
            let dates = value.split(separator: ",").compactMap(MonthDay.init)
            guard !dates.isEmpty, dates.count == value.split(separator: ",").count else {
                return nil
            }
            self = .fixedDates(dates)
        case "annual_window":
            let ends = value.split(separator: ":")
            guard ends.count == 2, let opens = MonthDay(ends[0]), let closes = MonthDay(ends[1])
            else { return nil }
            self = .window(opens: opens, closes: closes)
        case "days_after_agm":
            guard let days = Int(value), days >= 0 else { return nil }
            self = .afterAGM(days: days)
        case "days_after_event", "hours_after_event":
            let parts = value.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let amount = Int(parts[0]), amount >= 0 else { return nil }
            let event = parts[1].replacingOccurrences(of: "_", with: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !event.isEmpty else { return nil }
            self = .afterEvent(
                amount: amount, unit: type == "hours_after_event" ? .hours : .days, event: event)
        case "days_after_fy_end":
            guard let days = Int(value), days >= 0 else { return nil }
            self = .afterFinancialYearEnd(days: days)
        default:
            return nil
        }
    }

    /// The rule in a sentence — "By the 20th of every month".
    var summary: String {
        switch self {
        case .monthly(let day):
            return "By the \(CourtCalendar.ordinal(day)) of every month"
        case .annual(let date):
            return "By \(date.label) every year"
        case .fixedDates(let dates):
            return "On \(DisplayText.list(dates.map(\.label))) each year"
        case .window(let opens, let closes):
            return "Between \(opens.label) and \(closes.label) every year"
        case .afterAGM(let days):
            return "Within \(Self.count(days, "day")) of the AGM"
        case .afterEvent(let amount, let unit, let event):
            // The event named in brackets rather than with an article: the pipeline's names
            // ("invoice raised", "share allotment private placement") are labels, not nouns
            // that take "a" or "an" gracefully.
            let noun = unit == .hours ? "hour" : "day"
            return "Within \(Self.count(amount, noun)) of the event (\(event))"
        case .afterFinancialYearEnd(let days):
            return "Within \(Self.count(days, "day")) of the financial year end"
        }
    }

    private static func count(_ amount: Int, _ noun: String) -> String {
        amount == 1 ? "1 \(noun)" : "\(amount) \(noun)s"
    }
}

// MARK: - Verification

/// When the pipeline last confirmed the obligation against its regulator.
enum DeadlineVerification: Equatable, Sendable {
    /// Confirmed on this `YYYY-MM-DD`.
    case checked(String)
    /// The pipeline's own marker that the rule has not been confirmed. Shown, because a lawyer
    /// filing against an unconfirmed date needs to know it is one.
    case unconfirmed
    case unknown

    init(raw: String?) {
        let trimmed = raw?.trimmingCharacters(in: .whitespaces) ?? ""
        if trimmed.uppercased() == "NEEDS_VERIFICATION" {
            self = .unconfirmed
        } else if trimmed.count == 10, WireDate.parseDay(trimmed) != nil {
            self = .checked(trimmed)
        } else {
            self = .unknown
        }
    }
}

// MARK: - Days in India

/// Day arithmetic on `YYYY-MM-DD` keys, in India.
///
/// Hand-rolled names rather than a `DateFormatter`: the strings are fixed English, and building
/// them from arrays keeps the core free of locale-dependent formatting that would read
/// differently on a device set to another language than in these tests.
enum CourtCalendar {
    static let monthNames = [
        "January", "February", "March", "April", "May", "June", "July", "August", "September",
        "October", "November", "December",
    ]
    static let weekdayAbbreviations = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = WireDate.india
        return calendar
    }

    /// Whole days from one key to another; negative when `to` is earlier.
    ///
    /// Both keys parse to midnight in India, which keeps no daylight saving, so the difference
    /// is an exact multiple of a day and division cannot be off by one.
    static func days(from: String, to: String) -> Int? {
        guard let start = WireDate.parseDay(from), let end = WireDate.parseDay(to) else {
            return nil
        }
        return Int((end.timeIntervalSince(start) / 86_400).rounded())
    }

    /// "October 2026", for a key or a `YYYY-MM` prefix.
    static func monthTitle(_ key: String) -> String? {
        let parts = key.split(separator: "-")
        guard parts.count >= 2, let year = Int(parts[0]), let month = Int(parts[1]),
              (1...12).contains(month)
        else { return nil }
        return "\(monthNames[month - 1]) \(year)"
    }

    /// The parts of a calendar tile: "Sat", "31", "Oct".
    static func tile(_ key: String) -> (weekday: String, day: String, month: String)? {
        guard let date = WireDate.parseDay(key) else { return nil }
        let components = calendar.dateComponents([.weekday, .day, .month], from: date)
        guard let weekday = components.weekday, let day = components.day,
              let month = components.month
        else { return nil }
        return (
            weekdayAbbreviations[weekday - 1], String(day), String(monthNames[month - 1].prefix(3))
        )
    }

    /// 1st, 2nd, 3rd, 4th … 11th, 12th, 13th … 21st, 22nd, 23rd … 31st.
    static func ordinal(_ number: Int) -> String {
        let lastTwo = number % 100
        if (11...13).contains(lastTwo) { return "\(number)th" }
        switch number % 10 {
        case 1: return "\(number)st"
        case 2: return "\(number)nd"
        case 3: return "\(number)rd"
        default: return "\(number)th"
        }
    }
}
