import SwiftUI

/// One analysis tool: choose documents and a note, run it, follow it, read the result.
///
/// Pushed inside `AnalysisHubView`'s stack. Everything it decides lives in
/// `AnalysisRunViewModel`; this only lays the phases out and holds the running task, so leaving
/// the screen stops following the run.
struct AnalysisToolView: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session

    let tool: AnalysisJobTool
    /// A saved run to show instead of an empty screen.
    var openingRunID: String?

    @State private var model: AnalysisRunViewModel?
    @State private var runTask: Task<Void, Never>?
    @State private var isPickingFiles = false
    @State private var isShowingHistory = false
    @State private var toast: String?

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView()
            }
        }
        .background(theme.groupedBackground)
        .navigationTitle(tool.title)
        .navigationBarTitleDisplayMode(.inline)
        .recordToast($toast)
        .task {
            guard model == nil else { return }
            let created = AnalysisRunViewModel(tool: tool, service: session.analysis)
            model = created
            if let openingRunID { await created.open(runID: openingRunID) }
        }
        .onDisappear { stop() }
    }

    @ViewBuilder
    private func content(_ model: AnalysisRunViewModel) -> some View {
        phaseView(model)
            .toolbar { toolbar(model) }
            .sheet(isPresented: $isPickingFiles) {
                FileLibraryView(alreadyAttached: model.files) { chosen in
                    model.setFiles(chosen)
                }
            }
            .sheet(isPresented: $isShowingHistory) {
                NavigationStack {
                    AnalysisHistoryView(tool: tool) { run in
                        isShowingHistory = false
                        stop()
                        Task { await model.open(runID: run.id) }
                    }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { isShowingHistory = false }
                        }
                    }
                }
            }
    }

    @ViewBuilder
    private func phaseView(_ model: AnalysisRunViewModel) -> some View {
        switch model.phase {
        case .idle:
            if model.opening != nil {
                ProgressView("Opening…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                AnalysisIntakeView(
                    model: model,
                    onPick: { isPickingFiles = true },
                    onRun: { run(model) })
            }
        case .running(let stage, let progress):
            AnalysisProgressView(
                title: tool.runningTitle, stage: stage, progress: progress,
                onCancel: { stop(); model.cancel() })
        case .done(let outcome):
            AnalysisResultScreen(
                outcome: outcome,
                onAgain: { stop(); model.startOver() })
        case .failed(let failure):
            AnalysisFailureView(
                title: tool.failureTitle, failure: failure,
                onRetry: { retry(model) },
                onStartOver: { stop(); model.startOver() })
        }
    }

    @ToolbarContentBuilder
    private func toolbar(_ model: AnalysisRunViewModel) -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if case .done(let outcome) = model.phase {
                Menu {
                    ShareLink(item: outcome.result.plainText) {
                        Label("Share as text", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        UIPasteboard.general.string = outcome.result.plainText
                        toast = "Copied"
                    } label: {
                        Label("Copy as text", systemImage: "doc.on.doc")
                    }
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
            Button {
                isShowingHistory = true
            } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
            .disabled(model.isRunning)
        }
    }

    private func run(_ model: AnalysisRunViewModel) {
        stop()
        runTask = Task { await model.start() }
    }

    private func retry(_ model: AnalysisRunViewModel) {
        stop()
        runTask = Task { await model.retry() }
    }

    private func stop() {
        runTask?.cancel()
        runTask = nil
    }
}

// MARK: - Intake

/// Step 1, the documents; step 2, the note; then the one button — the web's intake.
struct AnalysisIntakeView: View {
    @Environment(\.theme) private var theme
    let model: AnalysisRunViewModel
    let onPick: () -> Void
    let onRun: () -> Void

    var body: some View {
        @Bindable var bindable = model
        Form {
            Section {
                AnalysisToolHeader(tool: model.tool)
            }
            .listRowBackground(Color.clear)

            AnalysisDocumentsSection(model: model, onPick: onPick)

            Section {
                TextField(model.tool.referencePlaceholder, text: $bindable.reference, axis: .vertical)
                    .lineLimit(3...8)
                    .font(.brand(.body))
            } header: {
                SectionHeader(title: model.tool.referenceLabel)
            } footer: {
                Text(model.tool.referenceHint)
                    .font(.brand(.caption))
                    .foregroundStyle(theme.textTertiary)
            }
            .listRowBackground(theme.surface)

            Section {
                Button(model.tool.runLabel, action: onRun)
                    .buttonStyle(.primaryAction)
                    .disabled(!model.canRun)
                    .listRowInsets(EdgeInsets())
            } footer: {
                Text(model.runHint)
                    .font(.brand(.caption))
                    .foregroundStyle(theme.textTertiary)
            }
            .listRowBackground(Color.clear)
        }
        .scrollContentBackground(.hidden)
    }
}

/// The tool's name, its other name and its promise, above the intake.
struct AnalysisToolHeader: View {
    @Environment(\.theme) private var theme
    let tool: AnalysisJobTool

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            IconTile(systemImage: tool.systemImage, hue: TileHue.forTool(tool.rawValue), size: .large)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(tool.title)
                    .font(.display(size: 24, relativeTo: .title2))
                    .foregroundStyle(theme.textPrimary)
                if let other = tool.alsoCalled {
                    Text("Also called \(other.lowercased())")
                        .font(.brand(.caption))
                        .foregroundStyle(theme.textTertiary)
                }
                Text(tool.tagline)
                    .font(.brand(.subheadline))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The documents picked from My Files, with the button that picks them.
struct AnalysisDocumentsSection: View {
    @Environment(\.theme) private var theme
    let model: AnalysisRunViewModel
    let onPick: () -> Void

    var body: some View {
        Section {
            ForEach(model.files, id: \.self) { file in
                AnalysisFileRow(file: file) { model.remove(file) }
            }
            Button(action: onPick) {
                Label(model.files.isEmpty ? "Choose from My Files" : "Change documents",
                      systemImage: "folder")
            }
        } header: {
            SectionHeader(
                title: "Choose your documents",
                detail: "\(model.files.count) of \(AnalysisJobTool.maxFiles)")
        } footer: {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                if let notice = model.filesNotice {
                    Text(notice)
                        .foregroundStyle(theme.warning)
                }
                Text("Documents are read and indexed in My Files first, so tools never take uploads directly.")
                    .foregroundStyle(theme.textTertiary)
            }
            .font(.brand(.caption))
        }
        .listRowBackground(theme.surface)
    }
}

struct AnalysisFileRow: View {
    @Environment(\.theme) private var theme
    let file: ChatAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "doc.text")
                .foregroundStyle(theme.accentText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(DisplayText.fileName(file.name))
                    .font(.brand(.subheadline, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                    .dynamicLineLimit(2)
                if let folder = file.folderName, !folder.isEmpty {
                    Text("In \(DisplayText.fileName(folder))")
                        .font(.brand(.caption))
                        .foregroundStyle(theme.textTertiary)
                }
            }
            Spacer(minLength: Spacing.sm)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(theme.textTertiary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Remove \(DisplayText.fileName(file.name))"))
        }
    }
}

// MARK: - Running and failing

/// The server's own line about what it is doing, a bar, and a clock — the web's live loader.
struct AnalysisProgressView: View {
    @Environment(\.theme) private var theme
    let title: String
    let stage: String
    let progress: Double
    let onCancel: () -> Void

    @State private var started = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.display(size: 24, relativeTo: .title2))
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                TimelineView(.periodic(from: started, by: 1)) { context in
                    Text(Self.clock(context.date.timeIntervalSince(started)))
                        .font(.brand(.footnote, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(theme.accentText)
                }
            }
            if progress > 0 {
                ProgressView(value: progress)
                    .tint(theme.accent)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(theme.accent)
            }
            HStack(spacing: Spacing.sm) {
                ProgressView()
                Text(stage.isEmpty ? "Working…" : stage)
                    .font(.brand(.subheadline, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
            }
            .accessibilityElement(children: .combine)
            Text("Long documents can take a few minutes. Nothing is shared with anyone else.")
                .font(.brand(.caption))
                .foregroundStyle(theme.textTertiary)
            Button("Cancel", action: onCancel)
                .buttonStyle(.quietAction)
            Spacer()
        }
        .padding(Spacing.gutter)
        .frame(maxWidth: 560, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Why a run did not finish, and what to do next. A plan refusal is said calmly, without a retry.
struct AnalysisFailureView: View {
    let title: String
    let failure: AnalysisFailure
    let onRetry: () -> Void
    let onStartOver: () -> Void

    var body: some View {
        if let refusal = failure.refusal, refusal.concernsThePlan {
            ScrollView {
                VStack(spacing: Spacing.lg) {
                    RefusalCard(refusal: refusal)
                    Button("Start over", action: onStartOver)
                        .buttonStyle(.secondaryAction)
                }
                .padding(Spacing.gutter)
            }
        } else {
            EmptyStateView(title, systemImage: "exclamationmark.triangle", message: failure.message, tone: .warning) {
                if failure.canRetry {
                    Button("Try again", action: onRetry)
                        .buttonStyle(.primaryAction)
                }
                Button("Start over", action: onStartOver)
                    .buttonStyle(.secondaryAction)
            }
        }
    }
}
