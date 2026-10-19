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

    /// The page an answer is laid out on when no page setup is given: A4, with a margin wide
    /// enough to survive a stapler and a registry's hole punch. A drafted document is laid out
    /// on the account's own `DocumentPageSetup` instead — what the web's print path does with
    /// its canvas page setup, and what it does without one is keep its fixed default, as here.
    private static let defaultPaper = CGSize(width: 595.2, height: 841.8)
    private static let defaultMargin: CGFloat = 36

    /// Renders `html` onto the page `pageSetup` describes — its size, orientation and margins —
    /// or onto the fixed A4 default when there is none.
    ///
    /// - Important: the markup is wrapped by `ArtifactDocument.html(wrapping:)` first, which is
    ///   the same wrapper the artifact viewer uses — so an exported answer and an answer on
    ///   screen cannot drift apart in styling.
    static func render(html fragment: String, pageSetup: DocumentPageSetup? = nil) -> Data {
        let paperSize: CGSize
        let insets: UIEdgeInsets
        if let pageSetup {
            paperSize = CGSize(width: pageSetup.widthPoints, height: pageSetup.heightPoints)
            let m = pageSetup.marginPoints
            insets = UIEdgeInsets(top: m.top, left: m.left, bottom: m.bottom, right: m.right)
        } else {
            paperSize = defaultPaper
            insets = UIEdgeInsets(
                top: defaultMargin, left: defaultMargin, bottom: defaultMargin, right: defaultMargin)
        }

        let renderer = UIPrintPageRenderer()
        let formatter = UIMarkupTextPrintFormatter(
            markupText: ArtifactDocument.html(wrapping: fragment))
        formatter.perPageContentInsets = insets
        renderer.addPrintFormatter(formatter, startingAtPageAt: 0)

        let paperRect = CGRect(origin: .zero, size: paperSize)
        let printable = paperRect.inset(by: insets)
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
