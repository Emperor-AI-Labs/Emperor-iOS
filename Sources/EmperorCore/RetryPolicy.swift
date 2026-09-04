import Foundation

/// When to retry a failed request, and how long to wait.
///
/// The connection this app runs on is a courtroom corridor: signal drops for a few seconds and
/// comes back. A single transient failure should not put a "Try again" button in front of an
/// advocate who is walking — but a *persistent* one should, quickly, rather than spinning.
///
/// Deliberately narrow about what it will retry. Retrying the wrong thing is worse than not
/// retrying at all: a duplicate `POST /chat` would replace the chat's stored messages a second
/// time, and a retried 401 just burns battery on a session that is over.
struct RetryPolicy: Equatable, Sendable {
    /// How many *additional* attempts after the first.
    var maximumRetries: Int
    /// The wait before the first retry. Doubles each time.
    var initialDelay: TimeInterval
    /// The cap, so a long chain cannot leave someone staring at a spinner.
    var maximumDelay: TimeInterval
    /// Random slice added to each wait, as a fraction of it.
    ///
    /// Without jitter every screen that failed during the same signal drop retries in lockstep
    /// and hits the server as one burst — and this app opens five screens at once.
    var jitterFraction: Double

    static let `default` = RetryPolicy(
        maximumRetries: 2, initialDelay: 0.6, maximumDelay: 4, jitterFraction: 0.25)

    /// No retries. For writes, and anywhere a duplicate would be worse than a failure.
    static let none = RetryPolicy(
        maximumRetries: 0, initialDelay: 0, maximumDelay: 0, jitterFraction: 0)

    /// The wait before `attempt`, counting the first retry as 1.
    ///
    /// - Parameter randomFraction: injected so the schedule can be asserted rather than sampled.
    func delay(beforeRetry attempt: Int, randomFraction: Double = Double.random(in: 0...1))
        -> TimeInterval {
        guard attempt >= 1 else { return 0 }
        let exponential = initialDelay * pow(2, Double(attempt - 1))
        let capped = min(exponential, maximumDelay)
        return capped * (1 + jitterFraction * randomFraction)
    }

    /// Whether this failure is worth another attempt.
    ///
    /// Only conditions that plausibly clear on their own:
    ///
    /// - **Offline / transport** — the case this exists for.
    /// - **5xx** — except a maintenance 503, which is a deliberate outage with a `Retry-After`
    ///   measured in minutes; hammering it is pointless.
    ///
    /// Never retried:
    ///
    /// - **401** — the session is over. A retry cannot fix it and the app signs out instead.
    /// - **4xx** — the request is wrong; sending it again makes it wrong again.
    /// - **Decoding** — the bytes arrived and did not fit. Deterministic.
    ///
    /// - Warning: do **not** read the 5xx rule as "the server is unhappy, not the request".
    ///   That is the usual justification and it is false here: this backend answers a missing
    ///   or malformed parameter with a **500**, not a 400, on most routes — `/documents` throws
    ///   `Missing userId` straight into its 500 handler (`sync-server.js:10607`), and
    ///   `/auction-watchlists` and `/create-folder` do the same. So a 500 may well be a
    ///   deterministic client mistake, and this policy will spend three attempts and ~1.8s of
    ///   backoff before surfacing it.
    ///
    ///   That is survivable only because every route wrapped in `withRetry` today sends a fixed
    ///   parameter set that `APIClient.makeRequest` always completes. **Before wrapping a route
    ///   whose parameters are optional or user-supplied, check what it does with a bad one** —
    ///   otherwise a typo becomes a three-second wait for the same error.
    func shouldRetry(_ error: Error) -> Bool {
        guard maximumRetries > 0 else { return false }
        guard let apiError = error as? APIError else {
            return DisplayText.isOffline(error)
        }
        switch apiError {
        case .transport:
            return true
        case .server(let status, _):
            return (500..<600).contains(status)
        case .notAuthenticated, .invalidCredentials, .maintenance, .decoding:
            return false
        }
    }
}

/// Runs an operation, retrying transient failures on a backoff.
///
/// - Parameters:
///   - policy: what counts as retryable and how long to wait.
///   - sleep: injected so tests do not spend real seconds asleep.
///   - randomFraction: injected so the schedule is assertable.
///   - operation: must be safe to run more than once. `RetryPolicy.none` exists for the ones
///     that are not.
func withRetry<Value>(
    _ policy: RetryPolicy = .default,
    sleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    },
    randomFraction: @Sendable () -> Double = { Double.random(in: 0...1) },
    operation: () async throws -> Value
) async throws -> Value {
    var attempt = 0
    while true {
        do {
            return try await operation()
        } catch {
            attempt += 1
            guard attempt <= policy.maximumRetries, policy.shouldRetry(error) else { throw error }
            // Cancellation must win over the backoff, or a screen the user has left keeps
            // retrying in the background.
            try Task.checkCancellation()
            try await sleep(
                policy.delay(beforeRetry: attempt, randomFraction: randomFraction()))
        }
    }
}
