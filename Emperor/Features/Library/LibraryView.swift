import SwiftUI

/// The shared reference corpus — bare acts, case law, rules.
///
/// Read-only, and the only screen in the app that is not about the user's own matters.
struct LibraryView: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session

    @Environment(\.dismiss) private var dismiss

    @State private var model: LibraryViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    content(model)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Library")
            // On the root rather than inside `content`, so it survives the loading, failure and
            // corpus-unavailable branches. This screen in particular can legitimately render
            // nothing but an "unavailable" message, and swiping is not an obvious way out of it.
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            // eAuctions (then called Liquidations) used to hang off the Library's toolbar, because
            // five tabs was the ceiling and there was nowhere else for it. There is now:
            // `MoreView` lists it as a peer of the Library. Leaving both would also have meant
            // opening a sheet from inside a sheet.
            .task {
                guard model == nil else { return }
                let created = LibraryViewModel(service: session.library)
                model = created
                await created.loadCategories()
            }
        }
    }

    @ViewBuilder
    private func content(_ model: LibraryViewModel) -> some View {
        @Bindable var bindable = model

        Group {
            if model.corpusLooksUnavailable {
                // Not an empty state. The corpus lives on a mounted volume, and a detached
                // volume returns success with zero rows everywhere rather than failing — which
                // is why the web renders silent empty tabs here.
                EmptyStateView(
                    "Library unavailable", systemImage: "books.vertical",
                    message: model.unavailableMessage, tone: .neutral
                ) {
                    Button("Try again") {
                        Task { await model.loadCategories() }
                    }
                    .buttonStyle(.primaryAction)
                }
            } else {
                VStack(spacing: 0) {
                    categoryBar(model)
                    if !model.subFilters.isEmpty {
                        subFilterBar(model)
                    }
                    results(model)
                }
            }
        }
        .background(theme.canvas)
        .searchable(text: $bindable.query, prompt: "Search the library")
        .onSubmit(of: .search) { Task { await model.reload() } }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Sort", selection: Binding(
                        get: { model.sort },
                        set: { model.sort = $0; Task { await model.reload() } }
                    )) {
                        ForEach(LibrarySort.allCases, id: \.self) { option in
                            Text(option.label).tag(option)
                        }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
            }
        }
        .sheet(item: $bindable.openDocument) { document in
            LibraryDocumentView(document: document)
        }
        .alert("Could not open", isPresented: Binding(
            get: { model.openError != nil },
            set: { if !$0 { model.openError = nil } }
        )) {
            Button("OK") { model.openError = nil }
        } message: {
            Text(model.openError ?? "")
        }
    }

    private func categoryBar(_ model: LibraryViewModel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.sm) {
                ForEach(model.categories) { category in
                    let isSelected = category.key == model.selectedCategory
                    let count = category.count ?? 0
                    Button {
                        Task { await model.select(category: category.key) }
                    } label: {
                        ChipLabel(
                            title: category.displayLabel,
                            count: count > 0 ? count : nil,
                            isSelected: isSelected)
                    }
                    .buttonStyle(ChipButtonStyle(isSelected: isSelected))
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    // A tab with nothing in it is still worth showing — it says the corpus has
                    // that category — but it cannot be browsed.
                    .disabled((category.count ?? 0) == 0)
                    .opacity((category.count ?? 0) == 0 ? 0.45 : 1)
                }
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.sm + 2)
        }
    }

    private func subFilterBar(_ model: LibraryViewModel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.xs + 2) {
                filterChip("All", isSelected: model.selectedSubFilter == nil) {
                    model.selectedSubFilter = nil
                    Task { await model.reload() }
                }
                ForEach(model.subFilters, id: \.self) { filter in
                    filterChip(filter, isSelected: model.selectedSubFilter == filter) {
                        model.selectedSubFilter = filter
                        Task { await model.reload() }
                    }
                }
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.bottom, Spacing.sm + 2)
        }
    }

    private func filterChip(
        _ text: String, isSelected: Bool, action: @escaping () -> Void
    ) -> some View {
        // The second tier, quieter than the category chips above it: the accent as text on its
        // own wash when chosen, plain words otherwise.
        let weight: Font.Weight? = isSelected ? Font.Weight.semibold : Font.Weight.medium
        return Button(action: action) {
            Text(text)
                .font(.brand(.caption, weight: weight))
                .foregroundStyle(isSelected ? theme.accentText : theme.textSecondary)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, 6)
                .background(isSelected ? theme.accentWash : Color.clear, in: Capsule())
                .overlay(
                    Capsule().strokeBorder(
                        isSelected ? theme.accentMuted : theme.separator, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func results(_ model: LibraryViewModel) -> some View {
        ListStateView(presentation: model.presentation, retry: { await model.reload() }) {
            List {
                Section {
                    ForEach(model.documents) { document in
                        Button {
                            Task { await model.open(document) }
                        } label: {
                            row(document)
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            // Paging is server-side; the last row asks for the next page.
                            if document.id == model.documents.last?.id {
                                Task { await model.loadMore() }
                            }
                        }
                    }
                    if model.isLoadingMore {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    }
                } header: {
                    SectionHeader(
                        title: model.currentCategory?.displayLabel ?? "Documents",
                        detail: model.total > 0
                            ? "\(model.documents.count) of \(model.total.formatted())"
                            : nil)
                }
                .listRowBackground(theme.surface)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.canvas)
        } empty: {
            if model.showsNoSearchResults {
                NoResultsView(query: model.query)
            } else {
                EmptyStateView(
                    "Nothing in this section",
                    systemImage: "books.vertical",
                    message: "Try another category.")
            }
        }
    }

    private func row(_ document: LibraryDocument) -> some View {
        HStack(spacing: Spacing.md) {
            // The reference corpus in the Library row's own gold, so a bare act never looks
            // like one of the user's own documents.
            IconTile(systemImage: document.isPDF ? "doc.richtext" : "doc.text", hue: .gold)

            VStack(alignment: .leading, spacing: 3) {
                Text(document.displayTitle)
                    .font(.brand(.subheadline, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                    .dynamicLineLimit(3)
                HStack(spacing: 6) {
                    if let size = document.fileSize, size > 0 {
                        Text(ByteCountFormatter.string(
                            fromByteCount: Int64(size), countStyle: .file))
                    }
                    if let added = document.addedDate {
                        SeparatorDot()
                        Text(DisplayText.longDay(WireDate.dayKey(added)))
                    }
                }
                .font(.brand(.caption2))
                .foregroundStyle(theme.textTertiary)
            }

            Spacer(minLength: 0)
            RowChevron()
        }
        .padding(.vertical, Spacing.xxs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the document")
    }
}

/// A document from the reference corpus.
private struct LibraryDocumentView: View {
    @Environment(\.theme) private var theme
    let document: LibraryViewModel.OpenLibraryDocument
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if document.isPDF {
                    PDFDataView(data: document.data)
                } else if let text = String(data: document.data, encoding: .utf8) {
                    ScrollView {
                        Text(text)
                            .font(.brand(.callout))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                } else {
                    EmptyStateView(
                        "Cannot preview this document",
                        systemImage: "doc.questionmark",
                        message: "Share it to open in another app.",
                        tone: .neutral)
                }
            }
            .background(theme.canvas)
            .navigationTitle(document.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    if let url = ShareableFile.url(
                        for: document.data,
                        named: "\(document.title).\(document.isPDF ? "pdf" : "txt")") {
                        ShareLink(item: url) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("Share")
                    }
                }
            }
        }
    }
}
