import SwiftUI

/// Settings → Storage: how much is kept on this device for reading offline, and clearing it.
///
/// Everything it says is `OfflineStorageViewModel`'s; this lays it out.
struct OfflineStorageSection: View {
    @Environment(Session.self) private var session
    @Environment(\.theme) private var theme

    @State private var model: OfflineStorageViewModel?
    @State private var isConfirmingClear = false

    private var summary: OfflineStorageSummary { model?.summary ?? OfflineStorageSummary() }

    var body: some View {
        Section {
            // The size under the words at the accessibility sizes, where beside them both would
            // be cut short.
            AdaptiveStack(spacing: Spacing.md) {
                IconTile(systemImage: "arrow.down.circle", hue: .teal)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Kept for offline reading")
                        .font(.brand(.body))
                        .foregroundStyle(theme.textPrimary)
                    Text(summary.contentsText)
                        .font(.brand(.caption))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Spacing.sm)
                Text(summary.sizeText)
                    .font(.brand(.body))
                    .monospacedDigit()
                    .foregroundStyle(theme.textSecondary)
                    .accessibilityIdentifier("offline-storage-size")
            }
            .padding(.vertical, Spacing.xxs)

            // Offered only when there is something to clear. It used to stay, dimmed and disabled,
            // under a row already saying "None" — a control that could do nothing, which the
            // accessibility audit could not read either: the dimmed words were reported as text
            // that neither scales nor fits. No `.destructive` role on the row; the confirmation
            // below carries it, where the act actually happens.
            if !summary.isEmpty {
                Button {
                    isConfirmingClear = true
                } label: {
                    IconRowLabel(
                        title: "Clear offline copies", systemImage: "trash", hue: .rose,
                        titleColor: theme.danger)
                }
                .accessibilityLabel(Text("Clear offline copies"))
                .accessibilityIdentifier("offline-storage-clear")
                // Asked first: a document saved for tomorrow's hearing goes with the rest, and
                // comes back only by opening it again with a connection.
                .confirmationDialog(
                    "Clear offline copies?",
                    isPresented: $isConfirmingClear,
                    titleVisibility: .visible
                ) {
                    Button("Clear offline copies", role: .destructive) {
                        model?.clear()
                        // The dialog closes, and the button goes with nothing left to clear; what
                        // happened is said rather than left to be inferred.
                        VoiceOver.announce("Offline copies cleared")
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Conversations, documents and matters kept on this device — including documents you saved for offline — will be removed. They are kept again the next time you open them with a connection.")
                }
            }
        } header: {
            SectionHeader(title: "Storage")
                .accessibilityIdentifier("settings-header-storage")
        } footer: {
            // Its full height at every text size. The longest footer in Settings, and the one the
            // accessibility audit found neither growing nor fitting when the size changed live.
            Text(OfflineStorageSummary.explanation)
                .font(.brand(.caption))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .listRowBackground(theme.surface)
        // Read every time Settings opens: what is kept changes whenever something is opened.
        .task {
            if let model {
                model.refresh()
            } else {
                model = OfflineStorageViewModel(
                    library: session.cache.offline, account: session.currentUser?.id)
            }
        }
    }
}
