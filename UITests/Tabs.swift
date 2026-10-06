import XCTest

extension XCUIApplication {
    /// The SF Symbol each tab is drawn with — on iPad the only identifier its button carries.
    private static let tabSymbols = [
        "Home": "house",
        "Cases": "briefcase",
        "Chat": "bubble.left.and.bubble.right",
        "Calendar": "calendar",
        "More": "ellipsis.circle",
    ]

    /// A tab, wherever this device draws the bar.
    ///
    /// On iPhone the tabs live in a tab bar along the bottom. On iPad (iPadOS 18 and later) the
    /// same `TabView` draws them as a row of buttons across the top, with no tab bar element at
    /// all — so `tabBars.buttons["Home"]` finds nothing there, and every test that started from a
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
    /// The stub's stored conversation, "Bakshi v. State", in the chat list — wherever this device
    /// draws it. On a phone its title is a text of its own; on an iPad, where the list sits beside
    /// the conversation and keeps a selection, the row is one button (`chat-row-c1`) and its title
    /// is not exposed separately. Found by either, so a test reads the same on both.
    var stubConversationRow: XCUIElement {
        descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ OR (elementType == %d AND label == %@)",
            "chat-row-c1", XCUIElement.ElementType.staticText.rawValue, "Bakshi v. State"))
            .firstMatch
    }
}
