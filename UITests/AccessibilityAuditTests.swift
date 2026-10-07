import UIKit
import XCTest

/// Xcode's accessibility audit, run over the main screens — on an iPhone and on an iPad, as every
/// UI test here is — and the main tabs drawn at the largest text size there is.
///
/// `performAccessibilityAudit()` asks the system what the screen it is looking at would mean to
/// someone using VoiceOver, a large text size or a less steady hand: text too faint for its
/// background, a control too small to hit, an element with nothing to say, a label cut short,
/// type that does not grow with the reader's setting. `PaletteTests` in the core measures the
/// colours the app is built from; this measures what reached the screen, which is where a
/// missing label, a fixed frame or a colour from outside the palette shows up.
///
/// Every issue fails, except the few that are not this app's to fix. Each of those is a `Waiver`
/// with its reason written beside it, and anything the waivers do not describe is a finding. A
/// failure names the screen, the kind of issue, the element and where it is, so it can be acted
/// on from the CI log alone; a screenshot of the screen is attached beside it.
///
/// The screens are grouped into a few tests rather than one each, because each test signs in
/// afresh — and each carries on past a failed audit, so one run reports every screen's findings
/// rather than the first screen's. The main tabs are the exception, a test each: see "The tabs".
final class AccessibilityAuditTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // A screen whose audit fails records its findings and the walk goes on to the next. A
        // screen that cannot be reached is a failure of its own, and whatever lies beyond it is
        // skipped rather than tapped at blindly: each step checks before it goes on.
        continueAfterFailure = true
    }

    // MARK: - Signing in

    /// The disclaimer gate, then every step of signing in, in the order a new person meets them:
    /// sign in, create an account, the one-time code, and the first-sign-in role question.
    func testTheSignInScreensPassTheAudit() {
        let app = launch("-UITestDisclaimer", "-UITestRoleWelcome")

        let acknowledge = app.buttons["I understand"]
        guard reached(acknowledge, "the disclaimer gate") else { return }
        audit("disclaimer", in: app)
        acknowledge.tap()

        guard reached(app.textFields["Email"], "the sign-in screen") else { return }
        audit("sign-in", in: app)

        app.buttons["Create an account"].tap()
        guard reached(app.textFields["Full name"], "the create-account step") else { return }
        audit("create-account", in: app)
        app.buttons["Sign in instead"].tap()

        let email = app.textFields["Email"]
        guard reached(email, "the sign-in screen, again") else { return }
        email.focusForTyping()
        email.typeText("john.doe@firm.com")
        app.buttons["Sign in with an email code"].tap()

        let code = app.textFields["Sign-in code"]
        guard reached(code, "the code step") else { return }
        audit("enter-code", in: app)
        code.focusForTyping()
        code.typeText("123456")

        let litigator = app.buttons["role-litigator"]
        guard reached(litigator, "the first-sign-in role question") else { return }
        audit("role-welcome", in: app)
        litigator.tap()
        app.buttons["Continue"].tap()
        XCTAssertTrue(app.tab("Home").waitForExistence(timeout: 10), "choosing a role led nowhere")
    }

    // MARK: - The tabs

    // Each tab in a test of its own, in each theme. They were one walk, and on a CI iPad the Home
    // tab's Dynamic Type audit ran out of time and left the app answering nothing, so the four
    // tabs after it went unaudited. Apart, a tab whose audit cannot finish costs only its own
    // result. The dark theme is the app's default; the light palette is a different set of
    // colour pairs, so a colour from outside it can pass on dark and fail there.

    func testTheHomeTabPassesTheAudit() { auditTab("Home") }
    func testTheCasesTabPassesTheAudit() { auditTab("Cases") }
    /// The chat list, and a conversation opened from it.
    func testTheChatTabPassesTheAudit() { auditTab("Chat") }
    func testTheCalendarTabPassesTheAudit() { auditTab("Calendar") }
    func testTheMoreTabPassesTheAudit() { auditTab("More") }

    func testTheSignInScreenPassesTheAuditInLight() {
        let app = launch("-UITestLight")
        guard reached(app.textFields["Email"], "the sign-in screen") else { return }
        audit("light-sign-in", in: app)
    }

    func testTheHomeTabPassesTheAuditInLight() { auditTab("Home", light: true) }
    func testTheCasesTabPassesTheAuditInLight() { auditTab("Cases", light: true) }
    func testTheChatTabPassesTheAuditInLight() { auditTab("Chat", light: true) }
    func testTheCalendarTabPassesTheAuditInLight() { auditTab("Calendar", light: true) }
    func testTheMoreTabPassesTheAuditInLight() { auditTab("More", light: true) }

    private func auditTab(_ tab: String, light: Bool = false) {
        let app = light ? launch("-UITestLight") : launch()
        guard signIn(app) else { return }
        let theme = light ? "light-" : ""
        // Each tab's title, and something its stub data puts on screen once it has loaded — so
        // the audit sees the screen a person sees, not its spinner.
        let landmarks: [String: (title: String, loaded: XCUIElement)] = [
            "Home": ("Home", app.descendants(matching: .any).matching(
                NSPredicate(format: "label BEGINSWITH %@", "Item 7, Court 12")).firstMatch),
            "Cases": ("Cases", app.navigationBars["Cases"]),
            "Chat": ("Emperor", app.stubConversationRow),
            "Calendar": ("Calendar", app.buttons["calendar-listing-case1"]),
            "More": ("More", app.buttons["Settings"]),
        ]
        guard let landmark = landmarks[tab] else {
            XCTFail("there is no tab named \(tab)")
            return
        }
        let button = app.tab(tab)
        guard reached(button, "the \(tab) tab") else { return }
        button.tap()
        _ = app.navigationBars[landmark.title].waitForExistence(timeout: 10)
        _ = landmark.loaded.waitForExistence(timeout: 10)
        audit(theme + tab.lowercased(), in: app)

        if tab == "Chat" {
            // A conversation: the stub's stored answer, its work log collapsed above it.
            let conversation = app.stubConversationRow
            guard reached(conversation, "the stored conversation") else { return }
            conversation.tap()
            _ = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Worked"))
                .firstMatch.waitForExistence(timeout: 10)
            audit(theme + "conversation", in: app)
        }
    }

    // MARK: - What More opens

    /// Each screen More presents, audited as a sheet over More — the Library, the Corporate
    /// Calendar, the tools and one tool's form, OCR, Translate and the file tools.
    func testTheScreensMoreOpensPassTheAudit() {
        let app = launch()
        guard signIn(app), openMore(app) else { return }

        if let bar = present("Library", titled: "Library", from: app) {
            audit("library", in: app, sheet: bar)
            close("Library", in: app)
        }

        if let bar = present("Corporate Calendar", titled: "Corporate Calendar", from: app) {
            _ = app.staticTexts["GSTR-1"].waitForExistence(timeout: 10)
            audit("corporate-calendar", in: app, sheet: bar)
            close("Corporate Calendar", in: app)
        }

        if let bar = present("All tools", titled: "Tools", from: app) {
            audit("tools", in: app, sheet: bar)
            // One tool's form. `firstMatch`: on an iPad the name can be on screen twice.
            let tool = app.staticTexts["Devil's Advocate"].firstMatch
            if reached(tool, "a tool in the list") {
                tool.tap()
                let form = app.navigationBars["Devil's Advocate"]
                if reached(form, "the tool's form") {
                    _ = app.buttons["Run"].firstMatch.waitForExistence(timeout: 10)
                    audit("tool-form", in: app, sheet: form)
                    goBack(from: form, named: "the tool's form", to: bar)
                }
            }
            // The list is longer than the sheet on both devices. Its later sections are audited
            // where a person scrolls them to, each brought up under the sheet's bar.
            for (header, screen, what) in [
                ("tools-header-analysis", "tools-analysis", "the Analysis tools"),
                ("tools-header-registry", "tools-registry", "the full registry"),
            ] {
                let heading = app.descendants(matching: .any)[header].firstMatch
                if let why = bringUnderTheBar(heading, of: bar, titled: "Tools", in: app) {
                    XCTFail("could not bring \(what) up under the bar — \(why) — so it was not audited")
                    continue
                }
                audit(screen, in: app, sheet: bar)
            }
            close("Tools", in: app)
        }

        if let bar = present("OCR", titled: "OCR", from: app) {
            _ = app.segmentedControls.firstMatch.waitForExistence(timeout: 10)
            audit("ocr", in: app, sheet: bar)
            close("OCR", in: app)
        }

        if let bar = present("Translate", titled: "Translate", from: app) {
            _ = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", "Bakshi Order"))
                .firstMatch.waitForExistence(timeout: 10)
            audit("translate", in: app, sheet: bar)
            close("Translate", in: app)
        }

        if let bar = present("File tools", titled: "File tools", from: app) {
            _ = app.buttons["tool-split"].waitForExistence(timeout: 10)
            audit("file-tools", in: app, sheet: bar)
            close("File tools", in: app)
        }
    }

    /// Settings, and what it holds below the fold or pushes: the role picker; Notifications — off,
    /// as a fresh install finds it, and on, with its reminders showing; Edit profile; and the
    /// Security and Storage sections, each brought up under the sheet's bar and audited there.
    func testSettingsAndItsScreensPassTheAudit() {
        let app = launch()
        guard signIn(app), openMore(app) else { return }
        guard let settings = present("Settings", titled: "Settings", from: app) else { return }
        _ = app.buttons["Role selector"].firstMatch.waitForExistence(timeout: 10)
        audit("settings", in: app, sheet: settings)

        let selector = app.buttons["Role selector"].firstMatch
        if reached(selector, "the role selector") {
            selector.tap()
            let picker = app.navigationBars["Switch role"]
            if reached(picker, "the role picker") {
                audit("role-picker", in: app, sheet: picker)
                // Back, not a row: a row would change the role the other tests expect.
                goBack(from: picker, named: "the role picker", to: settings)
            }
        }

        let row = app.buttons["notifications-settings"].firstMatch
        if reached(row, "the Notifications row") {
            scrollUntilHittable(row, in: app)
            row.tap()
            let notifications = app.navigationBars["Notifications"]
            if reached(notifications, "the Notifications screen") {
                let allow = app.switches["notifications-allow"].firstMatch
                _ = allow.waitForExistence(timeout: 10)
                audit("notification-settings", in: app, sheet: notifications)
                if allow.exists {
                    turnOn(allow)
                    if app.switches["notifications-briefing"].firstMatch
                        .waitForExistence(timeout: 10) {
                        audit("notification-settings-on", in: app, sheet: notifications)
                    }
                }
                goBack(from: notifications, named: "Notifications", to: settings)
            }
        }

        // Edit profile — the form as the account fills it. Left by Back, so nothing is saved.
        let profile = app.buttons["edit-profile"].firstMatch
        if reached(profile, "the Edit profile row") {
            scrollUntilHittable(profile, in: app)
            profile.tap()
            let form = app.navigationBars["Edit profile"]
            if reached(form, "the Edit profile screen") {
                _ = app.textFields["profile-name"].firstMatch.waitForExistence(timeout: 10)
                audit("edit-profile", in: app, sheet: form)
                goBack(from: form, named: "Edit profile", to: settings)
            }
        }

        // The app lock's section, then Storage — sections of Settings itself, so each is brought
        // up under the sheet's bar and audited as it then stands (`bringUnderTheBar`).
        _ = settings.waitForExistence(timeout: 10)
        for (header, anchor, screen, what) in [
            ("settings-header-security", "app-lock-toggle", "settings-security",
             "the Security section"),
            // The size, not "Clear offline copies": that is offered only when something is kept.
            ("settings-header-storage", "offline-storage-size", "settings-storage",
             "the Storage section"),
        ] {
            let heading = app.descendants(matching: .any)[header].firstMatch
            if let why = bringUnderTheBar(heading, of: settings, titled: "Settings", in: app) {
                XCTFail("could not bring \(what) up under the bar — \(why) — so it was not audited")
                continue
            }
            if reached(app.descendants(matching: .any)[anchor].firstMatch, what) {
                audit(screen, in: app, sheet: settings)
            }
        }

        close("Settings", in: app)
    }

    // MARK: - The largest text size

    /// Launched at the largest accessibility text size there is, the app signs in and draws each
    /// main tab without failing — and photographs each, as `a11y-xxxl-<screen>`, so the layouts
    /// can be looked at beside the screenshot tour's. Nothing here judges the pictures; that is
    /// what looking at them is for.
    func testTheMainTabsSurviveTheLargestTextSize() {
        let app = launch(
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL")
        guard reached(app.textFields["Email"], "the sign-in screen") else { return }
        shoot("sign-in", app)
        guard signIn(app) else {
            shoot("sign-in-failed", app)
            return
        }

        for (tab, title) in [
            ("Home", "Home"), ("Cases", "Cases"), ("Chat", "Emperor"),
            ("Calendar", "Calendar"), ("More", "More"),
        ] {
            let button = app.tab(tab)
            guard reached(button, "the \(tab) tab") else { continue }
            button.tap()
            _ = app.navigationBars[title].waitForExistence(timeout: 10)
            shoot(tab.lowercased(), app)
            XCTAssertEqual(
                app.state, .runningForeground, "the app died on \(tab) at the largest text size")
        }

        // The Library: a sheet with a search bar under a large title, whose text-size audit could
        // not finish on an iPad. Drawn here at the largest size, so a screen that stops answering
        // there shows as that, and not only as an audit that ran out of time.
        if present("Library", titled: "Library", from: app) != nil {
            shoot("library", app)
            XCTAssertEqual(app.state, .runningForeground)
            close("Library", in: app)
        }

        // One of the sheets, too: Settings carries the most kinds of row.
        if present("Settings", titled: "Settings", from: app) != nil {
            shoot("settings", app)
            XCTAssertEqual(app.state, .runningForeground)
            close("Settings", in: app)
        }
    }

    // MARK: - Getting around

    private func launch(_ extraArguments: String...) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestMode"] + extraArguments
        app.launch()
        return app
    }

    /// Signs in through the real login screen, as `EmperorUITests` does. Each control is scrolled
    /// to first: at the largest text size the button starts below the fold.
    private func signIn(_ app: XCUIApplication) -> Bool {
        let email = app.textFields["Email"]
        guard reached(email, "the sign-in screen") else { return false }
        scrollUntilHittable(email, in: app)
        email.focusForTyping()
        email.typeText("john.doe@firm.com")

        let password = app.secureTextFields["Password"]
        scrollUntilHittable(password, in: app)
        password.focusForTyping()
        password.typeText("hunter2")

        let button = app.buttons["Sign in"].firstMatch
        scrollUntilHittable(button, in: app)
        button.tap()
        return reached(app.tab("Home"), "Home, after signing in")
    }

    private func openMore(_ app: XCUIApplication) -> Bool {
        let more = app.tab("More")
        guard reached(more, "the More tab") else { return false }
        more.tap()
        return reached(app.navigationBars["More"], "the More screen")
    }

    /// Opens a row of More and returns the navigation bar of the sheet it presents, or `nil` —
    /// having said so — when the row or the sheet is not there.
    private func present(
        _ row: String, titled title: String, from app: XCUIApplication
    ) -> XCUIElement? {
        let button = app.buttons[row].firstMatch
        // Scrolled to before it is looked for: at the largest text size the lower rows are
        // below the fold, and a list builds only the rows it is showing.
        scrollUntilHittable(button, in: app)
        guard reached(button, "the \(row) row in More") else { return nil }
        button.tap()
        let bar = app.navigationBars[title]
        return reached(bar, "the \(title) screen") ? bar : nil
    }

    /// Closes a sheet from its own Done, and waits until it has gone — More's bar is there behind
    /// a sheet the whole time, so its presence proves nothing.
    private func close(_ title: String, in app: XCUIApplication) {
        let done = app.navigationBars[title].buttons["Done"]
        if done.waitForExistence(timeout: 5) { done.tap() } else { app.swipeDown() }
        var polls = 0
        while app.navigationBars[title].exists && polls < 40 {
            Thread.sleep(forTimeInterval: 0.25)
            polls += 1
        }
    }

    /// Waits for an element, and records a failure naming what was expected when it never comes.
    private func reached(_ element: XCUIElement, _ what: String, timeout: TimeInterval = 10) -> Bool {
        if element.waitForExistence(timeout: timeout) { return true }
        XCTFail("could not reach \(what), so it was not audited")
        return false
    }

    /// Swipes until an element lower on the screen can be tapped — a list builds only the rows it
    /// shows, and on a phone, or at a large text size, they start below the fold.
    private func scrollUntilHittable(_ element: XCUIElement, in app: XCUIApplication) {
        var swipes = 0
        while !(element.exists && element.isHittable) && swipes < 6 {
            app.swipeUp()
            swipes += 1
        }
    }

    /// Leaves a pushed screen by its Back button, and waits until that screen has gone and the one
    /// under it is showing — tapping again when a tap was not taken. On a CI iPad one Back, made
    /// as an audit finished, left Edit profile where it was, and every section of Settings after
    /// it went unreached.
    @discardableResult
    private func goBack(
        from bar: XCUIElement, named name: String, to destination: XCUIElement
    ) -> Bool {
        for attempt in 0..<3 {
            guard bar.exists else { break }
            // A moment for the screen to settle after an audit — a second before the first tap,
            // more before another.
            Thread.sleep(forTimeInterval: attempt == 0 ? 1 : 3)
            // iOS 26 names the Back button; elsewhere it is the bar's first button.
            let named = bar.buttons["BackButton"]
            let back = named.exists ? named : bar.buttons.element(boundBy: 0)
            // Tapped again only while it can still be: a bar caught leaving holds a button that
            // is no longer there to tap.
            guard back.exists, attempt == 0 || back.isHittable else { break }
            back.tap()
            var polls = 0
            while bar.exists && polls < 20 {
                Thread.sleep(forTimeInterval: 0.25)
                polls += 1
            }
        }
        if !bar.exists && destination.waitForExistence(timeout: 5) { return true }
        XCTFail("could not go back from \(name)")
        return false
    }

    /// Brings a section of a sheet's list up under the sheet's bar — its header just below the
    /// bar, with clear space between — as far as the list will scroll, and waits until the list
    /// is still. Whether the header is then on screen below the bar.
    ///
    /// Not by swiping. A swipe leaves the list coasting, and the audit's contrast check, which
    /// runs first, then reads rows sliding under the bar that its later checks no longer find
    /// there — "Edit profile" measured at 1.47:1 under the bar while Security was being audited.
    /// A drag that holds before it lets go leaves nothing to coast, and the header's place is
    /// read until it stops changing.
    ///
    /// Then no row is left straddling the bar's lower edge: a row half under the bar is neither
    /// on screen nor off it, and the audit reads it as neither. Such a row is moved up until it is
    /// wholly behind the bar. Where the list ends first — the last sections of Settings on a
    /// phone — the header stays where the end of the list leaves it.
    ///
    /// - Returns: `nil` once the header is in place; otherwise what stopped it, for the failure.
    private func bringUnderTheBar(
        _ header: XCUIElement, of sheet: XCUIElement, titled title: String,
        in app: XCUIApplication
    ) -> String? {
        guard sheet.exists else { return "the sheet had gone" }
        let bar = sheet.frame
        let window = app.windows.firstMatch.frame
        // Where the drags run: across the middle of the sheet, clear of its bar, and clear of
        // the home indicator and a sheet's own foot.
        let track = DragTrack(top: bar.maxY + 16, bottom: window.maxY - 120, x: bar.midX)
        // The header's place: below the bar and the strip under it that iOS 26 fades.
        let place = bar.maxY + 28

        // Found first. A list builds only the rows near what it shows, so it is paged down to.
        var pages = 0
        while top(of: header) == nil && pages < 10 {
            drag(app, by: -(track.bottom - track.top) * 0.8, along: track)
            pages += 1
        }
        guard top(of: header) != nil else { return "its header was not found in ten pages" }
        waitUntilStill(header)

        for _ in 0..<8 {
            guard let before = top(of: header) else { return "its header went while it was moved" }
            let off = before - place
            if abs(off) <= 6 { break }
            drag(app, by: -off, along: track)
            waitUntilStill(header)
            // The list goes no further this way.
            if let after = top(of: header), abs(after - before) < 2 { break }
        }

        let straddling = rowFrames(onScreenTitled: title, in: app).first { row in
            row.minX >= bar.minX - 1 && row.maxX <= bar.maxX + 1
                && row.minY < bar.maxY - 1 && row.maxY > bar.maxY + 1
        }
        if let straddling {
            drag(app, by: -(straddling.maxY - bar.maxY + 2), along: track)
            waitUntilStill(header)
        }
        guard let settled = top(of: header) else { return "its header went while it was moved" }
        return settled >= bar.maxY
            ? nil
            : String(format: "its header ended at %.0f, above the bar's foot at %.0f", settled, bar.maxY)
    }

    /// Where a drag runs on screen, in points.
    private struct DragTrack {
        let top: CGFloat
        let bottom: CGFloat
        let x: CGFloat
    }

    /// Moves a list's content by `distance` points — up when negative — with a press, a slow drag
    /// and a hold before letting go, so nothing is left to coast.
    ///
    /// A short move is made as two long ones, out and back: a drag of a few points is not yet a
    /// scroll, and lifting the finger then could select the row it started on.
    private func drag(_ app: XCUIApplication, by distance: CGFloat, along track: DragTrack) {
        let reach = track.bottom - track.top
        let travel = min(reach, abs(distance))
        guard travel > 1, reach > 80 else { return }
        let direction: CGFloat = distance < 0 ? -1 : 1
        if travel < 40 {
            stroke(app, by: -direction * 40, along: track)
            stroke(app, by: direction * (travel + 40), along: track)
        } else {
            stroke(app, by: direction * travel, along: track)
        }
    }

    /// One press, drag and hold, of `distance` points along the track — up when negative.
    private func stroke(_ app: XCUIApplication, by distance: CGFloat, along track: DragTrack) {
        let travel = min(track.bottom - track.top, abs(distance))
        let from = distance < 0 ? track.top + travel : track.top
        let to = distance < 0 ? track.top : track.top + travel
        let origin = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        origin.withOffset(CGVector(dx: track.x, dy: from)).press(
            forDuration: 0.05,
            thenDragTo: origin.withOffset(CGVector(dx: track.x, dy: to)),
            withVelocity: .slow,
            thenHoldForDuration: 0.4)
    }

    /// The top of an element on screen, or `nil` when it is not there — read from a snapshot, so
    /// an element that goes between two looks is an answer rather than a failed test. The
    /// snapshot stays on the main actor, where XCTest keeps it; only the number comes out.
    private func top(of element: XCUIElement) -> CGFloat? {
        MainActor.assumeIsolated { (try? element.snapshot())?.frame.minY }
    }

    /// Waits until an element has stopped moving — in the same place on two looks a quarter of a
    /// second apart — or five seconds have passed.
    private func waitUntilStill(_ element: XCUIElement) {
        var last = top(of: element)
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.25)
            let now = top(of: element)
            if let now, let last, abs(now - last) < 0.5 { return }
            last = now
        }
    }

    /// The frames of the rows of the list on the screen a navigation bar heads — that screen's own,
    /// not a screen's behind it — from one snapshot of the app, walked on the main actor where
    /// XCTest keeps it. Only the frames come out.
    private func rowFrames(onScreenTitled title: String, in app: XCUIApplication) -> [CGRect] {
        MainActor.assumeIsolated { () -> [CGRect] in
            Self.rowFramesOnMain(onScreenTitled: title, in: app)
        }
    }

    @MainActor
    private static func rowFramesOnMain(
        onScreenTitled title: String, in app: XCUIApplication
    ) -> [CGRect] {
        guard let root = try? app.snapshot() else { return [] }
        // The bar's ancestors, the nearest last.
        var path: [any XCUIElementSnapshot] = []
        func find(_ node: any XCUIElementSnapshot) -> Bool {
            if node.elementType == .navigationBar && node.identifier == title { return true }
            path.append(node)
            for child in node.children {
                if find(child) { return true }
            }
            path.removeLast()
            return false
        }
        guard find(root) else { return [] }
        // The bar's own screen: the nearest of them that holds rows.
        for ancestor in path.reversed() {
            let rows = cellFrames(in: ancestor)
            if !rows.isEmpty { return rows }
        }
        return []
    }

    /// The frames of everything inside a snapshot, at every depth.
    @MainActor
    private static func descendantFrames(of node: any XCUIElementSnapshot) -> [CGRect] {
        var frames: [CGRect] = []
        for child in node.children {
            frames.append(child.frame)
            frames += descendantFrames(of: child)
        }
        return frames
    }

    /// For a finding the audit could not name: every text and button on screen that an edge cuts
    /// or hides — the window's, the list it scrolls in, a navigation bar's — with its frame, so
    /// the CI log's attachment says which ones the finding can be, rather than nothing at all.
    private static func edgeReport(of app: XCUIApplication) -> String {
        MainActor.assumeIsolated { () -> String in
            guard let root = try? app.snapshot() else { return "The app could not be read." }
            var bars: [CGRect] = []
            var lines: [String] = []
            func findBars(_ node: any XCUIElementSnapshot) {
                if node.elementType == .navigationBar { bars.append(node.frame) }
                for child in node.children { findBars(child) }
            }
            findBars(root)
            let window = root.frame
            for bar in bars { lines.append("navigation bar \(describe(bar))") }

            func walk(_ node: any XCUIElementSnapshot, list: CGRect?, inBar: Bool) {
                var list = list
                if [.collectionView, .table, .scrollView].contains(node.elementType) {
                    list = node.frame
                    lines.append("list \(describe(node.frame))")
                }
                let inBar = inBar || node.elementType == .navigationBar
                if node.elementType == .staticText || node.elementType == .button {
                    var notes: [String] = []
                    if node.frame.isEmpty { notes.append("no size") }
                    if !window.contains(node.frame) { notes.append("past the window's edge") }
                    if let list, !inBar, !list.contains(node.frame) {
                        notes.append(list.intersects(node.frame) ? "cut by its list's edge" : "outside its list")
                    }
                    if !inBar, bars.contains(where: { $0.intersects(node.frame) }) {
                        notes.append(bars.contains { $0.contains(node.frame) }
                            ? "behind a bar" : "across a bar's edge")
                    }
                    if !notes.isEmpty {
                        let kind = node.elementType == .button ? "button" : "text"
                        lines.append(
                            "\(kind) “\(node.label.prefix(60))” \(describe(node.frame)): "
                                + notes.joined(separator: ", "))
                    }
                }
                for child in node.children { walk(child, list: list, inBar: inBar) }
            }
            walk(root, list: nil, inBar: false)
            return "Window \(describe(window)).\n" + lines.joined(separator: "\n")
        }
    }

    private static func describe(_ frame: CGRect) -> String {
        String(format: "(%.0f, %.0f) %.0f×%.0f", frame.minX, frame.minY, frame.width, frame.height)
    }

    @MainActor
    private static func cellFrames(in node: any XCUIElementSnapshot) -> [CGRect] {
        var frames = node.elementType == .cell ? [node.frame] : []
        for child in node.children {
            frames += cellFrames(in: child)
        }
        return frames
    }

    /// Turns a switch on. The switch is a child of the row on recent iOS; where it is not, it is
    /// drawn at the row's trailing edge — the row's middle is its label, which does not turn it.
    private func turnOn(_ toggle: XCUIElement) {
        guard (toggle.value as? String) != "1" else { return }
        let inner = toggle.switches.firstMatch
        if inner.exists {
            inner.tap()
        } else {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        }
        var polls = 0
        while (toggle.value as? String) != "1" && polls < 20 {
            Thread.sleep(forTimeInterval: 0.25)
            polls += 1
        }
    }

    /// A screenshot kept with the run, named so the CI export files it beside the tour's.
    private func shoot(_ screen: String, _ app: XCUIApplication) {
        Thread.sleep(forTimeInterval: 0.8)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "a11y-xxxl-\(screen)"
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: - The audit

    /// Audits what is on screen now, and fails once for every issue no `Waiver` covers.
    ///
    /// The audit's own report is replaced with one written here — the issue handler takes every
    /// issue — because the system's names the element but not the screen, and a run audits twenty.
    /// The one exception is an issue the audit ties to no element this test can see: that one is
    /// also left to XCTest to record, because its record carries a picture of the element, and
    /// without one there is nothing to go on.
    ///
    /// The checks run in three passes rather than one (`AuditPass`): contrast alone first, on a
    /// still screen, before the text-size checks start resizing things behind the scenes; then the
    /// checks about controls; then the ones about text size. A long screen — a whole answer, with
    /// its table and references — could not finish every check inside the audit's own time limit
    /// at once. A pass that runs out of time is tried again, one kind of check at a time.
    ///
    /// - Parameter sheet: the navigation bar of the sheet being audited, when the screen is
    ///   presented over another. What lies wholly outside the sheet is the screen it was opened
    ///   from, dimmed, which has its own audit.
    private func audit(
        _ screen: String, in app: XCUIApplication, sheet: XCUIElement? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        // Let a push, a load or a keyboard settle: half a transition is not what a person sees.
        Thread.sleep(forTimeInterval: 1)
        let context = layout(of: app, sheet: sheet)

        var findings: [AuditFinding] = []
        var pixels: ScreenPixels?
        for pass in AuditPass.allCases {
            for outcome in Self.run(pass.types, on: app, in: context) {
                switch outcome {
                case .ran(let found):
                    findings += found
                case .couldNotRun(let types, let reason):
                    XCTFail(
                        "[\(screen)] the \(AuditFinding.name(of: types)) audit could not run, "
                            + "even retried: " + reason,
                        file: file, line: line)
                    // Time for whatever the check left running to finish before the walk asks the
                    // app anything else. Only a wait — see `persist`.
                    Thread.sleep(forTimeInterval: 10)
                }
            }
            if pass == .contrast {
                // The screen as the contrast check saw it, to measure what it flagged.
                pixels = ScreenPixels(app.screenshot(), pointsWide: context.window.width)
            }
        }

        var waived: [String] = []
        var failures = 0
        var unnamed = 0
        for var finding in findings {
            if finding.kind.contains(.contrast), let element = finding.element, let pixels,
               let box = Waiver.measurableBox(of: element, in: context) {
                finding.measuredContrast = pixels.contrast(in: box)
            }
            if let waiver = Waiver.allCases.first(where: { $0.applies(to: finding, in: context) }) {
                waived.append("\(finding.report)\n    waived — \(waiver.reason(for: finding))")
            } else {
                failures += 1
                if finding.element == nil { unnamed += 1 }
                XCTFail("[\(screen)] \(finding.report)", file: file, line: line)
            }
        }

        if failures > 0 {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "a11y-audit-\(screen)"
            shot.lifetime = .keepAlways
            add(shot)
        }
        if unnamed > 0 {
            let edges = XCTAttachment(string: Self.edgeReport(of: app))
            edges.name = "a11y-audit-\(screen)-edges"
            edges.lifetime = .keepAlways
            add(edges)
        }
        // What was set aside, and why, kept with the run — a waiver that starts swallowing real
        // findings should be visible, not silent.
        if !waived.isEmpty {
            let note = XCTAttachment(string: waived.joined(separator: "\n\n"))
            note.name = "a11y-audit-\(screen)-waived"
            note.lifetime = .keepAlways
            add(note)
        }
    }

    /// Runs one pass, and when it cannot finish in time, settles and runs its checks one by one.
    private static func run(
        _ types: XCUIAccessibilityAuditType, on app: XCUIApplication, in context: AuditLayout
    ) -> [AuditOutcome] {
        let whole = perform(types, on: app, in: context)
        guard case .couldNotRun = whole else { return [whole] }
        let single = AuditPass.kinds.filter { types.contains($0) }
        guard single.count > 1 else {
            return [persist(types, on: app, in: context)]
        }
        return single.map { kind in persist(kind, on: app, in: context) }
    }

    /// One kind of check, tried until it finishes or has had three goes.
    ///
    /// On a CI iPad the text-size checks can run past the audit's own time limit on an ordinary
    /// screen — Home, Notifications with its reminders on — and the app can still be busy with
    /// the check that gave up when the next one starts. So each try waits longer than the last.
    /// The waits are only waits: nothing here asks the app anything in between. Asking an app
    /// that busy — even for the window's frame — is a question it cannot answer in time, and an
    /// unanswered question ends the whole test, every screen after this one with it. A check
    /// that cannot finish after three goes is still a failure — it is reported, not skipped.
    private static func persist(
        _ types: XCUIAccessibilityAuditType, on app: XCUIApplication, in context: AuditLayout
    ) -> AuditOutcome {
        var outcome = AuditOutcome.couldNotRun(types, "not tried")
        for settle in [2.0, 5.0, 10.0] {
            Thread.sleep(forTimeInterval: settle)
            outcome = perform(types, on: app, in: context)
            guard case .couldNotRun = outcome else { return outcome }
        }
        return outcome
    }

    /// One call to the audit, on the main actor, where the audit, its handler and every element
    /// it names live — and everything that touches them stays inside. Gathering into an array
    /// declared out here would send that array across actors, which Swift 6 refuses to compile;
    /// so the issues are turned into plain `AuditFinding`s in the block, and only those (all
    /// `Sendable`) come out. UI tests run on the main thread, so asserting the isolation is true,
    /// not a cast. Static, so the block captures no test case.
    private static func perform(
        _ types: XCUIAccessibilityAuditType, on app: XCUIApplication, in context: AuditLayout
    ) -> AuditOutcome {
        MainActor.assumeIsolated {
            var gathered: [AuditFinding] = []
            do {
                try app.performAccessibilityAudit(for: types) { issue in
                    let element = Self.facts(
                        about: issue.element, withWords: issue.auditType.contains(.contrast))
                    var finding = AuditFinding(
                        kind: issue.auditType,
                        summary: issue.compactDescription,
                        detail: issue.detailedDescription,
                        element: element)
                    // An element the audit did name, but that could not be read: what XCTest
                    // calls it is kept, so the report says which element rather than none.
                    if element == nil, let named = issue.element {
                        finding.unread = String(describing: named)
                    }
                    gathered.append(finding)
                    // Handled here (`true`) unless the audit named no element and no waiver
                    // covers it: then XCTest records it too, with its picture of the element.
                    let unnamed = finding.element == nil
                        && !Waiver.allCases.contains { $0.applies(to: finding, in: context) }
                    return !unnamed
                }
            } catch {
                return .couldNotRun(types, String(describing: error))
            }
            return .ran(gathered)
        }
    }

    /// The facts about an element the report and the waivers need, read once while it is there.
    ///
    /// From one snapshot of the element rather than a question per fact. Each question is a round
    /// trip to the app, made while the audit's own clock is running — six of them for every issue
    /// on a screen with twenty is most of a minute on a CI iPad — and a question the app is too
    /// busy to answer ends the test. A snapshot that cannot be taken is an element not read. The
    /// snapshot is read on the main actor, where XCTest keeps it, and only the plain facts come out.
    ///
    /// - Parameter withWords: for a button, also find its words — the first text inside it — so
    ///   a contrast finding can be measured on them rather than on the whole button, whose box
    ///   may hold an avatar or a tile as well.
    private static func facts(
        about element: XCUIElement?, withWords: Bool = false
    ) -> AuditFinding.Element? {
        guard let element else { return nil }
        return MainActor.assumeIsolated { () -> AuditFinding.Element? in
            guard let snapshot = try? element.snapshot() else { return nil }
            var words: CGRect?
            if withWords, snapshot.elementType == .button {
                words = firstText(in: snapshot)?.frame
            }
            return AuditFinding.Element(
                kind: snapshot.elementType,
                label: snapshot.label,
                identifier: snapshot.identifier,
                frame: snapshot.frame,
                isEnabled: snapshot.isEnabled,
                wordsFrame: words)
        }
    }

    /// The first text inside an element, in the order a query would find it.
    @MainActor
    private static func firstText(
        in snapshot: any XCUIElementSnapshot
    ) -> (any XCUIElementSnapshot)? {
        for child in snapshot.children {
            if child.elementType == .staticText { return child }
            if let inner = firstText(in: child) { return inner }
        }
        return nil
    }

    /// Where the system's own furniture is on screen as the audit runs.
    private func layout(of app: XCUIApplication, sheet: XCUIElement?) -> AuditLayout {
        let window = app.windows.firstMatch.frame
        let keyboard = app.keyboards.firstMatch
        var sheetFrame: CGRect?
        if let sheet, sheet.exists {
            // From the sheet's bar to the foot of the window, across the sheet's width — the whole
            // form sheet on an iPad, everything below the dimmed strip on an iPhone.
            let bar = sheet.frame
            sheetFrame = CGRect(
                x: bar.minX, y: bar.minY, width: bar.width, height: max(0, window.maxY - bar.minY))
        }
        // The tab bar, found by its own buttons rather than as a tab bar element: on iOS 26 the
        // element's frame is not the floating bar a person sees. On a phone the buttons sit along
        // the foot of the screen; on an iPad they are across the top, and there is no bar below.
        let tabButtons = AuditLayout.tabs.keys
            .map { app.tab($0) }
            .filter { $0.exists }
            .map { $0.frame }
        let bottomTabs = tabButtons.filter { $0.midY > window.midY }
        let bottomBarTop = sheetFrame == nil ? bottomTabs.map(\.minY).min() : nil
        let navigationBars = app.navigationBars.allElementsBoundByIndex
            .filter { $0.exists }
            .map { $0.frame }
        let sheetBar = sheet.flatMap { $0.exists ? $0.frame : nil }
        // Read from each bar's snapshot on the main actor, where XCTest keeps it; only frames
        // come out.
        let barItems = MainActor.assumeIsolated { () -> [CGRect] in
            app.navigationBars.allElementsBoundByIndex.flatMap { bar -> [CGRect] in
                guard let snapshot = try? bar.snapshot() else { return [] }
                return Self.descendantFrames(of: snapshot)
            }
        }
        return AuditLayout(
            window: window,
            keyboard: keyboard.exists ? keyboard.frame : nil,
            // Behind a sheet the tab bar is covered, and the sheet's own foot is the screen's.
            bottomBarTop: bottomBarTop,
            navigationBars: navigationBars,
            barItems: barItems,
            sheet: sheetFrame,
            sheetBar: sheetBar)
    }
}

// MARK: - Findings and waivers

/// Which checks run together. Contrast first and alone, then controls, then text size.
private enum AuditPass: CaseIterable {
    case contrast, controls, textSize

    var types: XCUIAccessibilityAuditType {
        switch self {
        case .contrast: return .contrast
        case .controls: return [.elementDetection, .sufficientElementDescription, .trait, .hitRegion]
        case .textSize: return [.dynamicType, .textClipped]
        }
    }

    /// Every kind of check, one at a time, for running a pass again in pieces.
    static let kinds: [XCUIAccessibilityAuditType] = [
        .contrast, .elementDetection, .sufficientElementDescription, .trait, .hitRegion,
        .dynamicType, .textClipped,
    ]
}

/// What one audit call came back with: its findings, or why it could not run. Plain values, so it
/// can leave the main-actor block the audit runs in.
private enum AuditOutcome: Sendable {
    case ran([AuditFinding])
    case couldNotRun(XCUIAccessibilityAuditType, String)
}

private struct AuditFinding: Sendable {
    struct Element: Sendable {
        let kind: XCUIElement.ElementType
        let label: String
        let identifier: String
        let frame: CGRect
        let isEnabled: Bool
        /// A button's words — the first text inside it — when they were looked for.
        var wordsFrame: CGRect? = nil
    }

    let kind: XCUIAccessibilityAuditType
    let summary: String
    let detail: String
    let element: Element?
    /// What XCTest calls an element the audit named but that could not be read — gone, or not
    /// answering, by the time it was asked about.
    var unread: String? = nil
    /// For a contrast finding, the ratio measured from the screen's own pixels inside the
    /// element's box — `ScreenPixels` — when the element is one that can be measured that way.
    var measuredContrast: Double? = nil

    /// "contrast — Contrast failed. <detail> Element: button "Done" (id "Done"), at (16, 54)
    /// 60×44." Everything needed to find it, on one line.
    var report: String {
        var parts = ["\(AuditFinding.name(of: kind)) — \(summary)"]
        if !detail.isEmpty, detail != summary { parts.append(detail) }
        parts.append("Element: \(elementDescription)")
        if let measuredContrast {
            parts.append(String(format: "Measured on screen: %.2f:1.", measuredContrast))
        }
        return parts.joined(separator: " ")
    }

    private var elementDescription: String {
        guard let element else {
            if let unread {
                return "one the audit named but that could not be read — \(unread)."
            }
            return "none named by the audit."
        }
        var words = AuditFinding.name(of: element.kind)
        if !element.label.isEmpty { words += " “\(element.label)”" }
        if !element.identifier.isEmpty, element.identifier != element.label {
            words += " (id “\(element.identifier)”)"
        }
        let frame = element.frame
        words += String(
            format: ", at (%.0f, %.0f) %.0f×%.0f", frame.minX, frame.minY, frame.width, frame.height)
        if !element.isEnabled { words += ", disabled" }
        return words + "."
    }

    static func name(of kind: XCUIAccessibilityAuditType) -> String {
        let known: [(XCUIAccessibilityAuditType, String)] = [
            (.contrast, "contrast"),
            (.elementDetection, "element detection"),
            (.hitRegion, "hit region"),
            (.sufficientElementDescription, "element description"),
            (.dynamicType, "Dynamic Type"),
            (.textClipped, "clipped text"),
            (.trait, "traits"),
        ]
        let names = known.filter { kind.contains($0.0) }.map { $0.1 }
        return names.isEmpty ? "audit type \(kind.rawValue)" : names.joined(separator: " + ")
    }

    static func name(of kind: XCUIElement.ElementType) -> String {
        switch kind {
        case .button: return "button"
        case .staticText: return "text"
        case .textField: return "text field"
        case .secureTextField: return "secure text field"
        case .searchField: return "search field"
        case .textView: return "text view"
        case .image: return "image"
        case .cell: return "cell"
        case .switch: return "switch"
        case .link: return "link"
        case .segmentedControl: return "segmented control"
        case .picker: return "picker"
        case .datePicker: return "date picker"
        case .slider: return "slider"
        case .progressIndicator: return "progress indicator"
        case .activityIndicator: return "activity indicator"
        case .navigationBar: return "navigation bar"
        case .tabBar: return "tab bar"
        case .toolbar: return "toolbar"
        case .menu: return "menu"
        case .menuItem: return "menu item"
        case .scrollView: return "scroll view"
        case .collectionView: return "collection view"
        case .table: return "table"
        case .key: return "keyboard key"
        case .keyboard: return "keyboard"
        case .other: return "element"
        default: return "element of type \(kind.rawValue)"
        }
    }
}


/// Where the system draws its own furniture while an audit runs.
private struct AuditLayout: Sendable {
    /// The tabs, by title, with the SF Symbol each carries as its identifier on iPad — see
    /// `Tabs.swift`.
    static let tabs = [
        "Home": "house", "Cases": "briefcase", "Chat": "bubble.left.and.bubble.right",
        "Calendar": "calendar", "More": "ellipsis.circle",
    ]

    let window: CGRect
    let keyboard: CGRect?
    /// The top of the tab bar along the foot of a phone's screen; `nil` on an iPad, whose tabs
    /// are across the top.
    let bottomBarTop: CGFloat?
    let navigationBars: [CGRect]
    /// The frames of the bars' own elements — titles, buttons and what is inside them — read from
    /// each bar's hierarchy. Content scrolled up behind a bar lies inside the bar's frame too; this
    /// is what tells the two apart.
    let barItems: [CGRect]
    /// The presented sheet's extent, when the screen audited is one.
    let sheet: CGRect?
    /// That sheet's own navigation bar, which its rows scroll up under.
    let sheetBar: CGRect?

    /// Whether an element is one of the tab bar's own buttons.
    func isTab(_ element: AuditFinding.Element) -> Bool {
        guard let symbol = Self.tabs[element.label] else { return false }
        if element.identifier == symbol { return true }
        guard let bottomBarTop else { return false }
        return element.frame.minY >= bottomBarTop - 8
    }

    /// Whether an element is inside a navigation bar — its title, or one of its buttons — rather
    /// than content scrolled up behind it.
    func isInANavigationBar(_ frame: CGRect) -> Bool {
        navigationBars.contains { $0.contains(frame) }
            && barItems.contains { $0.insetBy(dx: -1, dy: -1).contains(frame) }
    }

    /// Whether an element lies where iOS 26 fades the content at a bar's edge as it scrolls: under
    /// a navigation bar or within 24 points below it (the fade reaches past the bar's own frame —
    /// CI measured a sheet's row there at 1.27:1), or near the foot of the screen,
    /// just above and behind a phone's floating tab bar, or in the strip above an iPad's home
    /// indicator.
    func isAtTheScrollEdge(_ frame: CGRect) -> Bool {
        let topBars = navigationBars + [sheetBar].compactMap { $0 }
        let underATopBar = topBars.contains { bar in
            !bar.contains(frame)
                && frame.minY < bar.maxY + 24 && frame.maxY > bar.minY
                && frame.minX < bar.maxX && frame.maxX > bar.minX
        }
        // Scrolled wholly behind a bar: where the audit's own positioning puts a row rather than
        // leave it straddling the bar's edge. CI measured one there at 1.27:1.
        let behindATopBar = topBars.contains { $0.contains(frame) } && !isInANavigationBar(frame)
        if underATopBar || behindATopBar { return true }
        let fadeStarts = bottomBarTop.map { $0 - 24 } ?? (window.maxY - 34)
        return frame.maxY > fadeStarts
    }
}

/// The screen as the contrast check saw it, as pixels, to measure a flagged element's text
/// against what is actually behind it.
///
/// Inside the element's box, the commonest colour is its background, and the colour furthest from
/// that in luminance — among those that cover enough of the box to be strokes, not the soft edge
/// of a glyph — is its text. The ratio between the two is WCAG's, from the same formula
/// `PaletteColor.contrastRatio` uses in the core.
private struct ScreenPixels {
    private let width: Int
    private let height: Int
    /// Pixels per point.
    private let scale: CGFloat
    private let rgbx: [UInt8]

    init?(_ screenshot: XCUIScreenshot, pointsWide: CGFloat) {
        guard pointsWide > 0, let image = screenshot.image.cgImage else { return nil }
        let width = image.width
        let height = image.height
        var rgbx = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let drawn = rgbx.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.width = width
        self.height = height
        self.scale = CGFloat(width) / pointsWide
        self.rgbx = rgbx
    }

    /// The text-to-background ratio inside `frame`, in points; `nil` when the box is off the
    /// picture, and 1 when it holds a single colour.
    func contrast(in frame: CGRect) -> Double? {
        let x0 = max(0, Int((frame.minX * scale).rounded(.down)))
        let y0 = max(0, Int((frame.minY * scale).rounded(.down)))
        let x1 = min(width, Int((frame.maxX * scale).rounded(.up)))
        let y1 = min(height, Int((frame.maxY * scale).rounded(.up)))
        guard x1 > x0, y1 > y0 else { return nil }

        var counts: [UInt32: Int] = [:]
        for y in y0..<y1 {
            for x in x0..<x1 {
                let index = (y * width + x) * 4
                let colour = UInt32(rgbx[index]) << 16 | UInt32(rgbx[index + 1]) << 8
                    | UInt32(rgbx[index + 2])
                counts[colour, default: 0] += 1
            }
        }
        guard let background = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        let strokes = max(4, (x1 - x0) * (y1 - y0) / 200)
        let backgroundLuminance = Self.luminance(background)
        let distance = { (colour: UInt32) in abs(Self.luminance(colour) - backgroundLuminance) }
        guard let text = counts.filter({ $0.value >= strokes }).keys
            .max(by: { distance($0) < distance($1) })
        else { return 1 }
        let lighter = max(Self.luminance(text), backgroundLuminance)
        let darker = min(Self.luminance(text), backgroundLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// WCAG relative luminance of an sRGB colour packed as 0xRRGGBB.
    private static func luminance(_ colour: UInt32) -> Double {
        func channel(_ byte: UInt32) -> Double {
            let value = Double(byte) / 255
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(colour >> 16 & 0xFF)
            + 0.7152 * channel(colour >> 8 & 0xFF)
            + 0.0722 * channel(colour & 0xFF)
    }
}

/// An issue the audit raises that is not this app's to fix, and why.
///
/// Each one is something the system draws, a reading the audit cannot make where it is looking,
/// or a reading the screen itself contradicts — and each is drawn as tightly as the facts allow:
/// an element's kind, where it is, what the audit said. None is "this is hard". A new kind of
/// finding is fixed in the app, not added here, unless it is plainly one of these.
private enum Waiver: CaseIterable {
    case systemKeyboard
    case behindTheKeyboard
    case inactiveControl
    case measuredOnScreen
    case atTheScrollEdge
    case outsideTheSheet
    case tabTitles
    case barItems
    case brandFace
    case uikitLabelInTheBrandFace
    case inlineText
    case oneLineEntry
    case systemSearchField

    /// Where the screen's pixels can be measured for an element: a run of text, whose box is its
    /// glyphs; a button's own words, when they were found inside it; or a bar's button, whose box
    /// is its word on its glass. Never a whole row or card, whose box holds other things — a tile,
    /// an avatar — that would answer for the text.
    static func measurableBox(
        of element: AuditFinding.Element, in layout: AuditLayout
    ) -> CGRect? {
        if element.kind == .staticText { return element.frame }
        guard element.kind == .button else { return nil }
        if let words = element.wordsFrame { return words }
        return layout.isInANavigationBar(element.frame) ? element.frame : nil
    }

    func reason(for finding: AuditFinding) -> String {
        switch self {
        case .systemKeyboard:
            return "the system keyboard and its suggestions are Apple's, drawn in their own "
                + "process; nothing in this app styles a key."
        case .behindTheKeyboard:
            return "partly behind the system keyboard as it was audited, so it was measured "
                + "against the keys over it. Shown again once the keyboard goes."
        case .inactiveControl:
            return "a disabled control is dimmed on purpose, to read as unavailable, and WCAG 1.4.3 "
                + "exempts inactive controls from the contrast minimum."
        case .measuredOnScreen:
            let ratio = finding.measuredContrast.map { String(format: "%.2f", $0) } ?? "?"
            return "measured from the screen as the check left it: the text against what is behind "
                + "it is \(ratio):1, at or above WCAG's 4.5:1 — the audit's reading is not what "
                + "is on screen."
        case .atTheScrollEdge:
            return "where iOS 26 fades scrolling content into a bar's edge — part under a "
                + "navigation bar, or near the foot of the screen by the tab bar or home "
                + "indicator — so it is measured, and partly covered, by the system's fade. "
                + "Scrolled clear of the edge it is read as anywhere else."
        case .outsideTheSheet:
            return "wholly outside the visible part of the sheet being audited — the dimmed screen "
                + "it was opened from, or a row of the sheet scrolled out of its view. Neither is "
                + "text a person can read there."
        case .tabTitles:
            return "a tab's own title: UIKit's tab bar keeps its titles at one size by design and "
                + "offers the Large Content Viewer instead (press and hold a tab)."
        case .barItems:
            return "in a navigation bar: UIKit holds a bar's titles and buttons to a ceiling by "
                + "design and offers the Large Content Viewer instead (press and hold). The brand "
                + "titles are capped the same way (`BrandAppearance`)."
        case .brandFace:
            return "drawn in the brand face (Fredoka) through `Font.custom(_:size:relativeTo:)`, "
                + "which scales with Dynamic Type — `testTheMainTabsSurviveTheLargestTextSize` "
                + "photographs it at the largest size — but carries no text-style trait, and that "
                + "trait is what the audit reads; so it says 'partially'."
        case .uikitLabelInTheBrandFace:
            return "a label UIKit draws in the brand face — a bar's title or a picker's value — "
                + "whose font SwiftUI or `BrandAppearance` scales with Dynamic Type (in a bar, to "
                + "the ceiling UIKit keeps for its own titles). It carries no text-style trait, so "
                + "the audit says 'partially'."
        case .inlineText:
            return "a run of text, not a control. The audit counts it as one because it can be "
                + "pressed to select or carries its row's swipe actions; its target is the line "
                + "or the row, and WCAG 2.5.8 exempts targets in a line of text."
        case .oneLineEntry:
            return "a field that is one line by design — the sign-in fields, whose AutoFill, "
                + "one-time-code fill and Next/Go key belong to a single-line field, or the "
                + "system's search bar. It grows taller with the text size and scrolls sideways "
                + "rather than cutting text off."
        case .systemSearchField:
            return "UIKit's search bar (`searchable`): its field and placeholder are drawn in the "
                + "system's own colours, which the app cannot restyle."
        }
    }

    func applies(to finding: AuditFinding, in layout: AuditLayout) -> Bool {
        let said = finding.summary + " " + finding.detail
        let isTextSize = finding.kind.contains(.dynamicType) || finding.kind.contains(.textClipped)
        let isPartial = finding.kind.contains(.dynamicType) && said.contains("partially unsupported")

        // The two that need no element: the audit names the class it found in its own words.
        switch self {
        case .systemKeyboard where said.contains("TUIPrediction"):
            return true
        case .brandFace:
            return isPartial
                && (said.contains("SwiftUI.AccessibilityNode") || said.contains("UITextField"))
                && !(finding.element.map { layout.isTab($0) || layout.isInANavigationBar($0.frame) }
                    ?? false)
        case .uikitLabelInTheBrandFace:
            return isPartial && said.contains("UILabel")
        default:
            break
        }

        guard let element = finding.element else { return false }
        let frame = element.frame
        switch self {
        case .systemKeyboard:
            return element.kind == .key || element.kind == .keyboard

        case .behindTheKeyboard:
            guard let keyboard = layout.keyboard, !finding.kind.contains(.dynamicType) else {
                return false
            }
            return keyboard.intersects(frame)

        case .inactiveControl:
            return finding.kind.contains(.contrast) && !element.isEnabled

        case .measuredOnScreen:
            guard finding.kind.contains(.contrast), let ratio = finding.measuredContrast else {
                return false
            }
            return ratio >= 4.5

        case .atTheScrollEdge:
            guard finding.kind.contains(.contrast) || finding.kind.contains(.hitRegion)
                || finding.kind.contains(.textClipped)
            else { return false }
            return !layout.isTab(element) && layout.isAtTheScrollEdge(frame)

        case .outsideTheSheet:
            guard let sheet = layout.sheet, !frame.isEmpty else { return false }
            return !sheet.intersects(frame)
                && !layout.navigationBars.contains { $0.intersects(frame) }

        case .tabTitles:
            return isTextSize && layout.isTab(element)

        case .barItems:
            return isTextSize && layout.isInANavigationBar(frame)

        case .inlineText:
            return finding.kind.contains(.hitRegion) && element.kind == .staticText

        case .oneLineEntry:
            guard finding.kind.contains(.textClipped) else { return false }
            if element.kind == .searchField { return true }
            guard element.kind == .textField else { return false }
            return ["Email", "Mobile number"].contains(element.identifier)
                || element.label == "Sign-in code"

        case .systemSearchField:
            return finding.kind.contains(.contrast) && element.kind == .searchField

        case .brandFace, .uikitLabelInTheBrandFace:
            return false
        }
    }
}
