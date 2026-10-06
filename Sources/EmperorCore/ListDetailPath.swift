import Foundation

/// A list beside what it opens, on a screen wide enough for both — driven by the same path a
/// phone pushes onto.
///
/// On a phone the Cases and Chat tabs push what is opened onto a navigation stack, over the list.
/// On an iPad — any regular-width screen — they show the list in one column and the opened item
/// in the other. Both layouts read **one path**: the phone pushes it, the wide screen shows its
/// last element beside the list. So a request from another tab (`AppNavigator.openCase`) is
/// applied the same way to either, by replacing the path; and rotating a large phone, or resizing
/// an iPad window across the size-class line, keeps what was open rather than dropping it.
///
/// What a tap in the list does to that path is decided here, once, rather than in two views —
/// it is the part of the layout that can be wrong in a way nobody sees until a matter they were
/// reading vanishes.
enum ListDetailPath {

    // MARK: - Selection

    /// The item the detail column shows: the one a phone would have on top.
    static func selection<Route, ID>(in path: [Route], id: (Route) -> ID) -> ID? {
        path.last.map(id)
    }

    /// The path once the list reports a row chosen.
    ///
    /// - **The row already showing changes nothing.** The detail keeps its place, scrolled to
    ///   the section the reader left it on: a list reporting its selection again is not a request
    ///   for a fresh screen. A case the Calendar opened stays the screen that request made, too,
    ///   rather than being swapped for an identical one that reloads.
    /// - **No row changes nothing either.** A list can report that when the chosen row is filtered
    ///   out of sight by a search; the matter is still open, and someone searching for the next
    ///   one has not closed this one.
    /// - **Any other row replaces the path** with that one item. Not appended: the list beside it
    ///   is where every item lives, so what was open before is one tap away there, not something
    ///   to walk back through — the same reasoning as `AppNavigator`'s requests.
    static func selecting<Route, ID: Equatable>(
        _ chosen: ID?, in path: [Route], id: (Route) -> ID, route: (ID) -> Route
    ) -> [Route] {
        guard let chosen, selection(in: path, id: id) != chosen else { return path }
        return [route(chosen)]
    }

    /// `selection(in:id:)` for a path whose elements are the ids themselves, as the Chat tab's
    /// conversation ids are.
    static func selection<ID>(in path: [ID]) -> ID? {
        path.last
    }

    /// `selecting(_:in:id:route:)` for a path whose elements are the ids themselves.
    static func selecting<ID: Equatable>(_ chosen: ID?, in path: [ID]) -> [ID] {
        selecting(chosen, in: path, id: { $0 }, route: { $0 })
    }

    // MARK: - Before anything is chosen

    /// What the detail column says while nothing is open.
    struct Placeholder: Equatable, Sendable {
        let title: String
        let message: String
        /// The SF Symbol, the same mark the list's own tab carries.
        let systemImage: String
    }

    static let chooseCase = Placeholder(
        title: "Choose a case",
        message: "Its overview, hearings and orders open here, beside your docket.",
        systemImage: "briefcase")

    static let chooseConversation = Placeholder(
        title: "Choose a conversation",
        message: "Or start a new one. It opens here, beside the list.",
        systemImage: "bubble.left.and.bubble.right")

    /// The placeholder to draw beside `list`, or `nil` for a plain, empty column.
    ///
    /// Only while the list has something in it to choose. Beside "No matters yet", "Choose a
    /// case" contradicts the screen it sits on; beside a spinner or a failure it points at rows
    /// that are not there. The list's own state says what is going on in each of those, and the
    /// detail column stays quiet. `list` is optional because the list's model is made when its
    /// column first appears, and the detail can be drawn before that.
    static func placeholder(_ placeholder: Placeholder, beside list: ListPresentation?) -> Placeholder? {
        guard let list, !list.isEmpty else { return nil }
        return placeholder
    }
}
