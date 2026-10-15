import SwiftUI

/// The signed-in app: the redesign's five destinations, **Home · Cases · Ask · Files · History**.
///
/// - **Home** is the dashboard: the composer that starts a question, the cause list and the
///   drafting section as cards, and the recent conversations. The profile button in its bar
///   opens **You** as a sheet — the account, its plan and allowances, the app's settings — which
///   left the bar in the redesign, along with **Tools**, which holds everything that is not one
///   of the five: the role's workspace, every tool, the file tools, OCR and translation, the
///   Corporate Calendar, Library, drafts and updates.
/// - **Ask** is where a question starts: the date and a greeting, the composer, suggestions for
///   the reader's role, the next sitting from the cause list, and recent conversations.
/// - **Cases** is the cause list and the docket together: the next sitting, what is upcoming,
///   and every matter. The Calendar opens from it.
/// - **Files** is the library.
/// - **History** is every conversation, each pushing its thread.
///
/// Pushed screens — a conversation, a draft, a folder — hide the tab bar (`.toolbar(.hidden,
/// for: .tabBar)` on each), as the design asks.
///
/// ## Crossing tabs
///
/// The selected tab lives in an `AppNavigator`, made here and handed down the environment, so
/// one tab can ask another to show something without reaching into it — a matter opened from the
/// Calendar, "Ask about it" on a hearing. Made here rather than higher up so that signing out
/// discards it with everything else: a request must not survive into the next account.
struct MainTabView: View {
    @Environment(\.theme) private var theme

    @State private var navigator = AppNavigator()

    var body: some View {
        TabView(selection: Binding(
            get: { navigator.selectedTab },
            set: { navigator.selectedTab = $0 }
        )) {
            // Outline names: the bar fills each one itself, which is the iOS convention.
            HomeView()
                .tabItem {
                    Label("Home", systemImage: "house")
                }
                .tag(AppNavigator.Tab.home)

            MattersView()
                .tabItem {
                    Label("Cases", systemImage: "briefcase")
                }
                .tag(AppNavigator.Tab.cases)

            AskHomeView()
                .tabItem {
                    Label("Ask", systemImage: "sparkles")
                }
                .tag(AppNavigator.Tab.ask)

            MyFilesView(isTab: true)
                .tabItem {
                    Label("Files", systemImage: "folder")
                }
                .tag(AppNavigator.Tab.files)

            ChatListView()
                .tabItem {
                    Label("History", systemImage: "clock")
                }
                .tag(AppNavigator.Tab.history)
        }
        .environment(\.navigator, navigator)
        // A tapped notification opens where it leads — the Calendar, or Updates.
        .routesNotificationTaps(to: navigator)
        // A case or document tapped in the device's search opens here too.
        .routesSpotlightResults(to: navigator)
        // The chosen tab in the accent's text colour; the others in the caption colour
        // (`BrandAppearance`). iOS switches tabs instantly, as the design asks.
        .tint(theme.accentText)
    }
}
