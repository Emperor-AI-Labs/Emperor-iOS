import Foundation

/// The Overview's "N% complete" strip, as the web computes it (`SetupStrip.jsx`): six things a
/// matter is set up with, each either done or still to do. Pure, so the rule can be pinned here
/// and the screen only draws it.
///
/// The percentage is honest about what it cannot know: the documents step is `nil` until the
/// matter's files have been listed, and a `nil` step counts as neither done nor missing.
struct MatterSetup: Equatable, Sendable {

    struct Step: Equatable, Identifiable, Sendable {
        enum Key: String, Sendable { case court, side, parties, practice, documents, contact }
        let key: Key
        let label: String
        /// `true` done, `false` missing, `nil` not known yet.
        let done: Bool?
        var id: Key { key }
    }

    let steps: [Step]

    /// - Parameter fileCount: how many documents the matter holds, or `nil` while that is not
    ///   known — the detail route does not say, the list route and `/project-files` do.
    init(project: Project, people: [ProjectPerson], fileCount: Int?) {
        func has(_ value: String?) -> Bool {
            !(value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
        let clientReachable = people.contains { $0.isClient && $0.isReachable }
        steps = [
            Step(key: .court, label: "Court case", done: project.hasLinkedCase || project.isNotFiledYet),
            Step(key: .side, label: "Your side", done: has(project.ourSide)),
            Step(key: .parties, label: "Client & opposite party", done: has(project.client) && has(project.oppositeParty)),
            Step(key: .practice, label: "Practice area", done: has(project.practiceArea)),
            Step(key: .documents, label: "Documents", done: fileCount.map { $0 > 0 }),
            Step(key: .contact, label: "Client contact", done: clientReachable),
        ]
    }

    var doneCount: Int { steps.filter { $0.done == true }.count }
    var missing: [Step] { steps.filter { $0.done == false } }

    /// Rounded, out of every step — a step not known yet counts against the total, as the web's
    /// does, so the figure never jumps down when the files finish listing.
    var percent: Int { Int((Double(doneCount) / Double(steps.count) * 100).rounded()) }

    /// Whether there is anything left to show the strip for.
    var isComplete: Bool { missing.isEmpty && steps.allSatisfy { $0.done != nil } }

    /// "60% set up · Your side, Documents still to do".
    var summary: String {
        let head = "\(percent)% set up"
        guard !missing.isEmpty else { return isComplete ? "Set up" : head }
        return "\(head) · \(DisplayText.list(missing.map(\.label))) still to do"
    }
}

/// The one sentence under "Where things stand" (`OverviewSection.jsx`): what happens next on
/// the matter, in plain words, and what can be done when there is no date.
struct MatterStanding: Equatable, Sendable {
    enum Offer: Equatable, Sendable {
        /// Open the court search to link a case.
        case findCase
        /// Add a hearing to the chronology by hand.
        case addDate
    }

    let headline: String
    let detail: String?
    let offers: [Offer]

    /// - Parameters:
    ///   - nextHearingKey: the next hearing's day in India, from the matter or its linked case.
    ///   - lastHearingKey: the most recent past hearing's day, when there is no next one.
    ///   - todayKey: today in India.
    init(
        project: Project, linkedCase: LinkedCaseSummary?,
        nextHearingKey: String?, lastHearingKey: String?, todayKey: String
    ) {
        let court = [linkedCase?.courtName, project.forumName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

        if let next = nextHearingKey, next >= todayKey {
            let days = Self.days(from: todayKey, to: next)
            switch days {
            case 0: headline = "The case is in court today."
            case 1: headline = "The case is in court tomorrow."
            default: headline = "Next in court in \(days) days."
            }
            // `longDay` carries the weekday: "Wednesday, 28 October 2026".
            detail = [DisplayText.longDay(next), court].compactMap { $0 }.joined(separator: " · ")
            offers = []
        } else if project.isNotFiledYet {
            headline = "Not filed in court yet."
            detail = "Once it is filed, find the case and every hearing is tracked here for you."
            offers = [.findCase]
        } else if linkedCase != nil || project.hasLinkedCase {
            if let last = lastHearingKey {
                headline = "Waiting for the next date."
                detail = "Last heard on \(DisplayText.longDay(last)). The new date appears here as soon as the court gives one."
            } else {
                headline = "No hearing date yet."
                detail = "The date appears here as soon as the court lists the case."
            }
            offers = []
        } else {
            headline = "Add the court case to follow it here."
            detail = "Find it by case number and its hearings, orders and next date fill in by themselves."
            offers = [.findCase, .addDate]
        }
    }

    /// Whole days between two India day keys.
    static func days(from: String, to: String) -> Int {
        guard let a = WireDate.parseDay(from), let b = WireDate.parseDay(to) else { return 0 }
        return Int((b.timeIntervalSince(a) / 86_400).rounded())
    }
}
