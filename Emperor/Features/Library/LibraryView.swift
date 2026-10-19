import SwiftUI

// The Library (docs/library.md): the reference corpus, read as a library — shelves, covers, an
// index, a proper reading room. The web's `pages/Library.jsx` with `LibraryHome`, `SearchResults`
// and `CategoryStrip`; what each collection does below the strip lives in its own view.
//
// Routing: a `NavigationStack` over `LibraryRoute` — a collection, an Act page, a document's
// reading room — so Back behaves, and a judgment opened from a shelf returns to the shelf as it
// was. The sheet it is presented in keeps its own "Done" (`MoreView`'s rule).

/// Where the Library can go from its home.
enum LibraryRoute: Hashable {
    /// A collection, opened with the home's search carried along (as the web keeps `?q=`).
    case collection(LibraryCategoryCount, query: String = "")
    case act(id: Int, seed: CatalogueDocument?)
    case document(CatalogueDocument)

    /// An Act opens its Act page; everything else the reading room.
    static func open(_ doc: CatalogueDocument) -> LibraryRoute {
        doc.opensAsAct ? .act(id: doc.id, seed: doc) : .document(doc)
    }
}

struct LibraryView: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var model: LibraryViewModel?
    @State private var covers: LibraryCoverLoader?
    @State private var path: [LibraryRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let model {
                    LibraryHomeBody(model: model, path: $path)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(LibraryViewModel.Copy.title)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: LibraryRoute.self) { route in
                LibraryRouteView(route: route, path: $path)
            }
            .task {
                guard model == nil else { return }
                let created = LibraryViewModel(service: session.library)
                model = created
                covers = LibraryCoverLoader(service: session.library)
                await created.load()
            }
        }
        .environment(\.libraryCovers, covers)
    }
}

/// The screen a route opens.
struct LibraryRouteView: View {
    @Environment(Session.self) private var session
    let route: LibraryRoute
    @Binding var path: [LibraryRoute]

    var body: some View {
        switch route {
        case .collection(let category, let query):
            if category.key == LibraryCollection.bareActs.rawValue {
                BareActsIndexView(category: category, query: query, path: $path)
            } else if category.key == LibraryCollection.caseLaw.rawValue {
                CaseLawCollectionView(category: category, query: query, path: $path)
            } else {
                LibraryCollectionView(category: category, query: query, path: $path)
            }
        case .act(let id, let seed):
            ActPageView(id: id, seed: seed, path: $path)
        case .document(let doc):
            LibraryDocumentView(doc: doc, path: $path)
        }
    }
}

/// The home: the hero, the search box, the strip, the shelves — or the results of a search.
struct LibraryHomeBody: View {
    @Environment(\.theme) private var theme
    let model: LibraryViewModel
    @Binding var path: [LibraryRoute]

    var body: some View {
        @Bindable var model = model
        Group {
            if model.corpusLooksUnavailable {
                EmptyStateView(
                    "Library unavailable", systemImage: "books.vertical",
                    message: model.unavailableMessage, tone: .neutral
                ) {
                    Button("Try again") { Task { await model.load() } }
                        .buttonStyle(.primaryAction)
                }
            } else {
                ListStateView(presentation: model.presentation, retry: { await model.load() }) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            LibraryHero(model: model)
                            LibraryCategoryStrip(categories: model.orderedCategories, active: nil) { category in
                                path.append(.collection(category))
                            }
                            if model.isSearching {
                                LibrarySearchResults(model: model, path: $path)
                            } else {
                                LibraryShelves(model: model, path: $path)
                            }
                        }
                        .padding(.bottom, Spacing.xxxl)
                    }
                    .background(theme.canvas)
                } empty: {
                    LibraryEmptyView(title: "The library is empty", hint: "No collection has been catalogued on this server yet.")
                }
            }
        }
        .background(theme.canvas)
        .searchable(text: $model.query, placement: .navigationBarDrawer(displayMode: .always), prompt: LibraryViewModel.Copy.searchPrompt)
        .onSubmit(of: .search) { model.search() }
        .onChange(of: model.query) { _, text in
            if text.trimmingCharacters(in: .whitespaces).isEmpty { model.clearSearch() }
        }
    }
}

/// The hero: the display title and one line of what is here.
private struct LibraryHero: View {
    @Environment(\.theme) private var theme
    let model: LibraryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(LibraryViewModel.Copy.heroTitle)
                .font(.display(size: 28, relativeTo: .title))
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(model.heroLine)
                .font(.brand(.subheadline))
                .foregroundStyle(theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Spacing.gutter)
        .padding(.top, Spacing.md)
        .padding(.bottom, Spacing.lg)
    }
}

/// The row of collection tabs under the header: icon, label, live count.
struct LibraryCategoryStrip: View {
    @Environment(\.theme) private var theme
    let categories: [LibraryCategoryCount]
    var active: String?
    let onSelect: (LibraryCategoryCount) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.xs + 2) {
                ForEach(categories) { category in
                    let selected = active == category.key
                    Button {
                        onSelect(category)
                    } label: {
                        ChipLabel(title: category.theme.label, systemImage: category.theme.systemImage,
                                  count: category.count, isSelected: selected)
                    }
                    .buttonStyle(ChipButtonStyle(isSelected: selected))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, Spacing.gutter)
            .padding(.vertical, Spacing.xs)
        }
        .accessibilityLabel("Library collections")
    }
}

/// One shelf per collection, in shelf order.
private struct LibraryShelves: View {
    let model: LibraryViewModel
    @Binding var path: [LibraryRoute]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: Spacing.xl) {
            ForEach(model.orderedCategories) { category in
                LibraryCategoryShelf(category: category, model: model, path: $path)
            }
        }
        .padding(.top, Spacing.lg)
    }
}

private struct LibraryCategoryShelf: View {
    @Environment(\.theme) private var theme
    let category: LibraryCategoryCount
    let model: LibraryViewModel
    @Binding var path: [LibraryRoute]

    var body: some View {
        let shelf = model.shelf(for: category.key)
        let ink = Color(category.theme.ink(dark: theme.isDark))
        LibraryShelfRow(
            title: category.theme.label, blurb: category.theme.blurb, count: category.count, ink: ink,
            onSeeAll: { path.append(.collection(category)) }
        ) {
            if shelf.state.isLoading && shelf.items.isEmpty {
                ForEach(0..<5, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 3).fill(theme.surface2).frame(width: 136, height: 181)
                }
            } else if let failure = shelf.failure {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("This shelf could not be loaded. \(failure)")
                        .font(.brand(.caption))
                        .foregroundStyle(theme.textTertiary)
                    Button("Try again") { Task { await model.reloadShelf(category.key) } }
                        .font(.brand(.caption, weight: .semibold))
                        .foregroundStyle(theme.accentText)
                        .buttonStyle(.plain)
                }
                .frame(width: 260, height: 100, alignment: .topLeading)
            } else if shelf.items.isEmpty {
                Text(LibraryViewModel.Copy.emptyShelf)
                    .font(.brand(.caption))
                    .foregroundStyle(theme.textTertiary)
                    .frame(height: 100)
            } else {
                ForEach(shelf.items) { doc in
                    shelfCard(doc)
                }
            }
        }
    }

    @ViewBuilder
    private func shelfCard(_ doc: CatalogueDocument) -> some View {
        if category.key == LibraryCollection.bareActs.rawValue {
            Button {
                path.append(LibraryRoute.open(doc))
            } label: {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    ActCoverView(doc: doc, size: .medium)
                    LibraryCardCaption(title: LibraryActText.cardTitle(doc), facts: LibraryActText.facts(doc))
                        .frame(width: 148, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(LibraryActText.cardTitle(doc)))
        } else {
            LibraryDocCard(doc: doc) { path.append(LibraryRoute.open($0)) }
                .frame(width: 148)
        }
    }
}

/// What the search box shows when no collection is chosen: passages inside judgments, then one
/// section per collection with title matches and "See all N".
private struct LibrarySearchResults: View {
    @Environment(\.theme) private var theme
    let model: LibraryViewModel
    @Binding var path: [LibraryRoute]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            Text(model.searchState.isLoading ? "Searching every collection…" : "Results for “\(model.searchedFor)”")
                .font(.brand(.footnote))
                .foregroundStyle(theme.textFaint)
                .padding(.horizontal, Spacing.gutter)
                .padding(.top, Spacing.md)
                .accessibilityAddTraits(.updatesFrequently)

            if model.searchUnreachable {
                LibraryEmptyView(title: "The search could not reach the library", hint: LibraryViewModel.Copy.unreachable, isError: true) {
                    Button("Try again") { model.search() }.buttonStyle(.secondaryAction)
                }
            } else if model.searchFoundNothing {
                LibraryEmptyView(title: "Nothing found for “\(model.searchedFor)”", hint: LibraryViewModel.Copy.nothingHint)
            }

            if !model.passageItems.isEmpty {
                passages
            }
            ForEach(model.orderedGroups) { group in
                groupSection(group)
            }
            if model.searchState.isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, Spacing.xl)
            }
        }
    }

    private var passages: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            LibrarySectionHeading(
                title: LibraryViewModel.Copy.insideJudgments, count: model.passages?.total,
                ink: Color(LibraryCollection.caseLaw.theme.ink(dark: theme.isDark)),
                onSeeAll: { openCaseLaw() })
                .padding(.horizontal, Spacing.gutter)
            VStack(spacing: 0) {
                ForEach(model.passageItems) { doc in
                    LibraryDocCard(doc: doc, variant: .list, badge: doc.courtLabel, query: model.searchedFor) { path.append(.document($0)) }
                    RecordDivider()
                }
            }
            .padding(.horizontal, Spacing.gutter)
        }
    }

    private func groupSection(_ group: LibraryGroupedSearch.Group) -> some View {
        let category = model.categories.first { $0.key == group.category }
            ?? LibraryCategoryCount(key: group.category, label: group.label, count: group.total)
        let look = category.theme
        let isCaseLaw = group.category == LibraryCollection.caseLaw.rawValue
        let query = model.searchedFor
        return VStack(alignment: .leading, spacing: Spacing.sm) {
            LibrarySectionHeading(
                title: isCaseLaw ? LibraryViewModel.Copy.caseLawByName : look.label, count: group.total,
                ink: Color(look.ink(dark: theme.isDark)),
                onSeeAll: group.total > group.items.count ? { path.append(.collection(category, query: query)) } : nil)
                .padding(.horizontal, Spacing.gutter)
            if isCaseLaw {
                VStack(spacing: 0) {
                    ForEach(group.items) { doc in
                        LibraryDocCard(doc: doc, variant: .list, badge: doc.courtLabel) { path.append(.document($0)) }
                        RecordDivider()
                    }
                }
                .padding(.horizontal, Spacing.gutter)
            } else {
                LazyVGrid(columns: LibraryGrid.columns, alignment: .leading, spacing: Spacing.lg) {
                    ForEach(group.items) { doc in
                        LibraryDocCard(doc: doc) { path.append(LibraryRoute.open($0)) }
                    }
                }
                .padding(.horizontal, Spacing.gutter)
            }
        }
    }

    private func openCaseLaw() {
        let category = model.categories.first { $0.key == LibraryCollection.caseLaw.rawValue }
            ?? LibraryCategoryCount(key: LibraryCollection.caseLaw.rawValue, label: "Case law", count: nil)
        path.append(.collection(category, query: model.searchedFor))
    }
}
