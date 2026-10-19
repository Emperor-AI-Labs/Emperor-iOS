import SwiftUI

/// The web's Download menu on the cause list: the day's listings as a PDF, a Word document or a
/// CSV, with the web's columns and file names (`CauseListExport`), through the share sheet.
///
/// Each file is built inside the menu's content closure, which SwiftUI evaluates when the menu is
/// opened rather than when the screen draws — laying out a PDF on every redraw of the calendar
/// would cost more than the feature is worth.
struct CauseListDownloadMenu: View {
    /// The day, `YYYY-MM-DD` in India.
    let day: String
    let listings: [CauseListing]

    var body: some View {
        Menu {
            ForEach(CauseListExport.Format.allCases) { format in
                if let url = file(format) {
                    ShareLink(item: url) {
                        Label("Download \(format.label)", systemImage: symbol(format))
                    }
                }
            }
        } label: {
            Label("Download", systemImage: "square.and.arrow.down")
        }
        .disabled(listings.isEmpty)
        .accessibilityLabel("Download this day's cause list")
    }

    private func file(_ format: CauseListExport.Format) -> URL? {
        let data: Data
        switch format {
        case .pdf:
            data = AnswerPDF.render(html: CauseListExport.html(day: day, listings: listings, format: .pdf))
        case .docx:
            data = DocxDocument.make(fromHTML: CauseListExport.html(day: day, listings: listings, format: .docx))
        case .csv:
            data = Data(CauseListExport.csv(listings).utf8)
        }
        return ShareableFile.url(for: data, named: CauseListExport.fileName(day: day, format: format))
    }

    private func symbol(_ format: CauseListExport.Format) -> String {
        switch format {
        case .pdf: return "doc.richtext"
        case .docx: return "doc.text"
        case .csv: return "tablecells"
        }
    }
}
