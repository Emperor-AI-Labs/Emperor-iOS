import SwiftUI

/// Hearings and obligations together.
///
/// ## Two things this screen deliberately does not offer
///
/// **No reminder picker.** `remind_days` is written, returned and rendered by the web client —
/// and read by nothing. There is no scheduler, the `reminder` notification type has no
/// producer, and the ICS feed emits no `VALARM`. On the one screen whose purpose is not missing
/// a limitation date, a reminder control would be the worst possible place to make a promise
/// the product cannot keep.
///
/// **No calendar-subscription link.** A subscription URL is a standing credential for every
/// hearing the user has, so it is withheld until it can be issued as a rotatable token.
struct CalendarView: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session

    @State private var model: CalendarViewModel?
    @State private var isAddingEvent = false
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let model {
                    content(model)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Calendar")
            .navigationDestination(for: String.self) { caseID in
                CaseDetailView(caseID: caseID)
            }
            .task {
                guard model == nil else { return }
                let created = CalendarViewModel(
                    calendar: session.calendar,
                    caseService: session.cases,
                    cache: session.cache)
                model = created
                await created.load()
            }
        }
    }

    @ViewBuilder
    private func content(_ model: CalendarViewModel) -> some View {
        ListStateView(presentation: model.presentation, retry: { await model.load() }) {
            List {
                if !model.overdue.isEmpty {
                    Section {
                        ForEach(model.overdue) { event in
                            eventRow(event, model)
                        }
                    } header: {
                        SectionHeader(
                            title: "Past due", detail: "\(model.overdue.count) open")
                    }
                }

                ForEach(model.upcoming()) { day in
                    Section(DisplayText.longDay(day.key)) {
                        ForEach(day.hearings) { legalCase in
                            NavigationLink(value: legalCase.id) {
                                hearingRow(legalCase)
                            }
                        }
                        ForEach(day.events) { event in
                            eventRow(event, model)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.canvas)
            .refreshable { await model.load() }
        } empty: {
            ContentUnavailableView(
                "Nothing scheduled",
                systemImage: "calendar",
                description: Text("Hearings on your matters, and anything you add here, appear together."))
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isAddingEvent = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $isAddingEvent) {
            ComplianceEventSheet(day: model.selectedDay) { draft in
                await model.save(draft)
            }
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

    private func hearingRow(_ legalCase: LegalCase) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "building.columns")
                .foregroundStyle(theme.accentText)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(legalCase.displayTitle).font(.brand(.subheadline)).lineLimit(2)
                if let court = legalCase.courtName {
                    Text(court).font(.brand(.caption)).foregroundStyle(theme.textSecondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func eventRow(_ event: ComplianceEvent, _ model: CalendarViewModel) -> some View {
        HStack(spacing: 10) {
            Button {
                Task { await model.toggleDone(event) }
            } label: {
                Image(systemName: event.isDone ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(event.isDone ? theme.accent : theme.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(event.isDone ? "Mark not done" : "Mark done")

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title ?? "—")
                    .font(.brand(.subheadline))
                    .strikethrough(event.isDone)
                    .foregroundStyle(event.isDone ? theme.textSecondary : theme.textPrimary)
                    .lineLimit(2)
                HStack(spacing: 5) {
                    Label(event.kind.label, systemImage: event.kind.systemImage)
                    if let due = event.dayKey {
                        Text("·")
                        Text(DisplayText.longDay(due))
                    }
                }
                .font(.brand(.caption2))
                .foregroundStyle(theme.textTertiary)
                if let notes = event.notes, !notes.isEmpty {
                    Text(notes).font(.brand(.caption)).foregroundStyle(theme.textSecondary).lineLimit(2)
                }
            }
        }
        .swipeActions {
            Button(role: .destructive) {
                Task { await model.delete(event) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

/// Creating an obligation.
private struct ComplianceEventSheet: View {
    let day: String
    let onSave: (ComplianceDraft) async -> Void

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var kind: ComplianceKind = .task
    @State private var dueDate = Date()
    @State private var notes = ""
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What is due", text: $title)
                    Picker("Type", selection: $kind) {
                        ForEach(ComplianceKind.selectable, id: \.self) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    DatePicker("Due", selection: $dueDate, displayedComponents: .date)
                    TextField("Notes (optional)", text: $notes, axis: .vertical)
                        .lineLimit(2...6)
                } footer: {
                    // Said out loud rather than silently omitting the control: a practitioner
                    // who expects a reminder and does not get one is worse off than one who
                    // knows to set their own.
                    Text("Emperor does not send reminders for diary entries yet. Set your own alert if this date matters.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.canvas)
            .navigationTitle("Add to diary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        isSaving = true
                        Task {
                            await onSave(ComplianceDraft(
                                id: nil,
                                title: title,
                                kind: kind,
                                dueDate: dueDate,
                                notes: notes.isEmpty ? nil : notes,
                                caseID: nil))
                            isSaving = false
                            dismiss()
                        }
                    }
                    .disabled(
                        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
            .onAppear {
                if let parsed = WireDate.parseDay(day) { dueDate = parsed }
            }
        }
    }
}
