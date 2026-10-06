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
        email.typeText("john.doe@firm.com")

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

    // MARK: - Other ways in

    /// Every account can sign in with an emailed code, and it is the only way in for one made
    /// with Google. A full code goes on without a tap, as code fields do elsewhere on the phone.
    func testSigningInWithAnEmailCode() {
        let app = launch()
        let email = app.textFields["Email"]
        XCTAssertTrue(email.waitForExistence(timeout: 10))
        email.tap()
        email.typeText("john.doe@firm.com")

        app.buttons["Sign in with an email code"].tap()

        let code = app.textFields["Sign-in code"]
        XCTAssertTrue(code.waitForExistence(timeout: 10), "the code step never appeared")
        code.tap()
        code.typeText("123456")

        XCTAssertTrue(
            app.tab("Home").waitForExistence(timeout: 10),
            "a complete code did not sign in")
    }

    /// Creating an account no longer signs anyone in: the server emails a confirmation link. The
    /// screen must say so — the old flow reported "unexpected response" about an account it had
    /// just made.
    func testCreatingAnAccountAsksForConfirmation() {
        let app = launch()
        XCTAssertTrue(app.textFields["Email"].waitForExistence(timeout: 10))
        app.buttons["Create an account"].tap()

        let name = app.textFields["Full name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Jane Doe")
        let email = app.textFields["Email"]
        email.tap()
        email.typeText("jane.doe@firm.com")
        // Optional, and grouped as it is typed.
        let mobile = app.textFields["Mobile number"]
        XCTAssertTrue(mobile.exists, "the sign-up form asks for a mobile number")
        mobile.tap()
        mobile.typeText("9876543210")
        let password = app.secureTextFields["Password"]
        password.tap()
        password.typeText("long-enough-password")
        // The web's form asks for the password twice, and so does this one.
        let confirm = app.secureTextFields["Confirm password"]
        confirm.tap()
        confirm.typeText("long-enough-password")

        app.buttons["Create account"].tap()

        XCTAssertTrue(
            app.staticTexts["Confirm your email"].waitForExistence(timeout: 10),
            "the confirmation step never appeared")
        XCTAssertTrue(app.buttons["Use a code instead"].exists)
        XCTAssertFalse(app.tab("Home").exists, "nobody is signed in yet")
    }

    // MARK: - The tab bar

    /// The bar the product owner chose: Home · Cases · Chat · Calendar · More, the same for every
    /// role. Calendar holds the place the web gives its role-gated Corporate tab, which is now a
    /// row in More — so it must not come back here by accident.
    func testSigningInRevealsTheTabs() {
        let app = signIn(launch())
        for tab in ["Home", "Cases", "Chat", "Calendar", "More"] {
            XCTAssertTrue(
                app.tab(tab).waitForExistence(timeout: 10),
                "the \(tab) tab is missing")
        }
        XCTAssertFalse(app.tab("Corporate").exists, "Corporate lives in More now")
    }

    /// Every tab renders. A tab that crashes on appear takes the app down, and this is what
    /// notices.
    func testEveryTabOpensAndRendersItsScreen() {
        let app = signIn(launch())
        XCTAssertTrue(app.tab("Home").waitForExistence(timeout: 10))

        for (tab, title) in [
            ("Home", "Home"), ("Cases", "Cases"), ("Chat", "Emperor"),
            ("Calendar", "Calendar"), ("More", "More"),
        ] {
            app.tab(tab).tap()
            XCTAssertTrue(
                app.navigationBars[title].waitForExistence(timeout: 10),
                "tapping \(tab) did not show a screen titled \(title)")
            XCTAssertEqual(app.state, .runningForeground, "the app died on the \(tab) tab")
        }
    }

    // MARK: - Home

    /// A listing leads with where it is heard — item and courtroom — because that is what a
    /// litigator scans a list for. The row is one accessibility element saying so, in order.
    func testAHomeListingLeadsWithItsItemAndCourt() {
        let app = signIn(launch())
        XCTAssertTrue(app.tab("Home").waitForExistence(timeout: 10))
        let row = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "Item 7, Court 12")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the listing does not lead with item and court")
        XCTAssertEqual(app.state, .runningForeground)
    }

    // MARK: - Calendar

    /// The day's listing is on the Calendar, led by its sitting time, and tapping it lands on the
    /// **Cases** tab with that matter open on its overview — the stub's `/cause-list`, `/cases`
    /// and `/case` all describe `case1`, listed today, which is the day the Calendar opens on.
    ///
    /// Then the whole way round a second time. The request to open a case is taken once; this is
    /// what notices if it is never cleared (the case would re-open on every visit to Cases) or
    /// never re-armed (the second tap would do nothing).
    func testACalendarListingOpensItsCaseOnTheCasesTab() {
        let app = signIn(launch())
        XCTAssertTrue(app.tab("Calendar").waitForExistence(timeout: 10))
        app.tab("Calendar").tap()
        XCTAssertTrue(app.navigationBars["Calendar"].waitForExistence(timeout: 10))

        let listing = app.buttons["calendar-listing-case1"]
        XCTAssertTrue(listing.waitForExistence(timeout: 10), "today's listing is not on the Calendar")
        XCTAssertTrue(
            listing.label.hasPrefix("10:30 AM. Item 7, Court 12"),
            "the listing does not lead with its time, item and court: \(listing.label)")

        for pass in 1...2 {
            app.buttons["calendar-listing-case1"].tap()

            let matter = app.navigationBars["Bakshi v. State of Maharashtra"]
            XCTAssertTrue(
                matter.waitForExistence(timeout: 10),
                "pass \(pass): tapping the listing did not open its case")
            XCTAssertTrue(
                app.tab("Cases").isSelected,
                "pass \(pass): the case opened somewhere other than the Cases tab")
            let overview = app.staticTexts.matching(
                NSPredicate(format: "label ==[c] %@", "Overview")).firstMatch
            XCTAssertTrue(
                overview.waitForExistence(timeout: 10),
                "pass \(pass): the case did not open on its overview")

            // Back lands on the docket, not on whatever Cases showed before.
            matter.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(
                app.navigationBars["Cases"].waitForExistence(timeout: 10),
                "pass \(pass): back from the case did not land on the docket")

            app.tab("Calendar").tap()
            XCTAssertTrue(app.navigationBars["Calendar"].waitForExistence(timeout: 10))
        }

        // And coming back to Cases does not open the case again by itself.
        app.tab("Cases").tap()
        XCTAssertTrue(app.navigationBars["Cases"].waitForExistence(timeout: 10))
        XCTAssertFalse(
            app.navigationBars["Bakshi v. State of Maharashtra"].exists,
            "an old request re-opened the case")

        // The day's diary entry follows its listings, in a section of its own. Scrolled to, as
        // it sits below the month and the listing: a list only builds the rows it is showing.
        app.tab("Calendar").tap()
        let diary = app.staticTexts["File written statement"]
        var swipes = 0
        while !diary.exists, swipes < 3 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(diary.waitForExistence(timeout: 5), "the day's diary entry is missing")
    }

    // MARK: - Corporate Calendar

    /// More opens the Corporate Calendar for every role; it lists a statutory deadline and opens
    /// it, the way back is the back button, and the screen closes from its own Done.
    func testTheCorporateCalendarOpensFromMoreAndOpensADeadline() {
        let app = signIn(launch())
        XCTAssertTrue(app.tab("More").waitForExistence(timeout: 10))
        app.tab("More").tap()
        app.buttons["Corporate Calendar"].tap()
        XCTAssertTrue(app.navigationBars["Corporate Calendar"].waitForExistence(timeout: 10))

        let deadline = app.staticTexts["GSTR-1"]
        XCTAssertTrue(deadline.waitForExistence(timeout: 10), "the deadline is not listed")
        deadline.tap()

        // The detail is titled by the obligation's own reference.
        XCTAssertTrue(
            app.navigationBars["GSTR1"].waitForExistence(timeout: 10),
            "the deadline did not open")
        XCTAssertTrue(
            app.navigationBars["GSTR1"].buttons["Share"].waitForExistence(timeout: 5),
            "the deadline cannot be shared")
        app.navigationBars["GSTR1"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Corporate Calendar"].waitForExistence(timeout: 10))

        app.navigationBars["Corporate Calendar"].buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["More"].waitForExistence(timeout: 10))
    }

    // MARK: - Calendar subscription

    /// Subscribing is offered from Calendar, the link can be copied, and the sheet closes from a
    /// control on screen. "Subscribe in Calendar" itself is not tapped: it leaves the app for
    /// the Calendar app, which is the point of it and the end of any test.
    func testCalendarOffersAPrivateLinkThatCanBeCopied() {
        let app = signIn(launch())
        XCTAssertTrue(app.tab("Calendar").waitForExistence(timeout: 10))
        app.tab("Calendar").tap()
        XCTAssertTrue(app.navigationBars["Calendar"].waitForExistence(timeout: 10))

        app.navigationBars["Calendar"].buttons["Subscribe"].tap()
        XCTAssertTrue(app.navigationBars["Subscribe"].waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.buttons["Subscribe in Calendar"].waitForExistence(timeout: 10),
            "the link never loaded")

        app.buttons["Copy link"].tap()
        XCTAssertTrue(app.buttons["Copied"].waitForExistence(timeout: 5), "copying said nothing")

        app.navigationBars["Subscribe"].buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Calendar"].waitForExistence(timeout: 10))
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
        XCTAssertTrue(app.tab("More").waitForExistence(timeout: 10))
        app.tab("More").tap()

        // Hidden for now at the product owner's request; their screens are kept. See the note
        // at `MoreView`'s rows for how to bring them back.
        XCTAssertTrue(app.navigationBars["More"].waitForExistence(timeout: 10))
        for hidden in ["Projects", "eAuctions"] {
            XCTAssertFalse(app.buttons[hidden].exists, "\(hidden) is meant to be hidden")
        }

        for (row, title) in [
            ("My Files", "My Files"),
            ("Corporate Calendar", "Corporate Calendar"),
            ("Library", "Library"),
            ("All tools", "Tools"),
            ("File tools", "File tools"),
            ("Translate", "Translate"),
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

    // MARK: - My Files

    /// A folder opens, its document is listed, and deleting it asks first — naming the document
    /// in the question. Cancelled, so nothing is sent; what is pinned is that the destructive
    /// path cannot be reached without a confirmation that says what it will destroy.
    func testDeletingADocumentAsksFirstAndNamesIt() {
        let app = signIn(launch())
        XCTAssertTrue(app.tab("More").waitForExistence(timeout: 10))
        app.tab("More").tap()
        app.buttons["My Files"].tap()
        XCTAssertTrue(app.navigationBars["My Files"].waitForExistence(timeout: 10))

        app.buttons["Folders"].tap()
        let folder = app.staticTexts["Bakshi"]
        XCTAssertTrue(folder.waitForExistence(timeout: 10), "the folder from /user-files is not listed")
        folder.tap()
        XCTAssertTrue(app.navigationBars["Bakshi"].waitForExistence(timeout: 10), "the folder did not open")

        let document = app.staticTexts["Plaint.pdf"]
        XCTAssertTrue(document.waitForExistence(timeout: 10), "the folder's document is not listed")
        document.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()

        let confirmation = app.alerts["Delete “Plaint.pdf”?"]
        XCTAssertTrue(
            confirmation.waitForExistence(timeout: 5),
            "deleting did not ask first, or the question does not name the document")
        XCTAssertTrue(confirmation.buttons["Delete document"].exists)
        confirmation.buttons["Cancel"].tap()

        XCTAssertTrue(document.waitForExistence(timeout: 5), "cancelling must leave the document")
        XCTAssertEqual(app.state, .runningForeground)
    }

    // MARK: - First sign-in

    /// The role choice appears after a first sign-in on this device, offers a way past without
    /// choosing, and gives way to the app once answered.
    func testAFirstSignInIsAskedForARoleAndCanChooseOne() {
        let app = signIn(launch("-UITestRoleWelcome"))

        let choice = app.buttons["role-corporateCounsel"]
        XCTAssertTrue(choice.waitForExistence(timeout: 10), "the role choice did not appear")
        XCTAssertFalse(app.tab("Home").exists, "the app was reachable behind it")
        XCTAssertTrue(app.buttons["Skip for now"].exists, "there must be a way past without choosing")

        choice.tap()
        app.buttons["Continue"].tap()

        XCTAssertTrue(
            app.tab("Home").waitForExistence(timeout: 10),
            "choosing a role did not lead into the app")
    }

    func testTheRoleChoiceCanBeSkipped() {
        let app = signIn(launch("-UITestRoleWelcome"))
        let skip = app.buttons["Skip for now"]
        XCTAssertTrue(skip.waitForExistence(timeout: 10), "the role choice did not appear")
        skip.tap()
        XCTAssertTrue(app.tab("Home").waitForExistence(timeout: 10))
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
        XCTAssertTrue(app.tab("Cases").waitForExistence(timeout: 10))
        app.tab("Cases").tap()
        // The toolbar "+" carries the sheet's own title as its accessibility label.
        app.buttons["Find a case"].firstMatch.tap()

        XCTAssertTrue(
            app.navigationBars["Find a case"].waitForExistence(timeout: 10),
            "the court search sheet did not open")

        // Forty-eight courts, so a pushed searchable list rather than a control on the form.
        app.buttons["court-picker"].tap()
        XCTAssertTrue(
            app.navigationBars["Court"].waitForExistence(timeout: 5),
            "the court picker did not open")
        app.buttons["court-sc"].tap()

        // Case number leads, because it is the number people have. The Supreme Court needs a
        // case type for one and not the other, so which controls are present is what proves the
        // form is shaped by the mode rather than merely relabelled.
        XCTAssertTrue(
            app.textFields["Case number"].waitForExistence(timeout: 5),
            "the form opened in diary mode rather than case-number mode")

        app.buttons["By diary number"].tap()
        let diaryField = app.textFields["Diary number"]
        XCTAssertTrue(
            diaryField.waitForExistence(timeout: 5),
            "the number field did not change with the mode")

        // A diary number identifies a matter on its own, so this mode needs no case type — and
        // it is the one that can be driven end to end without operating a picker.
        diaryField.tap()
        diaryField.typeText("52650")
        app.textFields["Year"].tap()
        app.textFields["Year"].typeText("2023")

        app.buttons["Search the court"].tap()
        XCTAssertTrue(
            app.staticTexts["Bakshi v. State of Maharashtra"].waitForExistence(timeout: 20),
            "the case was not listed")
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// The district and subordinate courts are listed and disabled rather than hidden. A great
    /// deal of Indian litigation happens there, and a picker that silently omits them reads as a
    /// product that has not heard of them rather than one that knows what it cannot do.
    func testDistrictCourtsAreListedButCannotBeChosen() {
        let app = signIn(launch())
        XCTAssertTrue(app.tab("Cases").waitForExistence(timeout: 10))
        app.tab("Cases").tap()
        app.buttons["Find a case"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Find a case"].waitForExistence(timeout: 10))

        app.buttons["court-picker"].tap()
        XCTAssertTrue(app.navigationBars["Court"].waitForExistence(timeout: 5))

        // Filtered rather than scrolled to. The district courts sit past twenty-five High
        // Courts, and a `List` does not put off-screen rows in the accessibility tree at all —
        // so without this the row is not merely hard to reach, it does not exist to the test.
        let search = app.searchFields["Search courts"]
        XCTAssertTrue(search.waitForExistence(timeout: 5), "the picker has no search field")
        search.tap()
        search.typeText("Sessions")

        let district = app.buttons["court-dist-sessions"]
        XCTAssertTrue(
            district.waitForExistence(timeout: 5),
            "district courts must be listed, not hidden")
        XCTAssertFalse(district.isEnabled, "and must not be selectable")

        // The reason travels with them rather than being left to be inferred.
        let explanation = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "cannot look cases up")).firstMatch
        XCTAssertTrue(
            explanation.waitForExistence(timeout: 5),
            "the picker does not say why they are disabled")

        // A searchable one, for contrast — otherwise this would pass on a picker where every
        // row happened to be disabled.
        search.buttons["Clear text"].tap()
        search.typeText("Supreme")
        XCTAssertTrue(app.buttons["court-sc"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["court-sc"].isEnabled)
        XCTAssertEqual(app.state, .runningForeground)
    }

    // MARK: - Chat

    /// A stored answer carries the work log it was produced with — the stub's answer was stored
    /// with one, as the web stores every answer — drawn collapsed above it, and opening to the
    /// calls that were made.
    func testAStoredAnswerShowsTheWorkItRestsOn() {
        let app = signIn(launch())
        XCTAssertTrue(app.tab("Chat").waitForExistence(timeout: 10))
        app.tab("Chat").tap()
        let conversation = app.staticTexts["Bakshi v. State"]
        XCTAssertTrue(conversation.waitForExistence(timeout: 10), "the conversation is not listed")
        conversation.tap()

        let panel = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Worked")).firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 10), "the stored work log is not drawn")
        XCTAssertTrue(panel.label.contains("2 steps"), "the panel miscounts: \(panel.label)")

        let step = app.staticTexts["Searching the record for: Section 34(3) limitation"]
        XCTAssertFalse(step.exists, "a stored panel opens collapsed")
        panel.tap()
        XCTAssertTrue(step.waitForExistence(timeout: 5), "the panel does not open to its steps")
        XCTAssertEqual(app.state, .runningForeground)
    }

    // MARK: - Empty states

    /// `ListStateView` routes to `empty()` whenever the *filtered* list is empty, which is a
    /// branch three screens got wrong by handling it in the content closure instead. With every
    /// fixture empty, each of these must say something rather than showing a blank list.
    func testEmptyStatesRenderRatherThanBlankScreens() {
        let app = signIn(launch("-UITestEmpty"))
        XCTAssertTrue(app.tab("Home").waitForExistence(timeout: 10))

        for tab in ["Home", "Cases", "Chat", "Calendar"] {
            app.tab(tab).tap()
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
        XCTAssertTrue(app.tab("More").waitForExistence(timeout: 10))
        app.tab("More").tap()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))

        // Sign out is the last row, below Plan & usage, so on a phone it starts off screen — and
        // a list only builds the rows it is showing. Scroll to it rather than assume it is there.
        let signOut = app.buttons["Sign out"].firstMatch
        var swipes = 0
        while !(signOut.exists && signOut.isHittable) && swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
        signOut.tap()

        // A confirmation stands between the tap and the act, and its button carries the same
        // label — so it has to be found inside the dialog rather than by `firstMatch`, which
        // would just hit the row again. `.confirmationDialog` surfaces as a sheet on iPhone and
        // as a popover beside the row on iPad.
        let dialog = app.sheets.buttons["Sign out"]
        let popover = app.popovers.buttons["Sign out"]
        if dialog.waitForExistence(timeout: 5) {
            dialog.tap()
        } else if popover.waitForExistence(timeout: 2) {
            popover.tap()
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
        XCTAssertTrue(app.tab("More").waitForExistence(timeout: 10))
        app.tab("More").tap()
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

    // MARK: - Role selector

    /// The role is switched from the head of Settings, at once, as the web's selector does — and
    /// the workspace follows it.
    func testTheRoleIsSwitchedFromSettings() {
        let app = signIn(launch())
        XCTAssertTrue(app.tab("More").waitForExistence(timeout: 10))
        app.tab("More").tap()
        app.buttons["Settings"].tap()

        let selector = app.buttons["Role selector"].firstMatch
        XCTAssertTrue(selector.waitForExistence(timeout: 10), "Settings has no role selector")
        selector.tap()
        let corporate = app.buttons["role-corporateCounsel"].firstMatch
        XCTAssertTrue(corporate.waitForExistence(timeout: 10), "the roles were not listed")
        corporate.tap()

        // Back on Settings, which now says the new role. Polled rather than waited on with an
        // expectation: `waitForExpectations` sends the test case across actors, which Swift 6
        // refuses to compile here.
        XCTAssertTrue(selector.waitForExistence(timeout: 10))
        var polls = 0
        while !selector.label.contains("Corporate Counsel") && polls < 40 {
            Thread.sleep(forTimeInterval: 0.25)
            polls += 1
        }
        XCTAssertTrue(
            selector.label.contains("Corporate Counsel"), "Settings did not show the new role")

        // And the workspace is the new role's.
        app.navigationBars["Settings"].buttons["Done"].tap()
        let workspace = app.buttons["Your workspace"].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: 10))
        workspace.tap()
        XCTAssertTrue(
            app.navigationBars["Corporate Counsel"].waitForExistence(timeout: 10),
            "the workspace did not follow the role")
        app.buttons["Done"].firstMatch.tap()

        // Left as the other tests expect to find it.
        app.buttons["Settings"].firstMatch.tap()
        selector.tap()
        app.buttons["role-litigator"].firstMatch.tap()
    }

    // MARK: - Your workspace

    /// Litigator's workspace is the drafting taxonomy, and it opens a document's form. It was an
    /// empty screen — "Nothing in this part of the deck" — for the role most people hold, because
    /// the deck it showed has no Litigator cards on the platform either.
    ///
    /// The role is chosen through the first-sign-in question rather than assumed: a role persists
    /// between launches, and `testAFirstSignInIsAskedForARoleAndCanChooseOne` leaves the simulator
    /// on Corporate Counsel. Civil is tapped for the same reason — the matter is remembered too.
    func testTheLitigatorWorkspaceListsCivilDocumentsAndOpensOne() {
        let app = signIn(launch("-UITestRoleWelcome"))
        let litigator = app.buttons["role-litigator"]
        XCTAssertTrue(litigator.waitForExistence(timeout: 10), "the role choice did not appear")
        litigator.tap()
        app.buttons["Continue"].tap()

        XCTAssertTrue(app.tab("More").waitForExistence(timeout: 10))
        app.tab("More").tap()
        app.buttons["Your workspace"].tap()
        XCTAssertTrue(
            app.navigationBars["Litigator"].waitForExistence(timeout: 10),
            "Your workspace did not open as Litigator's")

        let civil = app.buttons["matter-civil"]
        XCTAssertTrue(civil.waitForExistence(timeout: 5), "the matter chips are missing")
        civil.tap()

        // A section of Civil documents: its heading, and the documents under it.
        let heading = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Pleadings & Petitions"))
            .firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 5), "the first Civil section is missing")
        let plaint = app.descendants(matching: .any)
            .matching(identifier: "ldoc-civil-plaint").firstMatch
        XCTAssertTrue(plaint.waitForExistence(timeout: 5), "the plaint is not listed")
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "ldoc-civil-writ").firstMatch.exists,
            "the writ petition is not listed")
        XCTAssertFalse(
            app.staticTexts["Nothing in this part of the deck."].exists,
            "the empty deck is back")

        // It opens in the tool form, titled and described as the platform resolves it.
        plaint.tap()
        XCTAssertTrue(
            app.navigationBars["Plaint"].waitForExistence(timeout: 10), "the document did not open")
        XCTAssertTrue(
            app.staticTexts["Civil · Pleadings & Petitions"].waitForExistence(timeout: 5),
            "the form is not the plaint's")
        XCTAssertTrue(app.buttons["Run"].exists, "the form cannot be run")
        XCTAssertEqual(app.state, .runningForeground)

        // And back out the whole way, from controls on screen.
        app.navigationBars["Plaint"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Litigator"].waitForExistence(timeout: 10))
        app.navigationBars["Litigator"].buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["More"].waitForExistence(timeout: 10))
    }

    // MARK: - File tools

    /// Every card in the hub opens its own screen and comes back. Each tool is a separate push
    /// from one grid, so a card wired to the wrong destination — or a screen that dies on
    /// appear — shows up here rather than in a user's hands.
    func testEveryFileToolOpensFromTheHubAndComesBack() {
        let app = signIn(launch())
        XCTAssertTrue(app.tab("More").waitForExistence(timeout: 10))
        app.tab("More").tap()
        app.buttons["File tools"].tap()
        XCTAssertTrue(app.navigationBars["File tools"].waitForExistence(timeout: 10))

        for (id, title) in [
            ("split", "Split PDF"),
            ("merge", "Merge PDF"),
            ("rearrange", "Rearrange PDF"),
            ("compressPDF", "Compress PDF"),
            ("imageToPDF", "Image to PDF"),
            ("pdfToWord", "PDF to Word"),
            ("compressImage", "Compress image"),
        ] {
            let card = app.buttons["tool-\(id)"]
            // The grid is lazy: a card below the fold does not exist until it is scrolled to.
            var swipes = 0
            while !(card.exists && card.isHittable), swipes < 4 {
                app.swipeUp()
                swipes += 1
            }
            XCTAssertTrue(card.waitForExistence(timeout: 5), "the \(title) card is missing")
            card.tap()
            XCTAssertTrue(
                app.navigationBars[title].waitForExistence(timeout: 10), "\(title) did not open")
            XCTAssertEqual(app.state, .runningForeground, "the app died opening \(title)")

            app.navigationBars[title].buttons.element(boundBy: 0).tap()
            XCTAssertTrue(
                app.navigationBars["File tools"].waitForExistence(timeout: 10),
                "could not come back from \(title)")
        }

        app.navigationBars["File tools"].buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["More"].waitForExistence(timeout: 10))
    }

    /// The account's own history, decoded from the shape `/ocr-history` really sends — a bare
    /// array whose jobs carry their page setup as an object. A decoder that cannot read it
    /// shows "Could not load" here instead of the row.
    func testTranslateListsTheAccountsHistory() {
        let app = signIn(launch())
        XCTAssertTrue(app.tab("More").waitForExistence(timeout: 10))
        app.tab("More").tap()
        app.buttons["Translate"].tap()
        XCTAssertTrue(app.navigationBars["Translate"].waitForExistence(timeout: 10))

        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Bakshi Order"))
            .firstMatch
        var swipes = 0
        while !row.exists, swipes < 4 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the history row did not render")
    }
}
