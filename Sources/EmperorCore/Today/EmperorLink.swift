import Foundation

/// The app's own links — what the Today widget opens, and the one way in that needs no
/// notification.
///
/// - `emperor://calendar?day=2026-10-09` — the Calendar, on that day in India.
/// - `emperor://calendar` — the Calendar, on today.
/// - `emperor://updates` — the Updates screen.
///
/// A link only ever *navigates*. It cannot change anything, sign anyone in or out, or carry data
/// into the app beyond a day, so a link from anywhere — a widget, a note, another app — can do no
/// more than a tap inside the app could.
///
/// Anything else, including any other scheme, is not ours: `init(url:)` answers `nil` and the
/// URL is left for whichever handler it belongs to (a document being opened in the app, say).
enum EmperorLink: Equatable, Sendable {
    /// `nil` is today.
    case calendar(day: String?)
    case updates

    static let scheme = "emperor"

    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == Self.scheme
        else { return nil }
        // `emperor://calendar` puts the destination in the host; `emperor:calendar` in the path.
        // Both are read, since a hand-typed link could be either.
        let destination = (components.host ?? components.path)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        switch destination {
        case "calendar":
            let day = components.queryItems?.first { $0.name == "day" }?.value
            // A day that is not a real one opens the Calendar where it is, rather than somewhere
            // odd — checked by round trip, as a notification's day is.
            self = .calendar(day: day.flatMap { IndianDay.isValid($0) ? $0 : nil })
        case "updates":
            self = .updates
        default:
            return nil
        }
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .calendar(let day):
            components.host = "calendar"
            if let day { components.queryItems = [URLQueryItem(name: "day", value: day)] }
        case .updates:
            components.host = "updates"
        }
        // Every part is a fixed word or a validated `YYYY-MM-DD`, so this cannot fail; the
        // fallback is there only so a mistake here opens the app rather than crashing it.
        return components.url ?? URL(string: "\(Self.scheme)://calendar")!
    }
}
