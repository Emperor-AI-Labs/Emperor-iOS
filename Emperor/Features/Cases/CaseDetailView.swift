import SwiftUI

/// One matter. Overview, hearings and orders first; everything else as reference.
///
/// Read-mostly by design. The only two writes offered are a note and a task — the two things
/// that make sense standing up outside a courtroom. Everything else the web workspace can do
/// is a desk job, and a wrong entry here is harder to notice than one made at a screen.
struct CaseDetailView: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session

    let caseID: String

    @State private var model: CaseDetailViewModel?
    @State private var isAddingNote = false
    @State private var isAddingTask = false

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(model?.legalCase?.displayTitle ?? "Matter")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard model == nil else { return }
            let created = CaseDetailViewModel(caseID: caseID, service: session.cases)
            model = created
            await created.load()
        }
    }

    @ViewBuilder
    private func content(_ model: CaseDetailViewModel) -> some View {
        @Bindable var bindable = model

        ListStateView(presentation: model.presentation, retry: { await model.load() }) {
            List {
                if let legalCase = model.legalCase {
                    overview(legalCase, model)
                }
                hearings(model)
                orders(model)
                tasks(model)
                timeline(model)
                other(model)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.canvas)
        } empty: {
            ContentUnavailableView("Matter unavailable", systemImage: "questionmark.folder")
        }
        .refreshable { await model.load() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        isAddingNote = true
                    } label: {
                        Label("Add a note", systemImage: "square.and.pencil")
                    }
                    Button {
                        isAddingTask = true
                    } label: {
                        Label("Add a task", systemImage: "checkmark.circle")
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .disabled(model.legalCase == nil)
            }
        }
        .sheet(isPresented: $isAddingNote) {
            CaseWriteSheet(kind: .note) { title, body, _ in
                await model.addNote(title: title, body: body)
            }
        }
        .sheet(isPresented: $isAddingTask) {
            CaseWriteSheet(kind: .task) { title, _, dueDate in
                await model.addTask(title: title ?? "", dueDate: dueDate)
            }
        }
        .sheet(item: $bindable.openDocument) { document in
            OrderDocumentView(document: document)
        }
        .alert("Could not save", isPresented: Binding(
            get: { model.writeError != nil },
            set: { if !$0 { model.writeError = nil } }
        )) {
            Button("OK") { model.writeError = nil }
        } message: {
            Text(model.writeError ?? "")
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func overview(_ legalCase: LegalCase, _ model: CaseDetailViewModel) -> some View {
        Section("Overview") {
            if let reference = legalCase.caseReference {
                LabeledContent("Case", value: reference)
            }
            if let court = legalCase.courtName {
                LabeledContent("Court", value: court)
            }
            if let judge = legalCase.judge {
                LabeledContent("Bench", value: judge)
            }
            if let status = legalCase.status {
                LabeledContent("Status", value: status)
            }
            if let stage = legalCase.stage {
                LabeledContent("Stage", value: stage)
            }
            if let hearing = legalCase.nextHearingDate {
                LabeledContent(
                    "Next hearing",
                    value: DisplayText.longDay(WireDate.dayKey(hearing)))
            }
            if let filed = legalCase.filingDate {
                LabeledContent("Filed", value: DisplayText.longDay(WireDate.dayKey(filed)))
            }

            // Said plainly, because it decides whether the dates above are worth trusting.
            Text(model.syncDescription)
                .font(.brand(.caption))
                .foregroundStyle(model.isCourtSynced ? theme.textSecondary : theme.warning)
        }
    }

    @ViewBuilder
    private func hearings(_ model: CaseDetailViewModel) -> some View {
        if !model.hearings.isEmpty {
            Section("Hearings") {
                ForEach(model.hearings) { item in
                    itemRow(item, model)
                }
            }
        }
    }

    @ViewBuilder
    private func orders(_ model: CaseDetailViewModel) -> some View {
        if !model.orders.isEmpty {
            Section("Orders") {
                ForEach(model.orders) { item in
                    Button {
                        Task { await model.openOrder(item) }
                    } label: {
                        HStack {
                            itemRow(item, model)
                            Spacer(minLength: 0)
                            if model.isWriting {
                                ProgressView()
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    // Fetching an order is a live call to a court portal and can take seconds.
                    .disabled(model.isWriting)
                }
            }
        }
    }

    @ViewBuilder
    private func tasks(_ model: CaseDetailViewModel) -> some View {
        if !model.tasks.isEmpty {
            Section("Tasks") {
                ForEach(model.tasks) { item in
                    itemRow(item, model)
                }
            }
        }
    }

    @ViewBuilder
    private func timeline(_ model: CaseDetailViewModel) -> some View {
        if !model.timeline.isEmpty {
            Section("Notes") {
                ForEach(model.timeline) { event in
                    VStack(alignment: .leading, spacing: 3) {
                        if let title = event.title, !title.isEmpty {
                            Text(title).font(.brand(.subheadline, weight: .semibold))
                        }
                        if let body = event.body, !body.isEmpty {
                            Text(body).font(.brand(.subheadline))
                        }
                        if let date = event.eventDate {
                            Text(DisplayText.relative(date))
                                .font(.brand(.caption2))
                                .foregroundStyle(theme.textTertiary)
                        }
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    /// Sections this build does not know about. Shown rather than dropped: `section` is an open
    /// string server-side, so a new one can appear at any time and swallowing it would hide
    /// real case data.
    @ViewBuilder
    private func other(_ model: CaseDetailViewModel) -> some View {
        ForEach(model.otherSections, id: \.section) { group in
            Section(DisplayText.fileName(group.section).capitalized) {
                ForEach(group.items) { item in
                    itemRow(item, model)
                }
            }
        }
    }

    private func itemRow(_ item: CaseItem, _ model: CaseDetailViewModel) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(item.title ?? "—")
                    .font(.brand(.subheadline))
                    .lineLimit(2)
                if item.isCourtOwned {
                    Image(systemName: "building.columns")
                        .font(.brand(.caption2))
                        .foregroundStyle(theme.accentText)
                        .accessibilityLabel("From court")
                }
            }
            if let subtitle = item.subtitle, !subtitle.isEmpty {
                Text(subtitle).font(.brand(.caption)).foregroundStyle(theme.textSecondary)
            }
            if let date = item.itemDate {
                Text(DisplayText.longDay(WireDate.dayKey(date)))
                    .font(.brand(.caption2))
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// A cited or fetched order PDF.
private struct OrderDocumentView: View {
    let document: CaseDetailViewModel.OpenDocument
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PDFDataView(data: document.data)
                .navigationTitle(document.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        if let url = ShareableFile.url(
                            for: document.data, named: "\(document.title).pdf") {
                            ShareLink(item: url) {
                                Image(systemName: "square.and.arrow.up")
                            }
                        }
                    }
                }
        }
    }
}
