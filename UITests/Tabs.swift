import XCTest

extension XCUIApplication {
    /// The SF Symbol each tab is drawn with — on iPad the only identifier its button carries.
    private static let tabSymbols = [
        "Home": "house",
        "Cases": "briefcase",
        "Ask": "sparkles",
        "Files": "folder",
        "History": "clock",
    ]

    /// A tab, wherever this device draws the bar.
    ///
    /// On iPhone the tabs live in a tab bar along the bottom. On iPad (iPadOS 18 and later) the
    /// same `TabView` draws them as a row of buttons across the top, with no tab bar element at
    /// all — so `tabBars.buttons["Ask"]` finds nothing there, and every test that started from a
    /// tab failed on iPad while the app itself was fine. Matched on label *and* symbol, because an
    /// iPad screen can carry a second button with the same label (a toolbar's "More").
    func tab(_ name: String) -> XCUIElement {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return tabBars.buttons[name] }
        let symbol = Self.tabSymbols[name] ?? name
        return buttons.matching(
            NSPredicate(format: "label == %@ AND identifier == %@", name, symbol)).firstMatch
    }
}

extension XCUIElement {
    /// Taps a text or search field until it actually holds the keyboard, then returns.
    ///
    /// On iPad a tap can land while a search field in the navigation bar is still settling and
    /// leave nothing focused, and `typeText` then fails outright with "neither element nor any
    /// descendant has keyboard focus" — on a field that works perfectly by hand. Asking the field
    /// whether it has focus, and tapping again if not, makes typing deterministic on both devices.
    func focusForTyping() {
        for _ in 0..<4 {
            tap()
            for _ in 0..<10 {
                if (value(forKey: "hasKeyboardFocus") as? Bool) == true { return }
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
    }
}

extension XCUIApplication {
    /// The stub's stored conversation, "Bakshi v. State" — among Ask's recent conversations, where
    /// its row is one button (`chat-row-c1`), or in History's list, where its title can be a text
    /// of its own. Found by either, so a test reads the same wherever it opens it.
    var stubConversationRow: XCUIElement {
        descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ OR (elementType == %d AND label == %@)",
            "chat-row-c1", XCUIElement.ElementType.staticText.rawValue, "Bakshi v. State"))
            .firstMatch
    }
}

extension XCUIApplication {
    /// Signs in the way the sign-in screen's code segment leads: choose the code, the address,
    /// "Email me a sign-in code", then the six digits. A full code goes on without a tap, as code
    /// fields do elsewhere on the phone. The stub answers `/auth/otp/request` and
    /// `/auth/otp/verify`, so this drives the real `SignInFlow`, `AuthService` and the
    /// signed-out → signed-in transition.
    ///
    /// Returns whether every step was there to take; it does not wait for the app behind it,
    /// because what comes next — the tabs, a role question, a document to save — is each test's
    /// own subject.
    @discardableResult
    func signInWithACode(_ address: String = "john.doe@firm.com") -> Bool {
        let email = textFields["Email"]
        guard email.waitForExistence(timeout: 15) else { return false }

        // The screen opens on the password; the code is behind its own segment.
        let codeSegment = buttons["Sign in with code"].firstMatch
        guard codeSegment.waitForExistence(timeout: 5) else { return false }
        codeSegment.tap()

        email.focusForTyping()
        email.typeText(address)

        let send = buttons["Email me a sign-in code"].firstMatch
        guard send.waitForExistence(timeout: 5) else { return false }
        send.tap()

        let code = textFields["Sign-in code"]
        guard code.waitForExistence(timeout: 10) else { return false }
        code.focusForTyping()
        code.typeText("123456")
        return true
    }

    /// Scrolls until `element` can be tapped: up first, then back down — a list builds only the
    /// rows near what it shows, and a row may be above the screen as easily as below it once the
    /// list has been scrolled for an earlier one.
    func reveal(_ element: XCUIElement) {
        var swipes = 0
        while !(element.exists && element.isHittable) && swipes < 6 {
            swipeUp()
            swipes += 1
        }
        swipes = 0
        while !(element.exists && element.isHittable) && swipes < 8 {
            swipeDown()
            swipes += 1
        }
    }
}
