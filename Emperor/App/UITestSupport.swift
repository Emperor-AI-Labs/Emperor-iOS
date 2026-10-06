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

    /// A one-page PDF where iOS would put a document another app handed over, for
    /// `-UITestIncomingDocument`. Written fresh on each launch; the app moves it into its own
    /// store, as it does the real inbox copy.
    static func sampleIncomingDocument() -> URL? {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("UITestShared", isDirectory: true)
        let url = folder.appendingPathComponent("Sample Order.pdf")
        let pdf = """
            %PDF-1.4
            1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj
            2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj
            3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] >> endobj
            trailer << /Root 1 0 R >>
            %%EOF
            """
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(pdf.utf8).write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// `-UITestLinkOnReturn <link>`, as many times as there are links: each is opened, in order,
    /// the next time the signed-in app comes back from the background — which is how a tap on the
    /// Today widget or a notification reaches an app that is already running.
    ///
    /// The tests cannot simply hand the running app a link. `XCUIApplication.open(_:)` *launches*
    /// the app with it, ending the running process first — and with it the in-memory session, so
    /// the link lands on the sign-in screen (seen on CI: the app went to the Home Screen and came
    /// back through a cold launch). `XCUIDevice.system.open(_:)` is reported to stop on an "Open
    /// in…" confirmation that the test cannot answer while the call is waiting. So the link is
    /// carried in from launch and opened through `AppLinks.open`, the function
    /// `RootView.onOpenURL` calls.
    @MainActor
    static func takeLinkOnReturn() -> URL? {
        let arguments = ProcessInfo.processInfo.arguments
        let links = arguments.indices.compactMap { index -> URL? in
            guard arguments[index] == "-UITestLinkOnReturn",
                  arguments.indices.contains(index + 1)
            else { return nil }
            return URL(string: arguments[index + 1])
        }
        guard isActive, linksOpened < links.count else { return nil }
        defer { linksOpened += 1 }
        return links[linksOpened]
    }

    @MainActor private static var linksOpened = 0

    /// The signal goes after the first load: every request answers once, then fails as a phone
    /// with no connection does. So a conversation, document or matter opened once can be opened
    /// again offline, which is what offline reading is for — and a second conversation opened for
    /// the first time still loads, which is how the iPad, whose open conversation cannot be
    /// re-chosen, leaves and comes back to it.
    static var isOffline: Bool {
        ProcessInfo.processInfo.arguments.contains("-UITestOffline")
    }

    /// The requests already answered once in an offline run — a route and its query, so each
    /// conversation's `/messages` is its own. Behind a lock because `URLProtocol` answers on the
    /// session's own queue.
    final class AnsweredRoutes: @unchecked Sendable {
        static let shared = AnsweredRoutes()
        private let lock = NSLock()
        private var answered: Set<String> = []

        /// `true` the first time a request is made, and never again.
        func isFirst(_ url: URL?) -> Bool {
            lock.withLock { answered.insert(Self.key(for: url)).inserted }
        }

        /// The path and the query, its items sorted: the client builds a query from a dictionary,
        /// whose order is not promised to be the same twice.
        private static func key(for url: URL?) -> String {
            guard let url else { return "" }
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let query = items.map { "\($0.name)=\($0.value ?? "")" }.sorted()
            return ([url.path] + query).joined(separator: "&")
        }
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
            if UITestSupport.isOffline, !AnsweredRoutes.shared.isFirst(request.url) {
                // A bare code, with none of the wording iOS gives the real thing — the harder case,
                // and the one a phone set to another language presents too. The client reads the
                // code (`APIError.transportFailure`), so it takes this for no connection as it
                // takes a real phone's.
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
                return
            }
            // The profile write answers with the account as it was sent, as the platform does.
            if path == "/update-profile" { Fixtures.ProfileStub.shared.record(request) }
            let body = Fixtures.itemBody(for: request.url) ?? Fixtures.body(for: path)
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
                return #"{"success":true,"token":"ui-test-token","user":{"id":1,"name":"John Doe","email":"john.doe@firm.com","phone":"+919876543210"}}"#
            // What the platform answers now: the account exists, a confirmation link is on its
            // way, and nobody is signed in (`sync-server.js`, "Deliberately NO token").
            case "/register":
                return #"{"success":true,"verificationRequired":true,"email":"jane.doe@firm.com","user":{"id":2,"name":"Jane Doe","email":"jane.doe@firm.com"}}"#
            case "/auth/otp/request":
                return #"{"success":true,"sent":true,"expiresInMinutes":10}"#
            // A metered account part-way through a month, so the usage meters have something
            // to draw — including one running low and one used up.
            case "/billing/entitlements":
                return #"{"success":true,"signedIn":true,"planLabel":"Essential","expired":false,"metered":true,"limits":{"matters":-1,"storageGb":10,"documents":-1,"scannedPages":6000,"chatQueries":1000,"deepThinkingQueries":150},"usage":{"resetsAt":"2026-10-31T18:30:00.000Z","chatQueries":812,"deepThinkingQueries":150,"scannedPages":120,"documents":44,"matters":7,"storageUsedBytes":2400000000,"storageAllowanceBytes":10000000000}}"#
            // Two, so the iPad's list beside its conversation has another row to choose; `c2`
            // answers `/messages` with an exchange of its own (`itemBody`).
            case "/chats":
                return #"{"success":true,"chats":[{"id":"c1","title":"Bakshi v. State"},{"id":"c2","title":"Kapoor Textiles — stay"}]}"#
            // One stored exchange shaped like a real answer — headings, a numbered list, a
            // table, a quotation, numbered citations and a References section — so the
            // screenshot tour shows the answer renderer and the citation badges doing their job.
            // The answer carries the work log the web stores with every answer (`reasoning`,
            // `workflowTasks`, `workLog`; see `WorkLogWire`), so the panel is drawn above it.
            case "/messages":
                return ###"{"success":true,"messages":[{"id":"m1","role":"user","content":"What is the limitation period for a petition under Section 34 of the Arbitration Act?"},{"id":"m2","role":"assistant","content":"## Short answer\n\nA petition under **Section 34** must be filed within **three months** of receiving the award [1], extendable by a further thirty days on sufficient cause — and no further [2].\n\n## How the period runs\n\n1. Time starts when the party *receives* a signed copy of the award [1].\n2. Where a request under Section 33 was made, time runs from its disposal.\n3. Section 5 of the Limitation Act, 1963 does not apply to the outer limit [2].\n\n| Step | Period |\n|---|---|\n| Ordinary limit | 3 months |\n| Condonable extension | 30 days |\n\n> The thirty days are an outer limit, not a starting point for condonation.\n\n## References\n\n[1] Arbitration and Conciliation Act, 1996 — Section 34(3).\n[2] Union of India v. Popular Construction Co., (2001) 8 SCC 470.","reasoning":{"points":[{"text":"The outer limit turns on Section 34(3) and its proviso.","done":true}],"seconds":38},"workflowTasks":[{"title":"Find the limitation","subtasks":[{"label":"Reading Section 34(3) and its proviso","tools":["search_knowledge_base"],"status":"completed"},{"label":"Checking whether the Limitation Act extends it","status":"completed"}],"status":"completed"}],"workLog":[{"kind":"note","text":"Let me find the limitation provision first."},{"kind":"group","status":"completed","steps":[{"label":"Searching the record for: Section 34(3) limitation","status":"completed"},{"label":"Reading pages 12–14 of Arbitration Act 1996","status":"completed"}]}]}]}"###
            // `case1` throughout — `/cases`, `/case` and `/cause-list` describe one matter, heard
            // today, so the Calendar lists it once (the two sources de-duplicate) and opening it
            // lands on the same matter's overview.
            case "/cases":
                return casesBody()
            case "/case":
                return caseBody()
            // `listings`, not `cases`; `date` and `caseId` are the two keys `CauseListing`
            // requires. Dated today, in India, so Home and the Calendar have a row to draw — with
            // the court, item, coram and time a published list supplies, which is what the row
            // is built around.
            case "/cause-list":
                return causeListBody()
            // A **bare array** — this route has no envelope. One dated row and one that needs
            // company context, which the screen drops and counts.
            case "/compliance-calendar":
                return complianceCalendarBody()
            // `path` is resolved against the API base's origin and must carry a full secret.
            case "/calendar/feed-url":
                return #"{"success":true,"path":"/api/calendar/my.ics?feed=0123456789abcdef0123456789abcdef","rotated":false}"#
            // Due today, so the Calendar's day carries a diary entry under its listing.
            case "/compliance":
                return complianceBody()
            case "/notifications":
                return #"{"success":true,"notifications":[{"id":"n1","title":"Hearing listed"}]}"#
            case "/notifications/unread-count":
                return #"{"success":true,"count":1}"#
            // The account's daily email, for Settings → Notifications. Remembers the switch for
            // the run, so turning it on reads back as on — the screen re-reads `/notif/status`
            // after every change rather than assuming. No `success` key on the status: the
            // platform sends the fields alone.
            case "/notif/status":
                return EmailBriefingStub.shared.status()
            case "/notif/optin":
                EmailBriefingStub.shared.set(optedIn: true)
                return #"{"success":true}"#
            case "/notif/optout":
                EmailBriefingStub.shared.set(optedIn: false)
                return #"{"success":true}"#
            case "/notif/test":
                return #"{"success":true,"emailed":1,"pushed":0,"skipped":0,"errors":[]}"#
            // Settings → Edit profile. The signed-in fixture user, with the four profile fields
            // as the request carried them — see `ProfileStub`.
            case "/update-profile":
                return ProfileStub.shared.reply()
            // `folders`, not `files`. Every node carries `type`, which `FileNode` switches on,
            // and a file needs `status: "ready"` or it reads as still being processed. See
            // `userFilesBody` for what the library holds.
            case "/user-files":
                return userFilesBody()
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

        private static func casesBody() -> String {
            """
            {"success":true,"cases":[{"id":"case1","title":"Bakshi v. State of Maharashtra",\
            "court_name":"Bombay High Court","case_number":"1234","case_year":"2025",\
            "next_hearing_date":"\(dayKey(0))"},\(docketBody())]}
            """
        }

        /// The rest of the docket: a matter under every court heading, so the Cases tab has its
        /// headings to draw in order and its sorts and filters something to sort and filter.
        ///
        /// Each is stamped the way the court lookup saves one — `court_type`, `court_code` and
        /// the court's own name — while `case1` above carries no type at all and is placed by its
        /// name, as an older case would be. Two High Courts besides Bombay, so that heading holds
        /// more than one. **No hearing is today**: the Calendar opens on today, and its tests
        /// expect `case1` to be the only listing there. Some came from the court and some were
        /// typed in, for the source filter; some have no hearing date, for the hearing filter.
        private static func docketBody() -> String {
            let synced = #""last_synced_at":"2026-10-05T22:00:00.000Z""#
            return """
                {"id":"case-sc","title":"Rao v. Union of India","court_type":"sc",\
                "court_code":"sc","court_name":"Supreme Court of India","case_type":"SLP(C)",\
                "case_number":"8812","case_year":"2025","diary_number":"41207/2025",\
                "stage":"For admission","next_hearing_date":"\(dayKey(6))",\
                "filing_date":"2025-03-18","updated_at":"2026-10-05T22:00:00.000Z",\(synced)},\
                {"id":"case-hc-delhi","title":"Kapoor Textiles Pvt. Ltd. v. Commissioner of Customs",\
                "court_type":"hc","court_code":"hc-delhi","court_name":"High Court of Delhi",\
                "case_type":"W.P.(C)","case_number":"10421","case_year":"2024",\
                "cnr":"DLHC010104212024","judge":"Hon'ble Ms. Justice R. Menon",\
                "stage":"Arguments","next_hearing_date":"\(dayKey(2))",\
                "filing_date":"2024-06-01","updated_at":"2026-10-04T09:30:00.000Z",\(synced)},\
                {"id":"case-hc-madras","title":"Lakshmi Spinning Mills v. Regional Provident Fund Commissioner",\
                "court_type":"hc","court_code":"hc-madras","court_name":"Madras High Court",\
                "case_type":"W.A.","case_number":"2210","case_year":"2023","status":"Pending",\
                "filing_date":"2023-07-14","updated_at":"2026-07-02 08:15:00"},\
                {"id":"case-nclat","title":"Creditors of Sunrise Alloys Ltd. v. Resolution Professional",\
                "court_type":"nclat","court_code":"trib-nclat",\
                "court_name":"National Company Law Appellate Tribunal, New Delhi",\
                "case_type":"Comp. App. (AT) (Ins.)","case_number":"512","case_year":"2025",\
                "stage":"Final arguments","next_hearing_date":"\(dayKey(9))",\
                "filing_date":"2025-05-05","updated_at":"2026-10-01T12:00:00.000Z",\(synced)},\
                {"id":"case-nclt","title":"Meridian Finance Ltd. v. Prakash Infra Projects Pvt. Ltd.",\
                "court_type":"nclt","court_code":"trib-nclt","court_name":"NCLT Mumbai Bench",\
                "case_type":"C.P. (IB)","case_number":"1187","case_year":"2024",\
                "stage":"Reserved for orders","next_hearing_date":"\(dayKey(-12))",\
                "filing_date":"2024-02-12","updated_at":"2026-09-20 11:00:00"},\
                {"id":"case-drt","title":"Western Coast Bank v. Mehta Exports",\
                "court_type":"tribunal","court_code":"trib-drt",\
                "court_name":"Debts Recovery Tribunal-I, Mumbai","case_type":"O.A.",\
                "case_number":"233","case_year":"2023","status":"Pending",\
                "updated_at":"2026-08-11T10:00:00.000Z"},\
                {"id":"case-district","title":"Desai v. Desai","court_type":"district",\
                "court_code":"dist-family","court_name":"Family Court, Bandra",\
                "case_type":"M.J. Petition","case_number":"1450","case_year":"2025",\
                "stage":"Mediation","next_hearing_date":"\(dayKey(15))",\
                "filing_date":"2025-08-01"},\
                {"id":"case-forum","title":"Iyer v. Skyline Builders","court_type":"forum",\
                "court_code":"forum-scdrc",\
                "court_name":"State Consumer Disputes Redressal Commission, Maharashtra",\
                "case_type":"C.C.","case_number":"88","case_year":"2024","stage":"Evidence",\
                "next_hearing_date":"\(dayKey(-30))","filing_date":"2024-04-22",\(synced)}
                """
        }

        private static func caseBody() -> String {
            """
            {"success":true,"case":{"id":"case1","title":"Bakshi v. State of Maharashtra",\
            "court_name":"Bombay High Court","case_type":"W.P.","case_number":"1234",\
            "case_year":"2025","judge":"Hon'ble Mr. Justice A. S. Gadkari",\
            "stage":"Admission","next_hearing_date":"\(dayKey(0))"},"events":[],"items":[]}
            """
        }

        private static func complianceBody() -> String {
            """
            {"success":true,"events":[{"id":"e1","title":"File written statement",\
            "type":"filing","status":"open","due_date":"\(dayKey(0))"}]}
            """
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

        /// Two matters and a loose document, so My Files has a grid of folder tiles to draw, a
        /// folder inside a folder to open, and a row under "Not in a folder". Bakshi still holds
        /// `Plaint.pdf` directly — the document the deletion test swipes — beside its `Orders`
        /// sub-folder. Files and folders mix at every level, the top included, as the server
        /// sends them.
        private static func userFilesBody() -> String {
            """
            {"success":true,"folders":[{"type":"folder","name":"Bakshi","path":"Bakshi",\
            "created":"2026-09-01T10:00:00.000Z","files":[{"type":"file","name":"Plaint.pdf",\
            "path":"Bakshi/Plaint.pdf","size":2048,"modified":"2026-10-01T09:00:00.000Z",\
            "status":"ready","favorite":false},{"type":"folder","name":"Orders",\
            "path":"Bakshi/Orders","created":"2026-09-02T10:00:00.000Z","files":[{"type":"file",\
            "name":"Interim_Order.pdf","path":"Bakshi/Orders/Interim_Order.pdf","size":4096,\
            "modified":"2026-09-20T09:00:00.000Z","status":"ready","favorite":true}]}]},\
            {"type":"folder","name":"Arora_Holdings","path":"Arora_Holdings",\
            "created":"2026-09-15T10:00:00.000Z","files":[{"type":"file",\
            "name":"Board_Resolution.docx","path":"Arora_Holdings/Board_Resolution.docx",\
            "size":1024,"modified":"2026-09-16T09:00:00.000Z","status":"ready",\
            "favorite":false}]},{"type":"file","name":"Engagement_Letter.pdf",\
            "path":"Engagement_Letter.pdf","size":3072,"modified":"2026-09-30T09:00:00.000Z",\
            "status":"ready","favorite":false}]}
            """
        }

        /// The daily-email switch, as the stub server holds it for one run. Behind a lock
        /// because `URLProtocol` answers on the session's own queue.
        final class EmailBriefingStub: @unchecked Sendable {
            static let shared = EmailBriefingStub()
            private let lock = NSLock()
            private var optedIn = false

            func set(optedIn value: Bool) { lock.withLock { optedIn = value } }

            func status() -> String {
                let on = lock.withLock { optedIn }
                return #"{"asked":true,"optedIn":\#(on),"pushCount":0,"systemEnabled":true,"notifTime":"08:00"}"#
            }
        }

        // MARK: - Answers that depend on which item was asked for

        /// The answer for one item of a route that is otherwise answered the same for every id —
        /// or `nil`, and `body(for:)` answers as it always has.
        ///
        /// For the iPad's list beside its detail: a test can only tell the detail column was
        /// replaced when the second item it opens reads differently from the first. So `/case`
        /// answers each docket matter as itself (`case1` keeps the answer above), and `/messages`
        /// answers `c2` with an exchange of its own. Every other id, including a conversation
        /// started in the test, gets exactly what it got before.
        static func itemBody(for url: URL?) -> String? {
            guard !isEmpty, let url,
                  let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            else { return nil }
            func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
            switch url.path.replacingOccurrences(of: "/api", with: "") {
            case "/case":
                guard let id = value("id"), id != "case1" else { return nil }
                return docketCaseBody(id: id)
            case "/messages":
                guard value("chatId") == "c2" else { return nil }
                return secondConversationBody
            default:
                return nil
            }
        }

        /// One matter of `docketBody`, as `/case` sends a matter: the same object, under `case`.
        /// Read out of the docket rather than written twice, so the row and its screen agree.
        private static func docketCaseBody(id: String) -> String? {
            guard let list = try? JSONSerialization.jsonObject(
                      with: Data("[\(docketBody())]".utf8)) as? [[String: Any]],
                  let match = list.first(where: { $0["id"] as? String == id }),
                  let data = try? JSONSerialization.data(withJSONObject: match),
                  let object = String(data: data, encoding: .utf8)
            else { return nil }
            return #"{"success":true,"case":"# + object + #","events":[],"items":[]}"#
        }

        /// A second conversation, short and plain — no work log, no table — so it cannot be
        /// mistaken for the first.
        private static let secondConversationBody = ###"{"success":true,"messages":[{"id":"k1","role":"user","content":"Can the Customs order in Kapoor Textiles be stayed pending the writ?"},{"id":"k2","role":"assistant","content":"## Stay pending the writ\n\nThe High Court may stay the order where a strong prima facie case, the balance of convenience and irreparable injury are shown together. Offer a deposit of part of the duty demanded; it is the usual condition of an interim stay."}]}"###
        /// The account `/update-profile` stores, echoed back: the fixture user's id, email and
        /// mobile, and the profile fields exactly as sent. Behind a lock for the reason
        /// `EmailBriefingStub` gives.
        final class ProfileStub: @unchecked Sendable {
            static let shared = ProfileStub()
            private let lock = NSLock()
            private var sent: [String: Any] = [:]

            func record(_ request: URLRequest) {
                // `httpBody` is moved into a stream on its way through `URLSession`, so read both.
                var data = request.httpBody
                if data == nil, let stream = request.httpBodyStream {
                    data = Self.drain(stream)
                }
                let object = data.flatMap {
                    try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
                } ?? [:]
                lock.withLock { sent = object }
            }

            func reply() -> String {
                let sent = lock.withLock { self.sent }
                var user: [String: Any] = [
                    "id": 1, "email": "john.doe@firm.com", "phone": "+919876543210",
                    "suspended": false, "needsPlan": false,
                ]
                for key in ["name", "avatar", "title", "organization"] {
                    user[key] = sent[key] ?? NSNull()
                }
                let body: [String: Any] = ["success": true, "user": user]
                guard let data = try? JSONSerialization.data(withJSONObject: body) else {
                    return #"{"success":false}"#
                }
                return String(decoding: data, as: UTF8.self)
            }

            private static func drain(_ stream: InputStream) -> Data {
                stream.open()
                defer { stream.close() }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let read = stream.read(&buffer, maxLength: buffer.count)
                    if read <= 0 { break }
                    data.append(contentsOf: buffer[0..<read])
                }
                return data
            }
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
