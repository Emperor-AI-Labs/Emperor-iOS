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
            .padding(.horizontal, Spacing.lg)
            .padding(.bottom, Spacing.sm)

            ListStateView(presentation: model.presentation, retry: { await model.load() }) {
                list(model)
            } empty: {
                // Both live here, not in the content closure. `presentation.isEmpty` is
                // `visible.isEmpty`, so a search that matches nothing satisfies
                // `showsEmptyState` too — a branch on `showsNoSearchResults` above would
                // never be reached.
                if model.showsNoSearchResults {
                    NoResultsView(query: model.query)
                } else {
                    EmptyStateView(
                        model.kind.title,
                        systemImage: model.kind.systemImage,
                        message: model.kind.emptyMessage)
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
        // Full screen for the same reason the chat's artifact viewer is: a draft is a document
        // to be read, and a form sheet on an iPad is a fraction of the screen.
        .fullScreenCover(item: Binding(
            get: { model.opened },
            set: { if $0 == nil { model.close() } }
        )) { opened in
            DraftReaderView(draft: opened)
        }
    }

    private func list(_ model: DraftHistoryViewModel) -> some View {
        List {
            ForEach(model.groups) { group in
                Section {
                    ForEach(group.items) { item in
                        row(model, item)
                    }
                } header: {
                    SectionHeader(title: group.title, detail: "\(group.items.count)")
                }
                .listRowBackground(theme.surface)
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
            HStack(spacing: Spacing.md) {
                // The tile a draft wears where the conversation produced it, too.
                IconTile(
                    systemImage: model.kind.systemImage,
                    hue: model.kind == .document ? .indigo : .teal)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.displayTitle)
                        .font(.brand(.subheadline, weight: .medium))
                        .dynamicLineLimit(2)
                        .foregroundStyle(theme.textPrimary)
                    Text(item.sourceLabel)
                        .font(.brand(.caption2))
                        .foregroundStyle(theme.textTertiary)
                        .dynamicLineLimit(1)
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
            Group {
                // Routed on what the body *is*, as the chat's own artifact viewer does. A draft
                // is usually an inline-styled HTML fragment, and this screen used to hand every
                // one of them to the Markdown renderer.
                switch draft.format {
                case .html:
                    DocumentWebView(html: draft.content)
                case .markdown:
                    MarkdownArtifactView(markdown: draft.content)
                }
            }
                .background(theme.canvas)
                .navigationTitle(draft.item.displayTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        DocumentExportMenu(
                            content: draft.content,
                            isHTML: draft.format == .html,
                            title: draft.item.displayTitle)
                    }
                }
        }
    }
}
