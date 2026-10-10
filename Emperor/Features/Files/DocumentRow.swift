import SwiftUI

/// One stored document, drawn the same way wherever the library is listed.
///
/// Shared by the attach picker and My Files so a document looks like itself in both — the same
/// name, the same reading state, the same star. Only the leading mark differs: a selection
/// circle where the row is being picked, the document's kind where it is being browsed.
struct DocumentRowLabel: View {
    @Environment(\.theme) private var theme

    enum Leading {
        /// Browsing: what kind of document this is.
        case kind
        /// Picking: whether it is chosen.
        case selection(Bool)
    }

    let file: FileNode.StoredFile
    var leading: Leading = .kind
    /// Where the document lives, for a flat list in which its folder is not otherwise on screen.
    var location: String?
    /// "Today", "Yesterday" or the date, for the lists ordered by it.
    var date: String?
    /// An edit is running against this row.
    var isBusy = false
    /// Whether the document opens without a connection. Drawn only in My Files.
    var offline: MyFilesViewModel.OfflineStatus = .none

    var body: some View {
        HStack(spacing: Spacing.md) {
            leadingMark

            VStack(alignment: .leading, spacing: 3) {
                Text(DisplayText.fileName(file.name))
                    .font(.brand(.body, weight: .medium))
                    .dynamicLineLimit(2)
                    .foregroundStyle(file.isReadable ? theme.textPrimary : theme.textSecondary)
                if let location {
                    Label(location, systemImage: "folder")
                        .font(.brand(.caption2))
                        .foregroundStyle(theme.textTertiary)
                        .dynamicLineLimit(1)
                }
                DocumentStatusLine(file: file, date: date)
            }

            Spacer(minLength: 0)

            if isBusy {
                ProgressView().controlSize(.small)
            } else {
                HStack(spacing: Spacing.sm) {
                    if case .kind = leading {
                        DocumentStatusBadge(file: file)
                    }
                    offlineMark
                    if file.favorite == true {
                        Image(systemName: "star.fill")
                            .font(.brand(.caption))
                            .foregroundStyle(theme.warning)
                            .accessibilityLabel("Starred")
                    }
                }
            }
        }
        .contentShape(Rectangle())
    }

    /// Filled and in the accent for a document saved for offline on purpose; outlined and quiet
    /// for one kept because it was opened, which goes first when room is needed.
    @ViewBuilder
    private var offlineMark: some View {
        switch offline {
        case .none:
            EmptyView()
        case .available:
            Image(systemName: "arrow.down.circle")
                .font(.brand(.caption))
                .foregroundStyle(theme.textTertiary)
                .accessibilityLabel("Available offline")
        case .saved:
            Image(systemName: "arrow.down.circle.fill")
                .font(.brand(.caption))
                .foregroundStyle(theme.accentText)
                .accessibilityLabel("Saved for offline")
        }
    }

    @ViewBuilder
    private var leadingMark: some View {
        switch leading {
        case .kind:
            // The kind as Record draws it: the extension in small capitals on a recessed tile.
            DocumentTile(kind: DocumentKind.label(for: file.name))
        case .selection(let isSelected):
            // For the eye only. The picker's row carries the choice as VoiceOver's own
            // "Selected" trait (`FileLibraryView`); a label here as well said it twice, and said
            // "Not selected" on every other row of the list.
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.brand(.title3))
                .foregroundStyle(isSelected ? theme.accentText : theme.textTertiary)
                .frame(minWidth: 30)
                .accessibilityHidden(true)
        }
    }
}

/// The line under a document's name: its size and date when it is ready, or why it is not.
///
/// A document still being read cannot answer questions yet, and one that failed never will, so
/// both say so in place of the size rather than looking like any other row.
struct DocumentStatusLine: View {
    @Environment(\.theme) private var theme
    let file: FileNode.StoredFile
    var date: String?

    var body: some View {
        switch file.state {
        case .ready:
            if let readyLine {
                Text(readyLine)
                    .font(.brand(.footnote))
                    .foregroundStyle(theme.textTertiary)
            }
        case .scanned:
            // Worth saying plainly: this is usable, just by a different route.
            Text([readyLine, "scanned"].compactMap { $0 }.joined(separator: " · "))
                .font(.brand(.footnote))
                .foregroundStyle(theme.textTertiary)
        case .inProgress(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.brand(.footnote))
                    .foregroundStyle(theme.textSecondary)
                    .dynamicLineLimit(1)
                // The design's thin bar while pages are read. The server reports no count the
                // row can rely on, so it runs as the indeterminate bar.
                IndeterminateBar()
            }
        case .failed(let reason):
            Text(reason.replacingOccurrences(of: "ERROR: ", with: ""))
                .font(.brand(.footnote))
                .foregroundStyle(theme.danger)
                // Why a document failed is the one thing to read on its row, so it is never cut
                // at the large sizes.
                .dynamicLineLimit(2)
        }
    }

    /// "Today · 2.4 MB", or whichever half exists.
    private var readyLine: String? {
        let size = file.size.map {
            ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
        }
        let parts = [date, size].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Where a document stands, at the end of its row: Ready, Searchable (a scan), Reading, or
/// Couldn't read — green only for ready, red only for failed.
struct DocumentStatusBadge: View {
    let file: FileNode.StoredFile

    var body: some View {
        switch file.state {
        case .ready:
            StatusPill(text: "Ready", tone: .success, systemImage: "checkmark")
        case .scanned:
            StatusPill(text: "Searchable", tone: .accent, systemImage: "doc.viewfinder")
        case .inProgress:
            StatusPill(text: "Reading", tone: .warning)
        case .failed:
            StatusPill(text: "Couldn't read", tone: .danger)
        }
    }
}

/// The design's indeterminate progress: a short bar sliding along a soft track, 1.3 s, eased —
/// still, half-filled, under Reduce Motion.
struct IndeterminateBar: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var travelled = false

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            Capsule()
                .fill(theme.accentText)
                .frame(width: width * 0.35)
                .offset(x: reduceMotion ? 0 : (travelled ? width : -width * 0.35))
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(Motion.easeInOut(1.3).repeatForever(autoreverses: false)) {
                        travelled = true
                    }
                }
        }
        .frame(height: 3)
        .background(theme.accentSoft, in: Capsule())
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}

/// The symbol and tile for a document's kind, read off its extension — the only signal a
/// listing has.
enum DocumentKind {
    /// The extension as the tile prints it: "PDF", "DOC", "IMG".
    static func label(for fileName: String) -> String {
        switch fileExtension(fileName) {
        case "pdf": return "PDF"
        case "docx", "doc", "odt", "rtf": return "DOC"
        case "csv": return "CSV"
        case "png", "jpg", "jpeg", "heic": return "IMG"
        case "txt": return "TXT"
        default: return "FILE"
        }
    }

    static func symbol(for fileName: String) -> String {
        switch fileExtension(fileName) {
        case "pdf": return "doc.richtext"
        case "docx", "doc", "odt", "rtf": return "doc.text"
        case "csv": return "tablecells"
        case "png", "jpg", "jpeg": return "photo"
        default: return "doc.plaintext"
        }
    }

    /// The colour a file manager would give the kind, from the web's muted palette: rose for a
    /// PDF, steel for a word-processor file, teal for a sheet, violet for a picture.
    static func hue(for fileName: String) -> TileHue {
        switch fileExtension(fileName) {
        case "pdf": return .rose
        case "docx", "doc", "odt", "rtf": return .steel
        case "csv": return .teal
        case "png", "jpg", "jpeg": return .violet
        default: return .graphite
        }
    }

    private static func fileExtension(_ fileName: String) -> String {
        fileName.split(separator: ".").last.map { $0.lowercased() } ?? ""
    }
}

/// A short sentence that appears over the bottom of a list after an edit, then goes.
///
/// Long enough to read a sentence about a filename, then out of the way. Tapping it dismisses
/// it early.
struct ActionNoticeToast: View {
    @Environment(\.theme) private var theme
    let notice: String
    let onDismiss: () -> Void

    var body: some View {
        Text(notice)
            .font(.brand(.footnote, weight: .medium))
            .multilineTextAlignment(.center)
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.sm + 2)
            .background(theme.surfaceElevated, in: Capsule())
            .overlay(Capsule().strokeBorder(theme.separator, lineWidth: 1))
            .foregroundStyle(theme.textPrimary)
            .shadow(color: theme.cardShadow, radius: 8, y: 3)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .transition(.opacity)
            .onTapGesture { onDismiss() }
            .accessibilityAddTraits(.isStaticText)
            // It appears away from VoiceOver's focus and is gone in four seconds, so it is said
            // as it appears — and again when a second notice replaces the first.
            .onAppear { VoiceOver.announce(notice) }
            .onChange(of: notice) { _, new in VoiceOver.announce(new) }
            .task(id: notice) {
                try? await Task.sleep(for: .seconds(4))
                onDismiss()
            }
    }
}
