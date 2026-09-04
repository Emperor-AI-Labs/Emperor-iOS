import XCTest
@testable import EmperorCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class LoadStateTests: XCTestCase {

    private func presentation(_ state: LoadState, empty: Bool) -> ListPresentation {
        ListPresentation(state: state, isEmpty: empty)
    }

    // MARK: - The three-way distinction

    /// The whole point: these three are mutually exclusive, and exactly one holds when there
    /// is nothing to show. Collapsing any two is how a failed request comes to read as "you
    /// have nothing".
    func testExactlyOneStateHoldsForAnEmptyList() {
        let cases: [(LoadState, String)] = [
            (.idle, "idle"),
            (.loading, "loading"),
            (.loaded, "loaded"),
            (.failed(LoadFailure(APIError.server(status: 500, message: "boom"))), "failed"),
        ]
        for (state, label) in cases {
            let p = presentation(state, empty: true)
            let flags = [p.showsLoadingPlaceholder, p.showsEmptyState, p.showsFailureState]
            XCTAssertEqual(flags.filter { $0 }.count, 1, "\(label) should light exactly one")
        }
    }

    /// A view's `.task` runs after its first render, so there is always a frame at `.idle`.
    /// Showing the empty state there flashes "you have nothing" on every cold open.
    func testIdleShowsASpinnerNotAnEmptyState() {
        let p = presentation(.idle, empty: true)
        XCTAssertTrue(p.showsLoadingPlaceholder)
        XCTAssertFalse(p.showsEmptyState)
    }

    func testOnlyAReturnedLoadEarnsTheEmptyState() {
        XCTAssertTrue(presentation(.loaded, empty: true).showsEmptyState)
        XCTAssertFalse(presentation(.loading, empty: true).showsEmptyState)
        XCTAssertFalse(
            presentation(.failed(LoadFailure(APIError.transport("x"))), empty: true)
                .showsEmptyState)
    }

    /// Content on screen is never replaced by a spinner or an error page.
    func testExistingContentIsNeverBlanked() {
        for state: LoadState in [
            .idle, .loading, .loaded,
            .failed(LoadFailure(APIError.transport("x"))),
        ] {
            let p = presentation(state, empty: false)
            XCTAssertFalse(p.showsLoadingPlaceholder, "\(state)")
            XCTAssertFalse(p.showsEmptyState, "\(state)")
            XCTAssertFalse(p.showsFailureState, "\(state)")
        }
    }

    func testAFailedRefreshOverContentShowsAStaleBanner() {
        let failed = LoadState.failed(LoadFailure(APIError.transport("x")))
        XCTAssertTrue(presentation(failed, empty: false).showsStaleBanner)
        XCTAssertFalse(presentation(.loaded, empty: false).showsStaleBanner)
    }

    // MARK: - Failure classification

    func testOfflineIsDistinguishedFromAServerError() {
        let offline = LoadFailure(URLError(.notConnectedToInternet))
        XCTAssertEqual(offline.kind, .offline)
        XCTAssertEqual(offline.message, DisplayText.offlineMessage)

        let server = LoadFailure(APIError.server(status: 500, message: "Database is locked"))
        XCTAssertEqual(server.kind, .server)
        XCTAssertEqual(server.message, "Database is locked", "the server's own words survive")
    }

    /// `APIError.transport` has already flattened a `URLError` to its description, so the code
    /// is gone by then. Classification has to work on both sides of that conversion.
    func testOfflineIsDetectedAfterTransportFlattensTheURLError() {
        for wrapped in [
            "The Internet connection appears to be offline.",
            "The network connection was lost.",
            "Could not connect to the server.",
            "The request timed out.",
        ] {
            XCTAssertEqual(
                LoadFailure(APIError.transport(wrapped)).kind, .offline,
                "\(wrapped) should read as offline")
        }
    }

    /// A transport error that is not about connectivity stays a server problem.
    func testANonConnectivityTransportErrorIsNotOffline() {
        XCTAssertEqual(LoadFailure(APIError.transport("Malformed response.")).kind, .server)
    }

    func testBothAuthFailuresRequireSigningInAgain() {
        for error: APIError in [.notAuthenticated, .invalidCredentials] {
            let failure = LoadFailure(error)
            XCTAssertEqual(failure.kind, .unauthenticated, "\(error)")
            XCTAssertFalse(failure.isRetryable, "retrying an expired session is pointless")
        }
        XCTAssertTrue(
            LoadState.failed(LoadFailure(APIError.notAuthenticated)).requiresReauthentication)
        XCTAssertFalse(LoadState.loaded.requiresReauthentication)
    }

    func testDecodingFailuresAreServerProblems() {
        XCTAssertEqual(LoadFailure(APIError.decoding("bad shape")).kind, .server)
    }

    // MARK: - Accessors

    func testStateAccessors() {
        XCTAssertTrue(LoadState.loading.isLoading)
        XCTAssertTrue(LoadState.loaded.hasLoaded)
        XCTAssertNil(LoadState.loaded.failure)
        XCTAssertNotNil(LoadState.failed(LoadFailure(APIError.transport("x"))).failure)
    }
}
