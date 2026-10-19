import SwiftUI
import UIKit

/// Fetch Orders: a case read from the court's own records, on one page, without adding it —
/// the web's `lookup/Dossier.jsx`.
///
/// The head names the case (court, number, a copy-able CNR, whether it is still going) with the
/// one button that matters; four tiles answer the first questions (next hearing, where it stands,
/// the latest order, what the court holds), each with a (?) that explains it in a line; then the
/// orders with their PDFs (filtered by year), the hearing history, applications, parties and
/// advocates, the timeline, connected cases and court fees, and a closing offer. Nothing is saved
/// until "Add to Matters", which asks the matter's name and the reader's side, tracks the case and
/// opens its workspace. A case already in Matters offers "Open in Matters" instead.
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
    @State private var adding = false

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
                    tracker: session.courtSearch, projects: session.projects,
                    cases: session.cases, recent: RecentLookups(store: Preferences()))
                model = created
                await created.load()
            }
            .sheet(isPresented: $adding) {
                if let model, let draft = model.addDraft {
                    AddToMattersSheet(model: model, draft: draft) { id in
                        adding = false
                        if let id, let onAdded {
                            dismiss()
                            onAdded(id)
                        }
                    }
                }
            }
        }
        .recordToast($toast)
    }

    @ViewBuilder
    private func content(_ model: CourtLookupViewModel) -> some View {
        ListStateView(presentation: model.presentation, retry: { await model.load() }) {
            List {
                CourtRecordHead(model: model, onKeep: { keep(model) })
                CourtRecordTiles(model: model)
                if let record = model.record {
                    CourtRecordOrders(model: model, record: record)
                    CourtRecordHearings(model: model, record: record)
                    CourtRecordApplications(record: record)
                    CourtRecordParties(model: model)
                    CourtRecordTimeline(model: model)
                    CourtRecordExtras(record: record)
                }
                CourtRecordKeepBand(model: model, onKeep: { keep(model) })
                Section {
                    Text("\(model.provenanceLine). \(CauseListViewModel.Copy.confirmWithCourt)")
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

    /// The one button: open the matter when there is one, else ask the two questions and add.
    private func keep(_ model: CourtLookupViewModel) {
        if let id = model.matterID {
            dismiss()
            onAdded?(id)
        } else {
            adding = true
        }
    }
}

// MARK: - The head

private struct CourtRecordHead: View {
    @Environment(\.theme) private var theme
    let model: CourtLookupViewModel
    let onKeep: () -> Void
    @State private var copied = false

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(spacing: Spacing.xs) {
                    if let court = model.record?.case.courtName?.nilIfEmpty ?? model.card.courtName {
                        StatusPill(text: court, systemImage: "building.columns")
                    }
                    if let number = model.record.map({ LookupModel.caseNumber(of: $0.case) })?.nilIfEmpty ?? model.card.reference {
                        StatusPill(text: number)
                    }
                    Spacer(minLength: 0)
                    StatusPill(text: model.statusWord, tone: model.isDisposed ? .neutral : .success)
                }
                Text(model.tidyTitle)
                    .font(.display(size: 24, relativeTo: .title2))
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle = model.subtitle {
                    Text(subtitle)
                        .font(.brand(.subheadline))
                        .foregroundStyle(theme.textSecondary)
                }
                ForEach(model.identifiers, id: \.label) { item in
                    identifierRow(item.label, item.value)
                }
                HStack(spacing: Spacing.sm) {
                    Button(action: onKeep) {
                        HStack(spacing: 6) {
                            if model.isAdding { ProgressView().controlSize(.small) }
                            Image(systemName: model.matterID == nil ? "folder.badge.plus" : "folder")
                            Text(model.keepLabel)
                        }
                    }
                    .buttonStyle(.compactPrimaryAction)
                    .disabled(model.isAdding || model.record == nil)
                    if model.isTracked, model.matterID == nil {
                        Label("On your docket", systemImage: "checkmark.circle.fill")
                            .font(.brand(.caption, weight: .medium))
                            .foregroundStyle(theme.success)
                    }
                }
                .padding(.top, Spacing.xs)
                if let error = model.addError {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.brand(.caption))
                        .foregroundStyle(theme.warning)
                }
            }
            .padding(.vertical, Spacing.xs)
        }
        .listRowBackground(theme.surface)
    }

    private func identifierRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: Spacing.sm) {
            Text(label)
                .font(.brand(.caption))
                .foregroundStyle(theme.textTertiary)
            Text(value)
                .font(.brand(.caption, weight: .medium))
                .monospacedDigit()
                .textSelection(.enabled)
            if label == "CNR" || label == "Diary no." {
                Button {
                    UIPasteboard.general.string = value
                    copied = true
                    Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").imageScale(.small)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Copy \(label)")
            }
        }
    }
}

// MARK: - The four tiles

private struct CourtRecordTiles: View {
    @Environment(\.theme) private var theme
    let model: CourtLookupViewModel

    var body: some View {
        if !model.tiles.isEmpty {
            Section {
                ForEach(model.tiles) { tile in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(tile.label)
                                .font(.brand(.caption2, weight: .semibold))
                                .foregroundStyle(theme.accentText)
                            if let hint = tile.hint { HintButton(label: tile.label, text: hint) }
                        }
                        Text(tile.value)
                            .font(.brand(.subheadline, weight: .medium))
                        if let detail = tile.detail {
                            Text(detail)
                                .font(.brand(.caption))
                                .foregroundStyle(theme.textSecondary)
                        }
                        if tile.label == "Where it stands", let since = model.sinceLine {
                            Text(since).font(.brand(.caption)).foregroundStyle(theme.textSecondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .listRowBackground(theme.surface)
        }
    }
}

/// The (?) beside a heading: what it means, in a line.
private struct HintButton: View {
    @Environment(\.theme) private var theme
    let label: String
    let text: String
    @State private var open = false

    var body: some View {
        Button {
            open.toggle()
        } label: {
            Text("?")
                .font(.brand(size: 10, weight: .bold, relativeTo: .caption2))
                .foregroundStyle(theme.textTertiary)
                .frame(width: 16, height: 16)
                .overlay(Circle().strokeBorder(theme.borderStrong, lineWidth: 1))
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("What is \(label)?")
        .popover(isPresented: $open) {
            Text(text)
                .font(.brand(.footnote))
                .foregroundStyle(theme.textSecondary)
                .padding(Spacing.md)
                .frame(maxWidth: 280)
                .presentationCompactAdaptation(.popover)
        }
    }
}

// MARK: - Orders

private struct CourtRecordOrders: View {
    @Environment(\.theme) private var theme
    let model: CourtLookupViewModel
    let record: CourtRecord
    @State private var showsAll = false

    var body: some View {
        @Bindable var model = model
        let orders = model.filteredOrders
        let shown = showsAll ? orders : Array(orders.prefix(8))
        Section {
            if model.orderYears.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.xs) {
                        LibraryChip(title: "All", isSelected: model.orderYear.isEmpty) { model.orderYear = "" }
                        ForEach(model.orderYears, id: \.self) { year in
                            LibraryChip(title: year, isSelected: model.orderYear == year) { model.orderYear = year }
                        }
                    }
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .accessibilityLabel("Filter by year")
            }
            if record.orders.isEmpty {
                Text("The court has not published any order for this case yet. Add it to Matters and we will tell you the moment one appears.")
                    .font(.brand(.footnote))
                    .foregroundStyle(theme.textSecondary)
            }
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, order in
                orderRow(order, latest: index == 0 && model.orderYear.isEmpty)
            }
            if orders.count > 8 {
                Button(showsAll ? "Show fewer" : "Show all \(orders.count)") { showsAll.toggle() }
                    .font(.brand(.footnote, weight: .semibold))
            }
        } header: {
            HStack(spacing: 4) {
                SectionHeader(title: "Orders and judgments", detail: "\(record.orders.count)")
                HintButton(label: "Orders and judgments", text: CourtLookupViewModel.Hints.orders)
            }
        } footer: {
            Text("Links open the court's own copy.")
                .font(.brand(.caption2))
                .foregroundStyle(theme.textTertiary)
        }
        .listRowBackground(theme.surface)
    }

    private func orderRow(_ order: CourtRecord.Order, latest: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(order.displayTitle).font(.brand(.subheadline, weight: .medium))
                    if latest { StatusPill(text: "Latest", tone: .accent) }
                }
                if let line = model.orderLine(order) {
                    Text(line).font(.brand(.caption2)).foregroundStyle(theme.textTertiary)
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
                    Label("Read", systemImage: "arrow.up.right.square")
                        .font(.brand(.caption, weight: .semibold))
                }
                .accessibilityLabel("Read the order\(order.date.map { " of \(DisplayText.longDay($0))" } ?? "")")
            }
        }
    }
}

// MARK: - Hearings

private struct CourtRecordHearings: View {
    @Environment(\.theme) private var theme
    let model: CourtLookupViewModel
    let record: CourtRecord
    @State private var showsAll = false

    var body: some View {
        if !record.hearings.isEmpty {
            let shown = showsAll ? record.hearings : Array(record.hearings.prefix(8))
            Section {
                ForEach(shown) { hearing in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            if let day = hearing.date {
                                Text(DisplayText.longDay(day)).font(.brand(.subheadline, weight: .medium))
                            }
                            if model.isUpcoming(hearing) { StatusPill(text: "Upcoming", tone: .accent) }
                        }
                        Text(model.hearingWhat(hearing)).font(.brand(.caption)).foregroundStyle(theme.textSecondary)
                        Text(model.hearingWhere(hearing)).font(.brand(.caption2)).foregroundStyle(theme.textTertiary)
                        if let remarks = hearing.remarks?.nilIfEmpty {
                            Text(remarks).font(.brand(.caption2)).foregroundStyle(theme.textTertiary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                if record.hearings.count > 8 {
                    Button(showsAll ? "Show fewer" : "Show all \(record.hearings.count)") { showsAll.toggle() }
                        .font(.brand(.footnote, weight: .semibold))
                }
            } header: {
                HStack(spacing: 4) {
                    SectionHeader(title: "Hearing history", detail: "\(record.hearings.count)")
                    HintButton(label: "Hearing history", text: CourtLookupViewModel.Hints.hearings)
                }
            }
            .listRowBackground(theme.surface)
        }
    }
}

private struct CourtRecordApplications: View {
    @Environment(\.theme) private var theme
    let record: CourtRecord

    var body: some View {
        if !record.applications.isEmpty {
            Section {
                ForEach(record.applications) { application in
                    VStack(alignment: .leading, spacing: 2) {
                        Text([application.number, LookupModel.plainCourtText(application.particular).nilIfEmpty ?? "Application"].compactMap { $0?.nilIfEmpty }.joined(separator: " · "))
                            .font(.brand(.subheadline))
                        HStack(spacing: 6) {
                            if let filed = application.filedOn { Text("Filed \(DisplayText.longDay(filed))") }
                            if let status = application.status?.nilIfEmpty {
                                if application.filedOn != nil { SeparatorDot() }
                                Text(status)
                            }
                        }
                        .font(.brand(.caption2))
                        .foregroundStyle(theme.textTertiary)
                        if let remark = application.remark?.nilIfEmpty {
                            Text(remark).font(.brand(.caption2)).foregroundStyle(theme.textTertiary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                HStack(spacing: 4) {
                    SectionHeader(title: "Applications", detail: "\(record.applications.count)")
                    HintButton(label: "Applications", text: CourtLookupViewModel.Hints.applications)
                }
            }
            .listRowBackground(theme.surface)
        }
    }
}

// MARK: - Parties, timeline, extras

private struct CourtRecordParties: View {
    @Environment(\.theme) private var theme
    let model: CourtLookupViewModel

    var body: some View {
        if let sides = model.sides, !(sides.first.names.isEmpty && sides.second.names.isEmpty) {
            Section {
                side("Petitioner / plaintiff side", sides.first)
                side("Respondent / defendant side", sides.second)
            } header: {
                HStack(spacing: 4) {
                    SectionHeader(title: "Parties and advocates")
                    HintButton(label: "Parties and advocates", text: CourtLookupViewModel.Hints.parties)
                }
            }
            .listRowBackground(theme.surface)
        }
    }

    private func side(_ label: String, _ side: LookupModel.Side) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.brand(.caption2, weight: .semibold)).foregroundStyle(theme.accentText)
            if side.names.isEmpty {
                Text("Not listed").font(.brand(.footnote)).foregroundStyle(theme.textTertiary)
            }
            ForEach(side.names.prefix(6), id: \.self) { Text($0).font(.brand(.subheadline)) }
            if side.names.count > 6 {
                Text("and \(side.names.count - 6) more").font(.brand(.caption2)).foregroundStyle(theme.textTertiary)
            }
            if !side.counsel.isEmpty {
                Text("Advocate\(side.counsel.count > 1 ? "s" : ""): \(side.counsel.joined(separator: ", "))")
                    .font(.brand(.caption))
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct CourtRecordTimeline: View {
    @Environment(\.theme) private var theme
    let model: CourtLookupViewModel

    var body: some View {
        let rows = model.timeline
        if !rows.isEmpty {
            Section {
                ForEach(rows) { row in
                    HStack(alignment: .top, spacing: Spacing.md) {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(LibraryTitles.shortDay(row.day))
                                .font(.brand(.caption, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(row.kind == .next ? theme.accentText : theme.textPrimary)
                            Text(row.kind == .next ? "Upcoming" : row.kind == .order ? "Order" : "Hearing")
                                .font(.brand(.caption2))
                                .foregroundStyle(theme.textTertiary)
                        }
                        .frame(width: 92, alignment: .trailing)
                        Image(systemName: row.kind == .next ? "calendar.badge.clock" : row.kind == .order ? "doc.text" : "person.3")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(row.kind == .next ? theme.onAccent : theme.accentText)
                            .frame(width: 22, height: 22)
                            .background(row.kind == .next ? theme.accent : theme.accentSoft, in: Circle())
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.title).font(.brand(.footnote, weight: row.kind == .order ? .semibold : .regular))
                            if !row.subtitle.isEmpty {
                                Text(row.subtitle).font(.brand(.caption2)).foregroundStyle(theme.textTertiary)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                HStack(spacing: 4) {
                    SectionHeader(title: "Timeline", detail: "\(rows.count)")
                    HintButton(label: "Timeline", text: CourtLookupViewModel.Hints.timeline)
                }
            }
            .listRowBackground(theme.surface)
        }
    }
}

private struct CourtRecordExtras: View {
    @Environment(\.theme) private var theme
    let record: CourtRecord

    var body: some View {
        if !record.connected.isEmpty || !record.courtFees.isEmpty {
            Section {
                ForEach(record.connected) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.caseNo ?? item.cnr ?? "Connected case").font(.brand(.subheadline))
                        Text([item.court?.nilIfEmpty, item.orderDate.map { "order \(LibraryTitles.shortDay($0))" }].compactMap { $0 }.joined(separator: " · "))
                            .font(.brand(.caption)).foregroundStyle(theme.textSecondary)
                    }
                }
                ForEach(record.courtFees) { fee in
                    ValueRow(fee.head ?? "Court fee", value: fee.amount.map(MatterMoney.inr) ?? "—")
                }
            } header: {
                HStack(spacing: 4) {
                    SectionHeader(title: "Also on the record")
                    HintButton(label: "Also on the record", text: CourtLookupViewModel.Hints.extras)
                }
            }
            .listRowBackground(theme.surface)
        }
    }
}

/// The closing offer: the same button as the head, with what adding gives you.
private struct CourtRecordKeepBand: View {
    @Environment(\.theme) private var theme
    let model: CourtLookupViewModel
    let onKeep: () -> Void

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text(model.keepTitle)
                    .font(.display(size: 18, relativeTo: .headline))
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(CourtLookupViewModel.keepPromises, id: \.self) { promise in
                    Label(promise, systemImage: "checkmark")
                        .font(.brand(.footnote))
                        .foregroundStyle(theme.textSecondary)
                }
                Button(action: onKeep) {
                    HStack {
                        Spacer()
                        Text(model.keepLabel)
                        Spacer()
                    }
                }
                .buttonStyle(.primaryAction)
                .disabled(model.isAdding || model.record == nil)
                .padding(.top, Spacing.xs)
            }
            .padding(.vertical, Spacing.xs)
        }
        .listRowBackground(theme.surface)
    }
}

// MARK: - Add to Matters

/// The last step of a lookup: what to call the matter, and which side the user is on. Confirm
/// tracks the case, makes its matter, writes the side, and hands back the matter's id.
private struct AddToMattersSheet: View {
    @Environment(\.theme) private var theme
    let model: CourtLookupViewModel
    @State var draft: AddToMattersDraft
    let onDone: (String?) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Matter name", text: $draft.name)
                        .font(.brand(.body))
                } header: {
                    SectionHeader(title: "Matter name")
                }
                .listRowBackground(theme.surface)

                Section {
                    sideRow(.first)
                    sideRow(.second)
                    sideRow(.none)
                } header: {
                    SectionHeader(title: "Which side are you on?")
                }
                .listRowBackground(theme.surface)

                Section {
                    ForEach(AddToMattersDraft.promises, id: \.self) { promise in
                        Label(promise, systemImage: "checkmark.circle")
                            .font(.brand(.footnote))
                            .foregroundStyle(theme.textSecondary)
                    }
                    if let error = model.addError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.brand(.footnote))
                            .foregroundStyle(theme.danger)
                    }
                }
                .listRowBackground(theme.surface)

                Section {
                    Button {
                        Task {
                            let id = await model.addToMatters(draft: draft)
                            if model.addError == nil { onDone(id) }
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if model.isAdding { ProgressView().controlSize(.small) }
                            Text(model.isAdding ? "Adding…" : "Add to Matters")
                            Spacer()
                        }
                    }
                    .buttonStyle(.primaryAction)
                    .disabled(!draft.canSubmit || model.isAdding)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
            .font(.brand(.body))
            .scrollContentBackground(.hidden)
            .background(theme.groupedBackground)
            .navigationTitle("Add to Matters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDone(nil) }.disabled(model.isAdding)
                }
            }
        }
    }

    private func sideRow(_ choice: AddToMattersDraft.SideChoice) -> some View {
        Button {
            draft.side = choice
        } label: {
            HStack(spacing: Spacing.sm) {
                RadioMark(isOn: draft.side == choice)
                VStack(alignment: .leading, spacing: 1) {
                    Text(draft.sideTitle(choice))
                        .font(.brand(.subheadline, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                    if let detail = draft.sideDetail(choice) {
                        Text(detail)
                            .font(.brand(.caption))
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(draft.side == choice ? [.isSelected] : [])
    }
}
