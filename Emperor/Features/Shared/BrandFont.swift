import SwiftUI

/// Fredoka — the platform's `--font-brand`.
///
/// `emperor-ai/src/ui/theme.css` sets `--font-brand: 'Fredoka'` for UI and headings and pulls it
/// from Google Fonts by `@import`. An app cannot do that, so the file is bundled
/// (`Emperor/Resources/Fonts/Fredoka.ttf`, SIL OFL 1.1, licence shipped beside it).
///
/// ## Why sizes are not ported
///
/// There is no type scale on the web to port — `theme.css` carries five one-off `font-size`
/// rules and everything else is Tailwind utilities. What *is* canonical is the family and the
/// weights, so those are what came across.
///
/// Sizes stay on iOS's own text styles, deliberately. `PaletteTests` opens by noting the target
/// user skews older and reads this in corridors and daylight; hard-coding the web's `rem` values
/// would freeze the type at one size and break Dynamic Type, which is the single largest
/// accessibility affordance the platform offers. `Font.custom(_:size:relativeTo:)` keeps the
/// scaling and only swaps the family.
///
/// ## The trap
///
/// This is one **variable** font carrying all five weights as named instances, and its default
/// instance is **Light** with a family name of "Fredoka Light". So `Font.custom("Fredoka", …)`
/// resolves to Light, and `UIFont(name: "Fredoka", …)` returns nil. Named instances have to be
/// addressed by their own PostScript names, which is what `Name` holds.
///
/// A wrong name here fails *silently* — SwiftUI substitutes the system font and renders
/// perfectly. `BrandFont.isAvailable` exists so a test can catch that rather than a person
/// noticing the app looks slightly off months later.
enum BrandFont {

    /// PostScript names of the variable font's five named instances, read from its `fvar` table.
    enum Name {
        static let light = "Fredoka-Light"        // wght 300
        static let regular = "Fredoka-Regular"    // wght 400
        static let medium = "Fredoka-Medium"      // wght 500
        static let semibold = "Fredoka-SemiBold"  // wght 600
        static let bold = "Fredoka-Bold"          // wght 700

        static let all = [light, regular, medium, semibold, bold]
    }

    /// The weight iOS itself gives each style, so swapping the family does not silently
    /// change emphasis. `.headline` is semibold on iOS; everything else is regular. Getting
    /// this wrong would flatten every section heading in the app.
    static func defaultWeight(for style: Font.TextStyle) -> Font.Weight {
        style == .headline ? .semibold : .regular
    }

    static func name(for weight: Font.Weight) -> String {
        switch weight {
        case .ultraLight, .thin, .light: return Name.light
        case .medium: return Name.medium
        case .semibold: return Name.semibold
        case .bold, .heavy, .black: return Name.bold
        default: return Name.regular
        }
    }

    /// The size iOS uses for each text style at the default Dynamic Type setting. Passing the
    /// style to `relativeTo:` is what makes the custom font scale with the user's setting
    /// instead of pinning it here.
    static func size(for style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: return 34
        case .title: return 28
        case .title2: return 22
        case .title3: return 20
        case .headline: return 17
        case .body: return 17
        case .callout: return 16
        case .subheadline: return 15
        case .footnote: return 13
        case .caption: return 12
        case .caption2: return 11
        @unknown default: return 17
        }
    }

    /// Whether the bundled font actually registered.
    ///
    /// Checked by `BrandFontTests` in the simulator, because every failure mode here is silent:
    /// a missing `UIAppFonts` entry, a resource that did not make it into the bundle, or a
    /// PostScript name that does not match the `fvar` table all end in the system font.
    static var isAvailable: Bool {
        #if canImport(UIKit)
        return UIFont(name: Name.regular, size: 17) != nil
        #else
        return false
        #endif
    }
}

extension Font {
    /// The brand face at an iOS text style, scaling with Dynamic Type.
    ///
    /// `.brand(.headline)` rather than `.headline` is the whole change at a call site. Omitting
    /// the weight gives whatever iOS gives that style, so a sweep cannot change emphasis by
    /// accident.
    static func brand(_ style: Font.TextStyle, weight: Font.Weight? = nil) -> Font {
        .custom(
            BrandFont.name(for: weight ?? BrandFont.defaultWeight(for: style)),
            size: BrandFont.size(for: style),
            relativeTo: style)
    }
}
