import SwiftUI
import UIKit

/// The signed-in app: **Home · Matters · Ask · Calendar · More**.
///
/// - **Home** is the dashboard: the composer that starts a question, the cause list and the
///   Precedents Vault as cards, and the recent conversations. The profile button in its bar
///   opens **You** as a sheet — the account, its plan and allowances, the app's settings, and
///   Tools (the role's workspace, every tool, the file tools, OCR and Translate, the Corporate
///   Calendar, Library, drafts and updates).
/// - **Matters** is the cause list and the docket together: the next sitting, what is upcoming,
///   and every matter.
/// - **Ask** is where a question starts: the composer, and suggestions for the reader's role.
///   Its tab icon is the Record mark — the logo, where the sparkle was.
/// - **Calendar** is the matters day by day, and the diary.
/// - **More** holds what is not a tab: Files, History, and the web sidebar's Case tools and
///   Doc tools rows (drawn for their shape; not yet wired to screens).
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
                    Label("Matters", systemImage: "folder")
                }
                .tag(AppNavigator.Tab.matters)

            AskHomeView()
                .tabItem {
                    Label {
                        Text("Ask")
                    } icon: {
                        Image(uiImage: Self.askMarkImage())
                    }
                }
                .tag(AppNavigator.Tab.ask)

            CalendarView()
                .tabItem {
                    Label("Calendar", systemImage: "calendar")
                }
                .tag(AppNavigator.Tab.calendar)

            MoreTabView()
                .tabItem {
                    Label("More", systemImage: "line.3.horizontal")
                }
                .tag(AppNavigator.Tab.more)
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

    /// The two-stroke Record mark, rendered once from its shape as a template image for the tab
    /// bar — template, so the bar tints it like every other icon.
    ///
    /// `ImageRenderer` rather than a bundled asset: the mark already exists as a `Shape`
    /// (`RecordMarkShape`) and the asset catalogue's copy is marked "original", which would
    /// resist the bar's tint.
    @MainActor
    private static func askMarkImage() -> UIImage {
        let height: CGFloat = 30
        let content = RecordMarkShape()
            .fill(Color.black)
            .frame(
                width: height * CGFloat(RecordMark.viewBox.width / RecordMark.viewBox.height),
                height: height)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 3
        return (renderer.uiImage ?? UIImage()).withRenderingMode(.alwaysTemplate)
    }
}
