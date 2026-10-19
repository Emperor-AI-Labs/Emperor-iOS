import Foundation

// The Library (docs/library.md in the platform): the reference corpus the platform holds — Bare
// Acts, Case Law, Books & Law Reports, Regulator Orders, Tribunals, Law Commission Reports,
// Professional Institutes, Parliament (PRS) and Legal Aid (NALSA) — read through the catalogue
// routes under `/library/catalogue/*`. Every shape here is the wire's, verified against
// `lib/library/query.js` (`toItem`), `act.js`, `judgment.js`, `shelf.js` and `routes.js`.

// MARK: - The nine collections

/// One of the Library's collections, keyed as the catalogue keys them.
///
/// The vocabulary is the web's `coverTheme.js`: the label on the strip, the one-word kind on a
/// cover, the sentence under a shelf title, and the cover cloth. A key the app does not know
/// still browses — `LibraryCollection.theme(for:)` falls back — so a collection the platform adds
/// later appears with a plain name rather than being hidden.
enum LibraryCollection: String, CaseIterable, Identifiable, Sendable {
    case bareActs = "bare-acts"
    case caseLaw = "case-law"
    case booksAndReports = "books-and-law-reports"
    case regulatorOrders = "regulator-orders"
    case tribunals = "tribunals"
    case lawCommission = "law-commission-reports"
    case professionalInstitutes = "professional-institutes"
    case parliament = "parliament-prs"
    case legalAid = "legal-aid-nalsa"

    var id: String { rawValue }

    /// Shelf order, the web's.
    static let shelfOrder: [LibraryCollection] = allCases

    var theme: LibraryCollectionTheme { LibraryCollectionTheme.theme(for: rawValue) }
}

/// What a collection looks like: its words and its colours.
struct LibraryCollectionTheme: Equatable, Sendable {
    let key: String
    /// "Bare acts" — the strip and the shelf title.
    let label: String
    /// "Bare act" — the kind, on a cover's kicker and a list badge.
    let cap: String
    /// What a nameless document is called: "Untitled Act".
    let untitled: String
    let blurb: String
    /// SF Symbol standing in for the web's lucide icon.
    let systemImage: String
    /// Cover cloth shades (hex), the same in both themes — a red book is red in a dark room.
    let cloth: [String]
    /// The collection's text/icon colour on a light surface and on a dark one.
    let ink: String
    let inkDark: String
    /// How the typographic cover is ruled: `bands`, `frame`, `report` or `seal`.
    let motif: String

    static let fallback = LibraryCollectionTheme(
        key: "", label: "Library", cap: "Document", untitled: "Untitled document", blurb: "",
        systemImage: "book.closed", cloth: ["#3A3F5C", "#424867", "#33384F"],
        ink: "#464E85", inkDark: "#B7BEE6", motif: "frame")

    static func theme(for key: String?) -> LibraryCollectionTheme {
        guard let key, let theme = themes[key] else {
            var fallback = Self.fallback
            fallback = LibraryCollectionTheme(
                key: key ?? "", label: fallback.label, cap: fallback.cap, untitled: fallback.untitled,
                blurb: fallback.blurb, systemImage: fallback.systemImage, cloth: fallback.cloth,
                ink: fallback.ink, inkDark: fallback.inkDark, motif: fallback.motif)
            return fallback
        }
        return theme
    }

    /// Lettering on every cover: 4.8:1 on the lightest cloth, 12:1 on navy.
    static let coverInk = "#F6F0E1"
    /// The gilt of rules and spine bands. Decorative only.
    static let coverGilt = "#D4B46A"

    private static let themes: [String: LibraryCollectionTheme] = [
        "bare-acts": LibraryCollectionTheme(
            key: "bare-acts", label: "Bare acts", cap: "Bare act", untitled: "Untitled Act",
            blurb: "Every central and state Act, with its rules, regulations and notifications.",
            systemImage: "scroll", cloth: ["#6E1F2A", "#7A2632", "#5F1A24"],
            ink: "#8C2A37", inkDark: "#EBA3AC", motif: "bands"),
        "case-law": LibraryCollectionTheme(
            key: "case-law", label: "Case law", cap: "Judgment", untitled: "Untitled judgment",
            blurb: "Judgments of the Supreme Court and the High Courts, searchable word for word.",
            systemImage: "building.columns", cloth: ["#1F2E4D", "#253860", "#1A2742"],
            ink: "#2B4373", inkDark: "#A9BDEB", motif: "report"),
        "books-and-law-reports": LibraryCollectionTheme(
            key: "books-and-law-reports", label: "Books and law reports", cap: "Book", untitled: "Untitled volume",
            blurb: "Commentaries, digests and bound law reports, volume by volume.",
            systemImage: "book", cloth: ["#1F4A3A", "#265643", "#1A3F31", "#2D4630", "#1B4047"],
            ink: "#23624A", inkDark: "#97D3B8", motif: "frame"),
        "regulator-orders": LibraryCollectionTheme(
            key: "regulator-orders", label: "Regulator orders", cap: "Order", untitled: "Regulator order",
            blurb: "Orders, circulars and directions from SEBI, RBI and other regulators.",
            systemImage: "seal", cloth: ["#1D4B55", "#225763", "#183F48"],
            ink: "#1F5F6C", inkDark: "#93CFDA", motif: "seal"),
        "tribunals": LibraryCollectionTheme(
            key: "tribunals", label: "Tribunals", cap: "Tribunal", untitled: "Tribunal decision",
            blurb: "Decisions of TDSAT and the Armed Forces Tribunal, with NHRC publications.",
            systemImage: "scale.3d", cloth: ["#4A2747", "#552D52", "#3F213C"],
            ink: "#6A3766", inkDark: "#D9AED5", motif: "report"),
        "law-commission-reports": LibraryCollectionTheme(
            key: "law-commission-reports", label: "Law Commission reports", cap: "Report", untitled: "Law Commission report",
            blurb: "Reports of the Law Commission of India, from the first to the latest.",
            systemImage: "text.book.closed", cloth: ["#3B3570", "#443D7E", "#332E62"],
            ink: "#4A4390", inkDark: "#B8B1EE", motif: "frame"),
        "professional-institutes": LibraryCollectionTheme(
            key: "professional-institutes", label: "Professional institutes", cap: "Institute", untitled: "Institute publication",
            blurb: "Standards and guidance from ICAI, ICSI and ICMAI.",
            systemImage: "graduationcap", cloth: ["#33363D", "#3C3F47", "#2B2D33"],
            ink: "#4A4E58", inkDark: "#C4C8D2", motif: "seal"),
        "parliament-prs": LibraryCollectionTheme(
            key: "parliament-prs", label: "Parliament", cap: "Parliament", untitled: "Parliamentary paper",
            blurb: "Bills as introduced and passed, with PRS summaries and committee reports.",
            systemImage: "building.2", cloth: ["#8A3F22", "#964628", "#7A371D"],
            ink: "#9A4724", inkDark: "#F0B497", motif: "bands"),
        "legal-aid-nalsa": LibraryCollectionTheme(
            key: "legal-aid-nalsa", label: "Legal aid", cap: "Legal aid", untitled: "Legal aid report",
            blurb: "Reports and schemes of the National Legal Services Authority.",
            systemImage: "hand.raised", cloth: ["#7A5A17", "#86641B", "#6C4F13"],
            ink: "#7A5A17", inkDark: "#E8C77E", motif: "frame"),
    ]
}

/// `GET /categories` → one row per collection with its live count.
struct LibraryCategoryCount: Codable, Equatable, Identifiable, Sendable {
    let key: String
    var label: String?
    var count: Int?

    var id: String { key }
    var collection: LibraryCollection? { LibraryCollection(rawValue: key) }
    var theme: LibraryCollectionTheme {
        var theme = LibraryCollectionTheme.theme(for: key)
        if theme.key.isEmpty || LibraryCollection(rawValue: key) == nil, let label, !label.isEmpty {
            theme = LibraryCollectionTheme(
                key: key, label: label, cap: theme.cap, untitled: theme.untitled, blurb: theme.blurb,
                systemImage: theme.systemImage, cloth: theme.cloth, ink: theme.ink, inkDark: theme.inkDark,
                motif: theme.motif)
        }
        return theme
    }
}

// MARK: - The document

/// A catalogue row as every list route returns it (`toItem` in `lib/library/query.js`).
///
/// Everything is optional: the catalogue is built from nine scrapers, and a field a source never
/// had is simply absent. `title` is the catalogue's own; `displayTitle` is the server's read-time
/// repair of it and wins when present (`LibraryTitles.tidyTitle`).
struct CatalogueDocument: Codable, Equatable, Identifiable, Hashable, Sendable {
    let id: Int
    var title: String?
    var displayTitle: String?
    var rawTitle: String?
    var genericTitle: Bool?
    var displayRef: String?
    var reportNo: Int?
    var subject: String?
    var publisher: String?
    var kind: String?
    var lang: String?
    var volumeNo: Int?
    var dateFromTitle: String?
    var category: String?
    var docType: String?
    var isAmendment: Bool?
    var jurisdiction: String?
    var jurisdictionInferred: Bool?
    var court: String?
    var courtLabel: String?
    var year: Int?
    var decidedOn: String?
    var petitioner: String?
    var respondent: String?
    var neutralCitation: String?
    var caseType: String?
    var caseNumber: String?
    var bench: String?
    var series: String?
    var volume: String?
    var issue: String?
    var reference: String?
    var titleFromScan: Bool?
    /// `.pdf`, `.txt`, `.html` — with the dot, unlike the older browse route.
    var ext: String?
    var fileSize: Int?
    /// `html` (a formatted mirror exists), `text`, `pdf` or `other`.
    var render: String?
    var hasChildren: Int?
    var parentId: Int?
    var anomalies: [String]?
    var coverUrl: String?
    /// `/doc` only: whether the bytes are on this host, and for judgments whether the text is.
    var hasFile: Bool?
    var hasText: Bool?
    /// Body search only: the passage the words were found in.
    var snippet: LibrarySnippet?
    /// Bare Acts index items and Act bundles (`/folders`, `/act`).
    var firstLetter: String?
    var groupTitle: String?
    var tabCounts: [String: Int]?
    var instruments: Int?
    var aliases: [String]?
    var repealed: Bool?
    var copies: [Int]?
    var hasCover: Bool?

    enum CodingKeys: String, CodingKey {
        case id, title, displayTitle, rawTitle, genericTitle, displayRef, reportNo, subject
        case publisher, kind, lang, volumeNo, dateFromTitle, category, docType, isAmendment
        case jurisdiction, jurisdictionInferred, court, courtLabel, year, decidedOn, petitioner, respondent
        case neutralCitation, caseType, caseNumber, bench, series, volume, issue, reference
        case titleFromScan, ext, fileSize, render, hasChildren, parentId, anomalies, coverUrl
        case hasFile, hasText, snippet, firstLetter, groupTitle, tabCounts, instruments, aliases
        case repealed, copies, hasCover
    }

    init(id: Int, title: String? = nil, category: String? = nil) {
        self.id = id
        self.title = title
        self.category = category
    }

    /// A document is a bare `id` on the wire; everything else is optional. Decoded by hand so a
    /// row carrying an unexpected type in a field this client ignores does not sink the page.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        displayTitle = try? c.decodeIfPresent(String.self, forKey: .displayTitle)
        rawTitle = try? c.decodeIfPresent(String.self, forKey: .rawTitle)
        genericTitle = try? c.decodeIfPresent(Bool.self, forKey: .genericTitle)
        displayRef = try? c.decodeIfPresent(String.self, forKey: .displayRef)
        reportNo = Self.flexibleInt(c, .reportNo)
        subject = try? c.decodeIfPresent(String.self, forKey: .subject)
        publisher = try? c.decodeIfPresent(String.self, forKey: .publisher)
        kind = try? c.decodeIfPresent(String.self, forKey: .kind)
        lang = try? c.decodeIfPresent(String.self, forKey: .lang)
        volumeNo = Self.flexibleInt(c, .volumeNo)
        dateFromTitle = try? c.decodeIfPresent(String.self, forKey: .dateFromTitle)
        category = try? c.decodeIfPresent(String.self, forKey: .category)
        docType = try? c.decodeIfPresent(String.self, forKey: .docType)
        isAmendment = try? c.decodeIfPresent(Bool.self, forKey: .isAmendment)
        jurisdiction = try? c.decodeIfPresent(String.self, forKey: .jurisdiction)
        jurisdictionInferred = try? c.decodeIfPresent(Bool.self, forKey: .jurisdictionInferred)
        court = try? c.decodeIfPresent(String.self, forKey: .court)
        courtLabel = try? c.decodeIfPresent(String.self, forKey: .courtLabel)
        year = Self.flexibleInt(c, .year)
        decidedOn = try? c.decodeIfPresent(String.self, forKey: .decidedOn)
        petitioner = try? c.decodeIfPresent(String.self, forKey: .petitioner)
        respondent = try? c.decodeIfPresent(String.self, forKey: .respondent)
        neutralCitation = try? c.decodeIfPresent(String.self, forKey: .neutralCitation)
        caseType = try? c.decodeIfPresent(String.self, forKey: .caseType)
        caseNumber = Self.flexibleString(c, .caseNumber)
        bench = Self.benchString(c)
        series = try? c.decodeIfPresent(String.self, forKey: .series)
        volume = Self.flexibleString(c, .volume)
        issue = Self.flexibleString(c, .issue)
        reference = try? c.decodeIfPresent(String.self, forKey: .reference)
        titleFromScan = try? c.decodeIfPresent(Bool.self, forKey: .titleFromScan)
        ext = try? c.decodeIfPresent(String.self, forKey: .ext)
        fileSize = Self.flexibleInt(c, .fileSize)
        render = try? c.decodeIfPresent(String.self, forKey: .render)
        hasChildren = Self.flexibleInt(c, .hasChildren)
        parentId = Self.flexibleInt(c, .parentId)
        anomalies = try? c.decodeIfPresent([String].self, forKey: .anomalies)
        coverUrl = try? c.decodeIfPresent(String.self, forKey: .coverUrl)
        hasFile = try? c.decodeIfPresent(Bool.self, forKey: .hasFile)
        hasText = try? c.decodeIfPresent(Bool.self, forKey: .hasText)
        snippet = try? c.decodeIfPresent(LibrarySnippet.self, forKey: .snippet)
        firstLetter = try? c.decodeIfPresent(String.self, forKey: .firstLetter)
        groupTitle = try? c.decodeIfPresent(String.self, forKey: .groupTitle)
        tabCounts = try? c.decodeIfPresent([String: Int].self, forKey: .tabCounts)
        instruments = Self.flexibleInt(c, .instruments)
        aliases = try? c.decodeIfPresent([String].self, forKey: .aliases)
        repealed = try? c.decodeIfPresent(Bool.self, forKey: .repealed)
        copies = try? c.decodeIfPresent([Int].self, forKey: .copies)
        hasCover = try? c.decodeIfPresent(Bool.self, forKey: .hasCover)
    }

    private static func flexibleInt(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int? {
        if let n = try? c.decodeIfPresent(Int.self, forKey: key) { return n }
        if let d = try? c.decodeIfPresent(Double.self, forKey: key) { return Int(d) }
        if let s = try? c.decodeIfPresent(String.self, forKey: key) { return Int(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    private static func flexibleString(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String? {
        if let s = try? c.decodeIfPresent(String.self, forKey: key) { return s }
        if let n = try? c.decodeIfPresent(Int.self, forKey: key) { return String(n) }
        if let d = try? c.decodeIfPresent(Double.self, forKey: key) {
            return d == d.rounded() ? String(Int(d)) : String(d)
        }
        return nil
    }

    /// `bench` is one string on a row and an array on a judgment header; rows that came through
    /// the formatter can carry either.
    private static func benchString(_ c: KeyedDecodingContainer<CodingKeys>) -> String? {
        if let s = try? c.decodeIfPresent(String.self, forKey: .bench) { return s }
        if let list = try? c.decodeIfPresent([String].self, forKey: .bench) { return list.joined(separator: ", ") }
        return nil
    }

    // MARK: Derived

    var collection: LibraryCollection? { category.flatMap(LibraryCollection.init(rawValue:)) }
    var theme: LibraryCollectionTheme { LibraryCollectionTheme.theme(for: category) }

    /// Whether the bytes are a PDF: by extension, by the server's rendering hint, or by the cover
    /// the server offered (only PDFs have one).
    var isPDF: Bool {
        if let ext { return ext.lowercased() == ".pdf" || ext.lowercased() == "pdf" }
        if let render { return render == "pdf" }
        return coverUrl != nil
    }

    /// Opens as text (a formatted judgment or the raw dump) rather than as a PDF.
    var isTextDocument: Bool {
        render == "html" || render == "text" || ext == ".txt" || ext == ".html"
    }

    /// A Bare Act that opens its Act page rather than the reading room.
    var opensAsAct: Bool {
        category == LibraryCollection.bareActs.rawValue && (docType == "act" || (hasChildren ?? 0) > 0)
    }

    /// The year on a cover: the decision's, else the catalogue's.
    var coverYear: String {
        if let decidedOn, decidedOn.count >= 4 { return String(decidedOn.prefix(4)) }
        return year.map(String.init) ?? ""
    }
}

/// A matched passage from body search; `before`/`after` say whether text was cut on that side,
/// so an ellipsis is drawn only where one is warranted.
struct LibrarySnippet: Codable, Equatable, Hashable, Sendable {
    var text: String
    var before: Bool
    var after: Bool
    var term: String?

    init(text: String, before: Bool = false, after: Bool = false, term: String? = nil) {
        self.text = text
        self.before = before
        self.after = after
        self.term = term
    }

    init(from decoder: Decoder) throws {
        // A bare string is accepted too, for an older backend that sent the passage alone.
        if let single = try? decoder.singleValueContainer(), let text = try? single.decode(String.self) {
            self.init(text: text)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        let before = (try? c.decodeIfPresent(Bool.self, forKey: .before)) ?? ((try? c.decodeIfPresent(String.self, forKey: .before)).map { !$0.isEmpty } ?? false)
        let after = (try? c.decodeIfPresent(Bool.self, forKey: .after)) ?? ((try? c.decodeIfPresent(String.self, forKey: .after)).map { !$0.isEmpty } ?? false)
        let term = try? c.decodeIfPresent(String.self, forKey: .term)
        self.init(text: text, before: before, after: after, term: term)
    }
}

// MARK: - Facets

/// One choice in a facet, with how many documents it holds.
struct LibraryFacetOption: Codable, Equatable, Hashable, Identifiable, Sendable {
    var value: String
    var label: String?
    var name: String?
    var count: Int?
    var yearMin: Int?
    var yearMax: Int?

    var id: String { value }
    var displayLabel: String { label?.nilIfEmpty ?? value }

    init(value: String, label: String? = nil, name: String? = nil, count: Int? = nil, yearMin: Int? = nil, yearMax: Int? = nil) {
        self.value = value
        self.label = label
        self.name = name
        self.count = count
        self.yearMin = yearMin
        self.yearMax = yearMax
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try? c.decode(String.self, forKey: .value) { value = s }
        else if let n = try? c.decode(Int.self, forKey: .value) { value = String(n) }
        else { value = "" }
        label = try? c.decodeIfPresent(String.self, forKey: .label)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        count = try? c.decodeIfPresent(Int.self, forKey: .count)
        yearMin = try? c.decodeIfPresent(Int.self, forKey: .yearMin)
        yearMax = try? c.decodeIfPresent(Int.self, forKey: .yearMax)
    }
}

struct LibraryYearCount: Codable, Equatable, Hashable, Sendable {
    var year: Int
    var count: Int
}

struct LibraryYearRange: Codable, Equatable, Sendable {
    var min: Int
    var max: Int
}

struct LibraryLetterCount: Codable, Equatable, Hashable, Identifiable, Sendable {
    var letter: String
    var count: Int
    var id: String { letter }
}

struct LibrarySortOption: Codable, Equatable, Hashable, Identifiable, Sendable {
    var value: String
    var label: String
    var id: String { value }
}

/// `GET /facets?category=` → what a collection can be filtered by.
struct LibraryFacets: Codable, Equatable, Sendable {
    var category: String?
    var label: String?
    var courts: [LibraryFacetOption]?
    var years: [LibraryYearCount]?
    var yearRange: LibraryYearRange?
    var docTypes: [LibraryFacetOption]?
    var jurisdictions: [LibraryFacetOption]?
    var series: [LibraryFacetOption]?
    var sorts: [LibrarySortOption]?
    var publishers: [LibraryFacetOption]?
    var kinds: [LibraryFacetOption]?
    var letters: [LibraryLetterCount]?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        category = try? c.decodeIfPresent(String.self, forKey: .category)
        label = try? c.decodeIfPresent(String.self, forKey: .label)
        courts = try? c.decodeIfPresent([LibraryFacetOption].self, forKey: .courts)
        years = try? c.decodeIfPresent([LibraryYearCount].self, forKey: .years)
        yearRange = try? c.decodeIfPresent(LibraryYearRange.self, forKey: .yearRange)
        docTypes = try? c.decodeIfPresent([LibraryFacetOption].self, forKey: .docTypes)
        jurisdictions = try? c.decodeIfPresent([LibraryFacetOption].self, forKey: .jurisdictions)
        series = try? c.decodeIfPresent([LibraryFacetOption].self, forKey: .series)
        sorts = try? c.decodeIfPresent([LibrarySortOption].self, forKey: .sorts)
        publishers = try? c.decodeIfPresent([LibraryFacetOption].self, forKey: .publishers)
        kinds = try? c.decodeIfPresent([LibraryFacetOption].self, forKey: .kinds)
        letters = try? c.decodeIfPresent([LibraryLetterCount].self, forKey: .letters)
    }
}

// MARK: - Pages

/// `GET /browse` and `GET /search`: one page of documents and the count behind it.
struct LibraryPage: Codable, Equatable, Sendable {
    var items: [CatalogueDocument]
    var total: Int
    var page: Int
    var pageSize: Int
    var sort: String?
    var search: String?
    /// Body search stops counting at 1,000 and says so.
    var totalIsCapped: Bool?
    var mode: String?
    var index: LibrarySearchIndexStatus?

    init(items: [CatalogueDocument] = [], total: Int = 0, page: Int = 1, pageSize: Int = 0,
         sort: String? = nil, search: String? = nil, totalIsCapped: Bool? = nil, mode: String? = nil,
         index: LibrarySearchIndexStatus? = nil) {
        self.items = items
        self.total = total
        self.page = page
        self.pageSize = pageSize
        self.sort = sort
        self.search = search
        self.totalIsCapped = totalIsCapped
        self.mode = mode
        self.index = index
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = (try? c.decodeIfPresent([CatalogueDocument].self, forKey: .items)) ?? []
        total = (try? c.decodeIfPresent(Int.self, forKey: .total)) ?? items.count
        page = (try? c.decodeIfPresent(Int.self, forKey: .page)) ?? 1
        pageSize = (try? c.decodeIfPresent(Int.self, forKey: .pageSize)) ?? items.count
        sort = try? c.decodeIfPresent(String.self, forKey: .sort)
        search = try? c.decodeIfPresent(String.self, forKey: .search)
        totalIsCapped = try? c.decodeIfPresent(Bool.self, forKey: .totalIsCapped)
        mode = try? c.decodeIfPresent(String.self, forKey: .mode)
        index = try? c.decodeIfPresent(LibrarySearchIndexStatus.self, forKey: .index)
    }

    var pageCount: Int { pageSize > 0 ? max(1, Int((Double(total) / Double(pageSize)).rounded(.up))) : 1 }
    var hasMore: Bool { page < pageCount }
}

/// How far the body index has got: a partial index answers correctly over what it covers, and
/// the reader must be able to tell "no matches" from "not indexed yet".
struct LibrarySearchIndexStatus: Codable, Equatable, Sendable {
    var available: Bool?
    var ready: Bool?
    var complete: Bool?
    var indexed: Int?
    var pending: Int?
    var noText: Int?
    var total: Int?
}

/// `GET /browse?groupBy=category&q=` → the top few title matches in every collection.
struct LibraryGroupedSearch: Codable, Equatable, Sendable {
    struct Group: Codable, Equatable, Identifiable, Sendable {
        var category: String
        var label: String?
        var total: Int
        var items: [CatalogueDocument]
        var id: String { category }
    }

    var groups: [Group]
    var search: String?
    var pageSize: Int?

    init(groups: [Group] = [], search: String? = nil, pageSize: Int? = nil) {
        self.groups = groups
        self.search = search
        self.pageSize = pageSize
    }
}

/// `GET /shelf?category=` → a day's pick for the home shelf.
struct LibraryShelf: Codable, Equatable, Sendable {
    var category: String?
    var label: String?
    var day: String?
    var items: [CatalogueDocument]

    init(category: String? = nil, label: String? = nil, day: String? = nil, items: [CatalogueDocument] = []) {
        self.category = category
        self.label = label
        self.day = day
        self.items = items
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        category = try? c.decodeIfPresent(String.self, forKey: .category)
        label = try? c.decodeIfPresent(String.self, forKey: .label)
        day = try? c.decodeIfPresent(String.self, forKey: .day)
        items = (try? c.decodeIfPresent([CatalogueDocument].self, forKey: .items)) ?? []
    }
}

/// `GET /shelf?category=books-and-law-reports&by=series` → the law reports by series.
struct LibrarySeriesShelves: Codable, Equatable, Sendable {
    struct SeriesShelf: Codable, Equatable, Identifiable, Sendable {
        var series: String
        var count: Int?
        var yearMin: Int?
        var yearMax: Int?
        var items: [CatalogueDocument]
        var id: String { series }
    }

    struct Standalone: Codable, Equatable, Sendable {
        var count: Int?
        var items: [CatalogueDocument]
    }

    var seriesTotal: Int?
    var shelves: [SeriesShelf]
    var standalone: Standalone?
    var day: String?

    init(seriesTotal: Int? = nil, shelves: [SeriesShelf] = [], standalone: Standalone? = nil, day: String? = nil) {
        self.seriesTotal = seriesTotal
        self.shelves = shelves
        self.standalone = standalone
        self.day = day
    }
}

// MARK: - One document

/// `GET /doc?id=` → the row plus what hangs off it.
struct LibraryDocumentDetail: Codable, Equatable, Sendable {
    struct ChildGroup: Codable, Equatable, Identifiable, Sendable {
        var key: String
        var label: String?
        var items: [CatalogueDocument]
        var id: String { key }
    }

    var doc: CatalogueDocument
    var childGroups: [ChildGroup]
    var childCount: Int?
    var editions: [CatalogueDocument]
    var parent: CatalogueDocument?

    init(doc: CatalogueDocument, childGroups: [ChildGroup] = [], childCount: Int? = nil,
         editions: [CatalogueDocument] = [], parent: CatalogueDocument? = nil) {
        self.doc = doc
        self.childGroups = childGroups
        self.childCount = childCount
        self.editions = editions
        self.parent = parent
    }

    /// The route folds these into the `doc` object itself.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        doc = try CatalogueDocument(from: decoder)
        childGroups = (try? c.decodeIfPresent([ChildGroup].self, forKey: .childGroups)) ?? []
        childCount = try? c.decodeIfPresent(Int.self, forKey: .childCount)
        editions = (try? c.decodeIfPresent([CatalogueDocument].self, forKey: .editions)) ?? []
        parent = try? c.decodeIfPresent(CatalogueDocument.self, forKey: .parent)
    }

    func encode(to encoder: Encoder) throws {
        try doc.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(childGroups, forKey: .childGroups)
        try c.encodeIfPresent(childCount, forKey: .childCount)
        try c.encode(editions, forKey: .editions)
        try c.encodeIfPresent(parent, forKey: .parent)
    }

    private enum CodingKeys: String, CodingKey {
        case childGroups, childCount, editions, parent
    }
}

// MARK: - Bare Acts

/// `GET /folders` → one page of the A–Z index of Acts, with the letter and jurisdiction counts.
struct ActIndexPage: Codable, Equatable, Sendable {
    var items: [CatalogueDocument]
    var total: Int
    var page: Int
    var pageSize: Int
    var letters: [LibraryLetterCount]
    var jurisdictions: [LibraryFacetOption]

    init(items: [CatalogueDocument] = [], total: Int = 0, page: Int = 1, pageSize: Int = 60,
         letters: [LibraryLetterCount] = [], jurisdictions: [LibraryFacetOption] = []) {
        self.items = items
        self.total = total
        self.page = page
        self.pageSize = pageSize
        self.letters = letters
        self.jurisdictions = jurisdictions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = (try? c.decodeIfPresent([CatalogueDocument].self, forKey: .items)) ?? []
        total = (try? c.decodeIfPresent(Int.self, forKey: .total)) ?? items.count
        page = (try? c.decodeIfPresent(Int.self, forKey: .page)) ?? 1
        pageSize = (try? c.decodeIfPresent(Int.self, forKey: .pageSize)) ?? max(items.count, 1)
        letters = (try? c.decodeIfPresent([LibraryLetterCount].self, forKey: .letters)) ?? []
        jurisdictions = (try? c.decodeIfPresent([LibraryFacetOption].self, forKey: .jurisdictions)) ?? []
    }

    var pageCount: Int { pageSize > 0 ? max(1, Int((Double(total) / Double(pageSize)).rounded(.up))) : 1 }
}

/// `GET /act?id=` → an Act with everything made under it, one tab each.
struct ActBundle: Codable, Equatable, Sendable {
    struct Tab: Codable, Equatable, Identifiable, Sendable {
        var key: String
        var label: String
        var count: Int
        var docs: [CatalogueDocument]
        var id: String { key }
    }

    var act: CatalogueDocument
    var bundleId: Int?
    var requestedId: Int?
    var selectedId: Int?
    var selectedTab: String?
    var orphan: Bool?
    /// `act`, `orphan` (an instrument whose Act is not held) or `amendments` (amending Acts of an
    /// Act that is not held, grouped).
    var kind: String?
    var groupTitle: String?
    var tabs: [Tab]

    init(act: CatalogueDocument, bundleId: Int? = nil, requestedId: Int? = nil, selectedId: Int? = nil,
         selectedTab: String? = nil, orphan: Bool? = nil, kind: String? = nil, groupTitle: String? = nil,
         tabs: [Tab] = []) {
        self.act = act
        self.bundleId = bundleId
        self.requestedId = requestedId
        self.selectedId = selectedId
        self.selectedTab = selectedTab
        self.orphan = orphan
        self.kind = kind
        self.groupTitle = groupTitle
        self.tabs = tabs
    }

    var resolvedKind: String { kind ?? (orphan == true ? "orphan" : "act") }
}

// MARK: - A judgment

/// One typeset block of a judgment (`/judgment` → `blocks[]`).
struct JudgmentBlock: Codable, Equatable, Identifiable, Hashable, Sendable {
    /// `para-<n>`, `h-<i>` or `b-<i>` — unique within the judgment.
    var id: String
    /// `heading`, `para`, `quote`, `list`, `cause`, `meta`, `table`.
    var type: String
    var text: String
    /// Headings: 1 is the JUDGMENT/ORDER banner, 2 a section heading.
    var level: Int?
    /// A numbered paragraph's own number — "12" or "2.1" — lifted out of `text`.
    var n: String?
    /// A list item's marker: `(a)`, `(iv)`, `•`.
    var marker: String?
    /// Cause titles, tables and signature blocks keep their line structure.
    var lines: [String]?
    /// Meta blocks: `author`, `date` or `signature`.
    var role: String?

    init(id: String, type: String, text: String, level: Int? = nil, n: String? = nil,
         marker: String? = nil, lines: [String]? = nil, role: String? = nil) {
        self.id = id
        self.type = type
        self.text = text
        self.level = level
        self.n = n
        self.marker = marker
        self.lines = lines
        self.role = role
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? ""
        type = (try? c.decodeIfPresent(String.self, forKey: .type)) ?? "para"
        lines = try? c.decodeIfPresent([String].self, forKey: .lines)
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? (lines?.joined(separator: "\n") ?? "")
        level = try? c.decodeIfPresent(Int.self, forKey: .level)
        if let s = try? c.decodeIfPresent(String.self, forKey: .n) { n = s }
        else if let number = try? c.decodeIfPresent(Double.self, forKey: .n) {
            n = number == number.rounded() ? String(Int(number)) : String(number)
        } else { n = nil }
        marker = try? c.decodeIfPresent(String.self, forKey: .marker)
        role = try? c.decodeIfPresent(String.self, forKey: .role)
    }

    /// The lines as the reader draws them — the kept structure where there is one.
    var displayLines: [String] {
        if let lines, !lines.isEmpty { return lines }
        return text.components(separatedBy: "\n")
    }
}

/// The header card of a judgment (`/judgment` → `header`).
struct JudgmentHeader: Codable, Equatable, Sendable {
    var court: String?
    var courtLabel: String?
    var title: String?
    var petitioner: String?
    var respondent: String?
    var caseNumber: String?
    var caseType: String?
    var decidedOn: String?
    var year: Int?
    var bench: [String]
    var author: String?
    var citations: [String]
    var neutralCitation: String?
    var source: String?
    var citesCount: Int?
    var citedByCount: Int?

    init() {
        bench = []
        citations = []
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        court = try? c.decodeIfPresent(String.self, forKey: .court)
        courtLabel = try? c.decodeIfPresent(String.self, forKey: .courtLabel)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        petitioner = try? c.decodeIfPresent(String.self, forKey: .petitioner)
        respondent = try? c.decodeIfPresent(String.self, forKey: .respondent)
        caseNumber = try? c.decodeIfPresent(String.self, forKey: .caseNumber)
        caseType = try? c.decodeIfPresent(String.self, forKey: .caseType)
        decidedOn = try? c.decodeIfPresent(String.self, forKey: .decidedOn)
        if let y = try? c.decodeIfPresent(Int.self, forKey: .year) { year = y }
        else if let s = try? c.decodeIfPresent(String.self, forKey: .year) { year = Int(s) } else { year = nil }
        if let list = try? c.decodeIfPresent([String].self, forKey: .bench) { bench = list }
        else if let one = try? c.decodeIfPresent(String.self, forKey: .bench) {
            bench = one.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        } else { bench = [] }
        author = try? c.decodeIfPresent(String.self, forKey: .author)
        citations = (try? c.decodeIfPresent([String].self, forKey: .citations)) ?? []
        neutralCitation = try? c.decodeIfPresent(String.self, forKey: .neutralCitation)
        source = try? c.decodeIfPresent(String.self, forKey: .source)
        citesCount = try? c.decodeIfPresent(Int.self, forKey: .citesCount)
        citedByCount = try? c.decodeIfPresent(Int.self, forKey: .citedByCount)
    }
}

/// A contents entry: a heading, or a `Para n` anchor in a long judgment.
struct JudgmentTOCEntry: Codable, Equatable, Identifiable, Hashable, Sendable {
    var id: String
    var label: String
    var level: Int
}

struct JudgmentStats: Codable, Equatable, Sendable {
    var paragraphs: Int?
    var words: Int?
    var blocks: Int?
    var layout: String?
    var debrisLines: Int?
    var formatMs: Int?
}

/// `GET /judgment?id=` → the structured judgment.
struct JudgmentDocument: Codable, Equatable, Sendable {
    var doc: CatalogueDocument?
    var header: JudgmentHeader?
    var blocks: [JudgmentBlock]
    var toc: [JudgmentTOCEntry]
    var stats: JudgmentStats?
    var formatterVersion: Int?
    var cached: Bool?

    init(doc: CatalogueDocument? = nil, header: JudgmentHeader? = nil, blocks: [JudgmentBlock] = [],
         toc: [JudgmentTOCEntry] = [], stats: JudgmentStats? = nil, formatterVersion: Int? = nil, cached: Bool? = nil) {
        self.doc = doc
        self.header = header
        self.blocks = blocks
        self.toc = toc
        self.stats = stats
        self.formatterVersion = formatterVersion
        self.cached = cached
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        doc = try? c.decodeIfPresent(CatalogueDocument.self, forKey: .doc)
        header = try? c.decodeIfPresent(JudgmentHeader.self, forKey: .header)
        blocks = (try? c.decodeIfPresent([JudgmentBlock].self, forKey: .blocks)) ?? []
        toc = (try? c.decodeIfPresent([JudgmentTOCEntry].self, forKey: .toc)) ?? []
        stats = try? c.decodeIfPresent(JudgmentStats.self, forKey: .stats)
        formatterVersion = try? c.decodeIfPresent(Int.self, forKey: .formatterVersion)
        cached = try? c.decodeIfPresent(Bool.self, forKey: .cached)
    }
}

// MARK: - Errors

/// What the catalogue said when it refused: every error is JSON `{error, …}` with a code.
///
/// Kept apart from `APIError` because the codes carry meaning a screen acts on — `file_missing`
/// is "not on the shelf yet", `cover_pending` is "ask again in five seconds", and
/// `catalogue_unavailable` is a host that has never built the catalogue.
struct LibraryCatalogueError: LocalizedError, Equatable, Sendable {
    var status: Int
    /// `bad_id`, `auth_required`, `not_found`, `unknown_category`, `unknown_library_route`,
    /// `not_an_act`, `not_a_judgment`, `file_missing`, `no_cover`, `cover_pending`, `too_large`,
    /// `catalogue_unavailable`, `search_busy`, `search_timeout`, `library_failed`…
    var code: String
    var message: String?
    /// `no_cover` says why: `not_pdf`, `encrypted`, `render_failed`, `too_large`, `no_pages`,
    /// `outside_root`, `file_missing`.
    var reason: String?
    var retryAfter: Int?

    init(status: Int, code: String, message: String? = nil, reason: String? = nil, retryAfter: Int? = nil) {
        self.status = status
        self.code = code
        self.message = message
        self.reason = reason
        self.retryAfter = retryAfter
    }

    var isMissingRoute: Bool { status == 404 && code == "unknown_library_route" }
    var isUnavailable: Bool { code == "catalogue_unavailable" }
    var isFileMissing: Bool { code == "file_missing" || (code == "no_cover" && reason == "file_missing") }
    var isTooLarge: Bool { code == "too_large" || status == 413 }
    var isBusy: Bool { code == "search_busy" || code == "search_timeout" }

    var errorDescription: String? { message ?? LibraryCatalogueError.wording(for: code, status: status) }

    static func wording(for code: String, status: Int) -> String {
        switch code {
        case "catalogue_unavailable": return "The library catalogue has not been built on this server yet."
        case "auth_required": return "Sign in to use the Library."
        case "not_found": return "There is no such document in the library."
        case "unknown_category": return "The library has no such collection."
        case "unknown_library_route": return "This server does not offer that part of the library yet."
        case "not_an_act": return "This document is not part of the Bare Acts."
        case "not_a_judgment": return "This document is not a judgment."
        case "file_missing": return "This document is listed in the catalogue, but its file has not been copied to this server yet."
        case "too_large": return "This document is too long to open in the reader. Download the original to read all of it."
        case "search_busy", "search_timeout": return "The library is busy searching for other readers. Try again in a moment."
        case "missing_query": return "Type something to search for."
        case "bad_id": return "That link does not name a document."
        default: return "The library did not answer (\(status)). Try again in a moment."
        }
    }
}
