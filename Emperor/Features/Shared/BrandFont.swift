import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The interface type: **SF Pro** — Text for the interface, Display for large titles — and
/// **New York** where the app speaks in prose (an answer, a drafted document), drawn as the
/// system serif.
///
/// The API is unchanged: `.brand(.body)` and `.display(size:relativeTo:)` are still what call
/// sites write, so the whole app moved faces without a sweep. What changed underneath:
///
/// - `.brand` — the system face at the iOS default size for the text style, scaled by Dynamic
///   Type. SF itself picks Text or Display by size (its optical-sizing), which is the split the
///   design asks for: SF Pro Text for body, menu labels and captions; SF Pro Display for large
///   page titles and prominent headers.
/// - `.display` — the system face at a Record size, for the numbers and titles that want the
///   larger optical size. Italic stays italic.
/// - `.serif` — New York (`Font.system(design: .serif)`), for assistant answers and drafted
///   documents (`MarkdownArtifactView`, `DraftReaderView`).
///
/// ## Sizes follow Dynamic Type
///
/// A style-based font scales with the reader's setting up to AX5, as the design asks. The
/// size-relative forms scale through `UIFontMetrics` against the same text style, so a precise
/// Record size still moves with Dynamic Type. Nothing here pins a size.
///
/// ## The bundled faces
///
/// Plus Jakarta Sans and Instrument Serif still ship in the bundle (`Emperor/Resources/Fonts`,
/// licences beside them) and `BrandFont.Name` / `isAvailable` still describe them —
/// `BundleResourceTests` holds them to it. No screen draws them any more. Removing the files,
/// the `UIAppFonts` entries and those tests is a separate step.
enum BrandFont {

    /// PostScript names of the bundled faces — retained for `BundleResourceTests`; no view
    /// asks for them.
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

    /// The weight iOS itself gives each style, so the system face keeps the emphasis a custom
    /// face was asked for. `.headline` is semibold on iOS; everything else is regular.
    static func defaultWeight(for style: Font.TextStyle) -> Font.Weight {
        style == .headline ? .semibold : .regular
    }

    /// The size iOS uses for each text style at the default Dynamic Type setting — which is also
    /// the Record iOS scale where the two overlap (body 17, callout 15 as `subheadline`,
    /// footnote 13).
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

    #if canImport(UIKit)
    /// The UIKit text style whose Dynamic Type curve a Record size follows.
    static func uiTextStyle(for style: Font.TextStyle) -> UIFont.TextStyle {
        switch style {
        case .largeTitle: return .largeTitle
        case .title: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .body: return .body
        case .callout: return .callout
        case .subheadline: return .subheadline
        case .footnote: return .footnote
        case .caption: return .caption1
        case .caption2: return .caption2
        @unknown default: return .body
        }
    }

    /// `UIFont.Weight` for a SwiftUI weight — there is no bridging, and a wrong default would
    /// silently flatten emphasis.
    static func uiWeight(_ weight: Font.Weight) -> UIFont.Weight {
        switch weight {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        default: return .regular
        }
    }
    #endif

    /// Whether the bundled interface face actually registered — for `BundleResourceTests`; no
    /// view depends on it.
    static var isAvailable: Bool {
        #if canImport(UIKit)
        return UIFont(name: Name.regular, size: 17) != nil
        #else
        return false
        #endif
    }

    /// Whether the bundled serif registered — for `BundleResourceTests`.
    static var isDisplayAvailable: Bool {
        #if canImport(UIKit)
        return UIFont(name: Name.display, size: 17) != nil
        #else
        return false
        #endif
    }
}

extension Font {
    /// The interface face — SF Pro — at an iOS text style, scaling with Dynamic Type.
    ///
    /// `.brand(.headline)` rather than `.headline` is the whole change at a call site, now that
    /// the face is the system's. Omitting the weight gives whatever iOS gives that style, so a
    /// sweep cannot change emphasis by accident.
    static func brand(_ style: Font.TextStyle, weight: Font.Weight? = nil) -> Font {
        guard let weight else { return .system(style) }
        return .system(style, design: .default, weight: weight)
    }

    /// The interface face at an exact Record size, scaling with Dynamic Type relative to `style`.
    ///
    /// The system font at a fixed size would not move with the reader's setting, so the size is
    /// scaled through `UIFontMetrics` against the style — the behaviour `Font.custom(_:size:
    /// relativeTo:)` gave the bundled face.
    static func brand(size: CGFloat, weight: Font.Weight = .regular, relativeTo style: Font.TextStyle) -> Font {
        #if canImport(UIKit)
        let base = UIFont.systemFont(ofSize: size, weight: BrandFont.uiWeight(weight))
        return Font(
            UIFontMetrics(forTextStyle: BrandFont.uiTextStyle(for: style)).scaledFont(for: base))
        #else
        return .system(size: size, weight: weight)
        #endif
    }

    /// SF Pro Display at a Record size — the numbers and large titles — scaling with Dynamic
    /// Type relative to `style`.
    static func display(size: CGFloat, italic: Bool = false, relativeTo style: Font.TextStyle) -> Font {
        #if canImport(UIKit)
        var base = UIFont.systemFont(ofSize: size, weight: .regular)
        if italic, let italicFont = base.withTraits(.traitItalic) { base = italicFont }
        return Font(
            UIFontMetrics(forTextStyle: BrandFont.uiTextStyle(for: style)).scaledFont(for: base))
        #else
        return .system(size: size, design: italic ? .serif : .default)
        #endif
    }

    /// **New York** — the system serif — at an iOS text style, scaling with Dynamic Type.
    ///
    /// The voice for prose the app produces: an assistant's answer, a drafted document. Not for
    /// labels, chrome or the reader's own words.
    static func serif(_ style: Font.TextStyle, weight: Font.Weight? = nil) -> Font {
        guard let weight else { return .system(style, design: .serif) }
        return .system(style, design: .serif, weight: weight)
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

#if canImport(UIKit)
private extension UIFont {
    /// The font with a trait applied, or nil when the trait cannot be set — the italic flag
    /// for `display`.
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont? {
        guard let descriptor = fontDescriptor.withSymbolicTraits(traits) else { return nil }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
#endif
