import SwiftUI

/// The Home tab — the redesign's dashboard.
///
/// This first stage holds the shell: the greeting, and the profile button in the bar that opens
/// **You** as a sheet — You left the tab bar, so this is where the account, its plan, Tools and
/// Settings are reached from now on. The composer, the quick actions, the cause list and the
/// drafting cards arrive with the dashboard itself.
struct HomeView: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var isShowingYou = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    header
                }
                .padding(.horizontal, Spacing.gutter)
                .padding(.top, Spacing.sm)
                .padding(.bottom, Spacing.xxxl)
                .frame(maxWidth: ReadableWidth.cap(for: sizeClass))
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(theme.canvas)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .sheet(isPresented: $isShowingYou) {
                YouView()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        TimelineView(.everyMinute) { context in
            SerifHeader(
                eyebrow: AskHome.dateLine(context.date),
                title: AskHome.greetingLine(
                    hour: Calendar.current.component(.hour, from: context.date),
                    name: session.currentUser?.name))
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                isShowingYou = true
            } label: {
                Image(systemName: "person.crop.circle")
            }
            .accessibilityIdentifier("home-profile")
            .accessibilityLabel("Your account")
            .accessibilityHint("Your profile, plan and settings")
        }
    }
}
