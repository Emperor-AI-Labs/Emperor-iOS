import Foundation

// Wire models for the IBBI liquidation e-auction feed (`sync-server.js:10289-10405`).
//
// Two properties of the `auction_notices` table govern everything below.
//
// **Every column except `id` is nullable** (`sync-server.js:3584-3599`), and a substantial
// minority of rows carry `is_fallback = 1` — parsed from the IBBI listing page alone because
// the notice predates the digital-form rollout and there was no PDF to read
// (`court-scraper/adapters/ibbi-liquidation-auctions.js:320-333`). Such a row has a debtor
// name, perhaps a date, and nothing else. So no field may be assumed present, and no absence
// may be papered over with a dash where the gap changes what the row means.
//
// **One row carries two date encodings.** `auction_date`, `emd_last_date` and the rest of the
// date columns are bare `YYYY-MM-DD` days in India; `created_at`/`updated_at` are zoneless
// SQLite `CURRENT_TIMESTAMP` in UTC. That is CLAUDE.md gotcha 6 in a single object, and it is
// why each field goes through the matching `WireDate` entry point instead of one decoding
// strategy.

/// One auction notice.
struct AuctionNotice: Codable, Equatable, Identifiable, Sendable {
    /// The only non-optional field. `SELECT *` on a table whose `id` is the PRIMARY KEY always
    /// carries it; anything else here can and does arrive null.
    let id: String
    var uniqueNumber: String? = nil
    /// `"Issue of Auction Notice"`, `"Corrigendum"` or `"Addendum"`. See `AuctionNoticeType`.
    var typeOfAN: String? = nil
    var corporateDebtor: String? = nil
    var cin: String? = nil
    var insolvencyCommencementDateRaw: String? = nil
    var liquidationCommencementDateRaw: String? = nil
    var processNumber: String? = nil
    var dateIssuedRaw: String? = nil
    var auctionDateRaw: String? = nil
    var emdLastDateRaw: String? = nil
    /// Whole rupees. The ingest reduces the printed figure to digits and stores an integer or
    /// null (`ibbi-liquidation-auctions.js:114-118`), so this never arrives as a formatted
    /// string — but it is null far more often than a reader expects.
    var reservePrice: Int? = nil
    var emdAmount: Int? = nil
    var auctionPlatform: String? = nil
    var auctionPlatformURLRaw: String? = nil
    var natureOfAssets: String? = nil
    var assetLocation: String? = nil
    var liquidatorName: String? = nil
    var ipRegistrationNumber: String? = nil
    var noticePDFURLRaw: String? = nil
    var digitalPDFURLRaw: String? = nil
    /// The `unique_number` of the notice this one amends, for corrigenda and addenda.
    var supersedesUniqueNumber: String? = nil
    /// **The number 0 or 1, not a JSON boolean** — the same shape as `notifications.read`.
    /// Decoding it as `Bool` throws `typeMismatch` and takes the whole page down with it.
    var isFallbackRaw: Int? = nil
    var createdAtRaw: String? = nil
    var updatedAtRaw: String? = nil

    // MARK: - Dates

    var auctionDate: Date? { WireDate.parseDay(auctionDateRaw) }
    var emdLastDate: Date? { WireDate.parseDay(emdLastDateRaw) }
    var dateIssued: Date? { WireDate.parseDay(dateIssuedRaw) }
    var insolvencyCommencementDate: Date? { WireDate.parseDay(insolvencyCommencementDateRaw) }
    var liquidationCommencementDate: Date? { WireDate.parseDay(liquidationCommencementDateRaw) }

    /// Ingest time, not auction time. A different encoding from every date above.
    var createdAt: Date? { WireDate.parse(createdAtRaw) }
    var updatedAt: Date? { WireDate.parse(updatedAtRaw) }

    /// The auction day as a `YYYY-MM-DD` key, for comparing against India's today.
    ///
    /// Kept as a string rather than a `Date` for the reason `CauseListing.date` is: the column
    /// is a day in India, and turning it into an instant invites `Calendar.current`, which
    /// buckets it into the wrong day for anyone whose device is not on IST.
    var auctionDayKey: String? {
        guard let raw = auctionDateRaw?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.count >= 10
        else { return nil }
        return String(raw.prefix(10))
    }

    /// Where this auction stands relative to a given day in India.
    ///
    /// - Parameter today: a `YYYY-MM-DD` key from `WireDate.todayKey()`, never a device day.
    func status(today: String) -> AuctionStatus {
        guard let day = auctionDayKey else { return .undated }
        if day == today { return .today }
        return day > today ? .upcoming : .closed
    }

    // MARK: - Text

    var type: AuctionNoticeType { AuctionNoticeType(wire: typeOfAN) }

    var displayDebtor: String {
        let trimmed = corporateDebtor?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Corporate debtor not named" : trimmed
    }

    /// The notice's own reference number, when it has one.
    ///
    /// `unique_number` is **not always a reference**. When IBBI published no digital notice the
    /// ingest has nothing to key on and synthesises `"fallback:<pdf url>"` as the dedup key
    /// (`court-scraper/ibbi-auctions-ingest.js:22`). That is an internal key, and rendering it
    /// puts a URL where a practitioner expects `Liq.AN/U27100MH…` — the same class of mistake
    /// as showing `LegalCase.parties` when it holds the `"[]"` sentinel.
    var displayReference: String? {
        guard let trimmed = uniqueNumber?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty, !trimmed.hasPrefix("fallback:")
        else { return nil }
        return trimmed
    }

    var reservePriceText: String? { reservePrice.map { IndianMoney.rupees($0) } }
    var emdAmountText: String? { emdAmount.map { IndianMoney.rupees($0) } }

    // MARK: - Provenance

    /// True when this row was scraped from the listing page and never from a notice PDF.
    ///
    /// Such a row is not wrong, it is thin: reserve price, platform, asset location, liquidator
    /// and the CIN are all routinely absent, and the CIN's absence in particular means the row
    /// can never be matched by a company watch.
    var isFallback: Bool { (isFallbackRaw ?? 0) != 0 }

    /// What to tell the reader about where this row came from, when it needs saying.
    var provenanceCaveat: String? {
        guard isFallback else { return nil }
        return """
            Read from the IBBI listing page only — no digital notice was published for it, so \
            the reserve price, platform and liquidator may be missing here even though they \
            appear in the notice PDF.
            """
    }

    /// Whether this notice supersedes an earlier one.
    var amendsAnEarlierNotice: Bool {
        type.amends || (supersedesUniqueNumber?.isEmpty == false)
    }

    // MARK: - Documents

    /// The notice to open. The digital form is the source every parsed figure on the screen
    /// came from, so it wins; a fallback row has only the scanned notice.
    var documentURL: URL? { Self.httpURL(digitalPDFURLRaw) ?? Self.httpURL(noticePDFURLRaw) }

    /// The scanned notice, when it is a *different* document from `documentURL`.
    var scannedNoticeURL: URL? {
        guard Self.httpURL(digitalPDFURLRaw) != nil else { return nil }
        return Self.httpURL(noticePDFURLRaw)
    }

    var platformURL: URL? { Self.httpURL(auctionPlatformURLRaw) }

    /// Parses a stored URL, refusing anything that is not http(s).
    ///
    /// These columns hold whatever the IBBI page had in an `href`. A relative path or a
    /// `javascript:` handler would otherwise be handed straight to a `Link`, producing a tap
    /// that either goes nowhere or leaves the app for a scheme nobody vetted.
    private static func httpURL(_ raw: String?) -> URL? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false
        else { return nil }
        return url
    }

    enum CodingKeys: String, CodingKey {
        case id, cin
        case uniqueNumber = "unique_number"
        case typeOfAN = "type_of_an"
        case corporateDebtor = "corporate_debtor"
        case insolvencyCommencementDateRaw = "insolvency_commencement_date"
        case liquidationCommencementDateRaw = "liquidation_commencement_date"
        case processNumber = "process_number"
        case dateIssuedRaw = "date_issued"
        case auctionDateRaw = "auction_date"
        case emdLastDateRaw = "emd_last_date"
        case reservePrice = "reserve_price"
        case emdAmount = "emd_amount"
        case auctionPlatform = "auction_platform"
        case auctionPlatformURLRaw = "auction_platform_url"
        case natureOfAssets = "nature_of_assets"
        case assetLocation = "asset_location"
        case liquidatorName = "liquidator_name"
        case ipRegistrationNumber = "ip_registration_number"
        case noticePDFURLRaw = "notice_pdf_url"
        case digitalPDFURLRaw = "digital_pdf_url"
        case supersedesUniqueNumber = "supersedes_unique_number"
        case isFallbackRaw = "is_fallback"
        case createdAtRaw = "created_at"
        case updatedAtRaw = "updated_at"
    }
}

/// Where an auction stands relative to today in India.
///
/// `.undated` is a first-class case rather than a synonym for `.closed`: a notice with no
/// auction date is usually a fallback row whose date never got parsed, and greying it out as
/// finished would hide a live auction.
enum AuctionStatus: Equatable, Sendable {
    case undated
    case today
    case upcoming
    case closed

    var label: String {
        switch self {
        case .undated: return "Date not published"
        case .today: return "Auction today"
        case .upcoming: return "Upcoming"
        case .closed: return "Closed"
        }
    }

    /// Whether the auction can still be bid at, as far as the date says.
    var isOpen: Bool { self == .today || self == .upcoming }
}

/// What kind of notice this is.
///
/// The three wire strings below are IBBI's own, carried verbatim through the scraper. They are
/// exposed because the list filter compares with `type_of_an = @typeOfAn` — **exact equality,
/// not a LIKE** (`sync-server.js:10320`) — so a filter value has to be the string the server
/// holds. That is also why the filter UI is driven by `/auction-notices/facets` rather than by
/// this enum: the facets are the values that actually exist in the table.
enum AuctionNoticeType: Equatable, Sendable {
    case issue
    case corrigendum
    case addendum
    /// Anything else, kept verbatim so an unfamiliar value is shown rather than dropped.
    case other(String)

    static let issueWire = "Issue of Auction Notice"
    static let corrigendumWire = "Corrigendum"
    static let addendumWire = "Addendum"

    /// Matched case-insensitively, as the platform does when it titles the notification
    /// (`court-scraper/ibbi-auctions-ingest.js:93`).
    init(wire: String?) {
        let trimmed = wire?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch trimmed {
        case _ where trimmed.caseInsensitiveCompare(Self.issueWire) == .orderedSame:
            self = .issue
        case _ where trimmed.caseInsensitiveCompare(Self.corrigendumWire) == .orderedSame:
            self = .corrigendum
        case _ where trimmed.caseInsensitiveCompare(Self.addendumWire) == .orderedSame:
            self = .addendum
        default:
            self = .other(trimmed)
        }
    }

    var label: String {
        switch self {
        case .issue: return "Auction notice"
        case .corrigendum: return "Corrigendum"
        case .addendum: return "Addendum"
        case .other(let raw): return raw.isEmpty ? "Notice" : raw
        }
    }

    /// Whether a notice of this kind changes an earlier one, so its figures win.
    var amends: Bool { self == .corrigendum || self == .addendum }
}

// MARK: - Money

/// Rupee amounts, written the way an Indian practitioner reads them.
///
/// Reserve prices on this feed run from a few lakh to several hundred crore. As raw digits
/// `₹125000000` and `₹1250000000` are one glance apart and differ by a factor of ten, which on
/// a reserve price is the entire decision. Lakh and crore put the magnitude in the first two
/// characters, and Indian digit grouping puts it in the commas below that.
///
/// Hand-rolled rather than `NumberFormatter` with `en_IN`: this is tested on Linux, whose
/// Foundation carries different locale data from the device's, and the string a practitioner
/// reads must not depend on which machine built it. `ListFormatter` and
/// `RelativeDateTimeFormatter` are absent there for the same reason `DisplayText` writes its
/// own.
enum IndianMoney {
    private static let lakh: UInt = 100_000
    private static let crore: UInt = 10_000_000

    /// `₹99,999`, `₹1.5 lakh`, `₹12.35 crore`.
    static func rupees(_ amount: Int) -> String {
        let sign = amount < 0 ? "-" : ""
        let value = amount.magnitude
        if value >= crore { return "\(sign)₹\(scaled(value, by: crore)) crore" }
        if value >= lakh { return "\(sign)₹\(scaled(value, by: lakh)) lakh" }
        return "\(sign)₹\(group(String(value)))"
    }

    /// Indian digit grouping: three digits, then twos — `1,23,45,678`.
    static func digits(_ value: Int) -> String {
        (value < 0 ? "-" : "") + group(String(value.magnitude))
    }

    /// `value / unit`, to at most two decimals, with trailing zeros dropped.
    ///
    /// Integer arithmetic throughout. A `Double` division of a crore-scale figure loses the
    /// last rupees before rounding, which is invisible in the common case and wrong in the one
    /// that matters.
    private static func scaled(_ value: UInt, by unit: UInt) -> String {
        var whole = value / unit
        var hundredths = ((value % unit) * 100 + unit / 2) / unit
        // Rounding can carry: ₹9,99,99,999 is 10 crore, not 9.100 crore.
        if hundredths >= 100 {
            whole += 1
            hundredths = 0
        }
        let head = group(String(whole))
        if hundredths == 0 { return head }
        if hundredths % 10 == 0 { return "\(head).\(hundredths / 10)" }
        return hundredths < 10 ? "\(head).0\(hundredths)" : "\(head).\(hundredths)"
    }

    private static func group(_ digits: String) -> String {
        guard digits.count > 3 else { return digits }
        var head = Substring(digits.dropLast(3))
        var groups = [String(digits.suffix(3))]
        while head.count > 2 {
            groups.insert(String(head.suffix(2)), at: 0)
            head = head.dropLast(2)
        }
        if !head.isEmpty { groups.insert(String(head), at: 0) }
        return groups.joined(separator: ",")
    }
}

// MARK: - Query

/// How a list of notices is ordered.
///
/// These are the whitelisted keys of the server's `SORT_MAP` (`sync-server.js:10309-10316`).
/// An unrecognised value is **not** an error: `SORT_MAP[sort] || SORT_MAP.auction_date_asc`
/// silently falls back to auction-date-ascending, so a typo produces a list that looks sorted
/// and is sorted by something else. Modelling the whitelist as an enum is what makes that
/// unreachable from this client.
enum AuctionSort: String, CaseIterable, Sendable {
    case auctionDateAscending = "auction_date_asc"
    case auctionDateDescending = "auction_date_desc"
    case reserveHighest = "reserve_desc"
    case reserveLowest = "reserve_asc"
    case recentlyIssued = "issued_desc"
    case debtorName = "debtor_asc"

    /// What the server uses when it does not recognise what it was sent.
    static let serverDefault = AuctionSort.auctionDateAscending

    var label: String {
        switch self {
        case .auctionDateAscending: return "Auction date, soonest"
        case .auctionDateDescending: return "Auction date, latest"
        case .reserveHighest: return "Reserve price, highest"
        case .reserveLowest: return "Reserve price, lowest"
        case .recentlyIssued: return "Recently issued"
        case .debtorName: return "Corporate debtor"
        }
    }
}

/// Everything that narrows a list request.
struct AuctionFilter: Equatable, Sendable {
    /// Exact match on `cin`.
    var cin: String?
    /// Free text, matched as `corporate_debtor LIKE %q% OR nature_of_assets LIKE %q%`
    /// (`sync-server.js:10319`).
    ///
    /// - Note: `%` and `_` typed by the user stay live as wildcards and cannot be escaped from
    ///   here. Left as typed rather than stripped: silently deleting characters from someone's
    ///   search term is worse than a broader match, and the term travels as a bound parameter
    ///   either way.
    var query: String?
    /// An exact `type_of_an`, taken from the facets rather than typed.
    var type: String?
    /// An exact `auction_platform`, likewise.
    var platform: String?
    /// `auction_date >= from`, as `YYYY-MM-DD`.
    var fromDay: String?
    /// `auction_date <= to`.
    var toDay: String?
    var minReserve: Int?
    var maxReserve: Int?

    /// Hide auctions whose date has passed.
    ///
    /// Deliberately **not** the server's `liveOnly=1`. That predicate is
    /// `auction_date >= date('now')` evaluated in **UTC** (`sync-server.js:10327`), and UTC
    /// midnight is 05:30 in India. So from India's midnight until 05:30 the server still counts
    /// the previous day's auctions as live, and then at 05:30 — the beginning of the working
    /// morning — they drop out of the list underneath whoever is reading it, with no refresh and
    /// no explanation. Sending our own `from` boundary computed in `Asia/Kolkata` moves the cut
    /// to India's midnight, where a date that means a day in India belongs. This is CLAUDE.md
    /// gotcha 9 wearing a different hat.
    var upcomingOnly = false

    var sort: AuctionSort = .auctionDateAscending

    init(
        cin: String? = nil, query: String? = nil, type: String? = nil, platform: String? = nil,
        fromDay: String? = nil, toDay: String? = nil,
        minReserve: Int? = nil, maxReserve: Int? = nil,
        upcomingOnly: Bool = false, sort: AuctionSort = .auctionDateAscending
    ) {
        self.cin = cin
        self.query = query
        self.type = type
        self.platform = platform
        self.fromDay = fromDay
        self.toDay = toDay
        self.minReserve = minReserve
        self.maxReserve = maxReserve
        self.upcomingOnly = upcomingOnly
        self.sort = sort
    }

    /// The query string for `GET /auction-notices`.
    ///
    /// - Parameter todayInIndia: `WireDate.todayKey()`. Passed in rather than read here so the
    ///   boundary is assertable instead of sampled.
    func queryItems(todayInIndia: String) -> [String: String] {
        var items = ["sort": sort.rawValue]
        if let cin = Self.text(cin) { items["cin"] = cin }
        if let query = Self.text(query) { items["q"] = query }
        if let type = Self.text(type) { items["typeOfAn"] = type }
        if let platform = Self.text(platform) { items["platform"] = platform }
        if let toDay = Self.text(toDay) { items["to"] = toDay }
        if let minReserve { items["minReserve"] = String(max(0, minReserve)) }
        if let maxReserve { items["maxReserve"] = String(max(0, maxReserve)) }

        // Never `liveOnly`. Both boundaries are `auction_date >=`, so the later of the user's
        // own start date and India's today is the one that satisfies both.
        var from = Self.text(fromDay)
        if upcomingOnly { from = max(from ?? todayInIndia, todayInIndia) }
        if let from { items["from"] = from }
        return items
    }

    /// Whether anything other than the sort order is narrowing the list.
    var isNarrowed: Bool {
        Self.text(cin) != nil || Self.text(query) != nil || Self.text(type) != nil
            || Self.text(platform) != nil || Self.text(fromDay) != nil || Self.text(toDay) != nil
            || minReserve != nil || maxReserve != nil || upcomingOnly
    }

    private static func text(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Facets

/// One value the filter dropdowns can offer, with how many notices carry it.
struct AuctionFacet: Codable, Equatable, Identifiable, Sendable {
    var value: String?
    var count: Int?

    var id: String { value ?? "" }
    var displayValue: String { value ?? "Unspecified" }

    enum CodingKeys: String, CodingKey {
        case value = "v"
        case count = "n"
    }
}

/// The real values in the table, so the filters describe the data rather than a guess.
///
/// - Note: `platforms` is the **top twenty by count, listed alphabetically**
///   (`sync-server.js:10344-10350`). It is not the complete set, so a platform missing from the
///   menu does not mean no notice names it — which is why the platform filter is offered
///   alongside free-text search rather than instead of it.
struct AuctionFacets: Equatable, Sendable {
    var types: [AuctionFacet] = []
    var platforms: [AuctionFacet] = []

    static let empty = AuctionFacets()
    var isEmpty: Bool { types.isEmpty && platforms.isEmpty }
}

// MARK: - Watchlists

/// A standing watch: one company, or one keyword.
///
/// Matching happens in the scraper as each notice is ingested — `cin` by equality, `keyword` by
/// case-insensitive substring over the debtor name *and* the nature of the assets
/// (`court-scraper/ibbi-auctions-ingest.js:74-85`). A match creates an `auction` notification
/// whose link is `/auction-notices/<id>`, which is the reason this feature exists.
struct AuctionWatchlist: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var userID: String? = nil
    var teamID: String? = nil
    var cin: String? = nil
    var keyword: String? = nil
    /// Zoneless SQLite `CURRENT_TIMESTAMP` — the INSERT omits the column so the DDL default
    /// fires (`sync-server.js:10386`).
    var createdAtRaw: String? = nil

    var createdAt: Date? { WireDate.parse(createdAtRaw) }

    var trimmedCIN: String? { Self.text(cin) }
    var trimmedKeyword: String? { Self.text(keyword) }

    /// What the row watches. In practice exactly one of the two is set, but the route accepts
    /// both in one body and stores both, so this reports what is actually there.
    var displayLabel: String {
        let parts = [trimmedCIN, trimmedKeyword].compactMap { $0 }
        return parts.isEmpty ? "Nothing to match" : DisplayText.list(parts)
    }

    var kindLabel: String {
        switch (trimmedCIN != nil, trimmedKeyword != nil) {
        case (true, true): return "Company and keyword"
        case (true, false): return "Company"
        case (false, true): return "Keyword"
        // A row with neither can never match a notice. It cannot be created through the API —
        // `POST` rejects it — so it means someone wrote the table directly, and saying so is
        // better than showing a watch that will never fire.
        case (false, false): return "Inactive"
        }
    }

    private static func text(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    enum CodingKeys: String, CodingKey {
        case id, cin, keyword
        case userID = "user_id"
        case teamID = "team_id"
        case createdAtRaw = "created_at"
    }
}

// MARK: - Envelopes

/// `success` is `Bool?` for the reason it is everywhere else in this client: the failure body on
/// these routes is `{"error": "..."}` with **no `success` key at all**
/// (`sync-server.js:10336`), so absence has to read as failure rather than decode as a missing
/// field. The watchlist DELETE is the other shape again — `{"success":false,"error":"Forbidden"}`
/// — which is why `CaseService.throwIfUnsuccessful` keys on `success != true` and covers both.
struct AuctionListResponse: Codable, Sendable {
    var success: Bool?
    /// The count matching the filter, not the page. Paging is offset-based with no cursor.
    var total: Int?
    var notices: [AuctionNotice]?
    var error: String?
}

struct AuctionFacetsResponse: Codable, Sendable {
    var success: Bool?
    var types: [AuctionFacet]?
    var platforms: [AuctionFacet]?
    var error: String?
}

struct AuctionDetailResponse: Codable, Sendable {
    var success: Bool?
    var notice: AuctionNotice?
    var amendments: [AuctionNotice]?
    var error: String?
}

struct AuctionWatchlistsResponse: Codable, Sendable {
    var success: Bool?
    var watchlists: [AuctionWatchlist]?
    var error: String?
}
