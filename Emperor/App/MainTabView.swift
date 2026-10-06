import SwiftUI

/// The signed-in app.
///
/// **A tab bar, as the web's own mobile navigation is.** `src/shell/MobileNav.jsx` is rendered by
/// `AppShell` under 768px and its comment reads *"Native-app-style bottom tab bar (mobile only).
/// Primary destinations + 'More' (drawer)."* So the platform had already answered what Emperor
/// looks like on a phone, and it answered "a tab bar" — which is also what iOS wants. Android uses
/// a navigation drawer with nineteen rows and no tab bar at all; it is the outlier, not this.
///
/// **The destinations are the product owner's choice, not the web's.** The web's bar is
/// Home · Cases · Chat · Corporate · More, with Corporate (the statutory Corporate Calendar) shown
/// only to Corporate Counsel, Senior Counsel and Litigator. This app's is
/// **Home · Cases · Chat · Calendar · More**, the same for every role: the fourth place goes to
/// the user's own Calendar — their hearings, day by day, and their diary — because every role
/// has hearings to keep, and a deadline register is somewhere one goes rather than lives. The
/// Corporate Calendar moved to More, where every role reaches it (the web's calendar tabs offer
/// it to every role too, `CalendarTabs.jsx`).
///
/// `Library` was a tab once and is now inside **More**, which is where the web puts it too — a
/// place you go occasionally, not a place you live. `Diary` made the same move, was renamed
/// Calendar to match the platform, and is back in the bar for the reason above. `Today` became
/// **Home**, matching the platform's label for the same screen: the thing you open the phone to
/// find out.
///
/// Notifications stay out of the bar. The platform's own dashboard puts them in the topbar as a
/// bell with a count (`src/shell/NotificationBell.jsx`), and the Home screen carries them the
/// same way.
///
/// ## Crossing tabs
///
/// The selected tab lives in an `AppNavigator`, made here and handed down the environment, so
/// one tab can ask another to show something without reaching into it — the Calendar opening a
/// listed case on the Cases tab is the one that does. Made here rather than higher up so that
/// signing out discards it with everything else: a request to open a case must not survive into
/// the next account.
struct MainTabView: View {
    @Environment(\.theme) private var theme

    @State private var navigator = AppNavigator()

    var body: some View {
        TabView(selection: Binding(
            get: { navigator.selectedTab },
            set: { navigator.selectedTab = $0 }
        )) {
            // Outline names throughout: the bar fills each one itself, which is the iOS
            // convention, so every symbol here is one whose filled form reads as clearly as its
            // outline. The marks are the conventional ones for each place — a house, a
            // briefcase for the docket, two speech bubbles for conversations, the calendar page,
            // and the ellipsis iOS uses for "the rest".
            CauseListView()
                .tabItem {
                    Label("Home", systemImage: "house")
                }
                .tag(AppNavigator.Tab.home)

            CaseListView()
                .tabItem {
                    Label("Cases", systemImage: "briefcase")
                }
                .tag(AppNavigator.Tab.cases)

            // Two plain bubbles rather than the bubble with lines of text in it that this was:
            // at tab-bar size the text lines blurred into a grey patch.
            ChatListView()
                .tabItem {
                    Label("Chat", systemImage: "bubble.left.and.bubble.right")
                }
                .tag(AppNavigator.Tab.chat)

            // The calendar page, matching the symbols either side of it — not the web's
            // `CalendarCheck`, which belonged to the Corporate Calendar this place held.
            CalendarView()
                .tabItem {
                    Label("Calendar", systemImage: "calendar")
                }
                .tag(AppNavigator.Tab.calendar)

            MoreView()
                .tabItem {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .tag(AppNavigator.Tab.more)
        }
        .environment(\.navigator, navigator)
        // A tapped notification opens where it leads — the Calendar, or Updates.
        .routesNotificationTaps(to: navigator)
        // A case or document tapped in the device's search opens here too.
        .routesSpotlightResults(to: navigator)
        // The web marks the active item with `--ex-accent` and a soft pill behind the icon.
        // The colour ports; the pill does not — a custom indicator would mean rebuilding the
        // tab bar to draw something iOS already draws, and losing the platform's own
        // accessibility and safe-area behaviour with it. The bar's translucent blur over the
        // canvas is what `.ex-mobilenav` asks for anyway, and iOS gives that by default.
        .tint(theme.accent)
    }
}
