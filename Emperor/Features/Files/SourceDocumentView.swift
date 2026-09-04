import SwiftUI
import UIKit
import PDFKit
import UniformTypeIdentifiers

/// Opens a cited source document at the page the citation names.
///
/// This is the claim the product rests on — every line names a page you can open — so the
/// jump has to actually land, and the failure has to be honest when it cannot.
struct SourceDocumentView: View {
    @Environment(\.theme) private var theme
    let attachment: ChatAttachment
    let mention: AnnexureMention

    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var model: SourceDocumentViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    content(model)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(model?.displayName ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                if let model {
                    ToolbarItem(placement: .principal) {
                        VStack(spacing: 1) {
                            Text(model.displayName).font(.brand(.headline)).lineLimit(1)
                            // The mark is how the document is referred to in the filing, so it
                            // belongs in the title bar next to the page.
                            Text(model.subtitle).font(.brand(.caption2)).foregroundStyle(theme.textSecondary)
                        }
                    }
                }
            }
            .task {
                guard model == nil else { return }
                let created = SourceDocumentViewModel(
                    attachment: attachment, mention: mention, service: session.files,
                    officePreview: session.officePreview)
                model = created
                await created.load()
            }
        }
    }

    @ViewBuilder
    private func content(_ model: SourceDocumentViewModel) -> some View {
        if model.isLoading {
            ProgressView("Opening \(model.displayName)")
        } else if let data = model.data, model.isPDF {
            PDFDataView(data: data, page: mention.startPage)
                .safeAreaInset(edge: .bottom) {
                    if model.isConvertedPreview {
                        // Said out loud because it is not the document. Pagination, fonts and
                        // line breaks are LibreOffice's reading of the file, so a page number
                        // taken from here may not match the one the sender sees — which for a
                        // filing is the difference that matters.
                        Text("Converted for viewing. Page breaks may differ from the original.")
                            .font(.brand(.caption2))
                            .foregroundStyle(theme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(theme.surface)
                    }
                }
        } else if let data = model.data, let image = UIImage(data: data) {
            // Scanned exhibits are frequently filed as images rather than PDFs.
            ScrollView([.horizontal, .vertical]) {
                Image(uiImage: image).resizable().scaledToFit()
            }
        } else if let text = model.textContents {
            ScrollView {
                Text(text)
                    .font(.brand(.callout))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        } else {
            ContentUnavailableView(
                "Cannot preview this document",
                systemImage: "doc.questionmark",
                description: Text(model.unavailableMessage))
        }
    }
}
