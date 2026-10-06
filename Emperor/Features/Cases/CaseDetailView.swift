import SwiftUI

/// One matter: the overview, then every section behind a tab.
///
/// The overview is what identifies the matter, so it stays put. Everything below it is read one
/// section at a time — you open a case to check the next date or to find an order, not to scroll
/// past four sections to reach the fifth — so the rest is a strip of tabs and one list.
///
/// Read-mostly by design. The only two writes offered are a note and a task — the two things
/// that make sense standing up outside a courtroom. Everything else the web workspace can do
/// is a desk job, and a wrong entry here is harder to notice than one made at a screen.
///
/// The Calendar opens a listed case here, on the Cases tab, asking for its overview. The overview
/// is not a tab but the head of the screen, so a fresh screen shows it with nothing to select;
/// `CaseRoute.request` is what makes the screen a fresh one even when the same case was already
/// open and scrolled down to its orders.
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
                if !model.tabs.isEmpty {
                    Section {
                        tabStrip(model)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                    selectedTabContent(model)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.canvas)
        } empty: {
            EmptyStateView("Matter unavailable", systemImage: "questionmark.folder", tone: .neutral)
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
            // A page on iPad: an order is a page to read, and a form sheet shrank it to a panel.
            OrderDocumentView(document: document)
                .pageSizedSheet()
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
        Section {
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
            Label {
                Text(model.syncDescription)
            } icon: {
                Image(systemName: model.isCourtSynced ? "building.columns" : "exclamationmark.triangle")
            }
            .font(.brand(.caption))
            .foregroundStyle(model.isCourtSynced ? theme.textSecondary : theme.warning)
        } header: {
            // A plain heading rather than `Section("Overview")`, which iOS draws in its own
            // capitals and face; the words are unchanged, and the Calendar's UI test finds them.
            SectionHeader(title: "Overview")
        }
        .listRowBackground(theme.surface)
    }

    /// The tab strip: one row, scrolling horizontally, as the library's category bar does.
    ///
    /// Not a segmented control. A matter can carry ten sections — and `section` is open
    /// server-side, so it can carry ones this build has no name for — and segments would be
    /// illegible well before that. The count rides in the chip because the reason to open
    /// Applications rather than Orders is usually that one of them has something in it.
    private func tabStrip(_ model: CaseDetailViewModel) -> some View {
        // Resolved once. `selectedTab` rebuilds `tabs` to answer, so asking inside the loop
        // would rebuild it per chip.
        let selectedID = model.selectedTab?.id
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.tabs) { tab in
                    let isSelected = selectedID == tab.id
                    Button {
                        model.selectedTabID = tab.id
                    } label: {
                        ChipLabel(title: tab.label, count: tab.count, isSelected: isSelected)
                    }
                    .buttonStyle(ChipButtonStyle(isSelected: isSelected))
                    .accessibilityLabel("\(tab.label), \(tab.count)")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.sm + 2)
        }
    }

    /// The chosen tab's rows. No header: the highlighted chip directly above is the heading, and
    /// repeating it would cost a line on a screen whose whole point is getting to the rows.
    @ViewBuilder
    private func selectedTabContent(_ model: CaseDetailViewModel) -> some View {
        if let tab = model.selectedTab {
            Section {
                switch tab.content {
                case .items(let items):
                    ForEach(items) { item in
                        if tab.id == CaseSection.orders.rawValue {
                            orderRow(item, model)
                        } else {
                            itemRow(item, model)
                        }
                    }
                case .notes(let events):
                    ForEach(events) { event in
                        noteRow(event)
                    }
                }
            }
            .listRowBackground(theme.surface)
        }
    }

    private func orderRow(_ item: CaseItem, _ model: CaseDetailViewModel) -> some View {
        Button {
            Task { await model.openOrder(item) }
        } label: {
            HStack(spacing: Spacing.md) {
                itemRow(item, model)
                Spacer(minLength: 0)
                if model.isWriting {
                    ProgressView()
                } else {
                    // An order opens a document, so it says so where the eye ends the row.
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.brand(.subheadline))
                        .foregroundStyle(theme.accentText)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Fetching an order is a live call to a court portal and can take seconds.
        .disabled(model.isWriting)
    }

    private func noteRow(_ event: CaseEvent) -> some View {
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
                            .accessibilityLabel("Share")
                        }
                    }
                }
        }
    }
}
