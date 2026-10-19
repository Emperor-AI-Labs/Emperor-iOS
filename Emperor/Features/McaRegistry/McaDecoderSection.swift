import SwiftUI

/// "Decode a CIN": the field, and what the number says as it is typed. Works offline — the
/// decode is arithmetic on the string; only the "on record here" line asks the server.
struct McaDecoderSection: View {
    @Environment(\.theme) private var theme
    @Bindable var model: McaRegistryViewModel

    var body: some View {
        Section {
            TextField("U16001AP2005PLC048552", text: $model.cinInput)
                .font(.system(.body, design: .monospaced))
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .accessibilityLabel("Corporate Identity Number")
            if model.showsDecode {
                McaDecodeResult(result: model.decoded)
                if model.canLookUpRecords {
                    McaRecordLookupRow(lookup: model.recordLookup)
                }
            }
        } header: {
            SectionHeader(title: "Decode a CIN")
        } footer: {
            Text("Every one of the 21 characters carries meaning, so any CIN ever allotted decodes here — the company does not need to be on record with us, and nothing leaves your phone.")
                .font(.brand(.caption))
                .foregroundStyle(theme.textTertiary)
        }
        .listRowBackground(theme.surface)
        // Debounced, so the records are asked about a finished CIN rather than every keystroke.
        .task(id: model.cinInput) {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await model.lookUpRecords()
        }
    }
}

/// What a CIN says, or why it says nothing.
struct McaDecodeResult: View {
    @Environment(\.theme) private var theme
    let result: CinResult

    var body: some View {
        if result.kind == .llpin || result.kind == .fcrn {
            McaNote(title: result.summary, text: result.reason ?? "", tone: theme.warning)
        } else if result.isIncomplete {
            Text("\(result.charactersRemaining) more character\(result.charactersRemaining == 1 ? "" : "s") to go.")
                .font(.brand(.footnote))
                .foregroundStyle(theme.textTertiary)
        } else if !result.shapeValid {
            McaNote(title: "Not a valid CIN", text: result.reason ?? "", tone: theme.danger)
        } else if let fields = result.fields {
            decoded(fields)
        }
    }

    @ViewBuilder
    private func decoded(_ fields: CinFields) -> some View {
        HStack(spacing: Spacing.sm) {
            StatusPill(
                text: result.confident ? "Well-formed CIN" : "Well-formed, but partly unreadable",
                tone: result.confident ? .success : .warning,
                systemImage: result.confident ? "checkmark.circle" : "exclamationmark.circle")
        }
        Text(result.summary)
            .font(.brand(.subheadline))
            .foregroundStyle(theme.textPrimary)
        ForEach(McaFieldRow.rows(for: fields)) { row in
            McaFieldRowView(row: row)
        }
        if !result.anomalies.isEmpty {
            McaNote(
                title: "Part of this CIN could not be read",
                text: result.anomalies.map { "• \($0)" }.joined(separator: "\n"),
                tone: theme.warning)
        }
        McaNote(title: "What this check does and does not prove", text: result.verificationNote,
                tone: theme.textSecondary)
    }
}

/// One decoded field.
struct McaFieldRowView: View {
    @Environment(\.theme) private var theme
    let row: McaFieldRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(row.label.uppercased())
                    .font(.brand(.caption2, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
                if let code = row.code {
                    Text(code)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(theme.textTertiary)
                }
            }
            Text(row.value)
                .font(.brand(.subheadline))
                .foregroundStyle(row.known ? theme.textPrimary : theme.danger)
            if let hint = row.hint {
                Text(hint)
                    .font(.brand(.caption))
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A titled note in a tone.
struct McaNote: View {
    @Environment(\.theme) private var theme
    let title: String
    let text: String
    let tone: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.brand(.subheadline, weight: .semibold))
                .foregroundStyle(tone)
            if !text.isEmpty {
                Text(text)
                    .font(.brand(.footnote))
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Whether the notice records name the decoded CIN. A miss is not an error: it says only that
/// no liquidation notice names the company.
private struct McaRecordLookupRow: View {
    @Environment(\.theme) private var theme
    let lookup: McaRecordLookup

    var body: some View {
        switch lookup {
        case .idle:
            EmptyView()
        case .loading:
            HStack(spacing: Spacing.sm) {
                ProgressView()
                Text("Checking our liquidation records…")
                    .font(.brand(.footnote))
                    .foregroundStyle(theme.textSecondary)
            }
        case .found(let company, let total):
            NavigationLink(value: McaCompanyRoute(company: company, total: total)) {
                Label("On record: \(company.name) — \(McaRegistry.count(total)) liquidation notice\(total == 1 ? "" : "s").",
                      systemImage: "hammer")
                    .font(.brand(.subheadline))
            }
        case .absent:
            McaNote(
                title: "Not among the companies on record here",
                text: "No IBBI liquidation auction notice held here names this CIN. That says nothing about whether the company exists or is solvent — this product only holds companies whose liquidator has published an auction notice. The decode above stands on its own.",
                tone: theme.textSecondary)
        case .failed:
            McaNote(
                title: "Could not check our records",
                text: "The notice records did not respond. The decode above is unaffected — it never needed them.",
                tone: theme.textSecondary)
        }
    }
}
