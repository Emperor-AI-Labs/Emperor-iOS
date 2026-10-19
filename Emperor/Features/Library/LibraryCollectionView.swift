import SwiftUI

// One collection, browsed — the web's `CategoryBrowser` and `books/CoverGrid`, with each
// collection's own front room: Books' series shelves, the institutes' three shelves, Parliament's
// papers by kind, Legal aid's handful of documents. Case law and Bare Acts have their own views.

struct LibraryCollectionView: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session

    let category: LibraryCategoryCount
    var query = ""
    @Binding var path: [LibraryRoute]

    @State private var model: LibraryCollectionViewModel?

    var body: some View {
        Group {
            if let model {
                LibraryCollectionBody(model: model, path: $path)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(category.theme.label)
        .navigationBarTitleDisplayMode(.inline)
        .background(theme.canvas)
        .task {
            guard model == nil else { return }
            let created = LibraryCollectionViewModel(category: category, query: query, service: session.library)
            model = created
            await created.load()
        }
    }
}

private struct LibraryCollectionBody: View {
    @Environment(\.theme) private var theme
    let model: LibraryCollectionViewModel
    @Binding var path: [LibraryRoute]

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                LibraryCollectionHeader(theme: model.theme, count: model.category.count)
                if let series = model.openSeries {
                    LibrarySeriesPage(model: model, series: series, path: $path)
                } else if model.showsOverview {
                    LibraryCollectionOverview(model: model, path: $path)
                } else {
                    LibraryCollectionBrowser(model: model, path: $path)
                }
            }
            .padding(.bottom, Spacing.xxxl)
        }
        .searchable(text: $model.query, placement: .navigationBarDrawer(displayMode: .automatic),
                    prompt: "Search \(model.theme.label.lowercased())")
        .onSubmit(of: .search) { Task { await model.search() } }
        .onChange(of: model.query) { _, text in
            if text.trimmingCharacters(in: .whitespaces).isEmpty, model.state.hasLoaded { Task { await model.clearQuery() } }
        }
    }
}

/// The collection's name, icon and one plain sentence.
struct LibraryCollectionHeader: View {
    @Environment(\.theme) private var appTheme
    let theme: LibraryCollectionTheme
    var count: Int?

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Image(systemName: theme.systemImage)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Color(theme.ink(dark: appTheme.isDark)))
                .frame(width: 44, height: 44)
                .background(Color(theme.ink(dark: appTheme.isDark)).opacity(0.1), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                    Text(theme.label)
                        .font(.display(size: 24, relativeTo: .title2))
                        .foregroundStyle(appTheme.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    if let count, count > 0 {
                        Text(LibraryTitles.count(count))
                            .font(.brand(.caption, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(appTheme.textTertiary)
                    }
                }
                Text(theme.blurb)
                    .font(.brand(.footnote))
                    .foregroundStyle(appTheme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Spacing.gutter)
        .padding(.vertical, Spacing.lg)
    }
}

/// The paged grid or list, under its facets, sort and count.
private struct LibraryCollectionBrowser: View {
    @Environment(\.theme) private var theme
    let model: LibraryCollectionViewModel
    @Binding var path: [LibraryRoute]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            if model.profile.overview == .seriesShelves {
                LibraryBooksSwitch(model: model)
            }
            LibraryFacetRows(model: model)
            LibraryCollectionToolbar(model: model)
            LibraryCollectionResults(model: model, path: $path)
        }
    }
}

/// Shelves ↔ All books, A–Z.
private struct LibraryBooksSwitch: View {
    let model: LibraryCollectionViewModel

    var body: some View {
        RecordSegmentedControl(
            label: "How to browse",
            options: [(value: false, title: LibraryCollectionViewModel.Copy.shelves), (value: true, title: LibraryCollectionViewModel.Copy.allBooks)],
            selection: Binding(
                get: { model.showsAllBooks || !model.showsOverview },
                set: { all in
                    model.showsAllBooks = all
                    Task {
                        if all { await model.reload() } else { await model.clearFilters(); await model.loadOverviewIfNeeded() }
                    }
                }))
            .padding(.horizontal, Spacing.gutter)
    }
}

/// The facet rows the collection offers, each a row of chips (years as two fields).
struct LibraryFacetRows: View {
    let model: LibraryCollectionViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            ForEach(model.facetRows, id: \.rawValue) { facet in
                row(facet)
            }
        }
    }

    @ViewBuilder
    private func row(_ facet: LibraryCollectionProfile.Facet) -> some View {
        switch facet {
        case .years:
            if let range = model.yearRange {
                LibraryYearRangeRow(range: range, from: model.filters.yearFrom, to: model.filters.yearTo) { from, to in
                    Task { await model.setYears(from: from, to: to) }
                }
            }
        case .letters:
            VStack(alignment: .leading, spacing: Spacing.xs) {
                LibraryCapLabel(text: model.profile.label(for: .letters)).padding(.horizontal, Spacing.gutter)
                LibraryLetterRow(letters: model.letters, selection: model.filters.letter) { letter in
                    Task { await model.setLetter(letter) }
                }
            }
        case .courts:
            LibraryFacetChipsRow(
                label: model.profile.label(for: facet), options: model.options(for: facet), selection: model.selection(for: facet),
                allLabel: "All courts", labelFor: { CaseLawVocabulary.court($0.value, label: $0.label).short },
                onPick: { value in Task { await model.select(facet, value: value) } })
        default:
            LibraryFacetChipsRow(
                label: model.profile.label(for: facet), options: model.options(for: facet), selection: model.selection(for: facet),
                onPick: { value in Task { await model.select(facet, value: value) } })
        }
    }
}

/// The count line, the active filters, the sort and the layout switch.
struct LibraryCollectionToolbar: View {
    @Environment(\.theme) private var theme
    let model: LibraryCollectionViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                if let line = model.countLine {
                    Text(line)
                        .font(.brand(.footnote, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                        .accessibilityAddTraits(.updatesFrequently)
                } else if model.state.isLoading {
                    Text("Loading…").font(.brand(.footnote)).foregroundStyle(theme.textTertiary)
                }
                Spacer(minLength: Spacing.sm)
                if !model.sortOptions.isEmpty {
                    LibrarySortMenu(model: model)
                }
                LibraryLayoutSwitch(model: model)
            }
            .padding(.horizontal, Spacing.gutter)
            if !model.activeFilters.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.xs) {
                        ForEach(model.activeFilters) { filter in
                            Button {
                                Task { await model.clear(filter.facet) }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "xmark").imageScale(.small)
                                    Text(filter.label)
                                }
                            }
                            .buttonStyle(ChipButtonStyle(isSelected: true))
                            .accessibilityLabel("Remove filter \(filter.label)")
                        }
                        if model.activeFilters.count > 1 {
                            Button("Clear all") { Task { await model.clearFilters() } }
                                .buttonStyle(ChipButtonStyle(isSelected: false))
                        }
                    }
                    .padding(.horizontal, Spacing.gutter)
                }
            }
            if let note = model.indexNote {
                Text(note)
                    .font(.brand(.caption2))
                    .foregroundStyle(theme.textTertiary)
                    .padding(.horizontal, Spacing.gutter)
            }
        }
    }
}

struct LibrarySortMenu: View {
    @Environment(\.theme) private var theme
    let model: LibraryCollectionViewModel

    var body: some View {
        Menu {
            Picker("Sort", selection: Binding(
                get: { model.currentSort },
                set: { value in Task { await model.setSort(value.isEmpty ? nil : value) } }
            )) {
                ForEach(model.sortOptions) { option in
                    Text(option.label).tag(option.value)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down").imageScale(.small)
                Text(model.sortOptions.first { $0.value == model.currentSort }?.label ?? "Sort")
            }
            .font(.brand(.caption, weight: .semibold))
            .foregroundStyle(theme.accentText)
        }
        .accessibilityLabel("Sort by")
    }
}

struct LibraryLayoutSwitch: View {
    @Environment(\.theme) private var theme
    let model: LibraryCollectionViewModel

    var body: some View {
        HStack(spacing: 0) {
            toggle(.grid, symbol: "square.grid.2x2", label: "Covers")
            toggle(.list, symbol: "list.bullet", label: "List")
        }
        .background(theme.surface, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(theme.borderStrong, lineWidth: 1))
    }

    private func toggle(_ layout: LibraryCollectionProfile.Layout, symbol: String, label: String) -> some View {
        let on = model.layout == layout
        return Button {
            Task { await model.setLayout(layout) }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(on ? theme.accentText : theme.textTertiary)
                .frame(width: 34, height: 30)
                .background(on ? theme.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The documents: a grid of covers or a list of rows, with honest empty and failed states.
struct LibraryCollectionResults: View {
    @Environment(\.theme) private var theme
    let model: LibraryCollectionViewModel
    @Binding var path: [LibraryRoute]

    var body: some View {
        Group {
            if let failure = model.state.failure {
                LibraryEmptyView(title: "This shelf could not be loaded", hint: failure.message, isError: true) {
                    if failure.isRetryable {
                        Button("Try again") { Task { await model.reload() } }.buttonStyle(.compactSecondaryAction)
                    }
                }
            } else if model.state.isLoading && model.documents.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, Spacing.xxl)
            } else if model.documents.isEmpty && model.state.hasLoaded {
                LibraryEmptyView(title: model.emptyTitle, hint: model.emptyHint) {
                    if model.filters.activeFilterCount > 0 {
                        Button("Clear filters") { Task { await model.clearFilters() } }.buttonStyle(.compactSecondaryAction)
                    }
                }
            } else if model.layout == .list {
                list
            } else {
                grid
            }
        }
        .opacity(model.state.isLoading && !model.documents.isEmpty ? 0.55 : 1)
        .animation(.easeOut(duration: 0.15), value: model.state.isLoading)
    }

    private var grid: some View {
        LazyVGrid(columns: LibraryGrid.columns, alignment: .leading, spacing: Spacing.lg) {
            ForEach(model.documents) { doc in
                LibraryDocCard(doc: doc, caption: model.caption(for: doc)) { path.append(LibraryRoute.open($0)) }
            }
            LibraryLoadMoreFooter(isLoading: model.isLoadingMore, canLoadMore: model.canLoadMore) { await model.loadMore() }
        }
        .padding(.horizontal, Spacing.gutter)
        .padding(.top, Spacing.sm)
    }

    private var list: some View {
        LazyVStack(spacing: 0) {
            ForEach(model.documents) { doc in
                LibraryDocCard(doc: doc, variant: .list, caption: model.caption(for: doc), badge: doc.courtLabel, query: model.query) {
                    path.append(LibraryRoute.open($0))
                }
                RecordDivider(inset: 14)
            }
            LibraryLoadMoreFooter(isLoading: model.isLoadingMore, canLoadMore: model.canLoadMore) { await model.loadMore() }
        }
        .padding(.horizontal, Spacing.gutter)
    }
}

// MARK: - Front rooms

/// What a collection shows before a search or a filter.
private struct LibraryCollectionOverview: View {
    @Environment(\.theme) private var theme
    let model: LibraryCollectionViewModel
    @Binding var path: [LibraryRoute]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            if model.profile.overview == .seriesShelves { LibraryBooksSwitch(model: model) }
            if let failure = model.overviewState.failure {
                LibraryEmptyView(title: "These shelves could not be loaded", hint: failure.message, isError: true) {
                    Button("Browse everything instead") { model.showsAllBooks = true; Task { await model.reload() } }
                        .buttonStyle(.compactSecondaryAction)
                }
            } else if model.overviewState.isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, Spacing.xxl)
            } else {
                switch model.profile.overview {
                case .seriesShelves: LibrarySeriesShelvesView(model: model, path: $path)
                case .publisherShelves: LibraryInstituteShelves(model: model, path: $path)
                case .groupedByKind: LibraryKindGroups(model: model, path: $path)
                case .feature: LibraryFeatureList(model: model, path: $path)
                case .browse: EmptyView()
                }
            }
        }
    }
}

/// Books: one shelf per notable series, "Standalone books", and an index of every series.
private struct LibrarySeriesShelvesView: View {
    @Environment(\.theme) private var theme
    let model: LibraryCollectionViewModel
    @Binding var path: [LibraryRoute]

    var body: some View {
        let ink = Color(model.theme.ink(dark: theme.isDark))
        VStack(alignment: .leading, spacing: Spacing.xl) {
            if let shelves = model.seriesShelves {
                Text("\(LibraryTitles.count(model.category.count ?? 0)) volumes. Law reports and journals stand together by series, in volume order; \(LibraryTitles.count(shelves.seriesTotal ?? shelves.shelves.count)) series in all.")
                    .font(.brand(.footnote))
                    .foregroundStyle(theme.textFaint)
                    .padding(.horizontal, Spacing.gutter)
                ForEach(shelves.shelves) { shelf in
                    LibraryShelfRow(
                        title: LibraryBooksFormat.seriesName(shelf.series),
                        blurb: ["\(LibraryTitles.count(shelf.count ?? shelf.items.count)) volumes", LibraryBooksFormat.yearSpan(shelf.yearMin, shelf.yearMax)].filter { !$0.isEmpty }.joined(separator: " · "),
                        ink: ink, onSeeAll: { Task { await model.open(series: shelf.series) } }
                    ) {
                        ForEach(shelf.items) { doc in
                            LibraryDocCard(doc: doc, caption: model.shelfCaption(for: doc, series: shelf.series)) { path.append(.document($0)) }
                                .frame(width: 148)
                        }
                    }
                }
                if let standalone = shelves.standalone, !standalone.items.isEmpty {
                    LibraryShelfRow(
                        title: LibraryCollectionViewModel.Copy.standalone, blurb: LibraryCollectionViewModel.Copy.standaloneBlurb,
                        count: standalone.count, ink: ink, onSeeAll: { model.showsAllBooks = true; Task { await model.reload() } }
                    ) {
                        ForEach(standalone.items) { doc in
                            LibraryDocCard(doc: doc, caption: model.caption(for: doc)) { path.append(.document($0)) }
                                .frame(width: 148)
                        }
                    }
                }
            }
            if !model.allSeries.isEmpty {
                LibrarySeriesIndex(series: model.allSeries) { name in Task { await model.open(series: name) } }
            }
        }
    }
}

/// Every series the facets know: a tappable list with counts.
private struct LibrarySeriesIndex: View {
    @Environment(\.theme) private var theme
    let series: [LibraryFacetOption]
    let onOpen: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            LibrarySectionHeading(title: LibraryCollectionViewModel.Copy.everySeries,
                                  blurb: "\(LibraryTitles.count(series.count)) runs of two or more volumes")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: Spacing.sm, alignment: .leading)], alignment: .leading, spacing: 0) {
                ForEach(series) { option in
                    Button {
                        onOpen(option.value)
                    } label: {
                        HStack {
                            Text(LibraryBooksFormat.seriesName(option.value))
                                .font(.brand(.footnote))
                                .foregroundStyle(theme.textPrimary)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: Spacing.sm)
                            Text(LibraryTitles.count(option.count ?? 0))
                                .font(.brand(.caption2))
                                .monospacedDigit()
                                .foregroundStyle(theme.textTertiary)
                        }
                        .padding(.vertical, Spacing.sm)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, Spacing.gutter)
    }
}

/// A series opened from the shelves: every volume, by decade.
private struct LibrarySeriesPage: View {
    @Environment(\.theme) private var theme
    let model: LibraryCollectionViewModel
    let series: String
    @Binding var path: [LibraryRoute]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Button {
                model.closeSeries()
            } label: {
                Label("All shelves", systemImage: "arrow.left")
                    .font(.brand(.footnote, weight: .semibold))
                    .foregroundStyle(theme.accentText)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Spacing.gutter)
            VStack(alignment: .leading, spacing: 4) {
                LibraryCapLabel(text: "Series")
                Text(LibraryBooksFormat.seriesName(series))
                    .font(.display(size: 24, relativeTo: .title2))
                    .foregroundStyle(theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(model.seriesLine)
                    .font(.brand(.footnote))
                    .foregroundStyle(theme.textFaint)
            }
            .padding(.horizontal, Spacing.gutter)
            if let failure = model.seriesState.failure {
                LibraryEmptyView(title: "This series could not be loaded", hint: failure.message, isError: true)
            } else if model.seriesState.isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, Spacing.xxl)
            } else if model.seriesVolumes.isEmpty {
                LibraryEmptyView(title: "No volumes in this series", hint: "The series name may have changed. Go back to the shelves.")
            } else {
                ForEach(model.seriesGroups) { group in
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        if model.seriesGroups.count > 1 {
                            LibrarySectionHeading(title: group.label, count: group.items.count).padding(.horizontal, Spacing.gutter)
                        }
                        LazyVGrid(columns: LibraryGrid.columns, alignment: .leading, spacing: Spacing.lg) {
                            ForEach(group.items) { doc in
                                LibraryDocCard(doc: doc, caption: model.caption(for: doc)) { path.append(.document($0)) }
                            }
                        }
                        .padding(.horizontal, Spacing.gutter)
                    }
                }
            }
        }
    }
}

/// Professional institutes: ICAI, ICSI and ICMAI as three shelves.
private struct LibraryInstituteShelves: View {
    @Environment(\.theme) private var theme
    let model: LibraryCollectionViewModel
    @Binding var path: [LibraryRoute]

    var body: some View {
        let ink = Color(model.theme.ink(dark: theme.isDark))
        VStack(alignment: .leading, spacing: Spacing.xl) {
            ForEach(LibraryCollectionViewModel.institutes, id: \.key) { institute in
                let items = model.institute(institute.label)
                if !items.isEmpty {
                    LibraryShelfRow(
                        title: "\(institute.label) · \(institute.name.replacingOccurrences(of: "The ", with: ""))",
                        blurb: institute.blurb, count: items.count, ink: ink,
                        onSeeAll: { Task { await model.setPublisher(institute.key) } }
                    ) {
                        ForEach(items) { doc in
                            LibraryDocCard(doc: doc, caption: model.caption(for: doc)) { path.append(.document($0)) }
                                .frame(width: 148)
                        }
                    }
                }
            }
        }
    }
}

/// Parliament: the papers grouped by what each is.
private struct LibraryKindGroups: View {
    let model: LibraryCollectionViewModel
    @Binding var path: [LibraryRoute]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            ForEach(model.kindGroups) { group in
                VStack(alignment: .leading, spacing: 0) {
                    LibrarySectionHeading(title: group.label, count: group.items.count)
                        .padding(.bottom, Spacing.xs)
                    ForEach(group.items) { doc in
                        LibraryDocCard(doc: doc, variant: .list, caption: model.caption(for: doc), badge: group.label) { path.append(.document($0)) }
                        RecordDivider(inset: 14)
                    }
                }
                .padding(.horizontal, Spacing.gutter)
            }
        }
    }
}

/// Legal aid: each document large, with its whole title and a clear way in.
private struct LibraryFeatureList: View {
    @Environment(\.theme) private var theme
    let model: LibraryCollectionViewModel
    @Binding var path: [LibraryRoute]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            ForEach(model.overviewItems) { doc in
                let caption = model.caption(for: doc)
                Button {
                    path.append(.document(doc))
                } label: {
                    HStack(alignment: .top, spacing: Spacing.lg) {
                        LibraryCoverView(doc: doc, size: .medium)
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            LibraryCapLabel(text: caption.eyebrow ?? "")
                            Text(caption.title)
                                .font(.display(size: 18, relativeTo: .headline))
                                .foregroundStyle(theme.textPrimary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            if !caption.meta.isEmpty {
                                Text(caption.meta.joined(separator: " · "))
                                    .font(.brand(.caption))
                                    .foregroundStyle(theme.textTertiary)
                            }
                            Label("Read", systemImage: "arrow.right")
                                .font(.brand(.footnote, weight: .semibold))
                                .foregroundStyle(theme.accentText)
                                .padding(.top, Spacing.xs)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(caption.title))
            }
            if model.overviewState.hasLoaded {
                Text(model.featureNote)
                    .font(.brand(.footnote))
                    .foregroundStyle(theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Spacing.gutter)
    }
}
