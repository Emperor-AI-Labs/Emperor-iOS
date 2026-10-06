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

    // MARK: Elevation
    /// The shadow under a card. Light only: on the dark canvas a card is told apart by its
    /// hairline and its lighter fill, and a shadow there is a smudge nobody can see.
    var cardShadow: PaletteColor

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
        info: PaletteColor(hex: 0x6F9AC0),             // --ex-accent-2

        cardShadow: PaletteColor(0, 0, 0, opacity: 0))

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
        info: PaletteColor(hex: 0x3F5D7D),

        // The colour of the light theme's `--ex-shadow-sm` (`0 6px 20px -8px rgba(20,30,60,0.14)`).
        // A SwiftUI shadow has no negative spread, so the same blur at full size would spread
        // wider than the web's; the opacity is lowered to keep it the same faint lift.
        cardShadow: PaletteColor(hex: 0x141E3C, opacity: 0.08))

    static func palette(for appearance: ThemePreference, systemIsDark: Bool) -> Palette {
        switch appearance {
        case .dark: return .dark
        case .light: return .light
        case .system: return systemIsDark ? .dark : .light
        }
    }
}

// MARK: - Icon tiles

/// The muted hues an icon tile is filled with — the web's own.
///
/// The platform draws every tool as a small filled tile, its icon in white on a colour from an
/// eight-colour palette its own comment calls "professional, non-neon" (`TOOL_PALETTE` in
/// `src/tools/registry.js`), and gives each role a colour from the same family
/// (`src/roles/roleConfig.js`). The app's tiles — More's rows, the tool lists, the file tools, a
/// document's kind, the role choice — are filled from the same hues, so a tool wears the same
/// colour on the phone as on the web. `TileTests` holds the hues, the hash and the role colours
/// to the platform's JavaScript.
///
/// `graphite` is the one hue the web does not have: a neutral for the rows that are about the app
/// rather than the work — Settings — which iOS itself draws grey.
enum TileHue: String, CaseIterable, Sendable {
    case indigo, teal, gold, steel, violet, rose, aqua, copper
    /// Senior Counsel's role colour, the one role hue outside the tool palette.
    case wine
    case graphite

    /// `TOOL_PALETTE`, in the web's order — the order `toolColor` indexes into.
    static let toolPalette: [TileHue] = [.indigo, .teal, .gold, .steel, .violet, .rose, .aqua, .copper]

    /// The web's own value for the hue, before it is deepened for a tile (`Palette.tile`).
    var webHex: UInt32 {
        switch self {
        case .indigo: return 0x7C86C9
        case .teal: return 0x5FA08C
        case .gold: return 0xB3924F
        case .steel: return 0x6F9AC0
        case .violet: return 0x9B83C0
        case .rose: return 0xC0808F
        case .aqua: return 0x5F9E9E
        case .copper: return 0xC0996B
        case .wine: return 0x9C6B72
        // Not the web's — see the type's note. A slate from the same cool family as the canvas.
        case .graphite: return 0x868BA0
        }
    }

    /// The hue the web gives a tool: `toolColor(id)`, a 31-multiplier hash over the id's UTF-16
    /// code units kept to 32 bits (`>>> 0`), modulo the palette.
    ///
    /// UTF-16 because `charCodeAt` reads code units, and wrapping arithmetic because `>>> 0` is
    /// a reduction modulo 2³² after every step — which is what `&*` and `&+` on a `UInt32` do.
    static func forTool(_ id: String) -> TileHue {
        var hash: UInt32 = 0
        for unit in id.utf16 {
            hash = hash &* 31 &+ UInt32(unit)
        }
        return toolPalette[Int(hash % UInt32(toolPalette.count))]
    }

    /// The web's `shade(hex, f)`: each channel scaled and rounded, clamped to a byte.
    static func shade(_ hex: UInt32, by factor: Double) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let value = Double((hex >> shift) & 0xFF) * factor
            return UInt32(min(255, max(0, value.rounded())))
        }
        return (channel(16) << 16) | (channel(8) << 8) | channel(0)
    }
}

extension PractitionerRole {
    /// The role's own colour, as `roleConfig.js` gives it.
    var tileHue: TileHue {
        switch self {
        case .litigator: return .indigo
        case .seniorCounsel: return .wine
        case .corporateCounsel: return .teal
        case .adjudicator: return .gold
        case .student: return .steel
        case .paralegal: return .violet
        case .legalAid: return .rose
        }
    }
}

extension Palette {
    /// How far a hue is deepened for a tile's fill.
    ///
    /// The web fills a tile with a gradient from 112% to 72% of the hue (`toolGradient`). A flat
    /// fill is used here, at the point in that range where both things a tile has to do hold for
    /// all ten hues: the white glyph clears 3:1 against it (WCAG's floor for a graphic), and the
    /// tile clears 3:1 against the dark card it sits on, so it reads as a shape rather than a
    /// smudge. `PaletteTests` measures both.
    static let tileShade = 0.84

    /// The fill of an icon tile. The same in both appearances, as iOS's own tiles are.
    func tile(_ hue: TileHue) -> PaletteColor {
        PaletteColor(hex: TileHue.shade(hue.webHex, by: Self.tileShade))
    }

    /// The glyph on a tile — white, as the web draws it.
    var onTile: PaletteColor { PaletteColor(hex: 0xFFFFFF) }

    /// Whether this is the dark appearance, read off the canvas rather than remembered.
    var isDark: Bool { canvas.luminance < 0.5 }
}

// MARK: - Washes

extension Palette {
    /// How strongly a colour is washed behind text drawn in that same colour, or behind a row
    /// that is chosen. Each strength is the one `PaletteTests` measures the text on it against, so
    /// a wash cannot be deepened for looks without a test saying which words stop being legible.
    enum Wash {
        /// A status pill — "Overdue", "Ready", "4 documents": a caption in the tone's colour on a
        /// wash of itself. 8%, not the web's 14%: at 10% the accent pill's caption fell to
        /// 4.47:1 on the light canvas, which a pill outside a card — a deadline's head — sits on.
        static let pill = 0.08
        /// A message in the sign-in card — what went wrong, or what was just sent — in the
        /// danger or info colour on a wash of itself, on the card.
        static let message = 0.12
        /// The chosen row in the role picker, washed in the role's own tile colour.
        static let selection = 0.14
        /// The warning banner over content that may be out of date, which carries an accent
        /// "Retry". 8%: at the 12% it was drawn with, "Retry" fell to 4.32:1 on the light canvas.
        static let banner = 0.08
        /// The row open beside the list on an iPad — a matter, a conversation. 5%: at the 13% of
        /// `surfaceAccent` it was drawn with, a "From court" pill on the open row fell to about
        /// 4.0:1 and accent text to 4.49:1 on dark. So faint a tint does not mark the row alone,
        /// which is why the row also carries a bar in the accent (`ListRowCard`).
        static let openRow = 0.05
    }

    /// `colour`, as the wash behind a pill drawn in it.
    func pillWash(_ colour: PaletteColor) -> PaletteColor {
        PaletteColor(colour.red, colour.green, colour.blue, opacity: Wash.pill)
    }

    /// `colour`, as the wash behind a message drawn in it.
    func messageWash(_ colour: PaletteColor) -> PaletteColor {
        PaletteColor(colour.red, colour.green, colour.blue, opacity: Wash.message)
    }

    /// The tint of the row open beside the list — `accentText`, washed.
    var openRowWash: PaletteColor {
        PaletteColor(accentText.red, accentText.green, accentText.blue, opacity: Wash.openRow)
    }

    /// The fill of the "showing what was last loaded" banner.
    var bannerWash: PaletteColor {
        PaletteColor(warning.red, warning.green, warning.blue, opacity: Wash.banner)
    }

    /// The fill of a chosen row: the role's tile hue, washed.
    ///
    /// Tertiary text is not drawn on it. In light it falls to about 4.2:1 there — under AA for
    /// the caption it would be — so a chosen row's quietest line is drawn in secondary instead
    /// (`RoleOptionLabel`).
    func selectionWash(_ hue: TileHue) -> PaletteColor {
        let tile = self.tile(hue)
        return PaletteColor(tile.red, tile.green, tile.blue, opacity: Wash.selection)
    }
}
