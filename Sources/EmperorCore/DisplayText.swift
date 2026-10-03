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

    /// An attached document named for a list row: the file, then the matter holding it.
    ///
    /// `{name, folderName}` is the platform's identity for a document. Two matters may each hold
    /// an `Order.pdf`, so a row showing only the name cannot tell a reader which one it means —
    /// which matters most where the row's purpose is deciding whether to remove it.
    ///
    /// A document at the storage root has no folder to name, and gets the bare filename rather
    /// than a dangling separator.
    static func attachmentTitle(_ attachment: ChatAttachment) -> String {
        let file = fileName(attachment.name)
        guard let folder = attachment.folderName, !folder.isEmpty else { return file }
        return "\(file) — \(fileName(folder))"
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

    // MARK: - Refusals

    /// What to say when the server declines on purpose.
    ///
    /// **Written here rather than passed through**, for the plan codes above all. The server's
    /// sentences are written for the web, where the next step is a pricing page: "Upgrade your
    /// plan to keep going." This app takes no money and links to nothing that does, so repeating
    /// that sentence would be a call to action with nowhere to go — and the kind an App Store
    /// reviewer reads as steering a customer to a purchase made elsewhere. Each message below says
    /// what happened and what still works, and stops.
    ///
    /// The sign-in codes say what to do next on the sign-in screen itself, which is where they
    /// are shown.
    static func message(for refusal: Refusal) -> String {
        switch refusal.code {
        case .providerAccount:
            let provider = refusal.provider.map(providerName) ?? "another service"
            return "This account signs in with \(provider), so it has no password here. "
                + "We can email you a one-time code instead."
        case .emailUnverified:
            return "Confirm your email address first — open the link we sent, or sign in "
                + "with a one-time code, which confirms it too."
        case .accountExists:
            return "An account with this email already exists. Sign in instead."
        case .invalidCode:
            // The server's reason is the only thing that knows *why* the code failed, so it is
            // read for that — but worded here, like every other refusal, so no server sentence
            // reaches the screen unvetted (`authFlows.verifyOtp`).
            let reason = refusal.serverMessage.lowercased()
            if reason.contains("expired") {
                return "That code has expired. Ask for a new one."
            }
            if reason.contains("attempts") {
                return "Too many attempts with that code. Ask for a new one."
            }
            if reason.contains("request a new code") {
                return "That code can't be used any more. Ask for a new one."
            }
            return "That code is not correct. Check it, or ask for a new one."
        case .planRequired:
            return "This account doesn't have an active plan, so new questions and uploads are "
                + "paused. Everything already in the account can still be opened and exported."
        case .queryLimit:
            var sentence = refusal.limit.map { limit in
                "This account has used all \(grouped(limit)) of this month's questions."
            } ?? "This account has used this month's questions."
            if let resetsAt = refusal.resetsAt {
                sentence += " They renew on \(renewalDay(resetsAt))."
            }
            return sentence
        case .featureNotInPlan:
            return "That isn't included in this account's plan."
        case .documentLimit:
            return "This account has used this month's document uploads, so this one wasn't added."
        case .storageLimit:
            return "This account's storage is full, so this document wasn't uploaded."
        case .matterLimit:
            return "This account is already tracking as many matters as its plan allows."
        case .scanLimit:
            return "This account has used this month's scanned pages, so this document can't be "
                + "read yet."
        case .accountSuspended:
            return "This account is paused, so new work can't be started. Your history and "
                + "documents are still here to read. Contact support to restore it."
        case .rateLimit:
            return "That's more requests in an hour than anyone sends by hand, so the account is "
                + "paused for a few minutes. Please try again shortly."
        }
    }

    /// A short title for a refusal, for the places that show one above the message.
    static func title(for refusal: Refusal) -> String {
        switch refusal.code {
        case .providerAccount, .emailUnverified, .accountExists, .invalidCode:
            return "Can't sign in yet"
        case .planRequired: return "No active plan"
        case .queryLimit: return "Monthly questions used"
        case .featureNotInPlan: return "Not in this plan"
        case .documentLimit: return "Monthly uploads used"
        case .storageLimit: return "Storage full"
        case .matterLimit: return "Matter limit reached"
        case .scanLimit: return "Monthly scans used"
        case .accountSuspended: return "Account paused"
        case .rateLimit: return "Too many requests"
        }
    }

    /// "1 November" — the day an allowance renews, as a day in India, which is where the
    /// platform's month turns over (`usageMeter.js`, `periodResetsAt`).
    static func renewalDay(_ date: Date) -> String {
        renewalFormatter.string(from: date)
    }

    nonisolated(unsafe) private static let renewalFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMMM"
        f.locale = Locale(identifier: "en_IN")
        f.timeZone = WireDate.india
        return f
    }()

    /// Indian digit grouping — "1,000", "10,00,000" — matching how the platform prints counts
    /// (`toLocaleString('en-IN')`). Hand-rolled because `NumberFormatter`'s grouping on Linux
    /// Foundation does not apply the Indian pattern.
    static func grouped(_ value: Int) -> String {
        let negative = value < 0
        var digits = String(abs(value))
        guard digits.count > 3 else { return (negative ? "-" : "") + digits }
        let lastThree = String(digits.suffix(3))
        digits.removeLast(3)
        var groups: [String] = []
        while digits.count > 2 {
            groups.insert(String(digits.suffix(2)), at: 0)
            digits.removeLast(2)
        }
        if !digits.isEmpty { groups.insert(digits, at: 0) }
        return (negative ? "-" : "") + (groups + [lastThree]).joined(separator: ",")
    }

    private static func providerName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "google": return "Google"
        case "apple": return "Apple"
        case "microsoft": return "Microsoft"
        default: return raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }

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
