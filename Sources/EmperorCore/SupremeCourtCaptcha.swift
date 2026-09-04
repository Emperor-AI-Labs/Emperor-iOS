import Foundation

/// The Supreme Court's captcha, when the server could not read it for us.
///
/// ## Why this exists at all
///
/// `/court/sc/auto` is a complete flow on its own: it opens a session with the court, OCRs the
/// captcha, submits, and retries up to six times, all server-side. On the happy path no captcha
/// ever reaches the phone. But the court's captcha is a hand-drawn arithmetic image and the
/// solver does fail, and when it does this is the **only** way through — there is no other route
/// to a Supreme Court case by number.
///
/// So this is not a nicety. Without it, a failed OCR is a dead end on the one forum whose cases
/// most often have no CNR to fall back on.
///
/// ## The one rule that is easy to get wrong
///
/// **A session is spent by a single submit, right or wrong.** The server deletes it before it
/// even checks the answer, so a wrong answer and an expired session are the same state: there is
/// nothing left to retry against. Re-submitting the same `sessionID` does not report "wrong
/// again", it reports *expired*, which reads to a user as the app losing their place.
///
/// Both outcomes therefore mean the same thing to the caller — **fetch a new captcha** — which
/// is why `CaptchaOutcome` does not distinguish them beyond the sentence it carries.
struct SupremeCourtCaptcha: Equatable, Sendable {
    /// Opaque; echo it back untouched. Server-side state keyed by this string expires 8 minutes
    /// after it is minted.
    let sessionID: String
    /// The PNG itself, already decoded. The wire carries it as a `data:` URI rather than a URL,
    /// so there is nothing to fetch and nothing to authenticate.
    let image: Data

    /// How long the server keeps the session. Not enforced here — the server is the authority
    /// and answers `expired` — but the screen uses it to offer a fresh image before the user
    /// types into one that has already died.
    static let sessionLifetime: TimeInterval = 8 * 60

    /// Pulls the PNG out of a `data:` URI.
    ///
    /// Returns `nil` rather than throwing for anything malformed: this is one field of a
    /// response, and a caller that cannot show an image needs to say "could not load the
    /// CAPTCHA" whatever the reason. Distinguishing "no comma" from "bad base64" would give the
    /// user nothing to act on.
    ///
    /// The prefix is not matched exactly. It is `data:image/png;base64,` today, but the only
    /// part this actually needs is the payload after the first comma — insisting on the media
    /// type would break on a server that switched to JPEG for a reason that does not concern us.
    static func decodeImage(fromDataURI uri: String) -> Data? {
        guard uri.hasPrefix("data:"), let comma = uri.firstIndex(of: ",") else { return nil }
        let payload = uri[uri.index(after: comma)...]
        guard !payload.isEmpty else { return nil }
        return Data(base64Encoded: String(payload))
    }
}

/// What came back from submitting a captcha answer.
///
/// An enum rather than a throwing call because two of the three outcomes are ordinary use — a
/// person mistyping a smudged digit is not an error condition, and treating it as one puts a
/// failure banner over a form the user is still working in.
enum CaptchaOutcome: Equatable, Sendable {
    /// The court answered. May be empty, which means it had no such case.
    case results([CourtSearchResult])
    /// The answer was wrong, or the session had already expired. Either way the session is gone:
    /// **get a new captcha**, do not resubmit. `message` is the server's own wording.
    case needsANewCaptcha(message: String)
}

/// The server's own captcha solver gave up, and a person can get through where it could not.
///
/// Thrown only for a Supreme Court search by case number, because that is the only lookup with
/// a manual route behind it. The High Court sends the same `fallback` flag to mean something
/// different — that its automated search is not wired up yet — and there is no session/submit
/// pair there for a human to use, so that one stays an ordinary failure.
struct NeedsHumanCaptcha: LocalizedError, Equatable {
    var errorDescription: String? {
        "The Supreme Court asked for a CAPTCHA. Solve it to continue."
    }
}
