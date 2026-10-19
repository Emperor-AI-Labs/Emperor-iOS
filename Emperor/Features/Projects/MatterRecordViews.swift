import SwiftUI
import UIKit

// The matter screen's printed things and its timeline: the fee receipt from a payment, the slip
// attached to an entry, the List of Dates & Events from the Chronology, and the Overview's drawn
// timeline. Every rule is in the core (`FeeReceipt`, `ChronologyExport`, `OverviewTimeline`,
// reached through `ProjectDetailViewModel`'s record extension); these views lay them out.

// MARK: - A whole HTML document as a PDF

/// Renders a complete HTML document — one that carries its own stylesheet, as the fee receipt
/// does — to A4. `AnswerPDF` wraps a fragment in the answer stylesheet first; a receipt must keep
/// its own, so it is drawn as it is, with the receipt's `@page` margins (16 mm by 18 mm).
enum HTMLDocumentPDF {
    static func render(document html: String) -> Data {
        let paper = CGSize(width: 595.2, height: 841.8)  // A4 in points, as `AnswerPDF` draws it
        let insets = UIEdgeInsets(top: 45.35, left: 51.02, bottom: 45.35, right: 51.02)
        let renderer = UIPrintPageRenderer()
        let formatter = UIMarkupTextPrintFormatter(markupText: html)
        formatter.perPageContentInsets = insets
        renderer.addPrintFormatter(formatter, startingAtPageAt: 0)
        let paperRect = CGRect(origin: .zero, size: paper)
        // Read by `UIPrintPageRenderer` through KVC, as `AnswerPDF` explains.
        renderer.setValue(paperRect, forKey: "paperRect")
        renderer.setValue(paperRect.inset(by: insets), forKey: "printableRect")
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
}

// MARK: - A ledger entry's menu

/// A document the matter's screen opens in the viewer.
struct MatterOpenedFile: Identifiable {
    let attachment: ChatAttachment
    var id: String { "\(attachment.folderName ?? "")/\(attachment.name)" }
}

/// The "…" beside a ledger entry: the fee receipt for a payment, built as a PDF when the menu
/// opens and offered through the share sheet, and the slip or challan the entry names.
struct LedgerEntryMenu: View {
    let entry: LedgerEntry
    let model: ProjectDetailViewModel
    let user: User?
    let onOpen: (ChatAttachment) -> Void

    var body: some View {
        let receipt = model.feeReceipt(for: entry, user: user)
        let attached = model.receiptAttachment(for: entry)
        if receipt != nil || attached != nil {
            Menu {
                if let receipt, let url = ShareableFile.url(
                    for: HTMLDocumentPDF.render(document: receipt.html), named: receipt.fileName) {
                    ShareLink(item: url) {
                        Label("Fee receipt", systemImage: "printer")
                    }
                }
                if let attached {
                    Button {
                        onOpen(attached)
                    } label: {
                        Label("Open \(DisplayText.fileName(attached.name))", systemImage: "paperclip")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .imageScale(.large)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(receipt != nil ? "Fee receipt and attachments" : "Attached file")
        }
    }
}

// MARK: - List of Dates & Events

/// The Chronology's way out: a row that opens the List of Dates & Events sheet.
struct ChronologyExportRow: View {
    @Environment(\.theme) private var theme
    let action: () -> Void

    var body: some View {
        Section {
            Button(action: action) {
                Label("List of Dates & Events", systemImage: "list.bullet.rectangle")
            }
        } footer: {
            Text("The chronology as the synopsis of a petition prints it, as Word or PDF.")
                .font(.brand(.caption2))
                .foregroundStyle(theme.textTertiary)
        }
        .listRowBackground(theme.surface)
    }
}

/// Pick what goes in, see it, take it out as Word or PDF — the web's export form.
struct ChronologyExportSheet: View {
    let model: ProjectDetailViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var groups = ChronologyExport.defaultGroups

    var body: some View {
        let entries = model.recordEntries
        let byGroup = ChronologyExport.grouped(entries)
        let picked = ChronologyExport.picked(entries, groups: groups)
        NavigationStack {
            List {
                Section {
                    ForEach(ChronologyExport.Group.allCases.filter { !(byGroup[$0] ?? []).isEmpty }) { group in
                        Toggle(isOn: binding(group)) {
                            HStack {
                                Text(group.label)
                                Spacer(minLength: Spacing.sm)
                                Text("\(byGroup[group]?.count ?? 0)")
                                    .monospacedDigit()
                                    .foregroundStyle(theme.textSecondary)
                            }
                        }
                    }
                } footer: {
                    Text("Dates print as DD.MM.YYYY under the court and cause title of this matter. Check the list before it is filed.")
                        .font(.brand(.caption))
                        .foregroundStyle(theme.textSecondary)
                }
                .listRowBackground(theme.surface)

                ChronologyExportPreview(entries: picked)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.groupedBackground)
            .navigationTitle("List of Dates & Events")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    downloadMenu(isEmpty: picked.isEmpty)
                }
            }
        }
    }

    private func binding(_ group: ChronologyExport.Group) -> Binding<Bool> {
        Binding(
            get: { groups.contains(group) },
            set: { on in
                if on { groups.insert(group) } else { groups.remove(group) }
            })
    }

    /// Built when the menu opens, not on every redraw.
    private func downloadMenu(isEmpty: Bool) -> some View {
        Menu {
            if let html = model.listOfDates(groups: groups) {
                let base = ChronologyExport.baseName(matterName: model.project?.name)
                if let word = ShareableFile.url(for: DocxDocument.make(fromHTML: html), named: "\(base).docx") {
                    ShareLink(item: word) { Label("Download Word", systemImage: "doc.text") }
                }
                if let pdf = ShareableFile.url(for: AnswerPDF.render(html: html), named: "\(base).pdf") {
                    ShareLink(item: pdf) { Label("Download PDF", systemImage: "doc.richtext") }
                }
            }
        } label: {
            Label("Download", systemImage: "square.and.arrow.down")
        }
        .disabled(isEmpty)
        .accessibilityLabel("Download the List of Dates and Events")
    }
}

/// The dates and events as they will print, oldest first.
private struct ChronologyExportPreview: View {
    @Environment(\.theme) private var theme
    let entries: [MatterRecordEntry]

    var body: some View {
        let ordered = MatterRecord.sorted(entries)
        Section {
            ForEach(ordered.prefix(40)) { entry in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
                    Text(MatterRecord.dots(entry.day))
                        .font(.brand(.caption, weight: .semibold).monospacedDigit())
                        .foregroundStyle(theme.textSecondary)
                    Text(MatterRecord.eventText(entry))
                        .font(.brand(.subheadline))
                        .foregroundStyle(theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
            if ordered.count > 40 {
                Text("…and \(ordered.count - 40) more")
                    .font(.brand(.caption))
                    .foregroundStyle(theme.textSecondary)
            }
        } header: {
            SectionHeader(title: ChronologyExport.summary(entries))
        }
        .listRowBackground(theme.surface)
    }
}

// MARK: - The Overview timeline

/// The matter's timeline, drawn: one line down the middle, each row's date on one side and what
/// happened on the other, swapping sides from row to row as the web's does; a year marker where
/// the year changes, and the next hearing on top. The court's rows, the user's and the ones found
/// in the documents carry different marks and say so in words.
struct OverviewTimelineSection: View {
    @Environment(\.theme) private var theme
    let rows: [OverviewTimeline.Row]
    let onOpen: () -> Void

    var body: some View {
        Section {
            if rows.isEmpty {
                Text(OverviewTimeline.emptyText)
                    .font(.brand(.footnote))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        OverviewTimelineRowView(row: row)
                    }
                }
                .padding(.vertical, Spacing.xs)
                .contentShape(Rectangle())
                .onTapGesture(perform: onOpen)
                .accessibilityAction(named: "Open the chronology", onOpen)
            }
        } header: {
            SectionHeader(title: "Timeline")
        } footer: {
            Text("Every step of the matter so far, newest at the top. Court dates and orders come in by themselves; dates you add show here too.")
                .font(.brand(.caption2))
                .foregroundStyle(theme.textTertiary)
        }
        .listRowBackground(theme.surface)
    }
}

private struct OverviewTimelineRowView: View {
    @Environment(\.theme) private var theme
    let row: OverviewTimeline.Row

    var body: some View {
        switch row.kind {
        case .year(let year):
            Text(year)
                .font(.brand(.caption2, weight: .bold))
                .foregroundStyle(theme.textSecondary)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, 2)
                .background(theme.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(theme.separator, lineWidth: 1))
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.xs)
                .background(alignment: .center) { spine }
                .accessibilityLabel(year)
                .accessibilityAddTraits(.isHeader)
        default:
            HStack(alignment: .top, spacing: Spacing.sm) {
                side(leading: true)
                node
                side(leading: false)
            }
            .padding(.vertical, Spacing.xs)
            .background(alignment: .center) { spine }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.accessibilityText)
        }
    }

    private var spine: some View {
        Rectangle().fill(theme.separator).frame(width: 1.5)
    }

    /// The date on one side, the words on the other; which is which flips with the row.
    @ViewBuilder
    private func side(leading: Bool) -> some View {
        let showsDate = leading != row.isFlipped
        Group {
            if showsDate { dateBlock } else { titleBlock }
        }
        .frame(maxWidth: .infinity, alignment: leading ? .trailing : .leading)
        .multilineTextAlignment(leading ? .trailing : .leading)
    }

    private var isNext: Bool { row.kind == .next }

    private var dateBlock: some View {
        VStack(alignment: .center, spacing: 1) {
            Text(row.date)
                .font(.brand(.footnote, weight: .bold).monospacedDigit())
                .foregroundStyle(isNext ? theme.accentText : theme.textPrimary)
            if !row.subtitle.isEmpty {
                Text(row.subtitle)
                    .font(.brand(.caption2, weight: .semibold))
                    .foregroundStyle(isNext ? theme.accentText : theme.textSecondary)
            }
        }
    }

    private var titleBlock: some View {
        VStack(spacing: 1) {
            Text(row.title)
                .font(.brand(.footnote, weight: isNext || row.isOrder ? .semibold : .regular))
                .foregroundStyle(isNext ? theme.accentText : theme.textPrimary)
                .lineLimit(2)
            if case .entry(_, let origin) = row.kind {
                Text(origin.label)
                    .font(.brand(.caption2))
                    .foregroundStyle(origin == .court ? theme.textSecondary : theme.accentText)
            }
        }
    }

    /// The mark on the line: filled for the next hearing, a seal for the court's own rows, a
    /// sparkle for what was found in the documents, a dot for the user's.
    private var node: some View {
        let symbol: String
        let tint: Color
        switch row.kind {
        case .next:
            symbol = "calendar.badge.clock"; tint = theme.accentText
        case .entry(let kind, let origin):
            switch origin {
            case .court: symbol = kind == "order" ? "doc.text.fill" : "building.columns.fill"; tint = theme.textSecondary
            case .ai: symbol = "sparkles"; tint = theme.accentText
            case .manual: symbol = "circle.fill"; tint = theme.accentText
            }
        case .year:
            symbol = "circle"; tint = theme.textSecondary
        }
        return Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 26, height: 26)
            .background(theme.surface, in: Circle())
            .overlay(Circle().strokeBorder(isNext || row.isOrder ? tint : theme.separator, lineWidth: isNext ? 2 : 1))
            .accessibilityHidden(true)
    }
}

// MARK: - The sheets

/// The List of Dates sheet and the viewer for an entry's attached slip, as one modifier so the
/// matter screen's long chain of sheets does not grow two more.
struct MatterRecordSheets: ViewModifier {
    let model: ProjectDetailViewModel
    @Binding var isExportingChronology: Bool
    @Binding var openedFile: MatterOpenedFile?

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isExportingChronology) {
                ChronologyExportSheet(model: model)
                    .pageSizedSheet()
            }
            .sheet(item: $openedFile) { file in
                // No citation brought us here: the viewer opens at the top, as from My Files.
                SourceDocumentView(
                    attachment: file.attachment,
                    mention: AnnexureMention(
                        fileName: file.attachment.name, mark: "", startPage: nil, endPage: nil),
                    isCitation: false)
            }
    }
}
