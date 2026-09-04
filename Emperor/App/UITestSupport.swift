#if DEBUG
import Foundation

/// Runs the app against a canned server, for the simulator UI tests.
///
/// ## Why a stubbed transport rather than fake services
///
/// `Session` already takes a `URLSession`, so a `URLProtocol` can answer every request without
/// touching the network. That means the UI tests drive the **real** services, view models,
/// decoders and stream parser — the whole stack the app actually ships — and only the socket is
/// replaced. Swapping in fake services would have tested the fakes.
///
/// It also means the fixtures below are a second, independent check on the wire contract: a
/// response shape that `APIModels` cannot decode fails the UI test as a blank screen, exactly as
/// it would against the real server.
///
/// ## Why this ships in the binary
///
/// `#if DEBUG` and inert without `-UITestMode`, so it is compiled out of any Release build and
/// does nothing in the debug build you sideload. The alternative — a separate scheme — buys
/// nothing and risks the tests exercising a target that is not the app.
enum UITestSupport {

    static let launchArgument = "-UITestMode"

    static var isActive: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    /// Start signed in. Sign-*out* is still exercised, from Settings.
    static var isSignedIn: Bool {
        !ProcessInfo.processInfo.arguments.contains("-UITestSignedOut")
    }

    /// Every list empty, so the empty states can be driven — they are a third of the branches in
    /// `ListStateView` and the easiest to get wrong.
    static var isEmpty: Bool {
        ProcessInfo.processInfo.arguments.contains("-UITestEmpty")
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// Answers the routes the screens under test call.
    ///
    /// Anything unlisted returns 200 with an empty object rather than failing: a screen this
    /// suite does not cover should not take the app down on some unrelated fetch, and a test
    /// that depends on a route it never declared is a test that is lying about its subject.
    final class StubProtocol: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}

        override func startLoading() {
            let path = request.url?.path.replacingOccurrences(of: "/api", with: "") ?? ""
            let body = Fixtures.body(for: path)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    /// The canned responses.
    ///
    /// Every key and every envelope here was read off the response type the service decodes
    /// into, not invented. That is not pedantry: the first run of this suite failed every
    /// signed-in test because `/login` omitted `success`, which `AuthResponse` declares
    /// **non-optional**. The app behaved exactly as it would against a server that did the same
    /// — sign-in silently did not happen — which is the whole argument for stubbing the
    /// transport instead of the services.
    ///
    /// `JSONDecoder` ignores unknown keys, so an extra field is harmless and only a *missing
    /// required* one breaks. Lists are populated only where the row model's required fields are
    /// known for certain; elsewhere they are empty, which is always valid and still renders a
    /// screen.
    enum Fixtures {
        static func body(for path: String) -> String {
            if isEmpty, let empty = emptyBody(for: path) { return empty }
            switch path {
            // `success` is **not** optional on `AuthResponse`. Omitting it fails the decode and
            // sign-in never happens.
            case "/login", "/register":
                return #"{"success":true,"token":"ui-test-token","user":{"id":1,"name":"Test Advocate","email":"test@example.com"}}"#
            case "/chats":
                return #"{"success":true,"chats":[{"id":"c1","title":"Bakshi v. State"}]}"#
            case "/messages":
                return #"{"success":true,"messages":[]}"#
            case "/cases":
                return #"{"success":true,"cases":[{"id":"case1","title":"Bakshi v. State of Maharashtra","court_name":"Bombay High Court","next_hearing_date":"2026-09-20"}]}"#
            case "/case":
                return #"{"success":true,"case":{"id":"case1","title":"Bakshi v. State of Maharashtra","court_name":"Bombay High Court"},"events":[],"items":[]}"#
            // `listings`, not `cases`, and `CauseListing` requires both `date` and `caseID` —
            // left empty rather than guessing their wire names.
            case "/cause-list":
                return #"{"success":true,"listings":[]}"#
            case "/compliance":
                return #"{"success":true,"events":[{"id":"e1","title":"File written statement"}]}"#
            case "/notifications":
                return #"{"success":true,"notifications":[{"id":"n1","title":"Hearing listed"}]}"#
            case "/notifications/unread-count":
                return #"{"success":true,"count":1}"#
            // `folders`, not `files`.
            case "/user-files":
                return #"{"success":true,"folders":[]}"#
            case "/library/categories":
                return #"{"success":true,"categories":[]}"#
            case "/library/subfilters":
                return #"{"success":true,"subFilters":[]}"#
            case "/library/browse":
                return #"{"success":true,"items":[],"total":0}"#
            case "/auction-notices":
                return #"{"success":true,"notices":[],"total":0}"#
            case "/auction-notices/facets":
                return #"{"success":true,"types":[],"platforms":[]}"#
            case "/documents", "/tables":
                return #"{"success":true,"documents":[],"tables":[]}"#
            // Both modes of the court lookup. A CNR is included so the card does not carry the
            // collision warning, which would otherwise be the thing a test sees first.
            case "/court/sc/auto", "/court/sc/diary", "/court/hc/search", "/court/hc/diary",
                 "/court/nclt/search", "/court/nclt/diary",
                 "/court/nclat/search", "/court/nclat/diary":
                return #"{"success":true,"results":[{"title":"Bakshi v. State of Maharashtra","caseType":"SLP(C)","caseNumber":"1234","caseYear":"2025","cnr":"SCIN010012342025","courtName":"Supreme Court of India"}]}"#
            default:
                return #"{"success":true}"#
            }
        }

        /// `nil` means "this route has no distinct empty shape", so the normal body is used.
        private static func emptyBody(for path: String) -> String? {
            switch path {
            case "/chats": return #"{"success":true,"chats":[]}"#
            case "/cases": return #"{"success":true,"cases":[]}"#
            case "/compliance": return #"{"success":true,"events":[]}"#
            case "/notifications": return #"{"success":true,"notifications":[]}"#
            case "/notifications/unread-count": return #"{"success":true,"count":0}"#
            default: return nil
            }
        }
    }
}
#endif
