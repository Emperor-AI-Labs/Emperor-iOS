import SwiftUI

/// The signed-in app.
///
/// **This is the web app's own mobile navigation, not a choice made here.**
/// `src/shell/MobileNav.jsx` is rendered by `AppShell` under 768px and its comment reads
/// *"Native-app-style bottom tab bar (mobile only). Primary destinations + 'More' (drawer)."*
/// Its items are **Home · Cases · Chat · Corporate · More**. So the platform had already
/// answered what Emperor looks like on a phone, and it answered "a tab bar" — which is also
/// what iOS wants.
///
/// **Corporate is role-gated, exactly as the web gates it**: shown to Corporate Counsel, Senior
/// Counsel and Litigator (`canCompliance` — `corporate`, `counsel`, `litigator`), hidden for the
/// other four. See `PractitionerRole.hasCorporateTab`. The role is read from `Practice`, so the
/// tab appears or goes the moment the role changes in Settings, without a relaunch. The screen
/// behind it, the Corporate Calendar, is open to every role all the same — the others reach it
/// from Calendar, as the web's calendar tabs let them.
///
/// That settles a question the two mobile clients had answered differently: Android uses a
/// navigation drawer with nineteen rows and no tab bar at all. It is the outlier, not this.
///
/// `Library` and `Diary` were tabs once and are now inside **More**, which is where the web puts
/// them too — they are places you go occasionally, not places you live. `Today` becomes
/// **Home**, matching the platform's label for the same screen: the thing you open the phone to
/// find out.
///
/// Notifications stay out of the bar. The platform's own dashboard puts them in the topbar as a
/// bell with a count (`src/shell/NotificationBell.jsx`), and the Home screen carries them the
/// same way.
struct MainTabView: View {
    @Environment(\.theme) private var theme
    @Environment(\.practice) private var practice

    /// Explicit, so a tab that disappears can hand the selection somewhere deliberate.
    @State private var selection: Destination = .home

    private enum Destination: Hashable {
        case home, cases, chat, corporate, more
    }

    var body: some View {
        // Read once per render; `Practice` is observed, so a role change re-renders this.
        let showsCorporate = practice.role.hasCorporateTab
        TabView(selection: $selection) {
            CauseListView()
                .tabItem {
                    Label("Home", systemImage: "house")
                }
                .tag(Destination.home)

            CaseListView()
                .tabItem {
                    Label("Cases", systemImage: "briefcase")
                }
                .tag(Destination.cases)

            ChatListView()
                .tabItem {
                    Label("Chat", systemImage: "bubble.left.and.text.bubble.right")
                }
                .tag(Destination.chat)

            if showsCorporate {
                // The web's `CalendarCheck` icon and its "Corporate" label. The screen owns no
                // stack of its own, because Calendar pushes the same screen into its own.
                NavigationStack {
                    ComplianceCalendarView()
                }
                .tabItem {
                    Label("Corporate", systemImage: "calendar.badge.checkmark")
                }
                .tag(Destination.corporate)
            }

            MoreView()
                .tabItem {
                    Label("More", systemImage: "line.3.horizontal")
                }
                .tag(Destination.more)
        }
        // A role without the tab must not leave the bar pointing at a tab that is gone. Not
        // reachable today — role is chosen in Settings, which the Corporate tab does not
        // offer — but cheap to make impossible rather than merely unlikely.
        .onChange(of: showsCorporate) { _, shows in
            if !shows && selection == .corporate { selection = .home }
        }
        // The web marks the active item with `--ex-accent` and a soft pill behind the icon.
        // The colour ports; the pill does not — a custom indicator would mean rebuilding the
        // tab bar to draw something iOS already draws, and losing the platform's own
        // accessibility and safe-area behaviour with it. The bar's translucent blur over the
        // canvas is what `.ex-mobilenav` asks for anyway, and iOS gives that by default.
        .tint(theme.accent)
    }
}
