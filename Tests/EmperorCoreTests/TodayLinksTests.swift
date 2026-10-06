import XCTest
@testable import EmperorCore

/// The ways into a day from outside the app — the `emperor://` links, the Calendar's pending-day
/// request, a waiting request for Updates — and finding the app group the widget shares.
final class TodayLinksTests: XCTestCase {

    // MARK: - Links

    func testACalendarLinkCarriesItsDay() throws {
        let url = try XCTUnwrap(URL(string: "emperor://calendar?day=2026-10-15"))
        XCTAssertEqual(EmperorLink(url: url), .calendar(day: "2026-10-15"))
    }

    func testLinksAreReadWhicheverWayTheyAreWritten() throws {
        for (text, link) in [
            ("emperor://calendar", EmperorLink.calendar(day: nil)),
            ("EMPEROR://Calendar", .calendar(day: nil)),
            ("emperor:calendar", .calendar(day: nil)),
            ("emperor://calendar/?day=2026-10-15", .calendar(day: "2026-10-15")),
            ("emperor://updates", .updates),
        ] {
            XCTAssertEqual(EmperorLink(url: try XCTUnwrap(URL(string: text))), link, text)
        }
    }

    /// A day that is not a real one opens the Calendar where it is — never somewhere odd.
    func testAMalformedDayOpensTheCalendarWithoutOne() throws {
        for day in ["2026-02-30", "tomorrow", "2026-10-15T00:00:00Z", ""] {
            let url = try XCTUnwrap(URL(string: "emperor://calendar?day=\(day)"))
            XCTAssertEqual(EmperorLink(url: url), .calendar(day: nil), day)
        }
    }

    /// Another scheme, or a destination this build does not know, is not ours — a document
    /// opened in the app must reach whatever handles documents.
    func testOtherURLsAreLeftAlone() throws {
        for text in [
            "file:///private/var/mobile/Order.pdf", "https://app.emperorailabs.com/calendar",
            "emperor://settings", "emperorx://calendar",
        ] {
            XCTAssertNil(EmperorLink(url: try XCTUnwrap(URL(string: text))), text)
        }
    }

    func testLinksAreBuiltTheWayTheyAreRead() {
        let links: [EmperorLink] = [.calendar(day: "2026-10-15"), .calendar(day: nil), .updates]
        XCTAssertEqual(links.map(\.url.absoluteString), [
            "emperor://calendar?day=2026-10-15", "emperor://calendar", "emperor://updates",
        ])
        for link in links {
            XCTAssertEqual(EmperorLink(url: link.url), link)
        }
    }

    /// A link takes the notification-tap path; with no day it means today in India — on the
    /// right side of midnight.
    func testALinkLeadsWhereANotificationWould() {
        let lastSecond = TodaySnapshotTests.lastSecondOfTuesday
        let midnight = TodaySnapshotTests.midnightIntoWednesday
        XCTAssertEqual(EmperorLink.calendar(day: nil).target(now: lastSecond), .calendar(day: "2026-10-13"))
        XCTAssertEqual(EmperorLink.calendar(day: nil).target(now: midnight), .calendar(day: "2026-10-14"))
        XCTAssertEqual(
            EmperorLink.calendar(day: "2026-10-20").target(now: midnight), .calendar(day: "2026-10-20"))
        XCTAssertEqual(EmperorLink.updates.target(now: midnight), .updates)
    }

    // MARK: - The app group

    /// Info.plist's group first, then `group.` + the app's identifier as installed.
    func testTheGroupsAreTriedInOrder() {
        XCTAssertEqual(
            AppGroup.candidates(
                configured: "group.com.emperorailabs.emperor",
                hostBundleIdentifier: "com.emperorailabs.emperor.ABCDE12345"),
            ["group.com.emperorailabs.emperor", "group.com.emperorailabs.emperor.ABCDE12345"])
    }

    /// No setting — or one the build never expanded — falls back to the project's group; a
    /// derived group that is the same is tried once.
    func testAMissingSettingFallsBackToTheDefaultGroup() {
        XCTAssertEqual(
            AppGroup.candidates(configured: nil, hostBundleIdentifier: "com.emperorailabs.emperor"),
            ["group.com.emperorailabs.emperor"])
        XCTAssertEqual(
            AppGroup.candidates(configured: "$(EMPEROR_APP_GROUP)", hostBundleIdentifier: nil),
            [AppGroup.defaultIdentifier])
        XCTAssertEqual(
            AppGroup.candidates(configured: "  ", hostBundleIdentifier: " "),
            [AppGroup.defaultIdentifier])
    }

    /// The first group the system has a container for wins — the renamed one, when the tool
    /// that installed the app renamed it.
    func testTheFirstGroupWithAContainerWins() {
        let candidates = ["group.a", "group.b", "group.c"]
        let renamed = AppGroup.resolve(candidates: candidates) { id in
            id == "group.a" ? nil : URL(fileURLWithPath: "/containers/\(id)")
        }
        XCTAssertEqual(renamed?.identifier, "group.b")
        XCTAssertEqual(renamed?.url.path, "/containers/group.b")

        var asked: [String] = []
        let first = AppGroup.resolve(candidates: candidates) { id in
            asked.append(id)
            return URL(fileURLWithPath: "/containers/\(id)")
        }
        XCTAssertEqual(first?.identifier, "group.a")
        XCTAssertEqual(asked, ["group.a"], "stops at the first")
    }

    /// No group at all — installed without the entitlement — is an answer, not a crash.
    func testNoContainerAnywhereIsNoGroup() {
        XCTAssertNil(AppGroup.resolve(candidates: ["group.a", "group.b"]) { _ in nil })
        XCTAssertNil(AppGroup.resolve(candidates: []) { _ in URL(fileURLWithPath: "/") })
    }

    /// From the widget: the containing app's own identifier, else the widget's minus its last part.
    func testTheWidgetFindsItsAppsIdentifier() {
        XCTAssertEqual(
            AppGroup.hostBundleIdentifier(
                containingAppIdentifier: "com.emperorailabs.emperor.XYZ",
                extensionIdentifier: "something.else.entirely"),
            "com.emperorailabs.emperor.XYZ", "the app's own word first")
        XCTAssertEqual(
            AppGroup.hostBundleIdentifier(
                containingAppIdentifier: nil,
                extensionIdentifier: "com.emperorailabs.emperor.ABCDE12345.widget"),
            "com.emperorailabs.emperor.ABCDE12345")
        XCTAssertNil(AppGroup.hostBundleIdentifier(containingAppIdentifier: nil, extensionIdentifier: "widget"))
        XCTAssertNil(AppGroup.hostBundleIdentifier(containingAppIdentifier: "", extensionIdentifier: nil))
    }

    func testTheContainingAppIsTwoFoldersUp() {
        let widget = URL(fileURLWithPath: "/apps/X/Emperor.app/PlugIns/EmperorWidget.appex")
        XCTAssertEqual(AppGroup.containingAppURL(ofExtensionAt: widget)?.path, "/apps/X/Emperor.app")
        XCTAssertNil(AppGroup.containingAppURL(
            ofExtensionAt: URL(fileURLWithPath: "/apps/X/Emperor.app")))
        XCTAssertNil(AppGroup.containingAppURL(
            ofExtensionAt: URL(fileURLWithPath: "/tmp/Extensions/EmperorWidget.appex")))
    }

    // MARK: - The Calendar's day

    /// A day asked for switches to the Calendar and waits there to be taken — once.
    func testOpeningADaySwitchesToTheCalendarAndIsTakenOnce() async {
        await onMain {
            let navigator = AppNavigator(selectedTab: .home)
            navigator.openCalendar(on: "2026-10-15")

            XCTAssertEqual(navigator.selectedTab, .calendar)
            XCTAssertEqual(navigator.pendingDay, "2026-10-15")
            XCTAssertEqual(navigator.takePendingDay(), "2026-10-15")
            XCTAssertNil(navigator.pendingDay)
            XCTAssertNil(navigator.takePendingDay(), "already applied")
        }
    }

    /// A malformed day still shows the Calendar, on whatever day it was showing.
    func testAMalformedDayOpensTheCalendarWhereItWas() async {
        await onMain {
            let navigator = AppNavigator(selectedTab: .cases)
            navigator.openCalendar(on: "2026-02-30")
            XCTAssertEqual(navigator.selectedTab, .calendar)
            XCTAssertNil(navigator.pendingDay)
            navigator.openCalendar(on: nil)
            XCTAssertNil(navigator.pendingDay)
        }
    }

    func testTheLatestDayWins() async {
        await onMain {
            let navigator = AppNavigator()
            navigator.openCalendar(on: "2026-10-15")
            navigator.openCalendar(on: "2026-10-16")
            XCTAssertEqual(navigator.takePendingDay(), "2026-10-16")
        }
    }

    // MARK: - Updates, waiting

    /// Asking for Updates does not switch tabs — something may be presented, and the sheet the
    /// person is working in must not go with the tab. It waits to be taken, once.
    func testUpdatesWaitWithoutMovingTheTab() async {
        await onMain {
            let navigator = AppNavigator(selectedTab: .calendar)
            navigator.openUpdates()

            XCTAssertEqual(navigator.selectedTab, .calendar)
            XCTAssertNotNil(navigator.updatesRequest)
            XCTAssertTrue(navigator.takeUpdatesRequest())
            XCTAssertNil(navigator.updatesRequest)
            XCTAssertFalse(navigator.takeUpdatesRequest(), "shown once")
        }
    }

    /// A second request while one waits is still a change, so a screen already showing Updates
    /// sees it and reloads.
    func testEachUpdatesRequestIsDistinct() async {
        await onMain {
            let navigator = AppNavigator()
            navigator.openUpdates()
            let first = navigator.updatesRequest
            navigator.openUpdates()
            XCTAssertNotEqual(first, navigator.updatesRequest)
        }
    }

    /// A hearing tapped after an update is the latest request: the Calendar opens on its day and
    /// the waiting Updates screen is dropped, rather than appearing over that day later.
    func testADayAskedForLaterDropsAWaitingUpdatesRequest() async {
        await onMain {
            let navigator = AppNavigator()
            navigator.openUpdates()
            navigator.openCalendar(on: "2026-10-15")
            XCTAssertFalse(navigator.takeUpdatesRequest())
            XCTAssertEqual(navigator.takePendingDay(), "2026-10-15")
        }
    }
}

/// Linux XCTest cannot call a `@MainActor` test method, so each test hops here instead.
@MainActor
private func onMain(_ body: @MainActor () async -> Void) async {
    await body()
}
