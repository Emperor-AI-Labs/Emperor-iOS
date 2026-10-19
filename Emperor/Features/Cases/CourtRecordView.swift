import SwiftUI
import UIKit

/// Fetch Orders: a case read from the court's own records, on one page, without adding it.
///
/// The head names the case; four tiles answer the first questions (next hearing, where it
/// stands, the latest order, what the court holds); then the orders with their PDFs, the hearing
/// history, applications, parties and advocates, connected cases and court fees. Nothing is
/// saved until "Add to Matters", which tracks the case and opens its workspace.
///
/// Every sentence on this screen comes from `CourtLookupViewModel`; this lays it out.
struct CourtRecordView: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session
    @Environment(\.navigator) private var navigator
    @Environment(\.dismiss) private var dismiss

    let card: CourtSearchResult
    /// Called with the matter's id once the case has been added and its workspace exists.
    var onAdded: ((String) -> Void)? = nil

    @State private var model: CourtLookupViewModel?
    @State private var toast: String?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    content(model)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Fetch Orders")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if let model {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button {
                                UIPasteboard.general.string = model.summaryText
                                toast = "Summary copied"
                            } label: {
                                Label("Copy summary", systemImage: "doc.on.doc")
                            }
                            Button {
                                dismiss()
                                navigator.ask(model.askPrompt)
                            } label: {
                                Label("Ask about it", systemImage: "text.bubble")
                            }
                        } label: {
                            Label("More", systemImage: "ellipsis.circle")
                        }
                        .disabled(model.record == nil)
                    }
                }
            }
            .task {
                guard model == nil else { return }
                let created = CourtLookupViewModel(
                    card: card, lookup: session.courtLookup,
                    tracker: session.courtSearch, projects: session.projects)
                model = created
                await created.load()
            }
        }
        .recordToast($toast)
    }

    @ViewBuilder
    private func content(_ model: CourtLookupViewModel) -> some View {
        ListStateView(presentation: model.presentation, retry: { await model.load() }) {
            List {
                head(model)
                tiles(model)
                keepIt(model)
                if let record = model.record {
                    orders(record)
                    hearings(record)
                    applications(record)
                    parties(record)
                    connected(record)
                    fees(record)
                }
                Section {
                    Text("Read straight from the court's records just now, and saved nowhere. \(CauseListViewModel.Copy.confirmWithCourt)")
                        .font(.brand(.caption))
                        .foregroundStyle(theme.textTertiary)
                }
                .listRowBackground(Color.clear)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.groupedBackground)
        } empty: {
            EmptyStateView(
                "Nothing came back", systemImage: "building.columns",
                message: "The court returned no details for this case.", tone: .neutral
            ) {
                Button("Try again") { Task { await model.load() } }
                    .buttonStyle(.primaryAction)
            }
        }
        .refreshable { await model.load() }
        .onChange(of: model.notice) { _, notice in
            if let notice { toast = notice }
        }
    }

    // MARK: - Head and tiles

    private func head(_ model: CourtLookupViewModel) -> some View {
        Section {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(model.title)
                    .font(.brand(.title3, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle = model.subtitle {
                    Text(subtitle)
                        .font(.brand(.subheadline))
                        .foregroundStyle(theme.textSecondary)
                }
                ForEach(model.identifiers, id: \.label) { item in
                    HStack {
                        Text(item.label)
                            .font(.brand(.caption))
                            .foregroundStyle(theme.textTertiary)
                        Text(item.value)
                            .font(.brand(.caption))
                            .monospacedDigit()
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.vertical, Spacing.xs)
        }
        .listRowBackground(theme.surface)
    }

    @ViewBuilder
    private func tiles(_ model: CourtLookupViewModel) -> some View {
        if !model.tiles.isEmpty {
            Section {
                ForEach(model.tiles) { tile in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tile.label)
                            .font(.brand(.caption2, weight: .semibold))
                            .foregroundStyle(theme.accentText)
                        Text(tile.value)
                            .font(.brand(.subheadline, weight: .medium))
                        if let detail = tile.detail {
                            Text(detail)
                                .font(.brand(.caption))
                                .foregroundStyle(theme.textSecondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .listRowBackground(theme.surface)
        }
    }

    private func keepIt(_ model: CourtLookupViewModel) -> some View {
        Section {
            if model.isTracked {
                Label(model.matterID == nil ? "On your docket" : "In your matters",
                      systemImage: "checkmark.circle.fill")
                    .font(.brand(.subheadline, weight: .medium))
                    .foregroundStyle(theme.success)
                if let id = model.matterID {
                    Button {
                        dismiss()
                        onAdded?(id)
                    } label: {
                        Label("Open the matter", systemImage: "folder.badge.gearshape")
                    }
                }
            } else {
                Button {
                    Task {
                        if let id = await model.addToMatters(), let onAdded {
                            dismiss()
                            onAdded(id)
                        }
                    }
                } label: {
                    HStack {
                        if model.isAdding { ProgressView().controlSize(.small) }
                        Label("Add to Matters", systemImage: "plus.circle.fill")
                    }
                }
                .disabled(model.isAdding || model.record == nil)
            }
            if let error = model.addError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.brand(.caption))
                    .foregroundStyle(theme.warning)
            }
        } footer: {
            Text("Adding tracks the case on your docket — its hearings refresh every hour and reminders follow — and opens a workspace for it.")
                .font(.brand(.caption2))
                .foregroundStyle(theme.textTertiary)
        }
        .listRowBackground(theme.surface)
    }

    // MARK: - The record

    @ViewBuilder
    private func orders(_ record: CourtRecord) -> some View {
        if !record.orders.isEmpty {
            Section {
                ForEach(record.orders) { order in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(order.displayTitle).font(.brand(.subheadline))
                            if let day = order.date {
                                Text(DisplayText.longDay(day))
                                    .font(.brand(.caption2))
                                    .foregroundStyle(theme.textTertiary)
                            }
                            if order.pdfURL == nil {
                                Text(CourtLookupViewModel.noCopyOnline)
                                    .font(.brand(.caption2))
                                    .foregroundStyle(theme.textTertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: Spacing.sm)
                        if let url = order.pdfURL {
                            Link(destination: url) {
                                Image(systemName: "arrow.up.right.square")
                            }
                            .accessibilityLabel("Open the order")
                        }
                    }
                }
            } header: {
                SectionHeader(title: "Orders and judgments", detail: "\(record.orders.count)")
            } footer: {
                Text("Links open the court's own copy.")
                    .font(.brand(.caption2))
                    .foregroundStyle(theme.textTertiary)
            }
            .listRowBackground(theme.surface)
        }
    }

    @ViewBuilder
    private func hearings(_ record: CourtRecord) -> some View {
        if !record.hearings.isEmpty {
            Section {
                ForEach(record.hearings) { hearing in
                    VStack(alignment: .leading, spacing: 2) {
                        if let day = hearing.date {
                            Text(DisplayText.longDay(day)).font(.brand(.subheadline, weight: .medium))
                        }
                        if let purpose = hearing.purpose, !purpose.isEmpty {
                            Text(purpose).font(.brand(.caption)).foregroundStyle(theme.textSecondary)
                        }
                        if let where_ = hearing.whereLine {
                            Text(where_).font(.brand(.caption2)).foregroundStyle(theme.textTertiary)
                        }
                        if let bench = hearing.bench, !bench.isEmpty {
                            Text(bench).font(.brand(.caption2)).foregroundStyle(theme.textTertiary)
                        }
                        if let remarks = hearing.remarks, !remarks.isEmpty {
                            Text(remarks).font(.brand(.caption2)).foregroundStyle(theme.textTertiary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                SectionHeader(title: "Hearing history", detail: "\(record.hearings.count)")
            }
            .listRowBackground(theme.surface)
        }
    }

    @ViewBuilder
    private func applications(_ record: CourtRecord) -> some View {
        if !record.applications.isEmpty {
            Section {
                ForEach(record.applications) { application in
                    VStack(alignment: .leading, spacing: 2) {
                        Text([application.number, application.particular].compactMap { $0?.nilIfEmpty }.joined(separator: " · "))
                            .font(.brand(.subheadline))
                        HStack(spacing: 6) {
                            if let filed = application.filedOn { Text("Filed \(DisplayText.longDay(filed))") }
                            if let status = application.status, !status.isEmpty {
                                if application.filedOn != nil { SeparatorDot() }
                                Text(status)
                            }
                        }
                        .font(.brand(.caption2))
                        .foregroundStyle(theme.textTertiary)
                        if let remark = application.remark, !remark.isEmpty {
                            Text(remark).font(.brand(.caption2)).foregroundStyle(theme.textTertiary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                SectionHeader(title: "Applications", detail: "\(record.applications.count)")
            }
            .listRowBackground(theme.surface)
        }
    }

    @ViewBuilder
    private func parties(_ record: CourtRecord) -> some View {
        let p = record.parties
        if !(p.petitioners.isEmpty && p.respondents.isEmpty) {
            Section {
                partyLines("Petitioners", p.petitioners, advocates: p.petitionerAdvocates)
                partyLines("Respondents", p.respondents, advocates: p.respondentAdvocates)
            } header: {
                SectionHeader(title: "Parties and advocates")
            }
            .listRowBackground(theme.surface)
        }
    }

    @ViewBuilder
    private func partyLines(_ label: String, _ names: [String], advocates: [String]) -> some View {
        if !names.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.brand(.caption2, weight: .semibold)).foregroundStyle(theme.accentText)
                ForEach(names, id: \.self) { Text($0).font(.brand(.subheadline)) }
                if !advocates.isEmpty {
                    Text("Through \(advocates.joined(separator: ", "))")
                        .font(.brand(.caption))
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private func connected(_ record: CourtRecord) -> some View {
        if !record.connected.isEmpty {
            Section {
                ForEach(record.connected) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.caseNo ?? item.cnr ?? "Connected case").font(.brand(.subheadline))
                        if let court = item.court, !court.isEmpty {
                            Text(court).font(.brand(.caption)).foregroundStyle(theme.textSecondary)
                        }
                    }
                }
            } header: {
                SectionHeader(title: "Connected cases", detail: "\(record.connected.count)")
            }
            .listRowBackground(theme.surface)
        }
    }

    @ViewBuilder
    private func fees(_ record: CourtRecord) -> some View {
        if !record.courtFees.isEmpty {
            Section {
                ForEach(record.courtFees) { fee in
                    ValueRow(fee.head ?? "Court fee", value: fee.amount.map(MatterMoney.inr) ?? "—")
                }
            } header: {
                SectionHeader(title: "Court fees")
            }
            .listRowBackground(theme.surface)
        }
    }
}
