import SwiftUI

/// How a screen built for a phone holds itself on an iPad: a readable measure for reading, and
/// sheets large enough to work in.
///
/// Both leave a phone exactly as it was. The measure applies only at a regular width — a phone
/// held sideways is wider than it, but keeps its own layout — and a phone presents every sheet
/// the same way whatever size is asked for.
enum ReadableWidth {
    /// The widest a column of reading runs: 760 points. The conversation's own measure, and the
    /// one every capped screen shares, so an answer, a day's hearings and the month above them
    /// all hold the same line when the tabs are switched.
    static let measure: CGFloat = 760

    /// The measure at a regular width; no limit otherwise.
    ///
    /// No limit rather than a different view, so a screen keeps one identity — and a list its
    /// place — if the width class changes under it.
    static func cap(for sizeClass: UserInterfaceSizeClass?) -> CGFloat {
        sizeClass == .regular ? measure : .infinity
    }
}

extension View {
    /// Caps this content at the readable measure and centres it on a wider screen, with the
    /// canvas painted behind it so the gutters either side do not show the system's background.
    ///
    /// Only at a regular width. On a phone the content keeps the whole screen, and keeps the
    /// background it had — Home's date bar sits on the system's background there, not the
    /// canvas, and must go on doing so.
    ///
    /// For a screen that is one list of rows read top to bottom — Home, the Calendar. On a
    /// 13-inch iPad held sideways such a list ran 1,300 points wide: a row's title at one edge
    /// and its chevron at the other, too far apart to read as one line.
    func readableColumn() -> some View {
        modifier(ReadableColumn())
    }

    /// Presents this sheet at the size of a page on iPad — taller and wider than the form sheet a
    /// sheet gets by default, which held My Files, Settings or the court lookup to a small panel
    /// in the middle of the display with most of the screen scrolled out of sight.
    ///
    /// Applied to the sheet's **content**, which is where SwiftUI reads presentation settings,
    /// not to the view that presents it.
    ///
    /// `presentationSizing` is iOS 18. On iOS 17 the sheet keeps the system's default, a form
    /// sheet: smaller than this, but whole and working.
    @ViewBuilder
    func pageSizedSheet() -> some View {
        if #available(iOS 18.0, *) {
            presentationSizing(.page)
        } else {
            self
        }
    }
}

private struct ReadableColumn: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: ReadableWidth.cap(for: sizeClass))
            .frame(maxWidth: .infinity)
            .background(sizeClass == .regular ? theme.canvas : Color.clear)
    }
}
