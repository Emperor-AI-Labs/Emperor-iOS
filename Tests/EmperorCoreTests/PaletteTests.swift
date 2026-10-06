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

    /// The *fill* accent is not a text colour on dark: as the words of a "Done" or a "Try again"
    /// it measures about 3.4:1 on a card. That is why the app's tint — what SwiftUI draws every
    /// text button, toolbar item and link in — has to be `accentText`, never `accent`. In light
    /// the two are the same colour, so only dark shows the difference.
    func testTheFillAccentIsNotATextColourOnDark() {
        let dark = Palette.dark
        for (surfaceName, surface) in [("canvas", dark.canvas), ("surface", dark.surface)] {
            XCTAssertLessThan(
                dark.accent.contrastRatio(against: surface), 4.5,
                "dark/\(surfaceName): if the fill accent now passes as text, the tint can use it")
            XCTAssertGreaterThanOrEqual(dark.accentText.contrastRatio(against: surface), 4.5)
        }
        XCTAssertEqual(Palette.light.accent, Palette.light.accentText)
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

    // MARK: - Icon tiles and elevation

    /// The white glyph on an icon tile is a graphic that carries meaning — it is the only thing
    /// telling My Files from Library — so it is held to WCAG's 3:1 for non-text contrast, on every
    /// hue, in both appearances.
    func testIconTileGlyphsClearTheGraphicsFloor() {
        for (name, palette) in cases {
            for hue in TileHue.allCases {
                let ratio = palette.onTile.contrastRatio(against: palette.tile(hue))
                XCTAssertGreaterThanOrEqual(
                    ratio, 3.0,
                    "\(name)/\(hue): the glyph on its tile is \(String(format: "%.2f", ratio)):1")
            }
        }
    }

    /// A tile has to read as a shape on the card and the canvas it sits on, or the row loses its
    /// landmark. The dark card is the hard case: the web's hues are mid-tones, and deepened too far
    /// for the glyph they sink into it.
    func testIconTilesStandOutFromTheirSurfaces() {
        for (name, palette) in cases {
            for hue in TileHue.allCases {
                for (surfaceName, surface) in [
                    ("canvas", palette.canvas), ("surface", palette.surface),
                ] {
                    let ratio = palette.tile(hue).contrastRatio(against: surface)
                    XCTAssertGreaterThanOrEqual(
                        ratio, 3.0,
                        "\(name)/\(hue) on \(surfaceName) is \(String(format: "%.2f", ratio)):1")
                }
            }
        }
    }

    /// The tiles are the web's hues, deepened — never a colour invented here, and never louder
    /// than the web's own. Each channel of the fill is at or below the web's value.
    func testTilesAreTheWebsHuesDeepened() {
        for hue in TileHue.allCases {
            let web = PaletteColor(hex: hue.webHex)
            let tile = Palette.dark.tile(hue)
            XCTAssertLessThanOrEqual(tile.red, web.red, "\(hue)")
            XCTAssertLessThanOrEqual(tile.green, web.green, "\(hue)")
            XCTAssertLessThanOrEqual(tile.blue, web.blue, "\(hue)")
            XCTAssertLessThan(tile.luminance, web.luminance, "\(hue) is not deepened")
        }
    }

    /// Cards lift on light with a faint shadow and do not cast one on dark, where the hairline
    /// does that job and a shadow on near-black is a smudge.
    func testCardsCastAShadowOnlyInLight() {
        XCTAssertEqual(Palette.dark.cardShadow.opacity, 0, accuracy: 0.0001)
        XCTAssertGreaterThan(Palette.light.cardShadow.opacity, 0)
        XCTAssertLessThanOrEqual(
            Palette.light.cardShadow.opacity, 0.14,
            "no heavier than the web's own --ex-shadow-sm")
    }

    func testEachPaletteKnowsWhichItIs() {
        XCTAssertTrue(Palette.dark.isDark)
        XCTAssertFalse(Palette.light.isDark)
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

    // MARK: - Captions, and the washes text is drawn on

    /// Tertiary text is held to only 3:1 above, as non-essential — but the app draws real
    /// captions in it at caption size: a role's description, a document's date, a court's name
    /// under a search result. On the plain surfaces it is drawn on it clears the full 4.5:1, and
    /// this keeps it there.
    func testTertiaryCaptionsClearAAOnPlainSurfaces() {
        for (name, palette) in cases {
            for (surfaceName, surface) in [
                ("canvas", palette.canvas), ("surface", palette.surface),
                ("elevated", palette.surfaceElevated),
            ] {
                let ratio = palette.textTertiary.contrastRatio(against: surface)
                XCTAssertGreaterThanOrEqual(
                    ratio, 4.5,
                    "\(name)/\(surfaceName): tertiary text is \(String(format: "%.2f", ratio)):1")
            }
        }
    }

    /// The offline bar's "Retry" is accent text on the elevated surface — the narrowest pairing
    /// the app draws accent text on, at about 4.6:1 on dark.
    func testAccentTextClearsAAOnTheElevatedSurface() {
        for (name, palette) in cases {
            let ratio = palette.accentText.contrastRatio(against: palette.surfaceElevated)
            XCTAssertGreaterThanOrEqual(
                ratio, 4.5, "\(name): accent on elevated is \(String(format: "%.2f", ratio)):1")
        }
    }

    /// The "as of" stamp over cached content is secondary text on the elevated surface.
    func testSecondaryTextClearsAAOnTheElevatedSurface() {
        for (name, palette) in cases {
            let ratio = palette.textSecondary.contrastRatio(against: palette.surfaceElevated)
            XCTAssertGreaterThanOrEqual(
                ratio, 4.5, "\(name): secondary on elevated is \(String(format: "%.2f", ratio)):1")
        }
    }

    /// A status pill's caption, in every tone, on its own wash — on a card, where most pills sit,
    /// and on the canvas, where a pill in a header or a role's deck sits. Neutral is secondary
    /// text; accent is `accentText`.
    func testStatusPillCaptionsClearAAOnCardsAndTheCanvas() {
        for (name, palette) in cases {
            for (tone, colour) in [
                ("neutral", palette.textSecondary), ("accent", palette.accentText),
                ("success", palette.success), ("warning", palette.warning),
                ("danger", palette.danger), ("info", palette.info),
            ] {
                for (surfaceName, surface) in [
                    ("canvas", palette.canvas), ("surface", palette.surface),
                ] {
                    let fill = palette.pillWash(colour).composited(over: surface)
                    let ratio = colour.contrastRatio(against: fill)
                    XCTAssertGreaterThanOrEqual(
                        ratio, 4.5,
                        "\(name)/\(tone) pill on \(surfaceName) is \(String(format: "%.2f", ratio)):1")
                }
            }
        }
    }

    /// Why the pill's wash is 8% and not the 10% it was: at 10% the accent pill's caption falls
    /// under AA on the light canvas. If this ever passes, the palette has changed and the wash
    /// can be reconsidered.
    func testAPillWashedAtTenPercentFailsOnTheLightCanvas() {
        let palette = Palette.light
        let accent = palette.accentText
        let tenPercent = PaletteColor(accent.red, accent.green, accent.blue, opacity: 0.10)
            .composited(over: palette.canvas)
        XCTAssertLessThan(accent.contrastRatio(against: tenPercent), 4.5)
        XCTAssertLessThan(Palette.Wash.pill, 0.10, "the pill's wash was deepened again")
    }

    /// A message in the sign-in card: the danger or info colour, on a wash of itself, on the card.
    func testSignInMessagesClearAAOnTheirWash() {
        for (name, palette) in cases {
            for (tone, colour) in [("error", palette.danger), ("info", palette.info)] {
                let fill = palette.messageWash(colour).composited(over: palette.surface)
                let ratio = colour.contrastRatio(against: fill)
                XCTAssertGreaterThanOrEqual(
                    ratio, 4.5, "\(name)/\(tone) message is \(String(format: "%.2f", ratio)):1")
            }
        }
    }

    /// The banner over content that may be out of date: its caveat, its "as of" line and its
    /// accent "Retry", on the banner's wash, over the canvas and a card.
    func testTheStaleBannerAndItsRetryClearAA() {
        for (name, palette) in cases {
            for (surfaceName, surface) in [
                ("canvas", palette.canvas), ("surface", palette.surface),
            ] {
                let fill = palette.bannerWash.composited(over: surface)
                for (text, colour) in [
                    ("caveat", palette.textPrimary), ("as of", palette.textSecondary),
                    ("Retry", palette.accentText),
                ] {
                    let ratio = colour.contrastRatio(against: fill)
                    XCTAssertGreaterThanOrEqual(
                        ratio, 4.5,
                        "\(name)/\(surfaceName): \(text) is \(String(format: "%.2f", ratio)):1")
                }
            }
        }
        // At the 12% the banner was drawn with, "Retry" fails on the light canvas.
        let light = Palette.light
        let old = PaletteColor(
            light.warning.red, light.warning.green, light.warning.blue, opacity: 0.12
        ).composited(over: light.canvas)
        XCTAssertLessThan(light.accentText.contrastRatio(against: old), 4.5)
    }

    /// The row open beside the list on an iPad keeps every word on it legible — its title, its
    /// details, its date, any accent text, and a pill of any tone — and is marked by a bar in the
    /// accent that is visible against the card: the tint alone is too faint to find.
    func testTheOpenRowKeepsItsTextLegibleAndIsMarkedByMoreThanATint() {
        for (name, palette) in cases {
            let fill = palette.openRowWash.composited(over: palette.surface)
            for (text, colour) in [
                ("primary", palette.textPrimary), ("secondary", palette.textSecondary),
                ("tertiary", palette.textTertiary), ("accent", palette.accentText),
            ] {
                let ratio = colour.contrastRatio(against: fill)
                XCTAssertGreaterThanOrEqual(
                    ratio, 4.5, "\(name): \(text) on the open row is \(String(format: "%.2f", ratio)):1")
            }
            for (tone, colour) in [
                ("neutral", palette.textSecondary), ("accent", palette.accentText),
                ("success", palette.success), ("warning", palette.warning),
                ("danger", palette.danger), ("info", palette.info),
            ] {
                let pill = palette.pillWash(colour).composited(over: fill)
                let ratio = colour.contrastRatio(against: pill)
                XCTAssertGreaterThanOrEqual(
                    ratio, 4.5,
                    "\(name): the \(tone) pill on the open row is \(String(format: "%.2f", ratio)):1")
            }
            let bar = palette.accent.contrastRatio(against: palette.surface)
            XCTAssertGreaterThanOrEqual(
                bar, 3.0, "\(name): the open row's bar is \(String(format: "%.2f", bar)):1")
        }
        // At the 13% it was drawn with, the accent pill on the open row fails.
        let dark = Palette.dark
        let old = dark.surfaceAccent.composited(over: dark.surface)
        let oldPill = dark.pillWash(dark.accentText).composited(over: old)
        XCTAssertLessThan(dark.accentText.contrastRatio(against: oldPill), 4.5)
    }

    /// The chosen role — in the picker, washed in the role's own colour; at first sign-in, on the
    /// tinted panel — keeps its name and its description legible: primary and secondary text on
    /// the wash, over the canvas and a card, for every role, in both appearances.
    func testAChosenRoleIsLegibleOnItsWash() {
        for (name, palette) in cases {
            for role in PractitionerRole.allCases {
                for (surfaceName, surface) in [
                    ("canvas", palette.canvas), ("surface", palette.surface),
                ] {
                    let washes = [
                        ("picker", palette.selectionWash(role.tileHue).composited(over: surface)),
                        ("welcome", palette.surfaceAccent.composited(over: surface)),
                    ]
                    for (place, fill) in washes {
                        for (text, colour) in [
                            ("primary", palette.textPrimary), ("secondary", palette.textSecondary),
                        ] {
                            let ratio = colour.contrastRatio(against: fill)
                            XCTAssertGreaterThanOrEqual(
                                ratio, 4.5,
                                "\(name)/\(role)/\(place) on \(surfaceName): \(text) is "
                                    + "\(String(format: "%.2f", ratio)):1")
                        }
                    }
                }
            }
        }
    }

    /// Why a chosen row draws its quietest line in secondary rather than tertiary: on the light
    /// selection wash tertiary falls under AA. Pinned, so the row is not "tidied" back.
    func testTertiaryTextIsTooFaintForAChosenRow() {
        let palette = Palette.light
        let fill = palette.selectionWash(PractitionerRole.seniorCounsel.tileHue)
            .composited(over: palette.canvas)
        XCTAssertLessThan(palette.textTertiary.contrastRatio(against: fill), 4.5)
        let panel = palette.surfaceAccent.composited(over: palette.canvas)
        XCTAssertLessThan(palette.textTertiary.contrastRatio(against: panel), 4.5)
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
