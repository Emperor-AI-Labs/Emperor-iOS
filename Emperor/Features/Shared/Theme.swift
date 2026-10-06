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
/// colour that has never been contrast-checked — the palette itself lives in the core, where
/// `PaletteTests` measures every pairing against WCAG.
@MainActor
@Observable
final class Theme {
    private(set) var preference: ThemePreference
    /// The device's own setting, so `.system` can resolve. Updated by the root view.
    var systemIsDark: Bool = true

    private let store: any PreferenceStore

    init(store: any PreferenceStore) {
        self.store = store
        self.preference = Theme.load(from: store)
    }

    var palette: Palette {
        Palette.palette(for: preference, systemIsDark: systemIsDark)
    }

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
    var separator: Color { Color(palette.separator) }

    var textPrimary: Color { Color(palette.textPrimary) }
    var textSecondary: Color { Color(palette.textSecondary) }
    var textTertiary: Color { Color(palette.textTertiary) }
    var onAccent: Color { Color(palette.onAccent) }

    var accent: Color { Color(palette.accent) }
    var accentText: Color { Color(palette.accentText) }
    var accentMuted: Color { Color(palette.accentMuted) }
    /// The wash behind accent-coloured *text* — a secondary button, a "Today" pill. Lighter than
    /// `surfaceAccent`, because it is the strength `CitationTests` holds accent text to 4.5:1 on,
    /// in both appearances; at `surfaceAccent`'s 13% a caption in the accent falls just short.
    var accentWash: Color { Color(palette.citationFill) }

    var success: Color { Color(palette.success) }
    var warning: Color { Color(palette.warning) }
    var danger: Color { Color(palette.danger) }
    var info: Color { Color(palette.info) }

    // MARK: - Tiles and elevation

    /// An icon tile's fill — one of the web's muted hues, deepened. See `TileHue`.
    func tile(_ hue: TileHue) -> Color { Color(palette.tile(hue)) }
    /// The glyph on an icon tile.
    var onTile: Color { Color(palette.onTile) }
    /// The faint shadow under a card in light; clear in dark.
    var cardShadow: Color { Color(palette.cardShadow) }
    var isDark: Bool { palette.isDark }
}

/// Classic `EnvironmentKey` rather than the `@Entry` macro — `@Entry` is iOS 18 and the
/// deployment target here is 17.0.
private struct ThemeKey: @preconcurrency EnvironmentKey {
    /// Defaults to dark, so a preview or a detached view never renders unthemed.
    @MainActor static let defaultValue = Theme(store: InMemoryPreferenceStore())
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

// MARK: - Metrics

/// The spacing scale. Every gap in the app is one of these, so two screens built months apart
/// still breathe the same way. A four-point grid, as iOS's own layouts are.
enum Spacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
    static let xxxl: CGFloat = 32
}

/// Corner radii: one family for cards, one for controls, and capsules for anything pressed
/// like a button or read like a pill. Always drawn `.continuous`, as iOS draws its own.
enum Radius {
    /// Cards and panels — the sign-in card, the tool hub, the summary tiles.
    static let card: CGFloat = 16
    /// Things inside a card or a thumb lands on — fields, the composer, badges, notices.
    static let control: CGFloat = 12
    /// Small inner marks — a day in the month grid, a reference row.
    static let small: CGFloat = 8
}

// MARK: - Building blocks

/// A card, as the platform's dashboard draws one: a faint surface, a hairline, a soft radius —
/// and in light, the faint lift of the web's `--ex-shadow-sm`, because a white card on a
/// near-white canvas is otherwise told apart by its hairline alone.
///
/// The shadow is drawn by the card's shape, not by its content: text over a translucent fill
/// would otherwise cast one too. Increase Contrast thickens the hairline into a real edge.
struct PanelBackground: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast
    var tinted = false
    var radius: CGFloat = Radius.card

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let edge: Color = tinted ? theme.accentMuted : theme.separator
        return content
            .background(
                shape
                    .fill(tinted ? theme.surfaceAccent : theme.surface)
                    .shadow(color: tinted ? Color.clear : theme.cardShadow, radius: 8, x: 0, y: 3))
            .overlay(
                shape.strokeBorder(
                    contrast == .increased ? theme.textTertiary : edge,
                    lineWidth: contrast == .increased ? 1.5 : 1))
    }
}

extension View {
    func panel(tinted: Bool = false, radius: CGFloat = Radius.card) -> some View {
        modifier(PanelBackground(tinted: tinted, radius: radius))
    }
}

/// The small status pill the dashboard uses — "Reserved", "Done", "4 new".
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
                    // The words carry the meaning; a glyph read aloud first ("exclamation mark
                    // triangle, Overdue") only delays them.
                    .accessibilityHidden(true)
            }
            Text(text)
                .monospacedDigit()
        }
        .font(.brand(.caption2, weight: .semibold))
        .foregroundStyle(foreground)
        // Never cut short. A pill is a few words, so it is given its full width first (the
        // priority below) and wraps only where even that does not fit — at a large text size,
        // or a court's long remark — rather than ending in an ellipsis that hides the status.
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, 3)
        // A full capsule, matching the 999px radius the dashboard's pills use, with a hairline
        // of its own tone so a pale wash still has an edge on a white card. The wash is
        // `Palette.Wash.pill`, the strength `PaletteTests` holds every tone's caption to 4.5:1
        // on — on a card and on the canvas.
        .background(foreground.opacity(Palette.Wash.pill), in: Capsule())
        .overlay(Capsule().strokeBorder(foreground.opacity(0.22), lineWidth: 0.5))
        .layoutPriority(1)
        .accessibilityElement(children: .combine)
    }

    private var foreground: Color {
        switch tone {
        case .neutral: return theme.textSecondary
        case .accent: return theme.accentText
        case .success: return theme.success
        case .warning: return theme.warning
        case .danger: return theme.danger
        case .info: return theme.info
        }
    }
}

/// A section heading in the dashboard's voice: a title, and a quiet count beside it.
///
/// Secondary rather than primary text, and sentence case rather than iOS's capitals: the rows
/// are what is read, and the heading only says where one group ends and the next begins. A
/// heading with no count is a single `Text`, so it is found by its words like any other.
struct SectionHeader: View {
    @Environment(\.theme) private var theme

    let title: String
    var detail: String?

    var body: some View {
        if let detail {
            // Side by side while both fit on one line; the detail under the title once they do
            // not — a long detail, or a large text size — rather than either being cut short.
            //
            // No line limit in either: side by side, the detail is held at its full width, which
            // is what makes this layout not fit — and the stacked one be chosen — when it is too
            // long. A limit would only ever have cut it.
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
            .textCase(nil)
            .accessibilityElement(children: .combine)
        } else {
            titleText
                .textCase(nil)
        }
    }

    private func detailText(_ detail: String) -> some View {
        Text(detail)
            .font(.brand(.caption, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(theme.textTertiary)
    }

    private var titleText: some View {
        Text(title)
            .font(.brand(.footnote, weight: .semibold))
            .foregroundStyle(theme.textSecondary)
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

/// A glyph on a small rounded square of one of the web's muted hues — the way iOS's Settings
/// draws a row's icon, and the way the web draws a tool.
///
/// Filled where the symbol has a filled form, white on the hue. Sized with Dynamic Type so a row
/// keeps its proportions at every text size, up to a ceiling past which a bigger tile would only
/// push the label off the screen. Always decorative: the row's own words name it.
struct IconTile: View {
    enum Size { case small, regular, large }

    @Environment(\.theme) private var theme

    let systemImage: String
    var hue: TileHue = .indigo
    var size: Size = .regular

    @ScaledMetric(relativeTo: .body) private var smallSide: CGFloat = 24
    @ScaledMetric(relativeTo: .body) private var regularSide: CGFloat = 30
    @ScaledMetric(relativeTo: .title2) private var largeSide: CGFloat = 40

    var body: some View {
        let side = self.side
        return Image(systemName: systemImage)
            .symbolVariant(.fill)
            .font(.system(size: side * 0.5, weight: .semibold))
            .foregroundStyle(theme.onTile)
            .frame(width: side, height: side)
            .background(
                theme.tile(hue),
                in: RoundedRectangle(cornerRadius: side * 0.26, style: .continuous))
            .accessibilityHidden(true)
    }

    private var side: CGFloat {
        switch size {
        case .small: return min(smallSide, 34)
        case .regular: return min(regularSide, 42)
        case .large: return min(largeSide, 56)
        }
    }
}

/// A glyph in a soft tinted circle — the head of an empty state, a confirmation, a gate.
struct IconCircle: View {
    enum Tone { case accent, neutral, success, warning, danger }

    @Environment(\.theme) private var theme

    let systemImage: String
    var tone: Tone = .accent

    @ScaledMetric(relativeTo: .largeTitle) private var side: CGFloat = 64

    var body: some View {
        let side = min(self.side, 96)
        return Image(systemName: systemImage)
            .font(.system(size: side * 0.4, weight: .medium))
            .foregroundStyle(foreground)
            .frame(width: side, height: side)
            .background(Circle().fill(fill))
            .overlay(Circle().strokeBorder(foreground.opacity(0.18), lineWidth: 1))
            .accessibilityHidden(true)
    }

    private var foreground: Color {
        switch tone {
        case .accent: return theme.accentText
        case .neutral: return theme.textSecondary
        case .success: return theme.success
        case .warning: return theme.warning
        case .danger: return theme.danger
        }
    }

    private var fill: Color {
        switch tone {
        case .accent: return theme.surfaceAccent
        default: return foreground.opacity(0.12)
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
            .font(.brand(.body))
            .foregroundStyle(titleColor ?? theme.textPrimary)
            .dynamicLineLimit(2)
    }

    private func valueText(_ value: String) -> some View {
        Text(value)
            .font(.brand(.body))
            .foregroundStyle(theme.textSecondary)
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

/// What a screen with nothing to show says: a glyph in a soft circle, a title, one line of
/// explanation, and the one thing to do about it.
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
        // a large-text reader must still reach the button. The same shape the sign-in screen
        // uses. A scroll view also lets a refreshable screen be pulled to refresh when empty.
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: Spacing.lg) {
                    IconCircle(systemImage: systemImage, tone: tone)
                        .padding(.bottom, Spacing.xs)
                    VStack(spacing: Spacing.sm) {
                        Text(title)
                            .font(.brand(.title3, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                            .multilineTextAlignment(.center)
                            .accessibilityAddTraits(.isHeader)
                        if let message {
                            Text(message)
                                .font(.brand(.subheadline))
                                .foregroundStyle(theme.textSecondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    VStack(spacing: Spacing.sm) {
                        actions
                    }
                    .padding(.top, Spacing.xs)
                }
                .frame(maxWidth: 360)
                .padding(.horizontal, Spacing.xxl)
                .padding(.vertical, Spacing.xxxl)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
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

/// The filled action button — the dashboard's "Ask Emperor".
///
/// A capsule at a full 44-point height, so it is a comfortable target at every text size. It
/// dims and settles a little when pressed; the settle is dropped under Reduce Motion.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.brand(.subheadline, weight: .semibold))
            .foregroundStyle(theme.onAccent)
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.md)
            .frame(minHeight: 44)
            .background(theme.accent.opacity(isEnabled ? 1 : 0.4), in: Capsule())
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The quieter companion to the primary button: the accent as text on a wash of itself, for
/// the second thing a screen offers.
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.brand(.subheadline, weight: .semibold))
            .foregroundStyle(theme.accentText)
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.md)
            .frame(minHeight: 44)
            .background(theme.accentWash, in: Capsule())
            .overlay(Capsule().strokeBorder(theme.accentMuted, lineWidth: 1))
            .contentShape(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// An action that destroys something, drawn as a wash of the danger colour rather than a solid
/// red slab: it should be findable, never the loudest thing on the screen.
struct DestructiveButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.brand(.subheadline, weight: .semibold))
            .foregroundStyle(theme.danger)
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.md)
            .frame(minHeight: 44)
            .background(theme.danger.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(theme.danger.opacity(0.3), lineWidth: 1))
            .contentShape(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A filter chip — a matter, a category, a section of a case. Filled in the accent when chosen,
/// an outlined card-coloured capsule when not.
struct ChipButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme

    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        // Spelled out rather than an implicit member on each side of the ternary: `brand` takes
        // an `Optional` weight, which `-parse` accepts and the type checker then argues with.
        let weight: Font.Weight? = isSelected ? Font.Weight.semibold : Font.Weight.medium
        let fill: Color = isSelected ? theme.accent : theme.surface
        let edge: Color = isSelected ? theme.accent : theme.separator
        return configuration.label
            .font(.brand(.subheadline, weight: weight))
            .foregroundStyle(isSelected ? theme.onAccent : theme.textSecondary)
            .padding(.horizontal, 14)
            .padding(.vertical, Spacing.sm)
            .background(fill, in: Capsule())
            .overlay(Capsule().strokeBorder(edge, lineWidth: 1))
            // The capsule is drawn at its own height, but the chip answers a touch across the
            // full 44 points iOS asks of a target — a strip of small chips is otherwise a row of
            // near misses for anyone with a less steady hand.
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: 0.12), value: isSelected)
    }
}

/// What a chip says: an optional glyph, its words, and an optional count in a quieter voice.
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
            }
            Text(title)
            if let count {
                Text(count.formatted())
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? theme.onAccent : theme.textTertiary)
            }
        }
        .lineLimit(1)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primaryAction: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondaryAction: SecondaryButtonStyle { SecondaryButtonStyle() }
}

extension ButtonStyle where Self == DestructiveButtonStyle {
    static var destructiveAction: DestructiveButtonStyle { DestructiveButtonStyle() }
}

// MARK: - Meters

/// A thin rounded bar for "how much of an allowance is used" — the Plan & usage meters.
///
/// Drawn rather than a `ProgressView`, whose track is the system's grey on every theme and whose
/// height cannot be set: on the dark card that grey read as a second, unrelated bar.
struct MeterBar: View {
    @Environment(\.theme) private var theme

    /// 0...1. Clamped, so an overspent allowance fills the bar rather than overflowing it.
    let fraction: Double
    let color: Color

    var body: some View {
        let clamped = CGFloat(min(1, max(0, fraction)))
        return Capsule()
            .fill(theme.surfaceElevated)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(color)
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
