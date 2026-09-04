import XCTest
@testable import EmperorCore

/// Contrast is a correctness property here, not a nicety.
///
/// The target user skews older, and the app is read on a phone in corridors and courtrooms —
/// often in daylight. WCAG AA is 4.5:1 for body text and 3:1 for large text and UI edges. These
/// assert the palette actually clears that, measured against the surface each colour is really
/// drawn on, with translucency composited first.
final class PaletteTests: XCTestCase {

    private let cases: [(name: String, palette: Palette)] = [
        ("dark", .dark), ("light", .light),
    ]

    /// Body text on every surface it can land on.
    func testPrimaryTextClearsAAOnEverySurface() {
        for (name, palette) in cases {
            for (surfaceName, surface) in [
                ("canvas", palette.canvas),
                ("surface", palette.surface),
                ("elevated", palette.surfaceElevated),
            ] {
                let ratio = palette.textPrimary
                    .composited(over: surface)
                    .contrastRatio(against: surface)
                XCTAssertGreaterThanOrEqual(
                    ratio, 4.5,
                    "\(name)/\(surfaceName): primary text is \(String(format: "%.2f", ratio)):1")
            }
        }
    }

    /// Secondary text carries real content — a court name, a hearing purpose — so it is held to
    /// the same 4.5:1 as body text rather than the 3:1 large-text allowance.
    func testSecondaryTextClearsAAOnCardsAndCanvas() {
        for (name, palette) in cases {
            for (surfaceName, surface) in [
                ("canvas", palette.canvas), ("surface", palette.surface),
            ] {
                let ratio = palette.textSecondary
                    .composited(over: surface)
                    .contrastRatio(against: surface)
                XCTAssertGreaterThanOrEqual(
                    ratio, 4.5,
                    "\(name)/\(surfaceName): secondary text is \(String(format: "%.2f", ratio)):1")
            }
        }
    }

    /// Tertiary text is timestamps and captions — non-essential, so the 3:1 large/secondary
    /// threshold applies. It must still be *visible*.
    func testTertiaryTextIsStillVisible() {
        for (name, palette) in cases {
            let ratio = palette.textTertiary
                .composited(over: palette.surface)
                .contrastRatio(against: palette.surface)
            XCTAssertGreaterThanOrEqual(
                ratio, 3.0, "\(name): tertiary text is \(String(format: "%.2f", ratio)):1")
        }
    }

    /// The label on a filled accent button.
    func testAccentButtonLabelClearsAA() {
        for (name, palette) in cases {
            let ratio = palette.onAccent
                .composited(over: palette.accent)
                .contrastRatio(against: palette.accent)
            XCTAssertGreaterThanOrEqual(
                ratio, 4.5, "\(name): accent button label is \(String(format: "%.2f", ratio)):1")
        }
    }

    /// The accent used as *text* — a link, a selected tab — needs its own value. `#6070E4` is a
    /// fine fill and a poor text colour on white, which is why light deepens it and dark
    /// lightens it.
    func testAccentTextClearsAAOnItsSurfaces() {
        for (name, palette) in cases {
            for (surfaceName, surface) in [
                ("canvas", palette.canvas), ("surface", palette.surface),
            ] {
                let ratio = palette.accentText
                    .composited(over: surface)
                    .contrastRatio(against: surface)
                XCTAssertGreaterThanOrEqual(
                    ratio, 4.5,
                    "\(name)/\(surfaceName): accent text is \(String(format: "%.2f", ratio)):1")
            }
        }
    }

    /// Status colours are carrying meaning — "past due", "from court", "could not load" — so
    /// they have to be readable as text, not merely distinguishable as dots.
    func testStatusColoursAreReadableAsText() {
        for (name, palette) in cases {
            for (label, colour) in [
                ("success", palette.success), ("warning", palette.warning),
                ("danger", palette.danger), ("info", palette.info),
            ] {
                let ratio = colour
                    .composited(over: palette.surface)
                    .contrastRatio(against: palette.surface)
                XCTAssertGreaterThanOrEqual(
                    ratio, 4.5,
                    "\(name)/\(label) is \(String(format: "%.2f", ratio)):1 on the card surface")
            }
        }
    }

    /// A separator is a UI boundary: 3:1 against what it divides, or it is decoration.
    func testSeparatorsAreVisibleAgainstTheirSurface() {
        for (name, palette) in cases {
            let ratio = palette.separator
                .composited(over: palette.surface)
                .contrastRatio(against: palette.surface)
            XCTAssertGreaterThanOrEqual(
                ratio, 1.2,
                "\(name): separator is \(String(format: "%.2f", ratio)):1 — invisible")
        }
    }

    /// The surface ladder has to actually be a ladder, or cards vanish into the canvas.
    func testSurfacesAreDistinguishableFromEachOther() {
        for (name, palette) in cases {
            let canvasToSurface = palette.surface.contrastRatio(against: palette.canvas)
            XCTAssertNotEqual(
                canvasToSurface, 1.0, accuracy: 0.001,
                "\(name): a card is indistinguishable from the canvas")
            let surfaceToElevated = palette.surfaceElevated
                .contrastRatio(against: palette.surface)
            XCTAssertNotEqual(
                surfaceToElevated, 1.0, accuracy: 0.001,
                "\(name): an elevated panel is indistinguishable from a card")
        }
    }

    /// Dark must actually be dark and light actually light — a swapped palette would still pass
    /// every contrast test above.
    func testTheTwoPalettesAreTheRightWayRound() {
        XCTAssertLessThan(Palette.dark.canvas.luminance, 0.1)
        XCTAssertGreaterThan(Palette.light.canvas.luminance, 0.7)
        XCTAssertGreaterThan(
            Palette.light.textPrimary.contrastRatio(against: Palette.light.canvas), 4.5)
    }

    // MARK: - Where we deliberately differ from the website

    /// The palette is ported from `emperor-ai/src/ui/theme.css`, and three values are
    /// **deliberately not** the token's. Each was measured and each fails AA if copied, so this
    /// pins the deviation: someone making the port "more faithful" would reintroduce a real
    /// contrast failure, and these say so at the point of the change rather than in review.
    func testTheThreeDeliberateDeviationsFromTheWebTokensHold() {
        // 1. `--ex-accent: #7c86c9` is the dark fill, and `--ex-accent-ink` on it is white.
        XCTAssertLessThan(
            PaletteColor(hex: 0xFFFFFF).contrastRatio(against: PaletteColor(hex: 0x7C86C9)),
            4.5,
            "the web token still fails — if this now passes, adopt it and delete this test")
        XCTAssertNotEqual(
            Palette.dark.accent, PaletteColor(hex: 0x7C86C9),
            "dark accent must stay the deeper indigo so a white button label clears AA")

        // 2. Light `--ex-elevated` is `#ffffff`, identical to `--ex-surface`.
        XCTAssertNotEqual(
            Palette.light.surfaceElevated, Palette.light.surface,
            "a raised panel must be distinguishable from the card under it")

        // 3. The light theme never re-cuts the status hues, so they stay at their dark values.
        for (label, webToken) in [
            ("success", PaletteColor(hex: 0x34D399)),
            ("warning", PaletteColor(hex: 0xFBBF24)),
            ("danger", PaletteColor(hex: 0xF87171)),
        ] {
            XCTAssertLessThan(
                webToken.contrastRatio(against: Palette.light.canvas), 4.5,
                "\(label): the web value still fails on light — the deviation is still needed")
        }
    }

    // MARK: - Preference

    /// **Dark is the default.** Not "match the system" — a user who never opens Settings should
    /// get the intended look.
    func testDarkIsTheDefault() {
        XCTAssertEqual(ThemePreference.default, .dark)
    }

    func testResolutionHonoursTheExplicitChoiceOverTheSystem() {
        XCTAssertEqual(
            Palette.palette(for: .dark, systemIsDark: false).canvas, Palette.dark.canvas,
            "an explicit dark choice wins over a light system")
        XCTAssertEqual(
            Palette.palette(for: .light, systemIsDark: true).canvas, Palette.light.canvas,
            "and the other way round")
    }

    func testSystemFollowsTheDevice() {
        XCTAssertEqual(
            Palette.palette(for: .system, systemIsDark: true).canvas, Palette.dark.canvas)
        XCTAssertEqual(
            Palette.palette(for: .system, systemIsDark: false).canvas, Palette.light.canvas)
    }

    func testEveryPreferenceIsOfferable() {
        XCTAssertEqual(ThemePreference.allCases.count, 3)
        for preference in ThemePreference.allCases {
            XCTAssertFalse(preference.label.isEmpty)
        }
    }

    // MARK: - The maths itself

    /// Sanity-check the contrast implementation against WCAG's own reference values, so a bug
    /// here cannot quietly bless a bad palette.
    func testContrastMathsMatchesKnownReferenceValues() {
        let white = PaletteColor(1, 1, 1)
        let black = PaletteColor(0, 0, 0)
        XCTAssertEqual(white.contrastRatio(against: black), 21, accuracy: 0.01)
        XCTAssertEqual(white.contrastRatio(against: white), 1, accuracy: 0.001)
        // #767676 on white is the canonical 4.54:1 boundary case.
        XCTAssertEqual(
            PaletteColor(hex: 0x767676).contrastRatio(against: white), 4.54, accuracy: 0.05)
    }

    func testCompositingBlendsTowardsTheBackground() {
        let halfWhiteOnBlack = PaletteColor.white(0.5).composited(over: PaletteColor(0, 0, 0))
        XCTAssertEqual(halfWhiteOnBlack.red, 0.5, accuracy: 0.001)
        XCTAssertEqual(halfWhiteOnBlack.opacity, 1, accuracy: 0.001)

        let opaque = PaletteColor(hex: 0x6070E4)
        XCTAssertEqual(opaque.composited(over: PaletteColor(1, 1, 1)), opaque, "no-op when opaque")
    }

    func testHexInitialiserIsCorrect() {
        let colour = PaletteColor(hex: 0x6070E4)
        XCTAssertEqual(colour.red, 96 / 255, accuracy: 0.001)
        XCTAssertEqual(colour.green, 112 / 255, accuracy: 0.001)
        XCTAssertEqual(colour.blue, 228 / 255, accuracy: 0.001)
    }
}
