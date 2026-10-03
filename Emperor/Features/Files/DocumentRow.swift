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

    var body: some View {
        HStack(spacing: 12) {
            leadingMark

            VStack(alignment: .leading, spacing: 3) {
                Text(DisplayText.fileName(file.name))
                    .lineLimit(2)
                    .foregroundStyle(file.isReadable ? theme.textPrimary : theme.textSecondary)
                if let location {
                    Label(location, systemImage: "folder")
                        .font(.brand(.caption2))
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                }
                DocumentStatusLine(file: file, date: date)
            }

            Spacer(minLength: 0)

            if isBusy {
                ProgressView().controlSize(.small)
            } else if file.favorite == true {
                Image(systemName: "star.fill")
                    .font(.brand(.caption))
                    .foregroundStyle(theme.warning)
                    .accessibilityLabel("Starred")
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var leadingMark: some View {
        switch leading {
        case .kind:
            Image(systemName: DocumentKind.symbol(for: file.name))
                .font(.brand(.title3))
                .foregroundStyle(file.isReadable ? theme.accentText : theme.textTertiary)
                .frame(width: 28)
                .accessibilityHidden(true)
        case .selection(let isSelected):
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? theme.accent : theme.textSecondary)
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
                    .font(.brand(.caption2))
                    .foregroundStyle(theme.textTertiary)
            }
        case .scanned:
            // Worth saying plainly: this is usable, just by a different route.
            Label("Scanned — read as images", systemImage: "eye")
                .font(.brand(.caption2))
                .foregroundStyle(theme.textSecondary)
        case .inProgress(let message):
            Label(message, systemImage: "clock")
                .font(.brand(.caption2))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
        case .failed(let reason):
            Label(
                reason.replacingOccurrences(of: "ERROR: ", with: ""),
                systemImage: "exclamationmark.triangle")
                .font(.brand(.caption2))
                .foregroundStyle(theme.danger)
                .lineLimit(2)
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

/// The symbol for a document's kind, read off its extension — the only signal a listing has.
enum DocumentKind {
    static func symbol(for fileName: String) -> String {
        let ext = fileName.split(separator: ".").last.map { $0.lowercased() } ?? ""
        switch ext {
        case "pdf": return "doc.richtext"
        case "docx", "doc", "odt", "rtf": return "doc.text"
        case "csv": return "tablecells"
        case "png", "jpg", "jpeg": return "photo"
        default: return "doc.plaintext"
        }
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
            .font(.brand(.footnote))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(theme.surfaceElevated, in: Capsule())
            .foregroundStyle(theme.textPrimary)
            .shadow(radius: 6, y: 2)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .transition(.opacity)
            .onTapGesture { onDismiss() }
            .accessibilityAddTraits(.isStaticText)
            .task(id: notice) {
                try? await Task.sleep(for: .seconds(4))
                onDismiss()
            }
    }
}
