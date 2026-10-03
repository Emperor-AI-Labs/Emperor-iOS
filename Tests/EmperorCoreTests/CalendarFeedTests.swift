import XCTest
@testable import EmperorCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The private calendar-subscription link: how the route's answer becomes a link a calendar
/// app can use, and every way it could become one that silently fetches nothing.
final class CalendarFeedTests: XCTestCase {

    private static let base = URL(string: "https://backend.example.test/api")!
    private static let secret = "0123456789abcdef0123456789abcdef"
    /// What the route answers: rooted, already carrying `/api` (`sync-server.js`,
    /// `/calendar/feed-url`).
    private static let path = "/api/calendar/my.ics?feed=\(secret)"

    override func setUp() {
        super.setUp()
        HTTPStub.reset()
    }

    override func tearDown() {
        HTTPStub.reset()
        super.tearDown()
    }

    // MARK: - Resolving the path

    /// Against the base's origin — appending to the base would give `/api/api/…`.
    func testThePathIsResolvedAgainstTheOriginNotAppendedToTheBase() throws {
        let url = try CalendarFeedURL.feedURL(fromPath: Self.path, base: Self.base)
        XCTAssertEqual(
            url.absoluteString,
            "https://backend.example.test/api/calendar/my.ics?feed=\(Self.secret)")
    }

    func testAPortOnTheBaseIsKept() throws {
        let url = try CalendarFeedURL.feedURL(
            fromPath: Self.path, base: URL(string: "https://dev.example.test:8443/api")!)
        XCTAssertEqual(url.port, 8443)
        XCTAssertEqual(url.path, "/api/calendar/my.ics")
    }

    func testAnAbsoluteHTTPSAnswerIsTakenAsItIs() throws {
        let absolute = "https://feeds.example.test/api/calendar/my.ics?feed=\(Self.secret)"
        let url = try CalendarFeedURL.feedURL(fromPath: absolute, base: Self.base)
        XCTAssertEqual(url.absoluteString, absolute)
    }

    /// The secret is the credential; it must never travel in the clear.
    func testAPlainHTTPLinkIsRefused() {
        XCTAssertThrowsError(try CalendarFeedURL.feedURL(
            fromPath: "http://backend.example.test/api/calendar/my.ics?feed=\(Self.secret)",
            base: Self.base))
    }

    /// A link without a full secret can only ever 404, which a calendar app shows as an empty
    /// calendar rather than an error. Refused here, where it can be explained.
    func testALinkWithoutAFullSecretIsRefused() {
        for bad in [
            "/api/calendar/my.ics",
            "/api/calendar/my.ics?feed=",
            "/api/calendar/my.ics?feed=abc123",
            "/api/calendar/my.ics?feed=\(Self.secret)&feed=\(Self.secret)",
            "",
            "calendar/my.ics?feed=\(Self.secret)",
            "//other.example.test/api/calendar/my.ics?feed=\(Self.secret)",
            "ftp://backend.example.test/my.ics?feed=\(Self.secret)",
        ] {
            XCTAssertThrowsError(
                try CalendarFeedURL.feedURL(fromPath: bad, base: Self.base), "accepted \(bad)")
        }
    }

    func testTheSecretIsReadFromTheQuery() throws {
        let url = try CalendarFeedURL.feedURL(fromPath: Self.path, base: Self.base)
        XCTAssertEqual(CalendarFeedURL.secret(in: url), Self.secret)
    }

    // MARK: - webcal

    /// Only the scheme changes: same host, port, path and secret.
    func testTheSubscribeLinkIsTheSameFeedAsWebcal() throws {
        let feed = URL(string: "https://dev.example.test:8443/api/calendar/my.ics?feed=\(Self.secret)")!
        let subscribe = try XCTUnwrap(CalendarFeedURL.subscribeURL(for: feed))
        XCTAssertEqual(
            subscribe.absoluteString,
            "webcal://dev.example.test:8443/api/calendar/my.ics?feed=\(Self.secret)")
    }

    func testOnlyAnHTTPSFeedBecomesASubscribeLink() {
        XCTAssertNil(CalendarFeedURL.subscribeURL(
            for: URL(string: "http://example.test/my.ics?feed=\(Self.secret)")!))
    }

    func testALinkCarriesBothForms() throws {
        let link = try CalendarFeedURL.link(fromPath: Self.path, base: Self.base)
        XCTAssertEqual(link.feedURL.scheme, "https")
        XCTAssertEqual(link.subscribeURL.scheme, "webcal")
        XCTAssertEqual(link.host, "backend.example.test")
    }

    // MARK: - The service, on the wire

    private func makeService() async -> CalendarFeedService {
        let client = APIClient(config: APIConfig(baseURL: Self.base), session: HTTPStub.session())
        await client.setCredentials(Credentials(token: "tok", userID: 42))
        return CalendarFeedService(client: client, baseURL: Self.base)
    }

    func testFetchingTheLinkIsAnAuthenticatedGet() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":true,"path":"\#(Self.path)","rotated":false}"#))

        let link = try await service.feedLink()

        let sent = try XCTUnwrap(HTTPStub.lastRequest)
        XCTAssertEqual(sent.httpMethod, "GET")
        XCTAssertEqual(sent.path, "/api/calendar/feed-url")
        XCTAssertEqual(sent.header("Authorization"), "Bearer tok")
        XCTAssertEqual(link.feedURL.path, "/api/calendar/my.ics")
    }

    func testResettingPostsRotate() async throws {
        let service = await makeService()
        let fresh = String(repeating: "f", count: 32)
        HTTPStub.always(.json(
            #"{"success":true,"path":"/api/calendar/my.ics?feed=\#(fresh)","rotated":true}"#))

        let link = try await service.resetFeedLink()

        let sent = try XCTUnwrap(HTTPStub.lastRequest)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.path, "/api/calendar/feed-url")
        XCTAssertEqual(sent.bodyJSON["rotate"] as? Bool, true)
        XCTAssertEqual(CalendarFeedURL.secret(in: link.feedURL), fresh)
    }

    /// The route answers 200 with the *existing* link when it did not rotate. Reporting that as
    /// a reset would tell someone whose link leaked that it is dead while it still works.
    func testAnAnswerThatDidNotRotateIsAFailedReset() async throws {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":true,"path":"\#(Self.path)","rotated":false}"#))
        do {
            _ = try await service.resetFeedLink()
            XCTFail("an unrotated answer must not count as a reset")
        } catch {
            XCTAssertTrue(DisplayText.message(for: error).contains("still works"))
        }
    }

    func testAFailureBodyIsAnError() async {
        let service = await makeService()
        HTTPStub.always(.json(
            #"{"success":false,"error":"Could not build your calendar feed link."}"#, status: 403))
        do {
            _ = try await service.feedLink()
            XCTFail("a failure must throw")
        } catch {
            XCTAssertEqual(
                DisplayText.message(for: error), "Could not build your calendar feed link.")
        }
    }

    func testAnUnusablePathIsAnError() async {
        let service = await makeService()
        HTTPStub.always(.json(#"{"success":true,"path":"/api/calendar/my.ics"}"#))
        do {
            _ = try await service.feedLink()
            XCTFail("a link without its secret must throw")
        } catch {
            XCTAssertTrue(DisplayText.message(for: error).contains("usable calendar link"))
        }
    }
}

// MARK: - The sheet's view model

final class CalendarSubscriptionViewModelTests: XCTestCase {

    private static func link(_ fill: Character) -> CalendarFeedLink {
        try! CalendarFeedURL.link(
            fromPath: "/api/calendar/my.ics?feed=\(String(repeating: fill, count: 32))",
            base: URL(string: "https://backend.example.test/api")!)
    }

    func testLoadingShowsTheLink() async {
        await withSubscription { service, model in
            service.current = Self.link("a")
            XCTAssertTrue(model.presentation.showsLoadingPlaceholder)
            await model.load()
            XCTAssertEqual(model.link, Self.link("a"))
            XCTAssertTrue(model.canUseLink)
        }
    }

    func testAFailedLoadIsAFailure() async {
        await withSubscription { service, model in
            service.error = APIError.server(status: 500, message: "down")
            await model.load()
            XCTAssertTrue(model.presentation.showsFailureState)
            XCTAssertFalse(model.canUseLink)
        }
    }

    func testAResetReplacesTheLinkAndSaysWhatHappened() async {
        await withSubscription { service, model in
            service.current = Self.link("a")
            service.next = Self.link("b")
            await model.load()
            await model.reset()
            XCTAssertEqual(model.link, Self.link("b"))
            XCTAssertTrue(model.didReset)
            XCTAssertNil(model.resetError)
        }
    }

    /// The old link is still the valid one, so it stays on screen and the failure is reported
    /// beside it — not swapped for a failure view.
    func testAFailedResetKeepsTheWorkingLink() async {
        await withSubscription { service, model in
            service.current = Self.link("a")
            await model.load()
            service.resetError = APIError.server(status: 500, message: "nope")
            await model.reset()
            XCTAssertEqual(model.link, Self.link("a"))
            XCTAssertFalse(model.didReset)
            XCTAssertEqual(model.resetError, "nope")
            XCTAssertFalse(model.presentation.showsFailureState)
        }
    }
}

final class FakeCalendarFeed: CalendarFeedProviding, @unchecked Sendable {
    var current: CalendarFeedLink?
    var next: CalendarFeedLink?
    var error: Error?
    var resetError: Error?

    func feedLink() async throws -> CalendarFeedLink {
        if let error { throw error }
        guard let current else { throw CalendarFeedURL.Failure.unusable }
        return current
    }

    func resetFeedLink() async throws -> CalendarFeedLink {
        if let resetError { throw resetError }
        guard let next else { throw CalendarFeedURL.Failure.unusable }
        current = next
        return next
    }
}

@MainActor
private func withSubscription(
    _ body: @MainActor (FakeCalendarFeed, CalendarSubscriptionViewModel) async -> Void
) async {
    let service = FakeCalendarFeed()
    await body(service, CalendarSubscriptionViewModel(service: service))
}
