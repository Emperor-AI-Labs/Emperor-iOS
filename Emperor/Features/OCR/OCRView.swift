import SwiftUI
import UniformTypeIdentifiers

/// Digitise a scanned order, optionally translating it.
///
/// The most phone-native thing in the product: photograph a paper order on a courtroom desk
/// and get a document you can search and quote.
///
/// ## What this screen deliberately omits
///
/// There is no history list — this screen shows only jobs started on this device. See
/// `OCRService`. There is also no "clear history" action, because clearing is not per-user and
/// would take jobs that are still running with it.
struct OCRView: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var model: OCRViewModel?
    @State private var isScanning = false
    @State private var isPickingFile = false

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    content(model)
                } else {
                    ProgressView()
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.canvas)
            .navigationTitle("Translate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                if model == nil { model = OCRViewModel(service: session.ocr) }
            }
        }
    }

    @ViewBuilder
    private func content(_ model: OCRViewModel) -> some View {
        @Bindable var bindable = model

        Form {
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
            }

            if !model.isRunning && model.result == nil {
                Section {
                    Button {
                        isScanning = true
                    } label: {
                        Label("Scan with the camera", systemImage: "doc.viewfinder")
                    }
                    Button {
                        isPickingFile = true
                    } label: {
                        Label("Choose a PDF", systemImage: "folder")
                    }
                }
            }

            if model.isRunning || model.isSubmitting {
                Section("Progress") {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: model.progress)
                        Text(model.statusDescription)
                            .font(.brand(.caption))
                            .foregroundStyle(theme.textSecondary)
                    }
                    .padding(.vertical, 4)

                    if !model.logLines.isEmpty {
                        DisclosureGroup("Details") {
                            ForEach(Array(model.logLines.suffix(20).enumerated()), id: \.offset) {
                                _, line in
                                Text(line)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(theme.textSecondary)
                            }
                        }
                    }
                }
            }

            if let result = model.result {
                Section("Ready") {
                    Button {
                        model.reset()
                    } label: {
                        Label("Digitise another", systemImage: "arrow.counterclockwise")
                    }
                    if let caveat = model.resultCaveat {
                        // status == "completed" does not mean "translated".
                        Label(caveat, systemImage: "exclamationmark.triangle")
                            .font(.brand(.caption))
                            .foregroundStyle(theme.warning)
                    }
                    if let url = ShareableFile.url(for: result.data, named: result.fileName) {
                        ShareLink(item: url) {
                            Label("Save or share \(result.fileName)", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
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
        .alert("Could not digitise", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onDisappear { model.cancelPolling() }
    }
}
