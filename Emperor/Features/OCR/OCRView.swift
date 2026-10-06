import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// OCR or Translate, as presented from More: the screen in its own stack, with its own **Done**.
///
/// Opens in the mode it is asked for — More has a row for each — and the screen's own switch
/// moves between the two, as the web's `?mode=` entry and its tabs do (`OCRTranslate.jsx:257-263`).
/// Everywhere else that offers it opens on Translate.
///
/// The screen itself is `OCRScreen`, which File tools also pushes — locked to PDF to Word — the
/// way the platform's `/tools/pdf-to-docx` is the same page as `/ocr-translate` with its mode
/// fixed (`src/pages/tools/PdfToDocx.jsx`).
struct OCRView: View {
    @Environment(\.dismiss) private var dismiss

    var mode: OCRViewModel.Mode = .translate

    var body: some View {
        NavigationStack {
            OCRScreen(mode: mode)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

/// Digitise a scanned order, or translate it — or convert a PDF to Word — and reopen what was
/// done before.
///
/// The most phone-native thing in the product: photograph a paper order on a courtroom desk
/// and get a document you can search and quote.
///
/// ## Modes
///
/// OCR and Translate share the screen, with a switch between them at the top as the web has
/// tabs; `mode` is only where it opens. PDF to Word is pushed from File tools locked to its mode,
/// and shows no switch.
///
/// ## History
///
/// "Recent documents" is the account's own history from the server — everything digitised,
/// translated or converted, whichever mode is showing — so a document made on the web can be
/// opened here and the other way round. Tapping a finished one fetches it and opens it in Quick
/// Look, which reads Word documents on the device and carries its own share button for saving or
/// sending it on. Clearing asks first, says that it reaches every device, and is not offered
/// while this screen is waiting on a document of its own.
struct OCRScreen: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session

    /// The mode the screen opens in. Once it has, the model's mode is the one shown.
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
        .navigationTitle((model?.mode ?? mode).title)
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
            if model.mode.isSwitchable {
                modeSection(model)
            }

            if model.mode.choosesLanguage {
                Section {
                    Picker("Translate to", selection: $bindable.language) {
                        ForEach(OCRLanguage.translationTargets, id: \.self) { language in
                            Text(language.label).tag(language)
                        }
                    }
                    .disabled(model.isRunning)
                } footer: {
                    Text("The document will be read, then translated into \(model.language.rawValue).")
                        .font(.brand(.caption))
                        .foregroundStyle(theme.textSecondary)
                }
                .listRowBackground(theme.surface)
            }

            if !model.isRunning && model.result == nil {
                Section {
                    // The two ways in, as action rows: the words in the accent, as an action is
                    // drawn, beside a tile that says what each does.
                    if model.mode.offersScanning {
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
                            title: model.mode == .pdfToWord ? "Choose a PDF" : "Choose a file",
                            systemImage: "folder", hue: .steel,
                            titleColor: theme.accentText)
                    }
                } footer: {
                    if model.mode == .pdfToWord {
                        // The one File tool that leaves the phone, as on the web — so it says so
                        // where the choice is made.
                        Text("The PDF is uploaded to Emperor and converted into an editable Word document. The other file tools work on this phone.")
                            .font(.brand(.caption))
                            .foregroundStyle(theme.textSecondary)
                    } else {
                        // "Choose a file" says less than "Choose a PDF" did, so the footer
                        // names what the picker will offer.
                        Text("A PDF, a Word document, or a JPEG, PNG, WebP or TIFF image.")
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
                        Label(model.mode.againTitle, systemImage: "arrow.counterclockwise")
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
            // The mode's own list, by extension. `jpg` and `jpeg` name one type, which is
            // harmless; an extension the system does not know is simply not offered.
            allowedContentTypes: model.mode.acceptedFileExtensions.compactMap {
                UTType(filenameExtension: $0)
            },
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
            "Clear your document history?",
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
        .alert(model.mode.failureTitle, isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onDisappear { model.cancelPolling() }
    }

    // MARK: - Mode

    /// OCR | Translate, at the head of the screen as the web's tabs are (`OCRTranslate.jsx:624-650`),
    /// with a line saying what the selected one does.
    ///
    /// The system's segmented control rather than a drawn one: it is two words, it reads as a
    /// switch between views of one screen on every device, and VoiceOver already announces it
    /// as one control with its selected segment. Switching starts clean — see `switchMode(to:)`
    /// — and is held while a document is on its way.
    private func modeSection(_ model: OCRViewModel) -> some View {
        Section {
            Picker("Mode", selection: Binding(
                get: { model.mode },
                set: { model.switchMode(to: $0) }
            )) {
                ForEach(OCRViewModel.Mode.switchable, id: \.self) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!model.canSwitchMode)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        } footer: {
            if let summary = model.mode.summary {
                Text(summary)
                    .font(.brand(.caption))
                    .foregroundStyle(theme.textSecondary)
            }
        }
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
                Text(model.mode == .pdfToWord
                     ? "Documents you convert, here or on the web, appear here."
                     : "Documents you digitise or translate, here or on the web, appear here.")
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
            // The same title in every mode: the list holds every kind of job, and a heading that
            // changed with the switch would suggest the list had been filtered when it had not.
            SectionHeader(
                title: "Recent documents",
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
