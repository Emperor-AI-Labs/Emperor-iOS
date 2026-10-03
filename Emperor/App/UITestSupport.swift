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
            case "/login", "/auth/otp/verify", "/auth/session":
                return #"{"success":true,"token":"ui-test-token","user":{"id":1,"name":"Test Advocate","email":"test@example.com"}}"#
            // What the platform answers now: the account exists, a confirmation link is on its
            // way, and nobody is signed in (`sync-server.js`, "Deliberately NO token").
            case "/register":
                return #"{"success":true,"verificationRequired":true,"email":"new@example.com","user":{"id":2,"name":"New Advocate","email":"new@example.com"}}"#
            case "/auth/otp/request":
                return #"{"success":true,"sent":true,"expiresInMinutes":10}"#
            // A metered account part-way through a month, so the usage meters have something
            // to draw — including one running low and one used up.
            case "/billing/entitlements":
                return #"{"success":true,"signedIn":true,"planLabel":"Essential","expired":false,"metered":true,"limits":{"matters":-1,"storageGb":10,"documents":-1,"scannedPages":6000,"chatQueries":1000,"deepThinkingQueries":150},"usage":{"resetsAt":"2026-10-31T18:30:00.000Z","chatQueries":812,"deepThinkingQueries":150,"scannedPages":120,"documents":44,"matters":7,"storageUsedBytes":2400000000,"storageAllowanceBytes":10000000000}}"#
            case "/chats":
                return #"{"success":true,"chats":[{"id":"c1","title":"Bakshi v. State"}]}"#
            // One stored exchange shaped like a real answer — headings, a numbered list, a
            // table, a quotation, numbered citations and a References section — so the
            // screenshot tour shows the answer renderer and the citation badges doing their job.
            case "/messages":
                return ###"{"success":true,"messages":[{"id":"m1","role":"user","content":"What is the limitation period for a petition under Section 34 of the Arbitration Act?"},{"id":"m2","role":"assistant","content":"## Short answer\n\nA petition under **Section 34** must be filed within **three months** of receiving the award [1], extendable by a further thirty days on sufficient cause — and no further [2].\n\n## How the period runs\n\n1. Time starts when the party *receives* a signed copy of the award [1].\n2. Where a request under Section 33 was made, time runs from its disposal.\n3. Section 5 of the Limitation Act, 1963 does not apply to the outer limit [2].\n\n| Step | Period |\n|---|---|\n| Ordinary limit | 3 months |\n| Condonable extension | 30 days |\n\n> The thirty days are an outer limit, not a starting point for condonation.\n\n## References\n\n[1] Arbitration and Conciliation Act, 1996 — Section 34(3).\n[2] Union of India v. Popular Construction Co., (2001) 8 SCC 470."}]}"###
            case "/cases":
                return #"{"success":true,"cases":[{"id":"case1","title":"Bakshi v. State of Maharashtra","court_name":"Bombay High Court","next_hearing_date":"2026-09-20"}]}"#
            case "/case":
                return #"{"success":true,"case":{"id":"case1","title":"Bakshi v. State of Maharashtra","court_name":"Bombay High Court"},"events":[],"items":[]}"#
            // `listings`, not `cases`; `date` and `caseId` are the two keys `CauseListing`
            // requires. Dated today, in India, so Home has a row to draw — with the court, item,
            // coram and time a published list supplies, which is what the row is built around.
            case "/cause-list":
                return causeListBody()
            // A **bare array** — this route has no envelope. One dated row and one that needs
            // company context, which the screen drops and counts.
            case "/compliance-calendar":
                return complianceCalendarBody()
            // `path` is resolved against the API base's origin and must carry a full secret.
            case "/calendar/feed-url":
                return #"{"success":true,"path":"/api/calendar/my.ics?feed=0123456789abcdef0123456789abcdef","rotated":false}"#
            case "/compliance":
                return #"{"success":true,"events":[{"id":"e1","title":"File written statement"}]}"#
            case "/notifications":
                return #"{"success":true,"notifications":[{"id":"n1","title":"Hearing listed"}]}"#
            case "/notifications/unread-count":
                return #"{"success":true,"count":1}"#
            // `folders`, not `files`. One matter holding one document, so My Files has a folder
            // to open and a row to swipe. Every node carries `type`, which `FileNode` switches on,
            // and a file needs `status: "ready"` or it reads as still being processed.
            case "/user-files":
                return #"{"success":true,"folders":[{"type":"folder","name":"Bakshi","path":"Bakshi","created":"2026-09-01T10:00:00.000Z","files":[{"type":"file","name":"Plaint.pdf","path":"Bakshi/Plaint.pdf","size":2048,"modified":"2026-10-01T09:00:00.000Z","status":"ready","favorite":false}]}]}"#
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
            // A bare array, as `/ocr-history` answers — not an envelope. `userId` matches the
            // signed-in fixture user, or the client narrows the row away as someone else's.
            // `pageSetup` is an object, as the server stores it.
            case "/ocr-history":
                return #"[{"id":"1790000000000","status":"completed","step":5,"progress":100,"fileName":"Bakshi_Order.pdf","targetLang":"Hindi","pageSetup":{"size":"A4"},"logs":[],"userId":"1","outputFile":"1790000000000_Bakshi_Order_Hindi.docx"}]"#
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

        /// Today and `days` from now, as the `YYYY-MM-DD` keys the server sends — in India.
        private static func dayKey(_ days: Int) -> String {
            WireDate.dayKey(Date().addingTimeInterval(TimeInterval(days) * 86_400))
        }

        private static func causeListBody() -> String {
            let today = dayKey(0)
            return """
                {"success":true,"listings":[{"date":"\(today)","caseId":"case1","teamId":"team1",\
                "title":"Bakshi v. State of Maharashtra","courtName":"Bombay High Court",\
                "courtType":"hc","caseNumber":"1234","caseYear":"2025",\
                "coram":"Hon'ble Mr. Justice A. S. Gadkari","purpose":"For admission",\
                "courtNo":"Court No. 12","itemNo":"7","time":"10:30 AM","scraped":true,\
                "source":"causelist"}]}
                """
        }

        private static func complianceCalendarBody() -> String {
            let soon = dayKey(3)
            return """
                [{"id":"stat:GSTR1:\(soon)","compliance_id":"GSTR1","statutory":true,\
                "status":"open","name":"GSTR-1","title":"GSTR-1","category":"universal",\
                "ui_category":"gst","government_body":"CBIC","authority":"CBIC",\
                "frequency":"monthly","notes":null,"description":null,\
                "next_due_date":"\(soon)","date":"\(soon)","dateKey":"\(soon)",\
                "deadline_type":null,"deadline_value":null,"last_verified_date":"2026-07-29"},\
                {"id":"stat:AOC4:na","compliance_id":"AOC4","statutory":true,"status":"open",\
                "name":"AOC-4","title":"AOC-4","category":"universal","ui_category":"mca",\
                "government_body":"MCA","authority":"MCA","frequency":"annual","notes":null,\
                "description":null,"next_due_date":"N/A - no company context","date":null,\
                "dateKey":null,"deadline_type":"days_after_agm","deadline_value":"30",\
                "last_verified_date":"2026-07-29"}]
                """
        }

        /// `nil` means "this route has no distinct empty shape", so the normal body is used.
        private static func emptyBody(for path: String) -> String? {
            switch path {
            case "/chats": return #"{"success":true,"chats":[]}"#
            case "/cases": return #"{"success":true,"cases":[]}"#
            case "/cause-list": return #"{"success":true,"listings":[]}"#
            case "/compliance-calendar": return "[]"
            case "/compliance": return #"{"success":true,"events":[]}"#
            case "/notifications": return #"{"success":true,"notifications":[]}"#
            case "/notifications/unread-count": return #"{"success":true,"count":0}"#
            case "/user-files": return #"{"success":true,"folders":[]}"#
            case "/ocr-history": return "[]"
            default: return nil
            }
        }
    }
}
#endif
