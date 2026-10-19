import SwiftUI

// Bare Acts — the web's `categories/BareActs.jsx` and `act/ActPage.jsx`: an index that reads like
// the index of a statute book (A–Z, jurisdiction chips, "Contains", the codes on a shelf), and
// the statute reading room (the Act with everything made under it, one tab each).

struct BareActsIndexView: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session

    let category: LibraryCategoryCount
    var query = ""
    @Binding var path: [LibraryRoute]

    @State private var model: BareActsIndexViewModel?

    var body: some View {
        Group {
            if let model {
                BareActsIndexBody(model: model, path: $path)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(BareActsIndexViewModel.Copy.heading)
        .navigationBarTitleDisplayMode(.inline)
        .background(theme.canvas)
        .task {
            guard model == nil else { return }
            let created = BareActsIndexViewModel(query: query, collectionCount: category.count, service: session.library)
            model = created
            await created.load()
        }
    }
}

private struct BareActsIndexBody: View {
    @Environment(\.theme) private var theme
    let model: BareActsIndexViewModel
    @Binding var path: [LibraryRoute]

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.md) {
                header
                if model.isBrowsing {
                    BareActsFeaturedShelf(model: model, path: $path)
                }
                BareActsControls(model: model)
                BareActsResults(model: model, path: $path)
            }
            .padding(.bottom, Spacing.xxxl)
        }
        .searchable(text: $model.query, placement: .navigationBarDrawer(displayMode: .always), prompt: BareActsIndexViewModel.Copy.searchPrompt)
        .onSubmit(of: .search) { Task { await model.search() } }
        .onChange(of: model.query) { _, text in
            if text.trimmingCharacters(in: .whitespaces).isEmpty, model.state.hasLoaded { Task { await model.search() } }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            LibraryCollectionHeader(theme: LibraryCollection.bareActs.theme, count: nil)
            if let stat = model.headerStat {
                Text(stat)
                    .font(.brand(.footnote, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, Spacing.gutter)
            }
        }
    }
}

/// "On every advocate's desk": the Constitution and the codes, on the shelf.
private struct BareActsFeaturedShelf: View {
    @Environment(\.theme) private var theme
    let model: BareActsIndexViewModel
    @Binding var path: [LibraryRoute]

    var body: some View {
        if model.featuredState.isLoading || !model.featured.isEmpty {
            LibraryShelfRow(title: BareActsIndexViewModel.Copy.featuredTitle, blurb: BareActsIndexViewModel.Copy.featuredBlurb,
                            ink: Color(LibraryCollection.bareActs.theme.ink(dark: theme.isDark)), onSeeAll: nil) {
                if model.featured.isEmpty {
                    ForEach(0..<5, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 3).fill(theme.surface2).frame(width: 148, height: 197)
                    }
                } else {
                    ForEach(model.featured) { doc in
                        ActCard(doc: doc, first: model.has) { path.append(.act(id: $0.id, seed: $0)) }
                            .frame(width: 148)
                    }
                }
            }
        }
    }
}

/// Jurisdiction chips, the "Contains" filter, sort and layout, the A–Z bar, the count line.
private struct BareActsControls: View {
    @Environment(\.theme) private var theme
    let model: BareActsIndexViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if !model.jurisdictions.isEmpty {
                LibraryFacetChipsRow(label: "Jurisdiction", options: model.jurisdictions, selection: model.jurisdiction,
                                     onPick: { value in Task { await model.pick(jurisdiction: value) } })
            }
            VStack(alignment: .leading, spacing: Spacing.xs) {
                LibraryCapLabel(text: BareActsIndexViewModel.Copy.contains).padding(.horizontal, Spacing.gutter)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.xs + 2) {
                        ForEach(LibraryActText.hasFilters, id: \.key) { filter in
                            LibraryChip(title: filter.label, isSelected: model.has == filter.key) {
                                Task { await model.pick(has: filter.key) }
                            }
                        }
                    }
                    .padding(.horizontal, Spacing.gutter)
                    .padding(.vertical, 2)
                }
            }
            if !model.letters.isEmpty {
                LibraryLetterRow(letters: model.letters, selection: model.letter) { letter in
                    Task { await model.pick(letter: letter) }
                }
            }
            HStack(alignment: .firstTextBaseline) {
                if let line = model.countLine {
                    Text(line).font(.brand(.footnote, weight: .medium)).foregroundStyle(theme.textSecondary)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                if model.isFiltered {
                    Button("Clear filters") { Task { await model.clearFilters() } }
                        .font(.brand(.caption, weight: .semibold))
                        .foregroundStyle(theme.accentText)
                        .buttonStyle(.plain)
                }
                Spacer()
                Menu {
                    Picker("Sort", selection: Binding(get: { model.sort }, set: { value in Task { await model.set(sort: value) } })) {
                        ForEach(BareActsIndexViewModel.Sort.allCases) { sort in
                            Text(sort.label).tag(sort)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.arrow.down").imageScale(.small)
                        Text(model.sort.label)
                    }
                    .font(.brand(.caption, weight: .semibold))
                    .foregroundStyle(theme.accentText)
                }
                .accessibilityLabel("Sort by")
                Button {
                    model.showsList.toggle()
                } label: {
                    Image(systemName: model.showsList ? "square.grid.2x2" : "list.bullet")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.accentText)
                        .frame(width: 34, height: 30)
                        .background(theme.surface, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(theme.borderStrong, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.showsList ? "Show as covers" : "Show as a list")
            }
            .padding(.horizontal, Spacing.gutter)
        }
    }
}

private struct BareActsResults: View {
    @Environment(\.theme) private var theme
    let model: BareActsIndexViewModel
    @Binding var path: [LibraryRoute]

    var body: some View {
        Group {
            if let failure = model.state.failure {
                LibraryEmptyView(title: "The index could not be loaded", hint: failure.message, isError: true) {
                    if failure.isRetryable { Button("Try again") { Task { await model.reload() } }.buttonStyle(.compactSecondaryAction) }
                }
            } else if model.state.isLoading && model.items.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, Spacing.xxl)
            } else if model.items.isEmpty && model.state.hasLoaded {
                LibraryEmptyView(title: BareActsIndexViewModel.Copy.empty, hint: model.emptyHint) {
                    if model.isFiltered { Button("Clear filters") { Task { await model.clearFilters() } }.buttonStyle(.compactSecondaryAction) }
                }
            } else if model.showsList {
                LazyVStack(spacing: 0) {
                    ForEach(model.items) { doc in
                        ActRow(doc: doc, first: model.has) { path.append(.act(id: $0.id, seed: $0)) }
                        RecordDivider(inset: 14)
                    }
                    LibraryLoadMoreFooter(isLoading: model.isLoadingMore, canLoadMore: model.canLoadMore) { await model.loadMore() }
                }
                .padding(.horizontal, Spacing.gutter)
            } else {
                LazyVGrid(columns: LibraryGrid.columns, alignment: .leading, spacing: Spacing.lg) {
                    ForEach(model.items) { doc in
                        ActCard(doc: doc, first: model.has) { path.append(.act(id: $0.id, seed: $0)) }
                    }
                    LibraryLoadMoreFooter(isLoading: model.isLoadingMore, canLoadMore: model.canLoadMore) { await model.loadMore() }
                }
                .padding(.horizontal, Spacing.gutter)
            }
        }
        .opacity(model.state.isLoading && !model.items.isEmpty ? 0.55 : 1)
    }
}

/// One Act in the grid: the cover standing up, title and facts underneath.
struct ActCard: View {
    let doc: CatalogueDocument
    var first: String?
    let onOpen: (CatalogueDocument) -> Void

    var body: some View {
        Button {
            onOpen(doc)
        } label: {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                ActCoverView(doc: doc, first: first)
                LibraryCardCaption(title: LibraryActText.cardTitle(doc), facts: LibraryActText.facts(doc))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(LibraryActText.cardTitle(doc)))
        .accessibilityHint("Opens the Act")
    }
}

/// One Act in the list: a slim cover, the title, the facts, and what the volume holds.
struct ActRow: View {
    @Environment(\.theme) private var theme
    let doc: CatalogueDocument
    var first: String?
    let onOpen: (CatalogueDocument) -> Void

    var body: some View {
        Button {
            onOpen(doc)
        } label: {
            HStack(alignment: .top, spacing: Spacing.md) {
                ActCoverView(doc: doc, size: .small, showsCounts: false)
                VStack(alignment: .leading, spacing: 3) {
                    Text(LibraryActText.cardTitle(doc))
                        .font(.brand(.subheadline, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                        .multilineTextAlignment(.leading)
                        .dynamicLineLimit(3)
                    HStack(spacing: 6) {
                        Text(LibraryActText.facts(doc).joined(separator: " · "))
                        if LibraryActText.isRepealed(doc) { StatusPill(text: ActPageViewModel.Copy.repealed, tone: .warning) }
                        if doc.kind == "instrument" { StatusPill(text: BareActsIndexViewModel.Copy.notInLibrary) }
                    }
                    .font(.brand(.caption2))
                    .foregroundStyle(theme.textTertiary)
                    let parts = LibraryActText.countParts(doc.tabCounts, first: first)
                    if !parts.isEmpty {
                        Text(parts.prefix(3).joined(separator: " · "))
                            .font(.brand(.caption2, weight: .medium))
                            .foregroundStyle(theme.textSecondary)
                            .accessibilityLabel("Contains \(parts.joined(separator: ", "))")
                    }
                }
                Spacer(minLength: 0)
                RowChevron()
            }
            .padding(.vertical, Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the Act")
    }
}

// MARK: - The Act page

struct ActPageView: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session

    let id: Int
    var seed: CatalogueDocument?
    @Binding var path: [LibraryRoute]

    @State private var model: ActPageViewModel?

    var body: some View {
        Group {
            if let model {
                ActPageBody(model: model, path: $path)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(model?.title ?? "Act")
        .navigationBarTitleDisplayMode(.inline)
        .background(theme.canvas)
        .task(id: id) {
            guard model == nil else { return }
            let created = ActPageViewModel(id: id, seed: seed, service: session.library)
            model = created
            await created.load()
        }
    }
}

private struct ActPageBody: View {
    @Environment(\.theme) private var theme
    let model: ActPageViewModel
    @Binding var path: [LibraryRoute]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    ActPageHead(model: model)
                    if let failure = model.state.failure {
                        LibraryEmptyView(title: model.failureTitle, hint: failure.message, isError: true) {
                            if failure.isRetryable { Button("Try again") { Task { await model.load() } }.buttonStyle(.compactSecondaryAction) }
                        }
                    } else if model.bundle == nil {
                        HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, Spacing.xxl)
                    } else {
                        if model.tabs.count > 1 { ActTabsBar(model: model) }
                        if model.showsList { ActInstrumentList(model: model) }
                        ActReadingPane(model: model, path: $path)
                    }
                }
                .padding(.bottom, Spacing.xxl)
            }
        }
        .toolbar {
            if let doc = model.current, let data = model.currentData {
                ToolbarItem(placement: .primaryAction) {
                    ActShareButton(doc: doc, data: data)
                }
            }
        }
    }
}

private struct ActShareButton: View {
    let doc: CatalogueDocument
    let data: Data

    var body: some View {
        if let url = ShareableFile.url(for: data, named: "\(LibraryActText.actTitle(doc).prefix(100)).pdf") {
            ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                .accessibilityLabel("Share the PDF")
        }
    }
}

/// "Central Act · 1860 · IPC" over the Act's name, what it holds, and the edition being read.
private struct ActPageHead: View {
    @Environment(\.theme) private var theme
    let model: ActPageViewModel

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            if let act = model.act {
                ActCoverView(doc: act, size: .small, showsCounts: false)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(model.kickerParts.joined(separator: " · "))
                        .font(.brand(size: 10.5, weight: .bold, relativeTo: .caption2))
                        .tracking(0.6)
                        .textCase(.uppercase)
                        .foregroundStyle(Color(LibraryCollection.bareActs.theme.ink(dark: theme.isDark)))
                    if model.isRepealed { StatusPill(text: ActPageViewModel.Copy.repealed, tone: .warning) }
                }
                Text(model.title)
                    .font(.display(size: 22, relativeTo: .title2))
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let note = model.standingNote {
                    Text(note).font(.brand(.caption)).foregroundStyle(theme.warning)
                }
                if let holds = model.holdsLine {
                    Text(holds).font(.brand(.footnote)).foregroundStyle(theme.textSecondary)
                }
                if !model.editions.isEmpty, let act = model.act {
                    Menu {
                        Picker("Edition", selection: Binding(
                            get: { model.current?.id ?? act.id },
                            set: { id in
                                if let chosen = ([act] + model.editions).first(where: { $0.id == id }) { Task { await model.pick(chosen) } }
                            }
                        )) {
                            Text(model.currentEditionLabel).tag(act.id)
                            ForEach(Array(model.editions.enumerated()), id: \.element.id) { index, edition in
                                Text(model.editionLabel(edition, index: index)).tag(edition.id)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "books.vertical").imageScale(.small)
                            Text(model.current?.id == act.id ? "Current edition" : "Another edition")
                            Image(systemName: "chevron.down").imageScale(.small)
                        }
                        .font(.brand(.caption, weight: .semibold))
                        .foregroundStyle(theme.accentText)
                    }
                    .accessibilityLabel("Edition")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.gutter)
        .padding(.top, Spacing.md)
    }
}

/// Only the tabs that have something, in the backend's order, with counts.
private struct ActTabsBar: View {
    let model: ActPageViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.xs + 2) {
                ForEach(model.tabs) { tab in
                    LibraryChip(title: tab.label, count: (tab.key != "act" || tab.count > 1) ? tab.count : nil,
                                isSelected: model.activeTab?.key == tab.key) {
                        Task { await model.pickTab(tab.key) }
                    }
                }
            }
            .padding(.horizontal, Spacing.gutter)
            .padding(.vertical, 2)
        }
        .accessibilityLabel("Parts of this Act")
    }
}

/// The tab's instruments, with year, size, Latest and Repealed marks; amendments as a chronology.
private struct ActInstrumentList: View {
    @Environment(\.theme) private var theme
    let model: ActPageViewModel

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                LibraryCapLabel(text: model.activeTab?.label ?? "")
                Text(LibraryTitles.count(model.list.count)).font(.brand(.caption2)).foregroundStyle(theme.textTertiary)
                Spacer()
            }
            .padding(.horizontal, Spacing.gutter)
            if model.showsFilter {
                RecordSearchField(text: $model.instrumentFilter, prompt: "Filter \(model.activeTab?.label.lowercased() ?? "")")
                    .padding(.horizontal, Spacing.gutter)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: Spacing.sm) {
                    ForEach(model.filteredList) { doc in
                        ActInstrumentChip(doc: doc, model: model)
                    }
                    if model.filteredList.isEmpty {
                        Text("Nothing here matches “\(model.instrumentFilter)”.")
                            .font(.brand(.caption)).foregroundStyle(theme.textTertiary)
                    }
                }
                .padding(.horizontal, Spacing.gutter)
                .padding(.vertical, 2)
            }
        }
    }
}

private struct ActInstrumentChip: View {
    @Environment(\.theme) private var theme
    let doc: CatalogueDocument
    let model: ActPageViewModel

    var body: some View {
        let on = model.current?.id == doc.id
        let title = LibraryActText.actTitle(doc)
        let short = LibraryActText.shortTitle(title, actName: model.title)
        Button {
            Task { await model.pick(doc) }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                if model.isChronology {
                    Text(doc.year.map(String.init) ?? "—")
                        .font(.display(size: 16, relativeTo: .subheadline))
                        .foregroundStyle(on ? theme.accentText : theme.textSecondary)
                }
                Text(short ?? title)
                    .font(.brand(.footnote, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? theme.accentText : theme.textPrimary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                HStack(spacing: 6) {
                    if model.activeTab?.key == "editions" { Text(LibraryActText.copySource(doc)) }
                    else if !model.isChronology, let year = doc.year { Text(String(year)) }
                    let size = LibraryActText.size(doc.fileSize)
                    if !size.isEmpty { Text(size) }
                    if let copies = doc.copies, !copies.isEmpty { Text("\(copies.count + 1) copies") }
                    if doc.id == model.latestID { Text(ActPageViewModel.Copy.latest).fontWeight(.semibold).foregroundStyle(theme.success) }
                    if LibraryActText.isRepealed(doc) { Text(ActPageViewModel.Copy.repealed).fontWeight(.semibold).foregroundStyle(theme.warning) }
                }
                .font(.brand(.caption2))
                .foregroundStyle(theme.textTertiary)
                .lineLimit(1)
            }
            .padding(Spacing.sm)
            .frame(width: 180, alignment: .leading)
            .background(on ? theme.accentSoft : theme.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(on ? theme.accentLine : theme.separator, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Where an instrument is read: a slim bar (what is open, previous / next) over the PDF.
private struct ActReadingPane: View {
    @Environment(\.theme) private var theme
    let model: ActPageViewModel
    @Binding var path: [LibraryRoute]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            bar
            Group {
                if let data = model.currentData {
                    PDFDataView(data: data)
                        .frame(minHeight: 520)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                } else if model.currentIsMissing {
                    LibraryEmptyView(title: ActPageViewModel.Copy.notOnShelf,
                                     hint: ActPageViewModel.Copy.notOnShelfHint + (model.alternatives.isEmpty ? "" : " " + ActPageViewModel.Copy.otherEdition)) {
                        ForEach(model.alternatives, id: \.doc.id) { alternative in
                            Button("Read \(alternative.label)\(LibraryActText.size(alternative.doc.fileSize).isEmpty ? "" : " · \(LibraryActText.size(alternative.doc.fileSize))")") {
                                Task { await model.pick(alternative.doc) }
                            }
                            .buttonStyle(.compactSecondaryAction)
                        }
                    }
                } else if let error = model.openError {
                    LibraryEmptyView(title: "This document could not be opened", hint: error, isError: true) {
                        Button("Try again") { Task { await model.openCurrent() } }.buttonStyle(.compactSecondaryAction)
                    }
                } else {
                    HStack { Spacer(); ProgressView(); Spacer() }.frame(height: 240)
                }
            }
        }
        .padding(.horizontal, Spacing.gutter)
    }

    private var bar: some View {
        HStack(spacing: Spacing.sm) {
            if let position = model.position {
                Button { Task { await model.previous() } } label: { Image(systemName: "chevron.left") }
                    .disabled(!model.hasPrevious)
                    .accessibilityLabel("Previous instrument")
                Text("\(position.index + 1) / \(position.total)")
                    .font(.brand(.caption, weight: .semibold)).monospacedDigit().foregroundStyle(theme.textSecondary)
                Button { Task { await model.next() } } label: { Image(systemName: "chevron.right") }
                    .disabled(!model.hasNext)
                    .accessibilityLabel("Next instrument")
            }
            VStack(alignment: .leading, spacing: 1) {
                if let kind = model.paneKindLabel {
                    Text(kind.uppercased()).font(.brand(size: 10, weight: .bold, relativeTo: .caption2)).tracking(0.6).foregroundStyle(theme.textTertiary)
                }
                if let current = model.current, !model.isPrincipal {
                    Text(LibraryActText.actTitle(current)).font(.brand(.footnote, weight: .medium)).foregroundStyle(theme.textPrimary).lineLimit(2)
                }
                if let current = model.current {
                    Text([current.year.map(String.init), LibraryActText.size(current.fileSize).nilIfEmpty].compactMap { $0 }.joined(separator: " · "))
                        .font(.brand(.caption2)).foregroundStyle(theme.textTertiary)
                }
            }
            Spacer()
            if model.activeTab?.key == "related", let current = model.current {
                Button {
                    path.append(.act(id: current.id, seed: current))
                } label: {
                    Label(ActPageViewModel.Copy.openAsAct, systemImage: "book")
                        .font(.brand(.caption, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.accentText)
            }
        }
    }
}
