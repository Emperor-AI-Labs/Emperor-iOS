import SwiftUI

/// Says that what is on screen is the copy kept on this device, and how old it is.
///
/// Calm on purpose: no warning colour, no exclamation mark. Nothing has gone wrong — the person
/// is somewhere without signal, which in a court building is most of the day — and the screen's
/// job is to say plainly what they are reading, not to alarm them about it.
///
/// Drawn as a bar of its own between the content and whatever acts on it (a conversation's
/// composer), never inside a scrolling list where it could be scrolled out of sight while the
/// controls it explains stay disabled.
struct OfflineCopyBanner: View {
    @Environment(\.theme) private var theme

    /// "Offline — showing the copy saved 2 hours ago."
    let notice: String
    /// What it means for this screen, if anything — why asking is paused.
    var detail: String?
    /// Whether a reload is already under way, in which case there is nothing to retry.
    var isReloading = false
    var retry: (() async -> Void)?

    var body: some View {
        // "Retry" under the words at the accessibility sizes, so the notice keeps its line.
        AdaptiveStack(spacing: Spacing.sm + 2) {
            Image(systemName: "wifi.slash")
                .font(.brand(.footnote, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(notice)
                    .font(.brand(.footnote, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("offline-notice")
                if let detail {
                    Text(detail)
                        .font(.brand(.caption))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if isReloading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Reloading")
            } else if let retry {
                // A word to the eye, a 44-point target to the thumb. `accentText` on the elevated
                // bar is a pairing `PaletteTests` holds to 4.5:1.
                Button {
                    Task { await retry() }
                } label: {
                    Text("Retry")
                        .font(.brand(.caption, weight: .semibold))
                        .foregroundStyle(theme.accentText)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityHint("Loads it again from the server")
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfaceElevated)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.separator).frame(height: 0.5)
        }
    }
}
