import SwiftUI

/// File tools — the platform's Document Utilities hub (`src/pages/tools/ToolsHub.jsx`).
///
/// A grid of cards, one per tool, each pushing that tool's own screen. The cards carry the
/// web's one distinction worth carrying: whether the file stays on the phone. Five of the seven
/// never touch the network, because these documents are privileged and uploading a client's brief
/// to cut three pages out of it would be the wrong trade regardless of convenience. PDF to Word
/// is the exception on both products — it is read on the server — and its card says so.
///
/// Presented from More, so it owns its `NavigationStack` and carries its own **Done**
/// (see `MoreView`). The tools push inside that stack and come back with the system back button.
struct PDFToolsView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Everyday document jobs. Split, merge, rearrange, compress and image to PDF run on this phone — those files never leave it. PDF to Word is read on Emperor's servers.")
                        .font(.brand(.subheadline))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    group("Documents", tools: DocumentTool.documentTools)
                    group("Images", tools: DocumentTool.imageTools)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(theme.canvas)
            .navigationTitle("File tools")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: DocumentTool.self) { tool in
                destination(for: tool)
            }
        }
    }

    /// Two columns where they fit; one at the accessibility text sizes, where a half-width card
    /// would wrap its title a word to a line.
    private var columns: [GridItem] {
        dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.adaptive(minimum: 158), spacing: 12, alignment: .top)]
    }

    private func group(_ title: String, tools: [DocumentTool]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: title)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(tools) { tool in
                    NavigationLink(value: tool) {
                        ToolCard(tool: tool)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("tool-\(tool.rawValue)")
                }
            }
        }
    }

    @ViewBuilder
    private func destination(for tool: DocumentTool) -> some View {
        switch tool {
        case .split: SplitPDFView()
        case .merge: MergePDFView()
        case .rearrange: RearrangePDFView()
        case .compressPDF: CompressPDFView()
        case .imageToPDF: ImageToPDFView()
        case .compressImage: CompressImageView()
        case .pdfToWord: OCRScreen(mode: .pdfToWord)
        }
    }
}

/// One tool: an icon, its name, a line saying what it does, and where the file goes.
private struct ToolCard: View {
    @Environment(\.theme) private var theme
    let tool: DocumentTool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: tool.symbol)
                    .font(.brand(.title3, weight: .semibold))
                    .foregroundStyle(theme.accentText)
                    .frame(width: 44, height: 44)
                    .background(theme.surfaceAccent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Spacer(minLength: 6)
                StatusPill(
                    text: tool.isOnDevice ? "On this phone" : "Uploaded",
                    tone: tool.isOnDevice ? .success : .info,
                    systemImage: tool.isOnDevice ? "lock.fill" : "icloud.and.arrow.up")
            }
            Text(tool.title)
                .font(.brand(.headline))
                .foregroundStyle(theme.textPrimary)
            Text(tool.summary)
                .font(.brand(.caption))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 168, alignment: .topLeading)
        .panel()
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(tool.isOnDevice ? "Runs on this phone" : "The document is uploaded to be converted")
    }
}
