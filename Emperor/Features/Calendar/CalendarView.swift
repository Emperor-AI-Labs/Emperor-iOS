import SwiftUI

/// The Calendar tab: the user's matters, day by day, and their own diary beside them.
///
/// ## A day
///
/// Selecting a day in the month shows the matters listed on it — from the cause list, topped up
/// from the docket's next hearing dates — **in the order the day will run**: by sitting time,
/// then the listings whose list printed no time, by courtroom and item. Each row is the one Home
/// draws (`CauseListingRow`), led by its time. Tapping one opens that case on the **Cases** tab,
/// on its overview: the case belongs to the docket, and a second copy of its screen inside this
/// tab would be a second place to look for the same matter. The day's diary entries follow as
/// their own section. The rules are `CalendarListings` and `CalendarViewModel`.
///
/// Every date is a day in India (README trap 9); the grid and "today" are pinned to it.
///
/// ## Subscribing from the Calendar app
///
/// **Subscribe** opens `CalendarSubscriptionSheet`: the user's private feed link, handed to the
/// iOS Calendar app as `webcal://`, copyable for Google or Outlook, and resettable. It was
/// withheld while the feed could not be issued as a secret the user can revoke; the platform
/// now issues one (`/calendar/feed-url`), with a reset that kills the old link.
///
/// ## What this screen deliberately does not offer
///
/// **No reminder picker.** `remind_days` is written, returned and rendered by the web client —
/// and read by nothing. There is no scheduler, the `reminder` notification type has no
/// producer, and the ICS feed emits no `VALARM` — so a subscribed calendar does not alert
/// either. On the one screen whose purpose is not missing a limitation date, a reminder control
/// would be the worst possible place to make a promise the product cannot keep.
///
/// The Corporate Calendar is not linked from here any more: it has its own row in More, for
/// every role.
struct CalendarView: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session
    @Environment(\.navigator) private var navigator

    @State private var model: CalendarViewModel?
    @State private var isAddingEvent = false
    @State private var isSubscribing = false

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    content(model)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Calendar")
            // On the root rather than inside `content`, so subscribing does not wait on — or
            // depend on — the calendar having loaded: the link is a separate request. Leading,
            // because a tab root has no Done to sit there and the trailing side holds "+".
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Subscribe") { isSubscribing = true }
                        .accessibilityHint("Adds your hearings and diary to the Calendar app")
                }
            }
            .sheet(isPresented: $isSubscribing) {
                CalendarSubscriptionSheet()
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

                // Read once: it filters the diary for the day.
                let day = model.selectedCalendarDay
                listingsSection(day, model)
                if !day.events.isEmpty {
                    Section {
                        ForEach(day.events) { event in
                            eventRow(event, model)
                        }
                    } header: {
                        SectionHeader(title: "Diary", detail: "\(day.events.count)")
                    }
                }

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
                ForEach(model.upcoming(excluding: model.selectedDay)) { upcoming in
                    Section {
                        ForEach(upcoming.listings) { listing in
                            listingButton(listing)
                        }
                        ForEach(upcoming.events) { event in
                            eventRow(event, model)
                        }
                    } header: {
                        SectionHeader(title: DisplayText.longDay(upcoming.key))
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

    /// The month as a grid of whole weeks, with a mark on every day that has something on it: a
    /// filled dot where a matter is listed, a ring where there are only diary entries.
    ///
    /// A mark rather than a count: the grid answers "which days", and the day's own sections
    /// below answer "what". A number in a cell this size is unreadable and, at a glance, is
    /// easily taken for the date. Two shapes rather than two colours, so the difference does not
    /// depend on seeing colour.
    private func monthSection(_ model: CalendarViewModel) -> some View {
        // Read once. `marks` walks both sources to build a map, and the grid is about to ask it
        // forty-odd times.
        let marks = model.marks
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
                                dayCell(day, model, mark: marks[day.key] ?? CalendarDayMark.clear)
                            }
                        }
                    }
                }
                legend
            }
            .padding(.vertical, 2)
            .listRowInsets(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
        } header: {
            monthHeader(model)
        }
    }

    /// What the two marks mean. Hidden from VoiceOver, which hears each day's mark as words.
    private var legend: some View {
        HStack(spacing: 14) {
            HStack(spacing: 5) {
                marker(.listed, isSelected: false)
                Text("Cases listed")
            }
            HStack(spacing: 5) {
                marker(.diary, isSelected: false)
                Text("Diary")
            }
            Spacer(minLength: 0)
        }
        .font(.brand(.caption2))
        .foregroundStyle(theme.textTertiary)
        .padding(.top, 4)
        .padding(.leading, 4)
        .accessibilityHidden(true)
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
        _ day: CalendarMonth.Day, _ model: CalendarViewModel, mark: CalendarDayMark
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
                marker(mark, isSelected: isSelected)
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
        .accessibilityValue(mark.spoken)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// A filled dot for a listed day, a ring for a diary-only one, nothing for a clear one — at a
    /// fixed size, so every cell is the same height whatever is on it.
    @ViewBuilder
    private func marker(_ mark: CalendarDayMark, isSelected: Bool) -> some View {
        switch mark {
        case .listed:
            Circle()
                .fill(isSelected ? theme.onAccent : theme.accent)
                .frame(width: 6, height: 6)
        case .diary:
            Circle()
                .strokeBorder(isSelected ? theme.onAccent : theme.textTertiary, lineWidth: 1)
                .frame(width: 6, height: 6)
        case .clear:
            Color.clear
                .frame(width: 6, height: 6)
        }
    }

    // MARK: - The selected day

    /// The matters listed on the selected day, in the order it will run — and when there are
    /// none, which kind of nothing it is. The footer says whose cases these are and to confirm
    /// with the court, on every state: an empty day must never read as a free one.
    private func listingsSection(_ day: CalendarDay, _ model: CalendarViewModel) -> some View {
        Section {
            if day.listings.isEmpty {
                Text(model.selectedDayEmptyText)
                    .font(.brand(.subheadline))
                    .foregroundStyle(theme.textSecondary)
            } else {
                ForEach(day.listings) { listing in
                    listingButton(listing)
                }
            }
        } header: {
            SectionHeader(
                title: DisplayText.longDay(day.key),
                detail: day.listings.isEmpty ? nil : "\(day.listings.count) listed")
        } footer: {
            Text(CalendarViewModel.Copy.listingsFooter)
                .font(.brand(.caption))
                .foregroundStyle(theme.textTertiary)
        }
    }

    /// A listing, which opens its case on the Cases tab — see the type's documentation for why
    /// it is not pushed here. A button with a chevron rather than a `NavigationLink`, because it
    /// leaves this tab; it still looks like every other row that leads somewhere.
    private func listingButton(_ listing: CauseListing) -> some View {
        Button {
            navigator.openCase(listing.caseID)
        } label: {
            HStack(spacing: 8) {
                CauseListingRow(listing: listing, leadsWithTime: true)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.brand(.footnote, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(listing.display.spokenLeadingWithTime(listing))
        .accessibilityHint("Opens the case on the Cases tab")
        .accessibilityIdentifier("calendar-listing-\(listing.caseID)")
    }

    // MARK: - Diary entries

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
