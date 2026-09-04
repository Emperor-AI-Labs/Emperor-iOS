import SwiftUI

/// The signed-in app.
///
/// **This is the web app's own mobile navigation, not a choice made here.**
/// `src/shell/MobileNav.jsx` is rendered by `AppShell` under 768px and its comment reads
/// *"Native-app-style bottom tab bar (mobile only). Primary destinations + 'More' (drawer)."*
/// Its items are **Home · Cases · Chat · More**, with a role-gated Corporate entry this client
/// has no equivalent for. So the platform had already answered what Emperor looks like on a
/// phone, and it answered "a tab bar" — which is also what iOS wants.
///
/// That settles a question the two mobile clients had answered differently: Android uses a
/// navigation drawer with nineteen rows and no tab bar at all. It is the outlier, not this.
///
/// Four entries where there were five. `Library` and `Diary` were tabs and are now inside
/// **More**, which is where the web puts them too — they are places you go occasionally, not
/// places you live. `Today` becomes **Home**, matching the platform's label for the same
/// screen: the thing you open the phone to find out.
///
/// Notifications stay out of the bar. The platform's own dashboard puts them in the topbar as a
/// bell with a count (`src/shell/NotificationBell.jsx`), and the Home screen carries them the
/// same way.
struct MainTabView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        TabView {
            CauseListView()
                .tabItem {
                    Label("Home", systemImage: "house")
                }

            CaseListView()
                .tabItem {
                    Label("Cases", systemImage: "briefcase")
                }

            ChatListView()
                .tabItem {
                    Label("Chat", systemImage: "bubble.left.and.text.bubble.right")
                }

            MoreView()
                .tabItem {
                    Label("More", systemImage: "line.3.horizontal")
                }
        }
        // The web marks the active item with `--ex-accent` and a soft pill behind the icon.
        // The colour ports; the pill does not — a custom indicator would mean rebuilding the
        // tab bar to draw something iOS already draws, and losing the platform's own
        // accessibility and safe-area behaviour with it. The bar's translucent blur over the
        // canvas is what `.ex-mobilenav` asks for anyway, and iOS gives that by default.
        .tint(theme.accent)
    }
}
