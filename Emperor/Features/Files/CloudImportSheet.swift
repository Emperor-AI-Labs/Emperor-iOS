import SwiftUI

/// My Files → Import from a drive: the web's import modal (`src/pages/MyFilesPage.jsx`).
///
/// Pick the drive (when two are connected), the folder, and the files; Import brings them in one
/// at a time, and each row then says how it went. Every decision is `CloudImportViewModel`'s.
struct CloudImportSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var model: CloudImportViewModel
    /// Told once a run has brought at least one file in, so My Files reads its library again.
    private let onImported: () async -> Void

    init(
        service: any CloudDriveProviding, destinations: [String], initialDestination: String,
        onImported: @escaping () async -> Void
    ) {
        _model = State(initialValue: CloudImportViewModel(
            service: service, destinations: destinations, initialDestination: initialDestination))
        self.onImported = onImported
    }

    var body: some View {
        NavigationStack {
            content
                .background(theme.groupedBackground)
                .navigationTitle(model.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
        }
        .interactiveDismissDisabled(model.isImporting)
        .task { await model.load() }
        .onChange(of: model.summary) { _, summary in
            if let summary { VoiceOver.announce(summary) }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(model.hasRun ? "Done" : "Cancel") { dismiss() }
                .disabled(model.isImporting)
        }
        if !model.hasRun, model.unavailable == nil {
            ToolbarItem(placement: .confirmationAction) {
                Button(model.importButtonTitle) {
                    Task {
                        if await model.importSelected() > 0 {
                            await onImported()
                        }
                    }
                }
                .disabled(!model.canImport)
                .accessibilityIdentifier("cloud-import-run")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let unavailable = model.unavailable {
            EmptyStateView(
                "Nothing to import from", systemImage: "externaldrive.badge.xmark",
                message: unavailable.message)
        } else {
            List {
                if model.drives.count > 1 {
                    drivePicker
                }
                destinationSection
                if let summary = model.summary {
                    Section {
                        Text(summary)
                            .font(.brand(.subheadline))
                            .foregroundStyle(theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .listRowBackground(theme.surface)
                }
                filesSection
            }
            .font(.brand(.body))
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
    }

    private var drivePicker: some View {
        Section {
            Picker("Drive", selection: Binding(
                get: { model.drive ?? model.drives.first ?? .google },
                set: { chosen in Task { await model.choose(chosen) } }
            )) {
                ForEach(model.drives) { drive in
                    Text(drive.label).tag(drive)
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.isImporting || model.hasRun)
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
    }

    private var destinationSection: some View {
        Section {
            Picker("Save into", selection: Binding(
                get: { model.destination },
                set: { model.destination = $0 }
            )) {
                ForEach(model.destinations, id: \.self) { path in
                    Text(CloudImportViewModel.label(forFolder: path)).tag(path)
                }
            }
            .pickerStyle(.menu)
            .disabled(model.isImporting || model.hasRun)
            .accessibilityIdentifier("cloud-import-folder")
        }
        .listRowBackground(theme.surface)
    }

    private var filesSection: some View {
        Section {
            filesRows
        } header: {
            SectionHeader(
                title: "Files",
                detail: model.selected.isEmpty ? nil : "\(model.selected.count) chosen")
        } footer: {
            Text(CloudImportViewModel.Copy.listNote)
                .font(.brand(.caption))
                .foregroundStyle(theme.textSecondary)
        }
        .listRowBackground(theme.surface)
    }

    @ViewBuilder
    private var filesRows: some View {
        switch model.state {
        case .idle, .loading:
            HStack(spacing: Spacing.sm) {
                ProgressView()
                Text("Listing files…")
                    .foregroundStyle(theme.textSecondary)
            }
        case .failed(let failure):
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text(failure.message)
                    .font(.brand(.subheadline))
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if failure.isRetryable {
                    Button("Try again") {
                        Task { await model.load() }
                    }
                    .font(.brand(.subheadline, weight: .semibold))
                }
            }
            .padding(.vertical, Spacing.xxs)
        case .loaded:
            if model.files.isEmpty {
                Text(CloudImportViewModel.Copy.empty)
                    .font(.brand(.subheadline))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(model.files) { file in
                    CloudFileRow(
                        file: file,
                        detail: model.detail(for: file),
                        isSelected: model.isSelected(file),
                        outcome: model.outcome(of: file),
                        isLocked: model.isImporting || model.hasRun,
                        toggle: { model.toggle(file) })
                }
            }
        }
    }
}

/// One drive file: a tick, its name, its size and date — and, once a run has started, how it went.
private struct CloudFileRow: View {
    @Environment(\.theme) private var theme

    let file: CloudDriveFile
    let detail: String?
    let isSelected: Bool
    let outcome: CloudImportOutcome?
    let isLocked: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? theme.accentText : theme.textTertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(file.name)
                        .font(.brand(.body))
                        .foregroundStyle(theme.textPrimary)
                        .dynamicLineLimit(2)
                    if let detail {
                        Text(detail)
                            .font(.brand(.footnote))
                            .monospacedDigit()
                            .foregroundStyle(theme.textTertiary)
                    }
                    if let outcome {
                        Text(outcome.line(for: file))
                            .font(.brand(.footnote, weight: .medium))
                            .foregroundStyle(outcome.isProblem ? theme.danger : theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLocked)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// What the "Save to …" action leaves on My Files: a line when a document arrived in the drive,
/// and an alert, in the server's words, when it did not.
struct CloudSaveOutcomes: ViewModifier {
    let cloud: CloudFileActionsViewModel?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let cloud, let notice = cloud.notice {
                    ActionNoticeToast(notice: notice) { cloud.notice = nil }
                        .padding(.top, Spacing.sm)
                }
            }
            .alert(
                cloud?.failure?.title ?? "Couldn't save",
                isPresented: Binding(
                    get: { cloud?.failure != nil },
                    set: { if !$0 { cloud?.failure = nil } }
                )
            ) {
                Button("OK") { cloud?.failure = nil }
            } message: {
                Text(cloud?.failure?.message ?? "")
            }
    }
}
