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
    ///
    /// On iPad the case opens beside the docket rather than over it, so there is no Back to take.
    /// Another case is chosen in the docket instead — which is also what makes the second request
    /// visible, since asking for the case already on screen would change nothing to look at — and
    /// it is that case, not the requested one, that coming back to Cases must find.
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

            if UIDevice.current.userInterfaceIdiom == .pad {
                // Beside the docket, which never left; then another case, chosen there.
                XCTAssertTrue(
                    app.navigationBars["Cases"].exists,
                    "pass \(pass): the case did not open beside the docket")
                caseRow(app, "case-hc-delhi").tap()
                XCTAssertTrue(
                    app.navigationBars["Kapoor Textiles Pvt. Ltd. v. Commissioner of Customs"]
                        .waitForExistence(timeout: 10),
                    "pass \(pass): choosing another case beside the docket did not open it")
            } else {
                // Back lands on the docket, not on whatever Cases showed before.
                matter.buttons.element(boundBy: 0).tap()
                XCTAssertTrue(
                    app.navigationBars["Cases"].waitForExistence(timeout: 10),
                    "pass \(pass): back from the case did not land on the docket")
            }

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
            ("OCR", "OCR"),
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
            // Gone, not only going. More's own bar is there behind a sheet the whole time, so it
            // does not prove the sheet has left — and the OCR screen's switch carries a button
            // named "Translate", the next row's name, until it has.
            var polls = 0
            while app.navigationBars[title].exists && polls < 40 {
                Thread.sleep(forTimeInterval: 0.25)
                polls += 1
            }
            XCTAssertFalse(app.navigationBars[title].exists, "\(row) did not close")
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
        // A folder is a tile now — one element, a button, found by its identifier, since its
        // label also carries what the folder holds.
        let folder = app.buttons["folder-Bakshi"]
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
        // The toolbar's "Add case" opens the lookup, which is titled for what it does first.
        app.buttons["Add case"].firstMatch.tap()

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
        app.buttons["Add case"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Find a case"].waitForExistence(timeout: 10))

        app.buttons["court-picker"].tap()
        XCTAssertTrue(app.navigationBars["Court"].waitForExistence(timeout: 5))

        // Filtered rather than scrolled to. The district courts sit past twenty-five High
        // Courts, and a `List` does not put off-screen rows in the accessibility tree at all —
        // so without this the row is not merely hard to reach, it does not exist to the test.
        let search = app.searchFields["Search courts"]
        XCTAssertTrue(search.waitForExistence(timeout: 5), "the picker has no search field")
        search.focusForTyping()
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
        search.focusForTyping()
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
        let conversation = app.stubConversationRow
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
        app.buttons["All tools"].firstMatch.tap()

        XCTAssertTrue(app.navigationBars["Tools"].waitForExistence(timeout: 10))
        // The five the web's own sidebar links, so the ones most likely to be opened.
        for tool in ["Devil's Advocate", "Highlighter"] {
            XCTAssertTrue(
                app.staticTexts[tool].waitForExistence(timeout: 5), "\(tool) is not listed")
        }

        // `firstMatch` throughout: an iPad draws the sheet and the screen behind it at once, so a
        // name can be on screen twice, and a bare query that finds two refuses to tap either.
        app.staticTexts["Devil's Advocate"].firstMatch.tap()
        let run = app.buttons["Run"].firstMatch
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

        app.navigationBars["Tools"].buttons["Done"].firstMatch.tap()
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
            // A card below the fold has to be scrolled to before it can be tapped.
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

    // MARK: - My Files as folders

    /// My Files opens on its folders, drawn as tiles, with no segment tapped. A tile opens its
    /// folder, which shows its own sub-folder as a tile and its documents as rows; a sub-folder's
    /// tile opens in turn; and Back returns, level by level, to the grid.
    func testMyFilesOpensOnFolderTilesThatOpenTheirFolders() {
        let app = signIn(launch())
        XCTAssertTrue(app.tab("More").waitForExistence(timeout: 10))
        app.tab("More").tap()
        app.buttons["My Files"].tap()
        XCTAssertTrue(app.navigationBars["My Files"].waitForExistence(timeout: 10))

        let bakshi = app.buttons["folder-Bakshi"]
        XCTAssertTrue(bakshi.waitForExistence(timeout: 10), "My Files did not open on its folder tiles")
        XCTAssertTrue(app.buttons["folder-Arora_Holdings"].exists, "every top-level folder is a tile")
        // One element, saying what the folder holds — counted all the way down.
        XCTAssertEqual(bakshi.label, "Bakshi, 2 documents, 1 folder")

        // A document filed in no folder stays reachable from the top, below the grid.
        let loose = app.staticTexts["Engagement Letter.pdf"]
        var swipes = 0
        while !loose.exists, swipes < 3 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(loose.waitForExistence(timeout: 5), "the document in no folder is not listed")

        bakshi.tap()
        XCTAssertTrue(app.navigationBars["Bakshi"].waitForExistence(timeout: 10), "the tile did not open its folder")
        let orders = app.buttons["folder-Bakshi/Orders"]
        XCTAssertTrue(orders.waitForExistence(timeout: 10), "the sub-folder is not drawn as a tile")
        XCTAssertTrue(
            app.staticTexts["Plaint.pdf"].waitForExistence(timeout: 5),
            "the folder's own document is not listed")

        orders.tap()
        XCTAssertTrue(app.navigationBars["Orders"].waitForExistence(timeout: 10), "the sub-folder did not open")
        XCTAssertTrue(
            app.staticTexts["Interim Order.pdf"].waitForExistence(timeout: 5),
            "the sub-folder's document is not listed")

        app.navigationBars["Orders"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Bakshi"].waitForExistence(timeout: 10), "Back did not return to Bakshi")
        app.navigationBars["Bakshi"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["My Files"].waitForExistence(timeout: 10), "Back did not return to My Files")
        XCTAssertTrue(app.buttons["folder-Bakshi"].waitForExistence(timeout: 10), "the grid is not there on return")
        XCTAssertEqual(app.state, .runningForeground)
    }

    // MARK: - Answer mode and OCR

    /// Opens the stub's stored conversation from the Chat tab.
    private func openTheStubConversation(_ app: XCUIApplication) {
        XCTAssertTrue(app.tab("Chat").waitForExistence(timeout: 10))
        app.tab("Chat").tap()
        let conversation = app.stubConversationRow
        XCTAssertTrue(conversation.waitForExistence(timeout: 10), "the conversation is not listed")
        conversation.tap()
    }

    /// Waits for an element to report itself selected, as a tap lands a frame or two later.
    /// Polled rather than waited on with an expectation, which Swift 6 refuses to compile here.
    @discardableResult
    private func becomesSelected(_ element: XCUIElement) -> Bool {
        var polls = 0
        while !element.isSelected && polls < 40 {
            Thread.sleep(forTimeInterval: 0.1)
            polls += 1
        }
        return element.isSelected
    }

    /// Quick and Thinking sit in the composer, always in sight, and one tap switches. A new
    /// account has no preferred model, so a conversation opens on Quick.
    func testTheComposerSwitchesBetweenQuickAndThinking() {
        let app = signIn(launch())
        openTheStubConversation(app)

        let quick = app.buttons["Quick"]
        let thinking = app.buttons["Thinking"]
        XCTAssertTrue(quick.waitForExistence(timeout: 10), "the composer has no mode switch")
        XCTAssertTrue(thinking.exists)
        XCTAssertTrue(quick.isSelected, "a conversation opens on the account's default, Quick")
        XCTAssertFalse(thinking.isSelected)

        thinking.tap()
        XCTAssertTrue(becomesSelected(thinking), "tapping Thinking did not select it")
        XCTAssertFalse(quick.isSelected, "both options are selected at once")

        quick.tap()
        XCTAssertTrue(becomesSelected(quick), "tapping Quick did not select it again")
        XCTAssertFalse(thinking.isSelected)
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// The toolbar's menu keeps searching the web and reporting an answer — and offers no role
    /// and no mode. A conversation is asked for in the practitioner's own role.
    func testTheOptionsMenuOffersNoRoleAndNoMode() {
        let app = signIn(launch())
        openTheStubConversation(app)

        let options = app.buttons["More options"]
        XCTAssertTrue(options.waitForExistence(timeout: 10), "the options menu is missing")
        options.tap()
        XCTAssertTrue(
            app.buttons["Report an answer"].waitForExistence(timeout: 5), "the menu did not open")
        let search = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Always search the web"))
            .firstMatch
        XCTAssertTrue(search.exists, "the web-search switch left the menu")

        // A picker in a menu is drawn either inline, as a button per choice, or as one button
        // named for the picker that opens them — so both shapes are looked for.
        XCTAssertFalse(
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Acting as"))
                .firstMatch.exists,
            "the menu still offers a role")
        for role in ["Litigator", "Corporate Counsel", "Arbitrator or Judge"] {
            XCTAssertFalse(app.buttons[role].exists, "the menu still offers \(role)")
        }
        for mode in ["Mode", "Quick —", "Thinking —"] {
            XCTAssertFalse(
                app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", mode))
                    .firstMatch.exists,
                "the mode is in the composer now, not the menu")
        }
    }

    /// More has an OCR row of its own beside Translate. It opens the shared screen on OCR —
    /// no language to choose — and the switch at its head turns it into Translate and back.
    func testOCROpensFromMoreAndItsSwitchChangesTheScreen() {
        let app = signIn(launch())
        XCTAssertTrue(app.tab("More").waitForExistence(timeout: 10))
        app.tab("More").tap()
        XCTAssertTrue(app.navigationBars["More"].waitForExistence(timeout: 10))

        let row = app.buttons["OCR"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "More has no OCR row")
        row.tap()
        XCTAssertTrue(app.navigationBars["OCR"].waitForExistence(timeout: 10), "OCR did not open")

        let modes = app.segmentedControls.firstMatch
        XCTAssertTrue(modes.waitForExistence(timeout: 5), "the OCR | Translate switch is missing")
        let ocr = modes.buttons["OCR"]
        let translate = modes.buttons["Translate"]
        XCTAssertTrue(ocr.isSelected, "opened from the OCR row, the switch is not on OCR")
        XCTAssertTrue(
            app.staticTexts["Make a scanned or photographed document searchable and editable, in its own language."]
                .exists,
            "OCR does not say what it does")
        let language = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Translate to")).firstMatch
        XCTAssertFalse(language.exists, "OCR offers a language it would never send")
        XCTAssertTrue(app.buttons["Scan with the camera"].exists, "OCR cannot scan")

        translate.tap()
        XCTAssertTrue(
            app.navigationBars["Translate"].waitForExistence(timeout: 5),
            "the switch did not turn the screen into Translate")
        XCTAssertTrue(becomesSelected(translate))
        XCTAssertTrue(language.waitForExistence(timeout: 5), "Translate lost its language")

        ocr.tap()
        XCTAssertTrue(app.navigationBars["OCR"].waitForExistence(timeout: 5), "could not switch back")
        XCTAssertTrue(becomesSelected(ocr))

        app.navigationBars["OCR"].buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["More"].waitForExistence(timeout: 10))
    }

    /// Translate, opened from its own row, opens on Translate — the same screen, other side.
    func testTranslateOpensOnTranslateWithItsSwitch() {
        let app = signIn(launch())
        XCTAssertTrue(app.tab("More").waitForExistence(timeout: 10))
        app.tab("More").tap()
        app.buttons["Translate"].tap()
        XCTAssertTrue(app.navigationBars["Translate"].waitForExistence(timeout: 10))

        let modes = app.segmentedControls.firstMatch
        XCTAssertTrue(modes.waitForExistence(timeout: 5), "the OCR | Translate switch is missing")
        XCTAssertTrue(modes.buttons["Translate"].isSelected)
        XCTAssertFalse(modes.buttons["OCR"].isSelected)
    }

    // MARK: - Cases: court headings, sort & filter, and the docket's own search

    /// The docket is headed by court, in order of importance — the stub has a matter under every
    /// heading but "Other courts". Read off the screen as it scrolls, a little at a time, because
    /// a list only builds the rows near the screen: each pass adds the headings it can see, top
    /// to bottom, and the order they were first seen in is the order they are drawn in.
    func testTheDocketIsHeadedByCourtInOrderOfImportance() {
        let app = signIn(launch())
        openCases(app)

        let headings = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "case-group-"))
        XCTAssertTrue(headings.firstMatch.waitForExistence(timeout: 10), "the docket has no headings")

        let expected = ["sc", "hc", "nclat", "nclt", "tribunal", "district", "forum"]
        var seen: [String] = []
        for _ in 0..<12 {
            let onScreen = headings.allElementsBoundByIndex
                .filter { $0.exists }
                .sorted { $0.frame.minY < $1.frame.minY }
                .map { String($0.identifier.dropFirst("case-group-".count)) }
            for key in onScreen where !seen.contains(key) {
                seen.append(key)
            }
            if seen.count >= expected.count { break }
            nudgeUp(app)
        }
        XCTAssertEqual(seen, expected, "the court headings are not in order of importance")
    }

    /// The docket has a search bar of its own, always on screen, that searches the user's own
    /// cases — by party, by a diary number — and says so when nothing matches, with a way back.
    /// Adding a case is a separate, labelled control.
    func testTheDocketsSearchBarSearchesYourOwnCases() {
        let app = signIn(launch())
        openCases(app)

        let search = app.searchFields["Search your cases"]
        XCTAssertTrue(search.waitForExistence(timeout: 10), "the docket has no search bar")
        XCTAssertTrue(app.buttons["Add case"].exists, "adding a case is not its own control")
        XCTAssertTrue(caseRow(app, "case-sc").waitForExistence(timeout: 10))

        search.focusForTyping()
        search.typeText("Kapoor")
        XCTAssertTrue(caseRow(app, "case-hc-delhi").waitForExistence(timeout: 5),
                      "the search did not find the matter by party")
        XCTAssertFalse(caseRow(app, "case-sc").exists, "the search did not narrow the docket")
        XCTAssertFalse(caseRow(app, "case1").exists, "the search did not narrow the docket")

        search.buttons["Clear text"].tap()
        search.focusForTyping()
        search.typeText("41207/2025")
        XCTAssertTrue(caseRow(app, "case-sc").waitForExistence(timeout: 5),
                      "the search did not find the matter by diary number")
        XCTAssertFalse(caseRow(app, "case-hc-delhi").exists)

        search.buttons["Clear text"].tap()
        search.focusForTyping()
        search.typeText("zzzz")
        let clear = app.buttons["case-no-matches-clear"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5), "nothing matching does not say so")
        clear.tap()
        XCTAssertTrue(caseRow(app, "case1").waitForExistence(timeout: 5),
                      "clearing did not bring the docket back")
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// Choosing a sort, a grouping and a court filter changes the docket; the filter shows as a
    /// chip and on the toolbar button; Clear all brings every court back.
    func testSortingAndFilteringChangeTheDocketAndClearAllRestoresIt() {
        let app = signIn(launch())
        openCases(app)

        let arrange = app.buttons["case-sort-filter"]
        XCTAssertTrue(arrange.waitForExistence(timeout: 10), "there is no sort & filter control")
        XCTAssertTrue(caseRow(app, "case-sc").waitForExistence(timeout: 10))
        XCTAssertEqual(arrange.value as? String, "No filters")

        arrange.tap()
        XCTAssertTrue(app.navigationBars["Sort & filter"].waitForExistence(timeout: 5),
                      "the sort & filter sheet did not open")
        app.buttons["Name A–Z"].firstMatch.tap()
        let ungrouped = app.segmentedControls.buttons["None"]
        revealInArrangementSheet(ungrouped, app)
        ungrouped.tap()
        let highCourts = app.buttons["case-filter-court-hc"]
        revealInArrangementSheet(highCourts, app)
        highCourts.tap()
        app.navigationBars["Sort & filter"].buttons["Done"].tap()

        // One heading, High Courts only, by name: Bakshi, Kapoor, Lakshmi.
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "case-group-all").firstMatch
                .waitForExistence(timeout: 5),
            "choosing no grouping did not make one list")
        let rows = ["case1", "case-hc-delhi", "case-hc-madras"].map { caseRow(app, $0) }
        for row in rows {
            XCTAssertTrue(row.waitForExistence(timeout: 5), "a High Court matter is missing")
        }
        XCTAssertLessThan(rows[0].frame.minY, rows[1].frame.minY, "not sorted by name")
        XCTAssertLessThan(rows[1].frame.minY, rows[2].frame.minY, "not sorted by name")
        XCTAssertFalse(caseRow(app, "case-sc").exists, "the court filter did not apply")

        let chip = app.buttons["case-filter-chip-court-hc"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "the filter is not shown as a chip")
        XCTAssertEqual(arrange.value as? String, "1 filter on")

        app.buttons["case-filters-clear-all"].tap()
        // Creditors… (NCLAT) is second by name, so it is on screen on any device.
        XCTAssertTrue(caseRow(app, "case-nclat").waitForExistence(timeout: 5),
                      "Clear all did not bring the other courts back")
        XCTAssertFalse(chip.exists, "the chip outlived its filter")
        XCTAssertEqual(arrange.value as? String, "No filters")
    }

    /// A filter that hides every case says so, rather than showing a blank list, and its Clear
    /// brings them back.
    func testAFilterThatHidesEverythingSaysSoAndCanBeCleared() {
        let app = signIn(launch())
        openCases(app)

        let arrange = app.buttons["case-sort-filter"]
        XCTAssertTrue(arrange.waitForExistence(timeout: 10))
        arrange.tap()
        XCTAssertTrue(app.navigationBars["Sort & filter"].waitForExistence(timeout: 5))
        // The Supreme Court matter came from the court, so "Added by hand" leaves nothing.
        for filter in ["case-filter-court-sc", "case-filter-source-manual"] {
            let row = app.buttons[filter]
            revealInArrangementSheet(row, app)
            row.tap()
        }
        app.navigationBars["Sort & filter"].buttons["Done"].tap()

        XCTAssertTrue(app.staticTexts["No cases match these filters"].waitForExistence(timeout: 5),
                      "a filtered-out docket did not say so")
        let clear = app.buttons["case-no-matches-clear"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.tap()
        XCTAssertTrue(caseRow(app, "case-sc").waitForExistence(timeout: 5),
                      "Clear did not bring the docket back")
    }

    private func openCases(_ app: XCUIApplication) {
        XCTAssertTrue(app.tab("Cases").waitForExistence(timeout: 10))
        app.tab("Cases").tap()
        XCTAssertTrue(app.navigationBars["Cases"].waitForExistence(timeout: 10))
    }

    /// A docket row, by the case's id — its label is the whole row read aloud.
    private func caseRow(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "case-row-\(id)").firstMatch
    }

    /// Scrolls the docket by about a third of the screen, slowly and without a fling, so no
    /// heading can pass from below the screen to above it between two looks.
    ///
    /// On iPad the drag is made inside the docket's own list: the middle of the window is in the
    /// column beside it, where the case opens, and a drag there scrolls nothing in the docket.
    private func nudgeUp(_ app: XCUIApplication) {
        let docket = app.collectionViews["case-docket"]
        let surface = UIDevice.current.userInterfaceIdiom == .pad && docket.exists
            ? docket : app.windows.firstMatch
        let from = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        let to = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.2)
    }

    /// The sheet opens at half height on a phone, with the filters below the fold: pull it to
    /// full height by its bar, then scroll inside it until the row can be tapped.
    private func revealInArrangementSheet(_ element: XCUIElement, _ app: XCUIApplication) {
        // Dragged inside the sheet's own list, from low in it to higher up. A drag that starts on
        // the sheet's bar or edge moves the sheet itself — it resized a half-height sheet and then
        // pulled it back down, so the row was never reached — and the docket behind it is a list
        // too, so the sheet's is found by name (the last list on screen, failing that).
        let named = app.collectionViews["case-arrangement-form"]
        let form = named.waitForExistence(timeout: 5)
            ? named : app.collectionViews.allElementsBoundByIndex.last ?? named
        var tries = 0
        while !(element.exists && element.isHittable), tries < 8 {
            let start = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            let end = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow,
                        thenHoldForDuration: 0.2)
            Thread.sleep(forTimeInterval: 0.3)
            tries += 1
        }
        XCTAssertTrue(element.exists && element.isHittable, "\(element) is not reachable in the sheet")
    }

    // MARK: - Notifications

    /// Settings → Notifications opens, is off until asked for, and turning it on shows the
    /// hearing reminders, updates and a test. In UI-test mode the app answers as a device that was
    /// asked and said yes — no real permission prompt, no real notification.
    ///
    /// The account's email switch is turned on and off against the stub, which remembers it for
    /// the run: the screen re-reads `/notif/status` after each change, so the switch only stays on
    /// if that read-back decodes.
    func testNotificationSettingsOpenAndShowTheirControls() {
        let app = signIn(launch())
        XCTAssertTrue(app.tab("More").waitForExistence(timeout: 10))
        app.tab("More").tap()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))

        let row = app.buttons["notifications-settings"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Settings has no Notifications row")
        scrollUntilHittable(row, in: app)
        row.tap()
        XCTAssertTrue(app.navigationBars["Notifications"].waitForExistence(timeout: 10))

        let allow = app.switches["notifications-allow"].firstMatch
        XCTAssertTrue(allow.waitForExistence(timeout: 10), "no master switch")
        XCTAssertEqual(allow.value as? String, "0", "off until the person turns it on")
        XCTAssertFalse(app.switches["notifications-briefing"].exists)

        flip(allow, to: "1")
        XCTAssertTrue(
            app.switches["notifications-briefing"].firstMatch.waitForExistence(timeout: 10),
            "turning notifications on did not show the hearing reminders")
        XCTAssertTrue(app.switches["notifications-evening"].firstMatch.exists)
        XCTAssertTrue(
            app.descendants(matching: .any)["notifications-briefing-time"].firstMatch.exists,
            "no briefing time")

        let test = app.buttons["notifications-test"].firstMatch
        XCTAssertTrue(test.waitForExistence(timeout: 5))
        test.tap()
        XCTAssertTrue(
            app.staticTexts["notifications-notice"].firstMatch.waitForExistence(timeout: 5),
            "the test did not say it was sent")

        let updates = app.switches["notifications-updates"].firstMatch
        scrollUntilHittable(updates, in: app)
        XCTAssertTrue(updates.exists, "no updates switch")

        // The account's email, lowest on the screen — scrolled to before it is looked for, since
        // a row below the fold does not exist yet.
        let email = app.switches["notifications-email"].firstMatch
        scrollUntilHittable(email, in: app)
        XCTAssertTrue(email.waitForExistence(timeout: 10), "the email switch did not load")
        XCTAssertEqual(email.value as? String, "0")
        flip(email, to: "1")
        let testEmail = app.buttons["notifications-test-email"].firstMatch
        scrollUntilHittable(testEmail, in: app)
        XCTAssertTrue(
            testEmail.waitForExistence(timeout: 5), "a test email is offered once the email is on")
        scrollUntilHittable(email, in: app)
        flip(email, to: "0")
        XCTAssertTrue(app.navigationBars["Notifications"].exists)

        // And back out to Settings, intact.
        app.navigationBars["Notifications"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
    }

    /// Swipes until an element lower on the screen can be tapped — a list builds only the rows it
    /// shows, and on a phone these start below the fold.
    private func scrollUntilHittable(_ element: XCUIElement, in app: XCUIApplication) {
        var swipes = 0
        while !(element.exists && element.isHittable) && swipes < 6 {
            app.swipeUp()
            swipes += 1
        }
    }

    /// Turns a switch and waits for it to read `value`.
    ///
    /// A SwiftUI `Toggle` in a list is one element covering the whole row, and tapping its middle
    /// lands on the label, which does not turn it. The switch itself is a child element on recent
    /// iOS; where it is not, the trailing edge of the row is where it is drawn.
    private func flip(_ toggle: XCUIElement, to value: String) {
        let inner = toggle.switches.firstMatch
        if inner.exists {
            inner.tap()
        } else {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        }
        var polls = 0
        while (toggle.value as? String) != value && polls < 40 {
            Thread.sleep(forTimeInterval: 0.25)
            polls += 1
        }
        XCTAssertEqual(toggle.value as? String, value, "the switch did not turn")
    }

    // MARK: - iPad layouts

    /// On iPad the docket stays on screen beside the case it opens. Before anything is chosen the
    /// case's column says what it is for; a row opens its case there, beside the docket and
    /// marked as the open one; and choosing another row **replaces** the case — the first is
    /// gone, not pushed under the second.
    ///
    /// `/case` answers each docket matter as itself (`UITestSupport.Fixtures.itemBody`), so the
    /// second case reads differently from the first.
    func testOnIPadTheDocketStaysBesideTheCaseItOpens() throws {
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        try XCTSkipUnless(isPad, "the docket beside its case is iPad's layout")
        let app = signIn(launch())
        openCases(app)

        XCTAssertTrue(
            app.staticTexts["Choose a case"].waitForExistence(timeout: 10),
            "with nothing chosen, the case's column does not say what it is for")

        let bakshi = caseRow(app, "case1")
        let kapoor = caseRow(app, "case-hc-delhi")
        XCTAssertTrue(bakshi.waitForExistence(timeout: 10), "the docket is not listed")
        bakshi.tap()

        let bakshiBar = app.navigationBars["Bakshi v. State of Maharashtra"]
        XCTAssertTrue(bakshiBar.waitForExistence(timeout: 10), "the case did not open")
        let overview = app.staticTexts.matching(
            NSPredicate(format: "label ==[c] %@", "Overview")).firstMatch
        XCTAssertTrue(overview.waitForExistence(timeout: 10), "the case did not open on its overview")

        // Both on screen at once: the docket — its title, its search, its other matters — and,
        // to the right of it, the case.
        XCTAssertTrue(app.navigationBars["Cases"].exists, "the docket left the screen")
        XCTAssertTrue(app.searchFields["Search your cases"].exists, "the docket's search left the screen")
        XCTAssertTrue(kapoor.exists, "the rest of the docket left the screen")
        XCTAssertLessThanOrEqual(
            bakshi.frame.maxX, overview.frame.minX,
            "the docket and the case are not side by side")
        XCTAssertFalse(app.staticTexts["Choose a case"].exists, "the placeholder outlived the choice")
        XCTAssertTrue(becomesSelected(bakshi), "the open case's row is not marked as open")

        kapoor.tap()
        XCTAssertTrue(
            app.navigationBars["Kapoor Textiles Pvt. Ltd. v. Commissioner of Customs"]
                .waitForExistence(timeout: 10),
            "choosing another case did not open it")
        XCTAssertTrue(
            disappears(bakshiBar),
            "the first case is still on screen — the second was pushed over it, not put in its place")
        XCTAssertTrue(becomesSelected(kapoor), "the newly open case's row is not marked")
        XCTAssertFalse(bakshi.isSelected, "two rows are marked as open at once")
        XCTAssertTrue(app.navigationBars["Cases"].exists, "the docket left the screen")
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// The same for Chat: a conversation opens beside the list, another replaces it, and a new
    /// one opens in that same column with the list still there and no row marked — a new
    /// conversation is in no row until its first turn is stored.
    ///
    /// `c2` answers `/messages` with an exchange of its own; `c1`'s carries the work log.
    func testOnIPadAConversationOpensBesideTheList() throws {
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        try XCTSkipUnless(isPad, "the list beside its conversation is iPad's layout")
        let app = signIn(launch())
        XCTAssertTrue(app.tab("Chat").waitForExistence(timeout: 10))
        app.tab("Chat").tap()
        XCTAssertTrue(app.navigationBars["Emperor"].waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.staticTexts["Choose a conversation"].waitForExistence(timeout: 10),
            "with nothing chosen, the conversation's column does not say what it is for")

        let first = chatRow(app, "c1")
        let second = chatRow(app, "c2")
        XCTAssertTrue(first.waitForExistence(timeout: 10), "the conversations are not listed")
        first.tap()

        let worked = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Worked")).firstMatch
        XCTAssertTrue(worked.waitForExistence(timeout: 10), "the conversation did not open")
        XCTAssertTrue(app.navigationBars["Emperor"].exists, "the list left the screen")
        XCTAssertTrue(second.exists, "the rest of the list left the screen")
        XCTAssertLessThanOrEqual(
            first.frame.maxX, worked.frame.minX,
            "the list and the conversation are not side by side")
        XCTAssertTrue(becomesSelected(first), "the open conversation's row is not marked as open")

        second.tap()
        // Read as "You asked: …", so matched on the question inside the label.
        let secondQuestion = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@",
            "Can the Customs order in Kapoor Textiles be stayed pending the writ?")).firstMatch
        XCTAssertTrue(
            secondQuestion.waitForExistence(timeout: 10),
            "choosing another conversation did not open it")
        XCTAssertTrue(
            disappears(worked),
            "the first conversation is still on screen — the second was pushed over it")
        XCTAssertTrue(becomesSelected(second), "the newly open conversation's row is not marked")
        XCTAssertFalse(first.isSelected, "two rows are marked as open at once")

        // A new conversation, from the list's own button, takes the same column.
        app.buttons["New chat"].firstMatch.tap()
        XCTAssertTrue(
            disappears(secondQuestion), "a new conversation did not take the open one's place")
        XCTAssertTrue(app.navigationBars["Conversation"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["Emperor"].exists, "the list left the screen")
        XCTAssertFalse(second.isSelected, "a row is still marked for a conversation no longer open")
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// A conversation in the list, by its id.
    private func chatRow(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "chat-row-\(id)").firstMatch
    }

    /// Waits for an element to leave the screen — a replaced column is taken down over an
    /// animation, not at once. Polled, as `becomesSelected` is.
    private func disappears(_ element: XCUIElement) -> Bool {
        var polls = 0
        while element.exists && polls < 40 {
            Thread.sleep(forTimeInterval: 0.25)
            polls += 1
        }
        return !element.exists
    }

    // MARK: - App lock

    /// Settings → Security: the switch, named for what this device asks for, and — once it is on
    /// — how long the app may be away. In UI-test mode a stand-in answers for Face ID and
    /// recognises every face, so the real `LAContext` is never touched; and every launch starts
    /// with the lock off, so turning it on here is turning it on from off.
    func testSecuritySettingsShowTheLockAndItsTimeout() {
        let app = signIn(launch())
        XCTAssertTrue(app.tab("More").waitForExistence(timeout: 10))
        app.tab("More").tap()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))

        // Below Plan & usage, so off screen on a phone until scrolled to — and then raised well
        // into view, not left on the bottom edge where the swipe first finds it. The timeout row
        // appears *beneath* the switch, and a list builds no row it is not showing: with the switch
        // on the last visible line, the row is never built and cannot be found.
        let toggle = app.switches["app-lock-toggle"].firstMatch
        scrollUntilHittable(toggle, in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "Settings has no Security section")
        appLockRaise(toggle, in: app)
        XCTAssertTrue(
            toggle.label.contains("Require Face ID"),
            "the switch is not named for the device: \(toggle.label)")
        XCTAssertEqual(toggle.value as? String, "0", "the lock is off until turned on")
        let timeout = app.descendants(matching: .any)["app-lock-timeout"].firstMatch
        XCTAssertFalse(timeout.exists, "a timeout is offered while the lock is off")

        // On — the stand-in confirms it is the owner — and the timeout appears, at a minute.
        flip(toggle, to: "1")
        XCTAssertTrue(
            timeout.waitForExistence(timeout: 10), "turning the lock on offered no timeout")
        scrollUntilHittable(timeout, in: app)
        XCTAssertTrue(
            appLockWait { self.appLockShows(app, "After 1 minute") },
            "the timeout does not start at a minute")

        // Another choice, from its menu.
        timeout.tap()
        let five = app.buttons["After 5 minutes"].firstMatch
        XCTAssertTrue(five.waitForExistence(timeout: 5), "the timeout's choices did not open")
        five.tap()
        XCTAssertTrue(
            appLockWait { self.appLockShows(app, "After 5 minutes") }, "the choice did not stick")

        // And off again, which takes the timeout with it.
        scrollUntilHittable(toggle, in: app)
        flip(toggle, to: "0")
        XCTAssertTrue(appLockWait { !timeout.exists }, "the timeout outlived the lock")
    }

    /// `-UITestAppLock`: the lock on, and someone already signed in on the device — a cold start
    /// with a session, which is when the lock is for. The app opens behind the lock with nothing
    /// behind it reachable, and Unlock reveals it.
    func testTheAppOpensLockedAndUnlockRevealsIt() {
        let app = launch("-UITestAppLock")
        let unlock = app.buttons["app-lock-unlock"]
        XCTAssertTrue(unlock.waitForExistence(timeout: 15), "the app did not open locked")
        XCTAssertTrue(app.staticTexts["Emperor is locked"].exists)
        XCTAssertFalse(app.tab("Home").exists, "the tabs were reachable behind the lock")
        XCTAssertFalse(app.textFields["Email"].exists, "a session on the device opened on sign-in")

        unlock.tap()
        XCTAssertTrue(
            app.tab("Home").waitForExistence(timeout: 10), "unlocking did not reveal the app")
        XCTAssertTrue(appLockWait { !unlock.exists }, "the lock stayed up")
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// Away and back: `-UITestAppLock` sets the lock to Immediately, so leaving for the Home
    /// Screen and returning locks the app again.
    func testReturningToTheAppLocksItAgain() {
        let app = launch("-UITestAppLock")
        let unlock = app.buttons["app-lock-unlock"]
        XCTAssertTrue(unlock.waitForExistence(timeout: 15), "the app did not open locked")
        unlock.tap()
        XCTAssertTrue(app.tab("Home").waitForExistence(timeout: 10))

        // To the Home Screen. The Home button press alone did not background the app on the
        // iOS 26 runners, so if the app is still in front a moment later, bringing SpringBoard
        // forward does the same thing a person's swipe home does.
        XCUIDevice.shared.press(.home)
        if !appLockWait(5, { app.state != .runningForeground }) {
            XCUIApplication(bundleIdentifier: "com.apple.springboard").activate()
        }
        XCTAssertTrue(
            appLockWait(10) { app.state != .runningForeground }, "the app did not leave")
        app.activate()

        XCTAssertTrue(
            app.buttons["app-lock-unlock"].waitForExistence(timeout: 10),
            "coming back did not lock the app")
        XCTAssertFalse(app.tab("Home").exists, "the tabs were reachable behind the lock")
        app.buttons["app-lock-unlock"].tap()
        XCTAssertTrue(
            app.tab("Home").waitForExistence(timeout: 10), "unlocking again did not reveal the app")
    }

    /// Drags the list holding `element` until the element sits in its upper half, so a row that
    /// appears beneath it is on screen — and so built — at once. Slow drags, not swipes: a swipe's
    /// momentum can carry the element off the top. Stops early where the list ends.
    private func appLockRaise(_ element: XCUIElement, in app: XCUIApplication) {
        let list = app.collectionViews.containing(.any, identifier: element.identifier).firstMatch
        guard list.exists else { return }
        for _ in 0..<6 {
            guard element.exists, element.frame.minY > list.frame.midY else { return }
            let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            let end = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow,
                        thenHoldForDuration: 0.2)
            Thread.sleep(forTimeInterval: 0.3)
        }
    }

    /// Whether the timeout row reads `text` — as its value, in its label, or as a text of its own,
    /// since a menu picker in a list is drawn differently from one iOS to the next. Not as a
    /// button: an item of the still-open menu is one, and would pass for the row.
    private func appLockShows(_ app: XCUIApplication, _ text: String) -> Bool {
        let timeout = app.descendants(matching: .any)["app-lock-timeout"].firstMatch
        if timeout.exists {
            if let value = timeout.value as? String, value.contains(text) { return true }
            if timeout.label.contains(text) { return true }
        }
        return app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text))
            .firstMatch.exists
    }

    /// Polls `condition` until it holds or `seconds` pass. `waitForExpectations` sends the test
    /// case across actors, which Swift 6 refuses to compile here.
    private func appLockWait(_ seconds: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return condition()
    }

    // MARK: - Profile, documents shared in, and search

    /// Settings → Edit profile opens on the account as it is, and a save reaches the server and
    /// comes back: the stub echoes the account it was sent, and Settings shows the new name and
    /// title from the session — not from the form.
    func testEditingTheProfileSavesItAndSettingsShowsIt() {
        let app = signIn(launch())
        XCTAssertTrue(app.tab("More").waitForExistence(timeout: 10))
        app.tab("More").tap()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))

        let edit = app.buttons["edit-profile"].firstMatch
        scrollUntilHittable(edit, in: app)
        XCTAssertTrue(edit.waitForExistence(timeout: 10), "Settings has no Edit profile row")
        edit.tap()
        XCTAssertTrue(app.navigationBars["Edit profile"].waitForExistence(timeout: 10))

        let name = app.textFields["profile-name"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 10), "no name field")
        XCTAssertEqual(name.value as? String, "John Doe", "the form starts from the account")
        XCTAssertFalse(app.buttons["profile-save"].firstMatch.isEnabled, "nothing to save yet")

        // The cursor lands at the end of a short name in a wide field; a few deletes more than
        // the name has are harmless.
        name.focusForTyping()
        let typed = (name.value as? String) ?? ""
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: typed.count + 4))
        name.typeText("John Q. Doe")

        // Found by identifier, not as a text field: the title wraps, and a field that wraps can
        // be reported as a text view.
        let title = app.descendants(matching: .any).matching(identifier: "profile-title").firstMatch
        XCTAssertTrue(title.exists, "no title field")
        title.focusForTyping()
        title.typeText("Advocate, Bombay High Court")

        let save = app.buttons["profile-save"].firstMatch
        XCTAssertTrue(save.isEnabled, "a real change can be saved")
        save.tap()

        XCTAssertTrue(
            app.navigationBars["Settings"].waitForExistence(timeout: 10),
            "saving did not return to Settings")
        let account = app.descendants(matching: .any)["account-profile"].firstMatch
        XCTAssertTrue(account.waitForExistence(timeout: 10), "Settings has no account header")
        var polls = 0
        while !account.label.contains("John Q. Doe") && polls < 40 {
            Thread.sleep(forTimeInterval: 0.25)
            polls += 1
        }
        XCTAssertTrue(account.label.contains("John Q. Doe"), "Settings did not show the saved name")
        XCTAssertTrue(
            account.label.contains("Advocate, Bombay High Court"), "Settings did not show the title")
    }

    /// A document handed to the app before anyone signs in waits for sign-in, then opens "Save to
    /// My Files" on its own name; choosing a folder and saving reaches the stub's upload route.
    ///
    /// The document is handed over by `-UITestIncomingDocument`, through the same handler
    /// `onOpenURL` calls — a UI test cannot drive another app's "Open in".
    func testADocumentHandedToTheAppIsSavedToMyFiles() {
        let app = launch("-UITestIncomingDocument")
        XCTAssertTrue(app.textFields["Email"].waitForExistence(timeout: 10))
        XCTAssertFalse(
            app.navigationBars["Save to My Files"].exists, "nothing is asked before sign-in")
        signIn(app)

        let bar = app.navigationBars["Save to My Files"]
        XCTAssertTrue(bar.waitForExistence(timeout: 15), "the document was not offered after sign-in")
        let name = app.textFields["incoming-name"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5), "no name field")
        XCTAssertEqual(name.value as? String, "Sample Order", "named as it arrived, type aside")

        let folder = app.buttons["incoming-folder"].firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 5), "no folder choice")
        folder.tap()
        let bakshi = app.buttons["incoming-folder-Bakshi"].firstMatch
        XCTAssertTrue(bakshi.waitForExistence(timeout: 10), "the library's folders were not offered")
        XCTAssertTrue(app.buttons["incoming-folder-Bakshi/Orders"].firstMatch.exists, "sub-folders too")
        bakshi.tap()
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "choosing a folder did not return to the form")

        let save = app.buttons["incoming-save"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()
        XCTAssertTrue(
            app.staticTexts["Uploading to Bakshi"].firstMatch.waitForExistence(timeout: 15),
            "saving did not reach the upload")

        app.buttons["incoming-done"].firstMatch.tap()
        var polls = 0
        while bar.exists && polls < 40 {
            Thread.sleep(forTimeInterval: 0.25)
            polls += 1
        }
        XCTAssertFalse(bar.exists, "the sheet did not close once the last document was saved")
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// "Don't save" lets a document go without uploading it, and the sheet closes.
    func testADocumentHandedToTheAppCanBeLetGo() {
        let app = signIn(launch("-UITestIncomingDocument"))
        let bar = app.navigationBars["Save to My Files"]
        XCTAssertTrue(bar.waitForExistence(timeout: 15), "the document was not offered")
        app.buttons["incoming-dont-save"].firstMatch.tap()
        var polls = 0
        while bar.exists && polls < 40 {
            Thread.sleep(forTimeInterval: 0.25)
            polls += 1
        }
        XCTAssertFalse(bar.exists)
        XCTAssertTrue(app.tab("Home").exists)
    }

    /// Settings → Search: "Show in Spotlight search", on by default, and it turns.
    func testTheSpotlightSwitchIsInSettings() {
        let app = signIn(launch())
        XCTAssertTrue(app.tab("More").waitForExistence(timeout: 10))
        app.tab("More").tap()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))

        let toggle = app.switches["spotlight-toggle"].firstMatch
        scrollUntilHittable(toggle, in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "Settings has no Spotlight switch")
        XCTAssertEqual(toggle.value as? String, "1", "on until turned off")
        flip(toggle, to: "0")
        flip(toggle, to: "1")
    }

    // MARK: - Opening a day from outside: the Today widget, links and notification taps

    /// `emperor://calendar?day=…` — what the Today widget opens, and the path a tapped hearing
    /// reminder takes — lands on the Calendar **on that day**: its cell selected and its listing
    /// below. Two days ahead, where the stub's docket lists the Delhi matter. Then a bare
    /// `emperor://calendar` moves it back to today.
    ///
    /// Each link arrives as the app comes back from the background (`-UITestLinkOnReturn`), which
    /// is how a widget's tap reaches an app that is already running — see
    /// `UITestSupport.takeLinkOnReturn` for why not `XCUIApplication.open(_:)`.
    func testALinkOpensTheCalendarOnItsDay() {
        let day = Self.indianDay(daysFromNow: 2)
        let app = signIn(launch(
            "-UITestLinkOnReturn", "emperor://calendar?day=\(day.key)",
            "-UITestLinkOnReturn", "emperor://calendar"))
        XCTAssertTrue(app.tab("Home").waitForExistence(timeout: 10), "signing in did not reach Home")

        leaveAndReturn(app)
        XCTAssertTrue(
            app.navigationBars["Calendar"].waitForExistence(timeout: 10),
            "the link did not open the Calendar")
        XCTAssertTrue(
            becomesSelected(app.tab("Calendar")), "the Calendar opened but its tab is not selected")
        let cell = dayCell(day.label, in: app)
        XCTAssertTrue(cell.waitForExistence(timeout: 10), "the month shown does not hold the day")
        XCTAssertTrue(becomesSelected(cell), "the Calendar did not open on the day the link named")
        XCTAssertTrue(
            app.buttons["calendar-listing-case-hc-delhi"].waitForExistence(timeout: 10),
            "the day's listing is not shown")

        leaveAndReturn(app)
        let today = dayCell(Self.indianDay(daysFromNow: 0).label, in: app)
        XCTAssertTrue(today.waitForExistence(timeout: 10), "today is not in the month shown")
        XCTAssertTrue(becomesSelected(today), "a link with no day did not open on today")
        // Still in the grid unless the two days fall in different months.
        if cell.exists {
            XCTAssertFalse(cell.isSelected, "the day the first link named is still selected")
        }
    }

    /// A day's cell in the Calendar's month. Today's is read out as "Today, …" — so it is found by
    /// either form of its label, not by the date alone.
    private func dayCell(_ label: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "label == %@ OR label == %@", label, "Today, \(label)")
        ).firstMatch
    }

    /// An update tapped while a sheet is open — here the Calendar's Subscribe sheet — must not be
    /// lost, and must not take the person's sheet away: Updates waits, and appears over Home the
    /// moment that sheet is closed. `emperor://updates` takes the same path a tapped update does,
    /// and arrives as the app comes back to the front, the privacy cover lifting as it does.
    func testUpdatesWaitForTheOpenSheetThenAppear() {
        let app = signIn(launch("-UITestLinkOnReturn", "emperor://updates"))
        XCTAssertTrue(app.tab("Calendar").waitForExistence(timeout: 10))
        app.tab("Calendar").tap()
        XCTAssertTrue(app.navigationBars["Calendar"].waitForExistence(timeout: 10))
        app.navigationBars["Calendar"].buttons["Subscribe"].tap()
        let subscribe = app.navigationBars["Subscribe"]
        XCTAssertTrue(subscribe.waitForExistence(timeout: 10))

        leaveAndReturn(app)
        XCTAssertTrue(subscribe.waitForExistence(timeout: 10), "the open sheet was taken away")
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(subscribe.exists, "the open sheet was taken away")
        XCTAssertFalse(
            app.navigationBars["Updates"].exists, "Updates was put over the open sheet")

        subscribe.buttons["Done"].tap()
        let updates = app.navigationBars["Updates"]
        XCTAssertTrue(
            updates.waitForExistence(timeout: 10), "Updates never followed once the sheet closed")

        updates.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tab("Home").isSelected, "Updates opens over Home, where its bell is")
    }

    /// Sends the app to the background and brings it back — the moment a link handed over with
    /// `-UITestLinkOnReturn` is opened. The Home button as the app-lock tests press it, with
    /// SpringBoard brought forward if the press alone does not move the app off screen.
    private func leaveAndReturn(_ app: XCUIApplication) {
        XCUIDevice.shared.press(.home)
        if !Self.poll(5, { app.state != .runningForeground }) {
            XCUIApplication(bundleIdentifier: "com.apple.springboard").activate()
        }
        XCTAssertTrue(Self.poll(10) { app.state != .runningForeground }, "the app did not leave")
        app.activate()
        XCTAssertTrue(
            Self.poll(10) { app.state == .runningForeground }, "the app did not come back")
    }

    /// Polls `condition` until it holds or `seconds` pass — an expectation would not compile
    /// in this target under Swift 6.
    private static func poll(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return condition()
    }

    /// A day `days` from now in India: its `YYYY-MM-DD` key, and the label its Calendar cell
    /// carries (`DisplayText.longDay`).
    private static func indianDay(daysFromNow days: Int) -> (key: String, label: String) {
        let date = Date().addingTimeInterval(TimeInterval(days) * 86_400)
        let india = TimeZone(identifier: "Asia/Kolkata") ?? .current
        let key = DateFormatter()
        key.dateFormat = "yyyy-MM-dd"
        key.timeZone = india
        key.locale = Locale(identifier: "en_US_POSIX")
        let label = DateFormatter()
        label.dateFormat = "EEEE, d MMMM yyyy"
        label.timeZone = india
        return (key.string(from: date), label.string(from: date))
    }

    // MARK: - Offline reading

    /// Waits for the stub's stored answer to be drawn — its work-log panel is the first thing in
    /// it — so a test knows the conversation has loaded and been kept.
    private func waitForTheStoredAnswer(_ app: XCUIApplication) -> Bool {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Worked")).firstMatch
            .waitForExistence(timeout: 10)
    }

    /// The list sits beside the conversation — an iPad at full width — rather than under it.
    private var listIsBesideConversation: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    /// Back from the conversation to the list, by the bar's leading button — see
    /// `testAToolOpensItsFormAndCanBeRun` for why it is not found by its label. A phone only: on
    /// an iPad the list is already in sight beside the conversation, and that bar's leading
    /// button is not a way back.
    private func leaveTheConversation(_ app: XCUIApplication) {
        guard !listIsBesideConversation else { return }
        let bar = app.navigationBars["Conversation"]
        XCTAssertTrue(bar.waitForExistence(timeout: 10))
        bar.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(
            app.stubConversationRow.waitForExistence(timeout: 10),
            "leaving the conversation did not return to the list")
    }

    /// Opens the stub conversation again, so that it loads a second time.
    ///
    /// On a phone: back to the list, and in again. On an iPad the conversation opens beside the
    /// list with its row selected, and choosing the selected row again opens nothing — so the
    /// list's other conversation is opened first, and the stub's chosen after it, which replaces
    /// the column and loads it afresh.
    private func reopenTheStubConversation(_ app: XCUIApplication) {
        if listIsBesideConversation {
            let other = app.buttons["chat-row-c2"].firstMatch
            XCTAssertTrue(other.waitForExistence(timeout: 10), "no other conversation to open")
            other.tap()
            XCTAssertTrue(becomesSelected(other), "the other conversation did not open")
        } else {
            leaveTheConversation(app)
        }
        app.stubConversationRow.tap()
    }

    /// `-UITestOffline` lets every route answer once and then fails it as a phone with no signal
    /// does. A conversation opened once therefore reopens from the copy kept on the device: the
    /// stored answer is there, the bar above the composer says it is the saved copy and how old,
    /// and a question typed into the composer cannot be sent — a saved copy is never posted back.
    func testAConversationOpenedOnceReopensOfflineAndCannotBeAskedFrom() {
        let app = signIn(launch("-UITestOffline"))
        openTheStubConversation(app)
        XCTAssertTrue(waitForTheStoredAnswer(app), "the conversation did not load the first time")
        XCTAssertFalse(app.staticTexts["offline-notice"].exists, "online, there is no notice")

        reopenTheStubConversation(app)

        let notice = app.staticTexts["offline-notice"].firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 10), "reopened offline with no notice")
        XCTAssertTrue(
            notice.label.hasPrefix("Offline — showing the copy saved"),
            "the notice does not say what it is: \(notice.label)")
        XCTAssertTrue(waitForTheStoredAnswer(app), "the saved copy's answer is not drawn")

        // Typed, so that only the offline rule can be what holds the send back.
        let placeholder = "Ask about this matter…"
        let field = app.textViews[placeholder].exists
            ? app.textViews[placeholder] : app.textFields[placeholder]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no composer")
        field.focusForTyping()
        field.typeText("Is the limitation extendable?")
        XCTAssertFalse(app.buttons["Send"].firstMatch.isEnabled, "a saved copy must not be asked from")
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// Settings → Storage counts what was kept — here, the conversation just opened — and
    /// clearing it asks first and then leaves nothing.
    func testSettingsStorageShowsWhatIsKeptAndClearsIt() {
        let app = signIn(launch())
        openTheStubConversation(app)
        XCTAssertTrue(waitForTheStoredAnswer(app))
        leaveTheConversation(app)

        XCTAssertTrue(app.tab("More").waitForExistence(timeout: 10))
        app.tab("More").tap()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))

        let size = app.staticTexts["offline-storage-size"].firstMatch
        scrollUntilHittable(size, in: app)
        XCTAssertTrue(size.waitForExistence(timeout: 10), "Settings has no Storage row")
        XCTAssertNotEqual(size.label, "None", "the conversation just opened was not counted")

        let clear = app.buttons["offline-storage-clear"].firstMatch
        scrollUntilHittable(clear, in: app)
        clear.tap()
        // A confirmation dialog: a sheet on iPhone, a popover on iPad.
        let confirm = [app.sheets, app.popovers, app.alerts]
            .map { $0.buttons["Clear offline copies"] }
            .first { $0.waitForExistence(timeout: 3) }
        XCTAssertNotNil(confirm, "clearing did not ask first")
        confirm?.tap()

        var polls = 0
        while size.label != "None" && polls < 20 {
            Thread.sleep(forTimeInterval: 0.25)
            polls += 1
        }
        XCTAssertEqual(size.label, "None")
    }
}
