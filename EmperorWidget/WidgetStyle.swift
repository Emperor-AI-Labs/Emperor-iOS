import SwiftUI

/// The app's colours and faces, for a process that cannot reach the app's `Theme`.
///
/// The colours are `TodayWidgetColors`, which `TodaySnapshotTests` holds to the app's `Palette`;
/// the faces are the same bundled Record faces (`BrandFont`) — Plus Jakarta Sans and Instrument
/// Serif — registered for the widget by its own `UIAppFonts`. Should a font not register,
/// `Font.custom` falls back to the system face — the widget still draws, only plainer.
///
/// It follows the phone's appearance: a widget cannot read the app's own Light / Dark choice.
struct WidgetStyle {
    private let colors: TodayWidgetColors

    init(_ scheme: ColorScheme) {
        colors = scheme == .dark ? .dark : .light
    }

    var canvas: Color { color(colors.canvas) }
    var textPrimary: Color { color(colors.textPrimary) }
    var textSecondary: Color { color(colors.textSecondary) }
    var textTertiary: Color { color(colors.textTertiary) }
    var accent: Color { color(colors.accent) }
    var accentText: Color { color(colors.accentText) }

    /// The interface face at a size that still follows Dynamic Type, scaled with `style`.
    func brand(_ size: CGFloat, _ weight: Font.Weight, relativeTo style: Font.TextStyle) -> Font {
        Font.custom(Self.fontName(weight), size: size, relativeTo: style)
    }

    /// The serif, for the numbers people scan for — a day, an item.
    func display(_ size: CGFloat, relativeTo style: Font.TextStyle) -> Font {
        Font.custom("InstrumentSerif-Regular", size: size, relativeTo: style)
    }

    /// The static files' PostScript names, as `BrandFont.Name` lists them.
    private static func fontName(_ weight: Font.Weight) -> String {
        switch weight {
        case .medium: return "PlusJakartaSans-Medium"
        case .semibold: return "PlusJakartaSans-SemiBold"
        case .bold, .heavy, .black: return "PlusJakartaSans-Bold"
        default: return "PlusJakartaSans-Regular"
        }
    }

    private func color(_ hex: UInt32) -> Color {
        let parts = TodayWidgetColors.components(hex)
        return Color(.sRGB, red: parts.red, green: parts.green, blue: parts.blue, opacity: 1)
    }
}
