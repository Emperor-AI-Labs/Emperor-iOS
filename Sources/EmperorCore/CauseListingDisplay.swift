import Foundation

/// What a cause-list row says about where and when a matter is heard.
///
/// A port of the extractors the web prints its cause list with — `extractCourtNo`,
/// `extractItemNo`, `extractCoram`, `extractTime` and `extractListingNote` in
/// `src/lib/causeList.js`, used by the Home card (`src/pages/home/TodayCauseList.jsx`) and Case
/// Management. Held to that file by `CauseListDisplayGolden`, generated from it under Node.
///
/// ## The rules that matter
///
/// - **A court-published row states its own room and item, or has none.** When the server
///   marks a listing `scraped`, its room and item come only from `courtNo` and `itemNo`.
///   Nothing is read out of its other text: Delhi's bench "Court 236" is a roster code, and
///   "TO BE LISTED IN COURT NO.270" a roster line, not where the matter is heard. A made-up
///   room sends a lawyer to the wrong door.
/// - **An item number belongs to one day's list.** The server never carries one from another
///   date (`sync-server.js`, `/cause-list`: "an item number belongs to ONE day's list"), and
///   this never invents one — no fallback to the row's position. A blank is a real answer;
///   a plausible "3" is read as where the matter is listed.
/// - **A coram is never a courtroom, nor the forum's own name** (consumer fora store the
///   commission as their "bench").
///
/// The web's Home card also falls back to reading a room out of the purpose text for every
/// row. That fallback is not carried over for court-published rows, because it is the one
/// place the web contradicts the rule above that its own server and `extractCourtNo` keep.
struct CauseListingDisplay: Equatable, Sendable {
    /// The item number in that day's list — "12", "3A", "12.1", "(A)".
    let item: String?
    /// The courtroom as a label — "Court 4", "Court II", "Registrar Court 1", or the list's own
    /// wording when it is not a numbered room.
    let room: String?
    /// The bench.
    let coram: String?
    /// The sitting time, where the list printed one.
    let time: String?
    /// What the listing is for — purpose and stage, minus placeholders.
    let note: String?
    /// The case number the web prints beside the title: "1234/2024", or the CNR or diary
    /// number when there is no case number.
    let reference: String?
    let advocates: String?

    init(_ listing: CauseListing) {
        let item = CauseListText.itemNumber(listing)
        self.item = item
        room = CauseListText.courtRoom(listing)
        coram = CauseListText.coram(listing)
        time = CauseListText.time(listing)
        let note = CauseListText.listingNote(listing)
        // The note is printed under the badge that already says "Item 12"; a stage reading
        // exactly that would say it twice.
        if let note, let item, note.lowercased() == "item \(item)".lowercased() {
            self.note = nil
        } else {
            self.note = note
        }
        reference = CauseListText.caseNumber(listing)
        advocates = listing.advocates.flatMap { CauseListText.trimmed($0) }
    }

    /// The number part of a numbered room — "4" for "Court 4", "II" for "Court II" — for the
    /// compact badge. `nil` for any other kind of room, which is then printed in full.
    var roomNumber: String? {
        guard let room, room.hasPrefix("Court ") else { return nil }
        let number = String(room.dropFirst("Court ".count))
        return number.isEmpty || number.contains(" ") ? nil : number
    }

    /// A room that does not fit the badge — "Registrar Court 1" — printed on the forum line.
    var roomInFull: String? { roomNumber == nil ? room : nil }

    /// Forum and bench, as the web's row prints them above the title — with a room that does
    /// not fit the badge ("Registrar Court 1") between them, so it is still said somewhere.
    func forum(courtName: String?) -> String? {
        let parts = [courtName.flatMap { CauseListText.trimmed($0) }, roomInFull, coram]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The whole row as one sentence for VoiceOver, location first — the order it is scanned
    /// in, and the badge's stacked numbers would otherwise be read with nothing to say which is
    /// the item and which the court.
    func spoken(_ listing: CauseListing) -> String {
        [
            spokenLocation, listing.displayTitle, forum(courtName: listing.courtName), detailLine,
            note, listing.remarks.flatMap { CauseListText.trimmed($0) },
        ]
        .compactMap { $0 }
        .joined(separator: ". ")
    }

    /// The small line under the title: number, time, counsel.
    var detailLine: String? {
        let parts = [reference, time, advocates].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// For VoiceOver, where the badge's two stacked numbers would otherwise be read as "12, 4"
    /// with nothing to say which is which.
    var spokenLocation: String? {
        let parts = [item.map { "Item \($0)" }, room].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// The ordering keys for a room: numbered rooms by number, then everything else by name.
    var roomSortKey: (Int, String) {
        guard let room else { return (Int.max, "") }
        guard let number = roomNumber else { return (Int.max - 1, room.lowercased()) }
        if let value = Int(number.prefix { $0.isASCII && $0.isNumber }) {
            return (value, room.lowercased())
        }
        return (CauseListText.romanValue(number) ?? Int.max - 2, room.lowercased())
    }
}

extension CauseListing {
    var display: CauseListingDisplay { CauseListingDisplay(self) }
}

/// The extractors themselves, kept apart from the struct so each can be tested against the
/// golden data on its own.
///
/// The patterns are the platform's, character for character, with two translations so they
/// mean in ICU what they mean in JavaScript: `\d` becomes `[0-9]` (ICU's `\d` also matches
/// Devanagari digits) and `\b` becomes an ASCII word boundary (ICU's counts Devanagari letters
/// as word characters, JavaScript's does not). Both scripts appear in Indian cause lists.
enum CauseListText {

    static func trimmed(_ value: String) -> String? {
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    /// `isPureCourtroom`: a courtroom label, or a comma-separated run of them ("Court 255,
    /// Court 259"), which is still rooms and never a coram.
    static func isPureCourtroom(_ value: String?) -> Bool {
        guard let value, !value.isEmpty else { return false }
        let parts = Patterns.shared.commaSplit.split(value)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return !parts.isEmpty && parts.allSatisfy {
            Patterns.shared.pureCourtroom.matches($0) || Patterns.shared.bareRoom.matches($0)
        }
    }

    /// `courtLabel`: a room as courts print it, shaped into "Court 4" / "Court II". A registrar
    /// court keeps its prefix — the Supreme Court's "Registrar Court 1" is not Court 1, the
    /// Chief Justice's court. Anything unrecognised comes back as written.
    static func courtLabel(_ value: String?) -> String? {
        guard let value else { return nil }
        let collapsed = Patterns.shared.whitespace.replaceAll(in: value, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.isEmpty || Patterns.shared.dashesOnly.matches(collapsed) { return nil }
        if let groups = Patterns.shared.registrarCourt.groups(in: collapsed) {
            return "\(groups[1] == nil ? "" : "Principal ")Registrar Court \(groups[2] ?? "")"
        }
        let number = Patterns.shared.courtNumber.groups(in: collapsed)?[1]
            ?? Patterns.shared.bareCourtNumber.groups(in: collapsed)?[1]
        if let number {
            let isRoman = Patterns.shared.roman.matches(number)
            return "Court \(isRoman ? number.uppercased() : number)"
        }
        return collapsed
    }

    /// `extractCourtNo`.
    static func courtRoom(_ listing: CauseListing) -> String? {
        if listing.scraped == true { return courtLabel(listing.courtNo) }
        if let label = courtLabel(listing.courtNo) { return label }
        if isPureCourtroom(listing.bench), let bench = listing.bench,
           let digits = Patterns.shared.firstRoomDigits.groups(in: bench)?[1] {
            return "Court \(digits)"
        }
        for field in [listing.purpose, listing.remarks, listing.bench] {
            guard let field, !field.isEmpty else { continue }
            if let number = Patterns.shared.courtInText.groups(in: field)?[1] {
                return "Court \(number)"
            }
        }
        return nil
    }

    /// `extractItemNo`. Never a position, never another day's number.
    static func itemNumber(_ listing: CauseListing) -> String? {
        if listing.scraped == true { return listing.itemNo.flatMap(trimmed) }
        if let direct = listing.itemNo.flatMap(trimmed) { return direct }
        let texts = [
            listing.stage, listing.purpose, listing.remarks, listing.bench, listing.title,
        ]
        for text in texts {
            guard let text, !text.isEmpty else { continue }
            for pattern in Patterns.shared.itemInText {
                if let raw = pattern.groups(in: text)?[1], let found = trimmed(raw) {
                    return found
                }
            }
        }
        return nil
    }

    /// `extractCoram`.
    static func coram(_ listing: CauseListing) -> String? {
        let forum = listing.courtName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        for candidate in [listing.coram, listing.judge, listing.bench] {
            guard let candidate, let value = trimmed(candidate) else { continue }
            if isPureCourtroom(value) || value == forum { continue }
            let cleaned = Patterns.shared.roomPrefix.replaceFirst(in: value, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty, !isPureCourtroom(cleaned) { return cleaned }
        }
        for text in [listing.purpose, listing.remarks, listing.stage] {
            guard let text, !text.isEmpty else { continue }
            for pattern in Patterns.shared.judgeInText {
                if let raw = pattern.groups(in: text)?[1], let found = trimmed(raw),
                   !isPureCourtroom(found) {
                    return found
                }
            }
        }
        return nil
    }

    /// `extractTime`.
    static func time(_ listing: CauseListing) -> String? {
        listing.time.flatMap(trimmed)
    }

    /// `extractListingNote`: purpose and stage, e.g. "Fixed Date by Court · Part heard
    /// matters", leaving out placeholders ("Next hearing", "Hearing - 2"), Delhi's roster line,
    /// bare numbers and a stage that repeats the purpose. Clipped at 140 UTF-16 units, as the
    /// web measures it, so a long Hindi purpose is cut where the web cuts it.
    static func listingNote(_ listing: CauseListing) -> String? {
        var parts: [String] = []
        for value in [listing.purpose, listing.stage] {
            let unbracketed = Patterns.shared.outerBrackets.replaceAll(in: value ?? "", with: "")
            let tidy = Patterns.shared.whitespace.replaceAll(in: unbracketed, with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if tidy.isEmpty || Patterns.shared.notAPurpose.matches(tidy)
                || Patterns.shared.bareRoom.matches(tidy) {
                continue
            }
            if parts.contains(where: { $0.lowercased() == tidy.lowercased() }) { continue }
            parts.append(tidy)
        }
        let note = parts.joined(separator: " · ")
        guard !note.isEmpty else { return nil }
        let units = Array(note.utf16)
        guard units.count > 140 else { return note }
        return String(decoding: units.prefix(139), as: UTF16.self) + "…"
    }

    /// `caseNoOf`: "1234/2024", "1234", or the CNR / diary number the server folds into `cnr`.
    static func caseNumber(_ listing: CauseListing) -> String? {
        if let number = listing.caseNumber.flatMap(trimmed) {
            if let year = listing.caseYear.flatMap(trimmed) { return "\(number)/\(year)" }
            return number
        }
        return listing.cnr.flatMap(trimmed)
    }

    /// A small Roman numeral — courtrooms run to a few dozen at most.
    static func romanValue(_ value: String) -> Int? {
        let digits: [Character: Int] = ["I": 1, "V": 5, "X": 10, "L": 50]
        let values = value.uppercased().compactMap { digits[$0] }
        guard !values.isEmpty, values.count == value.count else { return nil }
        var total = 0
        for (index, current) in values.enumerated() {
            if index + 1 < values.count, current < values[index + 1] {
                total -= current
            } else {
                total += current
            }
        }
        return total > 0 ? total : nil
    }

    // MARK: - Patterns

    /// One compiled `NSRegularExpression` and the three ways the port uses it.
    struct Pattern: @unchecked Sendable {
        // `@unchecked` because `NSRegularExpression` is not annotated `Sendable` on every
        // platform this builds for. It is immutable once compiled and documented as safe to
        // use from any thread, and nothing here mutates it.
        let regex: NSRegularExpression

        /// - Parameter javaScript: the pattern as the platform writes it.
        init(_ javaScript: String, caseInsensitive: Bool = true) {
            let asciiBoundary =
                "(?:(?<=[A-Za-z0-9_])(?![A-Za-z0-9_])|(?<![A-Za-z0-9_])(?=[A-Za-z0-9_]))"
            let translated = javaScript
                .replacingOccurrences(of: #"\b"#, with: asciiBoundary)
                .replacingOccurrences(of: #"\d"#, with: "[0-9]")
            // The patterns are constants in this file; one that fails to compile is a
            // programming error that every golden test would catch before it shipped.
            regex = try! NSRegularExpression(
                pattern: translated, options: caseInsensitive ? [.caseInsensitive] : [])
        }

        private func range(_ text: String) -> NSRange { NSRange(text.startIndex..., in: text) }

        func matches(_ text: String) -> Bool {
            regex.firstMatch(in: text, range: range(text)) != nil
        }

        /// Every capture group of the first match, `[0]` being the whole match; `nil` when
        /// there is no match. A group that did not take part is `nil`, as in JavaScript.
        func groups(in text: String) -> [String?]? {
            guard let match = regex.firstMatch(in: text, range: range(text)) else { return nil }
            return (0..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) }
            }
        }

        func replaceAll(in text: String, with template: String) -> String {
            regex.stringByReplacingMatches(
                in: text, range: range(text), withTemplate: template)
        }

        func replaceFirst(in text: String, with replacement: String) -> String {
            guard let match = regex.firstMatch(in: text, range: range(text)),
                  let found = Range(match.range, in: text)
            else { return text }
            return text.replacingCharacters(in: found, with: replacement)
        }

        /// `String.split(regex)`, for the one place the platform splits on a pattern.
        func split(_ text: String) -> [String] {
            var pieces: [String] = []
            var start = text.startIndex
            for match in regex.matches(in: text, range: range(text)) {
                guard let found = Range(match.range, in: text) else { continue }
                pieces.append(String(text[start..<found.lowerBound]))
                start = found.upperBound
            }
            pieces.append(String(text[start...]))
            return pieces
        }
    }

    /// Compiled once. Each is quoted from `src/lib/causeList.js` beside the function that
    /// uses it there.
    struct Patterns: Sendable {
        static let shared = Patterns()

        // isPureCourtroom
        let commaSplit = Pattern(#"\s*,\s*"#)
        let pureCourtroom = Pattern(#"^court\s*(?:no\.?|room)?\s*[0-9]+[a-z]?$"#)
        let bareRoom = Pattern(#"^\d+[a-z]?$"#)

        // courtLabel
        let whitespace = Pattern(#"\s+"#)
        let dashesOnly = Pattern(#"^[-—–]+$"#, caseInsensitive: false)
        let registrarCourt = Pattern(
            #"(principal\s+)?registrar\s*court\s*(?:no\.?)?\s*[:#.-]?\s*([0-9]+[a-z]?)"#)
        let courtNumber = Pattern(
            #"court\s*(?:no\.?|room|hall)?\s*[:#.-]?\s*([0-9]+[a-z]?|[ivxl]+)\b"#)
        let bareCourtNumber = Pattern(#"^([0-9]+[a-z]?|[ivxl]+)$"#)
        let roman = Pattern(#"^[ivxl]+$"#)

        // extractCourtNo — note the platform's digit pattern here has no `i` flag.
        let firstRoomDigits = Pattern(#"([0-9]+[a-z]?)"#, caseInsensitive: false)
        let courtInText = Pattern(#"court\s*(?:no\.?|room)?\s*[:#-]?\s*([0-9]+[a-z]?)"#)

        // extractItemNo, in the platform's order: the first that matches wins.
        let itemInText: [Pattern] = [
            Pattern(#"(?:item|item\s*no\.?|item\s*number|item\s*#|sl\.?\s*no\.?|sr\.?\s*no\.?|serial\s*no\.?|s\.?\s*no\.?)\s*[:#-]?\s*([0-9]+[a-z]?(?:\.[0-9]+)?)"#),
            Pattern(#"(?:at\s+item\s*(?:no\.?)?\s*)([0-9]+[a-z]?)"#),
            Pattern(#"\bitem\s*[:#-]?\s*([0-9]+[a-z]?)\b"#),
            Pattern(#"\b(?:sr|sl)\.?\s*[:#-]?\s*([0-9]+[a-z]?)\b"#),
            Pattern(#"\(item\s*([0-9]+[a-z]?)\)"#),
            Pattern(#"\bitem\s*([0-9]+[a-z]?)\s+of\b"#),
            Pattern(#"\bno\.\s*([0-9]+)\s+in\s+court\b"#),
            Pattern(#"\bitem\s*([0-9]+)\b"#),
        ]

        // extractCoram
        let roomPrefix = Pattern(#"^court\s*(?:no\.?|room)?\s*[0-9]+[a-z]?\s*[-–—:]\s*"#)
        let judgeInText: [Pattern] = [
            Pattern(#"(?:before\s+)?(hon['’]ble(?:\s+the)?\s+(?:chief\s+justice|justice|mr\.\s+justice|ms\.\s+justice|mrs\.\s+justice|dr\.\s+justice)[^,\n;]+)"#),
            Pattern(#"(?:before\s+)?((?:chief\s+justice|mr\.\s+justice|ms\.\s+justice|mrs\.\s+justice|dr\.\s+justice)[^,\n;]+)"#),
            Pattern(#"(?:coram\s*[:-]\s*)([^,\n;]+)"#),
            Pattern(#"(?:judge\s*[:-]\s*)([^,\n;]+)"#),
            Pattern(#"(?:bench\s*[:-]\s*)([^,\n;]+)"#),
        ]

        // extractListingNote
        let outerBrackets = Pattern(#"^\[|\]$"#, caseInsensitive: false)
        let notAPurpose = Pattern(
            #"^(?:listing|listed|hearing|next (?:listing|hearing)|first listing|hearing\s*-\s*\d+|pending|upcoming|submitted)$|listed in court"#)
    }
}
