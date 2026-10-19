import SwiftUI

/// "Build from documents": Emperor reads the matter's documents and proposes dated events, and
/// nothing is added until the user ticks it. Every rule — which can be ticked, what is sent, the
/// wording of the outcome — is `ChronologyBuildViewModel`'s.
struct ChronologyBuildSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let model: ChronologyBuildViewModel
    /// Told the outcome once saving has finished, for the workspace's toast.
    let onFinished: (String) -> Void

    var body: some View {
        NavigationStack {
            List { content }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(theme.groupedBackground)
                .navigationTitle("Build from documents")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
        }
        .interactiveDismissDisabled(model.phase == .saving)
        // Closing the sheet stops the review: an answer still on its way opens nothing.
        .onDisappear { model.abandon() }
        .onChange(of: model.phase) { _, phase in
            guard phase == .done else { return }
            if let summary = model.summary { onFinished(summary) }
            dismiss()
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
                .disabled(model.phase == .saving)
        }
        ToolbarItem(placement: .confirmationAction) {
            switch model.phase {
            case .pick:
                Button("Read documents") { Task { await model.start() } }
                    .disabled(!model.canStart)
            case .review:
                Button(model.acceptTitle) { Task { await model.acceptProposals() } }
                    .disabled(model.picked.isEmpty)
            case .failed:
                Button("Back") { model.backToPick() }
            case .reading, .saving, .done:
                ProgressView()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .pick: pick
        case .reading: reading
        case .review, .saving, .done: review
        case .failed: failed
        }
    }

    // MARK: - Pick

    @ViewBuilder
    private var pick: some View {
        Section {
            Text(ChronologyBuildViewModel.pickIntro)
                .font(.brand(.footnote))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .listRowBackground(theme.surface)

        Section {
            scopeRow("All documents in this matter", "Every processed file in the matter's own storage.", selected: model.scope == .all) {
                model.scope = .all
            }
            scopeRow("Choose documents", "Read only the files you pick.", selected: model.scope == .some) {
                Task { await model.chooseSome() }
            }
        } header: {
            SectionHeader(title: "Which documents")
        }
        .listRowBackground(theme.surface)

        if model.scope == .some {
            Section {
                if let files = model.files {
                    if files.isEmpty {
                        Text(model.filesError ?? "This matter has no files yet. Attach them from My Files in Files first.")
                            .font(.brand(.footnote))
                            .foregroundStyle(theme.textSecondary)
                    } else {
                        ForEach(files) { file in fileRow(file) }
                    }
                } else {
                    ProgressView()
                }
            } header: {
                SectionHeader(title: "Documents", detail: model.readingCount)
            }
            .listRowBackground(theme.surface)
        }
    }

    private func scopeRow(_ title: String, _ detail: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.md) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? theme.accentText : theme.textTertiary)
                    .imageScale(.large)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.brand(.subheadline, weight: .semibold)).foregroundStyle(theme.textPrimary)
                    Text(detail).font(.brand(.caption)).foregroundStyle(theme.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func fileRow(_ file: MatterFile) -> some View {
        let chosen = model.isChosen(file)
        return Button {
            model.toggle(file)
        } label: {
            HStack(spacing: Spacing.md) {
                Image(systemName: chosen ? "checkmark.square.fill" : "square")
                    .foregroundStyle(chosen ? theme.accentText : theme.textTertiary)
                    .imageScale(.large)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(DisplayText.fileName(file.name))
                        .font(.brand(.subheadline))
                        .foregroundStyle(file.isReady ? theme.textPrimary : theme.textSecondary)
                    let detail = [file.sub.isEmpty ? nil : file.sub, file.notReadyLine].compactMap { $0 }
                    if !detail.isEmpty {
                        Text(detail.joined(separator: " · "))
                            .font(.brand(.caption2))
                            .foregroundStyle(file.isReady ? theme.textTertiary : theme.warning)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!file.isReady)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    // MARK: - Reading

    private var reading: some View {
        Section {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack {
                    Label(ChronologyBuildViewModel.readingTitle, systemImage: "sparkles")
                        .font(.brand(.subheadline, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                    Spacer(minLength: Spacing.sm)
                    Text(model.readingCount)
                        .font(.brand(.caption))
                        .foregroundStyle(theme.textTertiary)
                }
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(theme.accentText)
                Text(ChronologyBuildViewModel.readingLine)
                    .font(.brand(.footnote))
                    .foregroundStyle(theme.textSecondary)
            }
            .padding(.vertical, Spacing.xs)
        } footer: {
            Text(ChronologyBuildViewModel.readingNote)
                .font(.brand(.caption2))
                .foregroundStyle(theme.textTertiary)
        }
        .listRowBackground(theme.surface)
    }

    // MARK: - Review

    @ViewBuilder
    private var review: some View {
        let saving = model.phase != .review
        if model.proposals.isEmpty {
            Section {
                Text(model.extraction?.message ?? model.nothingFoundLine)
                    .font(.brand(.footnote))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .listRowBackground(theme.surface)
        } else {
            if saving {
                Section {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        ProgressView(value: Double(model.progress.done), total: Double(max(model.progress.total, 1)))
                            .tint(theme.accentText)
                        Text(model.progressLine)
                            .font(.brand(.caption))
                            .foregroundStyle(theme.textSecondary)
                    }
                }
                .listRowBackground(theme.surface)
            }
            if let partial = model.partialLine {
                Section {
                    Label(partial, systemImage: "exclamationmark.triangle")
                        .font(.brand(.footnote))
                        .foregroundStyle(theme.warning)
                }
                .listRowBackground(theme.surface)
            }
            Section {
                ForEach(model.proposals) { proposal in
                    proposalRow(proposal, disabled: saving)
                }
            } header: {
                HStack {
                    SectionHeader(title: "Found", detail: model.countLine)
                    Spacer(minLength: Spacing.sm)
                    Menu {
                        Button("Tick all") { model.tickAll() }
                        Button("Untick all") { model.untickAll() }
                    } label: {
                        Image(systemName: "checklist")
                    }
                    .accessibilityLabel("Tick or untick all")
                    .disabled(saving)
                }
            } footer: {
                Text("Each event says where it was read. Check it against the document before it goes into a filing.")
                    .font(.brand(.caption2))
                    .foregroundStyle(theme.textTertiary)
            }
            .listRowBackground(theme.surface)
        }
    }

    private func proposalRow(_ proposal: ChronologyProposal, disabled: Bool) -> some View {
        let on = proposal.isOn && proposal.isUsable
        return Button {
            model.setOn(proposal, !proposal.isOn)
        } label: {
            HStack(alignment: .top, spacing: Spacing.md) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .foregroundStyle(on ? theme.accentText : theme.textTertiary)
                    .imageScale(.large)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(proposal.kindLabel)
                            .font(.brand(.caption2, weight: .semibold))
                            .foregroundStyle(theme.accentText)
                        SeparatorDot()
                        if let day = proposal.day {
                            Text(DisplayText.longDay(day))
                                .font(.brand(.caption2, weight: .semibold))
                                .foregroundStyle(theme.textPrimary)
                        } else {
                            Text(proposal.undatedLine)
                                .font(.brand(.caption2))
                                .foregroundStyle(theme.warning)
                        }
                    }
                    Text(proposal.title.isEmpty ? "No description" : proposal.title)
                        .font(.brand(.subheadline, weight: .medium))
                        .foregroundStyle(proposal.title.isEmpty ? theme.textTertiary : theme.textPrimary)
                    if !proposal.details.isEmpty {
                        Text(proposal.details).font(.brand(.caption)).foregroundStyle(theme.textSecondary)
                    }
                    if !proposal.sourceRef.isEmpty {
                        Label(proposal.sourceRef, systemImage: "doc.text.magnifyingglass")
                            .font(.brand(.caption2))
                            .foregroundStyle(theme.textTertiary)
                    }
                    if proposal.isDuplicate {
                        Text("Already on the record")
                            .font(.brand(.caption2, weight: .medium))
                            .foregroundStyle(theme.textSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .opacity(on || !proposal.isUsable ? 1 : 0.75)
        }
        .buttonStyle(.plain)
        .disabled(disabled || !proposal.isUsable)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: - Failed

    private var failed: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Couldn't build the chronology")
                        .font(.brand(.subheadline, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                    Text(model.failure ?? "Emperor could not read the documents.")
                        .font(.brand(.footnote))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(theme.danger)
            }
        }
        .listRowBackground(theme.surface)
    }
}

/// The Chronology section's way into `ChronologyBuildSheet`.
struct ChronologyBuildRow: View {
    @Environment(\.theme) private var theme
    let action: () -> Void

    var body: some View {
        Section {
            Button(action: action) {
                Label("Build from documents", systemImage: "sparkles")
            }
        } footer: {
            Text("Emperor proposes dated events from this matter's documents. Nothing is added until you tick it.")
                .font(.brand(.caption2))
                .foregroundStyle(theme.textTertiary)
        }
        .listRowBackground(theme.surface)
    }
}
