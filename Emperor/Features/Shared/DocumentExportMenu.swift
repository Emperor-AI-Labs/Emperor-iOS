import SwiftUI

/// Exporting a drafted document — as a PDF, as Word, or as its own text.
///
/// Both files are built inside the menu's content closure, which SwiftUI evaluates when the menu
/// is opened rather than when the screen draws. That matters: laying out a PDF and packing an
/// OOXML archive for every document on screen would cost more than the feature is worth, and
/// most documents are read and never exported.
struct DocumentExportMenu: View {
    /// The document as it is held. Named `content` rather than `body`, which a `View` needs for
    /// itself.
    let content: String
    let isHTML: Bool
    let title: String
    /// Whether to ask, for each format, with or without the citation numbers — the Record
    /// draft's download menu. Offered only when the draft carries any.
    var offersCitationChoice = false

    var body: some View {
        Menu {
            if offersCitationChoice {
                Section("Word") {
                    wordLink("Word · with citations", subtitle: "References listed at the end", citations: true)
                    wordLink("Word · without citations", subtitle: "A clean copy for filing", citations: false)
                }
                Section("PDF") {
                    pdfLink("PDF · with citations", citations: true)
                    pdfLink("PDF · without citations", citations: false)
                }
            } else {
                pdfLink("PDF", citations: true)
                wordLink("Word (.docx)", subtitle: nil, citations: true)
            }
            Divider()
            // The document as it stands, for pasting somewhere this app knows nothing about.
            ShareLink(item: content) {
                Label("Copy as text", systemImage: "textformat")
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .accessibilityLabel("Download this document")
    }

    @ViewBuilder
    private func pdfLink(_ label: String, citations: Bool) -> some View {
        if let pdf = pdfURL(citations: citations) {
            ShareLink(item: pdf) {
                Label(label, systemImage: "doc.richtext")
            }
        }
    }

    @ViewBuilder
    private func wordLink(_ label: String, subtitle: String?, citations: Bool) -> some View {
        if let word = wordURL(citations: citations) {
            ShareLink(item: word) {
                if let subtitle {
                    Label {
                        Text(label)
                        Text(subtitle)
                    } icon: {
                        Image(systemName: "doc.text")
                    }
                } else {
                    Label(label, systemImage: "doc.text")
                }
            }
        }
    }

    private func fragment(citations: Bool) -> String {
        let source = citations ? content : DraftCitations.withoutMarkers(content)
        return isHTML ? source : MarkdownHTML.html(from: source)
    }

    private func fileStem(citations: Bool) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = trimmed.isEmpty ? "Document" : trimmed
        return citations || !offersCitationChoice ? stem : "\(stem) (clean)"
    }

    private func pdfURL(citations: Bool) -> URL? {
        ShareableFile.url(
            for: AnswerPDF.render(html: fragment(citations: citations)),
            named: "\(fileStem(citations: citations)).pdf")
    }

    private func wordURL(citations: Bool) -> URL? {
        ShareableFile.url(
            for: DocxDocument.make(fromHTML: fragment(citations: citations)),
            named: "\(fileStem(citations: citations)).docx")
    }
}
