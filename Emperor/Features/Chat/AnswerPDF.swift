import UIKit

/// Renders an answer to a PDF that can be filed, printed or emailed.
///
/// An advocate's use for an answer is rarely to keep reading it on a phone — it is to put it in
/// a brief, send it to a junior, or print it. Until now the only way out of this app was Copy,
/// which loses every table and heading.
///
/// ## Why the print formatter rather than WKWebView
///
/// `WKWebView.createPDF` is asynchronous, needs a live view in a hierarchy, and produces
/// nothing useful if the view has not laid out yet — all awkward from a share action.
/// `UIMarkupTextPrintFormatter` is the same HTML engine driven synchronously, which is what
/// this needs: hand it markup, get back bytes.
enum AnswerPDF {

    /// Paper the output is laid out for.
    ///
    /// A4 for India, and it is the default for that reason — Letter exists because the
    /// artifact viewer already offers both and the two must not disagree.
    enum Paper: String, CaseIterable, Identifiable {
        case a4 = "A4"
        case letter = "Letter"

        var id: String { rawValue }

        /// In points, at 72 per inch, which is what UIKit's print system measures in.
        var size: CGSize {
            switch self {
            case .a4: return CGSize(width: 595.2, height: 841.8)
            case .letter: return CGSize(width: 612, height: 792)
            }
        }
    }

    /// A margin wide enough to survive a stapler and a registry's hole punch.
    private static let margin: CGFloat = 36

    /// Renders `html` onto `paper`.
    ///
    /// - Important: the markup is wrapped by `ArtifactDocument.html(wrapping:)` first, which is
    ///   the same wrapper the artifact viewer uses — so an exported answer and an answer on
    ///   screen cannot drift apart in styling.
    static func render(html fragment: String, paper: Paper = .a4) -> Data {
        let renderer = UIPrintPageRenderer()
        let formatter = UIMarkupTextPrintFormatter(
            markupText: ArtifactDocument.html(wrapping: fragment))
        formatter.perPageContentInsets = UIEdgeInsets(
            top: margin, left: margin, bottom: margin, right: margin)
        renderer.addPrintFormatter(formatter, startingAtPageAt: 0)

        let paperRect = CGRect(origin: .zero, size: paper.size)
        let printable = paperRect.insetBy(dx: margin, dy: margin)
        // These two are read by `UIPrintPageRenderer` through KVC, not properties — it has no
        // public setter for either, and without them it lays out at zero size and returns a
        // single blank page.
        renderer.setValue(paperRect, forKey: "paperRect")
        renderer.setValue(printable, forKey: "printableRect")

        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, paperRect, nil)
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: renderer.numberOfPages))
        for page in 0..<renderer.numberOfPages {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: page, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()
        return data as Data
    }

    /// A filename that says what it is and when, without leaking the question into a filename
    /// that may end up in a shared folder.
    static func fileName(on date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        formatter.timeZone = TimeZone(identifier: "Asia/Kolkata")
        return "Emperor-answer-\(formatter.string(from: date)).pdf"
    }
}
