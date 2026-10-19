import Foundation

// The rest of a matter, as the web's Matters workspace holds it (docs/projects.md): tasks and
// deadlines, the fee ledger, the people, the linked court case — and the vocabularies every
// form on it agrees on. "Matter" is the word on screen; the API and the tables keep "project".
//
// All ids are TEXT from `genId`; every timestamp is whatever SQLite or JavaScript wrote, so each
// is kept raw and read through `WireDate`. Money is stored in paise and returned both ways:
// `amount` in rupees as a number, `amount_paise` as an integer.

// MARK: - Tasks

/// A row of `project_tasks`: something to do on the matter, by a day.
struct ProjectTask: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var projectID: String?
    var title: String?
    var notes: String?
    /// `YYYY-MM-DD` or null — a day in India, as every court day is.
    var dueDateRaw: String?
    /// One of `MatterVocabulary.taskKinds`; carried raw and labelled through the vocabulary, so a
    /// kind this build has not heard of still labels itself.
    var kind: String?
    var priority: String?
    /// `open` or `done`.
    var status: String?
    var completedAtRaw: String?
    var createdAtRaw: String?
    var updatedAtRaw: String?

    var isDone: Bool { status?.caseInsensitiveCompare("done") == .orderedSame }
    var dueDate: Date? { WireDate.parseDay(dueDateRaw) }
    var isHighPriority: Bool { priority?.caseInsensitiveCompare("high") == .orderedSame }

    var displayTitle: String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Untitled task" : trimmed
    }

    var kindLabel: String { MatterVocabulary.label(for: kind, in: MatterVocabulary.taskKinds) ?? "Task" }

    /// Overdue: open, dated, and the day has passed in India.
    func isOverdue(todayKey: String) -> Bool {
        guard !isDone, let dueDateRaw, !dueDateRaw.isEmpty else { return false }
        return dueDateRaw < todayKey
    }

    enum CodingKeys: String, CodingKey {
        case id, title, notes, kind, priority, status
        case projectID = "project_id"
        case dueDateRaw = "due_date"
        case completedAtRaw = "completed_at"
        case createdAtRaw = "created_at"
        case updatedAtRaw = "updated_at"
    }
}

// MARK: - Money

/// A row of `project_ledger`: a fee billed, a payment received, or an expense paid.
struct LedgerEntry: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var projectID: String?
    /// `fee`, `payment` or `expense`.
    var kind: String?
    var title: String?
    /// Rupees, as the API returns them. The stored integer is `amountPaise`; this is derived from
    /// it server-side and is what every screen shows.
    var amount: Double?
    var amountPaise: Int?
    var entryDateRaw: String?
    /// `cash`, `upi`, `bank`, `cheque`, `card`, `other` — payments only.
    var mode: String?
    var reference: String?
    /// An expense's head — `court_fee`, `stamp_duty`, … — expenses only.
    var category: String?
    var receiptFile: String?
    var notes: String?
    var createdAtRaw: String?

    enum Kind: String, Sendable { case fee, payment, expense }

    var entryKind: Kind? { kind.flatMap { Kind(rawValue: $0.lowercased()) } }
    var entryDate: Date? { WireDate.parseDay(entryDateRaw) }

    /// Rupees, preferring the exact integer when both arrived. `amount` is a JavaScript number
    /// and `amount_paise / 100` is the figure it was made from.
    var rupees: Double {
        if let amountPaise { return Double(amountPaise) / 100 }
        return amount ?? 0
    }

    var displayTitle: String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        switch entryKind {
        case .fee: return "Fee"
        case .payment: return "Payment received"
        case .expense: return MatterVocabulary.label(for: category, in: MatterVocabulary.expenseCategories) ?? "Expense"
        case nil: return "Entry"
        }
    }

    /// The second line: the payment mode and reference, or the expense head.
    var detail: String? {
        switch entryKind {
        case .payment:
            let mode = MatterVocabulary.label(for: self.mode, in: MatterVocabulary.paymentModes)
            let ref = reference?.trimmingCharacters(in: .whitespacesAndNewlines)
            return [mode, (ref?.isEmpty ?? true) ? nil : ref].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
        case .expense:
            guard title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return nil }
            return MatterVocabulary.label(for: category, in: MatterVocabulary.expenseCategories)
        default:
            return nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, title, amount, mode, reference, category, notes
        case projectID = "project_id"
        case amountPaise = "amount_paise"
        case entryDateRaw = "entry_date"
        case receiptFile = "receipt_file"
        case createdAtRaw = "created_at"
    }
}

/// `totals` on `GET /project`: rupees, already summed by the server.
struct LedgerTotals: Codable, Equatable, Sendable {
    var billed: Double?
    var received: Double?
    var outstanding: Double?
    var expenses: Double?

    static let zero = LedgerTotals(billed: 0, received: 0, outstanding: 0, expenses: 0)

    /// Share of the fee that has been paid, for the ring on the Fees tile. `nil` when nothing has
    /// been billed — there is no share of nothing.
    var paidFraction: Double? {
        guard let billed, billed > 0 else { return nil }
        return min(1, max(0, (received ?? 0) / billed))
    }
}

/// Rupees for display — `₹1,25,000`, `₹1,25,000.50` — in the Indian grouping the web's `inr()`
/// uses. Whole rupees print without decimals; anything with paise prints both digits, never one.
enum MatterMoney {
    static func inr(_ rupees: Double) -> String {
        let paise = Int((rupees * 100).rounded())
        let negative = paise < 0
        let whole = abs(paise) / 100
        let fraction = abs(paise) % 100
        var text = "₹" + grouped(whole)
        if fraction != 0 { text += String(format: ".%02d", fraction) }
        return negative ? "-" + text : text
    }

    /// Indian digit grouping: the last three digits, then pairs — 12,34,567.
    static func grouped(_ value: Int) -> String {
        let digits = String(value)
        guard digits.count > 3 else { return digits }
        let head = String(digits.dropLast(3))
        let tail = String(digits.suffix(3))
        var pairs: [String] = []
        var rest = Substring(head)
        while rest.count > 2 {
            pairs.insert(String(rest.suffix(2)), at: 0)
            rest = rest.dropLast(2)
        }
        if !rest.isEmpty { pairs.insert(String(rest), at: 0) }
        return (pairs + [tail]).joined(separator: ",")
    }
}

// MARK: - People

/// A row of `project_people`: a party, a counsel, the bench, a witness.
struct ProjectPerson: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var projectID: String?
    /// One of `MatterVocabulary.peopleRoles`.
    var role: String?
    var name: String?
    var phone: String?
    var email: String?
    var address: String?
    var notes: String?
    var createdAtRaw: String?

    var displayName: String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Unnamed" : trimmed
    }

    var roleLabel: String { MatterVocabulary.label(for: role, in: MatterVocabulary.peopleRoles) ?? "Other" }

    var isClient: Bool { role?.caseInsensitiveCompare("client") == .orderedSame }

    /// Whether there is a way to reach them.
    var isReachable: Bool {
        !(phone?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            || !(email?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    /// Phone and email on one line.
    var contactLine: String? {
        [phone, email]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
            .nilIfEmpty
    }

    enum CodingKeys: String, CodingKey {
        case id, role, name, phone, email, address, notes
        case projectID = "project_id"
        case createdAtRaw = "created_at"
    }
}

// MARK: - The linked case

/// `linkedCase` on `GET /project`: the tracked case this matter follows, as the server summarises
/// it — only when the caller is on the case's team.
struct LinkedCaseSummary: Codable, Equatable, Sendable {
    var id: String?
    var title: String?
    var courtName: String?
    var courtType: String?
    var caseType: String?
    var caseNumber: String?
    var caseYear: String?
    var cnr: String?
    var nextHearingDateRaw: String?
    var stage: String?
    var status: String?
    var lastSyncedAtRaw: String?

    var nextHearingDate: Date? { WireDate.parseDay(nextHearingDateRaw) ?? WireDate.parseAny(nextHearingDateRaw) }
    var lastSyncedAt: Date? { WireDate.parseAny(lastSyncedAtRaw) }

    enum CodingKeys: String, CodingKey {
        case id, title, cnr, stage, status
        case courtName = "court_name"
        case courtType = "court_type"
        case caseType = "case_type"
        case caseNumber = "case_number"
        case caseYear = "case_year"
        case nextHearingDateRaw = "next_hearing_date"
        case lastSyncedAtRaw = "last_synced_at"
    }

    /// `case_number` and `case_year` are TEXT columns that a JSON number round-trips into; a
    /// server that stores a number answers one. Read either.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeFlexibleString(forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        courtName = try c.decodeIfPresent(String.self, forKey: .courtName)
        courtType = try c.decodeIfPresent(String.self, forKey: .courtType)
        caseType = try c.decodeIfPresent(String.self, forKey: .caseType)
        caseNumber = try c.decodeFlexibleString(forKey: .caseNumber)
        caseYear = try c.decodeFlexibleString(forKey: .caseYear)
        cnr = try c.decodeIfPresent(String.self, forKey: .cnr)
        nextHearingDateRaw = try c.decodeIfPresent(String.self, forKey: .nextHearingDateRaw)
        stage = try c.decodeIfPresent(String.self, forKey: .stage)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        lastSyncedAtRaw = try c.decodeIfPresent(String.self, forKey: .lastSyncedAtRaw)
    }

    init(id: String? = nil, title: String? = nil, courtName: String? = nil, nextHearingDateRaw: String? = nil) {
        self.id = id
        self.title = title
        self.courtName = courtName
        self.nextHearingDateRaw = nextHearingDateRaw
    }
}

extension KeyedDecodingContainer {
    /// A value a TEXT column holds but a JSON writer may have sent as a number.
    func decodeFlexibleString(forKey key: Key) throws -> String? {
        if let text = try? decodeIfPresent(String.self, forKey: key) { return text }
        if let number = try? decodeIfPresent(Int.self, forKey: key) { return String(number) }
        if let number = try? decodeIfPresent(Double.self, forKey: key) { return String(number) }
        return nil
    }
}

// MARK: - Files attached to a matter

/// One line of `POST /project-attach`'s answer: what became of each document asked for.
struct AttachedFile: Codable, Equatable, Sendable {
    var name: String?
    var folder: String?
    /// `indexing` (copied, being read), `ready` (an image-only scan), or `skipped`.
    var status: String?
    /// Why it was skipped, in the server's words.
    var reason: String?

    var wasAttached: Bool { status != "skipped" }

    /// "Plaint.pdf" or "Plaint.pdf — already in this matter".
    var line: String {
        let shown = DisplayText.fileName(name ?? "Document")
        guard !wasAttached, let reason, !reason.isEmpty else { return shown }
        return "\(shown) — \(reason)"
    }
}

// MARK: - Vocabularies

/// The fixed vocabularies of a matter, as the web lists them (`src/lib/projectsApi.js`), with
/// the server's keys and the labels a form shows. Order is the web's.
enum MatterVocabulary {
    typealias Option = (key: String, label: String)

    static let practiceAreas: [Option] = [
        ("civil", "Civil"), ("criminal", "Criminal"), ("writ", "Writ / constitutional"),
        ("arbitration", "Arbitration"), ("consumer", "Consumer"), ("family", "Family"),
        ("labour", "Labour & service"), ("tax", "Tax"), ("ipr", "IPR"), ("property", "Property"),
        ("corporate", "Corporate"), ("insolvency", "Insolvency"), ("other", "Other"),
    ]
    static let ourSides: [Option] = [
        ("petitioner", "Petitioner"), ("respondent", "Respondent"), ("plaintiff", "Plaintiff"),
        ("defendant", "Defendant"), ("appellant", "Appellant"), ("complainant", "Complainant"),
        ("accused", "Accused"), ("applicant", "Applicant"), ("other", "Other"),
    ]
    static let taskKinds: [Option] = [
        ("task", "Task"), ("deadline", "Deadline"), ("limitation", "Limitation"), ("filing", "Filing"),
        ("certified_copy", "Certified copy"), ("compliance", "Compliance"), ("hearing_prep", "Hearing prep"),
    ]
    static let expenseCategories: [Option] = [
        ("court_fee", "Court fee"), ("stamp_duty", "Stamp duty"), ("process_fee", "Process fee"),
        ("clerkage", "Clerkage"), ("typing_copies", "Typing & copies"), ("certified_copies", "Certified copies"),
        ("travel", "Travel"), ("notary", "Notary / oath"), ("other", "Other"),
    ]
    static let paymentModes: [Option] = [
        ("upi", "UPI"), ("bank", "Bank transfer"), ("cheque", "Cheque"), ("cash", "Cash"),
        ("card", "Card"), ("other", "Other"),
    ]
    static let peopleRoles: [Option] = [
        ("client", "Client"), ("opposite_party", "Opposite party"), ("opposing_counsel", "Opposing counsel"),
        ("our_counsel", "Our counsel"), ("judge", "Judge / bench"), ("witness", "Witness"), ("other", "Other"),
    ]
    /// Chronology kinds. `event` is a dated fact from the record; the rest are the older kinds.
    static let updateKinds: [Option] = [
        ("event", "Event"), ("hearing", "Hearing"), ("order", "Order"), ("filing", "Filing"),
        ("note", "Note"), ("milestone", "Milestone"), ("task", "Task"),
    ]
    /// The five folders every matter is made with, and the only destinations an attach offers.
    static let standardFolders = ["Pleadings", "Orders", "Evidence", "Correspondence", "Receipts"]

    /// The label for a stored key, or a tidied form of the key when it is not in the list — an
    /// unknown value must still name itself rather than render blank.
    static func label(for key: String?, in options: [Option]) -> String? {
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return nil }
        if let known = options.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) {
            return known.label
        }
        return key.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

// MARK: - What a form sends

/// A new or edited task. Every field optional but the title, so an edit sends only what changed
/// — the route keeps a stored value it is not sent.
struct TaskDraft: Equatable, Sendable {
    var title: String
    var notes: String?
    /// A day in India, `YYYY-MM-DD`.
    var dueDate: String?
    var kind: String?
    var priority: String?
    var status: String?
}

struct LedgerDraft: Equatable, Sendable {
    var kind: LedgerEntry.Kind
    var title: String?
    /// Rupees. The server stores paise.
    var amount: Double
    var entryDate: String?
    var mode: String?
    var reference: String?
    var category: String?
    var notes: String?
}

struct PersonDraft: Equatable, Sendable {
    var role: String
    var name: String
    var phone: String?
    var email: String?
    var address: String?
    var notes: String?
}

/// A chronology entry. `source` is `manual` from this client; the server stamps `court` and
/// the AI extraction `ai`.
struct UpdateDraft: Equatable, Sendable {
    var kind: String
    var title: String
    var body: String?
    /// A day in India, `YYYY-MM-DD`; the server also reads a month or a year alone.
    var eventDate: String?
}

/// A new matter: the three things New matter asks for, and the facts the first screen can fill.
struct MatterDraft: Equatable, Sendable {
    var name: String
    var client: String? = nil
    var practiceArea: String? = nil
    var ourSide: String? = nil
    var oppositeParty: String? = nil
    var color: String? = nil
    var banner: String? = nil
    /// `not_filed` when the matter has no court case yet by the user's own say-so.
    var courtStatus: String? = nil
}

// MARK: - Envelopes

struct ProjectFromCaseResponse: Codable, Sendable {
    var success: Bool?
    var project: Project?
    /// `true` when the caller already had a matter for the case and that one was returned.
    var existed: Bool?
    var error: String?
}

struct ProjectWriteResponse: Codable, Sendable {
    var success: Bool?
    var project: Project?
    var error: String?
}

struct ProjectTaskResponse: Codable, Sendable {
    var success: Bool?
    var task: ProjectTask?
    var error: String?
}

struct ProjectLedgerResponse: Codable, Sendable {
    var success: Bool?
    var entry: LedgerEntry?
    var error: String?
}

struct ProjectPersonResponse: Codable, Sendable {
    var success: Bool?
    var person: ProjectPerson?
    var error: String?
}

struct ProjectUpdateWriteResponse: Codable, Sendable {
    var success: Bool?
    var id: String?
    var error: String?
}

/// `GET /project-files`: the matter's own tree, in `/user-files`' item shape. `folders` holds
/// the sub-folders (each with its files) and `files` the loose ones at the matter's root.
struct ProjectFilesResponse: Codable, Sendable {
    var success: Bool?
    var root: String?
    var folders: [FileNode]?
    var files: [FileNode]?
    var error: String?
}

struct ProjectAttachResponse: Codable, Sendable {
    var success: Bool?
    var folder: String?
    var files: [AttachedFile]?
    var error: String?
}

struct ProjectCaseRefreshResponse: Codable, Sendable {
    var success: Bool?
    var lastSyncedAt: String?
    var error: String?
    /// Seconds until the court may be asked again, on a 429.
    var retryAfter: Int?
}

