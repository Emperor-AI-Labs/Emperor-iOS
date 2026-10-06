import SwiftUI

/// The docket, headed by court in order of importance — or by hearing date, or not at all — in
/// the order and through the filters the user chooses.
///
/// ## Three controls, three jobs
///
/// - **The search bar** finds one of *your* cases. Always on screen, and searching only this
///   docket, inside whatever filters are on.
/// - **Sort & filter** — the toolbar's filter icon, filled while any filter is on — chooses how
///   the docket is laid out. The filters that are on sit under the search bar as chips, each
///   removable, so a narrowed docket never looks like the whole of it.
/// - **Add case** looks a case up at its court and adds it. In words, beside the icon, so it
///   cannot be taken for the search: "+" next to a search field reads as "find more of these".
///
/// Also where another tab sends a matter to be opened — the Calendar does, for a listed case. The
/// stack is bound to `path` so it can be replaced from outside: `AppNavigator` holds the request,
/// and this takes it when it appears or when the request arrives while it is already on screen.
/// Taking clears it, so it is applied once. The case opens on a fresh `CaseDetailView`, whose
/// overview leads the screen.
///
/// ## On an iPad
///
/// At a regular width the docket is a column of its own and the case opens beside it
/// (`ListBesideDetail`), the chosen row tinted; choosing another row replaces the case rather than
/// pushing over it. The docket is the same screen — search, chips, sort & filter, Add case — and
/// so is the case. Both layouts read the one `path`: a phone pushes it, the iPad shows its last
/// element. So a request from the Calendar opens the case on either by replacing the path, and
/// what was open survives the screen changing width. A phone never draws the split.
struct CaseListView: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session
    @Environment(\.navigator) private var navigator
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var model: CaseListViewModel?
    @State private var isSearchingCourts = false
    @State private var isArranging = false
    @State private var path: [CaseRoute] = []

    private typealias Copy = CaseListViewModel.Copy

    var body: some View {
        Group {
            if isBesideDetail {
                ListBesideDetail(detailID: path.last) {
                    docketScreen
                } detail: {
                    if let route = path.last {
                        CaseDetailView(caseID: route.caseID)
                    } else {
                        DetailPlaceholder(placeholder: ListDetailPath.placeholder(
                            ListDetailPath.chooseCase, beside: model?.presentation))
                    }
                }
            } else {
                NavigationStack(path: $path) {
                    docketScreen
                        .navigationDestination(for: CaseRoute.self) { route in
                            CaseDetailView(caseID: route.caseID)
                        }
                }
            }
        }
        // Both, because either can be first: a tab never shown before is created by the switch
        // the request causes, and one already alive sees the request change instead.
        .onAppear { openRequestedCase() }
        .onChange(of: navigator.pendingCase) { _, _ in openRequestedCase() }
    }

    /// The docket in a column of its own, with the case beside it — a regular-width screen.
    private var isBesideDetail: Bool { sizeClass == .regular }

    /// The docket itself, the same in both layouts: its title, toolbar, sheets and model.
    private var docketScreen: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(Copy.title)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let model {
                    arrangeButton(model)
                }
                addCaseButton
            }
        }
        // A page on iPad, not a form sheet: the lookup pushes a forty-eight-court picker, and
        // sort & filter is twenty-odd choices — both were a small panel with most of it below
        // the fold.
        .sheet(isPresented: $isSearchingCourts) {
            CourtSearchView { Task { await model?.load() } }
                .pageSizedSheet()
        }
        .sheet(isPresented: $isArranging) {
            if let model {
                CaseArrangementSheet(model: model)
                    .pageSizedSheet()
            }
        }
        .task {
            guard model == nil else { return }
            let created = CaseListViewModel(
                service: session.cases, cache: session.cache, store: Self.preferences)
            model = created
            await created.load()
        }
    }

    /// The case open beside the docket, as the list's selection. Choosing a row replaces it;
    /// choosing the row already open leaves it be — `ListDetailPath` has the rules.
    private var selectedCaseID: Binding<String?> {
        Binding(
            get: { ListDetailPath.selection(in: path, id: { $0.caseID }) },
            set: { chosen in
                path = ListDetailPath.selecting(
                    chosen, in: path, id: { $0.caseID }, route: { CaseRoute(caseID: $0) })
            })
    }

    private func openRequestedCase() {
        guard let stack = navigator.takePendingCaseStack() else { return }
        path = stack
    }

    /// Where the sort, grouping and filters are remembered between launches.
    private static var preferences: any PreferenceStore {
        #if DEBUG
        if UITestSupport.isActive { return uiTestPreferences }
        #endif
        return Preferences()
    }

    #if DEBUG
    /// `UserDefaults` outlives a UI-test launch — the trap `EmperorApp` documents for the
    /// disclaimer — so a test that filtered the docket would hand its filter to every test after
    /// it, and a case those tests open would simply not be there. Under test the layout is
    /// remembered for one launch; across launches it is `CaseListOrganisationTests`' to prove.
    private static let uiTestPreferences = InMemoryPreferenceStore()
    #endif

    // MARK: - Toolbar

    private func arrangeButton(_ model: CaseListViewModel) -> some View {
        Button {
            isArranging = true
        } label: {
            // Filled while a filter is on: the one sign, from anywhere on the list, that what is
            // showing is not the whole docket.
            Image(systemName: model.filters.isEmpty
                  ? "line.3.horizontal.decrease.circle"
                  : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityLabel(Copy.arrange)
        .accessibilityValue(model.filterSummary)
        .accessibilityIdentifier("case-sort-filter")
    }

    /// A composed label rather than `Label`: a toolbar draws a `Label` as its icon alone, and the
    /// words are the point.
    private var addCaseButton: some View {
        Button {
            isSearchingCourts = true
        } label: {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "plus")
                Text(Copy.addCase)
            }
            .font(.brand(.body, weight: .semibold))
        }
        .accessibilityLabel(Copy.addCase)
        .accessibilityHint("Finds a case at its court and adds it to this list")
    }

    // MARK: - The list

    @ViewBuilder
    private func content(_ model: CaseListViewModel) -> some View {
        @Bindable var bindable = model

        // `presentation` reads the whole docket, so `empty` below is only ever "you have no
        // matters". A docket the search and filters have emptied is drawn here instead, with the
        // chips still on screen — they are how it is undone.
        ListStateView(presentation: model.presentation, retry: { await model.load() }) {
            Group {
                if let noMatches = model.noMatches {
                    EmptyStateView(
                        noMatches.title,
                        systemImage: "line.3.horizontal.decrease.circle",
                        message: noMatches.message) {
                        Button(noMatches.action) {
                            model.clearSearchAndFilters()
                        }
                        .buttonStyle(.primaryAction)
                        .accessibilityIdentifier("case-no-matches-clear")
                    }
                } else {
                    docket(model)
                }
            }
            .background(theme.canvas)
        } empty: {
            EmptyStateView(
                Copy.noMattersTitle,
                systemImage: "briefcase",
                message: Copy.noMattersMessage) {
                Button {
                    isSearchingCourts = true
                } label: {
                    Label(Copy.addCase, systemImage: "plus")
                }
                .buttonStyle(.primaryAction)
            }
        }
        .searchable(
            text: $bindable.query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: Copy.searchPrompt)
        .refreshable { await model.load() }
    }

    /// The list, bound to the open case on an iPad. Not on a phone, where a row pushes and the
    /// list has no selection to show.
    private func docket(_ model: CaseListViewModel) -> some View {
        Group {
            if isBesideDetail {
                List(selection: selectedCaseID) {
                    docketSections(model)
                }
            } else {
                List {
                    docketSections(model)
                }
            }
        }
        // Named so a UI test on iPad can scroll the docket itself; the middle of that screen is
        // the case's column.
        .accessibilityIdentifier("case-docket")
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.canvas)
    }

    @ViewBuilder
    private func docketSections(_ model: CaseListViewModel) -> some View {
        // The active filters, as the list's first row. Not a `safeAreaInset` above the list:
        // on iOS 26 the navigation bar's scroll-edge effect covers that band, and the chips
        // were laid out — leaving their gap — but never seen. In the list they scroll away
        // with it; the filled toolbar icon still says a filter is on.
        if !model.filterChips.isEmpty {
            Section {
                FilterChipBar(
                    chips: model.filterChips,
                    remove: { model.remove($0) },
                    clearAll: { model.clearFilters() })
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        ForEach(model.groups) { group in
            Section {
                ForEach(group.cases) { legalCase in
                    let isOpen = isBesideDetail && path.last?.caseID == legalCase.id
                    caseLink(legalCase)
                        .accessibilityIdentifier("case-row-\(legalCase.id)")
                        .accessibilityAddTraits(isOpen ? .isSelected : [])
                        // On the row rather than the section, so the open case's can differ.
                        .listRowBackground(ListRowCard(isSelected: isOpen))
                }
            } header: {
                // Named by key, not by its words: "Supreme Court" is also the start of a
                // court's name on a row, and the order test reads headings alone.
                SectionHeader(title: group.title, detail: "\(group.cases.count)")
                    .accessibilityIdentifier("case-group-\(group.key)")
            }
        }
    }

    /// A phone pushes the case's route. Beside the detail the link carries the case's id instead,
    /// which the list takes as its selection rather than pushing anything.
    @ViewBuilder
    private func caseLink(_ legalCase: LegalCase) -> some View {
        if isBesideDetail {
            NavigationLink(value: legalCase.id) {
                row(legalCase)
            }
        } else {
            NavigationLink(value: CaseRoute(caseID: legalCase.id)) {
                row(legalCase)
            }
        }
    }

    private func row(_ legalCase: LegalCase) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs + 1) {
            Text(legalCase.displayTitle)
                .font(.brand(.headline))
                .foregroundStyle(theme.textPrimary)
                .dynamicLineLimit(2)

            // Reference and court side by side, or one over the other at the accessibility sizes,
            // where one line holds neither. The court is never cut short: in an iPad's docket
            // column "Supreme Court of India" came out as "Supreme Court of I…", so it wraps.
            AdaptiveStack(verticalAlignment: .firstTextBaseline, spacing: 6) {
                if let reference = legalCase.caseReference {
                    Text(reference)
                        .monospacedDigit()
                }
                if let court = legalCase.courtName {
                    if !dynamicTypeSize.isAccessibilitySize {
                        // Raised off the baseline to the middle of the letters, as a "·" sits.
                        SeparatorDot()
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
                    }
                    Text(court)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.brand(.subheadline))
            .foregroundStyle(theme.textSecondary)

            AdaptiveStack(spacing: Spacing.sm) {
                if let hearing = legalCase.nextHearingDate {
                    Label {
                        Text(DisplayText.longDay(WireDate.dayKey(hearing)))
                    } icon: {
                        Image(systemName: "calendar")
                            .foregroundStyle(theme.accentText)
                    }
                }
                // Says where the row came from. A matter the court maintains and one typed in
                // by hand carry very different confidence, and the badge is the only signal.
                if legalCase.isCourtSynced {
                    StatusPill(
                        text: "From court", tone: .accent, systemImage: "building.columns")
                }
            }
            .font(.brand(.caption))
            .foregroundStyle(theme.textSecondary)

            if let stage = legalCase.stage ?? legalCase.status {
                Text(stage).font(.brand(.caption2)).foregroundStyle(theme.textTertiary)
            }
        }
        .padding(.vertical, Spacing.xs)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Filter chips

/// The filters that are on, under the search bar, each removable on its own, with a way to clear
/// them all. Scrolls sideways rather than wrapping, so however many are on it takes one line and
/// leaves the docket where it was.
private struct FilterChipBar: View {
    @Environment(\.theme) private var theme

    let chips: [CaseFilterChip]
    let remove: (CaseFilterChip) -> Void
    let clearAll: () -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Spacing.sm) {
                ForEach(chips) { chip in
                    Button {
                        remove(chip)
                    } label: {
                        HStack(spacing: Spacing.xs + 1) {
                            Text(chip.label)
                                .lineLimit(1)
                            Image(systemName: "xmark")
                                .imageScale(.small)
                                .accessibilityHidden(true)
                        }
                        .font(.brand(.footnote, weight: .semibold))
                        .foregroundStyle(theme.accentText)
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, 6)
                        .background(theme.accentWash, in: Capsule())
                        .overlay(Capsule().strokeBorder(theme.accentText.opacity(0.22), lineWidth: 0.5))
                        // Drawn as a small capsule, answering a touch across the full 44 points.
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove filter: \(chip.label)")
                    .accessibilityIdentifier("case-filter-chip-\(chip.id)")
                }

                // The padding and the 44-point frame inside the label, so the whole of it takes
                // the tap rather than the words alone.
                Button(action: clearAll) {
                    Text(CaseListViewModel.Copy.clearAll)
                        .font(.brand(.footnote, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                        .padding(.horizontal, Spacing.xs)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("case-filters-clear-all")
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.sm)
        }
        .scrollIndicators(.hidden)
        .background(theme.canvas)
    }
}

// MARK: - Sort & filter

/// Sort, grouping and every filter, in one sheet.
///
/// A sheet rather than a `Menu`, for three reasons. The court filter is several choices made at
/// once, and a menu closes on every tap, so choosing three courts would mean opening it three
/// times. Five sorts, three groupings and up to thirteen filters is more than a menu can show
/// without scrolling inside a popover. And a sheet has room to say how many cases each choice
/// holds, which is what tells someone a filter is worth choosing.
///
/// Full height, not a half-height detent. Twenty-odd choices do not fit in half a phone, and on
/// iPad a detent turns the sheet into a small panel with the grouping and every filter below the
/// fold — the screen shows its first section and looks like a sort menu. The standard sheet is
/// the whole list on a phone and a form sheet on iPad.
private struct CaseArrangementSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let model: CaseListViewModel

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            List {
                Section {
                    Picker("Sort by", selection: $model.sort) {
                        ForEach(CaseSort.allCases) { sort in
                            Text(sort.label).tag(sort)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    SectionHeader(title: "Sort by")
                }
                .listRowBackground(theme.surface)

                Section {
                    Picker("Group by", selection: $model.grouping) {
                        ForEach(CaseGrouping.allCases) { grouping in
                            Text(grouping.label).tag(grouping)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .listRowBackground(Color.clear)
                } header: {
                    SectionHeader(title: "Group by")
                }

                filterSection("Court", options: model.courtTierOptions.map(CaseFilterChip.court))
                filterSection("Hearing", options: HearingFilter.allCases.map(CaseFilterChip.hearing))
                filterSection("Source", options: SourceFilter.allCases.map(CaseFilterChip.source))
            }
            .font(.brand(.body))
            // Named so the UI tests can scroll this list, never the docket behind the sheet.
            .accessibilityIdentifier("case-arrangement-form")
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.canvas)
            .navigationTitle(CaseListViewModel.Copy.arrangeTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") { model.resetOptions() }
                        .disabled(model.isAtDefaults)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// Checkmark rows, each with the number of cases it holds across the whole docket.
    @ViewBuilder
    private func filterSection(_ title: String, options: [CaseFilterChip]) -> some View {
        if !options.isEmpty {
            Section {
                ForEach(options) { option in
                    filterRow(option)
                }
            } header: {
                SectionHeader(title: title)
            }
            .listRowBackground(theme.surface)
        }
    }

    private func filterRow(_ option: CaseFilterChip) -> some View {
        let isOn = model.isOn(option)
        let count = model.count(for: option)
        let spokenCount: String = count == 1 ? "1 case" : "\(count) cases"
        return Button {
            model.toggle(option)
        } label: {
            HStack(spacing: Spacing.md) {
                Text(option.optionLabel)
                    .foregroundStyle(theme.textPrimary)
                Spacer(minLength: Spacing.sm)
                Text("\(count)")
                    .font(.brand(.subheadline))
                    .monospacedDigit()
                    .foregroundStyle(theme.textTertiary)
                // Always laid out, shown only when on, so the counts stay in one column.
                Image(systemName: "checkmark")
                    .font(.brand(.subheadline, weight: .semibold))
                    .foregroundStyle(theme.accentText)
                    .opacity(isOn ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.optionLabel)
        .accessibilityValue(spokenCount)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("case-filter-\(option.id)")
    }
}
