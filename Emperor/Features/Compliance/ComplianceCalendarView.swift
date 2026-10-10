import SwiftUI

/// The Corporate Calendar: statutory deadlines from the platform's compliance pipeline.
///
/// The web's `ComplianceCalendar.jsx`, reshaped for a phone: the three counts, the category
/// chips and the status filter come across as they are, and the month grid gives way to its own
/// agenda — overdue, the next seven days, then each later month — because twenty-odd deadlines
/// spread across a year are mostly empty cells in a grid this size. What the screen does and
/// does not do, and why, is on `ComplianceCalendarViewModel`.
///
/// Reached from More, for every role, and presented there — so it owns its `NavigationStack` and
/// carries its own **Done**, as every screen More presents does (see `MoreView`). It was a
/// role-gated Corporate tab here, as it is on the web, until the product owner gave that place in
/// the bar to the user's own Calendar; see `MainTabView`.
struct ComplianceCalendarView: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var model: ComplianceCalendarViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    content(model)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(ComplianceCalendarViewModel.Copy.title)
            // On the root rather than inside `content`, so the way out is there in every state —
            // the spinner, and the failure view if the load never returns.
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                guard model == nil else { return }
                let created = ComplianceCalendarViewModel(
                    service: session.complianceCalendar, cache: session.cache)
                model = created
                await created.load()
            }
        }
    }

    @ViewBuilder
    private func content(_ model: ComplianceCalendarViewModel) -> some View {
        ListStateView(presentation: model.presentation, retry: { await model.load() }) {
            List {
                Section {
                    summaryStrip(model)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .listRowBackground(Color.clear)
                    if model.availableCategories.count > 1 {
                        categoryChips(model)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                } header: {
                    Text(ComplianceCalendarViewModel.Copy.subtitle)
                        .font(.brand(.caption))
                        .foregroundStyle(theme.textSecondary)
                        .textCase(nil)
                }

                if model.isFilteredToNothing {
                    Section {
                        VStack(alignment: .leading, spacing: Spacing.sm) {
                            Label {
                                Text(ComplianceCalendarViewModel.Copy.nothingMatches)
                            } icon: {
                                Image(systemName: "line.3.horizontal.decrease.circle")
                            }
                            .font(.brand(.subheadline))
                            .foregroundStyle(theme.textSecondary)
                            Button("Clear filters") { model.clearFilters() }
                                .font(.brand(.subheadline, weight: .semibold))
                                .foregroundStyle(theme.accentText)
                                .buttonStyle(.plain)
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(theme.surface)
                }

                ForEach(model.groups) { group in
                    Section {
                        ForEach(group.deadlines) { deadline in
                            NavigationLink {
                                ComplianceDeadlineDetailView(detail: model.detail(for: deadline))
                            } label: {
                                row(deadline, model)
                            }
                        }
                    } header: {
                        SectionHeader(title: group.title, detail: "\(group.deadlines.count)")
                    }
                    .listRowBackground(theme.surface)
                }

                Section {
                    EmptyView()
                } footer: {
                    footnote(model)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.groupedBackground)
            .refreshable { await model.load() }
        } empty: {
            // Only after a load that returned: "the feed has nothing dated", never "we could
            // not ask" — that is `LoadFailureView`'s job.
            EmptyStateView(
                ComplianceCalendarViewModel.Copy.nothingTracked,
                systemImage: "calendar.badge.checkmark",
                message: ComplianceCalendarViewModel.Copy.nothingTrackedDetail
            ) {
                Button("Refresh") { Task { await model.load() } }
                    .buttonStyle(.secondaryAction)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                filterMenu(model)
            }
        }
    }

    // MARK: - Counts and chips

    /// The web's three counts — overdue, next seven days, open — over whatever is filtered.
    private func summaryStrip(_ model: ComplianceCalendarViewModel) -> some View {
        let summary = model.summary
        // Three abreast, or one under another at the accessibility sizes — a third of the width
        // holds a large count, but not "Next 7 days" beside it.
        return AdaptiveStack(spacing: Spacing.sm) {
            countTile(summary.overdue, label: "Overdue", systemImage: "exclamationmark.triangle.fill",
                      color: summary.overdue > 0 ? theme.danger : theme.textTertiary)
            countTile(summary.dueSoon, label: "Next 7 days", systemImage: "clock.fill",
                      color: summary.dueSoon > 0 ? theme.warning : theme.textTertiary)
            countTile(summary.open, label: "Open", systemImage: "calendar",
                      color: theme.accentText)
        }
    }

    /// One of the three counts: its mark in a small wash of its colour, the number large and in
    /// even-width figures so the three line up, and what it counts.
    private func countTile(_ count: Int, label: String, systemImage: String, color: Color)
        -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Image(systemName: systemImage)
                .font(.brand(.caption, weight: .semibold))
                .foregroundStyle(color)
                .frame(minWidth: 26, minHeight: 26)
                .background(color.opacity(0.14), in: Circle())
            Text("\(count)")
                .font(.brand(.title2, weight: .semibold).monospacedDigit())
                .foregroundStyle(theme.textPrimary)
                .padding(.top, Spacing.xxs)
            Text(label)
                .font(.brand(.caption, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                .dynamicLineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.md)
        .panel()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(count)")
    }

    /// The category chips — the web's legend-and-filter row — limited to categories that have
    /// a dated deadline, so no chip is a dead end.
    private func categoryChips(_ model: ComplianceCalendarViewModel) -> some View {
        let selected = model.category
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.sm) {
                chip("All", systemImage: nil, count: model.count(in: nil),
                     isSelected: selected == nil) {
                    model.select(category: nil)
                }
                ForEach(model.availableCategories) { category in
                    chip(category.label, systemImage: category.systemImage,
                         count: model.count(in: category), isSelected: selected == category) {
                        // Tapping the chosen chip again clears it, as on the web.
                        model.select(category: selected == category ? nil : category)
                    }
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 6)
        }
    }

    private func chip(
        _ title: String, systemImage: String?, count: Int, isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ChipLabel(title: title, systemImage: systemImage, count: count, isSelected: isSelected)
        }
        .buttonStyle(ChipButtonStyle(isSelected: isSelected))
        .accessibilityLabel("\(title), \(count)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Status and regulator, the two filters that are not chips.
    private func filterMenu(_ model: ComplianceCalendarViewModel) -> some View {
        Menu {
            Picker("Status", selection: Binding(
                get: { model.status },
                set: { model.select(status: $0) }
            )) {
                ForEach(ComplianceCalendarViewModel.StatusFilter.allCases) { option in
                    Text(option.label).tag(option)
                }
            }

            if !model.availableRegulators.isEmpty {
                Picker("Regulator", selection: Binding(
                    get: { model.regulator },
                    set: { model.select(regulator: $0) }
                )) {
                    Text("All regulators").tag(String?.none)
                    ForEach(model.availableRegulators, id: \.self) { regulator in
                        Text(regulator).tag(String?.some(regulator))
                    }
                }
            }

            if model.hasActiveFilters {
                Divider()
                Button("Clear filters") { model.clearFilters() }
            }
        } label: {
            Label(
                "Filter",
                systemImage: model.hasActiveFilters
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel(model.hasActiveFilters ? "Filter, filters on" : "Filter")
    }

    // MARK: - Rows

    private func row(_ deadline: StatutoryDeadline, _ model: ComplianceCalendarViewModel)
        -> some View {
        let urgency = model.urgency(of: deadline)
        let done = model.isDone(deadline)
        // The date leaf beside the words, or above them at the accessibility sizes, where beside
        // them it would leave the obligation's name a word to a line.
        return AdaptiveStack(verticalAlignment: .top, spacing: Spacing.md) {
            dateTile(deadline.dueDay, urgency: urgency)

            VStack(alignment: .leading, spacing: 4) {
                Text(deadline.displayTitle)
                    .font(.brand(.subheadline, weight: .semibold))
                    .foregroundStyle(done ? theme.textSecondary : theme.textPrimary)
                    .strikethrough(done)
                    .dynamicLineLimit(2)

                HStack(spacing: 5) {
                    if let category = deadline.category {
                        // The category is named in the words beside it.
                        Image(systemName: category.systemImage)
                            .accessibilityHidden(true)
                    }
                    Text(sourceLine(deadline))
                        .dynamicLineLimit(1)
                }
                .font(.brand(.caption))
                .foregroundStyle(theme.textSecondary)

                AdaptiveStack(horizontalAlignment: .leading, spacing: 6) {
                    StatusPill(
                        text: urgency.label, tone: tone(urgency.emphasis),
                        systemImage: urgency.isOpenAndPast ? "exclamationmark.triangle" : nil)
                    if deadline.differsFromUsualSchedule {
                        StatusPill(text: "Moved", tone: .info, systemImage: "arrow.uturn.right")
                    }
                    if let frequency = deadline.frequencyLabel {
                        StatusPill(text: frequency)
                    }
                }
            }
        }
        .padding(.vertical, Spacing.xs)
    }

    private func sourceLine(_ deadline: StatutoryDeadline) -> String {
        [deadline.regulator, deadline.category?.label].compactMap { $0 }.joined(separator: " · ")
    }

    /// A calendar leaf — weekday, day, month — tinted by how pressing the date is.
    private func dateTile(_ day: String?, urgency: DeadlineUrgency) -> some View {
        let tile = day.flatMap(CourtCalendar.tile)
        let accent = color(urgency.emphasis)
        return VStack(spacing: 0) {
            Text(tile?.weekday ?? "")
                .font(.brand(.caption2, weight: .semibold))
                .foregroundStyle(accent)
            Text(tile?.day ?? "—")
                .font(.brand(.title3, weight: .bold).monospacedDigit())
                .foregroundStyle(theme.textPrimary)
            Text(tile?.month ?? "")
                .font(.brand(.caption2))
                .foregroundStyle(theme.textSecondary)
        }
        .frame(minWidth: 46)
        .padding(.vertical, Spacing.sm - 2)
        .padding(.horizontal, Spacing.xs)
        .background(
            accent.opacity(0.12),
            in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .strokeBorder(accent.opacity(0.25), lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(day.map(DisplayText.longDay) ?? "No date")
    }

    private func footnote(_ model: ComplianceCalendarViewModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ComplianceCalendarViewModel.Copy.confirmWithRegulator)
            // A short list must not be read as a complete one.
            if let undated = model.undatedFootnote {
                Text(undated)
            }
        }
        .font(.brand(.caption))
        .foregroundStyle(theme.textSecondary)
    }

    // MARK: - Tone

    private func tone(_ emphasis: DeadlineUrgency.Emphasis) -> StatusPill.Tone {
        switch emphasis {
        case .neutral: return .neutral
        case .success: return .success
        case .warning: return .warning
        case .danger: return .danger
        }
    }

    private func color(_ emphasis: DeadlineUrgency.Emphasis) -> Color {
        switch emphasis {
        case .neutral: return theme.accentText
        case .success: return theme.success
        case .warning: return theme.warning
        case .danger: return theme.danger
        }
    }
}

/// One deadline: what is due, to whom, when, and how far to trust the date.
///
/// No link out. The feed names each obligation's regulator but carries no notice or portal
/// URL — `toCalendarEvent` does not pass `filing_portal_url` through — and a link this app
/// guessed at would be a link to the wrong page on a government site.
struct ComplianceDeadlineDetailView: View {
    @Environment(\.theme) private var theme

    let detail: DeadlineDetail

    var body: some View {
        List {
            Section {
                header
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4))
            }

            Section {
                if let dueLong = detail.dueLong {
                    ValueRow("Next due", value: dueLong)
                }
                if let usual = detail.usualSchedule {
                    ValueRow("Usual deadline", value: usual)
                }
                if let frequency = detail.frequency {
                    ValueRow("Frequency", value: frequency)
                }
            } header: {
                SectionHeader(title: "When")
            } footer: {
                if detail.differsFromUsualSchedule {
                    Label(DeadlineDetail.movedNotice, systemImage: "arrow.uturn.right")
                        .font(.brand(.caption))
                        .foregroundStyle(theme.info)
                }
            }
            .listRowBackground(theme.surface)

            Section {
                if let regulator = detail.regulator {
                    ValueRow("Regulator", value: regulator)
                }
                if let category = detail.category {
                    ValueRow("Category", value: category.label)
                }
                if let code = detail.code {
                    ValueRow("Reference", value: code)
                }
            } header: {
                SectionHeader(title: "Who")
            }
            .listRowBackground(theme.surface)

            if let note = detail.note {
                Section {
                    Text(note)
                        .font(.brand(.subheadline))
                        .foregroundStyle(theme.textPrimary)
                        .textSelection(.enabled)
                } header: {
                    SectionHeader(title: "Note")
                }
                .listRowBackground(theme.surface)
            }

            Section {
                if detail.isDone {
                    Label("Marked done on the web", systemImage: "checkmark.circle.fill")
                        .font(.brand(.subheadline))
                        .foregroundStyle(theme.success)
                }
                if let verification = detail.verificationText {
                    Label(verification, systemImage: verificationSymbol)
                        .font(.brand(.subheadline))
                        .foregroundStyle(verificationColor)
                }
            } footer: {
                Text(ComplianceCalendarViewModel.Copy.confirmWithRegulator)
                    .font(.brand(.caption))
                    .foregroundStyle(theme.textSecondary)
            }
            .listRowBackground(theme.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.groupedBackground)
        .navigationTitle(detail.code ?? "Deadline")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: detail.shareText) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let category = detail.category {
                Label(category.label, systemImage: category.systemImage)
                    .font(.brand(.caption, weight: .semibold))
                    .foregroundStyle(theme.accentText)
            }
            Text(detail.title)
                .font(.brand(.title2, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 6) {
                StatusPill(text: detail.urgency.label, tone: tone)
                if detail.differsFromUsualSchedule {
                    StatusPill(text: "Moved", tone: .info, systemImage: "arrow.uturn.right")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tone: StatusPill.Tone {
        switch detail.urgency.emphasis {
        case .neutral: return .neutral
        case .success: return .success
        case .warning: return .warning
        case .danger: return .danger
        }
    }

    private var verificationSymbol: String {
        if case .unconfirmed = detail.verification { return "exclamationmark.triangle" }
        return "checkmark.seal"
    }

    private var verificationColor: Color {
        if case .unconfirmed = detail.verification { return theme.warning }
        return theme.textSecondary
    }
}
