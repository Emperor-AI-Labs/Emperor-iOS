import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Bringing a photo-library item into the tools as a file.
///
/// A library item has no name and is not always in the format its listing suggests, so it is
/// named from its own bytes (`ImagePDFLayout.sniffedExtension`) — which is what decides whether
/// Image to PDF can carry a JPEG through untouched.
enum PhotoImport {
    static func file(from item: PhotosPickerItem, number: Int) async -> PickedFile? {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return nil }
        let fileExtension = ImagePDFLayout.sniffedExtension(data)
            ?? item.supportedContentTypes.first?.preferredFilenameExtension
            ?? "jpg"
        return await ToolImport.write(data, named: "Photo \(number).\(fileExtension)")
    }
}

/// A small picture of an image file, drawn once it is on screen.
struct ImageFileThumbnail: View {
    @Environment(\.theme) private var theme
    let url: URL
    var side: CGFloat = 44

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(theme.surfaceElevated)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
        .accessibilityHidden(true)
        .task(id: url) {
            image = UIImage(contentsOfFile: url.path)?
                .preparingThumbnail(of: CGSize(width: side * 3, height: side * 3))
        }
    }
}

// MARK: - Compress image

/// Compress image — the platform's `/tools/compress-image` (`src/pages/tools/CompressImage.jsx`).
///
/// Quality is spent before resolution, as on the web: a scan that has been downscaled is a scan
/// whose small print has stopped being legible. A target the image cannot reach still produces
/// the smallest result possible, and says so. The output is always a JPEG.
struct CompressImageView: View {
    @Environment(\.theme) private var theme

    @State private var model: CompressImageViewModel?
    @State private var photo: PhotosPickerItem?
    @State private var isPickingFile = false
    @State private var isOpening = false
    @State private var openFailure: String?
    @State private var preview: UIImage?
    @FocusState private var isEditingTarget: Bool

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.canvas)
        .navigationTitle("Compress image")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if model == nil { model = CompressImageViewModel(engine: OnDeviceToolEngine()) }
        }
        .fileImporter(
            isPresented: $isPickingFile,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { outcome in
            guard case .success(let urls) = outcome, let url = urls.first else { return }
            Task { await open(await ToolImport.copy(url)) }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                await open(await PhotoImport.file(from: item, number: 1))
                photo = nil
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { isEditingTarget = false }
            }
        }
    }

    private func open(_ file: PickedFile?) async {
        guard let model else { return }
        isOpening = true
        defer { isOpening = false }
        guard let file, UIImage(contentsOfFile: file.url.path) != nil else {
            openFailure = ImageCompression.Failure.unreadable.errorDescription
            return
        }
        openFailure = nil
        model.load(file)
        preview = model.source == nil
            ? nil
            : UIImage(contentsOfFile: file.url.path)?.preparingThumbnail(of: CGSize(width: 200, height: 200))
    }

    @ViewBuilder
    private func content(_ model: CompressImageViewModel) -> some View {
        @Bindable var bindable = model

        Form {
            Section {
                if let source = model.source {
                    HStack(spacing: 12) {
                        Group {
                            if let preview {
                                Image(uiImage: preview).resizable().scaledToFill()
                            } else {
                                Rectangle().fill(theme.surfaceElevated)
                            }
                        }
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                        .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.name)
                                .font(.brand(.subheadline, weight: .semibold))
                                .dynamicLineLimit(2)
                            Text("Original · \(FileSize.format(source.bytes))")
                                .font(.brand(.caption))
                                .foregroundStyle(theme.textSecondary)
                        }
                    }
                }
                PhotosPicker(selection: $photo, matching: .images) {
                    Label(model.source == nil ? "Choose from Photos" : "Choose another photo",
                          systemImage: "photo.on.rectangle")
                }
                .disabled(isOpening || model.state.isRunning)
                Button {
                    isPickingFile = true
                } label: {
                    Label("Choose from Files", systemImage: "folder")
                }
                .disabled(isOpening || model.state.isRunning)
                if let failure = openFailure ?? model.notice {
                    ToolFailureRow(message: failure)
                }
            } header: {
                SectionHeader(title: "Image")
            } footer: {
                Text("JPG, PNG, HEIC, WebP and more, up to 1 GB. The result is always a JPG.")
                    .font(.brand(.caption))
                    .foregroundStyle(theme.textSecondary)
            }
            .listRowBackground(theme.surface)

            if model.source != nil {
                Section {
                    HStack {
                        TextField("100", text: $bindable.targetKB)
                            .keyboardType(.numberPad)
                            .focused($isEditingTarget)
                            .font(.brand(.body).monospacedDigit())
                            .accessibilityLabel("Target size in kilobytes")
                        Text("KB")
                            .font(.brand(.body))
                            .foregroundStyle(theme.textSecondary)
                    }
                    .listRowBackground(theme.surface)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Spacing.sm) {
                            ForEach(ImageCompression.presetsKB, id: \.self) { preset in
                                let selected = model.targetKB == String(preset)
                                Button {
                                    model.choosePreset(preset)
                                    isEditingTarget = false
                                } label: {
                                    Text("\(preset) KB")
                                        .monospacedDigit()
                                }
                                .buttonStyle(ChipButtonStyle(isSelected: selected))
                                .accessibilityAddTraits(selected ? .isSelected : [])
                            }
                        }
                        .padding(.vertical, 1)
                    }
                    .listRowBackground(Color.clear)
                } header: {
                    SectionHeader(title: "Target size")
                }

                Section {
                    ToolRunButton(
                        title: "Compress", runningTitle: "Compressing…",
                        isRunning: model.state.isRunning, isEnabled: model.canRun
                    ) {
                        isEditingTarget = false
                        Task { await model.run() }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                } footer: {
                    OnDeviceNote()
                }

                if let failure = model.state.failureMessage {
                    Section {
                        ToolFailureRow(message: failure)
                    }
                    .listRowBackground(theme.surface)
                }

                if let report = model.report, let source = model.source,
                   let caption = model.resultCaption {
                    Section {
                        SizeComparison(
                            originalBytes: source.bytes,
                            originalDetail: "\(report.originalWidth)×\(report.originalHeight)",
                            resultBytes: report.result.data.count,
                            resultDetail: "\(report.result.width)×\(report.result.height) · JPG",
                            headline: caption,
                            isImprovement: report.result.hitTarget)
                        if let output = model.output {
                            ToolResultRow(file: output)
                        }
                    } header: {
                        SectionHeader(title: "Result")
                    } footer: {
                        Text("Your original is unchanged. The result is a new file.")
                            .font(.brand(.caption))
                            .foregroundStyle(theme.textSecondary)
                    }
                    .listRowBackground(theme.surface)
                }
            }
        }
        .font(.brand(.body))
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }
}

// MARK: - Image to PDF

/// Image to PDF — the platform's `/tools/image-to-pdf` (`src/pages/tools/ImageToPdf.jsx`).
///
/// One image per page, in the order shown, on the paper size chosen; each image fitted inside a
/// uniform margin keeping its proportions (`ImagePDFLayout`). Photos come from the library or
/// from Files, and the order is the user's — drag a row to move it.
struct ImageToPDFView: View {
    @Environment(\.theme) private var theme

    @State private var model: ImageToPDFViewModel?
    @State private var photos: [PhotosPickerItem] = []
    @State private var isPickingFiles = false
    @State private var isAdding = false
    @State private var notice: String?

    /// Enough for a bundle of exhibit photographs, and a bound on how much the phone is asked
    /// to hold at once.
    private static let photoLimit = 60

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.canvas)
        .navigationTitle("Image to PDF")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if model == nil { model = ImageToPDFViewModel(engine: OnDeviceToolEngine()) }
        }
        .fileImporter(
            isPresented: $isPickingFiles,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { outcome in
            guard case .success(let urls) = outcome else { return }
            Task { await addFiles(urls) }
        }
        .onChange(of: photos) { _, items in
            guard !items.isEmpty else { return }
            Task {
                await addPhotos(items)
                photos = []
            }
        }
    }

    private func addFiles(_ urls: [URL]) async {
        guard let model else { return }
        isAdding = true
        defer { isAdding = false }
        var files: [PickedFile] = []
        for url in urls {
            if let file = await ToolImport.copy(url) { files.append(file) }
        }
        report(skipped: model.add(files) + (urls.count - files.count))
    }

    /// In the order they were ticked — the picker is asked for an ordered selection.
    private func addPhotos(_ items: [PhotosPickerItem]) async {
        guard let model else { return }
        isAdding = true
        defer { isAdding = false }
        var files: [PickedFile] = []
        for (offset, item) in items.enumerated() {
            if let file = await PhotoImport.file(from: item, number: model.images.count + offset + 1) {
                files.append(file)
            }
        }
        report(skipped: model.add(files) + (items.count - files.count))
    }

    private func report(skipped: Int) {
        notice = skipped == 0
            ? nil
            : "\(skipped) item\(skipped == 1 ? " was" : "s were") left out — not an image this tool can read."
    }

    @ViewBuilder
    private func content(_ model: ImageToPDFViewModel) -> some View {
        @Bindable var bindable = model

        Form {
            Section {
                ForEach(Array(model.images.enumerated()), id: \.element.id) { offset, image in
                    HStack(spacing: 12) {
                        Text("\(offset + 1)")
                            .font(.brand(.caption, weight: .bold).monospacedDigit())
                            .foregroundStyle(theme.textTertiary)
                            .frame(minWidth: 18)
                        ImageFileThumbnail(url: image.url)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(image.name)
                                .font(.brand(.subheadline))
                                .dynamicLineLimit(1)
                            Text(FileSize.format(image.bytes))
                                .font(.brand(.caption))
                                .foregroundStyle(theme.textSecondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Page \(offset + 1): \(image.name)")
                    .swipeActions {
                        Button(role: .destructive) {
                            model.remove(image.id)
                        } label: {
                            Label("Remove", systemImage: "minus.circle")
                        }
                    }
                }
                .onMove { source, destination in
                    model.move(fromOffsets: source, toOffset: destination)
                }

                PhotosPicker(
                    selection: $photos,
                    maxSelectionCount: Self.photoLimit,
                    selectionBehavior: .ordered,
                    matching: .images
                ) {
                    Label(model.images.isEmpty ? "Choose from Photos" : "Add from Photos",
                          systemImage: "photo.on.rectangle.angled")
                }
                .disabled(isAdding || model.state.isRunning)

                Button {
                    isPickingFiles = true
                } label: {
                    Label(model.images.isEmpty ? "Choose from Files" : "Add from Files", systemImage: "folder")
                }
                .disabled(isAdding || model.state.isRunning)

                if isAdding {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Adding…").font(.brand(.caption)).foregroundStyle(theme.textSecondary)
                    }
                }
                if let notice {
                    ToolFailureRow(message: notice)
                }
            } header: {
                SectionHeader(
                    title: "Images, in page order",
                    detail: model.images.count > 1 ? "Drag to reorder" : nil)
            }
            .listRowBackground(theme.surface)

            if !model.images.isEmpty {
                Section {
                    Picker("Page size", selection: $bindable.pageSize) {
                        ForEach(ImagePDFLayout.PageSize.allCases) { size in
                            Text(size.rawValue).tag(size)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                } header: {
                    SectionHeader(title: "Page size")
                } footer: {
                    Text("Each image is fitted to fill the page while keeping its proportions, centred with a uniform margin.")
                        .font(.brand(.caption))
                        .foregroundStyle(theme.textSecondary)
                }

                Section {
                    ToolRunButton(
                        title: model.actionLabel, runningTitle: "Building PDF…",
                        isRunning: model.state.isRunning, isEnabled: model.canRun
                    ) {
                        Task { await model.run() }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                } footer: {
                    OnDeviceNote()
                }

                if let failure = model.state.failureMessage {
                    Section {
                        ToolFailureRow(message: failure)
                    }
                    .listRowBackground(theme.surface)
                }

                if let output = model.output {
                    Section {
                        ToolResultRow(file: output)
                    } header: {
                        SectionHeader(title: "Result")
                    }
                    .listRowBackground(theme.surface)
                }
            }
        }
        .font(.brand(.body))
        .scrollContentBackground(.hidden)
    }
}
