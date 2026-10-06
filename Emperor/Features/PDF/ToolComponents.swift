import PDFKit
import SwiftUI
import UIKit

/// Copying a picked file into the app's own space.
///
/// A file from the Files picker is security-scoped: readable only between a start and a stop,
/// and only by the process that asked. The tools read their inputs several times — once for the
/// page count, again for thumbnails, again to build the output — and sometimes minutes apart, so
/// each input is copied once, here, and every later read is of the copy.
///
/// The copies live under the same temporary folder `ShareableFile` writes to, so signing out —
/// which clears that folder — takes the client's documents with it.
enum ToolImport {

    /// Copies a picked file. Runs the copy off the main thread: a paperbook can be large.
    static func copy(_ url: URL) async -> PickedFile? {
        await Task.detached(priority: .userInitiated) { ToolImport.copyNow(url) }.value
    }

    /// Writes bytes that arrived without a file — a photo-library item — as a file.
    static func write(_ data: Data, named name: String) async -> PickedFile? {
        await Task.detached(priority: .userInitiated) { () -> PickedFile? in
            guard let directory = ToolImport.freshDirectory() else { return nil }
            let destination = directory.appendingPathComponent(ToolImport.safeName(name))
            guard (try? data.write(to: destination, options: .atomic)) != nil else { return nil }
            return PickedFile(url: destination, name: name, bytes: data.count)
        }.value
    }

    /// Reads a PDF's page count from a local copy, off the main thread. `nil` when it cannot be
    /// opened — damaged, or locked with a password.
    static func pageCount(of file: PickedFile) async -> Int? {
        let url = file.url
        return await Task.detached(priority: .userInitiated) {
            PDFDocumentReader.pageCount(url)
        }.value
    }

    private static func copyNow(_ url: URL) -> PickedFile? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let directory = freshDirectory() else { return nil }
        let name = url.lastPathComponent
        let destination = directory.appendingPathComponent(safeName(name))
        guard (try? FileManager.default.copyItem(at: url, to: destination)) != nil else {
            return nil
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
        let bytes = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        return PickedFile(url: destination, name: name, bytes: bytes)
    }

    /// One folder per file, so two picks of `Order.pdf` cannot overwrite each other.
    private static func freshDirectory() -> URL? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmperorShare", isDirectory: true)
            .appendingPathComponent("Imports", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        } catch {
            return nil
        }
    }

    /// A `/` in a name would become a path separator; `ShareableFile` makes the same repair.
    private static func safeName(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return cleaned.isEmpty ? "Document" : cleaned
    }
}

/// The one PDFKit question the pickers ask.
enum PDFDocumentReader {
    /// The page count, or `nil` for a file that cannot be opened or is locked.
    static func pageCount(_ url: URL) -> Int? {
        guard let document = PDFDocument(url: url), !document.isLocked,
              document.pageCount > 0
        else { return nil }
        return document.pageCount
    }
}

// MARK: - Rows

/// The chosen input: its name, what is known about it, and a way to swap it.
struct ToolSourceRow: View {
    @Environment(\.theme) private var theme

    let name: String
    let detail: String
    var systemImage = "doc.richtext"
    var change: (() -> Void)?

    var body: some View {
        // "Change" under the file at the accessibility sizes, where beside it the file's name
        // would be cut to a word.
        AdaptiveStack(spacing: Spacing.md) {
            IconTile(systemImage: systemImage, hue: .rose, size: .large)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.brand(.subheadline, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .dynamicLineLimit(2)
                Text(detail)
                    .font(.brand(.caption))
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer(minLength: 8)
            if let change {
                Button(action: change) {
                    Text("Change")
                        .font(.brand(.caption, weight: .semibold))
                        .foregroundStyle(theme.accentText)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Change \(name)")
            }
        }
        .padding(.vertical, Spacing.xs)
    }
}

/// A finished file, one tap from the share sheet — which reaches Files, Mail and every other
/// place a document needs to go.
struct ToolResultRow: View {
    @Environment(\.theme) private var theme
    let file: ToolFile

    var body: some View {
        if let url = ShareableFile.url(for: file.data, named: file.name) {
            ShareLink(item: url) {
                HStack(spacing: Spacing.md) {
                    IconTile(systemImage: "checkmark", hue: .teal)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.name)
                            .font(.brand(.subheadline, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                            .dynamicLineLimit(2)
                        Text(FileSize.format(file.data.count))
                            .font(.brand(.caption))
                            .foregroundStyle(theme.textSecondary)
                    }
                    Spacer(minLength: Spacing.sm)
                    Image(systemName: "square.and.arrow.up")
                        .font(.brand(.body, weight: .medium))
                        .foregroundStyle(theme.accentText)
                        .accessibilityHidden(true)
                }
                .padding(.vertical, Spacing.xxs)
            }
            .accessibilityLabel("Save or share \(file.name)")
        }
    }
}

/// A failure, shown where the result would have been rather than in a dialog — the reason
/// stays on screen next to the control that will retry it.
struct ToolFailureRow: View {
    @Environment(\.theme) private var theme
    let message: String

    var body: some View {
        Label {
            Text(message)
                .font(.brand(.footnote))
                .foregroundStyle(theme.textPrimary)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(theme.danger)
        }
    }
}

/// Before and after, side by side — the web's result card (`CompressPdf.jsx:207-240`).
struct SizeComparison: View {
    @Environment(\.theme) private var theme

    let originalBytes: Int
    let originalDetail: String
    let resultBytes: Int
    let resultDetail: String
    let headline: String
    var isImprovement = true

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Before over after at the accessibility sizes, where two columns of large figures
            // do not fit side by side.
            AdaptiveStack(verticalAlignment: .top, spacing: 12) {
                column("Original", bytes: originalBytes, detail: originalDetail, highlighted: false)
                Image(systemName: dynamicTypeSize.isAccessibilitySize ? "arrow.down" : "arrow.right")
                    .foregroundStyle(theme.textTertiary)
                    .padding(.top, dynamicTypeSize.isAccessibilitySize ? 0 : 18)
                    .accessibilityHidden(true)
                column("Result", bytes: resultBytes, detail: resultDetail, highlighted: true)
                Spacer(minLength: 0)
            }
            Text(headline)
                .font(.brand(.headline))
                .foregroundStyle(isImprovement ? theme.success : theme.textSecondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func column(_ title: String, bytes: Int, detail: String, highlighted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // Drawn in capitals, spoken as the word: a string in capitals can be spelled out.
            Text(title)
                .textCase(.uppercase)
                .font(.brand(.caption2, weight: .semibold))
                .foregroundStyle(highlighted ? theme.accentText : theme.textTertiary)
            Text(FileSize.format(bytes))
                .font(.brand(.title3, weight: .semibold).monospacedDigit())
                .foregroundStyle(theme.textPrimary)
            Text(detail)
                .font(.brand(.caption))
                .foregroundStyle(theme.textSecondary)
        }
    }
}

/// The run button every tool ends with.
struct ToolRunButton: View {
    let title: String
    let runningTitle: String
    let isRunning: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(isRunning ? runningTitle : title)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.primaryAction)
        .disabled(!isEnabled || isRunning)
    }
}

/// Said under every on-device tool, because "on this phone" is the reason to use it rather
/// than the web, and nothing else on screen would say so.
struct OnDeviceNote: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Label("Everything happens on this phone. No document is uploaded.", systemImage: "lock.iphone")
            .font(.brand(.caption))
            .foregroundStyle(theme.textSecondary)
    }
}
