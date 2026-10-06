import SwiftUI
import UIKit

/// Presents a screen over whatever is showing — for things that arrive from outside the app.
///
/// A document handed over from another app, or a search result tapped on the Home Screen, comes
/// whenever the person chooses, and very often while one of More's screens is already up as a
/// sheet. A SwiftUI `.sheet` attached to the tab view cannot be shown over a sheet a child view is
/// already presenting: UIKit allows each controller one presentation, and SwiftUI does not queue
/// the second — it simply never appears. So this presents from the top-most controller instead,
/// and what it presents always shows, over whatever is there.
///
/// What it presents closes through the `close` closure it is handed rather than through
/// `@Environment(\.dismiss)`, which is wired to SwiftUI's own presentations.
@MainActor
final class TopPresenter {
    private weak var presented: UIViewController?

    /// Whether something this presented is still on screen.
    var isPresenting: Bool {
        guard let presented else { return false }
        return presented.presentingViewController != nil && !presented.isBeingDismissed
    }

    /// - Parameter modal: when `true`, the sheet cannot be swiped away — it asks a question
    ///   that needs an answer.
    func present<Content: View>(_ content: Content, modal: Bool) {
        guard !isPresenting, let top = Self.topController() else { return }
        let host = UIHostingController(rootView: content)
        // A form sheet: centred on iPad, the standard card on iPhone — what `.sheet` gives.
        host.modalPresentationStyle = .formSheet
        host.isModalInPresentation = modal
        top.present(host, animated: true)
        presented = host
    }

    /// Closes what this presented, and anything it went on to present over itself.
    func dismiss(animated: Bool = true) {
        guard let presented else { return }
        // Asked of the controller underneath: asking the presented one would close only what it
        // is presenting in turn — a preview opened from it — and leave it up.
        presented.presentingViewController?.dismiss(animated: animated)
        self.presented = nil
    }

    /// The controller everything else is presented over: the key window's root, followed up
    /// through whatever it presents.
    static func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let active = scenes.filter { $0.activationState == .foregroundActive }
        let windows = (active.isEmpty ? scenes : active).flatMap(\.windows)
        guard var top = (windows.first(where: \.isKeyWindow) ?? windows.first)?.rootViewController
        else { return nil }
        while let next = top.presentedViewController, !next.isBeingDismissed {
            top = next
        }
        return top
    }
}
