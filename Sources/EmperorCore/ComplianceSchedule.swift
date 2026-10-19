import Foundation

// A company's statutory deadlines, generated on the device from a profile the user describes.
//
// A port of the web's `src/lib/complianceSchedule.js`: the obligations, which profile switches
// they depend on, and `generateComplianceEvents`, which turns them into dated deadlines for a
// window of days. The web keeps the profiles in the browser (`localStorage`) and never sends
// them to the server; this client keeps them on the device the same way (`CompanyProfileStore`).
// Held to the web's own output by `scripts/generate-compliance-schedule-fixtures.mjs`.

/// A company the user has described, which decides which statutory deadlines apply.
///
/// The web's company object (`newCompany()` plus an `id`), with the same keys, so a profile reads
/// the same here as there. Every switch is off until the user turns it on: nothing is assumed.
struct CompanyProfile: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var listed = false
    var hasEmployees = false
    var gstRegistered = false
    /// FDI, ODI or foreign remittances — FEMA returns and transfer pricing.
    var foreignDealings = false
    /// Turnover over the s.44AB threshold.
    var taxAudit = false
    /// Meets the CSR trigger.
    var csr = false
    /// For Professional Tax; empty when not set.
    var state = ""
    /// The AGM's month, 1-indexed. The web's default is 30 September.
    var agmMonth = 9
    var agmDay = 30

    init(id: String, name: String = "") {
        self.id = id
        self.name = name
    }

    enum CodingKeys: String, CodingKey {
        case id, name, listed, hasEmployees, gstRegistered, foreignDealings, taxAudit, csr, state
        case agmMonth, agmDay
    }

    /// Lenient, as the web is: its `localStorage` copy is whatever an older page wrote, and a
    /// missing or odd key costs that switch, not every company.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        func flag(_ key: CodingKeys) -> Bool { ((try? c.decodeIfPresent(Bool.self, forKey: key)) ?? nil) ?? false }
        listed = flag(.listed)
        hasEmployees = flag(.hasEmployees)
        gstRegistered = flag(.gstRegistered)
        foreignDealings = flag(.foreignDealings)
        taxAudit = flag(.taxAudit)
        csr = flag(.csr)
        state = ((try? c.decodeIfPresent(String.self, forKey: .state)) ?? nil) ?? ""
        agmMonth = ((try? c.decodeIfPresent(Int.self, forKey: .agmMonth)) ?? nil) ?? 9
        agmDay = ((try? c.decodeIfPresent(Int.self, forKey: .agmDay)) ?? nil) ?? 30
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled company" : trimmed
    }

    /// The web's `profileSummary` — the "tailored for" line.
    var summary: String {
        var bits = [listed ? "Listed company" : "Unlisted company"]
        if gstRegistered { bits.append("GST-registered") }
        if hasEmployees { bits.append("with employees") }
        if foreignDealings { bits.append("FDI/ODI") }
        if !state.isEmpty { bits.append(state) }
        return bits.joined(separator: " · ")
    }

    /// What the web's form refuses before saving.
    var validationError: String? {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Enter a company name." : nil
    }

    /// "30 September".
    var agmLabel: String {
        let month = (1...12).contains(agmMonth) ? agmMonth : 9
        return "\(agmDay > 0 ? agmDay : 30) \(CourtCalendar.monthNames[month - 1])"
    }

    /// The days a month offers in the AGM picker. The web's picker is a date input fixed to 2025,
    /// so 29 February is never offered.
    static func agmDays(inMonth month: Int) -> ClosedRange<Int> {
        switch month {
        case 2: return 1...28
        case 4, 6, 9, 11: return 1...30
        default: return 1...31
        }
    }

    /// A new id in the web's shape, `co-<base36 millis>-<0…9999>`.
    static func newID(now: Date = Date(), random: Int = Int.random(in: 0..<10_000)) -> String {
        let millis = Int64((now.timeIntervalSince1970 * 1000).rounded(.down))
        return "co-" + String(millis, radix: 36) + "-" + String(random)
    }

    /// The six switches, read and written by name so a form can bind to each.
    subscript(flag: CompanyProfileSwitch) -> Bool {
        get {
            switch flag {
            case .listed: return listed
            case .hasEmployees: return hasEmployees
            case .gstRegistered: return gstRegistered
            case .foreignDealings: return foreignDealings
            case .taxAudit: return taxAudit
            case .csr: return csr
            }
        }
        set {
            switch flag {
            case .listed: listed = newValue
            case .hasEmployees: hasEmployees = newValue
            case .gstRegistered: gstRegistered = newValue
            case .foreignDealings: foreignDealings = newValue
            case .taxAudit: taxAudit = newValue
            case .csr: csr = newValue
            }
        }
    }
}

/// The company form's six switches, in its order and with its wording (`CompanyModal`).
enum CompanyProfileSwitch: String, CaseIterable, Identifiable, Sendable {
    case listed, hasEmployees, gstRegistered, foreignDealings, taxAudit, csr

    var id: String { rawValue }

    var label: String {
        switch self {
        case .listed: return "Listed company"
        case .hasEmployees: return "Has employees"
        case .gstRegistered: return "GST registered"
        case .foreignDealings: return "FDI / ODI / foreign remittances"
        case .taxAudit: return "Subject to tax audit (s.44AB)"
        case .csr: return "Meets the CSR trigger"
        }
    }

    var hint: String {
        switch self {
        case .listed: return "Adds SEBI / LODR periodic filings."
        case .hasEmployees: return "Adds EPF, ESI, Professional Tax and the POSH annual report."
        case .gstRegistered: return "Adds GSTR-1, GSTR-3B and the annual GST return."
        case .foreignDealings: return "Adds FEMA (FLA, APR) and transfer-pricing (3CEB)."
        case .taxAudit: return "Adds the tax audit report deadline."
        case .csr: return "Adds the CSR-2 report."
        }
    }
}

/// The obligations and the generator.
enum ComplianceSchedule {

    /// The rule that dates an obligation. Months are 1-indexed, as in the web's data.
    enum Rule: Sendable {
        case annual(month: Int, day: Int)
        case afterAGM(days: Int)
        /// Fixed dates every year (the web's `quarterly` and `custom` kinds).
        case dates([(month: Int, day: Int)])
        /// Once a month, on `day`, except in the months `overrides` names.
        case monthly(day: Int, overrides: [Int: (day: Int, note: String)])
    }

    enum Condition: String, Sendable {
        case listed, hasEmployees, gstRegistered, foreignDealings, taxAudit, csr
        /// Employees, and a state that levies Professional Tax.
        case professionalTax
    }

    struct Obligation: Sendable {
        let id: String
        let category: ComplianceCategory
        let name: String
        let frequency: String
        let authority: String
        let rule: Rule
        let description: String
        let condition: Condition?

        func applies(to profile: CompanyProfile) -> Bool {
            switch condition {
            case nil: return true
            case .listed: return profile.listed
            case .hasEmployees: return profile.hasEmployees
            case .gstRegistered: return profile.gstRegistered
            case .foreignDealings: return profile.foreignDealings
            case .taxAudit: return profile.taxAudit
            case .csr: return profile.csr
            case .professionalTax:
                return profile.hasEmployees && !profile.state.isEmpty
                    && ComplianceSchedule.professionalTaxStates.contains(profile.state)
            }
        }
    }

    /// One generated deadline.
    struct Deadline: Equatable, Sendable {
        /// `stat:<obligation>:<YYYY-MM-DD>` — the id the web marks done under.
        let id: String
        let obligationID: String
        let dateKey: String
        /// Set when the month moves the usual day ("TDS deducted in March is due 30 April.").
        let overrideNote: String?
    }

    /// States that levy Professional Tax (`PT_STATES`).
    static let professionalTaxStates: [String] = [
        "Andhra Pradesh", "Assam", "Bihar", "Gujarat", "Jharkhand", "Karnataka", "Kerala",
        "Madhya Pradesh", "Maharashtra", "Manipur", "Meghalaya", "Mizoram", "Nagaland",
        "Odisha", "Puducherry", "Sikkim", "Tamil Nadu", "Telangana", "Tripura", "West Bengal",
    ]

    /// The picker's states (`INDIAN_STATES`), including those with no Professional Tax.
    static let indianStates: [String] = [
        "Andhra Pradesh", "Assam", "Bihar", "Chhattisgarh", "Delhi", "Goa", "Gujarat", "Haryana",
        "Himachal Pradesh", "Jharkhand", "Karnataka", "Kerala", "Madhya Pradesh", "Maharashtra",
        "Manipur", "Meghalaya", "Mizoram", "Nagaland", "Odisha", "Puducherry", "Punjab",
        "Rajasthan", "Sikkim", "Tamil Nadu", "Telangana", "Tripura", "Uttar Pradesh",
        "Uttarakhand", "West Bengal",
    ]

    // swiftlint:disable line_length
    /// `COMPLIANCE_OBLIGATIONS`, in the web's order.
    static let obligations: [Obligation] = [
        // MCA / Companies Act 2013
        Obligation(id: "aoc4", category: .mca, name: "AOC-4 — Financial Statements", frequency: "Annual", authority: "Companies Act 2013, s.137", rule: .afterAGM(days: 30), description: "File the audited financial statements with the ROC within 30 days of the AGM.", condition: nil),
        Obligation(id: "mgt7", category: .mca, name: "MGT-7 — Annual Return", frequency: "Annual", authority: "Companies Act 2013, s.92", rule: .afterAGM(days: 60), description: "File the annual return with the ROC within 60 days of the AGM.", condition: nil),
        Obligation(id: "adt1", category: .mca, name: "ADT-1 — Auditor Appointment", frequency: "On appointment", authority: "Companies Act 2013, s.139", rule: .afterAGM(days: 15), description: "Intimate the ROC of an auditor appointment/ratification within 15 days of the AGM.", condition: nil),
        Obligation(id: "dir3kyc", category: .mca, name: "DIR-3 KYC — Director KYC", frequency: "Annual", authority: "Companies (Appt. & Qual. of Directors) Rules, r.12A", rule: .annual(month: 9, day: 30), description: "Every DIN holder must file KYC by 30 September each year.", condition: nil),
        Obligation(id: "dpt3", category: .mca, name: "DPT-3 — Return of Deposits", frequency: "Annual", authority: "Companies (Acceptance of Deposits) Rules, r.16", rule: .annual(month: 6, day: 30), description: "Annual return of deposits and outstanding non-deposit money as on 31 March.", condition: nil),
        Obligation(id: "msme1", category: .mca, name: "MSME-1 — Dues to MSME suppliers", frequency: "Half-yearly", authority: "Companies Act 2013, s.405", rule: .dates([(4, 30), (10, 31)]), description: "Half-yearly return of outstanding payments to MSME vendors pending beyond 45 days.", condition: nil),
        Obligation(id: "csr2", category: .mca, name: "CSR-2 — CSR Report", frequency: "Annual", authority: "Companies Act 2013, s.135", rule: .afterAGM(days: 30), description: "Report on CSR spending (filed as an addendum to AOC-4).", condition: .csr),
        Obligation(id: "agm", category: .mca, name: "Annual General Meeting", frequency: "Annual", authority: "Companies Act 2013, s.96", rule: .annual(month: 9, day: 30), description: "Hold the AGM within 6 months of the financial-year end (by 30 September).", condition: nil),
        Obligation(id: "board", category: .mca, name: "Board Meeting", frequency: "Quarterly", authority: "Companies Act 2013, s.173", rule: .dates([(6, 30), (9, 30), (12, 31), (3, 31)]), description: "Hold a board meeting — minimum 4 per year with a gap of no more than 120 days.", condition: nil),
        // Income Tax
        Obligation(id: "advtax1", category: .incometax, name: "Advance Tax — 1st instalment (15%)", frequency: "Quarterly", authority: "Income-tax Act, s.211", rule: .annual(month: 6, day: 15), description: "Pay 15% of the estimated annual tax by 15 June.", condition: nil),
        Obligation(id: "advtax2", category: .incometax, name: "Advance Tax — 2nd instalment (45%)", frequency: "Quarterly", authority: "Income-tax Act, s.211", rule: .annual(month: 9, day: 15), description: "Cumulative 45% of the estimated annual tax by 15 September.", condition: nil),
        Obligation(id: "advtax3", category: .incometax, name: "Advance Tax — 3rd instalment (75%)", frequency: "Quarterly", authority: "Income-tax Act, s.211", rule: .annual(month: 12, day: 15), description: "Cumulative 75% of the estimated annual tax by 15 December.", condition: nil),
        Obligation(id: "advtax4", category: .incometax, name: "Advance Tax — 4th instalment (100%)", frequency: "Quarterly", authority: "Income-tax Act, s.211", rule: .annual(month: 3, day: 15), description: "Cumulative 100% of the estimated annual tax by 15 March.", condition: nil),
        Obligation(id: "taxaudit", category: .incometax, name: "Tax Audit Report (3CA/3CB-3CD)", frequency: "Annual", authority: "Income-tax Act, s.44AB", rule: .annual(month: 9, day: 30), description: "File the tax audit report by 30 September.", condition: .taxAudit),
        Obligation(id: "itr6", category: .incometax, name: "Income Tax Return (ITR-6)", frequency: "Annual", authority: "Income-tax Act, s.139(1)", rule: .annual(month: 10, day: 31), description: "File the company income tax return by 31 October (audit cases).", condition: nil),
        Obligation(id: "tp3ceb", category: .incometax, name: "Form 3CEB — Transfer Pricing", frequency: "Annual", authority: "Income-tax Act, s.92E", rule: .annual(month: 10, day: 31), description: "Accountant's report on international / specified domestic transactions.", condition: .foreignDealings),
        // TDS / TCS
        Obligation(id: "tdspay", category: .tds, name: "TDS Payment", frequency: "Monthly", authority: "Income-tax Act, s.200", rule: .monthly(day: 7, overrides: [4: (30, "TDS deducted in March is due 30 April.")]), description: "Deposit TDS by the 7th of the following month (March deductions by 30 April).", condition: nil),
        Obligation(id: "tdsreturn", category: .tds, name: "TDS Return (24Q / 26Q / 27Q)", frequency: "Quarterly", authority: "Income-tax Act, s.200(3)", rule: .dates([(7, 31), (10, 31), (1, 31), (5, 31)]), description: "File the quarterly TDS statement (Q4 is due 31 May).", condition: nil),
        // GST
        Obligation(id: "gstr1", category: .gst, name: "GSTR-1 — Outward Supplies", frequency: "Monthly", authority: "CGST Act", rule: .monthly(day: 11, overrides: [:]), description: "Monthly statement of outward supplies by the 11th (QRMP filers: 13th of the month after the quarter).", condition: .gstRegistered),
        Obligation(id: "gstr3b", category: .gst, name: "GSTR-3B — Summary Return", frequency: "Monthly", authority: "CGST Act", rule: .monthly(day: 20, overrides: [:]), description: "Monthly summary return and tax payment by the 20th.", condition: .gstRegistered),
        Obligation(id: "gstr9", category: .gst, name: "GSTR-9 / 9C — Annual Return", frequency: "Annual", authority: "CGST Act", rule: .annual(month: 12, day: 31), description: "Annual GST return (9C reconciliation if turnover exceeds ₹5 crore).", condition: .gstRegistered),
        // EPF & ESI
        Obligation(id: "epf", category: .epf, name: "EPF — ECR & Contribution", frequency: "Monthly", authority: "EPF & MP Act 1952", rule: .monthly(day: 15, overrides: [:]), description: "Upload the ECR and pay the EPF contribution by the 15th.", condition: .hasEmployees),
        Obligation(id: "esi", category: .epf, name: "ESI — Contribution", frequency: "Monthly", authority: "ESI Act 1948", rule: .monthly(day: 15, overrides: [:]), description: "Pay the ESI contribution by the 15th.", condition: .hasEmployees),
        // Labour & POSH
        Obligation(id: "pt", category: .labour, name: "Professional Tax", frequency: "Monthly", authority: "State Professional Tax Act", rule: .monthly(day: 21, overrides: [:]), description: "Deposit Professional Tax (due date and rates vary by state).", condition: .professionalTax),
        Obligation(id: "posh", category: .labour, name: "POSH — Annual Report", frequency: "Annual", authority: "POSH Act 2013, s.21-22", rule: .annual(month: 1, day: 31), description: "Internal Committee files its annual report with the District Officer (required at 10+ employees).", condition: .hasEmployees),
        // SEBI / LODR
        Obligation(id: "sebiresults", category: .sebi, name: "Financial Results", frequency: "Quarterly", authority: "SEBI LODR, Reg. 33", rule: .dates([(8, 14), (11, 14), (2, 14), (5, 30)]), description: "Quarterly results within 45 days of quarter-end (annual within 60 days).", condition: .listed),
        Obligation(id: "sebishp", category: .sebi, name: "Shareholding Pattern", frequency: "Quarterly", authority: "SEBI LODR, Reg. 31", rule: .dates([(7, 21), (10, 21), (1, 21), (4, 21)]), description: "File the shareholding pattern within 21 days of quarter-end.", condition: .listed),
        Obligation(id: "sebicg", category: .sebi, name: "Corporate Governance Report", frequency: "Quarterly", authority: "SEBI LODR, Reg. 27(2)", rule: .dates([(7, 21), (10, 21), (1, 21), (4, 21)]), description: "File the corporate governance report within 21 days of quarter-end.", condition: .listed),
        // FEMA / RBI
        Obligation(id: "fla", category: .fema, name: "FLA Return", frequency: "Annual", authority: "FEMA 1999 (RBI)", rule: .annual(month: 7, day: 15), description: "Annual Foreign Liabilities & Assets return (position as on 31 March).", condition: .foreignDealings),
        Obligation(id: "apr", category: .fema, name: "APR — Overseas Investment", frequency: "Annual", authority: "FEMA (OI Rules 2022)", rule: .annual(month: 12, day: 31), description: "Annual Performance Report for overseas direct investment.", condition: .foreignDealings),
    ]
    // swiftlint:enable line_length

    static let obligationsByID: [String: Obligation] =
        Dictionary(uniqueKeysWithValues: obligations.map { ($0.id, $0) })

    /// Every deadline falling within `from...to` (inclusive `YYYY-MM-DD` keys) for this profile,
    /// in date order — `generateComplianceEvents`.
    ///
    /// The arithmetic is the JavaScript `Date`'s: a day past the end of a month rolls into the
    /// next (`new Date(y, m, 31)` in a 30-day month is the 1st), which the web relies on for
    /// nothing today but is kept so the two cannot disagree on a later rule.
    static func generate(from: String, to: String, profile: CompanyProfile) -> [Deadline] {
        guard let start = CivilDay(key: from), let end = CivilDay(key: to) else { return [] }
        var out: [(Deadline, Int)] = []
        func push(_ obligation: Obligation, _ day: CivilDay, note: String? = nil) {
            guard day >= start, day <= end else { return }
            let key = day.key
            out.append((Deadline(id: "stat:\(obligation.id):\(key)", obligationID: obligation.id,
                                 dateKey: key, overrideNote: note), out.count))
        }
        let years = Array(start.year...end.year)

        for obligation in obligations where obligation.applies(to: profile) {
            switch obligation.rule {
            case .annual(let month, let day):
                for year in years { push(obligation, CivilDay(year: year, month: month, day: day)) }
            case .afterAGM(let days):
                // `profile.agmMonth || 9`: a zero is "not set".
                let month = profile.agmMonth == 0 ? 9 : profile.agmMonth
                let day = profile.agmDay == 0 ? 30 : profile.agmDay
                for year in years {
                    push(obligation, CivilDay(year: year, month: month, day: day).adding(days: days))
                }
            case .dates(let dates):
                for year in years {
                    for date in dates { push(obligation, CivilDay(year: year, month: date.month, day: date.day)) }
                }
            case .monthly(let day, let overrides):
                var year = start.year, month = start.month
                while (year, month) <= (end.year, end.month) {
                    let override = overrides[month]
                    push(obligation, CivilDay(year: year, month: month, day: override?.day ?? day),
                         note: override?.note)
                    month += 1
                    if month > 12 { month = 1; year += 1 }
                }
            }
        }
        // The web's sort is by key alone and stable; the index keeps it so.
        return out.sorted { ($0.0.dateKey, $0.1) < ($1.0.dateKey, $1.1) }.map(\.0)
    }

    /// The page's window around a day: 60 days back, 366 ahead (`ComplianceCalendar.jsx`).
    static func window(around todayKey: String) -> (from: String, to: String)? {
        guard let today = CivilDay(key: todayKey) else { return nil }
        return (today.adding(days: -60).key, today.adding(days: 366).key)
    }

    /// The pipeline's obligation codes the generator already produces (`PIPELINE_OVERLAPS_LOCAL`).
    /// Once a company is described, the feed's copy of these is dropped, so one filing is not
    /// shown twice with two different dates.
    static let pipelineOverlaps: Set<String> = [
        "AOC4", "MGT7", "DPT3", "MSME1", "CSR2", "ADVTAX", "ITR", "TAXAUDIT", "TDS",
        "F3CEB", "GSTR1", "GSTR3B", "GSTR9", "EPF", "ESIC", "FLA", "APR",
    ]

    /// A generated deadline in the feed's own shape, so the screen draws both alike.
    static func row(for deadline: Deadline) -> StatutoryDeadline? {
        guard let obligation = obligationsByID[deadline.obligationID] else { return nil }
        var row = StatutoryDeadline(id: deadline.id)
        row.title = obligation.name
        row.uiCategory = obligation.category.rawValue
        row.authority = obligation.authority
        row.detail = obligation.description
        row.frequency = obligation.frequency
        row.dateKey = deadline.dateKey
        row.overrideNote = deadline.overrideNote
        row.fromCompanyProfile = true
        return row
    }

    /// The web's merge (`events` in `ComplianceCalendar.jsx`): the company's generated deadlines,
    /// then the feed's — all of it with no company, or without the obligations the generator
    /// already produces once there is one. A repeated id keeps its first row.
    static func merge(generated: [StatutoryDeadline], feed: [StatutoryDeadline]) -> [StatutoryDeadline] {
        let pipeline = generated.isEmpty
            ? feed
            : feed.filter { !pipelineOverlaps.contains($0.complianceID ?? "") }
        var seen = Set<String>()
        return (generated + pipeline).filter { seen.insert($0.id).inserted }
    }
}

/// A calendar day as year, month and day, with the JavaScript `Date`'s rollover.
struct CivilDay: Comparable, Hashable, Sendable {
    /// Days since 1970-01-01.
    let ordinal: Int

    init(ordinal: Int) { self.ordinal = ordinal }

    /// Out-of-range months and days roll over, as `new Date(y, m - 1, d)` does.
    init(year: Int, month: Int, day: Int) {
        let m0 = month - 1
        let y = year + Int((Double(m0) / 12).rounded(.down))
        let m = ((m0 % 12) + 12) % 12 + 1
        ordinal = Self.daysFromCivil(y, m, 1) + day - 1
    }

    init?(key: String) {
        let parts = key.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, let y = Int(parts[0]), let m = Int(parts[1]),
              let d = Int(parts[2]), (1...12).contains(m), (1...31).contains(d)
        else { return nil }
        self.init(year: y, month: m, day: d)
        guard self.key == key else { return nil }
    }

    func adding(days: Int) -> CivilDay { CivilDay(ordinal: ordinal + days) }

    var components: (year: Int, month: Int, day: Int) { Self.civilFromDays(ordinal) }
    var year: Int { components.year }
    var month: Int { components.month }

    var key: String {
        let c = components
        return String(format: "%04d-%02d-%02d", c.year, c.month, c.day)
    }

    static func < (lhs: CivilDay, rhs: CivilDay) -> Bool { lhs.ordinal < rhs.ordinal }

    // Howard Hinnant's algorithms, proleptic Gregorian.
    static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func civilFromDays(_ days: Int) -> (year: Int, month: Int, day: Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }
}

/// The companies, kept on the device as the web keeps them in the browser.
///
/// Same keys as the web's `localStorage` (`emperor-compliance-companies`, a JSON array, and
/// `emperor-compliance-active`, the chosen id). Never sent to the server: the web does not send
/// them either, so there is nowhere on the platform for them to go.
struct CompanyProfileStore: Sendable {
    static let companiesKey = "emperor-compliance-companies"
    static let activeKey = "emperor-compliance-active"

    let store: any PreferenceStore

    func companies() -> [CompanyProfile] {
        guard let raw = store.string(for: Self.companiesKey), let data = raw.data(using: .utf8),
              let list = try? JSONDecoder().decode([Lenient].self, from: data)
        else { return [] }
        return list.compactMap(\.profile)
    }

    func setCompanies(_ companies: [CompanyProfile]) {
        if let data = try? JSONEncoder().encode(companies),
           let raw = String(data: data, encoding: .utf8) {
            store.setString(raw, for: Self.companiesKey)
        }
    }

    /// The chosen company's id, or nil. An empty string is the web's "none".
    func activeID() -> String? { store.string(for: Self.activeKey)?.nilIfEmpty }

    func setActiveID(_ id: String?) { store.setString(id ?? "", for: Self.activeKey) }

    /// One element that fails to decode costs only itself.
    private struct Lenient: Decodable {
        let profile: CompanyProfile?
        init(from decoder: any Decoder) throws { profile = try? CompanyProfile(from: decoder) }
    }
}
