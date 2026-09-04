import Foundation

/// Turning wire values into something a practitioner should read.
///
/// Both rules here were previously inlined at every call site — six copies of the filename
/// rule across the views, and seven of the error rule. Inlined, each copy is a place for the
/// wording to drift, and none of them could be tested.
enum DisplayText {

    /// Presents a stored filename the way a person wrote it.
    ///
    /// Names are underscore-sanitised on disk (`UploadService.sanitize`), so what the server
    /// lists is `Partition_Suit_Order.pdf` rather than the title the user typed. Undoing that
    /// is display-only and must never be fed back to the API: annexure citations and status
    /// polls both match on the exact on-disk name.
    static func fileName(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ")
    }

    /// The message to show for a failed operation.
    ///
    /// `APIError` carries wording written for this product — "That email and password did not
    /// match", the server's own refusal text — whereas `localizedDescription` on the same value
    /// yields a generic framework string. Preferring the former is the whole point; the
    /// fallback is only for errors that come from outside our stack, such as `URLError` or the
    /// scanner.
    static func message(for error: Error) -> String {
        if let apiError = error as? APIError {
            // A transport failure that is really "no network" deserves the plainer sentence:
            // `URLError`'s own wording is framework English, and the distinction between
            // "you are offline" and "the server is unhappy" is the one users act on.
            if case .transport = apiError, isOffline(error) { return offlineMessage }
            return apiError.errorDescription ?? error.localizedDescription
        }
        if isOffline(error) { return offlineMessage }
        return error.localizedDescription
    }

    static let offlineMessage = "You appear to be offline. Check your connection and try again."

    /// A `YYYY-MM-DD` court day, written out — "Thursday, 14 September 2026".
    ///
    /// Formatted in India, because that is what the date means. Formatting it in the device's
    /// zone would name a different weekday for anyone travelling.
    static func longDay(_ key: String) -> String {
        guard let date = WireDate.parseDay(key) else { return key }
        return longDayFormatter.string(from: date)
    }


    /// A past instant, described the way a person would — "2 hours ago", "yesterday".
    ///
    /// Hand-rolled rather than `RelativeDateTimeFormatter`, which does not exist on Linux
    /// Foundation. Writing it out keeps the core buildable and testable on both platforms, and
    /// keeps the wording the same on both — which matters here, because this string is how a
    /// practitioner judges whether a hearing date is worth trusting.
    ///
    /// Beyond a week it falls back to the absolute day: "synced 3 weeks ago" invites a guess,
    /// where a date does not.
    static func relative(_ date: Date, from now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        guard seconds >= 0 else { return "just now" }

        switch seconds {
        case ..<60:
            return "just now"
        case ..<3_600:
            let minutes = Int(seconds / 60)
            return "\(minutes) minute\(minutes == 1 ? "" : "s") ago"
        case ..<86_400:
            let hours = Int(seconds / 3_600)
            return "\(hours) hour\(hours == 1 ? "" : "s") ago"
        default:
            // Compare calendar days in India, so "yesterday" means yesterday in court rather
            // than 24 hours ago.
            let days = dayDifference(from: date, to: now)
            switch days {
            case 0: return "earlier today"
            case 1: return "yesterday"
            case 2...6: return "\(days) days ago"
            default: return "on \(longDay(WireDate.dayKey(date)))"
            }
        }
    }

    private static func dayDifference(from earlier: Date, to later: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = WireDate.india
        let start = calendar.startOfDay(for: earlier)
        let end = calendar.startOfDay(for: later)
        return calendar.dateComponents([.day], from: start, to: end).day ?? 0
    }

    nonisolated(unsafe) private static let longDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, d MMMM yyyy"
        f.timeZone = WireDate.india
        return f
    }()

    /// Joins items the way a sentence does: "a", "a and b", "a, b and c".
    ///
    /// `ListFormatter` would do this, but it does not exist on Linux, where this is tested.
    /// No Oxford comma — this is British-English prose, matching the rest of the app's copy.
    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }

    /// Whether this failure is the network being unavailable rather than the server objecting.
    ///
    /// `APIError.transport` wraps `URLError.localizedDescription`, which loses the code — so
    /// matching on the wrapped text is the only signal left once it has been converted. Both
    /// paths are checked so the caller can ask either side of that conversion.
    static func isOffline(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return offlineCodes.contains(urlError.code)
        }
        if case .transport(let message)? = error as? APIError {
            return offlineDescriptions.contains { message.localizedCaseInsensitiveContains($0) }
        }
        return false
    }

    private static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
        .internationalRoamingOff, .cannotConnectToHost, .cannotFindHost,
        .dnsLookupFailed, .timedOut,
    ]

    private static let offlineDescriptions = [
        "offline", "not connected", "connection was lost", "network connection",
        "cannot connect", "could not connect", "hostname could not be found",
        "timed out", "connection appears to be offline",
    ]
}
