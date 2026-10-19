import Foundation
#if canImport(Darwin)
import Observation
#endif

// The MCA Registry (the web's `/mca-registry`): what a CIN says on its own, and the companies
// this product already holds records for.
//
// Deliberately narrower than "look up any Indian company". Registered address, directors,
// charges and filing history are MCA master data, which this product has no licensed source for;
// they are named as gaps (`Cin.masterDataGaps`), never guessed at. What is real: the decoder
// (`Cin.parse`) works offline on any CIN ever allotted, and the corporate debtors named in IBBI
// liquidation auction notices are searchable, one row per company with its notices under it.
//
// Auction watchlists are not offered here. The web's company page has a "Watch company" toggle;
// it writes to the same watchlist eAuctions would, which this client holds back — see README.md,
// "Built and deliberately held back". Do not add a watch control to these screens without
// reading that first.

/// One corporate debtor, gathered from the notices that name it.
struct McaCompany: Equatable, Identifiable, Sendable {
    /// The CIN in capitals, or `name:` and the debtor's name in capitals when no CIN was printed.
    let key: String
    /// The CIN exactly as the first notice stores it. Kept in that casing because the notice
    /// lookup compares exactly; the capitals are only for grouping.
    let cin: String?
    var name: String
    var notices: [AuctionNotice]
    /// The latest `date_issued`, as stored (`YYYY-MM-DD`).
    var latestIssued: String?

    var id: String { key }

    /// The CIN, decoded. An empty input decodes to "not a CIN", which the screen says plainly.
    var decoded: CinResult { Cin.parse(cin ?? "") }

    /// "3 notices on this page · latest issued 12 Mar 2025".
    var noticesLine: String {
        let count = "\(notices.count) notice\(notices.count == 1 ? "" : "s") on this page"
        guard let latestIssued, let date = WireDate.parseDay(latestIssued) else { return count }
        return "\(count) · latest issued \(McaRegistry.shortDate(date))"
    }
}

enum McaRegistry {
    /// The most notices one request returns — the route's own ceiling. Companies are found by
    /// gathering that page, so the cap is on notices scanned, not companies found, and the
    /// screen says so wherever it is reached.
    static let scanLimit = 200

    static let unnamed = "Unnamed corporate debtor"

    /// The web's `groupIntoCompanies`, exactly: one company per CIN (compared in capitals), or per
    /// debtor name where no CIN was printed; the longest spelling of the name, because IBBI
    /// notices truncate names inconsistently; and the latest issue date. In first-seen order.
    static func groupIntoCompanies(_ notices: [AuctionNotice]) -> [McaCompany] {
        var order: [String] = []
        var byKey: [String: McaCompany] = [:]
        for notice in notices {
            let cin = (notice.cin ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let key = cin.isEmpty ? "name:\((notice.corporateDebtor ?? "").uppercased())" : cin
            var company: McaCompany
            if let existing = byKey[key] {
                company = existing
            } else {
                order.append(key)
                let stored = notice.cin.flatMap { $0.isEmpty ? nil : $0 }
                company = McaCompany(key: key, cin: stored, name: "", notices: [], latestIssued: nil)
            }
            company.notices.append(notice)
            // Lengths in UTF-16, as the web compares them. Against "", so a real but short name
            // always beats the fallback.
            let debtor = notice.corporateDebtor ?? ""
            if debtor.utf16.count > company.name.utf16.count { company.name = debtor }
            if let issued = notice.dateIssuedRaw, !issued.isEmpty,
               company.latestIssued.map({ issued > $0 }) ?? true {
                company.latestIssued = issued
            }
            byKey[key] = company
        }
        return order.compactMap { key in
            guard var company = byKey[key] else { return nil }
            if company.name.isEmpty { company.name = unnamed }
            return company
        }
    }

    /// The browse request: newest notices first, so the default view is the companies in
    /// liquidation now; by debtor name while searching.
    static func browseFilter(search: String) -> AuctionFilter {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return AuctionFilter(query: q.isEmpty ? nil : q, sort: q.isEmpty ? .recentlyIssued : .debtorName)
    }

    /// One company's notices, latest auction first.
    static func companyFilter(cin: String) -> AuctionFilter {
        AuctionFilter(cin: cin, sort: .auctionDateDescending)
    }

    /// "1,392" — counts grouped the Indian way, as the web's `toLocaleString('en-IN')` does.
    static func count(_ n: Int) -> String { IndianMoney.digits(n) }

    static func shortDate(_ date: Date) -> String {
        shortDateFormatter.string(from: date)
    }

    nonisolated(unsafe) private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_IN")
        f.timeZone = WireDate.india
        f.dateFormat = "d MMM yyyy"
        return f
    }()
}

/// One decoded field as the registry lays it out: the web's label, the reading, the raw code
/// where it helps, and the hint under it.
struct McaFieldRow: Equatable, Identifiable, Sendable {
    let label: String
    let value: String
    let known: Bool
    let code: String?
    let hint: String?

    var id: String { label }

    /// The six fields, in the web's order and words. "Registrar", never "State": PN is ROC Pune
    /// and TZ is ROC Coimbatore, city offices inside states with codes of their own.
    static func rows(for f: CinFields) -> [McaFieldRow] {
        [
            McaFieldRow(label: "Listing status", value: f.listing.label, known: f.listing.known,
                        code: nil, hint: f.listing.note),
            McaFieldRow(label: "Company class", value: f.companyClass.label, known: f.companyClass.known,
                        code: f.companyClass.code, hint: f.companyClass.note),
            McaFieldRow(label: "Registrar (ROC)", value: f.roc.label, known: f.roc.known, code: f.roc.code,
                        hint: f.rocIsCityRegistrar
                            ? "City registrar within \(f.rocState ?? "its state") — the code is the ROC office, not the state."
                            : nil),
            McaFieldRow(label: "Year of incorporation", value: f.year.label, known: f.year.known,
                        code: nil, hint: nil),
            McaFieldRow(label: "Industry (NIC division)", value: f.industry.label, known: f.industry.known,
                        code: f.industry.code,
                        hint: f.industry.known && !f.industryIsSentinel
                            ? "Division \(f.industryDivision) of \(f.industryScheme). The full code \(f.industry.code) identifies a narrower sub-class that is not decoded here."
                            : nil),
            McaFieldRow(label: "Registration number", value: f.registration.label, known: true,
                        code: nil, hint: nil),
        ]
    }
}

/// What the notice records say about a decoded CIN.
enum McaRecordLookup: Equatable, Sendable {
    case idle
    case loading
    /// On record, with how many notices name it in all.
    case found(McaCompany, total: Int)
    /// No notice names it — which says nothing about whether the company exists.
    case absent
    case failed
}

/// The registry's front page: the CIN decoder, and the companies on record.
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class McaRegistryViewModel {
    /// The CIN being typed. Decoded on every keystroke — it is arithmetic on a string, with no
    /// request and nothing held here needed.
    var cinInput = ""
    /// The search as typed. The view applies it, debounced, with `search(_:)`.
    var searchText = ""

    private(set) var appliedSearch = ""
    private(set) var companies: [McaCompany] = []
    /// Notices on the page the companies were gathered from, and how many match in all.
    private(set) var scanned = 0
    private(set) var total = 0
    private(set) var isLoading = false
    private(set) var loadError: String?
    private(set) var recordLookup: McaRecordLookup = .idle

    private let service: any AuctionProviding
    private var lookupGeneration = 0

    init(service: any AuctionProviding) {
        self.service = service
    }

    static let loadFailedMessage =
        "Could not reach the notice records. The CIN decoder above still works — it runs entirely on this device."

    // MARK: - The decoder

    var decoded: CinResult { Cin.parse(cinInput) }
    var showsDecode: Bool { !cinInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Whether the notice records are worth asking about this CIN: only once it is a whole,
    /// well-formed one.
    var canLookUpRecords: Bool { decoded.kind == .cin && decoded.shapeValid }

    /// Asks the notice records about the decoded CIN: the normalised form first, then the input
    /// as typed when it differs, because a few rows store the CIN in another casing and the
    /// lookup compares exactly. A newer call supersedes an older one still in flight.
    func lookUpRecords() async {
        lookupGeneration += 1
        let generation = lookupGeneration
        let result = decoded
        guard canLookUpRecords else {
            recordLookup = .idle
            return
        }
        recordLookup = .loading
        var tries = [result.normalised]
        let raw = result.input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty, raw != result.normalised { tries.append(raw) }
        do {
            for cin in tries {
                let page = try await service.notices(
                    filter: McaRegistry.companyFilter(cin: cin), limit: McaRegistry.scanLimit, offset: 0)
                guard generation == lookupGeneration else { return }
                if let company = McaRegistry.groupIntoCompanies(page.notices).first {
                    recordLookup = .found(company, total: page.total)
                    return
                }
            }
            recordLookup = .absent
        } catch {
            guard generation == lookupGeneration else { return }
            recordLookup = .failed
        }
    }

    // MARK: - Companies on record

    func search(_ text: String) async {
        appliedSearch = text.trimmingCharacters(in: .whitespacesAndNewlines)
        await load()
    }

    func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let page = try await service.notices(
                filter: McaRegistry.browseFilter(search: appliedSearch),
                limit: McaRegistry.scanLimit, offset: 0)
            companies = McaRegistry.groupIntoCompanies(page.notices)
            scanned = page.notices.count
            total = page.total
        } catch {
            companies = []
            scanned = 0
            total = 0
            loadError = Self.loadFailedMessage
        }
    }

    /// "12 companies across 200 notices".
    var countLine: String {
        "\(McaRegistry.count(companies.count)) compan\(companies.count == 1 ? "y" : "ies") across "
            + "\(McaRegistry.count(scanned)) notice\(scanned == 1 ? "" : "s")"
    }

    /// Said only when the page did not hold every matching notice.
    var capLine: String? {
        guard total > scanned else { return nil }
        return "\(McaRegistry.count(total)) notices match in total; narrow the search to see companies beyond this page."
    }

    var emptyMessage: String {
        let subject = appliedSearch.isEmpty ? "this view" : "\"\(appliedSearch)\""
        return "No company on record matches \(subject). Only companies with a published liquidation "
            + "auction notice are held here — a company absent from this list may still exist and trade normally."
    }

    var showsEmpty: Bool { !isLoading && loadError == nil && companies.isEmpty }
}

/// One company's page: its decoded CIN and every notice that names it.
///
/// Opened from a company row, it re-reads the notices by CIN, so the page shows all of them and
/// not only those on the page it was opened from. If that read fails, the notices it came with
/// stay.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class McaCompanyViewModel {
    let company: McaCompany
    private(set) var notices: [AuctionNotice]
    private(set) var total: Int
    private(set) var isLoading: Bool

    private let service: any AuctionProviding

    init(company: McaCompany, total: Int? = nil, service: any AuctionProviding) {
        self.company = company
        self.notices = company.notices
        self.total = total ?? company.notices.count
        self.isLoading = company.cin != nil
        self.service = service
    }

    var decoded: CinResult { company.decoded }

    var cinLine: String {
        company.cin.map { Cin.format($0) } ?? "No CIN recorded on these notices"
    }

    func load() async {
        guard let cin = company.cin else {
            isLoading = false
            return
        }
        defer { isLoading = false }
        guard let page = try? await service.notices(
            filter: McaRegistry.companyFilter(cin: cin), limit: McaRegistry.scanLimit, offset: 0)
        else { return }
        notices = page.notices
        total = page.total
    }

    /// "4 on record · showing the 3 most recent".
    var countLine: String {
        if isLoading { return "loading…" }
        let base = "\(McaRegistry.count(total)) on record"
        return total > notices.count ? "\(base) · showing the \(notices.count) most recent" : base
    }

    var showsNoNotices: Bool { !isLoading && notices.isEmpty }
}
