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
/// rather than the first screen's.
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

    /// Home, Cases, the chat list and a conversation, Calendar and More — in the dark theme, the
    /// app's default.
    func testTheTabsPassTheAudit() {
        let app = launch()
        guard signIn(app) else { return }
        auditTheTabs(of: app, theme: "")
    }

    /// The sign-in screen and the same tabs in the light theme. Contrast is a property of a pair
    /// of colours, and the light palette is a different set of pairs — a colour from outside it
    /// can pass on dark and fail here.
    func testTheTabsPassTheAuditInLight() {
        let app = launch("-UITestLight")
        guard reached(app.textFields["Email"], "the sign-in screen") else { return }
        audit("light-sign-in", in: app)
        guard signIn(app) else { return }
        auditTheTabs(of: app, theme: "light-")
    }

    private func auditTheTabs(of app: XCUIApplication, theme: String) {
        // Each tab's title, and something its stub data puts on screen once it has loaded — so
        // the audit sees the screen a person sees, not its spinner.
        let tabs: [(tab: String, title: String, loaded: XCUIElement)] = [
            ("Home", "Home", app.descendants(matching: .any).matching(
                NSPredicate(format: "label BEGINSWITH %@", "Item 7, Court 12")).firstMatch),
            ("Cases", "Cases", app.navigationBars["Cases"]),
            ("Chat", "Emperor", app.stubConversationRow),
            ("Calendar", "Calendar", app.buttons["calendar-listing-case1"]),
            ("More", "More", app.buttons["Settings"]),
        ]
        for (tab, title, loaded) in tabs {
            let button = app.tab(tab)
            guard reached(button, "the \(tab) tab") else { continue }
            button.tap()
            _ = app.navigationBars[title].waitForExistence(timeout: 10)
            _ = loaded.waitForExistence(timeout: 10)
            audit(theme + tab.lowercased(), in: app)

            if tab == "Chat" {
                // A conversation: the stub's stored answer, its work log collapsed above it.
                let conversation = app.stubConversationRow
                guard reached(conversation, "the stored conversation") else { continue }
                conversation.tap()
                _ = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Worked"))
                    .firstMatch.waitForExistence(timeout: 10)
                audit(theme + "conversation", in: app)
                // Back to the list, so the next tab is reached from where a person would be.
                let back = app.navigationBars["Conversation"].buttons.element(boundBy: 0)
                if back.exists { back.tap() }
            }
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
                    form.buttons.element(boundBy: 0).tap()
                }
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
    /// Security and Storage sections, each audited with Settings scrolled to it.
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
                picker.buttons.element(boundBy: 0).tap()
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
                notifications.buttons.element(boundBy: 0).tap()
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
                form.buttons.element(boundBy: 0).tap()
            }
        }

        // The app lock's section, then Storage — rows of Settings itself, so Settings is
        // scrolled until each is on screen and audited as it then stands.
        _ = settings.waitForExistence(timeout: 10)
        for (identifier, screen, what) in [
            ("app-lock-toggle", "settings-security", "the Security section"),
            ("offline-storage-clear", "settings-storage", "the Storage section"),
        ] {
            let anchor = app.descendants(matching: .any)[identifier].firstMatch
            scrollUntilHittable(anchor, in: app)
            if reached(anchor, what) {
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
        guard reached(button, "the \(row) row in More") else { return nil }
        scrollUntilHittable(button, in: app)
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

        // On the main actor, where the audit, its handler and every element it names live — and
        // everything that touches them stays inside. Gathering into an array declared out here
        // would send that array across actors, which Swift 6 refuses to compile; so the issues
        // are gathered and turned into plain `AuditFinding`s in the block, and only those (all
        // `Sendable`) come out. UI tests run on the main thread, so asserting the isolation is
        // true, not a cast. `facts` is static so the block captures no test case.
        let outcome: AuditOutcome = MainActor.assumeIsolated {
            var gathered: [XCUIAccessibilityAuditIssue] = []
            do {
                try app.performAccessibilityAudit { issue in
                    gathered.append(issue)
                    return true
                }
            } catch {
                return .couldNotRun(String(describing: error))
            }
            return .ran(gathered.map { issue in
                AuditFinding(
                    kind: issue.auditType,
                    summary: issue.compactDescription,
                    detail: issue.detailedDescription,
                    element: Self.facts(about: issue.element))
            })
        }
        let findings: [AuditFinding]
        switch outcome {
        case .couldNotRun(let reason):
            XCTFail(
                "[\(screen)] the accessibility audit could not run: \(reason)",
                file: file, line: line)
            return
        case .ran(let found):
            findings = found
        }

        var waived: [String] = []
        var failures = 0
        for finding in findings {
            if let waiver = Waiver.allCases.first(where: { $0.applies(to: finding, in: context) }) {
                waived.append("\(finding.report)\n    waived — \(waiver.reason)")
            } else {
                failures += 1
                XCTFail("[\(screen)] \(finding.report)", file: file, line: line)
            }
        }

        if failures > 0 {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "a11y-audit-\(screen)"
            shot.lifetime = .keepAlways
            add(shot)
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

    /// The facts about an element the report and the waivers need, read once while it is there.
    private static func facts(about element: XCUIElement?) -> AuditFinding.Element? {
        guard let element, element.exists else { return nil }
        return AuditFinding.Element(
            kind: element.elementType,
            label: element.label,
            identifier: element.identifier,
            frame: element.frame,
            isEnabled: element.isEnabled)
    }

    /// Where the system's own furniture is on screen as the audit runs.
    private func layout(of app: XCUIApplication, sheet: XCUIElement?) -> AuditLayout {
        let window = app.windows.firstMatch.frame
        let keyboard = app.keyboards.firstMatch
        let tabBar = app.tabBars.firstMatch
        var sheetFrame: CGRect?
        if let sheet, sheet.exists {
            // From the sheet's bar to the foot of the window, across the sheet's width — the whole
            // form sheet on an iPad, everything below the dimmed strip on an iPhone.
            let bar = sheet.frame
            sheetFrame = CGRect(
                x: bar.minX, y: bar.minY, width: bar.width, height: max(0, window.maxY - bar.minY))
        }
        return AuditLayout(
            window: window,
            keyboard: keyboard.exists ? keyboard.frame : nil,
            tabBar: tabBar.exists ? tabBar.frame : nil,
            navigationBars: app.navigationBars.allElementsBoundByIndex
                .filter { $0.exists }
                .map { $0.frame },
            sheet: sheetFrame)
    }
}

// MARK: - Findings and waivers

/// One issue the audit raised, as plain facts.
/// What one audit came back with: its findings, or why it could not run. Plain values, so it can
/// leave the main-actor block the audit runs in.
private enum AuditOutcome: Sendable {
    case ran([AuditFinding])
    case couldNotRun(String)
}

private struct AuditFinding: Sendable {
    struct Element: Sendable {
        let kind: XCUIElement.ElementType
        let label: String
        let identifier: String
        let frame: CGRect
        let isEnabled: Bool
    }

    let kind: XCUIAccessibilityAuditType
    let summary: String
    let detail: String
    let element: Element?

    /// "contrast — Contrast failed. <detail> Element: button "Done" (id "Done"), at (16, 54)
    /// 60×44." Everything needed to find it, on one line.
    var report: String {
        var parts = ["\(AuditFinding.name(of: kind)) — \(summary)"]
        if !detail.isEmpty, detail != summary { parts.append(detail) }
        parts.append("Element: \(elementDescription)")
        return parts.joined(separator: " ")
    }

    private var elementDescription: String {
        guard let element else { return "none named by the audit." }
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
private struct AuditLayout {
    let window: CGRect
    let keyboard: CGRect?
    let tabBar: CGRect?
    let navigationBars: [CGRect]
    /// The presented sheet's extent, when the screen audited is one.
    let sheet: CGRect?
}

/// An issue the audit raises that is not this app's to fix, and why.
///
/// Kept short on purpose. Each one is either something the system draws, or a reading the audit
/// cannot make where it is looking; none is "this is hard". A new kind of finding is fixed in the
/// app, not added here, unless it is plainly one of those two things.
private enum Waiver: CaseIterable {
    case systemKeyboard
    case inactiveControl
    case tabBarTitleSize
    case behindTheSheet
    case partlyUnderABar

    var reason: String {
        switch self {
        case .systemKeyboard:
            return "the system keyboard is Apple's, drawn in its own process; nothing in this app "
                + "styles a key."
        case .inactiveControl:
            return "a disabled control is dimmed on purpose, to read as unavailable, and WCAG 1.4.3 "
                + "exempts inactive controls from the contrast minimum."
        case .tabBarTitleSize:
            return "UIKit's tab bar keeps its titles at one size by design and offers the Large "
                + "Content Viewer instead (press and hold an item); the app draws none of it."
        case .behindTheSheet:
            return "wholly outside the sheet being audited: the screen it was opened from, dimmed "
                + "by the system while the sheet is up. That screen has an audit of its own."
        case .partlyUnderABar:
            return "part-way under a translucent navigation or tab bar as the list scrolls, so the "
                + "text is measured against the bar's blur and cut by its edge — not by the layout."
        }
    }

    func applies(to finding: AuditFinding, in layout: AuditLayout) -> Bool {
        guard let element = finding.element else { return false }
        let frame = element.frame
        switch self {
        case .systemKeyboard:
            if element.kind == .key || element.kind == .keyboard { return true }
            guard let keyboard = layout.keyboard else { return false }
            return keyboard.contains(frame)

        case .inactiveControl:
            return finding.kind.contains(.contrast) && !element.isEnabled

        case .tabBarTitleSize:
            guard finding.kind.contains(.dynamicType) else { return false }
            if let tabBar = layout.tabBar, tabBar.contains(frame) { return true }
            // On an iPad (iPadOS 18 and later) the tabs are buttons across the top, with no tab
            // bar element; each carries its SF Symbol as its identifier — see `Tabs.swift`.
            let tabs = [
                "Home": "house", "Cases": "briefcase", "Chat": "bubble.left.and.bubble.right",
                "Calendar": "calendar", "More": "ellipsis.circle",
            ]
            return tabs[element.label] == element.identifier

        case .behindTheSheet:
            guard let sheet = layout.sheet, !frame.isEmpty else { return false }
            return !sheet.intersects(frame)

        case .partlyUnderABar:
            guard finding.kind.contains(.contrast) || finding.kind.contains(.textClipped) else {
                return false
            }
            let bars = layout.navigationBars + [layout.tabBar].compactMap { $0 }
            let underABar = bars.contains { $0.intersects(frame) && !$0.contains(frame) }
            let offScreen = !layout.window.isEmpty && !layout.window.contains(frame)
            return underABar || offScreen
        }
    }
}
