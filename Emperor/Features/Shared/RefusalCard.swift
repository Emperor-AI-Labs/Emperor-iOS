import SwiftUI

/// The server declined on purpose — a plan limit, a paused account — said calmly, in place.
///
/// Not an error style. Nothing failed, and red would invite the retry that is guaranteed to be
/// refused again. The wording is `DisplayText`'s, which says what happened and never tells anyone
/// to buy. Where a plan is the answer, and the build allows it, a separate "View plans" button
/// opens the web app's plans page in the browser — see `WebPlans`.
struct RefusalCard: View {
    @Environment(Session.self) private var session
    @Environment(\.theme) private var theme

    let refusal: Refusal

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Image(systemName: symbol)
                .font(.brand(.title3, weight: .medium))
                .foregroundStyle(theme.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.sm) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(DisplayText.title(for: refusal))
                        .font(.brand(.subheadline, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                    Text(DisplayText.message(for: refusal))
                        .font(.brand(.footnote))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                if session.webPlans.isOffered(for: refusal) {
                    ViewPlansButton(style: .inline)
                }
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
        .accessibilityElement(children: .contain)
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
    @Environment(Session.self) private var session
    @Environment(\.theme) private var theme

    let standing: Session.Standing

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm + 2) {
            Image(systemName: standing == .suspended ? "pause.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(theme.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text(standing == .suspended
                     ? "This account is paused. You can read your history and documents, but new work can't be started."
                     : "This account doesn't have an active plan, so new questions and uploads are paused.")
                    .font(.brand(.footnote))
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if session.webPlans.isOffered(for: standing) {
                    ViewPlansButton(style: .inline)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.md)
        .background(
            theme.warning.opacity(0.10),
            in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .strokeBorder(theme.warning.opacity(0.3), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

/// Opens the web app's plans page in the browser, where a plan is bought on the same account.
///
/// The browser, not a sheet inside the app: buying is the web app's, start to finish, and Safari
/// is where the person may already be signed in to it. Coming back reads the account at once
/// (`Session.noteOpenedPlans`). Drawn only where `WebPlans` says to offer it.
struct ViewPlansButton: View {
    enum Style {
        /// Beside a refusal or a banner: a compact capsule under the words.
        case inline
        /// A row of its own in Settings.
        case row
    }

    @Environment(Session.self) private var session
    @Environment(\.openURL) private var openURL
    @Environment(\.theme) private var theme

    var style: Style = .inline

    var body: some View {
        Button {
            session.noteOpenedPlans()
            openURL(session.webPlans.url)
        } label: {
            switch style {
            case .inline:
                HStack(spacing: 6) {
                    Text(WebPlans.buttonTitle)
                    Image(systemName: "arrow.up.right")
                        .font(.brand(.caption, weight: .bold))
                        .accessibilityHidden(true)
                }
                .font(.brand(.footnote, weight: .semibold))
                .foregroundStyle(theme.onAccent)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, 7)
                .background(theme.accent, in: Capsule())
            case .row:
                HStack(spacing: Spacing.md) {
                    IconTile(systemImage: "sparkles", hue: .gold)
                    Text(WebPlans.buttonTitle)
                        .font(.brand(.body, weight: .semibold))
                        .foregroundStyle(theme.accentText)
                    Spacer(minLength: Spacing.sm)
                    Image(systemName: "arrow.up.right.square")
                        .font(.brand(.callout))
                        .foregroundStyle(theme.textTertiary)
                        .accessibilityHidden(true)
                }
                .padding(.vertical, Spacing.xxs)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(WebPlans.buttonTitle))
        .accessibilityHint(Text("Opens the Emperor web app in your browser"))
        .accessibilityAddTraits(.isLink)
        .accessibilityIdentifier("View plans")
    }
}
