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
                VStack(alignment: .leading, spacing: Spacing.xxl) {
                    Text("Everyday document jobs. Split, merge, rearrange, compress and image to PDF run on this phone — those files never leave it. PDF to Word is read on Emperor's servers.")
                        .font(.brand(.subheadline))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    group("Documents", tools: DocumentTool.documentTools)
                    group("Images", tools: DocumentTool.imageTools)
                }
                // A readable width on an iPad, centred, rather than cards stretched edge to edge.
                .frame(maxWidth: 760)
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.md)
                .frame(maxWidth: .infinity)
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
            : [GridItem(.adaptive(minimum: 158), spacing: Spacing.md, alignment: .top)]
    }

    private func group(_ title: String, tools: [DocumentTool]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm + 2) {
            SectionHeader(title: title)
                .padding(.horizontal, Spacing.xs)
            LazyVGrid(columns: columns, alignment: .leading, spacing: Spacing.md) {
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
        VStack(alignment: .leading, spacing: Spacing.sm + 2) {
            HStack(alignment: .top) {
                IconTile(systemImage: tool.symbol, hue: hue, size: .large)
                Spacer(minLength: 6)
                StatusPill(
                    text: tool.isOnDevice ? "On this phone" : "Uploaded",
                    tone: tool.isOnDevice ? .success : .info,
                    systemImage: tool.isOnDevice ? "lock.fill" : "icloud.and.arrow.up")
            }
            Text(tool.title)
                .font(.brand(.headline))
                .foregroundStyle(theme.textPrimary)
                .padding(.top, Spacing.xxs)
            Text(tool.summary)
                .font(.brand(.caption))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, minHeight: 168, alignment: .topLeading)
        .panel()
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(tool.isOnDevice ? "Runs on this phone" : "The document is uploaded to be converted")
    }

    /// One of the web's muted hues per tool, so the grid reads as seven tools rather than one
    /// tile seven times. Fixed here rather than hashed: these are the app's own cards, not
    /// registry tools, and the seven should never collide.
    private var hue: TileHue {
        switch tool {
        case .split: return .rose
        case .merge: return .steel
        case .rearrange: return .violet
        case .compressPDF: return .teal
        case .imageToPDF: return .gold
        case .compressImage: return .aqua
        case .pdfToWord: return .indigo
        }
    }
}
