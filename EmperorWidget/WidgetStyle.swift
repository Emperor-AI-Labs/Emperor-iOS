import SwiftUI

/// The app's colours and face, for a process that cannot reach the app's `Theme`.
///
/// The colours are `TodayWidgetColors`, which `TodaySnapshotTests` holds to the app's `Palette`;
/// the face is the same bundled Fredoka (`BrandFont`), registered for the widget by its own
/// `UIAppFonts`. Should the font not register, `Font.custom` falls back to the system face — the
/// widget still draws, only plainer.
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

    /// The brand face at a size that still follows Dynamic Type, scaled with `style`.
    func brand(_ size: CGFloat, _ weight: Font.Weight, relativeTo style: Font.TextStyle) -> Font {
        Font.custom(Self.fontName(weight), size: size, relativeTo: style)
    }

    /// The variable font's named instances, as `BrandFont.Name` lists them.
    private static func fontName(_ weight: Font.Weight) -> String {
        switch weight {
        case .medium: return "Fredoka-Medium"
        case .semibold: return "Fredoka-SemiBold"
        case .bold, .heavy, .black: return "Fredoka-Bold"
        default: return "Fredoka-Regular"
        }
    }

    private func color(_ hex: UInt32) -> Color {
        let parts = TodayWidgetColors.components(hex)
        return Color(.sRGB, red: parts.red, green: parts.green, blue: parts.blue, opacity: 1)
    }
}
