import SwiftUI

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

    var success: Color { Color(palette.success) }
    var warning: Color { Color(palette.warning) }
    var danger: Color { Color(palette.danger) }
    var info: Color { Color(palette.info) }
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

// MARK: - Building blocks

/// A card, as the platform's dashboard draws one: a faint surface, a hairline, a soft radius.
struct PanelBackground: ViewModifier {
    @Environment(\.theme) private var theme
    var tinted = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(tinted ? theme.surfaceAccent : theme.surface))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(theme.separator, lineWidth: 1))
    }
}

extension View {
    func panel(tinted: Bool = false) -> some View {
        modifier(PanelBackground(tinted: tinted))
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
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(text)
        }
        .font(.brand(.caption2, weight: .semibold))
        .foregroundStyle(foreground)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        // A full capsule, matching the 999px radius the dashboard's pills use.
        .background(foreground.opacity(0.14), in: Capsule())
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
struct SectionHeader: View {
    @Environment(\.theme) private var theme

    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.brand(.subheadline, weight: .bold))
                .foregroundStyle(theme.textPrimary)
            Spacer(minLength: 8)
            if let detail {
                Text(detail)
                    .font(.brand(.caption))
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .textCase(nil)
        .accessibilityElement(children: .combine)
    }
}

/// The filled action button — the dashboard's "Ask Emperor".
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.brand(.subheadline, weight: .semibold))
            .foregroundStyle(theme.onAccent)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(theme.accent.opacity(isEnabled ? 1 : 0.4), in: Capsule())
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primaryAction: PrimaryButtonStyle { PrimaryButtonStyle() }
}
