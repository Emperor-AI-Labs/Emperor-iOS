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
///
/// The app is the redesign's five tabs — **Home · Matters · Ask · Calendar · More**
/// (`MainTabView`). The Calendar is a tab of its own, every conversation opens from Home's
/// recents or More's History, and what was the More tab and Settings is You — reached from
/// Home's profile button — with the tools as rows that present their screens.
final class EmperorUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launch(_ extraArguments: String...) -> XCUIApplication {
        launch(arguments: extraArguments)
    }

    private func launch(arguments extraArguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestMode"] + extraArguments
        app.launch()
        return app
    }

    /// Signs in through the real sign-in screen, with an emailed code — the way it leads with
    /// (`XCUIApplication.signInWithACode`).
    @discardableResult
    private func signIn(_ app: XCUIApplication) -> XCUIApplication {
        XCTAssertTrue(app.signInWithACode(), "the sign-in screen did not take an emailed code")
        return app
    }

    /// Launched and signed in, with the tabs on screen.
    private func signedIn(_ extraArguments: String...) -> XCUIApplication {
        let app = signIn(launch(arguments: extraArguments))
        XCTAssertTrue(app.tab("Home").waitForExistence(timeout: 15), "signing in did not reach Home")
        return app
    }

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    /// You, on its own screen: opened from Home's profile button, where the redesign keeps it —
    /// it is no longer a tab.
    private func openYou(_ app: XCUIApplication) {
        XCTAssertTrue(app.tab("Home").waitForExistence(timeout: 10))
        app.tab("Home").tap()
        let profile = app.buttons["home-profile"]
        XCTAssertTrue(profile.waitForExistence(timeout: 10), "Home has no profile button")
        profile.tap()
        XCTAssertTrue(app.navigationBars["Account & Profile"].waitForExistence(timeout: 10), "You did not open")
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

    // MARK: - Ways in

    /// The code way in: chosen from its segment, an address, and a six-digit code. A full code
    /// goes on without a tap, as code fields do elsewhere on the phone.
    func testSigningInWithAnEmailCode() {
        let app = launch()
        let email = app.textFields["Email"]
        XCTAssertTrue(email.waitForExistence(timeout: 10))
        // The screen opens with the password; choosing the code must ask for no password.
        app.buttons["Sign in with code"].tap()
        // The field fades out with the swap; ask only once the transition has landed.
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertFalse(app.secureTextFields["Password"].exists, "the code asks for no password")
        email.focusForTyping()
        email.typeText("john.doe@firm.com")

        app.buttons["Email me a sign-in code"].tap()

        let code = app.textFields["Sign-in code"]
        XCTAssertTrue(code.waitForExistence(timeout: 10), "the code step never appeared")
        XCTAssertTrue(app.staticTexts["Check your email"].exists, "the code step does not say where to look")
        code.focusForTyping()
        code.typeText("123456")

        XCTAssertTrue(
            app.tab("Ask").waitForExistence(timeout: 10),
            "a complete code did not sign in")
    }

    /// The password, as the screen opens with it: address, password, sign in.
    func testSigningInWithAPassword() {
        let app = launch()
        let email = app.textFields["Email"]
        XCTAssertTrue(email.waitForExistence(timeout: 10))
        email.focusForTyping()
        email.typeText("john.doe@firm.com")

        let password = app.secureTextFields["Password"]
        XCTAssertTrue(password.waitForExistence(timeout: 5), "the screen does not open with a password")
        password.focusForTyping()
        password.typeText("hunter2")
        app.buttons["Sign in"].firstMatch.tap()

        XCTAssertTrue(
            app.tab("Ask").waitForExistence(timeout: 10), "signing in with a password did not sign in")
    }

    /// Creating an account no longer signs anyone in: the server emails a confirmation link. The
    /// screen must say so — the old flow reported "unexpected response" about an account it had
    /// just made.
    func testCreatingAnAccountAsksForConfirmation() {
        let app = launch()
        XCTAssertTrue(app.textFields["Email"].waitForExistence(timeout: 10))
        app.buttons["Create new account"].tap()

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
        XCTAssertFalse(app.tab("Ask").exists, "nobody is signed in yet")
    }

    // MARK: - The tab bar

    /// The redesign's five: Home · Matters · Ask · Calendar · More, the same for every role. You
    /// left the bar (Home's profile button opens it), and the old Chat, Cases, Files and History
    /// never come back — Files and History live under More, and Cases is Matters.
    func testSigningInRevealsTheTabs() {
        let app = signIn(launch())
        for tab in ["Home", "Matters", "Ask", "Calendar", "More"] {
            XCTAssertTrue(
                app.tab(tab).waitForExistence(timeout: 10),
                "the \(tab) tab is missing")
        }
        for gone in ["Cases", "Files", "History", "You", "Chat"] {
            XCTAssertFalse(app.tab(gone).exists, "\(gone) is not a tab any more")
        }
    }

    /// Every tab renders. A tab that crashes on appear takes the app down, and this is what
    /// notices. Each is checked the way it identifies itself: a navigation title where it has
    /// one, Home's profile button where it has none, and History's list under its own title.
    func testEveryTabOpensAndRendersItsScreen() {
        let app = signedIn()
        for (tab, title) in [
            ("Home", nil),
            ("Matters", "Matters"),
            ("Ask", "Ask"),
            ("Calendar", "Calendar"),
            ("More", "More services & tools"),
        ] {
            app.tab(tab).tap()
            if let title {
                XCTAssertTrue(
                    app.navigationBars[title].waitForExistence(timeout: 10),
                    "tapping \(tab) did not show a screen titled \(title)")
            } else {
                XCTAssertTrue(
                    app.buttons["home-profile"].waitForExistence(timeout: 10),
                    "tapping Home did not show the dashboard")
            }
            XCTAssertEqual(app.state, .runningForeground, "the app died on the \(tab) tab")
        }
    }

    // MARK: - Ask

    /// The next sitting on Matters leads with where it is heard — item and courtroom — because
    /// that is what a litigator scans a list for. The row is one accessibility element saying so.
    func testAMatterListingLeadsWithItsItemAndCourt() {
        let app = signedIn()
        app.tab("Matters").tap()
        let row = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "Item 7, Court 12")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the listing does not lead with item and court")
        XCTAssertEqual(app.state, .runningForeground)
    }

    // MARK: - Calendar

    /// Opens the Calendar tab, on today — the day's listing and the diary.
    private func openTheCalendar(_ app: XCUIApplication) {
        XCTAssertTrue(app.tab("Calendar").waitForExistence(timeout: 10))
        app.tab("Calendar").tap()
        XCTAssertTrue(
            app.navigationBars["Calendar"].waitForExistence(timeout: 10), "the Calendar did not open")
    }

    /// The day's listing is on the Calendar, led by its sitting time, and tapping it leaves the
    /// Calendar and lands on the **Matters** tab with that matter open on its overview — the
    /// stub's `/cause-list`, `/cases` and `/case` all describe `case1`, listed today, which is
    /// the day the Calendar opens on.
    ///
    /// Then the whole way round a second time. The request to open a case is taken once; this is
    /// what notices if it is never cleared (the case would re-open on every visit to Matters) or
    /// never re-armed (the second tap would do nothing).
    func testACalendarListingOpensItsCaseOnTheMattersTab() {
        let app = signedIn()

        for pass in 1...2 {
            openTheCalendar(app)
            let listing = app.buttons["calendar-listing-case1"]
            XCTAssertTrue(
                listing.waitForExistence(timeout: 10),
                "pass \(pass): today's listing is not on the Calendar")
            XCTAssertTrue(
                listing.label.hasPrefix("10:30 AM. Item 7, Court 12"),
                "the listing does not lead with its time, item and court: \(listing.label)")
            listing.tap()

            let matter = app.navigationBars["Bakshi v. State of Maharashtra"]
            XCTAssertTrue(
                matter.waitForExistence(timeout: 10),
                "pass \(pass): tapping the listing did not open its case")
            let overview = app.staticTexts.matching(
                NSPredicate(format: "label ==[c] %@", "Overview")).firstMatch
            XCTAssertTrue(
                overview.waitForExistence(timeout: 10),
                "pass \(pass): the case did not open on its overview")

            // Back lands on Matters, not on whatever it showed before.
            matter.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(
                app.navigationBars["Matters"].waitForExistence(timeout: 10),
                "pass \(pass): back from the case did not land on Matters")
            // Asked here rather than over the case, which hides the tab bar.
            XCTAssertTrue(
                becomesSelected(app.tab("Matters")),
                "pass \(pass): the case opened somewhere other than the Matters tab")
        }

        // And coming back to Matters does not open the case again by itself.
        app.tab("Ask").tap()
        XCTAssertTrue(app.navigationBars["Ask"].waitForExistence(timeout: 10))
        app.tab("Matters").tap()
        XCTAssertTrue(app.navigationBars["Matters"].waitForExistence(timeout: 10))
        XCTAssertFalse(
            app.navigationBars["Bakshi v. State of Maharashtra"].exists,
            "an old request re-opened the case")

        // The day's diary entry follows its listings, in a section of its own. Scrolled to, as
        // it sits below the month and the listing: a list only builds the rows it is showing.
        app.tab("Calendar").tap()
        XCTAssertTrue(app.navigationBars["Calendar"].waitForExistence(timeout: 10))
        let diary = app.staticTexts["File written statement"]
        var swipes = 0
        while !diary.exists, swipes < 3 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(diary.waitForExistence(timeout: 5), "the day's diary entry is missing")
    }

    // MARK: - Corporate Calendar

    /// You's Tools open the Corporate Calendar for every role; it lists a statutory deadline and
    /// opens it, the way back is the back button, and the screen closes from its own Done.
    func testTheCorporateCalendarOpensFromYouAndOpensADeadline() {
        let app = signedIn()
        openYou(app)
        openToolRow("Corporate Calendar", in: app)
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
        XCTAssertTrue(app.navigationBars["Account & Profile"].waitForExistence(timeout: 10))
    }

    // MARK: - Calendar subscription

    /// Subscribing is offered from Calendar, the link can be copied, and the sheet closes from a
    /// control on screen. "Subscribe in Calendar" itself is not tapped: it leaves the app for
    /// the Calendar app, which is the point of it and the end of any test.
    func testCalendarOffersAPrivateLinkThatCanBeCopied() {
        let app = signedIn()
        openTheCalendar(app)

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

    // MARK: - You's Tools

    /// Taps one of You's rows by its name, scrolled to first: You is a long list, and on a phone
    /// the Tools rows start below the fold.
    private func openToolRow(_ row: String, in app: XCUIApplication) {
        let button = app.buttons[row].firstMatch
        app.reveal(button)
        XCTAssertTrue(button.waitForExistence(timeout: 5), "You has no \(row) row")
        button.tap()
    }

    /// Each Tools row on You opens its screen, **and every one of them can be closed by a control
    /// on screen**.
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
    func testEveryToolsRowOpensAndClosesFromAControlOnScreen() {
        let app = signedIn()
        openYou(app)

        // Hidden for now at the product owner's request; their screens are kept. See the note
        // at `ToolsSections` for how to bring them back.
        for hidden in ["Projects", "eAuctions"] {
            XCTAssertFalse(app.buttons[hidden].exists, "\(hidden) is meant to be hidden")
        }

        for (row, title) in [
            ("Corporate Calendar", "Corporate Calendar"),
            ("Library", "Library"),
            ("All tools", "Tools"),
            ("File tools", "File tools"),
            ("OCR", "OCR"),
            ("Translate", "Translate"),
        ] {
            openToolRow(row, in: app)
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
                app.navigationBars["Account & Profile"].waitForExistence(timeout: 10),
                "closing \(row) did not return to You")
            // Gone, not only going. You's own bar is there behind a sheet the whole time, so it
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

    // MARK: - Files

    /// Opens Files from More, on the library's top level.
    private func openFiles(_ app: XCUIApplication) {
        XCTAssertTrue(app.tab("More").waitForExistence(timeout: 10))
        app.tab("More").tap()
        let files = app.buttons["Files"].firstMatch
        XCTAssertTrue(files.waitForExistence(timeout: 10), "More has no Files row")
        files.tap()
        XCTAssertTrue(app.navigationBars["Files"].waitForExistence(timeout: 10), "Files did not open")
    }

    /// A folder opens, its document is listed, and deleting it asks first — naming the document
    /// in the question. Cancelled, so nothing is sent; what is pinned is that the destructive
    /// path cannot be reached without a confirmation that says what it will destroy.
    func testDeletingADocumentAsksFirstAndNamesIt() {
        let app = signedIn()
        openFiles(app)

        // A folder is one element, a button, found by its identifier, since its label also
        // carries what the folder holds.
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

    /// Files opens on its folders — the matters' papers — with no section tapped. A folder opens,
    /// showing its own sub-folder and its documents; the sub-folder opens in turn; and Back
    /// returns, level by level, to the top.
    func testFilesOpensOnFoldersThatOpenTheirFolders() {
        let app = signedIn()
        openFiles(app)

        let bakshi = app.buttons["folder-Bakshi"]
        XCTAssertTrue(bakshi.waitForExistence(timeout: 10), "Files did not open on its folders")
        XCTAssertTrue(app.buttons["folder-Arora_Holdings"].exists, "every top-level folder is listed")
        // One element, saying what the folder holds — counted all the way down.
        XCTAssertEqual(bakshi.label, "Bakshi, 2 documents, 1 folder")

        // A document filed in no folder stays reachable from the top, below the folders.
        let loose = app.staticTexts["Engagement Letter.pdf"]
        var swipes = 0
        while !loose.exists, swipes < 3 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(loose.waitForExistence(timeout: 5), "the document in no folder is not listed")

        app.reveal(bakshi)
        bakshi.tap()
        XCTAssertTrue(app.navigationBars["Bakshi"].waitForExistence(timeout: 10), "the folder did not open")
        let orders = app.buttons["folder-Bakshi/Orders"]
        XCTAssertTrue(orders.waitForExistence(timeout: 10), "the sub-folder is not listed")
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
        XCTAssertTrue(app.navigationBars["Files"].waitForExistence(timeout: 10), "Back did not return to Files")
        XCTAssertTrue(app.buttons["folder-Bakshi"].waitForExistence(timeout: 10), "the folders are not there on return")
        XCTAssertEqual(app.state, .runningForeground)
    }

    // MARK: - First sign-in

    /// The role choice appears after a first sign-in on this device, offers a way past without
    /// choosing, and gives way to the app once answered.
    func testAFirstSignInIsAskedForARoleAndCanChooseOne() {
        let app = signIn(launch("-UITestRoleWelcome"))

        let choice = app.buttons["role-corporateCounsel"]
        XCTAssertTrue(choice.waitForExistence(timeout: 10), "the role choice did not appear")
        XCTAssertFalse(app.tab("Ask").exists, "the app was reachable behind it")
        XCTAssertTrue(app.buttons["Skip for now"].exists, "there must be a way past without choosing")

        choice.tap()
        app.buttons["Continue"].tap()

        XCTAssertTrue(
            app.tab("Ask").waitForExistence(timeout: 10),
            "choosing a role did not lead into the app")
    }

    func testTheRoleChoiceCanBeSkipped() {
        let app = signIn(launch("-UITestRoleWelcome"))
        let skip = app.buttons["Skip for now"]
        XCTAssertTrue(skip.waitForExistence(timeout: 10), "the role choice did not appear")
        skip.tap()
        XCTAssertTrue(app.tab("Ask").waitForExistence(timeout: 10))
    }

    // MARK: - Court search

    /// Opens the court lookup from Matters' "Add a matter".
    private func openTheCourtLookup(_ app: XCUIApplication) {
        XCTAssertTrue(app.tab("Matters").waitForExistence(timeout: 10))
        app.tab("Matters").tap()
        XCTAssertTrue(app.navigationBars["Matters"].waitForExistence(timeout: 10))
        app.buttons["Add a matter"].firstMatch.tap()
        XCTAssertTrue(
            app.navigationBars["Find a case"].waitForExistence(timeout: 10),
            "the court search sheet did not open")
    }

    /// Looking a case up by its **case number** — the number printed on every piece of paper
    /// after registration, and until recently the one way of finding a matter this app could not
    /// do. It only offered diary-number lookup, which is the number you get when you file and
    /// rarely the one you have later.
    ///
    /// The two modes are separate routes taking different fields, so this checks that switching
    /// actually reshapes the form rather than just relabelling it.
    func testACaseCanBeFoundByCaseNumberAndByDiaryNumber() {
        let app = signedIn()
        openTheCourtLookup(app)

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
        let app = signedIn()
        openTheCourtLookup(app)

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

    // MARK: - Conversations

    /// The reading card over the stub's stored answer: its work log read a document and searched
    /// the record, which the card sums up in one line (`StepLabels.summary`).
    private func storedWorkLogPanel(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Read 1 document")).firstMatch
    }

    /// Opens the stub's stored conversation from Home's recent conversations.
    private func openTheStubConversation(_ app: XCUIApplication) {
        XCTAssertTrue(app.tab("Home").waitForExistence(timeout: 10))
        app.tab("Home").tap()
        let conversation = app.stubConversationRow
        XCTAssertTrue(conversation.waitForExistence(timeout: 10), "the conversation is not listed on Home")
        app.reveal(conversation)
        conversation.tap()
        XCTAssertTrue(
            app.navigationBars["Conversation"].waitForExistence(timeout: 10),
            "the conversation did not open")
    }

    /// A stored answer carries the work log it was produced with — the stub's answer was stored
    /// with one, as the web stores every answer — drawn folded above it, and opening to the
    /// steps that were taken, each said in plain words.
    func testAStoredAnswerShowsTheWorkItRestsOn() {
        let app = signedIn()
        openTheStubConversation(app)

        let panel = storedWorkLogPanel(app)
        XCTAssertTrue(panel.waitForExistence(timeout: 10), "the stored work log is not drawn")
        XCTAssertTrue(
            panel.label.contains("searched your files"), "the card misdescribes the work: \(panel.label)")

        let step = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Searching your documents")).firstMatch
        XCTAssertFalse(step.exists, "a stored card opens folded")
        panel.tap()
        XCTAssertTrue(step.waitForExistence(timeout: 5), "the card does not open to its steps")
        XCTAssertEqual(app.state, .runningForeground)
    }

    // MARK: - Empty states

    /// With every fixture empty, each tab must say something rather than showing a blank screen.
    func testEmptyStatesRenderRatherThanBlankScreens() {
        let app = signedIn("-UITestEmpty")

        // (tab, navigation title) — Home has none, and is checked by its profile button.
        for (tab, title) in [("Home", nil), ("Matters", "Matters"), ("Ask", "Ask"),
                             ("Calendar", "Calendar"), ("More", "More services & tools")] {
            app.tab(tab).tap()
            if let title {
                XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10))
            } else {
                XCTAssertTrue(app.buttons["home-profile"].waitForExistence(timeout: 10))
            }
            // An empty state renders as static text; any of it is enough to prove the empty
            // branch drew something.
            let hasCopy = app.staticTexts.count > 0
            XCTAssertTrue(hasCopy, "the \(tab) tab rendered nothing at all when empty")
            XCTAssertEqual(app.state, .runningForeground, "the app died on an empty \(tab)")
        }
    }

    // MARK: - Sign out

    /// The one destructive action reachable without a server write, and the way back to the
    /// login screen.
    func testSigningOutReturnsToLogin() {
        let app = signedIn()
        openYou(app)

        // Sign out is the last row of You, so on a phone it starts off screen — and a list only
        // builds the rows it is showing. Scroll to it rather than assume it is there.
        let signOut = app.buttons["Sign out"].firstMatch
        var swipes = 0
        while !(signOut.exists && signOut.isHittable) && swipes < 10 {
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
        let app = signedIn()
        openYou(app)
        openToolRow("All tools", in: app)

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
            app.navigationBars["Account & Profile"].waitForExistence(timeout: 10),
            "the tool sheet could not be closed after running a tool")
    }

    // MARK: - Role

    /// The role is switched from You's Role row, at once, as the web's selector does — and the
    /// workspace follows it.
    func testTheRoleIsSwitchedFromYou() {
        let app = signedIn()
        openYou(app)

        // Below the account and its plan, so off screen on a phone until scrolled to.
        let selector = app.buttons["Role selector"].firstMatch
        app.reveal(selector)
        XCTAssertTrue(selector.waitForExistence(timeout: 5), "You has no role row")
        selector.tap()
        let corporate = app.buttons["role-corporateCounsel"].firstMatch
        XCTAssertTrue(corporate.waitForExistence(timeout: 10), "the roles were not listed")
        corporate.tap()

        // Back on You, which now says the new role. Polled rather than waited on with an
        // expectation: `waitForExpectations` sends the test case across actors, which Swift 6
        // refuses to compile here.
        XCTAssertTrue(app.navigationBars["Account & Profile"].waitForExistence(timeout: 10))
        app.reveal(selector)
        XCTAssertTrue(selector.waitForExistence(timeout: 10))
        var polls = 0
        while !selector.label.contains("Corporate Counsel") && polls < 40 {
            Thread.sleep(forTimeInterval: 0.25)
            polls += 1
        }
        XCTAssertTrue(
            selector.label.contains("Corporate Counsel"), "You did not show the new role: \(selector.label)")

        // And the workspace is the new role's.
        openToolRow("Your workspace", in: app)
        XCTAssertTrue(
            app.navigationBars["Corporate Counsel"].waitForExistence(timeout: 10),
            "the workspace did not follow the role")
        app.navigationBars["Corporate Counsel"].buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Account & Profile"].waitForExistence(timeout: 10))

        // Left as the other tests expect to find it.
        app.reveal(selector)
        selector.tap()
        app.buttons["role-litigator"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Account & Profile"].waitForExistence(timeout: 10))
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

        openYou(app)
        openToolRow("Your workspace", in: app)
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
        XCTAssertTrue(app.navigationBars["Account & Profile"].waitForExistence(timeout: 10))
    }

    // MARK: - File tools

    /// Every card in the hub opens its own screen and comes back. Each tool is a separate push
    /// from one grid, so a card wired to the wrong destination — or a screen that dies on
    /// appear — shows up here rather than in a user's hands.
    func testEveryFileToolOpensFromTheHubAndComesBack() {
        let app = signedIn()
        openYou(app)
        openToolRow("File tools", in: app)
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
        XCTAssertTrue(app.navigationBars["Account & Profile"].waitForExistence(timeout: 10))
    }

    /// The account's own history, decoded from the shape `/ocr-history` really sends — a bare
    /// array whose jobs carry their page setup as an object. A decoder that cannot read it
    /// shows "Could not load" here instead of the row.
    func testTranslateListsTheAccountsHistory() {
        let app = signedIn()
        openYou(app)
        openToolRow("Translate", in: app)
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

    // MARK: - Answer mode and OCR

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

    /// Polls until `element`'s label is `label`.
    private func reads(_ element: XCUIElement, _ label: String) -> Bool {
        Self.poll(10) { element.exists && element.label == label }
    }

    /// The answer mode sits in the composer, always in sight, as a chip that names it; the chip
    /// opens the choice of Fast and Deep thinking, each with what it is for, and one tap switches.
    /// The fixture account is on no plan tier, so a conversation opens on Fast.
    func testTheComposerSwitchesBetweenFastAndDeepThinking() {
        let app = signedIn()
        openTheStubConversation(app)

        let chip = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Answer mode,")).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "the composer has no answer mode")
        XCTAssertTrue(reads(chip, "Answer mode, Fast"), "a conversation opens on Fast: \(chip.label)")

        let fast = app.buttons.matching(NSPredicate(
            format: "label CONTAINS %@", "Quick answers from your record")).firstMatch
        let deep = app.buttons.matching(NSPredicate(
            format: "label CONTAINS %@", "reasons through long records")).firstMatch

        chip.tap()
        XCTAssertTrue(deep.waitForExistence(timeout: 5), "the answer modes were not offered")
        XCTAssertTrue(fast.exists, "Fast is not offered")
        XCTAssertTrue(fast.isSelected, "the current mode is not marked")
        XCTAssertFalse(deep.isSelected)

        deep.tap()
        XCTAssertTrue(reads(chip, "Answer mode, Deep thinking"), "choosing Deep thinking did not take")
        XCTAssertFalse(deep.exists, "the choice stayed open after a mode was chosen")

        chip.tap()
        XCTAssertTrue(deep.waitForExistence(timeout: 5))
        XCTAssertTrue(becomesSelected(deep), "Deep thinking is not marked as the current mode")
        XCTAssertFalse(fast.isSelected, "both modes are marked at once")
        fast.tap()
        XCTAssertTrue(reads(chip, "Answer mode, Fast"), "choosing Fast again did not take")
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// The toolbar's menu keeps searching the web and reporting an answer — and offers no role
    /// and no mode. A conversation is asked for in the practitioner's own role, and the mode is
    /// the composer's.
    func testTheOptionsMenuOffersNoRoleAndNoMode() {
        let app = signedIn()
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
        for mode in ["Mode", "Fast", "Deep thinking"] {
            XCTAssertFalse(
                app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", mode))
                    .firstMatch.exists,
                "the mode is in the composer, not the menu")
        }
    }

    /// You has an OCR row of its own beside Translate. It opens the shared screen on OCR —
    /// no language to choose — and the switch at its head turns it into Translate and back.
    func testOCROpensFromYouAndItsSwitchChangesTheScreen() {
        let app = signedIn()
        openYou(app)
        openToolRow("OCR", in: app)
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
        XCTAssertTrue(app.navigationBars["Account & Profile"].waitForExistence(timeout: 10))
    }

    /// Translate, opened from its own row, opens on Translate — the same screen, other side.
    func testTranslateOpensOnTranslateWithItsSwitch() {
        let app = signedIn()
        openYou(app)
        openToolRow("Translate", in: app)
        XCTAssertTrue(app.navigationBars["Translate"].waitForExistence(timeout: 10))

        let modes = app.segmentedControls.firstMatch
        XCTAssertTrue(modes.waitForExistence(timeout: 5), "the OCR | Translate switch is missing")
        XCTAssertTrue(modes.buttons["Translate"].isSelected)
        XCTAssertFalse(modes.buttons["OCR"].isSelected)
    }

    // MARK: - Matters: court headings, sort & filter, and the docket's own search

    /// Opens Matters on "All matters" — the docket.
    private func openTheDocket(_ app: XCUIApplication) {
        XCTAssertTrue(app.tab("Matters").waitForExistence(timeout: 10))
        app.tab("Matters").tap()
        XCTAssertTrue(app.navigationBars["Matters"].waitForExistence(timeout: 10))
        let all = app.buttons["All matters"].firstMatch
        XCTAssertTrue(all.waitForExistence(timeout: 10), "Matters has no All matters")
        all.tap()
        XCTAssertTrue(becomesSelected(all), "All matters did not open")
    }

    /// A docket row, by the case's id — its label is the whole row read aloud.
    private func caseRow(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "case-row-\(id)").firstMatch
    }

    /// A heading of the docket: "High Courts · 3". Matched whatever its case, as the heading is
    /// drawn in capitals.
    private func docketHeading(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "\(title) ·"))
            .firstMatch
    }

    /// The docket's search field, which searches the user's own matters.
    private func docketSearch(_ app: XCUIApplication) -> XCUIElement {
        app.textFields["Search your cases"].firstMatch
    }

    /// The docket is headed by court, in order of importance — the stub has a matter under every
    /// heading but "Other courts". The docket is drawn whole, so every heading is there to be read
    /// and their order is the order of their places on the page.
    func testTheDocketIsHeadedByCourtInOrderOfImportance() {
        let app = signedIn()
        openTheDocket(app)

        let expected = [
            "Supreme Court", "High Courts", "NCLAT", "NCLT", "Tribunals", "District Courts",
            "Consumer Commissions",
        ]
        let headings = expected.map { docketHeading($0, in: app) }
        for (title, heading) in zip(expected, headings) {
            XCTAssertTrue(heading.waitForExistence(timeout: 10), "the docket has no \(title) heading")
        }
        let tops = headings.map { $0.frame.minY }
        XCTAssertEqual(tops, tops.sorted(), "the court headings are not in order of importance")
        XCTAssertFalse(docketHeading("Other courts", in: app).exists, "an empty heading is drawn")
    }

    /// The docket has a search field of its own that searches the user's own cases — by party,
    /// by a diary number — and says so when nothing matches, with a way back. Adding a matter is
    /// a separate, labelled control.
    func testTheDocketsSearchBarSearchesYourOwnCases() {
        let app = signedIn()
        openTheDocket(app)

        let search = docketSearch(app)
        XCTAssertTrue(search.waitForExistence(timeout: 10), "the docket has no search field")
        XCTAssertTrue(app.buttons["Add a matter"].firstMatch.exists, "adding a matter is not its own control")
        XCTAssertTrue(caseRow(app, "case-sc").waitForExistence(timeout: 10))

        search.focusForTyping()
        search.typeText("Kapoor")
        XCTAssertTrue(caseRow(app, "case-hc-delhi").waitForExistence(timeout: 5),
                      "the search did not find the matter by party")
        XCTAssertFalse(caseRow(app, "case-sc").exists, "the search did not narrow the docket")
        XCTAssertFalse(caseRow(app, "case1").exists, "the search did not narrow the docket")

        app.buttons["Clear search"].firstMatch.tap()
        search.focusForTyping()
        search.typeText("41207/2025")
        XCTAssertTrue(caseRow(app, "case-sc").waitForExistence(timeout: 5),
                      "the search did not find the matter by diary number")
        XCTAssertFalse(caseRow(app, "case-hc-delhi").exists)

        app.buttons["Clear search"].firstMatch.tap()
        search.focusForTyping()
        search.typeText("zzzz")
        let nothing = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "No cases match")).firstMatch
        XCTAssertTrue(nothing.waitForExistence(timeout: 5), "nothing matching does not say so")
        // The empty state's own "Clear search", or the field's: either brings the docket back.
        app.buttons["Clear search"].firstMatch.tap()
        XCTAssertTrue(caseRow(app, "case1").waitForExistence(timeout: 5),
                      "clearing did not bring the docket back")
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// Choosing a sort, a grouping and a court filter changes the docket; the filter shows as a
    /// chip and on the toolbar button; Clear all brings every court back.
    func testSortingAndFilteringChangeTheDocketAndClearAllRestoresIt() {
        let app = signedIn()
        openTheDocket(app)

        let arrange = app.buttons["Sort and filter"].firstMatch
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
            docketHeading("All cases", in: app).waitForExistence(timeout: 5),
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
        XCTAssertTrue(caseRow(app, "case-nclat").waitForExistence(timeout: 5),
                      "Clear all did not bring the other courts back")
        XCTAssertFalse(chip.exists, "the chip outlived its filter")
        XCTAssertEqual(arrange.value as? String, "No filters")
    }

    /// A filter that hides every case says so, rather than showing a blank list, and its Clear
    /// brings them back.
    func testAFilterThatHidesEverythingSaysSoAndCanBeCleared() {
        let app = signedIn()
        openTheDocket(app)

        let arrange = app.buttons["Sort and filter"].firstMatch
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
        let clear = app.buttons["Clear filters"].firstMatch
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.tap()
        XCTAssertTrue(caseRow(app, "case-sc").waitForExistence(timeout: 5),
                      "Clear did not bring the docket back")
    }

    /// The sheet's filters may sit below the fold: scroll inside it until the row can be tapped.
    private func revealInArrangementSheet(_ element: XCUIElement, _ app: XCUIApplication) {
        // Dragged inside the sheet's own list, from low in it to higher up. A drag that starts on
        // the sheet's bar or edge moves the sheet itself, so the sheet's list is found by name
        // (the last list on screen, failing that).
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

    /// You → Notifications opens, is off until asked for, and turning it on shows the hearing
    /// reminders, updates and a test. In UI-test mode the app answers as a device that was asked
    /// and said yes — no real permission prompt, no real notification.
    ///
    /// The account's email switch is turned on and off against the stub, which remembers it for
    /// the run: the screen re-reads `/notif/status` after each change, so the switch only stays on
    /// if that read-back decodes.
    func testNotificationSettingsOpenAndShowTheirControls() {
        let app = signedIn()
        openYou(app)

        let row = app.buttons["notifications-settings"].firstMatch
        app.reveal(row)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "You has no Notifications row")
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

        // And back out to You, intact.
        app.navigationBars["Notifications"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Account & Profile"].waitForExistence(timeout: 10))
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

    /// Taps a control that asks before it acts, and returns the confirmation's button — found in
    /// whichever form the dialog took: a sheet on iPhone, a popover on iPad, or an alert.
    ///
    /// A tap the app did not take is made again, up to three in all. On a CI iPhone one tap on
    /// "Clear offline copies", centred on a row that had been still for seconds, brought up no
    /// dialog at all; the code under it had passed on the run before. Tapped again only while
    /// no dialog has come and the control is still there to tap — a second tap behind an open
    /// dialog would dismiss it.
    private func confirmation(
        _ title: String, afterTapping control: XCUIElement, in app: XCUIApplication
    ) -> XCUIElement? {
        for _ in 0..<3 {
            control.tap()
            for _ in 0..<20 {
                let shown = [app.sheets, app.popovers, app.alerts]
                    .map { $0.buttons[title].firstMatch }
                    .first { $0.exists }
                if let shown { return shown }
                Thread.sleep(forTimeInterval: 0.25)
            }
            guard control.exists && control.isHittable else { break }
        }
        return nil
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

    /// On iPad, History — every conversation, opened from More → History — shows a conversation
    /// beside the list: one opens there, another replaces it, and a new one opens in that same
    /// column with the list still there and no row marked — a new conversation is in no row
    /// until its first turn is stored.
    ///
    /// `c2` answers `/messages` with an exchange of its own; `c1`'s carries the work log.
    func testOnIPadAConversationOpensBesideTheList() throws {
        try XCTSkipUnless(isPad, "the list beside its conversation is iPad's layout")
        let app = signedIn()
        XCTAssertTrue(app.tab("More").waitForExistence(timeout: 10))
        app.tab("More").tap()
        let history = app.buttons["History"].firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 10), "More has no History row")
        history.tap()
        XCTAssertTrue(app.navigationBars["Conversations"].waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.staticTexts["Choose a conversation"].waitForExistence(timeout: 10),
            "the list is not beside its conversation")

        // History's own list.
        let list = app.collectionViews.containing(.any, identifier: "chat-row-c2").firstMatch
        let first = list.descendants(matching: .any).matching(identifier: "chat-row-c1").firstMatch
        let second = list.descendants(matching: .any).matching(identifier: "chat-row-c2").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10), "the conversations are not listed")
        first.tap()

        let worked = storedWorkLogPanel(app)
        XCTAssertTrue(worked.waitForExistence(timeout: 10), "the conversation did not open")
        XCTAssertTrue(app.navigationBars["Conversations"].exists, "the list left the screen")
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
        app.navigationBars["Conversations"].buttons["New chat"].firstMatch.tap()
        XCTAssertTrue(
            disappears(secondQuestion), "a new conversation did not take the open one's place")
        XCTAssertTrue(app.navigationBars["Conversation"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["Conversations"].exists, "the list left the screen")
        XCTAssertFalse(second.isSelected, "a row is still marked for a conversation no longer open")
        XCTAssertEqual(app.state, .runningForeground)
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

    /// You → Security: the switch, named for what this device asks for, and — once it is on —
    /// how long the app may be away. In UI-test mode a stand-in answers for Face ID and
    /// recognises every face, so the real `LAContext` is never touched; and every launch starts
    /// with the lock off, so turning it on here is turning it on from off.
    func testSecuritySettingsShowTheLockAndItsTimeout() {
        let app = signedIn()
        openYou(app)

        // Far down You, so off screen on a phone until scrolled to — and then raised well into
        // view, not left on the bottom edge where the swipe first finds it. The timeout row
        // appears *beneath* the switch, and a list builds no row it is not showing: with the switch
        // on the last visible line, the row is never built and cannot be found.
        let toggle = app.switches["app-lock-toggle"].firstMatch
        app.reveal(toggle)
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "You has no Security section")
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
        app.reveal(toggle)
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
        XCTAssertFalse(app.tab("Ask").exists, "the tabs were reachable behind the lock")
        XCTAssertFalse(app.textFields["Email"].exists, "a session on the device opened on sign-in")

        unlock.tap()
        XCTAssertTrue(
            app.tab("Ask").waitForExistence(timeout: 10), "unlocking did not reveal the app")
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
        XCTAssertTrue(app.tab("Ask").waitForExistence(timeout: 10))

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
        XCTAssertFalse(app.tab("Ask").exists, "the tabs were reachable behind the lock")
        app.buttons["app-lock-unlock"].tap()
        XCTAssertTrue(
            app.tab("Ask").waitForExistence(timeout: 10), "unlocking again did not reveal the app")
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
        Self.poll(seconds, condition)
    }

    // MARK: - Profile, documents shared in, and search

    /// You → the account at its head opens Edit profile on the account as it is, and a save
    /// reaches the server and comes back: the stub echoes the account it was sent, and You shows
    /// the new name and title from the session — not from the form.
    func testEditingTheProfileSavesItAndYouShowsIt() {
        let app = signedIn()
        openYou(app)

        let edit = app.buttons["edit-profile"].firstMatch
        app.reveal(edit)
        XCTAssertTrue(edit.waitForExistence(timeout: 10), "You has no Edit profile row")
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
            app.navigationBars["Account & Profile"].waitForExistence(timeout: 10),
            "saving did not return to You")
        let account = app.descendants(matching: .any)["account-profile"].firstMatch
        app.reveal(account)
        XCTAssertTrue(account.waitForExistence(timeout: 10), "You has no account header")
        var polls = 0
        while !account.label.contains("John Q. Doe") && polls < 40 {
            Thread.sleep(forTimeInterval: 0.25)
            polls += 1
        }
        XCTAssertTrue(account.label.contains("John Q. Doe"), "You did not show the saved name")
        XCTAssertTrue(
            account.label.contains("Advocate, Bombay High Court"), "You did not show the title")
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
        XCTAssertTrue(app.tab("Ask").waitForExistence(timeout: 5))
    }

    /// You → Search: "Show in Spotlight search", on by default, and it turns.
    func testTheSpotlightSwitchIsOnYou() {
        let app = signedIn()
        openYou(app)

        let toggle = app.switches["spotlight-toggle"].firstMatch
        app.reveal(toggle)
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "You has no Spotlight switch")
        XCTAssertEqual(toggle.value as? String, "1", "on until turned off")
        flip(toggle, to: "0")
        flip(toggle, to: "1")
    }

    // MARK: - Opening a day from outside: the Today widget, links and notification taps

    /// `emperor://calendar?day=…` — what the Today widget opens, and the path a tapped hearing
    /// reminder takes — opens the Calendar **on that day**: its cell selected and its listing
    /// below. Two days ahead, where the stub's docket lists the Delhi matter. Then a bare
    /// `emperor://calendar` moves it back to today.
    ///
    /// Each link arrives as the app comes back from the background (`-UITestLinkOnReturn`), which
    /// is how a widget's tap reaches an app that is already running — see
    /// `UITestSupport.takeLinkOnReturn` for why not `XCUIApplication.open(_:)`.
    func testALinkOpensTheCalendarOnItsDay() {
        let day = Self.indianDay(daysFromNow: 2)
        let app = signedIn(
            "-UITestLinkOnReturn", "emperor://calendar?day=\(day.key)",
            "-UITestLinkOnReturn", "emperor://calendar")

        leaveAndReturn(app)
        XCTAssertTrue(
            app.navigationBars["Calendar"].waitForExistence(timeout: 10),
            "the link did not open the Calendar")
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

        // The Calendar is a tab of its own; the link selected its tab.
        XCTAssertTrue(
            becomesSelected(app.tab("Calendar")), "the Calendar tab is not selected")
    }

    /// A day's cell in the Calendar's month. Today's is read out as "Today, …" — so it is found by
    /// either form of its label, not by the date alone.
    private func dayCell(_ label: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "label == %@ OR label == %@", label, "Today, \(label)")
        ).firstMatch
    }

    /// An update tapped while a sheet is open — here the Subscribe sheet over the Calendar tab —
    /// must not be lost, and must not take the person's sheets away: Updates waits until nothing
    /// is presented, and then appears over Home, where its bell is. `emperor://updates` takes the
    /// same path a tapped update does, and arrives as the app comes back to the front, the
    /// privacy cover lifting as it does.
    func testUpdatesWaitForTheOpenSheetThenAppear() {
        let app = signedIn("-UITestLinkOnReturn", "emperor://updates")
        openTheCalendar(app)
        app.navigationBars["Calendar"].buttons["Subscribe"].tap()
        let subscribe = app.navigationBars["Subscribe"]
        XCTAssertTrue(subscribe.waitForExistence(timeout: 10))

        leaveAndReturn(app)
        XCTAssertTrue(subscribe.waitForExistence(timeout: 10), "the open sheet was taken away")
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(subscribe.exists, "the open sheet was taken away")
        XCTAssertFalse(
            app.navigationBars["Updates"].exists, "Updates was put over the open sheet")

        // Nothing is presented any more, so Updates appears at once — over Home, where its bell
        // is (`AppNotifications` routes an update to Home before it presents).
        subscribe.buttons["Done"].tap()
        let updates = app.navigationBars["Updates"]
        XCTAssertTrue(
            updates.waitForExistence(timeout: 10), "Updates never followed once the sheet closed")

        updates.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["home-profile"].waitForExistence(timeout: 10))
        XCTAssertTrue(becomesSelected(app.tab("Home")), "Updates opens over Home, where its bell is")
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

    /// Waits for the stub's stored answer to be drawn — its reading card is the first thing in
    /// it — so a test knows the conversation has loaded and been kept.
    private func waitForTheStoredAnswer(_ app: XCUIApplication) -> Bool {
        storedWorkLogPanel(app).waitForExistence(timeout: 10)
    }

    /// Back from the conversation to Home, by the bar's leading button — see
    /// `testAToolOpensItsFormAndCanBeRun` for why it is not found by its label.
    private func leaveTheConversation(_ app: XCUIApplication) {
        let bar = app.navigationBars["Conversation"]
        XCTAssertTrue(bar.waitForExistence(timeout: 10))
        bar.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(
            app.stubConversationRow.waitForExistence(timeout: 10),
            "leaving the conversation did not return to Home")
    }

    /// `-UITestOffline` lets every route answer once and then fails it as a phone with no signal
    /// does. A conversation opened once therefore reopens from the copy kept on the device: the
    /// stored answer is there, the bar above the composer says it is the saved copy and how old,
    /// and a question typed into the composer cannot be sent — a saved copy is never posted back.
    func testAConversationOpenedOnceReopensOfflineAndCannotBeAskedFrom() {
        let app = signedIn("-UITestOffline")
        openTheStubConversation(app)
        XCTAssertTrue(waitForTheStoredAnswer(app), "the conversation did not load the first time")
        XCTAssertFalse(app.staticTexts["offline-notice"].exists, "online, there is no notice")

        leaveTheConversation(app)
        app.reveal(app.stubConversationRow)
        app.stubConversationRow.tap()

        let notice = app.staticTexts["offline-notice"].firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 10), "reopened offline with no notice")
        XCTAssertTrue(
            notice.label.hasPrefix("Offline — showing the copy saved"),
            "the notice does not say what it is: \(notice.label)")
        XCTAssertTrue(waitForTheStoredAnswer(app), "the saved copy's answer is not drawn")

        // Typed, so that only the offline rule can be what holds the send back.
        let placeholder = "Ask a follow-up…"
        let field = app.textViews[placeholder].exists
            ? app.textViews[placeholder] : app.textFields[placeholder]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no composer")
        field.focusForTyping()
        field.typeText("Is the limitation extendable?")
        XCTAssertFalse(app.buttons["Send"].firstMatch.isEnabled, "a saved copy must not be asked from")
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// You → Storage counts what was kept — here, the conversation just opened — and clearing it
    /// asks first and then leaves nothing.
    func testStorageOnYouShowsWhatIsKeptAndClearsIt() {
        let app = signedIn()
        openTheStubConversation(app)
        XCTAssertTrue(waitForTheStoredAnswer(app))
        leaveTheConversation(app)

        openYou(app)
        let size = app.staticTexts["offline-storage-size"].firstMatch
        app.reveal(size)
        XCTAssertTrue(size.waitForExistence(timeout: 10), "You has no Storage row")
        XCTAssertNotEqual(size.label, "None", "the conversation just opened was not counted")

        let clear = app.buttons["offline-storage-clear"].firstMatch
        app.reveal(clear)
        let confirm = confirmation("Clear offline copies", afterTapping: clear, in: app)
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
