import SwiftUI

/// The Matters tab: the next sitting, what is upcoming, and every matter.
///
/// The first two are the cause list (`MattersOverview`), each hearing led by its item number in
/// the serif and opening its sheet; the third is the docket (`CaseListViewModel`), with its search,
/// sort and filters, each matter pushing its page. `+` adds a matter through the court lookup, and
/// the Calendar — hearings day by day, and the diary — opens from the bar. Pull to refresh checks
/// the cause lists again, and says so when it is done.
///
/// - Important: what is listed here is the user's own matters by hearing date, not the court's
///   published list. Every empty state ends with `CauseListViewModel.Copy.confirmWithCourt`.
struct MattersView: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session
    @Environment(\.navigator) private var navigator
    @Environment(\.horizontalSizeClass) private var sizeClass

    enum Segment: Hashable { case next, upcoming, all }

    @State private var path: [CaseRoute] = []
    @State private var causeList: CauseListViewModel?
    @State private var cases: CaseListViewModel?
    @State private var segment: Segment = .next
    @State private var openHearing: CauseListing?
    @State private var isAddingMatter = false
    @State private var isArranging = false
    @State private var isShowingCalendar = false
    @State private var toast: String?

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let overview {
                        Text(overview.subtitle(trackedMatters: cases.map { $0.cases.count }))
                            .font(.brand(.subheadline))
                            .foregroundStyle(theme.textFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    RecordSegmentedControl(
                        label: "Show",
                        options: [
                            (value: Segment.next, title: nextLabel),
                            (value: Segment.upcoming, title: "Upcoming"),
                            (value: Segment.all, title: "All matters"),
                        ],
                        selection: $segment)
                        .padding(.top, Spacing.lg)

                    if let failure = causeList?.state.failure, segment != .all {
                        refreshFailed(failure)
                            .padding(.top, Spacing.md)
                    }

                    Group {
                        switch segment {
                        case .next: nextSittingList
                        case .upcoming: upcomingList
                        case .all: allMattersList
                        }
                    }
                    .padding(.top, 14)

                    if segment != .all {
                        Text("Court and item numbers come from the published cause list, for your own matters. \(CauseListViewModel.Copy.confirmWithCourt)")
                            .font(.brand(size: 12.5, relativeTo: .caption))
                            .foregroundStyle(theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, Spacing.md)
                    }
                }
                .padding(.horizontal, Spacing.gutter)
                .padding(.bottom, Spacing.xxxl)
                .frame(maxWidth: ReadableWidth.cap(for: sizeClass))
                .frame(maxWidth: .infinity)
            }
            .refreshable { await refresh() }
            .background(theme.canvas)
            .navigationTitle("Matters")
            .navigationBarTitleDisplayMode(.large)
            .toolbar { toolbar }
            .navigationDestination(for: CaseRoute.self) { route in
                CaseDetailView(caseID: route.caseID)
                    .toolbar(.hidden, for: .tabBar)
            }
            .sheet(item: $openHearing) { listing in
                HearingSheet(
                    listing: listing,
                    allListings: causeList?.listings ?? [],
                    onOpenMatter: { path = [CaseRoute(caseID: $0)] },
                    onAsk: { navigator.ask($0) })
            }
            .sheet(isPresented: $isAddingMatter) {
                CourtSearchView {
                    let cases = self.cases
                    Task { await cases?.load() }
                }
                .pageSizedSheet()
            }
            .sheet(isPresented: $isArranging) {
                if let cases {
                    CaseArrangementSheet(model: cases)
                        .pageSizedSheet()
                }
            }
            .sheet(isPresented: $isShowingCalendar) {
                CalendarView(onDone: { isShowingCalendar = false })
                    .pageSizedSheet()
            }
        }
        .recordToast($toast)
        .task { await loadOnce() }
        // A matter asked for from elsewhere — the Calendar, a search result. Both, because either
        // can be first: a tab never shown before is created by the switch the request causes.
        .onAppear {
            openRequestedCase()
            openRequestedCalendar()
        }
        .onChange(of: navigator.pendingCase) { _, _ in
            isShowingCalendar = false
            openRequestedCase()
        }
        .onChange(of: navigator.calendarRequest) { _, _ in openRequestedCalendar() }
    }

    private var overview: MattersOverview? {
        causeList.map { MattersOverview(listings: $0.listings, todayKey: $0.todayKey) }
    }

    /// The first segment is named for its day: "Today", "Mon 12 Oct".
    private var nextLabel: String {
        guard let overview, let day = overview.nextSitting else { return "Next sitting" }
        return overview.dayLabel(day.key)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                isShowingCalendar = true
            } label: {
                Image(systemName: "calendar")
            }
            .accessibilityLabel("Calendar")
            .accessibilityHint("Your hearings day by day, and your diary")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if segment == .all, let cases {
                Button {
                    isArranging = true
                } label: {
                    Image(systemName: cases.filters.isEmpty
                          ? "line.3.horizontal.decrease.circle"
                          : "line.3.horizontal.decrease.circle.fill")
                }
                .accessibilityLabel(CaseListViewModel.Copy.arrange)
                .accessibilityValue(cases.filterSummary)
            }
            Button {
                isAddingMatter = true
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Add a matter")
            .accessibilityHint("Finds a case at its court and adds it to your matters")
        }
    }

    // MARK: - Next sitting

    @ViewBuilder
    private var nextSittingList: some View {
        if let overview, let day = overview.nextSitting {
            hearingGroup(day.listings)
        } else if causeList?.listings.isEmpty ?? true, causeList?.state.isLoading ?? true {
            loading
        } else {
            EmptyStateContent(
                title: causeList?.hasAnyListings == true ? "Nothing listed ahead" : CauseListViewModel.Copy.nothingAtAll,
                systemImage: "calendar.badge.checkmark",
                message: causeList?.hasAnyListings == true
                    ? "None of your matters has a hearing coming up. \(CauseListViewModel.Copy.confirmWithCourt)"
                    : "\(CauseListViewModel.Copy.nothingAtAllDetail) \(CauseListViewModel.Copy.confirmWithCourt)"
            ) {
                Button {
                    isAddingMatter = true
                } label: {
                    Label("Add a matter", systemImage: "plus")
                }
                .buttonStyle(.primaryAction)
            }
        }
    }

    private func hearingGroup(_ listings: [CauseListing]) -> some View {
        RecordGroup {
            ForEach(Array(listings.enumerated()), id: \.element.id) { index, listing in
                if index > 0 { RecordDivider(inset: 0) }
                Button {
                    openHearing = listing
                } label: {
                    HearingRow(listing: listing)
                }
                .buttonStyle(.recordRow)
                .accessibilityHint("Shows the hearing")
            }
        }
    }

    // MARK: - Upcoming

    @ViewBuilder
    private var upcomingList: some View {
        if let overview, !overview.upcoming.isEmpty {
            RecordGroup {
                ForEach(Array(allUpcoming(overview).enumerated()), id: \.offset) { index, entry in
                    if index > 0 { RecordDivider(inset: 0) }
                    Button {
                        openHearing = entry.listing
                    } label: {
                        UpcomingRow(dayKey: entry.day, listing: entry.listing)
                    }
                    .buttonStyle(.recordRow)
                }
            }
        } else if causeList?.listings.isEmpty ?? true, causeList?.state.isLoading ?? true {
            loading
        } else {
            EmptyStateContent(
                title: "Nothing further listed",
                systemImage: "calendar",
                message: "Nothing of yours is listed after the next sitting. \(CauseListViewModel.Copy.confirmWithCourt)"
            ) {
                Button("Open the Calendar") { isShowingCalendar = true }
                    .buttonStyle(.secondaryAction)
            }
        }
    }

    private func allUpcoming(_ overview: MattersOverview) -> [(day: String, listing: CauseListing)] {
        overview.upcoming.flatMap { day in day.listings.map { (day: day.key, listing: $0) } }
    }

    // MARK: - All matters

    @ViewBuilder
    private var allMattersList: some View {
        if let cases {
            @Bindable var bindable = cases
            VStack(alignment: .leading, spacing: Spacing.md) {
                RecordSearchField(text: $bindable.query, prompt: CaseListViewModel.Copy.searchPrompt)

                if !cases.filterChips.isEmpty {
                    FilterChipBar(
                        chips: cases.filterChips,
                        remove: { cases.remove($0) },
                        clearAll: { cases.clearFilters() })
                }

                if cases.cases.isEmpty, cases.state.isLoading {
                    loading
                } else if cases.cases.isEmpty {
                    EmptyStateContent(
                        title: CaseListViewModel.Copy.noMattersTitle,
                        systemImage: "briefcase",
                        message: CaseListViewModel.Copy.noMattersMessage
                    ) {
                        Button {
                            isAddingMatter = true
                        } label: {
                            Label("Add a matter", systemImage: "plus")
                        }
                        .buttonStyle(.primaryAction)
                    }
                } else if let noMatches = cases.noMatches {
                    EmptyStateContent(
                        title: noMatches.title,
                        systemImage: "line.3.horizontal.decrease.circle",
                        message: noMatches.message
                    ) {
                        Button(noMatches.action) { cases.clearSearchAndFilters() }
                            .buttonStyle(.secondaryAction)
                    }
                } else {
                    ForEach(cases.groups) { group in
                        VStack(alignment: .leading, spacing: 0) {
                            RecordSectionLabel(title: "\(group.title) · \(group.cases.count)")
                                .padding(.top, -Spacing.sm)
                            RecordGroup {
                                ForEach(Array(group.cases.enumerated()), id: \.element.id) { index, legalCase in
                                    if index > 0 { RecordDivider() }
                                    Button {
                                        path.append(CaseRoute(caseID: legalCase.id))
                                    } label: {
                                        MatterRow(legalCase: legalCase)
                                    }
                                    .buttonStyle(.recordRow)
                                    .accessibilityIdentifier("case-row-\(legalCase.id)")
                                }
                            }
                        }
                    }
                }
            }
        } else {
            loading
        }
    }

    // MARK: - States

    private var loading: some View {
        ProgressView()
            .frame(maxWidth: .infinity, minHeight: 120)
    }

    private func refreshFailed(_ failure: LoadFailure) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            Image(systemName: "exclamationmark.triangle")
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("The cause lists couldn't be checked. \(causeList?.listings.isEmpty == false ? "This is what was last loaded." : "")")
                    .foregroundStyle(theme.textPrimary)
                Text(failure.message)
                    .foregroundStyle(theme.textSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if failure.isRetryable {
                Button("Retry") {
                    Task { await refresh() }
                }
                .buttonStyle(.quietAction)
            }
        }
        .font(.brand(.footnote))
        .foregroundStyle(theme.warning)
        .padding(Spacing.md)
        .background(Color(theme.palette.bannerWash), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    // MARK: - Loading and requests

    private func loadOnce() async {
        if causeList == nil {
            causeList = CauseListViewModel(service: session.cases, cache: session.cache)
        }
        if cases == nil {
            cases = CaseListViewModel(
                service: session.cases, cache: session.cache, store: CaseListView.preferences)
        }
        let causeList = self.causeList
        let cases = self.cases
        await causeList?.load()
        await cases?.load()
    }

    /// Pull to refresh: the cause lists and the docket, then a word on how it went.
    private func refresh() async {
        let causeList = self.causeList
        let cases = self.cases
        await causeList?.load()
        await cases?.load()
        if causeList?.state.failure == nil {
            toast = "Cause lists checked"
        }
    }

    private func openRequestedCase() {
        guard let stack = navigator.takePendingCaseStack() else { return }
        segment = .all
        path = stack
    }

    private func openRequestedCalendar() {
        guard navigator.takeCalendarRequest() else { return }
        isShowingCalendar = true
    }
}

/// An upcoming hearing: its day as a calendar block, then the matter and where it is listed.
private struct UpcomingRow: View {
    @Environment(\.theme) private var theme
    let dayKey: String
    let listing: CauseListing

    @ScaledMetric(relativeTo: .title2) private var blockWidth: CGFloat = 52

    var body: some View {
        let display = listing.display
        let block = MattersOverview.calendarBlock(dayKey)
        let place = [MattersOverview.courtShortName(listing.courtName), display.room, display.item.map { "Item \($0)" }]
            .compactMap { $0 }.joined(separator: " · ")
        HStack(alignment: .top, spacing: Spacing.md) {
            VStack(spacing: 2) {
                Text(block.day)
                    .font(.display(size: 24, relativeTo: .title2))
                    .monospacedDigit()
                    .foregroundStyle(theme.textPrimary)
                Text(block.month)
                    .font(.brand(size: 9.5, weight: .bold, relativeTo: .caption2))
                    .tracking(0.6)
                    .foregroundStyle(theme.textTertiary)
            }
            .padding(.vertical, Spacing.sm)
            .frame(width: min(blockWidth, 84))
            .frame(maxHeight: .infinity)
            .background(theme.surface2, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .strokeBorder(theme.separator, lineWidth: 1))

            VStack(alignment: .leading, spacing: 2) {
                Text(display.reference ?? listing.displayTitle)
                    .font(.brand(.body, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .dynamicLineLimit(1)
                if display.reference != nil {
                    Text(listing.displayTitle)
                        .font(.brand(.footnote))
                        .foregroundStyle(theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !place.isEmpty {
                    StatusPill(text: place)
                        .padding(.top, Spacing.xs)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(DisplayText.longDay(dayKey)). \(display.spoken(listing))")
    }
}

/// A matter in the docket: its title, its reference and court, and its next hearing.
private struct MatterRow: View {
    @Environment(\.theme) private var theme
    let legalCase: LegalCase

    var body: some View {
        let next = legalCase.nextHearingDate.map { "Next date " + MattersOverview.shortDay(WireDate.dayKey($0)) }
        let subtitle = [legalCase.caseReference, legalCase.courtName, next]
            .compactMap { $0 }.joined(separator: " · ")
        RecordRow(
            title: legalCase.displayTitle,
            subtitle: subtitle.isEmpty ? nil : subtitle,
            titleLines: 2
        ) {
            IconTile(systemImage: legalCase.isCourtSynced ? "building.columns" : "scalemass")
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(legalCase.isCourtSynced ? "From court" : "")
    }
}
