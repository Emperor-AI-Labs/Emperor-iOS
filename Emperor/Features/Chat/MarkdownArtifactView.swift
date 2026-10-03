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
struct MarkdownContentView: View {
    @Environment(\.theme) private var theme
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownTable.segments(in: markdown).enumerated()), id: \.offset) {
                _, segment in
                switch segment {
                case .prose(let text):
                    ForEach(Array(MarkdownBlocks.parse(text).enumerated()), id: \.offset) {
                        _, block in
                        blockView(block)
                    }
                case .table(let table):
                    MarkdownTableView(table: table)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            InlineMarkdownText(text: text)
                .font(.brand(headingStyle(level), weight: .bold))
                .foregroundStyle(theme.textPrimary)
                .padding(.top, level <= 2 ? 6 : 2)

        case .paragraph(let text):
            InlineMarkdownText(text: text)

        case .bullet(let depth, let text):
            listRow(marker: bullet(depth), text: text, depth: depth)

        case .numbered(let depth, let number, let text):
            listRow(marker: "\(number).", text: text, depth: depth)

        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                // A rule rather than a quotation mark: the text is often itself a quotation and
                // would then carry two.
                Rectangle()
                    .fill(theme.accentMuted)
                    .frame(width: 3)
                InlineMarkdownText(text: text)
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
            .background(theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func listRow(marker: String, text: String, depth: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(marker)
                .font(.brand(.subheadline))
                .foregroundStyle(theme.textSecondary)
                // Fixed, so the text of every item in a list starts at the same place however
                // wide its marker is — "10." against "1." otherwise sets up a ragged edge.
                .frame(minWidth: 18, alignment: .trailing)
            InlineMarkdownText(text: text)
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

/// Inline markdown — bold, italics, links. Everything a block is not.
private struct InlineMarkdownText: View {
    let text: String

    var body: some View {
        Text(attributed)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var attributed: AttributedString {
        // `.inlineOnlyPreservingWhitespace`, NOT `.full`. `.full` strips newlines and encodes
        // breaks as `presentationIntent` runs, which SwiftUI's `Text` ignores — every
        // multi-paragraph draft would render as one unbroken blob. A failure to parse falls
        // back to the raw text rather than showing nothing.
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                           failurePolicy: .returnPartiallyParsedIfPossible)))
            ?? AttributedString(text)
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
            .background(theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8))
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
        Text(text)
            .font(isHeader ? .caption.weight(.semibold) : .caption)
            .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
            .textSelection(.enabled)
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
