import SwiftUI

// The reading room — the web's `ReadingRoom.jsx`: the document's facts in the head, then its
// body — the judgment reader for text, the PDF for everything else — with share and download
// only when the file is on the shelf.

struct LibraryDocumentView: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session

    let doc: CatalogueDocument
    @Binding var path: [LibraryRoute]

    @State private var model: LibraryDocumentViewModel?

    var body: some View {
        Group {
            if let model {
                LibraryDocumentBody(model: model, path: $path)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(model?.kind ?? doc.theme.cap)
        .navigationBarTitleDisplayMode(.inline)
        .background(theme.canvas)
        .task(id: doc.id) {
            guard model == nil else { return }
            let created = LibraryDocumentViewModel(doc: doc, service: session.library)
            model = created
            await created.load()
        }
    }
}

private struct LibraryDocumentBody: View {
    @Environment(\.theme) private var theme
    let model: LibraryDocumentViewModel
    @Binding var path: [LibraryRoute]

    var body: some View {
        VStack(spacing: 0) {
            LibraryDocumentHead(model: model)
            Divider()
            if model.isText {
                JudgmentReaderView(doc: model.doc)
            } else {
                LibraryPDFBody(model: model)
            }
        }
        .toolbar {
            if model.onShelf, let data = model.pdf {
                ToolbarItem(placement: .primaryAction) {
                    LibraryShareButton(data: data, name: model.shareName)
                }
            }
        }
    }
}

/// A small cover, the title, the kind and the facts.
private struct LibraryDocumentHead: View {
    @Environment(\.theme) private var theme
    let model: LibraryDocumentViewModel

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            LibraryCoverView(doc: model.doc, size: .small, image: false)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.title)
                    .font(.display(size: 17, relativeTo: .headline))
                    .foregroundStyle(theme.textPrimary)
                    .dynamicLineLimit(3)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: 6) {
                    Text(model.kind)
                        .font(.brand(.caption2, weight: .bold))
                        .foregroundStyle(Color(model.theme.ink(dark: theme.isDark)))
                    ForEach(model.meta, id: \.self) { fact in
                        SeparatorDot()
                        Text(fact)
                    }
                }
                .font(.brand(.caption2))
                .foregroundStyle(theme.textTertiary)
                .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.gutter)
        .padding(.vertical, Spacing.sm)
        .background(theme.chrome)
    }
}

/// The PDF, after the check that its file is on this server.
private struct LibraryPDFBody: View {
    @Environment(\.theme) private var theme
    let model: LibraryDocumentViewModel

    var body: some View {
        if let data = model.pdf {
            PDFDataView(data: data)
                .ignoresSafeArea(edges: .bottom)
        } else if model.isMissing {
            ScrollView {
                LibraryEmptyView(title: LibraryDocumentViewModel.Copy.missingTitle, hint: LibraryDocumentViewModel.Copy.missingHint)
                    .padding(.top, Spacing.xl)
            }
        } else if let failure = model.fileState.failure {
            ScrollView {
                LibraryEmptyView(title: failure.kind == .server && failure.message.contains("no such") ? LibraryDocumentViewModel.Copy.goneTitle : LibraryDocumentViewModel.Copy.failedTitle,
                                 hint: failure.message, isError: true) {
                    if failure.isRetryable {
                        Button("Try again") { Task { await model.loadFileIfPDF() } }.buttonStyle(.compactSecondaryAction)
                    }
                }
                .padding(.top, Spacing.xl)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct LibraryShareButton: View {
    let data: Data
    let name: String

    var body: some View {
        if let url = ShareableFile.url(for: data, named: name) {
            ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                .accessibilityLabel("Share")
        }
    }
}
