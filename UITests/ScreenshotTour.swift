import XCTest

/// Photographs every main screen, in the dark theme and the light one.
///
/// Not a test of behaviour — the other UI tests are that — but the only way to *see* this app
/// from the machine it is developed on, which has no Xcode. CI exports these attachments as
/// plain PNGs (the `screenshot-tour` artifact), so a layout that is cramped, clipped, low in
/// contrast or simply wrong is caught by looking, which is how such things are caught.
///
/// Every step tolerates a missing control: a tour that stops at the first surprise shows
/// nothing after it, and the point is to show everything that rendered.
final class ScreenshotTour: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
    }

    func testTheDarkTour() { tour(light: false) }
    func testTheLightTour() { tour(light: true) }

    // MARK: - The tour

    private func tour(light: Bool) {
        let app = XCUIApplication()
        // The first-sign-in role question is asked, so the tour can answer it: the role persists
        // between launches, and the workspace photographed below is Litigator's.
        app.launchArguments = ["-UITestMode", "-UITestRoleWelcome"] + (light ? ["-UITestLight"] : [])
        app.launch()
        let theme = light ? "light" : "dark"
        var step = 0
        func snap(_ name: String) {
            step += 1
            // Let animations and loads settle; a half-drawn transition is not what a person sees.
            Thread.sleep(forTimeInterval: 0.8)
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = String(format: "%@-%02d-%@", theme, step, name)
            shot.lifetime = .keepAlways
            add(shot)
        }

        // Signing in, every step of it.
        guard app.textFields["Email"].waitForExistence(timeout: 15) else {
            snap("launch-failed"); return
        }
        snap("sign-in")

        tapIfPresent(app.buttons["Create an account"])
        if app.textFields["Full name"].waitForExistence(timeout: 5) { snap("create-account") }
        tapIfPresent(app.buttons["Sign in instead"])

        let email = app.textFields["Email"]
        if email.waitForExistence(timeout: 5) {
            email.tap()
            email.typeText("john.doe@firm.com")
        }
        tapIfPresent(app.buttons["Sign in with an email code"])
        let code = app.textFields["Sign-in code"]
        if code.waitForExistence(timeout: 10) {
            snap("enter-code")
            code.tap()
            code.typeText("123456")
        }

        let litigator = app.buttons["role-litigator"]
        if litigator.waitForExistence(timeout: 10) {
            snap("role-welcome")
            litigator.tap()
            tapIfPresent(app.buttons["Continue"])
        }

        guard app.tab("Home").waitForExistence(timeout: 15) else {
            snap("sign-in-failed"); return
        }
        snap("home")

        // The updates sheet, from Home's bell. Its label carries the unread count, so it is
        // found by how it starts.
        let updates = app.navigationBars["Home"].buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Updates")).firstMatch
        if updates.waitForExistence(timeout: 5) {
            updates.tap()
            if app.navigationBars["Updates"].waitForExistence(timeout: 10) {
                snap("updates")
                tapIfPresent(app.navigationBars["Updates"].buttons["Done"])
            }
        }

        app.tab("Cases").tap()
        snap("cases")

        // Finding a case at the court — the form before a court is chosen.
        let find = app.buttons["Find a case"].firstMatch
        if find.waitForExistence(timeout: 5) {
            find.tap()
            if app.navigationBars["Find a case"].waitForExistence(timeout: 10) {
                snap("find-a-case")
                tapIfPresent(app.navigationBars["Find a case"].buttons["Done"])
            }
        }

        // The Calendar opens on today, where the stub lists one matter and one diary entry; the
        // listing then opens its case on the Cases tab, on the overview.
        if app.tab("Calendar").exists {
            app.tab("Calendar").tap()
            let listing = app.buttons["calendar-listing-case1"]
            let isListed = listing.waitForExistence(timeout: 10)
            snap("calendar")
            if isListed {
                listing.tap()
                let matter = app.navigationBars["Bakshi v. State of Maharashtra"]
                if matter.waitForExistence(timeout: 10) {
                    snap("case-overview")
                    backOut(app)
                }
            }
        }

        // A conversation: the stub serves a stored answer with headings, a table and citations,
        // and the work log it was stored with, collapsed above it.
        app.tab("Chat").tap()
        snap("chats")
        let conversation = app.staticTexts["Bakshi v. State"]
        if conversation.waitForExistence(timeout: 10) {
            conversation.tap()
            snap("conversation")
            app.swipeUp()
            snap("conversation-references")
            backOut(app)
        }

        // Everything behind More, each opened and closed from its own Done.
        app.tab("More").tap()
        snap("more")
        // Projects and eAuctions are hidden for now; see `MoreView`.
        for row in ["My Files", "Corporate Calendar", "Library", "Your workspace",
                    "All tools", "File tools", "Translate", "Settings"] {
            let button = app.buttons[row].firstMatch
            guard button.waitForExistence(timeout: 5) else { continue }
            button.tap()
            snap(row.lowercased().replacingOccurrences(of: " ", with: "-"))
            if row == "Settings" {
                // The role selector, opened from the head of Settings.
                let selector = app.buttons["Role selector"].firstMatch
                if selector.waitForExistence(timeout: 5) {
                    selector.tap()
                    if app.navigationBars["Switch role"].waitForExistence(timeout: 5) {
                        snap("settings-role-selector")
                        backOut(app)
                    }
                }
                app.swipeUp()
                snap("settings-plan-and-usage")
            }
            if row == "Your workspace" {
                // Litigator's workspace is the drafting taxonomy; one of its documents, opened.
                tapIfPresent(app.buttons["matter-civil"])
                let plaint = app.descendants(matching: .any)
                    .matching(identifier: "ldoc-civil-plaint").firstMatch
                if plaint.waitForExistence(timeout: 5) {
                    plaint.tap()
                    snap("litigator-document")
                    // Scoped to the form's own bar: the sheet sits over More, and an unscoped
                    // query could reach for a bar behind it.
                    let back = app.navigationBars["Plaint"].buttons.element(boundBy: 0)
                    if back.waitForExistence(timeout: 5) { back.tap() } else { backOut(app) }
                }
            }
            let done = app.buttons["Done"].firstMatch
            if done.waitForExistence(timeout: 5) { done.tap() } else { app.swipeDown() }
        }
    }

    /// What each tab says when there is nothing to show — every fixture empty. The empty state is
    /// a component of its own, drawn on more screens than any other, and the populated tour never
    /// reaches it.
    func testTheEmptyStatesDark() { emptyTour(light: false) }
    func testTheEmptyStatesLight() { emptyTour(light: true) }

    private func emptyTour(light: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestMode", "-UITestEmpty"] + (light ? ["-UITestLight"] : [])
        app.launch()
        let theme = light ? "light" : "dark"
        guard app.textFields["Email"].waitForExistence(timeout: 15) else { return }
        let email = app.textFields["Email"]
        email.tap()
        email.typeText("john.doe@firm.com")
        let password = app.secureTextFields["Password"]
        if password.waitForExistence(timeout: 5) {
            password.tap()
            password.typeText("hunter2")
        }
        tapIfPresent(app.buttons["Sign in"])
        guard app.tab("Home").waitForExistence(timeout: 15) else { return }

        var step = 0
        for tab in ["Home", "Cases", "Chat", "Calendar"] {
            let button = app.tab(tab)
            guard button.waitForExistence(timeout: 5) else { continue }
            button.tap()
            step += 1
            Thread.sleep(forTimeInterval: 0.8)
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = String(format: "empty-%@-%02d-%@", theme, step, tab.lowercased())
            shot.lifetime = .keepAlways
            add(shot)
        }
    }

    /// The sign-in screens as they look once Sign in with Apple and Google are switched on —
    /// `-UITestSocial` draws them with a placeholder client id; nothing here signs in.
    func testTheSignInProviders() {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestMode", "-UITestSocial"]
        app.launch()
        guard app.textFields["Email"].waitForExistence(timeout: 15) else { return }
        Thread.sleep(forTimeInterval: 0.8)
        let signIn = XCTAttachment(screenshot: app.screenshot())
        signIn.name = "providers-01-sign-in"
        signIn.lifetime = .keepAlways
        add(signIn)

        tapIfPresent(app.buttons["Create an account"])
        Thread.sleep(forTimeInterval: 0.8)
        let create = XCTAttachment(screenshot: app.screenshot())
        create.name = "providers-02-create-account"
        create.lifetime = .keepAlways
        add(create)
    }

    private func tapIfPresent(_ element: XCUIElement) {
        if element.waitForExistence(timeout: 5) { element.tap() }
    }

    private func backOut(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists { back.tap() }
    }
}
