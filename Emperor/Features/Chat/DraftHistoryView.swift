import SwiftUI

/// Everything the assistant has drafted, across every conversation.
///
/// Reached from the conversation list rather than given a tab of its own: a draft is the
/// product of a chat, and the list of chats is where someone goes looking for one. The value
/// is that they no longer have to remember *which* chat — which, a week later, they do not.
struct DraftHistoryView: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var model: DraftHistoryViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    content(model)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Your drafts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                guard model == nil else { return }
                // Loading is driven by the kind-keyed task below, which also has to run when
                // the segmented control changes — doing it here as well would fetch twice on
                // first appear.
                model = DraftHistoryViewModel(service: session.drafts)
            }
        }
    }

    private func content(_ model: DraftHistoryViewModel) -> some View {
        // Named apart from `model` on purpose: `@Bindable var` is a mutable local, and
        // capturing one in a `@Sendable` closure — `.task`, `.refreshable` — does not compile.
        // The bindings come from here; everything else uses the immutable parameter.
        @Bindable var bindable = model

        return VStack(spacing: 0) {
            Picker("Kind", selection: $bindable.kind) {
                ForEach(DraftKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)

            ListStateView(presentation: model.presentation, retry: { await model.load() }) {
                list(model)
            } empty: {
                // Both live here, not in the content closure. `presentation.isEmpty` is
                // `visible.isEmpty`, so a search that matches nothing satisfies
                // `showsEmptyState` too — a branch on `showsNoSearchResults` above would
                // never be reached.
                if model.showsNoSearchResults {
                    ContentUnavailableView.search(text: model.query)
                } else {
                    ContentUnavailableView(
                        model.kind.title,
                        systemImage: model.kind.systemImage,
                        description: Text(model.kind.emptyMessage))
                }
            }
        }
        .background(theme.canvas)
        // Drafts and tables are separate routes rather than a filter over one list, so
        // switching the control is a fetch. This is also the initial load.
        .task(id: model.kind) { await model.load() }
        .searchable(text: $bindable.query, prompt: "Search drafts")
        .alert("Couldn't open that", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(item: Binding(
            get: { model.opened },
            set: { if $0 == nil { model.close() } }
        )) { opened in
            DraftReaderView(draft: opened)
        }
    }

    private func list(_ model: DraftHistoryViewModel) -> some View {
        List {
            ForEach(model.groups) { group in
                Section(group.title) {
                    ForEach(group.items) { item in
                        row(model, item)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .refreshable { await model.load() }
    }

    private func row(_ model: DraftHistoryViewModel, _ item: DraftedItem) -> some View {
        Button {
            model.open(item)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: model.kind.systemImage)
                    .foregroundStyle(theme.accent)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.displayTitle)
                        .lineLimit(2)
                        .foregroundStyle(theme.textPrimary)
                    Text(item.sourceLabel)
                        .font(.brand(.caption2))
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if model.loadingID == item.id {
                    ProgressView().controlSize(.small)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Reads one drafted document or table.
///
/// Reuses the artifact renderer rather than a plain `Text`: what comes back is the same
/// markdown the assistant wrote into the conversation, tables and all.
struct DraftReaderView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let draft: DraftHistoryViewModel.OpenedDraft

    var body: some View {
        NavigationStack {
            MarkdownArtifactView(markdown: draft.content)
                .background(theme.canvas)
                .navigationTitle(draft.item.displayTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: draft.content) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
        }
    }
}
