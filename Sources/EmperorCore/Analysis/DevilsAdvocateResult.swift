import Foundation

/// Devil's Advocate: where the case is weak, what the other side will ask, and what to do.
///
/// Shape: `repairDevilsAdvocate` in the platform's `lib/analysis/schemas.js`. It always sends
/// every section (lists possibly empty except the weak spots and the one-minute summary), ranks
/// the weak spots most serious first and numbers them `1…n`, and points questions, document gaps
/// and authorities at a spot by that number. Every count, band and bar here is derived, as the
/// web's page derives them.
struct DevilsAdvocateResult: Decodable, Equatable, Sendable {

    enum Severity: String, Decodable, Sendable, CaseIterable {
        case serious, moderate, minor

        var label: String {
            switch self {
            case .serious: return "Serious"
            case .moderate: return "Moderate"
            case .minor: return "Minor"
            }
        }

        var hint: String {
            switch self {
            case .serious: return "Could lose or stall the case"
            case .moderate: return "Could cost money or credibility"
            case .minor: return "Easy to fix, awkward if ignored"
            }
        }

        /// What a spot of this severity weighs in the category bars.
        var weight: Int {
            switch self {
            case .serious: return 3
            case .moderate: return 2
            case .minor: return 1
            }
        }
    }

    enum Category: String, Decodable, Sendable, CaseIterable {
        case limitation, jurisdiction, pleadings, evidence, contract, relief, procedure

        var label: String {
            switch self {
            case .limitation: return "Limitation"
            case .jurisdiction: return "Jurisdiction"
            case .pleadings: return "Pleadings"
            case .evidence: return "Evidence"
            case .contract: return "Contract terms"
            case .relief: return "Relief and quantum"
            case .procedure: return "Procedure"
            }
        }
    }

    enum Readiness: String, Decodable, Sendable, CaseIterable {
        case ready, work, gap

        var label: String {
            switch self {
            case .ready: return "Ready"
            case .work: return "Needs work"
            case .gap: return "Gap"
            }
        }
    }

    struct WeakSpot: Decodable, Equatable, Sendable, Identifiable {
        var id: Int
        var severity: Severity
        var category: Category
        /// 1…5: how likely the other side raises it.
        var likelihood: Int
        /// 1…5: how badly it hurts if they do.
        var impact: Int
        var title: String
        var why: String
        /// Cites into the papers — "Plaint para 11".
        var `where`: [String]
        /// What the other side will say.
        var say: String
        var fix: String
    }

    struct Question: Decodable, Equatable, Sendable {
        var q: String
        var why: String
        var answer: String
        var readiness: Readiness
        /// The weak spot it belongs to.
        var spot: Int?
    }

    struct DocGap: Decodable, Equatable, Sendable {
        var doc: String
        var who: String
        var how: String
        var when: String
        /// The weak spot it closes.
        var spot: Int?
    }

    struct Authority: Decodable, Equatable, Sendable {
        var name: String
        var court: String
        var year: String
        var holds: String
        var distinguish: String
        /// Not found in the user's own papers — decided by the server, not the model.
        var verify: Bool
        var pinCite: String?
        /// The weak spot it hurts.
        var against: Int?

        /// "Supreme Court, 2019 · para 52".
        var whereLine: String {
            let court = [self.court, year].filter { !$0.isEmpty }.joined(separator: ", ")
            return [court, pinCite ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    struct ChecklistItem: Decodable, Equatable, Sendable, Identifiable {
        var id: String
        var text: String
        var done: Bool
    }

    struct Matter: Decodable, Equatable, Sendable {
        var title: String
        var forum: String
        var number: String
        var client: String
    }

    var matter: Matter
    /// 0…100.
    var exposureScore: Int
    /// Two to four short paragraphs.
    var oneMinute: [String]
    var weakSpots: [WeakSpot]
    var questions: [Question]
    var docGaps: [DocGap]
    var authorities: [Authority]
    var checklist: [ChecklistItem]

    init(
        matter: Matter = Matter(title: "", forum: "", number: "", client: ""),
        exposureScore: Int, oneMinute: [String], weakSpots: [WeakSpot],
        questions: [Question] = [], docGaps: [DocGap] = [], authorities: [Authority] = [],
        checklist: [ChecklistItem] = []
    ) {
        self.matter = matter
        self.exposureScore = exposureScore
        self.oneMinute = oneMinute
        self.weakSpots = weakSpots
        self.questions = questions
        self.docGaps = docGaps
        self.authorities = authorities
        self.checklist = checklist
    }

    enum CodingKeys: String, CodingKey {
        case matter, exposureScore, oneMinute, weakSpots, questions, docGaps, authorities, checklist
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        matter = try c.decode(Matter.self, forKey: .matter)
        exposureScore = try c.decode(Int.self, forKey: .exposureScore)
        oneMinute = try c.decode([String].self, forKey: .oneMinute)
        weakSpots = try c.decode([WeakSpot].self, forKey: .weakSpots)
        questions = try c.decode([Question].self, forKey: .questions)
        docGaps = try c.decode([DocGap].self, forKey: .docGaps)
        authorities = try c.decode([Authority].self, forKey: .authorities)
        checklist = try c.decode([ChecklistItem].self, forKey: .checklist)
        guard !weakSpots.isEmpty, !oneMinute.isEmpty, (0...100).contains(exposureScore) else {
            throw DecodingError.dataCorruptedError(
                forKey: .weakSpots, in: c,
                debugDescription: "A report needs weak spots, a summary and a score from 0 to 100.")
        }
    }

    // MARK: - Derived

    enum Band: String, Sendable {
        case low = "Low", moderate = "Moderate", high = "High"
    }

    /// The web's `exposureBand`: under 34 is low, under 67 moderate, the rest high.
    var band: Band {
        exposureScore < 34 ? .low : exposureScore < 67 ? .moderate : .high
    }

    func count(_ severity: Severity) -> Int {
        weakSpots.filter { $0.severity == severity }.count
    }

    /// "2 serious, 3 moderate, 1 minor".
    var severityLine: String {
        "\(count(.serious)) serious, \(count(.moderate)) moderate, \(count(.minor)) minor"
    }

    struct CategoryRow: Equatable, Sendable, Identifiable {
        var category: Category
        var serious: Int
        var moderate: Int
        var minor: Int
        var count: Int { serious + moderate + minor }
        var weight: Int { serious * 3 + moderate * 2 + minor }
        var id: String { category.rawValue }
    }

    /// The categories that hold a spot, heaviest first — the web's `categoryRows`.
    var categoryRows: [CategoryRow] {
        let rows = Category.allCases.map { category -> CategoryRow in
            let mine = weakSpots.filter { $0.category == category }
            return CategoryRow(
                category: category,
                serious: mine.filter { $0.severity == .serious }.count,
                moderate: mine.filter { $0.severity == .moderate }.count,
                minor: mine.filter { $0.severity == .minor }.count)
        }
        // A stable sort: equal weights keep the categories' own order, as the web's does.
        return rows.filter { $0.count > 0 }
            .enumerated()
            .sorted { $0.element.weight != $1.element.weight ? $0.element.weight > $1.element.weight : $0.offset < $1.offset }
            .map(\.element)
    }

    func count(_ readiness: Readiness) -> Int {
        questions.filter { $0.readiness == readiness }.count
    }

    func questions(_ readiness: Readiness?) -> [Question] {
        guard let readiness else { return questions }
        return questions.filter { $0.readiness == readiness }
    }

    func spot(_ id: Int?) -> WeakSpot? {
        guard let id else { return nil }
        return weakSpots.first { $0.id == id }
    }

    /// The matter's meta lines, each only when present.
    var matterFacts: [(label: String, value: String)] {
        [("Forum", matter.forum), ("Matter", matter.number), ("Prepared for", matter.client)]
            .filter { !$0.1.isEmpty }
            .map { (label: $0.0, value: $0.1) }
    }

    // MARK: - Text

    var plainText: String {
        var lines = ["DEVIL'S ADVOCATE REPORT"]
        lines.append(matter.title.isEmpty ? "Your matter" : matter.title)
        for fact in matterFacts { lines.append("\(fact.label): \(fact.value)") }
        lines.append("Overall exposure: \(band.rawValue) (\(exposureScore) of 100) — \(severityLine)")
        lines.append("")
        lines.append("A first draft to check, not advice. Written by an AI from your documents; check every point against them before you rely on it.")

        lines.append("")
        lines.append("IN ONE MINUTE")
        for (index, paragraph) in oneMinute.enumerated() { lines.append("\(index + 1). \(paragraph)") }

        lines.append("")
        lines.append("YOUR WEAK SPOTS, RANKED")
        for spot in weakSpots {
            lines.append("")
            lines.append("#\(spot.id) [\(spot.severity.label) · \(spot.category.label)] \(spot.title)")
            lines.append("Why it hurts: \(spot.why)")
            if !spot.where.isEmpty { lines.append("Where in your papers: \(spot.where.joined(separator: "; "))") }
            if !spot.say.isEmpty { lines.append("What they will say: “\(spot.say)”") }
            lines.append("How to close the gap: \(spot.fix)")
        }

        if !questions.isEmpty {
            lines.append("")
            lines.append("QUESTIONS YOU SHOULD EXPECT")
            for q in questions {
                lines.append("")
                lines.append("“\(q.q)” [\(q.readiness.label)]")
                if !q.why.isEmpty { lines.append("Why they ask: \(q.why)") }
                if !q.answer.isEmpty { lines.append("Your best answer: \(q.answer)\(q.spot.map { " (weak spot #\($0))" } ?? "")") }
            }
        }

        if !docGaps.isEmpty {
            lines.append("")
            lines.append("PAPERS YOU ARE MISSING")
            for gap in docGaps {
                var bits = [gap.doc]
                if !gap.who.isEmpty { bits.append("who has it: \(gap.who)") }
                if !gap.how.isEmpty { bits.append("how to get it: \(gap.how)") }
                if !gap.when.isEmpty { bits.append("by when: \(gap.when)") }
                if let spot = gap.spot { bits.append("closes #\(spot)") }
                lines.append("- " + bits.joined(separator: " — "))
            }
        }

        if !authorities.isEmpty {
            lines.append("")
            lines.append("AUTHORITIES THAT CUT AGAINST YOU")
            for a in authorities {
                lines.append("")
                lines.append("See e.g. \(a.name)\(a.whereLine.isEmpty ? "" : " (\(a.whereLine))")\(a.verify ? " [Verify before citing: not found in your papers]" : "")")
                if !a.holds.isEmpty { lines.append("What it generally holds: \(a.holds)") }
                if !a.distinguish.isEmpty { lines.append("How to distinguish it: \(a.distinguish)") }
                if let against = a.against { lines.append("Hurts: weak spot #\(against)") }
            }
        }

        if !checklist.isEmpty {
            lines.append("")
            lines.append("YOUR PREPARATION CHECKLIST")
            for item in checklist { lines.append("[\(item.done ? "x" : " ")] \(item.text)") }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
