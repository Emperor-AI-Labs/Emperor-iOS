import Foundation

/// What the matter's screen prints and draws from its record: the fee receipt for a payment, the
/// receipt file attached to an entry, the List of Dates & Events, and the Overview's timeline.
/// Kept beside `ProjectDetailViewModel` rather than inside it; every rule is in `FeeReceipt`,
/// `ChronologyExport`, `MatterRecord` and `OverviewTimeline`, held to the web's own code.
extension ProjectDetailViewModel {

    // MARK: - Fee receipt

    /// A receipt ready to print, for a payment entry.
    struct FeeReceiptDocument: Equatable, Sendable {
        /// The web's document, laid out for paper (`FeeReceipt.printableHTML`).
        let html: String
        let fileName: String
        let number: String
    }

    /// The receipt for a payment — the web offers one from a payment and from nothing else.
    func feeReceipt(for entry: LedgerEntry, user: User?) -> FeeReceiptDocument? {
        guard entry.entryKind == .payment, let project else { return nil }
        let html = FeeReceipt.printableHTML(
            advocate: FeeReceipt.advocate(from: user),
            client: FeeReceipt.client(project: project, people: people),
            matter: FeeReceipt.matter(from: project),
            entry: entry)
        return FeeReceiptDocument(
            html: html, fileName: FeeReceipt.fileName(for: entry), number: FeeReceipt.number(of: entry))
    }

    /// The file an entry names as its slip or challan, as the viewer opens it: by its name and
    /// the folder it is in, relative to the user's storage (`receipt_file`).
    func receiptAttachment(for entry: LedgerEntry) -> ChatAttachment? {
        let path = (entry.receiptFile ?? "").replacingOccurrences(of: "\\", with: "/")
        guard let name = FeeReceipt.attachedFileName(path) else { return nil }
        let folder = path.contains("/") ? String(path[..<path.lastIndex(of: "/")!]) : ""
        return ChatAttachment(name: name, folderName: folder.isEmpty ? nil : folder)
    }

    // MARK: - The record

    /// The chronology and the court's record as one list (`MatterRecord.entries`).
    var recordEntries: [MatterRecordEntry] {
        MatterRecord.entries(updates: updates, courtHistory: courtHistory)
    }

    /// The List of Dates & Events for the chosen groups, as an HTML fragment.
    func listOfDates(groups: Set<ChronologyExport.Group>) -> String? {
        guard let project else { return nil }
        return ChronologyExport.html(
            project: project, linkedCase: linkedCase,
            entries: ChronologyExport.picked(recordEntries, groups: groups))
    }

    /// The Overview timeline's rows for a day in India.
    func timelineRows(today: String = WireDate.todayKey()) -> [OverviewTimeline.Row] {
        let next = MatterRecord.nextHearing(
            projectDate: project?.nextHearingDateRaw, courtDate: linkedCase?.nextHearingDateRaw, today: today)
        return OverviewTimeline.rows(entries: recordEntries, next: next, today: today)
    }
}
