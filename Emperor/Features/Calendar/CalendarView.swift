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
/// ## Opened on a day from outside
///
/// A tapped hearing reminder, the Today widget and the app's `emperor://calendar?day=` link all
/// ask `AppNavigator` for a day. This takes it the way the Cases tab takes a case — when it
/// appears, or when the request arrives while it is already alive — selects the day, and scrolls
/// back to the month so the day's listings are what is on screen. A request that arrives before
/// the screen has made its model is taken as the model is made, before the first load.
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var model: CalendarViewModel?
    @State private var isAddingEvent = false
    @State private var isSubscribing = false
    /// The month steps, scaled with the heading they sit beside.
    @ScaledMetric(relativeTo: .footnote) private var stepSide: CGFloat = 32
    /// Counts days opened from outside, each of which scrolls back up to the month.
    @State private var openedDays = 0

    /// The month grid's row, which a day opened from outside scrolls to.
    private static let monthRowID = "calendar-month"

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
                // A day asked for before this screen existed — the tap that launched the app.
                if let day = navigator.takePendingDay() { created.select(day: day) }
                model = created
                await created.load()
            }
        }
        // Both, as the Cases tab does: a tab never shown before is created by the switch the
        // request causes, and one already alive sees the request change instead.
        .onAppear { openRequestedDay() }
        .onChange(of: navigator.pendingDay) { _, _ in openRequestedDay() }
    }

    /// Selects a day asked for from outside. Left waiting until the model exists — the `.task`
    /// above takes it then.
    private func openRequestedDay() {
        guard let model, let day = navigator.takePendingDay() else { return }
        model.select(day: day)
        openedDays += 1
    }

    @ViewBuilder
    private func content(_ model: CalendarViewModel) -> some View {
        ListStateView(presentation: model.presentation, retry: { await model.load() }) {
            ScrollViewReader { proxy in
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
                        .listRowBackground(theme.surface)
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
                        .listRowBackground(theme.surface)
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
                        .listRowBackground(theme.surface)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(theme.groupedBackground)
                .refreshable { await model.load() }
                // A day opened from outside: back up to the month, the day just below it.
                .onChange(of: openedDays) { _, _ in
                    withAnimation(reduceMotion ? nil : Animation.default) {
                        proxy.scrollTo(Self.monthRowID, anchor: .top)
                    }
                }
            }
        } empty: {
            // Should be unreachable: `presentation` reports empty only before the first load
            // returns, and that shows a spinner or a failure instead. Left as something legible
            // rather than an `EmptyView`, so that if the reasoning is ever wrong the screen says
            // what it means — going blank is the bug this grid was built to end.
            EmptyStateView(
                "Nothing scheduled",
                systemImage: "calendar",
                message: "Hearings on your matters, and anything you add here, appear together.")
        }
        // The conversation's measure on an iPad, so the month is a grid the eye takes in at once
        // rather than seven columns spread across the display, and a listing reads as one line.
        .readableColumn()
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
            VStack(spacing: Spacing.xs) {
                HStack(spacing: Spacing.xs) {
                    ForEach(Array(CalendarMonth.weekdayInitials.enumerated()), id: \.offset) {
                        _, initial in
                        Text(initial)
                            .font(.brand(.caption2, weight: .semibold))
                            .foregroundStyle(theme.textTertiary)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.bottom, Spacing.xxs)
                // One element for the row, saying what it is — each day cell already names its
                // own weekday, so seven single letters read aloud would only be noise; but text
                // on screen with nothing behind it reads to the audit as text VoiceOver cannot
                // reach.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Sunday to Saturday")
                // Text, not a control: without the trait an element built from children is judged
                // as one, and its 14-point height as a target too small to hit.
                .accessibilityAddTraits(.isStaticText)
                if let month = model.month {
                    // Keyed by position: a week has no identity of its own, and the days inside
                    // it carry real dates that do.
                    ForEach(Array(month.weeks.enumerated()), id: \.offset) { _, week in
                        HStack(spacing: Spacing.xs) {
                            ForEach(week) { day in
                                dayCell(day, model, mark: marks[day.key] ?? CalendarDayMark.clear)
                            }
                        }
                    }
                }
                legend
            }
            .padding(.vertical, Spacing.xxs)
            .listRowInsets(EdgeInsets(top: 12, leading: 10, bottom: 10, trailing: 10))
            .id(Self.monthRowID)
        } header: {
            monthHeader(model)
        }
        .listRowBackground(theme.surface)
    }

    /// What the two marks mean — said once, as a sentence, to VoiceOver, which also hears each
    /// day's own mark as words.
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
        .padding(.top, Spacing.sm)
        .padding(.leading, Spacing.xs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("A dot marks a day with cases listed; a ring, a day with only diary entries.")
        // Text, not a control — see the weekday row above.
        .accessibilityAddTraits(.isStaticText)
    }

    /// The month's name, as the heading of its own card, with the way back to today and the
    /// two steps beside it — round, as Home's day steps are.
    private func monthHeader(_ model: CalendarViewModel) -> some View {
        // The month over its controls at the accessibility sizes, where beside them its name
        // would be cut to a word.
        AdaptiveStack(spacing: Spacing.sm) {
            Text(model.month?.title ?? "")
                .font(.brand(.headline, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Spacing.sm)
            HStack(spacing: Spacing.sm) {
                // Only once there is somewhere to come back from. The capsule inside the label,
                // with a 44-point frame round it, so all of it takes the tap — not the word alone.
                if !model.isShowingToday {
                    Button {
                        model.goToToday()
                        VoiceOver.announce(model.month?.title ?? "")
                    } label: {
                        Text("Today")
                            .font(.brand(.caption, weight: .semibold))
                            .foregroundStyle(theme.accentText)
                            .padding(.horizontal, Spacing.md)
                            .padding(.vertical, 6)
                            .background(theme.accentWash, in: Capsule())
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                monthStep("chevron.left", label: "Previous month") { step(model, by: -1) }
                monthStep("chevron.right", label: "Next month") { step(model, by: 1) }
            }
        }
        .textCase(nil)
        .padding(.bottom, Spacing.xs)
    }

    private func monthStep(
        _ systemImage: String, label: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.brand(.footnote, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .frame(width: min(stepSide, 48), height: min(stepSide, 48))
                .background(theme.surface, in: Circle())
                .overlay(Circle().strokeBorder(theme.separator, lineWidth: 1))
                // The circle is drawn at its size; the target is at least 44 points.
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// The month changes above the control VoiceOver is on, so its name is said as well.
    private func step(_ model: CalendarViewModel, by months: Int) {
        model.step(months: months)
        VoiceOver.announce(model.month?.title ?? "")
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
            VStack(spacing: 3) {
                Text("\(day.number)")
                    .font(.brand(.subheadline, weight: weight).monospacedDigit())
                marker(mark, isSelected: isSelected)
            }
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                isSelected ? theme.accent : Color.clear,
                in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .strokeBorder(
                        isToday && !isSelected ? theme.accentText : Color.clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Today is ringed for the eye; to VoiceOver it is said.
        .accessibilityLabel(
            isToday ? "Today, \(DisplayText.longDay(day.key))" : DisplayText.longDay(day.key))
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
        .listRowBackground(theme.surface)
    }

    /// A listing, which opens its case on the Cases tab — see the type's documentation for why
    /// it is not pushed here. A button with a chevron rather than a `NavigationLink`, because it
    /// leaves this tab; it still looks like every other row that leads somewhere.
    private func listingButton(_ listing: CauseListing) -> some View {
        Button {
            navigator.openCase(listing.caseID)
        } label: {
            HStack(spacing: Spacing.sm) {
                CauseListingRow(listing: listing, leadsWithTime: true)
                Spacer(minLength: 0)
                RowChevron()
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
        HStack(alignment: .top, spacing: Spacing.md) {
            Button {
                Task { await model.toggleDone(event) }
            } label: {
                Image(systemName: event.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.brand(.title3))
                    .foregroundStyle(event.isDone ? theme.accentText : theme.textTertiary)
                    // A fingertip's worth, though the mark itself is small.
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(event.isDone ? "Mark not done" : "Mark done")

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title ?? "—")
                    .font(.brand(.subheadline, weight: .medium))
                    .strikethrough(event.isDone)
                    .foregroundStyle(event.isDone ? theme.textSecondary : theme.textPrimary)
                    .dynamicLineLimit(2)
                // Kind and date one over the other at the accessibility sizes. Not combined into
                // one element: the tests find an entry by its title's text.
                AdaptiveStack(spacing: 5) {
                    Label(event.kind.label, systemImage: event.kind.systemImage)
                    if let due = event.dayKey {
                        if !dynamicTypeSize.isAccessibilitySize {
                            SeparatorDot()
                        }
                        Text(DisplayText.longDay(due))
                    }
                }
                .font(.brand(.caption2))
                .foregroundStyle(theme.textTertiary)
                if let notes = event.notes, !notes.isEmpty {
                    Text(notes).font(.brand(.caption)).foregroundStyle(theme.textSecondary)
                        .dynamicLineLimit(2)
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
                        .font(.brand(.caption))
                        .foregroundStyle(theme.textSecondary)
                }
                .listRowBackground(theme.surface)
            }
            .font(.brand(.body))
            .scrollContentBackground(.hidden)
            .background(theme.groupedBackground)
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
