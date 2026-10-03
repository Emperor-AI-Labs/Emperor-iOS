import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// Translate, as presented from More: the screen in its own stack, with its own **Done**.
///
/// The screen itself is `OCRScreen`, which File tools also pushes — locked to PDF to Word — the
/// way the platform's `/tools/pdf-to-docx` is the same page as `/ocr-translate` with its mode
/// fixed (`src/pages/tools/PdfToDocx.jsx`).
struct OCRView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            OCRScreen(mode: .translate)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

/// Digitise a scanned order, optionally translating it — or convert a PDF to Word — and reopen
/// what was done before.
///
/// The most phone-native thing in the product: photograph a paper order on a courtroom desk
/// and get a document you can search and quote.
///
/// ## History
///
/// "Recent translations" is the account's own history from the server, so a document translated
/// on the web can be opened here and the other way round. Tapping a finished one fetches it and
/// opens it in Quick Look, which reads Word documents on the device and carries its own share
/// button for saving or sending it on. Clearing asks first, says that it reaches every device,
/// and is not offered while this screen is waiting on a document of its own.
struct OCRScreen: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session

    let mode: OCRViewModel.Mode

    @State private var model: OCRViewModel?
    @State private var isScanning = false
    @State private var isPickingFile = false
    @State private var isConfirmingClear = false
    @State private var previewURL: URL?

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scrollContentBackground(.hidden)
        .background(theme.canvas)
        .navigationTitle(mode == .translate ? "Translate" : "PDF to Word")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard model == nil else { return }
            let created = OCRViewModel(service: session.ocr, mode: mode)
            model = created
            await created.loadHistory()
        }
        .quickLookPreview($previewURL)
    }

    @ViewBuilder
    private func content(_ model: OCRViewModel) -> some View {
        @Bindable var bindable = model

        Form {
            if mode == .translate {
                Section {
                    Picker("Translate to", selection: $bindable.language) {
                        ForEach(OCRLanguage.allCases, id: \.self) { language in
                            Text(language.label).tag(language)
                        }
                    }
                    .disabled(model.isRunning)
                } footer: {
                    // Said plainly because the server's default is the opposite of the intuitive
                    // one: omitting a language translates to Hindi.
                    Text(model.language == .original
                         ? "The document will be read and kept in its original language."
                         : "The document will be read, then translated into \(model.language.rawValue).")
                        .font(.brand(.caption))
                        .foregroundStyle(theme.textSecondary)
                }
                .listRowBackground(theme.surface)
            }

            if !model.isRunning && model.result == nil {
                Section {
                    // The two ways in, as action rows: the words in the accent, as an action is
                    // drawn, beside a tile that says what each does.
                    if mode == .translate {
                        Button {
                            isScanning = true
                        } label: {
                            IconRowLabel(
                                title: "Scan with the camera", systemImage: "doc.viewfinder",
                                hue: .indigo, titleColor: theme.accentText)
                        }
                    }
                    Button {
                        isPickingFile = true
                    } label: {
                        IconRowLabel(
                            title: "Choose a PDF", systemImage: "folder", hue: .steel,
                            titleColor: theme.accentText)
                    }
                } footer: {
                    if mode == .pdfToWord {
                        // The one File tool that leaves the phone, as on the web — so it says so
                        // where the choice is made.
                        Text("The PDF is uploaded to Emperor and converted into an editable Word document. The other file tools work on this phone.")
                            .font(.brand(.caption))
                            .foregroundStyle(theme.textSecondary)
                    }
                }
                .listRowBackground(theme.surface)
            }

            if model.isRunning || model.isSubmitting {
                Section {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        MeterBar(fraction: model.progress, color: theme.accent)
                        Text(model.statusDescription)
                            .font(.brand(.caption))
                            .foregroundStyle(theme.textSecondary)
                    }
                    .padding(.vertical, Spacing.xs)

                    if !model.logLines.isEmpty {
                        DisclosureGroup("Details") {
                            ForEach(Array(model.logLines.suffix(20).enumerated()), id: \.offset) {
                                _, line in
                                Text(line)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(theme.textSecondary)
                            }
                        }
                        .font(.brand(.subheadline))
                    }
                } header: {
                    SectionHeader(title: "Progress")
                }
                .listRowBackground(theme.surface)
            }

            if let result = model.result {
                Section {
                    Button {
                        previewURL = ShareableFile.url(for: result.data, named: result.fileName)
                    } label: {
                        Label("Open \(result.fileName)", systemImage: "doc.text.magnifyingglass")
                    }
                    if let url = ShareableFile.url(for: result.data, named: result.fileName) {
                        ShareLink(item: url) {
                            Label("Save or share", systemImage: "square.and.arrow.up")
                        }
                    }
                    if let caveat = model.resultCaveat {
                        // status == "completed" does not always mean "translated".
                        Label(caveat, systemImage: "exclamationmark.triangle")
                            .font(.brand(.caption))
                            .foregroundStyle(theme.warning)
                    }
                    Button {
                        model.reset()
                    } label: {
                        Label(mode == .translate ? "Digitise another" : "Convert another",
                              systemImage: "arrow.counterclockwise")
                    }
                } header: {
                    SectionHeader(title: "Ready")
                }
                .listRowBackground(theme.surface)
            }

            historySection(model)
        }
        .font(.brand(.body))
        .refreshable { await model.loadHistory() }
        .sheet(isPresented: $isScanning) {
            DocumentScannerView { scan in
                isScanning = false
                if case .success(let document) = scan {
                    Task {
                        await model.submit(
                            data: document.pdfData, fileName: document.suggestedName)
                    }
                }
            }
            .ignoresSafeArea()
        }
        .fileImporter(
            isPresented: $isPickingFile,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { outcome in
            guard case .success(let urls) = outcome, let url = urls.first else { return }
            Task {
                // A security-scoped URL from the picker must be opened before reading.
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { return }
                await model.submit(data: data, fileName: url.lastPathComponent)
            }
        }
        .onChange(of: model.opened?.id) { _, _ in
            // A history document arrived: hand it to Quick Look, then let it go so tapping the
            // same row again fetches it afresh.
            guard let opened = model.opened else { return }
            previewURL = ShareableFile.url(for: opened.data, named: opened.fileName)
            model.opened = nil
        }
        .confirmationDialog(
            "Clear your translation history?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear history", role: .destructive) {
                Task { await model.clearHistory() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.clearHistoryConfirmation)
        }
        .alert(mode == .translate ? "Could not translate" : "Could not convert", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onDisappear { model.cancelPolling() }
    }

    // MARK: - History

    @ViewBuilder
    private func historySection(_ model: OCRViewModel) -> some View {
        let presentation = model.historyPresentation
        let jobs = model.visibleHistory

        Section {
            if presentation.showsLoadingPlaceholder {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if presentation.showsFailureState, let failure = presentation.failure {
                // "We could not ask" — never shown as an empty history.
                VStack(alignment: .leading, spacing: 8) {
                    ToolFailureRow(message: failure.message)
                    if failure.isRetryable {
                        Button("Try again") { Task { await model.loadHistory() } }
                            .font(.brand(.subheadline, weight: .semibold))
                            .buttonStyle(.borderless)
                    }
                }
            } else if presentation.showsEmptyState {
                Text(mode == .translate
                     ? "Documents you translate or digitise, here or on the web, appear here."
                     : "Documents you convert, here or on the web, appear here.")
                    .font(.brand(.subheadline))
                    .foregroundStyle(theme.textSecondary)
            } else {
                if presentation.showsStaleBanner, let failure = presentation.failure {
                    Label(failure.kind == .offline
                          ? "Offline — showing what was last loaded."
                          : "Could not refresh. Showing what was last loaded.",
                          systemImage: "exclamationmark.triangle")
                        .font(.brand(.caption))
                        .foregroundStyle(theme.warning)
                }
                ForEach(jobs, id: \.historyKey) { job in
                    historyRow(job, model)
                }
                if model.canClearHistory {
                    Button(role: .destructive) {
                        isConfirmingClear = true
                    } label: {
                        Label("Clear history", systemImage: "trash")
                    }
                }
            }
        } header: {
            SectionHeader(
                title: mode == .translate ? "Recent translations" : "Recent documents",
                detail: jobs.isEmpty ? nil : "\(jobs.count)")
        }
        .listRowBackground(theme.surface)
    }

    private func historyRow(_ job: OCRJob, _ model: OCRViewModel) -> some View {
        let isOpening = model.openingJobID != nil && model.openingJobID == (job.id ?? job.outputFile)
        let canOpen = job.state == .completed && job.outputFile != nil

        return Button {
            Task { await model.open(job) }
        } label: {
            HStack(alignment: .top, spacing: Spacing.md) {
                // A Word document, as the result is, in the kind's own colour — grey until it
                // can be opened.
                IconTile(systemImage: "doc.text", hue: canOpen ? .steel : .graphite)
                VStack(alignment: .leading, spacing: 3) {
                    Text(job.displayName)
                        .font(.brand(.subheadline, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(2)
                    Text(historyDetail(job))
                        .font(.brand(.caption))
                        .foregroundStyle(theme.textSecondary)
                    if job.state == .failed, let error = job.error, !error.isEmpty {
                        Text(error)
                            .font(.brand(.caption))
                            .foregroundStyle(theme.danger)
                            .lineLimit(3)
                    }
                }
                Spacer(minLength: 8)
                if isOpening {
                    ProgressView()
                } else {
                    statusPill(job)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canOpen || model.openingJobID != nil)
        .accessibilityHint(canOpen ? "Opens the document" : "")
    }

    /// "Hindi · 2 hours ago".
    private func historyDetail(_ job: OCRJob) -> String {
        var parts: [String] = []
        if let language = job.languageLabel { parts.append(language) }
        if let date = job.createdAt { parts.append(DisplayText.relative(date)) }
        if !job.state.isTerminal, let progress = job.progress { parts.append("\(progress)%") }
        return parts.isEmpty ? " " : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func statusPill(_ job: OCRJob) -> some View {
        switch job.state {
        case .completed: StatusPill(text: "Ready", tone: .success)
        case .failed: StatusPill(text: "Failed", tone: .danger)
        case .starting, .running: StatusPill(text: "In progress", tone: .info)
        case .unknown(let raw): StatusPill(text: raw.capitalized, tone: .neutral)
        }
    }
}

private extension OCRJob {
    /// A stable identity for a history row. The id is always present on `/ocr-history`; the
    /// fallbacks only keep a malformed entry from colliding with another.
    var historyKey: String { id ?? outputFile ?? "\(fileName ?? "")|\(status)" }
}
