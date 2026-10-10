import Foundation

/// The words at the head of the Ask tab: the date, the greeting, and the suggestions for the
/// reader's role.
///
/// The greeting follows the **device's** clock, unlike a court date: "Good evening" is about the
/// person holding the phone, wherever they are. The suggestions only ever *fill* the composer —
/// nothing is sent until the reader sends it.
enum AskHome {

    /// "Good morning" before noon, "Good afternoon" before five, "Good evening" after.
    static func greeting(hour: Int) -> String {
        switch hour {
        case ..<12: return "Good morning"
        case ..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }

    /// The greeting line: "Good evening, Aarti." — or the greeting alone with no name to use.
    static func greetingLine(hour: Int, name: String?) -> String {
        let greeting = greeting(hour: hour)
        guard let first = firstName(name) else { return "\(greeting)." }
        return "\(greeting), \(first)."
    }

    /// The first word of a name that is a name — not an email address, not "Adv." or "Dr.".
    static func firstName(_ name: String?) -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
              !name.contains("@")
        else { return nil }
        let honorifics: Set<String> = ["adv", "adv.", "advocate", "dr", "dr.", "mr", "mr.", "ms", "ms.", "mrs", "mrs.", "shri", "smt", "smt."]
        let words = name.split(separator: " ").map(String.init)
        return words.first { !honorifics.contains($0.lowercased()) }
    }

    /// The date above the greeting: "Saturday, 10 October", on the device's calendar.
    static func dateLine(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, d MMMM"
        f.timeZone = timeZone
        f.locale = Locale(identifier: "en_IN")
        return f.string(from: date)
    }

    // MARK: - Suggestions

    /// A starting point for a question.
    struct Suggestion: Equatable, Sendable, Identifiable {
        let title: String
        /// An SF Symbol.
        let systemImage: String
        /// What goes into the composer. Ends where the reader is meant to carry on.
        let prompt: String
        var id: String { title }
    }

    /// Four suggestions for the role the reader practises in.
    static func suggestions(for role: PractitionerRole) -> [Suggestion] {
        let summarise = Suggestion(
            title: "Summarise a judgment", systemImage: "doc.text",
            prompt: "Summarise the judgment in the attached file: the facts, the issues, the holding and the ratio.")
        let limitation = Suggestion(
            title: "Check limitation", systemImage: "clock",
            prompt: "Is the challenge still within limitation? Work it out from the dates in the attached documents.")
        switch role {
        case .litigator:
            return [
                Suggestion(title: "Prepare for a hearing", systemImage: "building.columns",
                           prompt: "Prepare a short hearing note for my next listed matter, with every point cited to its page."),
                summarise,
                Suggestion(title: "Draft a reply", systemImage: "pencil",
                           prompt: "Draft a reply to the attached notice, paragraph by paragraph."),
                limitation,
            ]
        case .seniorCounsel:
            return [
                Suggestion(title: "Opinion on a question", systemImage: "text.book.closed",
                           prompt: "Give an opinion on the following question, with the authorities that decide it: "),
                summarise,
                Suggestion(title: "Points for arguments", systemImage: "list.bullet",
                           prompt: "List the strongest points for arguments from the attached paper book, each cited to its page."),
                limitation,
            ]
        case .corporateCounsel:
            return [
                Suggestion(title: "Review a contract", systemImage: "doc.text.magnifyingglass",
                           prompt: "Review the attached contract and list the clauses that expose us, with what to ask for instead."),
                Suggestion(title: "Compliance this month", systemImage: "calendar.badge.checkmark",
                           prompt: "What statutory filings and compliances fall due for a company this month?"),
                Suggestion(title: "Draft a notice", systemImage: "pencil",
                           prompt: "Draft a legal notice for the following default: "),
                summarise,
            ]
        case .adjudicator:
            return [
                Suggestion(title: "Issues for decision", systemImage: "list.number",
                           prompt: "Frame the issues for decision from the attached pleadings."),
                Suggestion(title: "Compare the pleadings", systemImage: "square.split.2x1",
                           prompt: "Set out where the claim and the reply in the attached documents agree and where they differ."),
                summarise,
                limitation,
            ]
        case .student:
            return [
                summarise,
                Suggestion(title: "Explain a provision", systemImage: "book",
                           prompt: "Explain the following provision in plain words, with the leading cases on it: "),
                Suggestion(title: "Moot preparation", systemImage: "person.2",
                           prompt: "Help me prepare submissions for both sides on the following moot problem: "),
                Suggestion(title: "Case brief", systemImage: "doc.plaintext",
                           prompt: "Write a case brief of the attached judgment."),
            ]
        case .paralegal:
            return [
                Suggestion(title: "Index a paper book", systemImage: "list.bullet.rectangle",
                           prompt: "Prepare an index of the attached paper book: each document, its date and its pages."),
                Suggestion(title: "List of dates", systemImage: "calendar",
                           prompt: "Prepare a list of dates and events from the attached documents."),
                summarise,
                Suggestion(title: "Draft a covering letter", systemImage: "envelope",
                           prompt: "Draft a covering letter for filing the attached documents."),
            ]
        case .legalAid:
            return [
                Suggestion(title: "Explain someone's rights", systemImage: "person.badge.shield.checkmark",
                           prompt: "Explain, in simple words, the rights of a person in this situation: "),
                Suggestion(title: "Draft an application", systemImage: "pencil",
                           prompt: "Draft an application for the following relief: "),
                summarise,
                limitation,
            ]
        }
    }
}
