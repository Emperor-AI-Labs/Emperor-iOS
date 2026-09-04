import Foundation

/// Which appearance the app uses.
///
/// **Dark is the default**, deliberately — not "follow the system". The product is read in
/// courtrooms and corridors, and the platform's own dashboard is dark. A user who prefers
/// otherwise can say so; a user who never opens Settings gets the intended look.
enum ThemePreference: String, CaseIterable, Sendable, Codable {
    case dark, light, system

    static let `default` = ThemePreference.dark

    var label: String {
        switch self {
        case .dark: return "Dark"
        case .light: return "Light"
        case .system: return "Match device"
        }
    }

    static let storageKey = "appearance.preference.v1"
}

/// One colour, as sRGB components in 0...1.
///
/// Deliberately not `SwiftUI.Color`: the palette lives in the Foundation-only core so its
/// contrast ratios can be *tested* rather than eyeballed. The app layer maps these to `Color`
/// in one place.
struct PaletteColor: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var opacity: Double

    init(_ red: Double, _ green: Double, _ blue: Double, opacity: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.opacity = opacity
    }

    /// From a `#RRGGBB` hex, which is how the values were read off the platform.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            Double((hex >> 16) & 0xFF) / 255,
            Double((hex >> 8) & 0xFF) / 255,
            Double(hex & 0xFF) / 255,
            opacity: opacity)
    }

    /// White at a given alpha — the surface ladder the platform's dashboard is built from.
    static func white(_ opacity: Double) -> PaletteColor {
        PaletteColor(1, 1, 1, opacity: opacity)
    }

    static func black(_ opacity: Double) -> PaletteColor {
        PaletteColor(0, 0, 0, opacity: opacity)
    }

    /// Relative luminance, per WCAG 2.1.
    var luminance: Double {
        func channel(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// This colour composited over an opaque background, so a translucent surface can be
    /// measured for contrast the way it will actually be seen.
    func composited(over background: PaletteColor) -> PaletteColor {
        guard opacity < 1 else { return self }
        let a = opacity
        return PaletteColor(
            red * a + background.red * (1 - a),
            green * a + background.green * (1 - a),
            blue * a + background.blue * (1 - a))
    }

    /// WCAG contrast ratio against another colour, 1...21.
    func contrastRatio(against other: PaletteColor) -> Double {
        let a = luminance
        let b = other.luminance
        let lighter = max(a, b)
        let darker = min(a, b)
        return (lighter + 0.05) / (darker + 0.05)
    }
}

/// The app's colours, for one appearance.
///
/// **Ported from the web app's own design tokens** — the `--ex-*` custom properties in
/// `emperor-ai/src/ui/theme.css`, which `src/main.jsx` loads last and which therefore win over
/// everything else. `:root` is dark, `:root[data-ex-theme="light"]` is light, and the file's own
/// comment says dark is the default — the same posture both mobile clients already take.
///
/// This replaces an earlier palette drawn from `s2-dark`/`s2-light` in `src/index.css` and from
/// colours measured off the marketing hero. Neither was the app's chrome: the `s*` themes are
/// the older showcase system (`public/showcase.css`), and the marketing site is a different
/// surface again — it is where the Android client took *its* palette, along with Plus Jakarta
/// Sans. So all three products were matching three different sources. This one matches what a
/// signed-in user actually looks at.
///
/// - Important: three values are deliberately **not** the website's, because copying them would
///   import a contrast failure into an app read in daylight. Each is marked at its site. Where
///   the token is sound it is used verbatim, including its hex.
struct Palette: Sendable {

    // MARK: Surfaces
    /// Behind everything.
    var canvas: PaletteColor
    /// Cards, list rows, sheets.
    var surface: PaletteColor
    /// A card on a card — pickers, the composer, a raised panel.
    var surfaceElevated: PaletteColor
    /// A faint tint used for panels that should read as "ours" rather than neutral.
    var surfaceAccent: PaletteColor
    var separator: PaletteColor

    // MARK: Text
    var textPrimary: PaletteColor
    var textSecondary: PaletteColor
    var textTertiary: PaletteColor
    /// Text drawn on top of `accent`.
    var onAccent: PaletteColor

    // MARK: Accent
    var accent: PaletteColor
    /// The accent as a *text* colour, lightened on dark so it stays legible.
    var accentText: PaletteColor
    var accentMuted: PaletteColor

    // MARK: Status
    var success: PaletteColor
    var warning: PaletteColor
    var danger: PaletteColor
    var info: PaletteColor

    /// Dark — the default, and the web app's `:root`.
    static let dark = Palette(
        canvas: PaletteColor(hex: 0x0A0B10),           // --ex-bg
        surface: PaletteColor(hex: 0x13151D),          // --ex-surface
        surfaceElevated: PaletteColor(hex: 0x1E222D),  // --ex-elevated
        surfaceAccent: PaletteColor(hex: 0x7C86C9, opacity: 0.13),  // --ex-accent-soft
        separator: PaletteColor(hex: 0x272B37),        // --ex-border

        textPrimary: PaletteColor(hex: 0xF4F6FB),      // --ex-text
        textSecondary: PaletteColor(hex: 0xC6CDDB),    // --ex-text-soft
        textTertiary: PaletteColor(hex: 0x949CB0),     // --ex-text-faint
        onAccent: PaletteColor(hex: 0xFFFFFF),         // --ex-accent-ink

        // **Not `--ex-accent` (`#7c86c9`).** That is the token for a filled button, and
        // `--ex-accent-ink` on it is white — which measures **3.44:1**, below AA for the label
        // on the app's most-tapped control. The value used instead is the website's *own*
        // light-mode accent, which clears white at 5.44:1, so this is still its indigo rather
        // than one invented here. `#7c86c9` is kept below, where it is sound.
        accent: PaletteColor(hex: 0x5A64AD),
        accentText: PaletteColor(hex: 0x7C86C9),       // --ex-accent, 5.30:1 on a card
        accentMuted: PaletteColor(hex: 0x7C86C9, opacity: 0.28),    // --ex-accent-line

        success: PaletteColor(hex: 0x34D399),          // --ex-success
        warning: PaletteColor(hex: 0xFBBF24),          // --ex-warn
        danger: PaletteColor(hex: 0xF87171),           // --ex-danger
        info: PaletteColor(hex: 0x6F9AC0))             // --ex-accent-2

    /// Light — the web app's `:root[data-ex-theme="light"]`.
    static let light = Palette(
        canvas: PaletteColor(hex: 0xF6F7FB),           // --ex-bg
        surface: PaletteColor(hex: 0xFFFFFF),          // --ex-surface
        // **Not `--ex-elevated`.** In light the website sets it to `#ffffff`, the same as the
        // surface — so a picker or a raised panel would be invisible on a card. The next rung
        // of its own ladder (`--ex-surface-2`) is used, which reads as recessed rather than
        // raised but is at least *there*.
        surfaceElevated: PaletteColor(hex: 0xF4F6FB),
        surfaceAccent: PaletteColor(hex: 0x5A64AD, opacity: 0.13),  // --ex-accent-soft
        separator: PaletteColor(hex: 0xE3E7F0),        // --ex-border

        textPrimary: PaletteColor(hex: 0x0C0F17),      // --ex-text
        textSecondary: PaletteColor(hex: 0x3C4560),    // --ex-text-soft
        textTertiary: PaletteColor(hex: 0x626A83),     // --ex-text-faint
        onAccent: PaletteColor(hex: 0xFFFFFF),         // --ex-accent-ink

        accent: PaletteColor(hex: 0x5A64AD),           // --ex-accent
        accentText: PaletteColor(hex: 0x5A64AD),       // --ex-accent, 5.44:1 on white
        accentMuted: PaletteColor(hex: 0x5A64AD, opacity: 0.30),    // --ex-accent-line

        // **The website's light theme does not re-cut these**, so they stay at their dark
        // values and land on near-white at 1.80:1, 1.56:1 and 2.58:1 — all far below AA. That
        // it re-cuts `--ex-lock` and `--ex-proj-green` for exactly this reason says the
        // omission is an oversight rather than a decision. These are the previous iOS values,
        // which clear AA; the discrepancy is filed as a web-side fix.
        success: PaletteColor(hex: 0x2C6B49),
        warning: PaletteColor(hex: 0x7E5F16),
        danger: PaletteColor(hex: 0x9C2B25),
        info: PaletteColor(hex: 0x3F5D7D))

    static func palette(for appearance: ThemePreference, systemIsDark: Bool) -> Palette {
        switch appearance {
        case .dark: return .dark
        case .light: return .light
        case .system: return systemIsDark ? .dark : .light
        }
    }
}
