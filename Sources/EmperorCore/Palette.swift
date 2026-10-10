import Foundation

/// Which appearance the app uses.
///
/// **System is the default**, as the Record design's You screen lists it first and its prototype
/// starts on it: white in daylight, deep indigo at night. The app used to default to dark because
/// the platform's dashboard was dark; the Record theme is designed for both grounds, and following
/// the phone is what a reader who never opens You expects.
enum ThemePreference: String, CaseIterable, Sendable, Codable {
    case system, light, dark

    static let `default` = ThemePreference.system

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
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
/// **Built from the Record design tokens** (`RecordTokens`, generated from
/// `Design/record-tokens.json`). The design's own role names are all here under `record`; the
/// semantic names below are what the views were written against, each mapped to one token so the
/// whole app moved to the new surface without a view inventing a colour.
///
/// - Important: two values are deliberately **not** the token of the same name, because copying
///   them would import a contrast failure or a surface that cannot be seen. Each is marked at its
///   site and pinned by `PaletteTests.testTheDeliberateDeviationsFromTheTokensHold`.
struct Palette: Sendable {

    /// Every Record colour role for this appearance, as the design names them.
    let record: RecordTokens.ColorSet
    /// The primary gradient: the one main action per screen, the send button, the avatar.
    let primaryGradient: RecordTokens.GradientStops
    /// The gradient the two-stroke Record mark is filled with.
    let logoGradient: RecordTokens.GradientStops

    // MARK: Surfaces
    /// Behind everything — `bg`.
    var canvas: PaletteColor { record.bg }
    /// Cards, list groups, sheets — `surface`.
    var surface: PaletteColor { record.surface }
    /// A card on a card — pickers, a recessed panel, the track of a meter.
    ///
    /// **Not `elevated`.** In light the token is `#FFFFFF`, identical to `surface`, so a panel
    /// raised on a card would vanish into it. `surface2` is the design's own next rung and what its
    /// kit draws inside cards (meters, file chips, the reading card).
    var surfaceElevated: PaletteColor { record.surface2 }
    /// The faint accent tint — `accentSoft`.
    var surfaceAccent: PaletteColor { record.accentSoft }
    /// Hairlines — `border`.
    var separator: PaletteColor { record.border }

    // MARK: Text
    var textPrimary: PaletteColor { record.text }
    var textSecondary: PaletteColor { record.textSoft }
    /// Captions and timestamps — `textMute`. Increase Contrast swaps in `textFaint`.
    var textTertiary: PaletteColor { record.textMute }
    /// Text drawn on top of `accent` or the primary gradient.
    var onAccent: PaletteColor { record.onAccent }

    // MARK: Accent
    /// The accent as a **fill** — a selected switch, a chosen chip, the bar beside an open row.
    ///
    /// **Not the `accent` token in dark.** There it is `#8B95CC`, a text colour, and white on it
    /// measures about 2.6:1. The fill is the primary gradient's first stop, which is the design's
    /// own colour for every filled control and carries a white label at AA in both appearances.
    var accent: PaletteColor { primaryGradient.start }
    /// The accent as *text* — links, the selected tab, citation numbers — the `accent` token.
    var accentText: PaletteColor { record.accent }
    /// The accent's hairline — `accentLine`.
    var accentMuted: PaletteColor { record.accentLine }

    // MARK: Status
    /// Ready, verified — and nothing else.
    var success: PaletteColor { record.success }
    var warning: PaletteColor { record.warn }
    /// Destructive or failed — and nothing else.
    var danger: PaletteColor { record.danger }
    /// Neutral information — a notice that is neither good nor bad news.
    ///
    /// The accent, as text. Record has no "info" role of its own — indigo is action and
    /// selection — and `accent2`, the nearest, falls under AA in light once it sits on its own
    /// wash (about 4.2:1 in a sign-in message).
    var info: PaletteColor { record.accent }

    // MARK: Elevation
    /// The shadow under a card. Light only: on the indigo ground a card is told apart by its
    /// hairline and its lighter fill, and a shadow there is a smudge nobody can see.
    let cardShadow: PaletteColor

    /// Dark — the deep indigo ground.
    static let dark = Palette(
        record: RecordTokens.dark,
        primaryGradient: RecordTokens.Gradient.primaryDark,
        logoGradient: RecordTokens.Gradient.logoDark,
        cardShadow: PaletteColor(0, 0, 0, opacity: 0))

    /// Light — the white ground.
    static let light = Palette(
        record: RecordTokens.light,
        primaryGradient: RecordTokens.Gradient.primaryLight,
        logoGradient: RecordTokens.Gradient.logoLight,
        cardShadow: RecordTokens.Elevation.level1.color)

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
        /// The row open beside the list on an iPad — a matter, a conversation. 4%: at 5% the
        /// Record caption colour (`textMute`) fell to 4.49:1 on the light row. So faint a tint
        /// does not mark the row alone, which is why the row also carries a bar in the accent
        /// text colour (`ListRowCard`).
        static let openRow = 0.04
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
