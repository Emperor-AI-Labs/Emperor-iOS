import XCTest

/// Drives the app in a simulator.
///
/// This is the only thing in the repository that can find a screen which compiles and then
/// renders blank, crashes on appear, or navigates nowhere. 619 core tests and a green
/// `xcodebuild` all pass on a view whose body throws the moment it is laid out.
///
/// The app runs against a stubbed transport (`UITestSupport`), so the **real** services, view
/// models, decoders and navigation are exercised — only the socket is replaced. A response shape
/// the decoder cannot read shows up here as an empty screen, exactly as it would in the field.
final class EmperorUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launch(_ extraArguments: String...) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestMode"] + extraArguments
        app.launch()
        return app
    }

    /// Signs in through the real login screen. The stub answers `/login`, so this exercises
    /// `AuthService`, `Session.adopt` and the signed-out → signed-in transition rather than
    /// bypassing them.
    @discardableResult
    private func signIn(_ app: XCUIApplication) -> XCUIApplication {
        let email = app.textFields["Email"]
        XCTAssertTrue(email.waitForExistence(timeout: 10), "the login screen never appeared")
        email.tap()
        email.typeText("test@example.com")

        let password = app.secureTextFields["Password"]
        password.tap()
        password.typeText("hunter2")

        app.buttons["Sign in"].tap()
        return app
    }

    // MARK: - It starts

    /// The single most valuable assertion here: the process comes up and draws something.
    func testTheAppLaunchesAndShowsSignIn() {
        let app = launch()
        XCTAssertTrue(
            app.textFields["Email"].waitForExistence(timeout: 10),
            "the app launched but never rendered the login screen")
    }

    /// The gate is a compliance surface, so it must be impossible to get past accidentally.
    func testTheDisclaimerGateBlocksTheAppUntilAcknowledged() {
        let app = launch("-UITestDisclaimer")
        let acknowledge = app.buttons["I understand"]
        XCTAssertTrue(acknowledge.waitForExistence(timeout: 10), "the gate did not appear")
        XCTAssertFalse(app.textFields["Email"].exists, "the login screen was reachable behind it")
        acknowledge.tap()
        XCTAssertTrue(app.textFields["Email"].waitForExistence(timeout: 10))
    }

    // MARK: - The tab bar

    /// The four destinations the platform's own mobile nav declares.
    func testSigningInRevealsTheFourTabs() {
        let app = signIn(launch())
        for tab in ["Home", "Cases", "Chat", "More"] {
            XCTAssertTrue(
                app.tabBars.buttons[tab].waitForExistence(timeout: 10),
                "the \(tab) tab is missing")
        }
    }

    /// Every tab renders. A tab that crashes on appear takes the app down, and this is what
    /// notices.
    func testEveryTabOpensAndRendersItsScreen() {
        let app = signIn(launch())
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 10))

        for (tab, title) in [("Home", "Home"), ("Cases", "Cases"), ("Chat", "Emperor"), ("More", "More")] {
            app.tabBars.buttons[tab].tap()
            XCTAssertTrue(
                app.navigationBars[title].waitForExistence(timeout: 10),
                "tapping \(tab) did not show a screen titled \(title)")
            XCTAssertEqual(app.state, .runningForeground, "the app died on the \(tab) tab")
        }
    }

    // MARK: - More

    /// Each row in More opens its screen, **and every one of them can be closed by a control on
    /// screen**.
    ///
    /// The second half is the point. Each destination presents rather than pushes, so iOS gives
    /// it no back button — and five of the eight carried no close button either, because they
    /// were built as tabs, where leaving is what the tab bar is for. A swipe down does dismiss
    /// them, which is why this went unnoticed, but a gesture with no visible affordance is not
    /// navigation: it is a thing you have to already know. It is also unavailable to anyone
    /// driving the screen with VoiceOver or Switch Control.
    ///
    /// So this taps the button rather than swiping. A swipe would pass either way and is exactly
    /// how the gap survived a green suite the first time.
    func testEveryMoreRowOpensAndClosesFromAControlOnScreen() {
        let app = signIn(launch())
        XCTAssertTrue(app.tabBars.buttons["More"].waitForExistence(timeout: 10))
        app.tabBars.buttons["More"].tap()

        for (row, title) in [
            ("Calendar", "Calendar"),
            ("Library", "Library"),
            ("Projects", "Projects"),
            ("All tools", "Tools"),
            ("File tools", "File tools"),
            ("Translate", "Translate"),
            ("Liquidations", "Liquidations"),
            ("Settings", "Settings"),
        ] {
            let cell = app.buttons[row]
            XCTAssertTrue(cell.waitForExistence(timeout: 10), "the \(row) row is missing")
            cell.tap()
            XCTAssertTrue(
                app.navigationBars[title].waitForExistence(timeout: 10),
                "\(row) did not open a screen titled \(title)")
            XCTAssertEqual(app.state, .runningForeground, "the app died opening \(row)")

            // Scoped to the navigation bar, so this also pins *where* it is. A "Done" somewhere
            // in the content would satisfy a looser query while still leaving the bar bare.
            let done = app.navigationBars[title].buttons["Done"]
            XCTAssertTrue(
                done.waitForExistence(timeout: 5),
                "\(row) has no close button in its navigation bar — swiping is not an affordance")
            done.tap()

            XCTAssertTrue(
                app.navigationBars["More"].waitForExistence(timeout: 10),
                "closing \(row) did not return to More")
        }
    }

    // MARK: - Court search

    /// Looking a case up by its **case number** — the number printed on every piece of paper
    /// after registration, and until recently the one way of finding a matter this app could not
    /// do. It only offered diary-number lookup, which is the number you get when you file and
    /// rarely the one you have later.
    ///
    /// The two modes are separate routes taking different fields, so this checks that switching
    /// actually reshapes the form rather than just relabelling it.
    func testACaseCanBeFoundByCaseNumberAndByDiaryNumber() {
        let app = signIn(launch())
        XCTAssertTrue(app.tabBars.buttons["Cases"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Cases"].tap()
        // The toolbar "+" carries the sheet's own title as its accessibility label.
        app.buttons["Find a case"].firstMatch.tap()

        XCTAssertTrue(
            app.navigationBars["Find a case"].waitForExistence(timeout: 10),
            "the court search sheet did not open")

        // Forty-eight courts, so a pushed searchable list rather than a control on the form.
        app.buttons["Court"].tap()
        XCTAssertTrue(
            app.navigationBars["Court"].waitForExistence(timeout: 5),
            "the court picker did not open")
        app.buttons["Supreme Court of India"].tap()

        // Case number leads, because it is the number people have.
        let caseNumberField = app.textFields["Case number"]
        XCTAssertTrue(
            caseNumberField.waitForExistence(timeout: 5),
            "the form opened in diary mode rather than case-number mode")

        caseNumberField.tap()
        caseNumberField.typeText("1234")
        app.textFields["Year"].tap()
        app.textFields["Year"].typeText("2025")
        // The Supreme Court publishes its case types, so this is a menu rather than a text field
        // — and picking from it is what proves the catalogue reached the screen.
        app.buttons["Case type"].tap()
        app.buttons["Civil Appeal"].tap()

        app.buttons["Search the court"].tap()
        XCTAssertTrue(
            app.staticTexts["Bakshi v. State of Maharashtra"].waitForExistence(timeout: 15),
            "the case was not listed")

        // Switching mode renames the number, because a diary number is a different number for
        // the same matter.
        app.buttons["By diary number"].tap()
        XCTAssertTrue(
            app.textFields["Diary number"].waitForExistence(timeout: 5),
            "the number field did not change with the mode")
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// The district and subordinate courts are listed and disabled rather than hidden. A great
    /// deal of Indian litigation happens there, and a picker that silently omits them reads as a
    /// product that has not heard of them rather than one that knows what it cannot do.
    func testDistrictCourtsAreListedButCannotBeChosen() {
        let app = signIn(launch())
        XCTAssertTrue(app.tabBars.buttons["Cases"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Cases"].tap()
        app.buttons["Find a case"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Find a case"].waitForExistence(timeout: 10))

        app.buttons["Court"].tap()
        XCTAssertTrue(app.navigationBars["Court"].waitForExistence(timeout: 5))

        let district = app.buttons["District & Sessions Court"]
        XCTAssertTrue(
            district.waitForExistence(timeout: 5),
            "district courts must be listed, not hidden")
        XCTAssertFalse(district.isEnabled, "and must not be selectable")

        // The reason travels with them rather than being left to be inferred.
        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS[c] %@", "cannot look cases up")
            ).firstMatch.exists,
            "the picker does not say why they are disabled")
        XCTAssertEqual(app.state, .runningForeground)
    }

    // MARK: - Empty states

    /// `ListStateView` routes to `empty()` whenever the *filtered* list is empty, which is a
    /// branch three screens got wrong by handling it in the content closure instead. With every
    /// fixture empty, each of these must say something rather than showing a blank list.
    func testEmptyStatesRenderRatherThanBlankScreens() {
        let app = signIn(launch("-UITestEmpty"))
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 10))

        for tab in ["Home", "Cases", "Chat"] {
            app.tabBars.buttons[tab].tap()
            // `ContentUnavailableView` renders as static text; any of it is enough to prove the
            // empty branch drew something.
            let hasCopy = app.staticTexts.count > 0
            XCTAssertTrue(hasCopy, "the \(tab) tab rendered nothing at all when empty")
            XCTAssertEqual(app.state, .runningForeground, "the app died on an empty \(tab)")
        }
    }

    // MARK: - Sign out

    /// The one destructive action reachable without a server write, and the way back to the
    /// login screen.
    func testSigningOutReturnsToLogin() {
        let app = signIn(launch())
        XCTAssertTrue(app.tabBars.buttons["More"].waitForExistence(timeout: 10))
        app.tabBars.buttons["More"].tap()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))

        app.buttons["Sign out"].firstMatch.tap()

        // A confirmation stands between the tap and the act, and its button carries the same
        // label — so it has to be found inside the dialog rather than by `firstMatch`, which
        // would just hit the row again. `.confirmationDialog` surfaces as a sheet on iPhone.
        let dialog = app.sheets.buttons["Sign out"]
        if dialog.waitForExistence(timeout: 5) {
            dialog.tap()
        } else if app.alerts.buttons["Sign out"].waitForExistence(timeout: 2) {
            app.alerts.buttons["Sign out"].tap()
        }

        XCTAssertTrue(
            app.textFields["Email"].waitForExistence(timeout: 10),
            "signing out did not return to the login screen")
    }

    // MARK: - Tools

    /// The registry is twenty-nine screens' worth of form behind one row, and the forms are
    /// generated from data rather than laid out by hand — so one broken field definition would
    /// break every tool at once. This opens the list and runs one.
    func testAToolOpensItsFormAndCanBeRun() {
        let app = signIn(launch())
        XCTAssertTrue(app.tabBars.buttons["More"].waitForExistence(timeout: 10))
        app.tabBars.buttons["More"].tap()
        app.buttons["All tools"].tap()

        XCTAssertTrue(app.navigationBars["Tools"].waitForExistence(timeout: 10))
        // The five the web's own sidebar links, so the ones most likely to be opened.
        for tool in ["Devil's Advocate", "Highlighter"] {
            XCTAssertTrue(
                app.staticTexts[tool].waitForExistence(timeout: 5), "\(tool) is not listed")
        }

        app.staticTexts["Devil's Advocate"].tap()
        let run = app.buttons["Run"]
        XCTAssertTrue(run.waitForExistence(timeout: 10), "the tool form did not render")
        run.tap()

        // Running starts a conversation and sends the prompt. The stub answers, so what is
        // asserted is that the navigation happened and the app survived it.
        XCTAssertTrue(app.navigationBars["Conversation"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.state, .runningForeground)

        // The whole way back out. This is the deepest chain in the app — a sheet containing a
        // stack two pushes deep — and it is the one that had no exit at the bottom: the two
        // pushes have back buttons, but before `ToolsListView` grew a "Done" the only way off
        // the tool list was a swipe.
        //
        // The leading nav-bar button is the back button; asserting it by label would be asserting
        // the *previous screen's title*, which iOS abbreviates when it is long. Scoped to the bar
        // being left, so this cannot accidentally match a bar further up the hierarchy.
        for (leaving, arriving) in [
            ("Conversation", "Devil's Advocate"),
            ("Devil's Advocate", "Tools"),
        ] {
            app.navigationBars[leaving].buttons.element(boundBy: 0).tap()
            XCTAssertTrue(
                app.navigationBars[arriving].waitForExistence(timeout: 10),
                "going back from \(leaving) did not land on \(arriving)")
        }

        app.navigationBars["Tools"].buttons["Done"].tap()
        XCTAssertTrue(
            app.navigationBars["More"].waitForExistence(timeout: 10),
            "the tool sheet could not be closed after running a tool")
    }
}
