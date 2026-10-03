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
        app.launchArguments = ["-UITestMode"] + (light ? ["-UITestLight"] : [])
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

        guard app.tabBars.buttons["Home"].waitForExistence(timeout: 15) else {
            snap("sign-in-failed"); return
        }
        snap("home")

        for tab in ["Cases", "Corporate"] where app.tabBars.buttons[tab].exists {
            app.tabBars.buttons[tab].tap()
            snap(tab.lowercased())
        }

        // A conversation: the stub serves a stored answer with headings, a table and citations.
        app.tabBars.buttons["Chat"].tap()
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
        app.tabBars.buttons["More"].tap()
        snap("more")
        for row in ["My Files", "Calendar", "Library", "Projects", "Your workspace",
                    "All tools", "File tools", "Translate", "eAuctions", "Settings"] {
            let button = app.buttons[row].firstMatch
            guard button.waitForExistence(timeout: 5) else { continue }
            button.tap()
            snap(row.lowercased().replacingOccurrences(of: " ", with: "-"))
            if row == "Settings" {
                app.swipeUp()
                snap("settings-plan-and-usage")
            }
            let done = app.buttons["Done"].firstMatch
            if done.waitForExistence(timeout: 5) { done.tap() } else { app.swipeDown() }
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
