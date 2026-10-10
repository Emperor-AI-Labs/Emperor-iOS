import SwiftUI
import UIKit

extension Color {
    init(_ palette: PaletteColor) {
        self.init(
            .sRGB,
            red: palette.red, green: palette.green, blue: palette.blue,
            opacity: palette.opacity)
    }
}

/// The resolved appearance, handed down the view tree.
///
/// One object rather than scattered `Color` constants so a screen cannot quietly invent a
/// colour that has never been contrast-checked — the palette itself lives in the core, built from
/// the Record design tokens (`RecordTokens`), where `PaletteTests` measures every pairing.
///
/// Increase Contrast is honoured here, once, as the design asks: `border` becomes `borderStrong`
/// and `textMute` becomes `textFaint` (`increasesContrast`, set by the root view).
@MainActor
@Observable
final class Theme {
    private(set) var preference: ThemePreference
    /// The device's own setting, so `.system` can resolve. Updated by the root view.
    var systemIsDark: Bool = false
    /// The device's Increase Contrast setting. Updated by the root view.
    var increasesContrast: Bool = false

    private let store: any PreferenceStore

    init(store: any PreferenceStore) {
        self.store = store
        self.preference = Theme.load(from: store)
    }

    var palette: Palette {
        Palette.palette(for: preference, systemIsDark: systemIsDark)
    }

    /// Every Record colour role, as the design names them.
    var record: RecordTokens.ColorSet { palette.record }

    /// What to hand `.preferredColorScheme`. `nil` means "let the device decide".
    var colorScheme: ColorScheme? {
        switch preference {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }

    func select(_ preference: ThemePreference) {
        self.preference = preference
        store.setString(preference.rawValue, for: ThemePreference.storageKey)
    }

    private static func load(from store: any PreferenceStore) -> ThemePreference {
        guard let raw = store.string(for: ThemePreference.storageKey),
              let stored = ThemePreference(rawValue: raw)
        else { return .default }
        return stored
    }

    // MARK: - Semantic colours

    var canvas: Color { Color(palette.canvas) }
    var surface: Color { Color(palette.surface) }
    var surfaceElevated: Color { Color(palette.surfaceElevated) }
    var surfaceAccent: Color { Color(palette.surfaceAccent) }
    /// Hairlines — `border`, or `borderStrong` under Increase Contrast.
    var separator: Color { Color(increasesContrast ? record.borderStrong : palette.separator) }

    var textPrimary: Color { Color(palette.textPrimary) }
    var textSecondary: Color { Color(palette.textSecondary) }
    /// Captions — `textMute`, or `textFaint` under Increase Contrast.
    var textTertiary: Color { Color(increasesContrast ? record.textFaint : palette.textTertiary) }
    var onAccent: Color { Color(palette.onAccent) }

    /// The accent as a fill. Never as text on dark — see `Palette.accent`.
    var accent: Color { Color(palette.accent) }
    var accentText: Color { Color(palette.accentText) }
    var accentMuted: Color { Color(palette.accentMuted) }
    /// The wash behind small accent-coloured *text* — a citation number, a "Today" pill. Lighter
    /// than `accentSoft`, because it is the strength `CitationTests` holds accent text to 4.5:1 on
    /// a card in both appearances.
    var accentWash: Color { Color(palette.citationFill) }

    var success: Color { Color(palette.success) }
    var warning: Color { Color(palette.warning) }
    var danger: Color { Color(palette.danger) }
    var info: Color { Color(palette.info) }

    // MARK: - Record roles

    var surface2: Color { Color(record.surface2) }
    var elevated: Color { Color(record.elevated) }
    var hover: Color { Color(record.hover) }
    var press: Color { Color(record.press) }
    var border: Color { separator }
    var borderStrong: Color { Color(record.borderStrong) }
    var textFaint: Color { Color(record.textFaint) }
    var accentSoft: Color { Color(record.accentSoft) }
    var accentLine: Color { Color(record.accentLine) }
    /// The highlight on a cited passage.
    var mark: Color { Color(record.mark) }
    /// The reader's own question.
    var bubble: Color { Color(record.bubble) }
    /// Bars: translucent, over a blur.
    var chrome: Color { Color(record.chrome) }
    var chromeTint: Color { Color(record.chromeTint) }
    var inverse: Color { Color(record.inverse) }
    var onInverse: Color { Color(record.onInverse) }
    var scrim: Color { Color(record.scrim) }
    var paper: Color { Color(record.paper) }
    var paperInk: Color { Color(record.paperInk) }
    var successBg: Color { Color(record.successBg) }
    var warnBg: Color { Color(record.warnBg) }
    var dangerBg: Color { Color(record.dangerBg) }
    var switchOff: Color { Color(record.switchOff) }

    /// Behind a grouped `List`. Record's ground is white in light, and so are its cards — told
    /// apart by a hairline a system list cannot draw round its groups. The design's next rung
    /// (`surface2`) behind them gives those lists their shape back; in dark the ground already
    /// differs from the card.
    var groupedBackground: Color { isDark ? canvas : surface2 }

    // MARK: - Gradients

    /// The one main action per screen, the send button, the avatar. 135°.
    var primaryGradient: LinearGradient { Self.gradient(palette.primaryGradient) }
    /// The Record mark's fill.
    var logoGradient: LinearGradient { Self.gradient(palette.logoGradient) }

    private static func gradient(_ stops: RecordTokens.GradientStops) -> LinearGradient {
        LinearGradient(
            colors: [Color(stops.start), Color(stops.end)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // MARK: - Tiles and elevation

    /// A hue tile's fill — kept for the role picker's selection, which still wears the role's
    /// colour. Row icons are Record tiles (`IconTile`), which are not hued.
    func tile(_ hue: TileHue) -> Color { Color(palette.tile(hue)) }
    /// The glyph on a hue tile.
    var onTile: Color { Color(palette.onTile) }
    /// The faint shadow under a card in light; clear in dark.
    var cardShadow: Color { Color(palette.cardShadow) }
    /// Elevation 2 — a toast, a raised segment.
    var raisedShadow: Color { Color(RecordTokens.Elevation.level2.color) }
    /// A control under the thumb is drawn this much darker (the design's `brightness(.94)`).
    var pressShade: Color { Color(PaletteColor(0, 0, 0, opacity: 0.06)) }
    var isDark: Bool { palette.isDark }
}

/// Classic `EnvironmentKey` rather than the `@Entry` macro — `@Entry` is iOS 18 and the
/// deployment target here is 17.0.
private struct ThemeKey: @preconcurrency EnvironmentKey {
    /// Light, following the default preference, so a preview or a detached view never renders
    /// unthemed.
    @MainActor static let defaultValue = Theme(store: InMemoryPreferenceStore())
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

// MARK: - Metrics

/// The spacing scale — Record's (`RecordTokens.Space`), a four-point grid, under the names the
/// views were written with. `xxs` is the one step below the grid: the gap between two lines of
/// one item.
enum Spacing {
    static let xxs: CGFloat = CGFloat(RecordTokens.Space.xxs) / 2
    static let xs: CGFloat = CGFloat(RecordTokens.Space.xxs)
    static let sm: CGFloat = CGFloat(RecordTokens.Space.xs)
    static let md: CGFloat = CGFloat(RecordTokens.Space.s)
    static let lg: CGFloat = CGFloat(RecordTokens.Space.m)
    static let xl: CGFloat = CGFloat(RecordTokens.Space.l)
    static let xxl: CGFloat = CGFloat(RecordTokens.Space.xl)
    static let xxxl: CGFloat = CGFloat(RecordTokens.Space.xxl)
    static let xxxxl: CGFloat = CGFloat(RecordTokens.Space.xxxl)
    /// The screen's side margin.
    static let gutter: CGFloat = CGFloat(RecordTokens.Layout.gutter)
}

/// Corner radii. Record is crisp: 6 for controls, 8 for cards, 10 for a grouped list, 14 only
/// where a sheet meets the screen edge — never the platform's default 12. Always `.continuous`.
enum Radius {
    /// Things a thumb lands on — fields, buttons, the send button, an item number.
    static let control: CGFloat = CGFloat(RecordTokens.Radius.control)
    /// Cards and panels — the composer, the reading card, a sheet's paper.
    static let card: CGFloat = CGFloat(RecordTokens.Radius.card)
    /// A grouped list of rows.
    static let group: CGFloat = CGFloat(RecordTokens.Radius.group)
    static let sheet: CGFloat = CGFloat(RecordTokens.Radius.sheet)
    static let dialog: CGFloat = CGFloat(RecordTokens.Radius.dialog)
    /// Small inner marks — a badge, a citation number — the kit's two-thirds of a control.
    static let small: CGFloat = control * 2 / 3
    /// The tile at the head of an empty state: a card's radius and half again.
    static let emptyTile: CGFloat = card * 1.5
    /// The reader's question: tucked in at the corner by the speaker.
    static let bubble = RecordTokens.Radius.bubble.map { CGFloat($0) }
}

/// Fixed sizes from the design.
enum Layout {
    static let touchTarget: CGFloat = CGFloat(RecordTokens.Layout.touchTarget)
    static let buttonHeight: CGFloat = CGFloat(RecordTokens.Layout.buttonHeight)
    /// The kit's small button (`.btn-sm`): two-thirds and a little of a full one.
    static let compactButtonHeight: CGFloat = 36
    static let listRow: CGFloat = CGFloat(RecordTokens.Layout.listRow)
    static let composerMaxLines: Int = RecordTokens.Layout.composerMaxLines
}

// MARK: - Motion

/// Record's curves and durations as SwiftUI animations, and the one rule for Reduce Motion:
/// every movement becomes a 150 ms cross-fade.
enum Motion {
    typealias Duration = RecordTokens.Motion.Duration

    static func curve(_ curve: RecordTokens.Curve, _ duration: Double) -> Animation {
        .timingCurve(curve.x1, curve.y1, curve.x2, curve.y2, duration: duration)
    }

    static func easeOut(_ duration: Double) -> Animation { curve(RecordTokens.Motion.easeOut, duration) }
    static func easeInOut(_ duration: Double) -> Animation { curve(RecordTokens.Motion.easeInOut, duration) }
    static func easePop(_ duration: Double) -> Animation { curve(RecordTokens.Motion.easePop, duration) }

    /// The press on any control: scale .985 and 6% darker, 120 ms.
    static var tap: Animation { easeOut(Duration.tap) }

    /// The cross-fade Reduce Motion uses in place of every movement.
    static var crossFade: Animation { .easeInOut(duration: Duration.reduceMotionCrossFade) }

    /// `animation`, or the cross-fade under Reduce Motion.
    static func adaptive(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? crossFade : animation
    }

    /// A message arriving: rise 8 points and fade, or only fade under Reduce Motion.
    static func rise(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .offset(y: 8).combined(with: .opacity)
    }
}

// MARK: - Haptics

/// The design's haptics, at the moments it lists — and never per streamed token.
@MainActor
enum Haptics {
    /// A question sent.
    static func send() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    /// An answer finished.
    static func answerComplete() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    /// An answer stopped by the reader.
    static func stopped() { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
    /// A citation tapped, a switch or a segment changed.
    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
    /// Just before a destructive confirmation is shown.
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    /// A pull passing its threshold.
    static func threshold() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
}

// MARK: - Building blocks

/// A Record card: the surface, a hairline, a radius of 8 — and in light the faint lift of
/// elevation 1, because a white card on the white ground is otherwise told apart by its hairline
/// alone. Increase Contrast thickens the hairline.
///
/// The shadow is drawn by the card's shape, not by its content: text over a translucent fill
/// would otherwise cast one too.
struct PanelBackground: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast
    var tinted = false
    var radius: CGFloat = Radius.card

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let edge: Color = tinted ? theme.accentLine : theme.separator
        let shadow = RecordTokens.Elevation.level1
        return content
            .background(
                shape
                    .fill(tinted ? theme.surfaceAccent : theme.surface)
                    .shadow(
                        color: tinted ? Color.clear : theme.cardShadow,
                        radius: CGFloat(shadow.blur), x: 0, y: CGFloat(shadow.y)))
            .overlay(
                shape.strokeBorder(
                    contrast == .increased ? theme.borderStrong : edge,
                    lineWidth: contrast == .increased ? 1.5 : 1))
    }
}

extension View {
    func panel(tinted: Bool = false, radius: CGFloat = Radius.card) -> some View {
        modifier(PanelBackground(tinted: tinted, radius: radius))
    }
}

/// A Record badge — "Ready", "Searchable", "SUPPL", "Court 4" — small, square-cornered, in a tone
/// that means something: green ready or verified, red failed, amber waiting, indigo the record's
/// own, plain for a fact.
struct StatusPill: View {
    enum Tone { case neutral, accent, success, warning, danger, info }

    @Environment(\.theme) private var theme

    let text: String
    var tone: Tone = .neutral
    var systemImage: String?

    var body: some View {
        HStack(spacing: Spacing.xs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .imageScale(.small)
                    // The words carry the meaning; a glyph read aloud first only delays them.
                    .accessibilityHidden(true)
            }
            Text(text)
                .monospacedDigit()
        }
        .font(.brand(size: 11.5, weight: .semibold, relativeTo: .caption2))
        .foregroundStyle(foreground)
        // Never cut short. A badge is a few words, so it is given its full width first and
        // wraps only where even that does not fit, rather than ending in an ellipsis.
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(fill, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
        .overlay {
            if tone == .neutral {
                RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                    .strokeBorder(theme.separator, lineWidth: 1)
            }
        }
        .layoutPriority(1)
        .accessibilityElement(children: .combine)
        // Named, so the accessibility audit can say which badge it means rather than "this element".
        .accessibilityIdentifier("status-pill-\(text)")
    }

    private var foreground: Color {
        switch tone {
        case .neutral: return theme.textFaint
        case .accent, .info: return theme.accentText
        case .success: return theme.success
        case .warning: return theme.warning
        case .danger: return theme.danger
        }
    }

    /// The design's own washes for the three status tones (`successBg`, `warnBg`, `dangerBg`);
    /// the accent on the 8% wash `PaletteTests` holds it to 4.5:1 on.
    private var fill: Color {
        switch tone {
        case .neutral: return theme.surface2
        case .accent, .info: return Color(theme.palette.pillWash(theme.palette.accentText))
        case .success: return theme.successBg
        case .warning: return theme.warnBg
        case .danger: return theme.dangerBg
        }
    }
}

/// A section heading in Record's voice: small capitals, spaced, in the caption colour — with a
/// quiet count beside it.
///
/// The rows are what is read; the heading only says where one group ends and the next begins.
struct SectionHeader: View {
    @Environment(\.theme) private var theme

    let title: String
    var detail: String?

    var body: some View {
        if let detail {
            // Side by side while both fit on one line; the detail under the title once they do
            // not — a long detail, or a large text size — rather than either being cut short.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    titleText
                    Spacer(minLength: Spacing.sm)
                    detailText(detail)
                        .fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    titleText
                    detailText(detail)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
        } else {
            titleText
        }
    }

    private func detailText(_ detail: String) -> some View {
        Text(detail)
            .font(.brand(.caption, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(theme.textTertiary)
            .textCase(nil)
    }

    private var titleText: some View {
        Text(title)
            .recordText(RecordTokens.Typography.label)
            .foregroundStyle(theme.textTertiary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The dot between two facts on a line — "O.A. 233/2023 · Debts Recovery Tribunal".
///
/// A shape rather than a "·" in a `Text`. As text, a glyph three points wide is read aloud as
/// "middle dot", and it is the one piece of text on the line a contrast check cannot measure: it
/// is all edge. Drawn in the colour of the words beside it, and sized with them.
struct SeparatorDot: View {
    @ScaledMetric(relativeTo: .caption) private var side: CGFloat = 3

    var body: some View {
        Circle()
            .frame(width: side, height: side)
            .accessibilityHidden(true)
    }
}

// MARK: - Icons

/// A Record tile: a glyph in the accent on `accentSoft`, square-cornered at the control radius —
/// the head of a row in every list.
///
/// Record's tiles are not hued: indigo is the colour of the record, and a row is told apart by its
/// glyph and its words. `hue` is accepted so every call site keeps its shape; it no longer
/// colours the tile. Sized with Dynamic Type up to a ceiling, and always decorative: the row's own
/// words name it.
struct IconTile: View {
    enum Size { case small, regular, large }

    @Environment(\.theme) private var theme

    let systemImage: String
    var hue: TileHue = .indigo
    var size: Size = .regular

    @ScaledMetric(relativeTo: .body) private var smallSide: CGFloat = 24
    @ScaledMetric(relativeTo: .body) private var regularSide: CGFloat = 32
    @ScaledMetric(relativeTo: .title2) private var largeSide: CGFloat = 40

    var body: some View {
        let side = self.side
        return Image(systemName: systemImage)
            .font(.system(size: side * 0.52, weight: .medium))
            .foregroundStyle(theme.accentText)
            .frame(width: side, height: side)
            .background(
                theme.accentSoft,
                in: RoundedRectangle(
                    cornerRadius: size == .large ? Radius.card : Radius.control, style: .continuous))
            .accessibilityHidden(true)
    }

    private var side: CGFloat {
        switch size {
        case .small: return min(smallSide, 34)
        case .regular: return min(regularSide, 44)
        case .large: return min(largeSide, 56)
        }
    }
}

/// A document's kind as a Record tile: its extension in small capitals on the recessed surface —
/// "PDF", "DOC".
struct DocumentTile: View {
    @Environment(\.theme) private var theme
    let kind: String

    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 32

    var body: some View {
        let side = min(self.side, 44)
        return Text(kind.uppercased())
            .font(.brand(size: 9.5, weight: .bold, relativeTo: .caption2))
            .tracking(0.4)
            .foregroundStyle(theme.textFaint)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: side, height: side)
            .background(theme.surface2, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .strokeBorder(theme.separator, lineWidth: 1))
            .accessibilityHidden(true)
    }
}

/// The glyph at the head of an empty state, a confirmation, a gate — a large Record tile.
struct IconCircle: View {
    enum Tone { case accent, neutral, success, warning, danger }

    @Environment(\.theme) private var theme

    let systemImage: String
    var tone: Tone = .accent

    @ScaledMetric(relativeTo: .largeTitle) private var side: CGFloat = 52

    var body: some View {
        let side = min(self.side, 88)
        return Image(systemName: systemImage)
            .font(.system(size: side * 0.46, weight: .medium))
            .foregroundStyle(foreground)
            .frame(width: side, height: side)
            .background(fill, in: RoundedRectangle(cornerRadius: Radius.emptyTile, style: .continuous))
            .accessibilityHidden(true)
    }

    private var foreground: Color {
        switch tone {
        case .accent: return theme.accentText
        case .neutral: return theme.textFaint
        case .success: return theme.success
        case .warning: return theme.warning
        case .danger: return theme.danger
        }
    }

    private var fill: Color {
        switch tone {
        case .accent: return theme.accentSoft
        case .neutral: return theme.surface2
        case .success: return theme.successBg
        case .warning: return theme.warnBg
        case .danger: return theme.dangerBg
        }
    }
}

/// The chevron at the end of a row that leads somewhere, where iOS does not draw one itself —
/// a button row that presents rather than pushes.
struct RowChevron: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.brand(.footnote, weight: .semibold))
            .foregroundStyle(theme.textTertiary)
            .accessibilityHidden(true)
    }
}

/// A row in the Settings style: a tile, the label, and an optional value at the trailing edge.
///
/// The label is the row's accessible name; the tile is decoration. A row that presents rather
/// than pushes adds a `RowChevron` after it.
struct IconRowLabel: View {
    @Environment(\.theme) private var theme

    let title: String
    let systemImage: String
    var hue: TileHue = .indigo
    var value: String?
    var titleColor: Color?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: Spacing.md) {
            IconTile(systemImage: systemImage, hue: hue)
            if let value, dynamicTypeSize.isAccessibilitySize {
                // At the accessibility sizes the value goes under the title: beside it, the two
                // would share a line too short for either.
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    titleText
                    valueText(value)
                }
                Spacer(minLength: 0)
            } else {
                titleText
                Spacer(minLength: Spacing.sm)
                if let value {
                    valueText(value)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, Spacing.xxs)
    }

    private var titleText: some View {
        Text(title)
            .font(.brand(.body, weight: .medium))
            .foregroundStyle(titleColor ?? theme.textPrimary)
            .dynamicLineLimit(2)
    }

    private func valueText(_ value: String) -> some View {
        Text(value)
            .font(.brand(.footnote))
            .foregroundStyle(theme.textTertiary)
    }
}

/// A label and its value, as a list row: the value in the palette's secondary text.
///
/// `LabeledContent(_:value:)` draws the value in the system's secondary grey, which is about
/// 3.4:1 on a white card — under AA for words a person came to the screen to read. This is the
/// same row with the value in a colour `PaletteTests` holds to 4.5:1.
struct ValueRow: View {
    @Environment(\.theme) private var theme

    let title: String
    let value: String

    init(_ title: String, value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        LabeledContent(title) {
            Text(value)
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - Empty and failed states

/// What a screen with nothing to show says: a tile, a serif title, one line of explanation, and
/// the one thing to do about it.
///
/// The app's own rather than `ContentUnavailableView`, which draws in the system face with a
/// grey glyph — the one screen in a session most likely to be looked at closely, drawn as if it
/// belonged to a different app.
struct EmptyStateView<Actions: View>: View {
    @Environment(\.theme) private var theme

    let title: String
    let systemImage: String
    let message: String?
    let tone: IconCircle.Tone
    let actions: Actions

    init(
        _ title: String, systemImage: String, message: String? = nil,
        tone: IconCircle.Tone = .accent, @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
        self.tone = tone
        self.actions = actions()
    }

    var body: some View {
        // Centred while it fits, scrolling once Dynamic Type makes it taller than the screen —
        // a large-text reader must still reach the button. A scroll view also lets a
        // refreshable screen be pulled to refresh when empty.
        GeometryReader { proxy in
            ScrollView {
                EmptyStateContent(
                    title: title, systemImage: systemImage, message: message, tone: tone
                ) {
                    actions
                }
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
    }
}

/// The empty state's content without its own scroll view, for a screen that already scrolls —
/// a segment of Matters, a folder.
struct EmptyStateContent<Actions: View>: View {
    @Environment(\.theme) private var theme

    let title: String
    let systemImage: String
    var message: String?
    var tone: IconCircle.Tone = .accent
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: Spacing.md) {
            IconCircle(systemImage: systemImage, tone: tone)
                .padding(.bottom, Spacing.xs)
            VStack(spacing: Spacing.sm) {
                Text(title)
                    .font(.display(size: 22, relativeTo: .title2))
                    .foregroundStyle(theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                if let message {
                    Text(message)
                        .font(.brand(.subheadline))
                        .foregroundStyle(theme.textFaint)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(spacing: Spacing.sm) {
                actions()
            }
            .padding(.top, Spacing.xs)
        }
        .frame(maxWidth: 360)
        .padding(.horizontal, Spacing.xxl)
        .padding(.vertical, Spacing.xxxxl)
        .frame(maxWidth: .infinity)
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(
        _ title: String, systemImage: String, message: String? = nil,
        tone: IconCircle.Tone = .accent
    ) {
        self.init(title, systemImage: systemImage, message: message, tone: tone) { EmptyView() }
    }
}

/// A search that matched nothing — the third kind of nothing, beside "empty" and "failed".
struct NoResultsView: View {
    let query: String

    var body: some View {
        EmptyStateView(
            "No results for “\(query)”",
            systemImage: "magnifyingglass",
            message: "Check the spelling, or try fewer words.",
            tone: .neutral)
    }
}

// MARK: - Buttons

/// The primary action — **one per screen**, drawn with the gradient.
///
/// Fifty points high at the control radius, the label in white. Pressed, it settles to 98.5% and
/// darkens by 6% over 120 ms; under Reduce Motion it only darkens.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        return configuration.label
            .font(compact ? Font.brand(.subheadline, weight: .semibold) : Font.brand(.callout, weight: .semibold))
            .foregroundStyle(theme.onAccent)
            .multilineTextAlignment(.center)
            .padding(.horizontal, compact ? Spacing.lg : Spacing.xl)
            .padding(.vertical, Spacing.sm)
            .frame(minHeight: compact ? Layout.compactButtonHeight : Layout.buttonHeight)
            .background(theme.primaryGradient, in: shape)
            .overlay(shape.fill(configuration.isPressed ? theme.pressShade : Color.clear))
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.42)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(Motion.tap, value: configuration.isPressed)
    }
}

/// The second thing a screen offers: the card's surface, a strong hairline, the text colour.
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        return configuration.label
            .font(compact ? Font.brand(.subheadline, weight: .semibold) : Font.brand(.callout, weight: .semibold))
            .foregroundStyle(theme.textPrimary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, compact ? Spacing.lg : Spacing.xl)
            .padding(.vertical, Spacing.sm)
            .frame(minHeight: compact ? Layout.compactButtonHeight : Layout.buttonHeight)
            .background(configuration.isPressed ? theme.hover : theme.surface, in: shape)
            .overlay(shape.strokeBorder(theme.borderStrong, lineWidth: 1))
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.42)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(Motion.tap, value: configuration.isPressed)
    }
}

/// A quieter companion inside a card — "Compare plans": the accent on its soft wash.
struct TonalButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    var compact = true

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        return configuration.label
            .font(.brand(.subheadline, weight: .semibold))
            .foregroundStyle(theme.accentText)
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.xs)
            .frame(minHeight: compact ? Layout.compactButtonHeight : Layout.buttonHeight)
            .background(theme.accentSoft, in: shape)
            .overlay(shape.fill(configuration.isPressed ? theme.pressShade : Color.clear))
            .frame(minHeight: Layout.touchTarget)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.42)
            .animation(Motion.tap, value: configuration.isPressed)
    }
}

/// A text button in the accent — "Send a new code", "See all".
struct QuietButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.brand(.subheadline, weight: .semibold))
            .foregroundStyle(theme.accentText)
            .padding(.horizontal, Spacing.md)
            .frame(minHeight: Layout.touchTarget)
            .background(
                configuration.isPressed ? theme.accentSoft : Color.clear,
                in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.42)
    }
}

/// An action that destroys something — "Sign out": the danger colour as words on the card, with a
/// hairline of it. Findable, never the loudest thing on the screen.
struct DestructiveButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        return configuration.label
            .font(.brand(.callout, weight: .semibold))
            .foregroundStyle(theme.danger)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.sm)
            .frame(minHeight: Layout.buttonHeight)
            .background(configuration.isPressed ? theme.dangerBg : theme.surface, in: shape)
            .overlay(shape.strokeBorder(theme.danger.opacity(0.35), lineWidth: 1))
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.42)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(Motion.tap, value: configuration.isPressed)
    }
}

/// A Record chip — a suggestion, a filter, a section of a case. A pill with a strong hairline on
/// the card's surface; chosen, the accent on its soft wash.
struct ChipButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme

    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        // Spelled out rather than an implicit member on each side of the ternary: `brand` takes
        // an `Optional` weight, which `-parse` accepts and the type checker then argues with.
        let weight: Font.Weight? = isSelected ? Font.Weight.semibold : Font.Weight.medium
        let fill: Color = isSelected ? theme.accentSoft : (configuration.isPressed ? theme.hover : theme.surface)
        let edge: Color = isSelected ? theme.accentLine : theme.borderStrong
        return configuration.label
            .font(.brand(.subheadline, weight: weight))
            .foregroundStyle(isSelected ? theme.accentText : theme.textSecondary)
            .padding(.horizontal, 14)
            .frame(minHeight: Layout.compactButtonHeight)
            .background(fill, in: Capsule())
            .overlay(Capsule().strokeBorder(edge, lineWidth: 1))
            // The capsule is drawn at its own height, but the chip answers a touch across the
            // full 44 points iOS asks of a target.
            .frame(minHeight: Layout.touchTarget)
            .contentShape(Rectangle())
            .animation(Motion.easeOut(Motion.Duration.fade), value: isSelected)
    }
}

/// What a chip says: an optional glyph in the accent, its words, and an optional count.
struct ChipLabel: View {
    @Environment(\.theme) private var theme

    let title: String
    var systemImage: String?
    var count: Int?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .imageScale(.small)
                    .foregroundStyle(theme.accentText)
            }
            Text(title)
            if let count {
                Text(count.formatted())
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? theme.accentText : theme.textTertiary)
            }
        }
        .lineLimit(1)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primaryAction: PrimaryButtonStyle { PrimaryButtonStyle() }
    static var compactPrimaryAction: PrimaryButtonStyle { PrimaryButtonStyle(compact: true) }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondaryAction: SecondaryButtonStyle { SecondaryButtonStyle() }
    static var compactSecondaryAction: SecondaryButtonStyle { SecondaryButtonStyle(compact: true) }
}

extension ButtonStyle where Self == TonalButtonStyle {
    static var tonalAction: TonalButtonStyle { TonalButtonStyle() }
}

extension ButtonStyle where Self == QuietButtonStyle {
    static var quietAction: QuietButtonStyle { QuietButtonStyle() }
}

extension ButtonStyle where Self == DestructiveButtonStyle {
    static var destructiveAction: DestructiveButtonStyle { DestructiveButtonStyle() }
}

// MARK: - Meters

/// A thin bar for "how much of an allowance is used" — Record's meter: a recessed track with a
/// hairline, filled with the primary gradient, or with a status colour when one is given.
///
/// Drawn rather than a `ProgressView`, whose track is the system's grey on every theme and whose
/// height cannot be set.
struct MeterBar: View {
    @Environment(\.theme) private var theme

    /// 0...1. Clamped, so an overspent allowance fills the bar rather than overflowing it.
    let fraction: Double
    /// A status colour for the fill — amber near a limit. `nil` is the gradient.
    var color: Color?

    init(fraction: Double, color: Color? = nil) {
        self.fraction = fraction
        self.color = color
    }

    var body: some View {
        let clamped = CGFloat(min(1, max(0, fraction)))
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        return shape
            .fill(theme.surface2)
            .overlay(shape.strokeBorder(theme.separator, lineWidth: 1))
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Group {
                        if let color {
                            shape.fill(color)
                        } else {
                            shape.fill(theme.primaryGradient)
                        }
                    }
                    // At least a dot, so "1 of 6,000" is visibly not "none".
                    .frame(width: clamped > 0 ? max(6, proxy.size.width * clamped) : 0)
                }
            }
            .frame(height: 6)
            .accessibilityHidden(true)
    }
}

// MARK: - The largest text sizes

/// A row that becomes a column at the accessibility text sizes.
///
/// A row of a title and something beside it — a pill, a count, a "Change" button — shares one
/// line between them. At the five accessibility sizes that line holds a word or two of each, and
/// the title is cut to an ellipsis to make room for the thing beside it. Stacked, each gets the
/// whole width. Below those sizes it is the `HStack` it replaces, so nothing moves for anyone else.
///
/// Switched on the size rather than measured (`ViewThatFits`): a row whose title can wrap always
/// "fits" on one line, by wrapping into a column of single words.
struct AdaptiveStack<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var horizontalAlignment: HorizontalAlignment = .leading
    var verticalAlignment: VerticalAlignment = .center
    var spacing: CGFloat?
    @ViewBuilder var content: () -> Content

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: horizontalAlignment, spacing: spacing))
            : AnyLayout(HStackLayout(alignment: verticalAlignment, spacing: spacing))
        return layout { content() }
    }
}

/// A line limit for the standard text sizes, lifted at the accessibility sizes.
///
/// Two lines of a matter's title is a tidy list at the default size; at the largest it is three
/// words and an ellipsis, and the reader who most needs the title is the one who cannot see it.
/// So the limit holds where it keeps a list scannable, and goes where it would hide the words.
private struct DynamicLineLimit: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let limit: Int

    func body(content: Content) -> some View {
        content.lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : limit)
    }
}

extension View {
    /// `lineLimit(limit)`, except at the accessibility text sizes — see `DynamicLineLimit`.
    func dynamicLineLimit(_ limit: Int) -> some View {
        modifier(DynamicLineLimit(limit: limit))
    }
}

/// Says something to VoiceOver now — a sign-in that failed, a document that is ready.
///
/// For the changes a person waits on and cannot see happen from where VoiceOver's focus is.
/// Used sparingly: everything announced interrupts whatever was being read.
///
/// UIKit's post, which every iOS release has, rather than SwiftUI's `AccessibilityNotification`:
/// the same announcement, and one less API this layer has to take on trust until CI compiles it.
@MainActor
enum VoiceOver {
    static func announce(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        UIAccessibility.post(notification: .announcement, argument: trimmed)
    }
}
