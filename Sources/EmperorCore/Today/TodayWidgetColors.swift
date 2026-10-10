import Foundation

/// The brand colours the widget draws with, as `#RRGGBB`.
///
/// The widget cannot compile `Palette` — it sits beside the role and tile tables the rest of the
/// app needs — so the handful of colours a widget uses are restated here, and
/// `TodaySnapshotTests` holds every one of them to `Palette.dark` and `Palette.light`. Change the
/// palette and that test names what to change here.
///
/// The widget follows the device's appearance (a widget cannot read the app's own theme
/// choice), so both are carried.
struct TodayWidgetColors: Equatable, Sendable {
    let canvas: UInt32
    let textPrimary: UInt32
    let textSecondary: UInt32
    let textTertiary: UInt32
    let accent: UInt32
    let accentText: UInt32

    static let dark = TodayWidgetColors(
        canvas: 0x14172A,
        textPrimary: 0xEEF0F8, textSecondary: 0xC3C8DD, textTertiary: 0x8C93B0,
        accent: 0x4D568F, accentText: 0x8B95CC)

    static let light = TodayWidgetColors(
        canvas: 0xFFFFFF,
        textPrimary: 0x0F1424, textSecondary: 0x454B63, textTertiary: 0x6B7187,
        accent: 0x464E85, accentText: 0x464E85)

    /// A hex's three channels in 0...1, for `Color(.sRGB, red:green:blue:)`.
    static func components(_ hex: UInt32) -> (red: Double, green: Double, blue: Double) {
        (
            Double((hex >> 16) & 0xFF) / 255,
            Double((hex >> 8) & 0xFF) / 255,
            Double(hex & 0xFF) / 255
        )
    }
}
