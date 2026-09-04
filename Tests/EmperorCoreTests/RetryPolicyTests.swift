import XCTest
@testable import EmperorCore

/// Retry is the one piece of behaviour where getting it *wrong* is worse than not having it:
/// a retried write duplicates work server-side, and a retried 401 spins on a dead session.
/// So these pin what is retried at least as carefully as what is waited.
final class RetryPolicyTests: XCTestCase {

    // MARK: - What is retried

    func testTransportFailuresAreRetried() {
        XCTAssertTrue(RetryPolicy.default.shouldRetry(APIError.transport("lost connection")))
    }

    func testServerErrorsAreRetried() {
        for status in [500, 502, 503, 504, 599] {
            XCTAssertTrue(
                RetryPolicy.default.shouldRetry(APIError.server(status: status, message: "x")),
                "\(status) should be retried")
        }
    }

    /// A wrong request stays wrong. Retrying a 400 turns one error into three.
    func testClientErrorsAreNotRetried() {
        for status in [400, 403, 404, 413, 429, 499] {
            XCTAssertFalse(
                RetryPolicy.default.shouldRetry(APIError.server(status: status, message: "x")),
                "\(status) should not be retried")
        }
    }

    /// The session is over; the app signs out. Retrying delays that by seconds for nothing.
    func testAuthenticationFailuresAreNotRetried() {
        XCTAssertFalse(RetryPolicy.default.shouldRetry(APIError.notAuthenticated))
        XCTAssertFalse(RetryPolicy.default.shouldRetry(APIError.invalidCredentials))
    }

    /// Maintenance is a deliberate outage measured in minutes. It arrives as a 503, so without
    /// its own case it would be caught by the 5xx rule and hammered three times per screen.
    func testMaintenanceIsNotRetriedDespiteBeingA503() {
        XCTAssertFalse(RetryPolicy.default.shouldRetry(APIError.maintenance(message: "back at 6")))
    }

    /// The bytes arrived and did not fit the model. Deterministic — it will not fit next time.
    func testDecodingFailuresAreNotRetried() {
        XCTAssertFalse(RetryPolicy.default.shouldRetry(APIError.decoding("typeMismatch")))
    }

    /// The offline case reaches us as a raw `URLError` from anything that does not wrap.
    func testRawOfflineURLErrorIsRetried() {
        XCTAssertTrue(RetryPolicy.default.shouldRetry(URLError(.notConnectedToInternet)))
    }

    func testUnrelatedErrorsAreNotRetried() {
        struct Boom: Error {}
        XCTAssertFalse(RetryPolicy.default.shouldRetry(Boom()))
    }

    /// `.none` is what every write uses, so it must refuse even the obviously-transient cases.
    func testNonePolicyRetriesNothing() {
        XCTAssertFalse(RetryPolicy.none.shouldRetry(APIError.transport("lost")))
        XCTAssertFalse(RetryPolicy.none.shouldRetry(APIError.server(status: 503, message: "x")))
    }

    // MARK: - The schedule

    func testDelayDoublesEachAttempt() {
        let policy = RetryPolicy(
            maximumRetries: 5, initialDelay: 1, maximumDelay: 100, jitterFraction: 0)
        XCTAssertEqual(policy.delay(beforeRetry: 1, randomFraction: 0), 1)
        XCTAssertEqual(policy.delay(beforeRetry: 2, randomFraction: 0), 2)
        XCTAssertEqual(policy.delay(beforeRetry: 3, randomFraction: 0), 4)
        XCTAssertEqual(policy.delay(beforeRetry: 4, randomFraction: 0), 8)
    }

    /// Nobody waits 32 seconds at a listing board. The cap is the whole point of having one.
    func testDelayIsCapped() {
        let policy = RetryPolicy(
            maximumRetries: 9, initialDelay: 1, maximumDelay: 4, jitterFraction: 0)
        XCTAssertEqual(policy.delay(beforeRetry: 8, randomFraction: 0), 4)
    }

    /// Jitter only ever *adds*, so the floor of the window is the un-jittered delay — a retry
    /// can never fire sooner than the backoff says.
    func testJitterAddsWithinTheStatedFraction() {
        let policy = RetryPolicy(
            maximumRetries: 3, initialDelay: 2, maximumDelay: 10, jitterFraction: 0.25)
        XCTAssertEqual(policy.delay(beforeRetry: 1, randomFraction: 0), 2, accuracy: 0.0001)
        XCTAssertEqual(policy.delay(beforeRetry: 1, randomFraction: 1), 2.5, accuracy: 0.0001)
        XCTAssertEqual(policy.delay(beforeRetry: 1, randomFraction: 0.5), 2.25, accuracy: 0.0001)
    }

    func testDelayIsZeroBeforeTheFirstAttempt() {
        XCTAssertEqual(RetryPolicy.default.delay(beforeRetry: 0, randomFraction: 1), 0)
    }

    /// The default has to stay short enough that a genuinely dead server surfaces quickly.
    /// Worst case here is 0.75 + 1.5 = 2.25s of waiting before the error shows.
    func testDefaultPolicyFailsFastEnoughToNotFeelHung() {
        let policy = RetryPolicy.default
        let worst = (1...policy.maximumRetries)
            .map { policy.delay(beforeRetry: $0, randomFraction: 1) }
            .reduce(0, +)
        XCTAssertLessThan(worst, 3)
    }

    // MARK: - Running

    /// A helper that records what it was asked to sleep, so the schedule is asserted rather
    /// than waited out. `withRetry` is generic and non-isolated, so a class box is the simplest
    /// way to accumulate across attempts.
    private final class Recorder: @unchecked Sendable {
        var sleeps: [TimeInterval] = []
        var attempts = 0
    }

    func testSucceedsWithoutSleepingWhenTheFirstAttemptWorks() async throws {
        let recorder = Recorder()
        let value = try await withRetry(
            .default,
            sleep: { recorder.sleeps.append($0) },
            randomFraction: { 0 }
        ) {
            recorder.attempts += 1
            return 42
        }
        XCTAssertEqual(value, 42)
        XCTAssertEqual(recorder.attempts, 1)
        XCTAssertTrue(recorder.sleeps.isEmpty)
    }

    func testRetriesUntilItSucceeds() async throws {
        let recorder = Recorder()
        let value = try await withRetry(
            .default,
            sleep: { recorder.sleeps.append($0) },
            randomFraction: { 0 }
        ) {
            recorder.attempts += 1
            if recorder.attempts < 3 { throw APIError.transport("flaky") }
            return "ok"
        }
        XCTAssertEqual(value, "ok")
        XCTAssertEqual(recorder.attempts, 3)
        XCTAssertEqual(recorder.sleeps, [0.6, 1.2])
    }

    /// After the budget is spent the *original* error must surface — not a retry-shaped one —
    /// because the error wording the screens show is derived from it.
    func testGivesUpAfterTheBudgetAndRethrowsTheRealError() async {
        let recorder = Recorder()
        do {
            _ = try await withRetry(
                .default,
                sleep: { recorder.sleeps.append($0) },
                randomFraction: { 0 }
            ) {
                recorder.attempts += 1
                throw APIError.server(status: 502, message: "bad gateway")
            }
            XCTFail("should have thrown")
        } catch let error as APIError {
            guard case .server(let status, let message) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(status, 502)
            XCTAssertEqual(message, "bad gateway")
        } catch {
            XCTFail("wrong error type: \(error)")
        }
        XCTAssertEqual(recorder.attempts, 3, "first attempt plus two retries")
        XCTAssertEqual(recorder.sleeps.count, 2)
    }

    /// A non-retryable failure must cost exactly one attempt and no delay, or every mistyped
    /// password would take three seconds to be told it was wrong.
    func testNonRetryableFailureIsThrownImmediately() async {
        let recorder = Recorder()
        do {
            _ = try await withRetry(
                .default,
                sleep: { recorder.sleeps.append($0) },
                randomFraction: { 0 }
            ) {
                recorder.attempts += 1
                throw APIError.invalidCredentials
            }
            XCTFail("should have thrown")
        } catch {
            XCTAssertTrue(error is APIError)
        }
        XCTAssertEqual(recorder.attempts, 1)
        XCTAssertTrue(recorder.sleeps.isEmpty)
    }

    func testNonePolicyRunsExactlyOnce() async {
        let recorder = Recorder()
        _ = try? await withRetry(
            .none,
            sleep: { recorder.sleeps.append($0) },
            randomFraction: { 0 }
        ) {
            recorder.attempts += 1
            throw APIError.transport("lost")
        }
        XCTAssertEqual(recorder.attempts, 1)
    }

    /// The jitter source must be re-sampled per attempt. Sampling once and reusing it would
    /// put every client back in lockstep, which is the thing jitter exists to prevent.
    func testJitterIsSampledOncePerRetry() async {
        let recorder = Recorder()
        let draws = Recorder()
        let fractions = [0.0, 1.0]
        _ = try? await withRetry(
            RetryPolicy(maximumRetries: 2, initialDelay: 1, maximumDelay: 10, jitterFraction: 0.5),
            sleep: { recorder.sleeps.append($0) },
            randomFraction: {
                defer { draws.attempts += 1 }
                return fractions[min(draws.attempts, fractions.count - 1)]
            }
        ) {
            throw APIError.transport("lost")
        }
        XCTAssertEqual(draws.attempts, 2)
        XCTAssertEqual(recorder.sleeps[0], 1.0, accuracy: 0.0001)   // 1 * (1 + 0.5*0)
        XCTAssertEqual(recorder.sleeps[1], 3.0, accuracy: 0.0001)   // 2 * (1 + 0.5*1)
    }

    /// A screen the user has swiped away from must stop, not keep retrying in the background.
    func testCancellationStopsTheRetryLoop() async {
        let recorder = Recorder()
        let task = Task {
            try await withRetry(
                .default,
                sleep: { _ in
                    // Stand in for a real wait: give the cancel a chance to land.
                    try await Task.sleep(nanoseconds: 50_000_000)
                },
                randomFraction: { 0 }
            ) {
                recorder.attempts += 1
                throw APIError.transport("lost")
            }
        }
        // Let the first attempt run and enter the backoff before cancelling.
        try? await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()

        let result = await task.result
        if case .success = result { XCTFail("cancelled work should not succeed") }
        XCTAssertLessThanOrEqual(recorder.attempts, 2, "must not run the full budget after cancel")
    }
}
