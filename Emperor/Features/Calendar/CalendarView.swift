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

    @Environment(\.dismiss) private var dismiss

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
            // On the root rather than inside `content`, so it is there in every state — including
            // the spinner before the first load returns, and the failure view if it never does.
            // A screen you cannot leave until it finishes loading is the one case where the way
            // out matters most.
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
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
                monthSection(model)
                selectedDaySection(model)

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

                // The selected day is listed in full directly above, so the agenda leaves it
                // out rather than printing the same day twice on one screen.
                ForEach(model.upcoming(excluding: model.selectedDay)) { day in
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
            // Should be unreachable: `presentation` reports empty only before the first load
            // returns, and that shows a spinner or a failure instead. Left as something legible
            // rather than an `EmptyView`, so that if the reasoning is ever wrong the screen says
            // what it means — going blank is the bug this grid was built to end.
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

    // MARK: - The month

    /// The month as a grid of whole weeks, with a dot on every day that has something on it.
    ///
    /// The dot rather than a count: the grid answers "which days", and the day's own section
    /// below answers "what". A number in a cell this size is unreadable and, at a glance, is
    /// easily taken for the date.
    private func monthSection(_ model: CalendarViewModel) -> some View {
        // Read once. `populatedDays` walks both arrays to build a set, and the grid is about to
        // ask it forty-odd times.
        let populated = model.populatedDays
        return Section {
            VStack(spacing: 5) {
                HStack(spacing: 4) {
                    ForEach(Array(CalendarMonth.weekdayInitials.enumerated()), id: \.offset) {
                        _, initial in
                        Text(initial)
                            .font(.brand(.caption2, weight: .semibold))
                            .foregroundStyle(theme.textTertiary)
                            .frame(maxWidth: .infinity)
                    }
                }
                if let month = model.month {
                    // Keyed by position: a week has no identity of its own, and the days inside
                    // it carry real dates that do.
                    ForEach(Array(month.weeks.enumerated()), id: \.offset) { _, week in
                        HStack(spacing: 4) {
                            ForEach(week) { day in
                                dayCell(day, model, hasItems: populated.contains(day.key))
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 2)
            .listRowInsets(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
        } header: {
            monthHeader(model)
        }
    }

    private func monthHeader(_ model: CalendarViewModel) -> some View {
        HStack(spacing: 10) {
            Text(model.month?.title ?? "")
                .font(.brand(.subheadline, weight: .bold))
                .foregroundStyle(theme.textPrimary)
            Spacer(minLength: 8)
            // Only once there is somewhere to come back from.
            if !model.isShowingToday {
                Button("Today") { model.goToToday() }
                    .font(.brand(.caption, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.accentText)
            }
            Button { model.step(months: -1) } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Previous month")
            Button { model.step(months: 1) } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Next month")
        }
        .font(.brand(.footnote, weight: .semibold))
        .foregroundStyle(theme.accentText)
        .textCase(nil)
    }

    private func dayCell(
        _ day: CalendarMonth.Day, _ model: CalendarViewModel, hasItems: Bool
    ) -> some View {
        let isSelected = day.key == model.selectedDay
        let isToday = day.key == model.todayKey
        // Spelled out rather than implicit members either side of the ternary: `brand(_:weight:)`
        // takes an `Optional`, which is the shape `-parse` accepts and the type checker rejects.
        let weight: Font.Weight? = isToday ? Font.Weight.bold : Font.Weight.regular
        let foreground: Color =
            isSelected ? theme.onAccent : (day.isInMonth ? theme.textPrimary : theme.textTertiary)

        return Button {
            model.select(day: day.key)
        } label: {
            VStack(spacing: 2) {
                Text("\(day.number)").font(.brand(.footnote, weight: weight))
                Circle()
                    .fill(hasItems ? (isSelected ? theme.onAccent : theme.accent) : Color.clear)
                    .frame(width: 5, height: 5)
            }
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(
                isSelected ? theme.accent : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        isToday && !isSelected ? theme.accent : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(DisplayText.longDay(day.key))
        .accessibilityValue(hasItems ? "Has entries" : "Nothing scheduled")
    }

    /// What is on the selected day — and when there is nothing, which kind of nothing it is.
    /// An empty day in a full diary and an empty diary are different things to be told.
    private func selectedDaySection(_ model: CalendarViewModel) -> some View {
        let day = model.selectedCalendarDay
        return Section {
            if day.isEmpty {
                Text(model.hasNothingToShow
                     ? "Nothing scheduled yet. Add a diary entry with the + above."
                     : "Nothing on this day.")
                    .font(.brand(.subheadline))
                    .foregroundStyle(theme.textSecondary)
            } else {
                ForEach(day.hearings) { legalCase in
                    NavigationLink(value: legalCase.id) {
                        hearingRow(legalCase)
                    }
                }
                ForEach(day.events) { event in
                    eventRow(event, model)
                }
            }
        } header: {
            SectionHeader(title: DisplayText.longDay(day.key))
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
