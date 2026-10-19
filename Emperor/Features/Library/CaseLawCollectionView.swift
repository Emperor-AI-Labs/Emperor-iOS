import SwiftUI

// The Case Law collection — the web's `categories/CaseLaw.jsx`: court chips with counts, a year
// timeline with two handles, Newest / Oldest / A–Z, "Titles and parties" or "Words inside", and
// the judgments as index entries with the court's seal.

struct CaseLawCollectionView: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session

    let category: LibraryCategoryCount
    var query = ""
    @Binding var path: [LibraryRoute]

    @State private var model: LibraryCollectionViewModel?

    var body: some View {
        Group {
            if let model {
                CaseLawBody(model: model, path: $path)
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

private struct CaseLawBody: View {
    @Environment(\.theme) private var theme
    let model: LibraryCollectionViewModel
    @Binding var path: [LibraryRoute]

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.md) {
                LibraryCollectionHeader(theme: model.theme, count: model.category.count)
                if !model.options(for: .courts).isEmpty {
                    CaseLawCourtChips(model: model)
                }
                if let range = model.yearRange {
                    CaseLawYearTimeline(model: model, range: range)
                }
                CaseLawToolbar(model: model)
                CaseLawRows(model: model, path: $path)
            }
            .padding(.bottom, Spacing.xxxl)
        }
        .searchable(text: $model.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search case names, or words inside")
        .onSubmit(of: .search) { Task { await model.search() } }
        .onChange(of: model.query) { _, text in
            if text.trimmingCharacters(in: .whitespaces).isEmpty { Task { await model.clearQuery() } }
        }
    }
}

/// All courts, then the Supreme Court (judgments, daily orders), then the High Courts.
private struct CaseLawCourtChips: View {
    let model: LibraryCollectionViewModel

    var body: some View {
        LibraryFacetChipsRow(
            label: "Court", options: model.options(for: .courts), selection: model.filters.court,
            allLabel: "All courts", labelFor: { CaseLawVocabulary.court($0.value, label: $0.label).short },
            onPick: { value in Task { await model.select(.courts, value: value) } })
    }
}

/// One bar per year (square-root scale so the 1960s stay visible) and two steppers for the
/// range; a tap on a bar picks that year.
private struct CaseLawYearTimeline: View {
    @Environment(\.theme) private var theme
    let model: LibraryCollectionViewModel
    let range: LibraryYearRange

    @State private var draftFrom: Int?
    @State private var draftTo: Int?

    private var lo: Int { draftFrom ?? model.filters.yearFrom ?? range.min }
    private var hi: Int { draftTo ?? model.filters.yearTo ?? range.max }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                LibraryCapLabel(text: "Years decided")
                Spacer()
                Text(lo == hi ? String(lo) : "\(lo)–\(hi)")
                    .font(.brand(.footnote, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(theme.textSecondary)
                if model.filters.yearFrom != nil || model.filters.yearTo != nil {
                    Button(LibraryCollectionViewModel.Copy.allYears) {
                        draftFrom = nil
                        draftTo = nil
                        Task { await model.setYears(from: nil, to: nil) }
                    }
                    .font(.brand(.caption, weight: .semibold))
                    .foregroundStyle(theme.accentText)
                    .buttonStyle(.plain)
                }
            }
            CaseLawYearBars(counts: model.yearCounts, range: range, lo: lo, hi: hi) { year in
                draftFrom = year
                draftTo = year
                Task { await model.setYears(from: year, to: year) }
            }
            HStack(spacing: Spacing.md) {
                stepper("From", value: lo, bounds: range.min...hi) { draftFrom = $0 }
                stepper("To", value: hi, bounds: lo...range.max) { draftTo = $0 }
                Spacer()
                if draftFrom != nil || draftTo != nil {
                    Button("Apply") {
                        let a = lo == range.min ? nil : lo
                        let b = hi == range.max ? nil : hi
                        draftFrom = nil
                        draftTo = nil
                        Task { await model.setYears(from: a, to: b) }
                    }
                    .buttonStyle(.compactPrimaryAction)
                }
            }
            Text("\(LibraryTitles.count(model.judgments(inYears: lo, hi))) judgments in \(lo == hi ? String(lo) : "\(lo)–\(hi)")\(model.filters.court != nil ? " · bars count all courts" : "")")
                .font(.brand(.caption2))
                .foregroundStyle(theme.textTertiary)
        }
        .padding(.horizontal, Spacing.gutter)
    }

    private func stepper(_ label: String, value: Int, bounds: ClosedRange<Int>, set: @escaping (Int) -> Void) -> some View {
        Stepper(value: Binding(get: { value }, set: set), in: bounds) {
            HStack(spacing: 4) {
                Text(label).font(.brand(.caption)).foregroundStyle(theme.textTertiary)
                Text(String(value)).font(.brand(.footnote, weight: .semibold)).monospacedDigit().foregroundStyle(theme.textPrimary)
            }
        }
        .accessibilityLabel("\(label) year")
        .accessibilityValue(String(value))
    }
}

private struct CaseLawYearBars: View {
    @Environment(\.theme) private var theme
    let counts: [LibraryYearCount]
    let range: LibraryYearRange
    let lo: Int
    let hi: Int
    let onPick: (Int) -> Void

    var body: some View {
        let byYear = Dictionary(uniqueKeysWithValues: counts.map { ($0.year, $0.count) })
        let peak = max(1, counts.map(\.count).max() ?? 1)
        let years = Array(range.min...range.max)
        GeometryReader { proxy in
            let w = max(1, (proxy.size.width - CGFloat(years.count - 1)) / CGFloat(years.count))
            HStack(alignment: .bottom, spacing: 1) {
                ForEach(years, id: \.self) { year in
                    let n = byYear[year] ?? 0
                    let h = max(2, proxy.size.height * CGFloat((Double(n) / Double(peak)).squareRoot()))
                    Rectangle()
                        .fill(year >= lo && year <= hi ? theme.accent : theme.borderStrong)
                        .frame(width: w, height: h)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .contentShape(Rectangle())
                        .onTapGesture { onPick(year) }
                }
            }
        }
        .frame(height: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Judgments per year, \(range.min) to \(range.max)")
        .accessibilityHint("Use the From and To steppers to change the years")
    }
}

/// The count, the names/words switch and the sort.
private struct CaseLawToolbar: View {
    @Environment(\.theme) private var theme
    let model: LibraryCollectionViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if model.hasQuery {
                RecordSegmentedControl(
                    label: "Search in",
                    options: [(value: false, title: LibraryCollectionViewModel.Copy.titlesAndParties),
                              (value: true, title: LibraryCollectionViewModel.Copy.wordsInside)],
                    selection: Binding(get: { model.inText }, set: { on in Task { await model.setInText(on) } }))
                    .padding(.horizontal, Spacing.gutter)
            }
            LibraryCollectionToolbar(model: model)
        }
    }
}

/// The judgments as index entries.
private struct CaseLawRows: View {
    @Environment(\.theme) private var theme
    let model: LibraryCollectionViewModel
    @Binding var path: [LibraryRoute]

    var body: some View {
        Group {
            if let failure = model.state.failure {
                LibraryEmptyView(title: "We couldn't load these judgments", hint: failure.message, isError: true) {
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
                    } else if model.hasQuery, !model.inText {
                        Button("Search inside judgments") { Task { await model.setInText(true) } }.buttonStyle(.compactSecondaryAction)
                    }
                }
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(model.documents) { doc in
                        CaseLawRow(doc: doc, facts: model.caseRow(for: doc), query: model.query) { path.append(.document($0)) }
                        RecordDivider(inset: 52)
                    }
                    LibraryLoadMoreFooter(isLoading: model.isLoadingMore, canLoadMore: model.canLoadMore) { await model.loadMore() }
                }
                .padding(.horizontal, Spacing.gutter)
            }
        }
        .opacity(model.state.isLoading && !model.documents.isEmpty ? 0.55 : 1)
    }
}

/// One judgment: the court's seal, "A v. B", the badge, date, citation, number, bench, and a
/// passage when searching inside the text.
struct CaseLawRow: View {
    @Environment(\.theme) private var theme
    let doc: CatalogueDocument
    let facts: LibraryCollectionViewModel.CaseRowFacts
    var query = ""
    let onOpen: (CatalogueDocument) -> Void

    var body: some View {
        Button {
            onOpen(doc)
        } label: {
            HStack(alignment: .top, spacing: Spacing.md) {
                CourtSealView(court: CaseLawVocabulary.court(facts.courtKey, label: doc.courtLabel))
                VStack(alignment: .leading, spacing: 4) {
                    CaseLawTitleText(doc: doc)
                    metaLine
                    if let bench = facts.bench {
                        Text("Bench: \(bench)")
                            .font(.brand(.caption2))
                            .foregroundStyle(theme.textTertiary)
                            .lineLimit(2)
                    }
                    if let passage = facts.passage {
                        LibraryPassageText(snippet: passage, query: query)
                    } else if facts.noPassage {
                        Text(LibraryCollectionViewModel.Copy.noPassage)
                            .font(.brand(.caption))
                            .foregroundStyle(theme.textTertiary)
                            .italic()
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
        .accessibilityHint("Opens the judgment")
    }

    private var metaLine: some View {
        HStack(spacing: 6) {
            Text(facts.courtShort)
                .font(.brand(size: 10.5, weight: .bold, relativeTo: .caption2))
                .foregroundStyle(Color.libraryHex(theme.isDark ? CaseLawVocabulary.court(facts.courtKey).inkDark : CaseLawVocabulary.court(facts.courtKey).ink))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.libraryHex(theme.isDark ? CaseLawVocabulary.court(facts.courtKey).inkDark : CaseLawVocabulary.court(facts.courtKey).ink).opacity(0.1), in: Capsule())
            if let date = facts.date {
                Text(date)
                    .font(.brand(.caption2, weight: facts.dateUnclear ? .semibold : .regular))
                    .foregroundStyle(facts.dateUnclear ? theme.warning : theme.textTertiary)
            }
            if let citation = facts.citation {
                Text(citation).font(.brand(.caption2, weight: .medium)).foregroundStyle(theme.textSecondary)
            }
            if let number = facts.number {
                Text(number).font(.brand(.caption2)).foregroundStyle(theme.textTertiary)
            }
        }
        .lineLimit(1)
    }
}

/// "Seethamma *v.* State of Karnataka" — the parties, the v. in italics.
struct CaseLawTitleText: View {
    @Environment(\.theme) private var theme
    let doc: CatalogueDocument
    var header: JudgmentHeader?
    var size: CGFloat = 15

    var body: some View {
        Group {
            if let parties = header.flatMap(CaseLawVocabulary.parties(of:)) ?? CaseLawVocabulary.parties(of: doc) {
                Text(parties.0).font(.display(size: size, relativeTo: .subheadline))
                    + Text(" v. ").font(.display(size: size, italic: true, relativeTo: .subheadline)).foregroundColor(theme.textTertiary)
                    + Text(parties.1).font(.display(size: size, relativeTo: .subheadline))
            } else {
                Text(CaseLawVocabulary.tidyParty(header?.title ?? doc.title ?? "Untitled judgment"))
                    .font(.display(size: size, relativeTo: .subheadline))
            }
        }
        .foregroundStyle(theme.textPrimary)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}
