import SwiftUI

/// Markdown as a document: headings, lists, quotes, code and real tables.
///
/// Used both inline in the transcript and full-screen in the artifact viewer, because they are
/// the same content — the platform says so plainly (`ToolWorkspace.jsx:503`: "The reply is
/// Markdown") and renders both through one component. This app drew the transcript with a plain
/// `Text`, so every heading and list arrived as literal characters on the screen people read
/// most.
///
/// Two parsers, deliberately. `MarkdownBlocks` finds the block structure, which
/// `AttributedString` cannot give us — its `.full` option encodes blocks as `presentationIntent`
/// runs that SwiftUI's `Text` ignores. Inline markup inside each block is still left to
/// `AttributedString`, so emphasis and links are parsed once, by the thing that already does it.
///
/// Numbered citations are found before either runs (`CitedMarkdown`): the References entries are
/// lifted out and drawn as a list, and each `[N]` that names one of them becomes a badge that
/// opens it. An answer without references comes out exactly as it did before.
struct MarkdownContentView: View {
    @Environment(\.theme) private var theme
    let markdown: String
    /// Whether the answer is still arriving. Only the last block can be mid-marker, and only
    /// then; see `CitationMarkup.linked`.
    var isStreaming = false

    /// The reference whose card is showing, after a tap on its number.
    @State private var shownCitation: CitationReference?

    var body: some View {
        content(CitedMarkdown.parse(markdown))
    }

    /// One parse per update, shared by every block and by the tap handler, so a badge and the
    /// card it opens can never disagree about what a number means.
    private func content(_ cited: CitedMarkdown) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(cited.blocks.enumerated()), id: \.offset) { offset, block in
                citedBlockView(
                    block, citations: cited.index,
                    isTail: isStreaming && offset == cited.blocks.count - 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // A badge is a link to a private scheme, intercepted here. Anything else — a real link
        // in the answer — is handed back to the system and opens as it always did.
        //
        // A card rather than a scroll to the References, which is what the web does
        // (`citations.js:317`): the transcript's scroll view belongs to the screen, not to this
        // answer, and a card can be read and dismissed without losing one's place.
        .environment(\.openURL, OpenURLAction { url in
            guard let number = CitationLink.number(from: url) else { return .systemAction }
            guard let reference = cited.index.reference(for: number) else { return .discarded }
            shownCitation = reference
            return .handled
        })
        .sheet(item: $shownCitation) { reference in
            CitationReferenceSheet(reference: reference)
        }
    }

    @ViewBuilder
    private func citedBlockView(
        _ block: CitedBlock, citations: CitationIndex, isTail: Bool
    ) -> some View {
        switch block {
        case .block(let markdownBlock):
            blockView(markdownBlock, citations: citations, isTail: isTail)
        case .table(let table):
            MarkdownTableView(table: table, citations: citations)
        case .references(let references):
            CitationReferenceList(references: references, citations: citations)
        }
    }

    @ViewBuilder
    private func blockView(
        _ block: MarkdownBlock, citations: CitationIndex, isTail: Bool
    ) -> some View {
        switch block {
        case .heading(let level, let text):
            InlineMarkdownText(text: text, citations: citations, holdingTrailingMarker: isTail)
                .font(.brand(headingStyle(level), weight: .bold))
                .foregroundStyle(theme.textPrimary)
                .padding(.top, level <= 2 ? 6 : 2)

        case .paragraph(let text):
            InlineMarkdownText(text: text, citations: citations, holdingTrailingMarker: isTail)

        case .bullet(let depth, let text):
            listRow(marker: bullet(depth), text: text, depth: depth, citations: citations,
                    isTail: isTail)

        case .numbered(let depth, let number, let text):
            listRow(marker: "\(number).", text: text, depth: depth, citations: citations,
                    isTail: isTail)

        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                // A rule rather than a quotation mark: the text is often itself a quotation and
                // would then carry two.
                Rectangle()
                    .fill(theme.accentMuted)
                    .frame(width: 3)
                InlineMarkdownText(text: text, citations: citations, holdingTrailingMarker: isTail)
                    .foregroundStyle(theme.textSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .code(let text):
            // Kept verbatim and scrollable: a citation block or a snippet must not be reflowed,
            // and must not push the answer around it sideways.
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
            .background(
                theme.surfaceElevated,
                in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                    .strokeBorder(theme.separator, lineWidth: 1))
        }
    }

    private func listRow(
        marker: String, text: String, depth: Int, citations: CitationIndex, isTail: Bool
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(marker)
                .font(.brand(.subheadline))
                .foregroundStyle(theme.textSecondary)
                // Fixed, so the text of every item in a list starts at the same place however
                // wide its marker is — "10." against "1." otherwise sets up a ragged edge.
                .frame(minWidth: 18, alignment: .trailing)
            InlineMarkdownText(text: text, citations: citations, holdingTrailingMarker: isTail)
        }
        .padding(.leading, CGFloat(depth) * 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Disc, circle, square by depth — the convention a word processor uses.
    private func bullet(_ depth: Int) -> String {
        ["•", "◦", "▪"][depth % 3]
    }

    private func headingStyle(_ level: Int) -> Font.TextStyle {
        switch level {
        case 1: return .title3
        case 2: return .headline
        default: return .subheadline
        }
    }
}

/// Renders a markdown artifact full-screen.
struct MarkdownArtifactView: View {
    @Environment(\.theme) private var theme
    @Environment(\.horizontalSizeClass) private var sizeClass
    let markdown: String

    /// The widest the text column is allowed to get.
    ///
    /// The same reasoning as the HTML wrapper's `ch` cap: run edge to edge on a 13-inch iPad and
    /// the line is long enough that the eye loses its place coming back to the left margin. A
    /// cap centred in the window reads as a page.
    private static let measure: CGFloat = 760

    var body: some View {
        ScrollView {
            MarkdownContentView(markdown: markdown)
                .frame(maxWidth: Self.measure, alignment: .leading)
                .padding(.horizontal, sizeClass == .regular ? 40 : 16)
                .padding(.vertical, 16)
                // Centres the capped column rather than pinning it to the leading edge.
                .frame(maxWidth: .infinity)
        }
    }
}

/// Inline markdown — bold, italics, links, citation badges. Everything a block is not.
///
/// Not file-private: the References list and the citation card draw their text with it too.
struct InlineMarkdownText: View {
    let text: String
    var citations: CitationIndex = .empty
    var holdingTrailingMarker = false

    var body: some View {
        CitedText(
            text: text, citations: citations, holdingTrailingMarker: holdingTrailingMarker)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A markdown table as an actual grid.
///
/// Scrolls horizontally inside its own container rather than forcing the page sideways — a
/// chronology with six columns does not fit a phone, and the answer around it must stay
/// readable at the normal width.
private struct MarkdownTableView: View {
    @Environment(\.theme) private var theme
    let table: MarkdownTable
    var citations: CitationIndex = .empty

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(table.headers.enumerated()), id: \.offset) { index, header in
                        cell(header, alignment: alignment(index), isHeader: true)
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)

                ForEach(Array(table.normalisedRows.enumerated()), id: \.offset) { rowIndex, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { index, value in
                            cell(value, alignment: alignment(index), isHeader: false)
                        }
                    }
                    if rowIndex < table.normalisedRows.count - 1 {
                        Divider().gridCellUnsizedAxes(.horizontal)
                    }
                }
            }
            .background(
                theme.surface,
                in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                    .strokeBorder(theme.separator, lineWidth: 1))
            .padding(.vertical, 2)
        }
    }

    private func alignment(_ index: Int) -> HorizontalAlignment {
        guard index < table.alignments.count else { return .leading }
        switch table.alignments[index] {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    @ViewBuilder
    private func cell(
        _ text: String, alignment: HorizontalAlignment, isHeader: Bool
    ) -> some View {
        // Read as inline markdown like every other line of the answer, so a chronology's
        // authority column carries the same citation badges as the prose above it — and bold
        // in a cell is bold, as it already is in the exported file.
        CitedText(text: text, citations: citations)
            // Spelled out on both sides: `font(_:)` takes an `Optional`, the shape the type
            // checker argues with when both branches are implicit members.
            .font((isHeader ? Font.brand(.caption, weight: .semibold) : Font.brand(.caption))
                .monospacedDigit())
            .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
            // Wide enough to read a date or a short phrase; capped so one long cell cannot
            // push every other column off the screen.
            .frame(minWidth: 72, maxWidth: 240, alignment: frameAlignment(alignment))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
    }

    private func frameAlignment(_ alignment: HorizontalAlignment) -> Alignment {
        switch alignment {
        case .center: return .center
        case .trailing: return .trailing
        default: return .leading
        }
    }
}
