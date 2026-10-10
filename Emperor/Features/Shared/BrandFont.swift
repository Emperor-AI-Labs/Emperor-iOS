import SwiftUI

/// The Record faces: **Plus Jakarta Sans** for the interface and **Instrument Serif** for large
/// titles, greetings, document titles and the numbers people scan for — item numbers, days.
///
/// Both are SIL OFL 1.1 and bundled (`Emperor/Resources/Fonts`, licences beside them), because an
/// app cannot `@import` from Google Fonts as the web does. The family, weights and roles are the
/// design's (`Design/record-tokens.json`, `font` and `type`).
///
/// ## Sizes follow Dynamic Type
///
/// `Font.custom(_:size:relativeTo:)` everywhere: the size is the design's at the default text
/// size, and the text style it is relative to scales it with the reader's setting — up to AX5,
/// which the design asks to be honoured. Nothing here pins a size.
///
/// ## Static files, named instances
///
/// Plus Jakarta Sans is bundled as four static files (400, 500, 600, 700) rather than Google
/// Fonts' variable one, whose named instances carry no PostScript names: `UIFont(name:)` could not
/// address a weight by name and would silently return the default. Each static file carries its
/// own name, which is what `Name` holds.
///
/// A wrong name fails *silently* — SwiftUI substitutes the system font and renders perfectly.
/// `BrandFont.isAvailable` exists so `BundleResourceTests` can catch that.
enum BrandFont {

    /// PostScript names, read from each file's `name` table.
    enum Name {
        static let regular = "PlusJakartaSans-Regular"    // 400
        static let medium = "PlusJakartaSans-Medium"      // 500
        static let semibold = "PlusJakartaSans-SemiBold"  // 600
        static let bold = "PlusJakartaSans-Bold"          // 700

        static let all = [regular, medium, semibold, bold]

        /// Instrument Serif, roman and italic — the display face. One weight, 400.
        static let display = "InstrumentSerif-Regular"
        static let displayItalic = "InstrumentSerif-Italic"

        static let displayAll = [display, displayItalic]
    }

    /// The weight iOS itself gives each style, so swapping the family does not silently
    /// change emphasis. `.headline` is semibold on iOS; everything else is regular.
    static func defaultWeight(for style: Font.TextStyle) -> Font.Weight {
        style == .headline ? .semibold : .regular
    }

    /// The nearest bundled weight. Light and thinner fall to Regular — Record uses nothing
    /// lighter than 400 — and the heavy weights to Bold.
    static func name(for weight: Font.Weight) -> String {
        switch weight {
        case .medium: return Name.medium
        case .semibold: return Name.semibold
        case .bold, .heavy, .black: return Name.bold
        default: return Name.regular
        }
    }

    /// The size iOS uses for each text style at the default Dynamic Type setting — which is also
    /// the Record iOS scale where the two overlap (body 17, callout 15 as `subheadline`,
    /// footnote 13). Passing the style to `relativeTo:` is what makes the face scale.
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

    /// Whether the bundled interface face actually registered.
    static var isAvailable: Bool {
        #if canImport(UIKit)
        return UIFont(name: Name.regular, size: 17) != nil
        #else
        return false
        #endif
    }

    /// Whether the serif registered.
    static var isDisplayAvailable: Bool {
        #if canImport(UIKit)
        return UIFont(name: Name.display, size: 17) != nil
        #else
        return false
        #endif
    }
}

extension Font {
    /// The interface face at an iOS text style, scaling with Dynamic Type.
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

    /// The interface face at an exact Record size, scaling with Dynamic Type relative to `style`.
    static func brand(size: CGFloat, weight: Font.Weight = .regular, relativeTo style: Font.TextStyle) -> Font {
        .custom(BrandFont.name(for: weight), size: size, relativeTo: style)
    }

    /// Instrument Serif at a Record size, scaling with Dynamic Type relative to `style`.
    static func display(size: CGFloat, italic: Bool = false, relativeTo style: Font.TextStyle) -> Font {
        .custom(
            italic ? BrandFont.Name.displayItalic : BrandFont.Name.display,
            size: size, relativeTo: style)
    }

    /// A step of the Record type scale (`RecordTokens.Typography`), in its own face and weight.
    static func record(_ style: RecordTokens.TextStyle) -> Font {
        let size = CGFloat(style.size)
        let relative = RecordType.textStyle(for: style)
        switch style.role {
        case .display:
            return .display(size: size, relativeTo: relative)
        case .ui:
            return .brand(size: size, weight: RecordType.weight(style.weight), relativeTo: relative)
        }
    }
}

/// How a Record type step maps onto iOS: the text style it scales with, its weight, and its
/// letter spacing in points.
enum RecordType {
    static func weight(_ css: Int) -> Font.Weight {
        switch css {
        case ..<500: return .regular
        case 500..<600: return .medium
        case 600..<700: return .semibold
        default: return .bold
        }
    }

    /// The iOS text style whose Dynamic Type curve a step follows — the nearest by default size.
    static func textStyle(for style: RecordTokens.TextStyle) -> Font.TextStyle {
        switch style.size {
        case 34...: return .largeTitle
        case 26..<34: return .title
        case 20..<26: return .title2
        case 17..<20: return .body
        case 15..<17: return .subheadline
        case 13..<15: return .footnote
        case 12..<13: return .caption
        default: return .caption2
        }
    }

    /// CSS `letter-spacing` in `em`, as points at the step's size.
    static func tracking(_ style: RecordTokens.TextStyle) -> CGFloat {
        CGFloat(style.tracking * style.size)
    }
}

extension View {
    /// A Record type step: face, size, weight, tracking and case together, so a label cannot
    /// take the size of one step and the tracking of another.
    func recordText(_ style: RecordTokens.TextStyle) -> some View {
        self
            .font(.record(style))
            .tracking(RecordType.tracking(style))
            .textCase(style.uppercase ? .uppercase : nil)
    }
}
