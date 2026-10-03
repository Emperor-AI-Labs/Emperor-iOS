import SwiftUI
import UniformTypeIdentifiers

/// Compress PDF — the platform's `/tools/compress-pdf` (`src/pages/tools/CompressPdf.jsx`).
///
/// The same three levels as the web, with the web's own descriptions. What happens to the file
/// differs, and the screen says how: the web re-encodes the images inside each page, which
/// PDFKit cannot reach, so here the scanned and photographed pages are redrawn at the level's
/// resolution while typed pages are copied untouched. `PDFCompression` has the rules.
///
/// The original is never replaced. The result is a new file, offered only when it is actually
/// smaller, beside the original's size so the saving is plain.
struct CompressPDFView: View {
    @Environment(\.theme) private var theme

    @State private var model: CompressPDFViewModel?
    @State private var isPicking = false
    @State private var isOpening = false
    @State private var openFailure: String?

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.canvas)
        .navigationTitle("Compress PDF")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if model == nil { model = CompressPDFViewModel(engine: OnDeviceToolEngine()) }
        }
        .fileImporter(
            isPresented: $isPicking,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { outcome in
            guard case .success(let urls) = outcome, let url = urls.first else { return }
            Task { await open(url) }
        }
    }

    private func open(_ url: URL) async {
        guard let model else { return }
        isOpening = true
        openFailure = nil
        defer { isOpening = false }
        guard let file = await ToolImport.copy(url),
              let pageCount = await ToolImport.pageCount(of: file)
        else {
            openFailure = PDFTools.Failure.unreadable.errorDescription
            return
        }
        model.load(file, pageCount: pageCount)
    }

    @ViewBuilder
    private func content(_ model: CompressPDFViewModel) -> some View {
        Form {
            Section {
                if let source = model.source {
                    ToolSourceRow(
                        name: source.name,
                        detail: "\(FileSize.format(source.bytes)) · \(model.pageCount) page\(model.pageCount == 1 ? "" : "s")",
                        change: model.state.isRunning ? nil : { isPicking = true })
                } else {
                    Button {
                        isPicking = true
                    } label: {
                        Label(isOpening ? "Opening…" : "Choose a PDF", systemImage: "doc.badge.plus")
                    }
                    .disabled(isOpening)
                }
                if let openFailure {
                    ToolFailureRow(message: openFailure)
                }
            } header: {
                SectionHeader(title: "Document")
            }

            if model.source != nil {
                Section {
                    ForEach(PDFCompression.levels) { level in
                        Button {
                            model.level = level
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: model.level == level ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(model.level == level ? theme.accent : theme.textTertiary)
                                    .font(.brand(.title3))
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(level.label)
                                        .font(.brand(.subheadline, weight: .semibold))
                                        .foregroundStyle(theme.textPrimary)
                                    Text(level.detail)
                                        .font(.brand(.caption))
                                        .foregroundStyle(theme.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(model.state.isRunning)
                        .accessibilityAddTraits(model.level == level ? .isSelected : [])
                    }
                } header: {
                    SectionHeader(title: "Compression level")
                } footer: {
                    Text("Scanned and photographed pages are redrawn as JPEG at this level; their text is kept as an invisible layer, so search and copy still work. Typed pages, and pages with links or form fields, are copied exactly as they are.")
                        .font(.brand(.caption2))
                }

                Section {
                    ToolRunButton(
                        title: "Compress", runningTitle: "Compressing…",
                        isRunning: model.state.isRunning, isEnabled: model.canRun
                    ) {
                        Task { await model.run() }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)

                    if model.state.isRunning {
                        ProgressView(value: model.progress)
                            .listRowBackground(Color.clear)
                            .accessibilityLabel("Compressing")
                    }
                } footer: {
                    OnDeviceNote()
                }

                if let failure = model.state.failureMessage {
                    Section {
                        ToolFailureRow(message: failure)
                    }
                }

                if let outcome = model.currentOutcome, let source = model.source {
                    Section {
                        SizeComparison(
                            originalBytes: source.bytes,
                            originalDetail: "\(model.pageCount) page\(model.pageCount == 1 ? "" : "s")",
                            resultBytes: outcome.compressedBytes,
                            resultDetail: "PDF",
                            headline: outcome.headline,
                            isImprovement: outcome.hasReduction)
                        Text(outcome.detail)
                            .font(.brand(.caption))
                            .foregroundStyle(outcome.isMeaningful ? theme.textSecondary : theme.warning)
                        if let output = model.currentOutput {
                            ToolResultRow(file: output)
                        }
                    } header: {
                        SectionHeader(title: "Result")
                    } footer: {
                        Text("Your original is unchanged. The result is a new file.")
                            .font(.brand(.caption2))
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
    }
}
