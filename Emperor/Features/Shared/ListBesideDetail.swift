import SwiftUI

/// A list in one column and what it opens in the other — the Cases and Chat tabs on an iPad.
///
/// On a phone those tabs push what is opened over the list, and opening a matter or a
/// conversation on an iPad did the same: the whole screen was replaced, and moving from one case
/// to the next meant Back, find, tap, every time. Here the list stays on screen and the detail
/// column changes beside it, which is how Mail and Notes work on the same device.
///
/// Used only at a regular horizontal size class; the tabs choose, and keep their phone layout
/// otherwise. Both layouts read the same navigation path — see `ListDetailPath`.
///
/// ## Both columns, always
///
/// `.balanced` with every column visible, rather than the system's automatic choice. In portrait —
/// the way an iPad is most often held — the automatic style hides the list behind a button and
/// shows the detail alone, which is the phone's layout again with an extra tap. Balanced keeps
/// the list beside the detail and narrows the detail to make room. The sidebar button still
/// folds the list away when a long order or answer wants the whole width.
///
/// ## A fresh detail per item
///
/// The detail column's stack is rebuilt — `.id(detailID)` — whenever a different item opens, so
/// the new one starts on its own first screen with its own view model. Without it SwiftUI keeps
/// the same `CaseDetailView` and hands it a new id, and a view that builds its model once in
/// `.task` goes on showing the matter it opened first. Anything pushed inside the detail stays in
/// the detail column, in that stack, and goes with it.
struct ListBesideDetail<DetailID: Hashable, ListColumn: View, DetailColumn: View>: View {
    /// What the detail column is showing, by identity — `nil` for nothing. A change replaces the
    /// column's stack.
    let detailID: DetailID
    @ViewBuilder let list: () -> ListColumn
    @ViewBuilder let detail: () -> DetailColumn

    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            list()
                // Wide enough for a case title on two lines and a court beside its number;
                // narrow enough that the detail keeps the larger share of a portrait screen.
                .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 420)
        } detail: {
            NavigationStack {
                detail()
            }
            .id(detailID)
        }
        .navigationSplitViewStyle(.balanced)
    }
}

/// The detail column while nothing is open: what opens there, in the app's empty-state style —
/// or, while the list beside it has nothing to choose, a plain canvas (see
/// `ListDetailPath.placeholder(_:beside:)`).
///
/// Neutral rather than the accent: this is a resting state, not something asking to be done.
struct DetailPlaceholder: View {
    @Environment(\.theme) private var theme

    let placeholder: ListDetailPath.Placeholder?

    var body: some View {
        Group {
            if let placeholder {
                EmptyStateView(
                    placeholder.title,
                    systemImage: placeholder.systemImage,
                    message: placeholder.message,
                    tone: .neutral)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.canvas)
    }
}

/// The card behind a list row, tinted with the accent while its item is the one open beside the
/// list — the one sign, in a long docket, of which matter the detail column is showing.
///
/// Drawn here rather than left to the list's own selection highlight, which does not show
/// through a custom row background, and every row in these lists has one. On a phone nothing is
/// ever selected, so this is the plain surface the rows always had.
struct ListRowCard: View {
    @Environment(\.theme) private var theme

    let isSelected: Bool

    var body: some View {
        ZStack {
            theme.surface
            if isSelected {
                theme.surfaceAccent
            }
        }
    }
}
