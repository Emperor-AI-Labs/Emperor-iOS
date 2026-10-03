import SwiftUI
import UIKit

/// The brand face in the UIKit chrome SwiftUI does not style: navigation titles, large and
/// inline, and segmented controls.
///
/// Applied once, at launch, through the appearance proxies — so every navigation bar in the app,
/// including the ones inside sheets and the system's own pushes, takes the same title without a
/// modifier on fifty screens.
///
/// Only the title attributes are set, never a whole `UINavigationBarAppearance`. Replacing the
/// appearance object replaces its background too, and that would take away the bar the system
/// draws on each release — the scroll-edge transparency, the material, and on iOS 26 the glass —
/// for one this app would then have to keep in step by hand. A font and a colour are all that
/// is wanted, and the legacy attributes are what UIKit builds its default appearance from.
///
/// ## Dynamic Type
///
/// Each font is scaled by `UIFontMetrics` for its text style, so a reader at a large text size
/// gets a larger title — and capped, because a large title that will not fit is truncated
/// rather than wrapped. The scale is read at launch; a size changed while the app is open
/// applies from the next launch, as with any appearance proxy.
///
/// ## Colour
///
/// The title takes the palette's primary text, resolved per trait, so it follows the theme the
/// root view chose with `preferredColorScheme` — including "Match device".
@MainActor
enum BrandAppearance {

    static func apply() {
        // A font that did not register would come back nil and leave the system face, which is
        // the right fallback; `BundleResourceTests` is what notices.
        guard BrandFont.isAvailable else { return }

        let title = titleColor()

        let navigationBar = UINavigationBar.appearance()
        navigationBar.largeTitleTextAttributes = [
            .font: scaled(BrandFont.Name.semibold, size: 34, style: .largeTitle, maximum: 40),
            .foregroundColor: title,
        ]
        navigationBar.titleTextAttributes = [
            .font: scaled(BrandFont.Name.semibold, size: 17, style: .headline, maximum: 22),
            .foregroundColor: title,
        ]

        // The appearance pickers, the My Files sections, the court-search modes. Only the face:
        // the colours stay the system's, which already follow the trait.
        let segmented = UISegmentedControl.appearance()
        segmented.setTitleTextAttributes(
            [.font: scaled(BrandFont.Name.medium, size: 13, style: .footnote, maximum: 19)],
            for: .normal)
        segmented.setTitleTextAttributes(
            [.font: scaled(BrandFont.Name.semibold, size: 13, style: .footnote, maximum: 19)],
            for: .selected)
    }

    /// Built outside the main actor on purpose. UIKit may resolve a dynamic colour wherever it
    /// is drawing, and a closure formed on the main actor would carry that isolation with it —
    /// which Swift 6 checks at run time, and traps on.
    nonisolated private static func titleColor() -> UIColor {
        UIColor { traits in
            UIColor(traits.userInterfaceStyle == .light
                    ? Palette.light.textPrimary
                    : Palette.dark.textPrimary)
        }
    }

    private static func scaled(
        _ name: String, size: CGFloat, style: UIFont.TextStyle, maximum: CGFloat
    ) -> UIFont {
        guard let font = UIFont(name: name, size: size) else {
            return UIFont.preferredFont(forTextStyle: style)
        }
        return UIFontMetrics(forTextStyle: style).scaledFont(for: font, maximumPointSize: maximum)
    }
}

private extension UIColor {
    convenience init(_ colour: PaletteColor) {
        self.init(
            red: colour.red, green: colour.green, blue: colour.blue, alpha: colour.opacity)
    }
}
