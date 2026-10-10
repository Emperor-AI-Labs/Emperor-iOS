import SwiftUI

/// The chrome around a sign-in field, as Record draws a field: the card's surface, a strong
/// hairline at the control radius, fifty points high — and when focused, the accent's edge with a
/// soft ring of it.
///
/// A modifier on the field rather than a wrapper view, so each field keeps its own
/// `textContentType`, keyboard and focus binding — the things that make Password AutoFill and
/// one-time-code suggestions work — and its accessibility label stays the field's own title.
struct AuthFieldChrome: ViewModifier {
    @Environment(\.theme) private var theme

    let systemImage: String?
    var isFocused: Bool
    var isInvalid = false

    /// The glyph's slot, scaled with the text beside it, so a large text size widens the slot
    /// instead of letting the glyph spill into the field.
    @ScaledMetric(relativeTo: .callout) private var glyphWidth: CGFloat = 20

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        let edge: Color = isInvalid ? theme.danger : (isFocused ? theme.accentText : theme.borderStrong)
        return HStack(spacing: 12) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.brand(.callout))
                    .foregroundStyle(isFocused ? theme.accentText : theme.textTertiary)
                    .frame(width: glyphWidth)
                    .accessibilityHidden(true)
            }
            content
                .font(.brand(.body))
                .foregroundStyle(theme.textPrimary)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: Layout.buttonHeight)
        .background(theme.surface, in: shape)
        .overlay(shape.strokeBorder(edge, lineWidth: 1))
        // The focus ring: three points of the accent's soft wash outside the edge.
        .background(
            RoundedRectangle(cornerRadius: Radius.control + 3, style: .continuous)
                .fill(isFocused && !isInvalid ? theme.accentSoft : Color.clear)
                .padding(-3))
        .animation(Motion.easeOut(0.15), value: isFocused)
    }
}

extension View {
    func authField(_ systemImage: String?, isFocused: Bool, isInvalid: Bool = false) -> some View {
        modifier(AuthFieldChrome(systemImage: systemImage, isFocused: isFocused, isInvalid: isInvalid))
    }
}

/// A short message inside the sign-in card: what went wrong, or what just happened.
///
/// Inside the card rather than as an alert, next to the field it concerns, so it can be read
/// while correcting the field — an alert would have to be dismissed first.
struct AuthMessage: View {
    enum Tone { case error, info }

    @Environment(\.theme) private var theme

    let text: String
    var tone: Tone = .error

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: tone == .error ? "exclamationmark.circle.fill" : "info.circle.fill")
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.brand(.footnote))
        .foregroundStyle(color)
        .padding(Spacing.md)
        // `Palette.Wash.message`: the strength `PaletteTests` holds both tones' text to 4.5:1 on.
        .background(
            color.opacity(Palette.Wash.message),
            in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tone == .error ? "Error: \(text)" : text)
    }

    private var color: Color {
        tone == .error ? theme.danger : theme.info
    }
}

/// The filled action at the foot of each step, with a spinner while it runs.
struct AuthPrimaryButton: View {
    @Environment(\.theme) private var theme

    let title: String
    var isWorking = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                // The title keeps its space while the spinner shows, so the button does not
                // change size under the person's thumb.
                Text(title).opacity(isWorking ? 0 : 1)
                if isWorking {
                    ProgressView().tint(theme.onAccent)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.primaryAction)
        .accessibilityLabel(title)
    }
}

/// The quiet text button used for every secondary way forward.
struct AuthLinkButton: View {
    @Environment(\.theme) private var theme

    let title: String
    var systemImage: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage).accessibilityHidden(true)
                }
                Text(title)
            }
            .font(.brand(.subheadline, weight: .semibold))
            .foregroundStyle(theme.accentText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            // A full-height target, though it is drawn as a line of text.
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
