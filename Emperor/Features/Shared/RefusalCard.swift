import SwiftUI

/// The server declined on purpose — a plan limit, a paused account — said calmly, in place.
///
/// Not an error style. Nothing failed, and red would invite the retry that is guaranteed to be
/// refused again. The wording is `DisplayText`'s, which never points anywhere to buy something:
/// this app takes no money and must not send anyone to where they could spend it.
struct RefusalCard: View {
    @Environment(\.theme) private var theme

    let refusal: Refusal

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Image(systemName: symbol)
                .font(.brand(.title3, weight: .medium))
                .foregroundStyle(theme.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(DisplayText.title(for: refusal))
                    .font(.brand(.subheadline, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Text(DisplayText.message(for: refusal))
                    .font(.brand(.footnote))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(theme.warning.opacity(0.10)))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .strokeBorder(theme.warning.opacity(0.3), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch refusal.code {
        case .queryLimit, .documentLimit, .scanLimit: return "calendar.badge.clock"
        case .storageLimit: return "externaldrive.badge.exclamationmark"
        case .accountSuspended: return "pause.circle"
        case .rateLimit: return "hourglass"
        default: return "exclamationmark.circle"
        }
    }
}

/// Why new work will be refused, said before it is — on the screens where new work starts.
struct AccountStandingBanner: View {
    @Environment(\.theme) private var theme

    let standing: Session.Standing

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm + 2) {
            Image(systemName: standing == .suspended ? "pause.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(theme.warning)
                .accessibilityHidden(true)
            Text(standing == .suspended
                 ? "This account is paused. You can read your history and documents, but new work can't be started."
                 : "This account doesn't have an active plan, so new questions and uploads are paused.")
                .font(.brand(.footnote))
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Spacing.md)
        .background(
            theme.warning.opacity(0.10),
            in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .strokeBorder(theme.warning.opacity(0.3), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}
