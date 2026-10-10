import SwiftUI

/// The signed-in app: the Record design's four destinations, **Ask · Matters · Files · You**.
///
/// - **Ask** is where a question starts: the date and a greeting, the composer, suggestions for
///   the reader's role, the next sitting from the cause list, and recent conversations. Every
///   conversation is reached from here — the recent ones on the screen, all of them under History.
/// - **Matters** is the cause list and the docket together: the next sitting, what is upcoming,
///   and every matter. The Calendar opens from it.
/// - **Files** is the library.
/// - **You** is the account, its plan and allowances, the app's settings — and **Tools**, which
///   holds everything that is not one of the four: the role's workspace, every tool, the file
///   tools, OCR and translation, the Corporate Calendar, Library, drafts and updates. Nothing that
///   was in the old More tab has been taken out of the app.
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
            AskHomeView()
                .tabItem {
                    Label("Ask", systemImage: "text.bubble")
                }
                .tag(AppNavigator.Tab.ask)

            MattersView()
                .tabItem {
                    Label("Matters", systemImage: "scalemass")
                }
                .tag(AppNavigator.Tab.matters)

            MyFilesView(isTab: true)
                .tabItem {
                    Label("Files", systemImage: "folder")
                }
                .tag(AppNavigator.Tab.files)

            YouView()
                .tabItem {
                    Label("You", systemImage: "person.crop.circle")
                }
                .tag(AppNavigator.Tab.you)
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
