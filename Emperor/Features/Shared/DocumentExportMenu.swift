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
    /// Whether `content` is HTML. Markdown is bridged through `MarkdownHTML`, because both
    /// exporters read HTML.
    let isHTML: Bool
    /// What the file should be called, before an extension.
    let title: String

    var body: some View {
        Menu {
            if let pdf = pdfURL {
                ShareLink(item: pdf) {
                    Label("PDF", systemImage: "doc.richtext")
                }
            }
            if let word = wordURL {
                ShareLink(item: word) {
                    Label("Word (.docx)", systemImage: "doc.text")
                }
            }
            Divider()
            // The document as it stands, for pasting somewhere this app knows nothing about.
            ShareLink(item: content) {
                Label("Copy as text", systemImage: "textformat")
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .accessibilityLabel("Export this document")
    }

    /// The fragment both exporters read.
    private var fragment: String {
        isHTML ? content : MarkdownHTML.html(from: content)
    }

    private var fileStem: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Document" : trimmed
    }

    private var pdfURL: URL? {
        ShareableFile.url(for: AnswerPDF.render(html: fragment), named: "\(fileStem).pdf")
    }

    private var wordURL: URL? {
        ShareableFile.url(for: DocxDocument.make(fromHTML: fragment), named: "\(fileStem).docx")
    }
}
