import SwiftUI

/// Doc Index on a phone: one card per document rather than a wide table. The title column heads
/// the card, badges sit under it, and every other filled column is a label and its value.
struct DocIndexResultView: View {
    @Environment(\.theme) private var theme
    let index: DocIndexResult

    @State private var filter: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            DocIndexSummary(index: index)
            if !index.filterOptions.isEmpty {
                DocIndexFilterBar(index: index, filter: $filter)
            }
            let rows = Array(index.rows(matching: filter).enumerated())
            ForEach(rows, id: \.offset) { offset, row in
                DocIndexCard(index: index, row: row)
                    .id(DocIndexResult.id(of: row, at: offset))
            }
        }
    }
}

/// The index's label, the counts and why the AI chose these columns.
struct DocIndexSummary: View {
    @Environment(\.theme) private var theme
    let index: DocIndexResult

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(index.label)
                .font(.display(size: 24, relativeTo: .title2))
                .foregroundStyle(theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(index.summaryLine)
                .font(.brand(.subheadline, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
            if !index.rationale.isEmpty {
                Text(index.rationale)
                    .font(.brand(.footnote))
                    .foregroundStyle(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// "All 12 · Pleading 5 · Contract 3" — the filter column's values as chips.
struct DocIndexFilterBar: View {
    @Environment(\.theme) private var theme
    let index: DocIndexResult
    @Binding var filter: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.sm) {
                chip("All", count: index.rows.count, value: nil)
                ForEach(index.filterOptions) { option in
                    chip(option.value, count: option.count, value: option.value)
                }
            }
        }
        .accessibilityLabel(Text("Filter by \((index.filterLabel ?? index.filterColumn?.label ?? "").lowercased())"))
    }

    private func chip(_ title: String, count: Int, value: String?) -> some View {
        let selected = filter == value
        return Button {
            filter = value
        } label: {
            Text("\(title) \(count)")
                .font(.brand(.footnote, weight: .semibold))
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.xs)
                .foregroundStyle(selected ? theme.onAccent : theme.textPrimary)
                .background(selected ? theme.accent : theme.surface2, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// One document.
struct DocIndexCard: View {
    @Environment(\.theme) private var theme
    let index: DocIndexResult
    let row: DocIndexResult.Row

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(index.title(of: row))
                    .font(.brand(.headline))
                    .foregroundStyle(theme.textPrimary)
                Spacer(minLength: Spacing.sm)
                if index.isFlagged(row) {
                    Image(systemName: "flag.fill")
                        .foregroundStyle(theme.warning)
                        .accessibilityLabel(Text(index.flag?.label ?? "Flagged"))
                }
            }
            badges
            ForEach(fields) { column in
                DocIndexField(index: index, row: row, column: column)
            }
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private var badgeColumns: [DocIndexResult.Column] {
        index.detailColumns.filter { $0.type == .badge && index.cell(row, $0) != nil }
    }

    private var fields: [DocIndexResult.Column] {
        index.detailColumns.filter { $0.type != .badge && index.cell(row, $0) != nil }
    }

    @ViewBuilder
    private var badges: some View {
        if !badgeColumns.isEmpty {
            HStack(spacing: Spacing.xs) {
                ForEach(badgeColumns) { column in
                    if let value = index.cell(row, column) {
                        StatusPill(text: value, tone: DocIndexField.pillTone(index.tone(for: value, in: column)))
                            .accessibilityLabel(Text("\(column.label): \(value)"))
                    }
                }
            }
        }
    }
}

/// One filled column of a document: its label, then its value drawn by type.
struct DocIndexField: View {
    @Environment(\.theme) private var theme
    let index: DocIndexResult
    let row: DocIndexResult.Row
    let column: DocIndexResult.Column

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(column.label.uppercased())
                .font(.brand(size: 10.5, weight: .bold, relativeTo: .caption2))
                .tracking(0.6)
                .foregroundStyle(theme.textTertiary)
            value
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var value: some View {
        if column.type == .tags {
            Text(index.tags(row, column).joined(separator: " · "))
                .font(.brand(.footnote))
                .foregroundStyle(theme.textSecondary)
        } else {
            Text(index.cell(row, column) ?? "—")
                .font(.brand(.subheadline))
                .monospacedDigit()
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    static func pillTone(_ tone: DocIndexResult.Tone) -> StatusPill.Tone {
        switch tone {
        case .danger: return .danger
        case .warn: return .warning
        case .ok: return .success
        case .accent: return .accent
        case .info: return .info
        case .neutral: return .neutral
        }
    }
}
