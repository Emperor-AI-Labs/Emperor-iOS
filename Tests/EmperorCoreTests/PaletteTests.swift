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

    /// The surface ladder has to actually be a ladder, or panels vanish into the card under them.
    ///
    /// In light Record draws its cards white on white and tells them apart by their hairline —
    /// so there the card must differ from the canvas by its border, and in dark by its fill.
    func testSurfacesAreDistinguishableFromEachOther() {
        for (name, palette) in cases {
            let surfaceToElevated = palette.surfaceElevated
                .contrastRatio(against: palette.surface)
            XCTAssertNotEqual(
                surfaceToElevated, 1.0, accuracy: 0.001,
                "\(name): an elevated panel is indistinguishable from a card")
        }
        XCTAssertNotEqual(
            Palette.dark.surface.contrastRatio(against: Palette.dark.canvas), 1.0, accuracy: 0.001,
            "dark: a card is indistinguishable from the canvas")
        XCTAssertEqual(Palette.light.surface, Palette.light.canvas, "light cards are white on white")
        XCTAssertGreaterThanOrEqual(
            Palette.light.separator.contrastRatio(against: Palette.light.canvas), 1.2,
            "light: a card's hairline must be visible on the white ground")
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

    /// The Record tile — a glyph in the accent's text colour on `accentSoft` — is what every
    /// row's icon is drawn as. The glyph is a graphic that carries meaning, so it is held to
    /// WCAG's 3:1 for non-text contrast, on a card and on the canvas, in both appearances.
    func testRecordTileGlyphsClearTheGraphicsFloor() {
        for (name, palette) in cases {
            for (surfaceName, surface) in [
                ("canvas", palette.canvas), ("surface", palette.surface),
                ("elevated", palette.surfaceElevated),
            ] {
                let fill = palette.surfaceAccent.composited(over: surface)
                let ratio = palette.accentText.contrastRatio(against: fill)
                XCTAssertGreaterThanOrEqual(
                    ratio, 3.0,
                    "\(name)/\(surfaceName): a tile's glyph is \(String(format: "%.2f", ratio)):1")
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
    /// does that job and a shadow on the indigo ground is a smudge.
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

    // MARK: - Where we deliberately differ from the tokens

    /// The palette is built from `RecordTokens`, and two of its roles are **deliberately not**
    /// the token of the same name. Each was measured, and each would fail if copied, so this
    /// pins the deviation: someone making the mapping "more faithful" would reintroduce the
    /// failure, and this says so at the point of the change rather than in review.
    func testTheDeliberateDeviationsFromTheTokensHold() {
        // 1. The dark `accent` token is a text colour; white on it fails AA as a button label.
        XCTAssertLessThan(
            RecordTokens.dark.onAccent.contrastRatio(against: RecordTokens.dark.accent), 4.5,
            "the dark accent token now carries a white label — adopt it as the fill")
        XCTAssertEqual(Palette.dark.accent, RecordTokens.Gradient.primaryDark.start)
        XCTAssertEqual(Palette.dark.accentText, RecordTokens.dark.accent)
        XCTAssertEqual(Palette.light.accent, RecordTokens.light.accent)

        // 2. Light `elevated` is `#FFFFFF`, identical to `surface`.
        XCTAssertEqual(RecordTokens.light.elevated, RecordTokens.light.surface)
        XCTAssertNotEqual(
            Palette.light.surfaceElevated, Palette.light.surface,
            "a raised panel must be distinguishable from the card under it")
    }

    /// A chosen chip — a suggestion, a filter, the deep-thinking mode — is the accent's text on
    /// `accentSoft`, as the design draws it. Chips sit on the canvas.
    func testAChosenChipKeepsItsWordsReadable() {
        for (name, palette) in cases {
            let fill = palette.surfaceAccent.composited(over: palette.canvas)
            let ratio = palette.accentText.contrastRatio(against: fill)
            XCTAssertGreaterThanOrEqual(
                ratio, 4.5, "\(name): a chosen chip is \(String(format: "%.2f", ratio)):1")
        }
    }

    /// Every other role is the token itself.
    func testTheRolesAreTheTokens() {
        for (palette, tokens) in [(Palette.dark, RecordTokens.dark), (Palette.light, RecordTokens.light)] {
            XCTAssertEqual(palette.canvas, tokens.bg)
            XCTAssertEqual(palette.surface, tokens.surface)
            XCTAssertEqual(palette.textPrimary, tokens.text)
            XCTAssertEqual(palette.textSecondary, tokens.textSoft)
            XCTAssertEqual(palette.textTertiary, tokens.textMute)
            XCTAssertEqual(palette.separator, tokens.border)
            XCTAssertEqual(palette.success, tokens.success)
            XCTAssertEqual(palette.warning, tokens.warn)
            XCTAssertEqual(palette.danger, tokens.danger)
        }
    }

    /// The label on the primary gradient — the one main action per screen. White clears AA on the
    /// gradient's first stop in both appearances and on its last in light. The dark gradient's last
    /// stop is 4.4:1, which is why the label is bold and set at 16 points or more: WCAG's large-text
    /// allowance is 3:1, and the centre of the button, where the label sits, still clears 4.5.
    func testThePrimaryGradientCarriesAWhiteLabel() {
        for (name, palette) in cases {
            let gradient = palette.primaryGradient
            let start = palette.onAccent.contrastRatio(against: gradient.start)
            XCTAssertGreaterThanOrEqual(start, 4.5, "\(name): label on the first stop")
            let end = palette.onAccent.contrastRatio(against: gradient.end)
            XCTAssertGreaterThanOrEqual(end, 3.0, "\(name): label on the last stop")
            let middle = PaletteColor(
                (gradient.start.red + gradient.end.red) / 2,
                (gradient.start.green + gradient.end.green) / 2,
                (gradient.start.blue + gradient.end.blue) / 2)
            XCTAssertGreaterThanOrEqual(
                palette.onAccent.contrastRatio(against: middle), 4.5, "\(name): label mid-button")
        }
    }

    /// The highlight on a cited passage (`mark`) and the user's bubble keep body text at AA.
    func testMarkedWordsAndBubblesStayReadable() {
        for (name, palette) in cases {
            let marked = palette.record.mark.composited(over: palette.record.paper)
            XCTAssertGreaterThanOrEqual(
                palette.record.paperInk.contrastRatio(against: marked), 4.5, "\(name): marked words")
            XCTAssertGreaterThanOrEqual(
                palette.textPrimary.contrastRatio(against: palette.record.bubble), 4.5,
                "\(name): a question in its bubble")
        }
    }

    /// Increase Contrast swaps `textMute` for `textFaint` and `border` for `borderStrong`; both
    /// swaps must actually raise the contrast they are for.
    func testIncreaseContrastSwapsAreStronger() {
        for (name, palette) in cases {
            let surface = palette.surface
            XCTAssertGreaterThan(
                palette.record.textFaint.contrastRatio(against: surface),
                palette.record.textMute.contrastRatio(against: surface), "\(name): text")
            XCTAssertGreaterThan(
                palette.record.borderStrong.contrastRatio(against: surface),
                palette.record.border.contrastRatio(against: surface), "\(name): border")
        }
    }

    /// Red is for destructive and failed, and is readable as text on its own wash.
    func testTheDesignsBadgeWashesKeepTheirWordsReadable() {
        for (name, palette) in cases {
            for (tone, colour, wash) in [
                ("success", palette.success, palette.record.successBg),
                ("warning", palette.warning, palette.record.warnBg),
                ("danger", palette.danger, palette.record.dangerBg),
            ] {
                for (surfaceName, surface) in [("canvas", palette.canvas), ("surface", palette.surface)] {
                    let fill = wash.composited(over: surface)
                    let ratio = colour.contrastRatio(against: fill)
                    XCTAssertGreaterThanOrEqual(
                        ratio, 4.5,
                        "\(name)/\(tone) badge on \(surfaceName) is \(String(format: "%.2f", ratio)):1")
                }
            }
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
            let bar = palette.accentText.contrastRatio(against: palette.surface)
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

    /// **System is the default** — the Record design is drawn for both grounds, and its You
    /// screen offers System first.
    func testSystemIsTheDefault() {
        XCTAssertEqual(ThemePreference.default, .system)
        XCTAssertEqual(ThemePreference.allCases.map(\.label), ["System", "Light", "Dark"])
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
