import Foundation
#if canImport(Darwin)
import Observation
#endif

// "Build from documents" (docs/projects.md, the AI section): Emperor reads the matter's documents
// and proposes the dated events in them, each with the page it was read from. Nothing is written
// until the user ticks a proposal — a date the model misread must never land unseen in a list
// that ends up in a court filing. Proposals that look like an entry already on the record start
// unticked, so building twice does not double up.

// MARK: - The wire

/// One event `POST /project-chronology-extract` proposes.
///
/// `date` is asked for as `YYYY-MM-DD` but may come back in the record's own form, or as a month
/// or a year alone — so it is kept as text and read by `ChronologyProposal.parseDocDate`.
struct ExtractedEvent: Decodable, Equatable, Sendable {
    var date: String?
    var title: String?
    var details: String?
    /// `event`, `filing`, `hearing`, `order`, `notice` or `agreement`.
    var kind: String?
    var sourceRef: String?

    init(date: String? = nil, title: String? = nil, details: String? = nil, kind: String? = nil, sourceRef: String? = nil) {
        self.date = date
        self.title = title
        self.details = details
        self.kind = kind
        self.sourceRef = sourceRef
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decodeFlexibleString(forKey: .date)
        title = try c.decodeFlexibleString(forKey: .title)
        details = try c.decodeFlexibleString(forKey: .details)
        kind = try c.decodeFlexibleString(forKey: .kind)
        sourceRef = try c.decodeFlexibleString(forKey: .sourceRef)
    }

    enum CodingKeys: String, CodingKey { case date, title, details, kind, sourceRef }
}

/// What the extract route answers: the proposals, how many documents were read, the names of
/// those with no readable text yet, and whether the list may be incomplete.
struct ChronologyExtraction: Decodable, Equatable, Sendable {
    var events: [ExtractedEvent]
    /// How many documents were read.
    var files: Int?
    var skipped: [String]
    /// Some text was left out or some part could not be read: the list may be incomplete.
    var partial: Bool
    /// The server's sentence when there was nothing to read.
    var message: String?

    init(events: [ExtractedEvent] = [], files: Int? = nil, skipped: [String] = [], partial: Bool = false, message: String? = nil) {
        self.events = events
        self.files = files
        self.skipped = skipped
        self.partial = partial
        self.message = message
    }
}

struct ChronologyExtractResponse: Decodable, Sendable {
    var success: Bool?
    var error: String?
    var events: [ExtractedEvent]?
    var files: Int?
    var skipped: [String]?
    var partial: Bool?
    var message: String?

    enum CodingKeys: String, CodingKey { case success, error, events, files, skipped, partial, message }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        success = try? c.decodeIfPresent(Bool.self, forKey: .success)
        error = try? c.decodeIfPresent(String.self, forKey: .error)
        // One malformed event costs that event, not the list.
        events = (try? c.decodeIfPresent([Lenient<ExtractedEvent>].self, forKey: .events))?.compactMap(\.value)
        files = try? c.decodeIfPresent(Int.self, forKey: .files)
        skipped = (try? c.decodeIfPresent([String].self, forKey: .skipped)) ?? nil
        partial = try? c.decodeIfPresent(Bool.self, forKey: .partial)
        message = try? c.decodeIfPresent(String.self, forKey: .message)
    }

    private struct Lenient<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }
}

// MARK: - Proposals

/// One proposed event on the review list, with the web's `toProposals` rules.
struct ChronologyProposal: Equatable, Identifiable, Sendable {
    /// Its place in the answer.
    let index: Int
    /// `YYYY-MM-DD`, or `nil` when the date could not be pinned to a whole day.
    let day: String?
    /// The date as the model wrote it, shown on an undated proposal.
    let rawDate: String
    let title: String
    let details: String
    /// A chronology kind this client and the server both know; `event` otherwise.
    let kind: String
    let sourceRef: String
    /// Looks like an entry already on the record (same day, similar title).
    let isDuplicate: Bool
    /// Ticked to be added.
    var isOn: Bool

    var id: Int { index }
    var isUndated: Bool { day == nil }
    /// Has what a chronology entry needs: a whole day and a title.
    var isUsable: Bool { day != nil && !title.isEmpty }

    var kindLabel: String { MatterVocabulary.label(for: kind, in: MatterVocabulary.updateKinds) ?? "Event" }

    /// "Read as “March 2019”", or "No date given".
    var undatedLine: String { rawDate.isEmpty ? "No date given" : "Read as “\(rawDate)”" }

    /// The proposals for an answer, checked against what the matter already records.
    ///
    /// - Parameter known: the day and title of every entry already on the record.
    static func proposals(from events: [ExtractedEvent], known: [(day: String?, title: String?)]) -> [ChronologyProposal] {
        let existing = known.map { (day: $0.day, title: norm($0.title)) }
        let kinds = Set(MatterVocabulary.updateKinds.map(\.key))
        return events.enumerated().map { index, event in
            let day = parseDocDate(event.date)
            let title = (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let normalised = norm(title)
            let dup = day != nil && existing.contains { $0.day == day && sameEvent($0.title, normalised) }
            let kind = event.kind.flatMap { kinds.contains($0) ? $0 : nil } ?? "event"
            return ChronologyProposal(
                index: index, day: day,
                rawDate: (event.date ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                title: title,
                details: (event.details ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                kind: kind,
                sourceRef: (event.sourceRef ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                isDuplicate: dup,
                isOn: day != nil && !title.isEmpty && !dup)
        }
    }

    /// Lower case, every run of anything but `a-z0-9` one space, trimmed.
    static func norm(_ text: String?) -> String {
        var out = ""
        var pendingSpace = false
        for scalar in (text ?? "").lowercased().unicodeScalars {
            let isWordy = ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
            if isWordy {
                if pendingSpace && !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingSpace = true
            }
        }
        return out
    }

    /// Equal, or — when both are at least 12 characters — one contains the other.
    static func sameEvent(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        return min(a.count, b.count) >= 12 && (a.contains(b) || b.contains(a))
    }

    /// The web's `parseDocDate`: `YYYY-MM-DD…` (a time after it is ignored) or
    /// `DD.MM.YYYY` / `DD/MM/YYYY` / `DD-MM-YYYY`, and only a day that exists. Anything else —
    /// a month, a year, prose — is no day.
    static func parseDocDate(_ raw: String?) -> String? {
        let text = Array((raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars)
        // A run of ASCII digits starting at `at`: its value and where it ends.
        func digits(_ at: Int, max: Int = .max) -> (value: Int, end: Int, count: Int) {
            var end = at
            var value = 0
            while end < text.count, end - at < max, let digit = Self.asciiDigit(text[end]) {
                value = value * 10 + digit
                end += 1
            }
            return (value, end, end - at)
        }
        let y: Int, m: Int, d: Int
        let first = digits(0)
        if first.count == 4, first.end < text.count, text[first.end] == "-" {
            // YYYY-M(M)-D(D), anything after it ignored.
            let month = digits(first.end + 1)
            guard (1...2).contains(month.count), month.end < text.count, text[month.end] == "-" else { return nil }
            let day = digits(month.end + 1, max: 2)
            guard day.count >= 1 else { return nil }
            (y, m, d) = (first.value, month.value, day.value)
        } else if (1...2).contains(first.count), first.end < text.count, Self.isDateSeparator(text[first.end]) {
            // D(D).M(M).YYYY and nothing after it.
            let month = digits(first.end + 1)
            guard (1...2).contains(month.count), month.end < text.count, Self.isDateSeparator(text[month.end]) else { return nil }
            let year = digits(month.end + 1)
            guard year.count == 4, year.end == text.count else { return nil }
            (d, m, y) = (first.value, month.value, year.value)
        } else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard (1...12).contains(m), (1...31).contains(d),
              let date = calendar.date(from: DateComponents(year: y, month: m, day: d)) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == y, back.month == m, back.day == d else { return nil }
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    private static func asciiDigit(_ scalar: Unicode.Scalar) -> Int? {
        ("0"..."9").contains(scalar) ? Int(scalar.value) - 48 : nil
    }

    private static func isDateSeparator(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "." || scalar == "/" || scalar == "-"
    }
}

// MARK: - The flow

/// The "Build from documents" sheet: pick → reading → review → saving → done, or failed.
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class ChronologyBuildViewModel {

    enum Phase: Equatable, Sendable {
        case pick, reading, review, saving, done, failed
    }

    enum Scope: Equatable, Sendable { case all, some }

    let projectID: String
    private(set) var phase: Phase = .pick
    var scope: Scope = .all

    /// The matter's files, once "Choose documents" has listed them.
    private(set) var files: [MatterFile]?
    private(set) var filesError: String?
    private(set) var chosen: Set<String> = []

    private(set) var proposals: [ChronologyProposal] = []
    private(set) var extraction: ChronologyExtraction?
    /// Why the read failed, shown on the failed phase.
    private(set) var failure: String?
    /// How far the accept loop has got.
    private(set) var progress: (done: Int, total: Int) = (0, 0)
    /// The line said when the saving finishes — the web's toast wording.
    private(set) var summary: String?
    /// Whether every ticked event was saved.
    private(set) var summaryIsError = false

    private let service: any ProjectProviding
    private let known: [(day: String?, title: String?)]
    private let reload: @MainActor () async -> Void
    /// Bumped on every start and on `abandon()`; an answer for an older run is dropped.
    private var run = 0

    /// - Parameters:
    ///   - updates: the matter's chronology, for the "already on the record" check.
    ///   - courtHistory: the linked case's rows, for the same check.
    ///   - reload: re-reads the matter once something was saved.
    init(
        projectID: String,
        service: any ProjectProviding,
        updates: [ProjectUpdate] = [],
        courtHistory: [CaseItem] = [],
        reload: @escaping @MainActor () async -> Void = {}
    ) {
        self.projectID = projectID
        self.service = service
        self.reload = reload
        let own = updates.map { (day: $0.day.map(WireDate.dayKey), title: $0.title) }
        let court = courtHistory.map { (day: $0.itemDate.map(WireDate.dayKey), title: $0.title) }
        self.known = own + court
    }

    // MARK: Pick

    /// Read only the files the user picks. Lists the matter's files the first time.
    func chooseSome() async {
        scope = .some
        guard files == nil else { return }
        do {
            files = MatterFile.flatten(try await service.projectFiles(projectID: projectID), projectID: projectID)
        } catch {
            files = []
            filesError = DisplayText.message(for: error)
        }
    }

    func toggle(_ file: MatterFile) {
        guard file.isReady else { return }
        if chosen.contains(file.key) { chosen.remove(file.key) } else { chosen.insert(file.key) }
    }

    func isChosen(_ file: MatterFile) -> Bool { chosen.contains(file.key) }

    var canStart: Bool { phase == .pick && (scope == .all || !chosen.isEmpty) }

    /// "all files", "1 file", "3 files" — what is being read.
    var readingCount: String {
        guard scope == .some else { return "all files" }
        return chosen.count == 1 ? "1 file" : "\(chosen.count) files"
    }

    static let readingTitle = "Reading the documents"
    static let readingLine = "Finding dated events and where each one is written…"
    static let readingNote = "Long files can take a minute or two. Nothing is saved until you have reviewed the list; closing this window stops the review."
    static let pickIntro = "Emperor reads this matter’s documents and proposes the dated events in them — agreements, notices, payments, filings, orders — each with the page it was found on. Nothing is added until you tick it."

    // MARK: Reading

    /// Asks the server to read the documents. Proposals arrive on `review`; a refusal on `failed`.
    func start() async {
        guard canStart else { return }
        run += 1
        let mine = run
        phase = .reading
        failure = nil
        let selection: [ChatAttachment]? = scope == .some
            ? (files ?? []).filter { chosen.contains($0.key) }.map(\.attachment)
            : nil
        do {
            let answer = try await service.extractChronology(projectID: projectID, files: selection)
            guard mine == run else { return }
            extraction = answer
            proposals = ChronologyProposal.proposals(from: answer.events, known: known)
            phase = .review
        } catch {
            guard mine == run else { return }
            failure = DisplayText.message(for: error)
            phase = .failed
        }
    }

    /// The sheet was closed: an answer still on its way must not open a review nobody sees.
    func abandon() {
        run += 1
        if phase == .reading { phase = .pick }
    }

    /// Back to the choice of documents, after a failure.
    func backToPick() {
        guard phase == .failed else { return }
        phase = .pick
        failure = nil
    }

    // MARK: Review

    var picked: [ChronologyProposal] { proposals.filter { $0.isOn && $0.isUsable } }

    /// "No dated events were found in …", for an answer with none.
    var nothingFoundLine: String {
        let whereRead = scope == .some ? "those documents" : "this matter’s documents"
        return "No dated events were found in \(whereRead). Scanned files that are still being read appear once processing finishes."
    }

    /// Said above the list when the server could not read everything.
    var partialLine: String? {
        guard extraction?.partial == true else { return nil }
        return "Some of the text could not be read, so this list may be incomplete."
    }

    /// "12 found · 9 ticked".
    var countLine: String { "\(proposals.count) found · \(picked.count) ticked" }

    /// "Add 9 events", "Add 1 event".
    var acceptTitle: String { picked.count == 1 ? "Add 1 event" : "Add \(picked.count) events" }

    func setOn(_ proposal: ChronologyProposal, _ on: Bool) {
        guard phase == .review, proposal.isUsable,
              let at = proposals.firstIndex(where: { $0.index == proposal.index }) else { return }
        proposals[at].isOn = on
    }

    func tickAll() {
        guard phase == .review else { return }
        for i in proposals.indices { proposals[i].isOn = proposals[i].isUsable }
    }

    func untickAll() {
        guard phase == .review else { return }
        for i in proposals.indices { proposals[i].isOn = false }
    }

    // MARK: Saving

    /// Saves the ticked events one at a time, each as an `ai` entry naming the page it came from.
    ///
    /// One at a time on purpose: a failure part-way leaves a clear count of what did land, rather
    /// than an unknown subset of a parallel burst. A failed save does not stop the rest.
    func acceptProposals() async {
        let chosen = picked
        guard phase == .review, !chosen.isEmpty else { return }
        phase = .saving
        progress = (0, chosen.count)
        var ok = 0
        var failed = 0
        var lastError = ""
        for proposal in chosen {
            let draft = UpdateDraft(
                kind: proposal.kind, title: proposal.title,
                body: proposal.details.isEmpty ? nil : proposal.details,
                eventDate: proposal.day, source: "ai",
                sourceRef: proposal.sourceRef.isEmpty ? nil : proposal.sourceRef)
            do {
                _ = try await service.saveUpdate(projectID: projectID, id: nil, draft: draft)
                ok += 1
            } catch {
                failed += 1
                lastError = DisplayText.message(for: error)
            }
            progress = (ok + failed, chosen.count)
        }
        await reload()
        if failed > 0 {
            summary = "\(ok) added; \(failed) could not be saved\(lastError.isEmpty ? "" : " — \(lastError)")."
            summaryIsError = true
        } else {
            summary = "\(ok) \(ok == 1 ? "event" : "events") added to the chronology"
            summaryIsError = false
        }
        phase = .done
    }

    /// "Adding 3 of 9…".
    var progressLine: String { "Adding \(progress.done) of \(progress.total)…" }
}
