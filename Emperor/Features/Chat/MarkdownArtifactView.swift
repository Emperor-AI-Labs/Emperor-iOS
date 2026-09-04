import SwiftUI

/// Renders a markdown artifact, with real tables.
///
/// `AttributedString(markdown:)` silently does not support tables — it renders the pipe syntax
/// as literal text. Chronologies and lists of dates are a large share of what this product
/// produces, so the document is split into tables and prose (`MarkdownTable.segments`) and each
/// is rendered by something that can actually handle it.
struct MarkdownArtifactView: View {
    @Environment(\.theme) private var theme
    let markdown: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(MarkdownTable.segments(in: markdown).enumerated()), id: \.offset) {
                    _, segment in
                    switch segment {
                    case .prose(let text):
                        ProseView(text: text)
                    case .table(let table):
                        MarkdownTableView(table: table)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }
}

/// Inline markdown — bold, italics, links. Everything a table is not.
private struct ProseView: View {
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
