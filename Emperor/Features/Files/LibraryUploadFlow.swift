import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

/// A document picked to go into the library: where its bytes are, and what it will be called.
struct PickedDocument {
    let url: URL
    let fileName: String
}

/// Picked documents the library already holds, waiting on the user's answer.
struct DuplicateReview: Identifiable {
    let id = UUID()
    var items: [DuplicateReviewSheet.Item]
    /// The documents that need no question, passed through so the caller has one list.
    var cleared: [(url: URL, fileName: String)]
    /// Where all of them are going.
    let folder: String
    /// For a folder upload: where each file goes instead, by its URL.
    var folders: [URL: String] = [:]
    /// For a folder upload: the picked folder, whose access covers every file inside it.
    var scope: URL?
}

/// A folder picked for upload: its plan, and where each planned file's bytes are.
struct PickedFolderUpload: Identifiable {
    let id = UUID()
    /// The picked folder. Its security scope covers every file inside it.
    let root: URL
    let plan: FolderUploadPlan
    /// Each planned file's URL, by its relative path.
    let urls: [String: URL]

    /// The planned files, in order, with their bytes and their landing folders.
    var documents: [(url: URL, fileName: String, folder: String)] {
        plan.entries.compactMap { entry in
            urls[entry.relativePath].map { ($0, entry.fileName, entry.folderName) }
        }
    }
}

/// Putting documents into the library — shared by the attach picker and My Files, so the two
/// cannot disagree about what is accepted, what is asked, or where a failure is reported.
///
/// The rules are `LibraryUpload`'s and `DuplicateCheck`'s, in the core. What is here is only the
/// part that needs the device: reading a picked file under its security scope, turning a photo
/// into a JPEG, and handing bytes to the background uploader.
@MainActor
enum LibraryUploadFlow {

    /// What the file importer offers: the library's types, as the system names them.
    static var importableTypes: [UTType] {
        LibraryUpload.acceptedExtensions.compactMap { UTType(filenameExtension: $0) }
    }

    /// Asks the server whether any of these are already filed.
    ///
    /// - Returns: the question to put to the user, or `nil` when there is nothing to ask — in
    ///   which case the caller uploads everything straight away.
    ///
    /// **Every failure path here uploads.** A 401, an offline phone, a file that will not hash,
    /// a server that answers with something unexpected — none of them is a reason to refuse a
    /// document the user has explicitly chosen. The check is a courtesy that prevents a
    /// duplicate; treating its absence as a blocker would turn an expired token into "this app
    /// will not take my documents any more", which is far worse than the mess it avoids. The
    /// server also dedupes on arrival regardless, so nothing is lost but the prompt.
    static func review(
        _ picked: [PickedDocument], into folder: String, duplicates: any DuplicateChecking
    ) async -> DuplicateReview? {
        var hashes: [String?] = []
        for document in picked {
            // A picker URL is security-scoped and must be opened before reading. A photo's
            // temporary copy is not, and opening it is a harmless no-op.
            let scoped = document.url.startAccessingSecurityScopedResource()
            defer { if scoped { document.url.stopAccessingSecurityScopedResource() } }
            hashes.append(FileHash.sha256(of: document.url))
        }

        let checkable = zip(picked, hashes).compactMap { document, hash in
            hash.map { (name: document.fileName, hash: $0) }
        }
        let results = (try? await duplicates.check(files: checkable, targetFolder: folder)) ?? []
        let decisions = LibraryUpload.decisions(forHashes: hashes, results: results)

        var flagged: [DuplicateReviewSheet.Item] = []
        var cleared: [(url: URL, fileName: String)] = []
        for (document, decision) in zip(picked, decisions) {
            if case .upload = decision {
                cleared.append((document.url, document.fileName))
            } else {
                flagged.append(DuplicateReviewSheet.Item(
                    url: document.url, fileName: document.fileName, decision: decision,
                    // Off by default — see `DuplicateReviewSheet`.
                    upload: false))
            }
        }
        return flagged.isEmpty ? nil : DuplicateReview(items: flagged, cleared: cleared, folder: folder)
    }

    /// Hands each document to the background uploader, which copies it before returning.
    ///
    /// - Parameters:
    ///   - folders: for a folder upload, each file's own landing folder; `folder` otherwise.
    ///   - scope: for a folder upload, the picked folder, held open while its files are copied.
    /// - Returns: the first failure, worded for the user, or `nil` if every one started.
    static func upload(
        _ files: [(url: URL, fileName: String)], into folder: String,
        folders: [URL: String] = [:], scope: URL? = nil
    ) async -> String? {
        let scopeOpen = scope?.startAccessingSecurityScopedResource() ?? false
        defer { if scopeOpen { scope?.stopAccessingSecurityScopedResource() } }
        var failure: String?
        for file in files {
            let scoped = file.url.startAccessingSecurityScopedResource()
            defer {
                if scoped { file.url.stopAccessingSecurityScopedResource() }
                // A converted photo was ours. The uploader has taken its own copy by now.
                if file.url.path.hasPrefix(photoDirectory.path) {
                    try? FileManager.default.removeItem(at: file.url)
                }
            }
            do {
                try await BackgroundUploader.shared.start(
                    source: file.url, fileName: file.fileName,
                    folderName: folders[file.url] ?? folder)
            } catch {
                failure = failure ?? DisplayText.message(for: error)
            }
        }
        return failure
    }

    // MARK: - Folders

    /// Reads a picked folder: every file inside it, at any depth, by its path from the folder
    /// down — the folder's own name first, as a browser's folder pick names them — and the plan
    /// `FolderUploadPlan` makes of them. Nothing is copied here; the uploader copies each file
    /// as it starts.
    static func pickedFolder(at url: URL, into destination: String) -> PickedFolderUpload {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let rootName = url.lastPathComponent
        let base = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        var found: [(path: String, url: URL, size: Int)] = []
        if let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants]) {
            for case let fileURL as URL in walker {
                guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true
                else { continue }
                let parts = fileURL.standardizedFileURL.resolvingSymlinksInPath().pathComponents
                guard parts.count > base.count, Array(parts.prefix(base.count)) == base else { continue }
                let relative = ([rootName] + parts.dropFirst(base.count)).joined(separator: "/")
                found.append((relative, fileURL, values.fileSize ?? 0))
            }
        }
        found.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

        let plan = FolderUploadPlan(
            sources: found.map { FolderUploadPlan.Source(relativePath: $0.path, size: $0.size) },
            destination: destination)
        var urls: [String: URL] = [:]
        for item in found where urls[item.path] == nil { urls[item.path] = item.url }
        return PickedFolderUpload(root: url, plan: plan, urls: urls)
    }

    /// The duplicate question for a folder upload — `review` for a batch whose files land in
    /// several folders. The rules are `FolderUploadPlan.decisions`; as with `review`, every
    /// failure here uploads.
    ///
    /// - Parameter existing: the library as last read, for a clash below the destination.
    static func reviewFolder(
        _ picked: PickedFolderUpload, duplicates: any DuplicateChecking,
        existing: [FileNode.StoredFile]
    ) async -> DuplicateReview? {
        let documents = picked.documents
        let scoped = picked.root.startAccessingSecurityScopedResource()
        let hashes = documents.map { FileHash.sha256(of: $0.url) }
        if scoped { picked.root.stopAccessingSecurityScopedResource() }

        let checkable = zip(documents, hashes).compactMap { document, hash in
            hash.map { (name: document.fileName, hash: $0) }
        }
        let results = (try? await duplicates.check(
            files: checkable, targetFolder: picked.plan.destination)) ?? []
        let decisions = picked.plan.decisions(hashes: hashes, results: results, existing: existing)

        var flagged: [DuplicateReviewSheet.Item] = []
        var cleared: [(url: URL, fileName: String)] = []
        for (document, decision) in zip(documents, decisions) {
            if case .upload = decision {
                cleared.append((document.url, document.fileName))
            } else {
                flagged.append(DuplicateReviewSheet.Item(
                    url: document.url, fileName: document.fileName, decision: decision,
                    upload: false))
            }
        }
        guard !flagged.isEmpty else { return nil }
        var review = DuplicateReview(items: flagged, cleared: cleared, folder: picked.plan.destination)
        review.folders = folderMap(picked)
        review.scope = picked.root
        return review
    }

    /// Every planned file of a picked folder, each into its own folder.
    static func uploadFolder(_ picked: PickedFolderUpload) async -> String? {
        await upload(
            picked.documents.map { ($0.url, $0.fileName) }, into: picked.plan.destination,
            folders: folderMap(picked), scope: picked.root)
    }

    private static func folderMap(_ picked: PickedFolderUpload) -> [URL: String] {
        var map: [URL: String] = [:]
        for document in picked.documents { map[document.url] = document.folder }
        return map
    }

    // MARK: - Photos

    /// Inside the share directory, so signing out — which clears that directory — also removes
    /// any photo that was converted and never sent.
    private static var photoDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("EmperorShare", isDirectory: true)
            .appendingPathComponent("PhotoUploads", isDirectory: true)
    }

    /// Turns photos from the library into JPEGs the library can hold.
    ///
    /// The photo library hands over HEIC more often than not, which the platform neither accepts
    /// nor lists (`LibraryUpload.acceptedExtensions`). Each photo is decoded and re-encoded as a
    /// JPEG and named for the moment it was added.
    ///
    /// - Returns: the documents ready to upload, and how many photos could not be read.
    static func documents(from items: [PhotosPickerItem]) async -> (documents: [PickedDocument], unreadable: Int) {
        try? FileManager.default.createDirectory(at: photoDirectory, withIntermediateDirectories: true)
        let now = Date()
        var documents: [PickedDocument] = []
        var unreadable = 0
        for (index, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data),
                  let jpeg = image.jpegData(compressionQuality: 0.85)
            else {
                unreadable += 1
                continue
            }
            let name = LibraryUpload.photoFileName(at: now, index: index)
            let url = photoDirectory.appendingPathComponent(name)
            do {
                try jpeg.write(to: url, options: .atomic)
                documents.append(PickedDocument(url: url, fileName: name))
            } catch {
                unreadable += 1
            }
        }
        return (documents, unreadable)
    }
}

/// Uploads still going, read from disk so they survive the app closing.
///
/// Reopening the app mid-upload shows it still going, which is the point of the background
/// uploader. Said plainly, because it is the reassurance that makes someone willing to put the
/// phone in a pocket at a registry counter.
struct UploadsInFlightBanner: View {
    @Environment(\.theme) private var theme
    /// The attach picker's own foreground upload, when it is running one.
    var foregroundProgress: Double?

    private var batch: UploadBatch { BackgroundUploader.shared.batch }
    /// Uploads the server declined and that were stopped, until the person dismisses them. One
    /// already in the batch says so on its own row instead.
    private var refused: [BackgroundUploader.Refused] {
        BackgroundUploader.shared.refused.filter { !batch.contains($0.id) }
    }

    var body: some View {
        if !batch.isEmpty || !refused.isEmpty || foregroundProgress != nil {
            VStack(alignment: .leading, spacing: 8) {
                // Said here, where the upload was being watched, rather than not at all — which
                // is what a declined background upload used to amount to.
                ForEach(refused) { notice in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(theme.warning)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(DisplayText.fileName(notice.fileName)) wasn't uploaded")
                                .font(.brand(.caption, weight: .semibold))
                                .foregroundStyle(theme.textPrimary)
                                .dynamicLineLimit(1)
                            Text(notice.message)
                                .font(.brand(.caption))
                                .foregroundStyle(theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        UploadPanelCloseButton(hint: "Removes this notice") {
                            BackgroundUploader.shared.dismissRefusal(notice.id)
                        }
                    }
                    .accessibilityElement(children: .contain)
                }

                if !batch.isEmpty {
                    UploadBatchPanel(batch: batch) {
                        BackgroundUploader.shared.dismissBatch()
                    }
                }

                if let foregroundProgress {
                    // Ingestion runs after the upload's 200, so this stays up until the server
                    // reports the file readable — not until the bytes land.
                    VStack(alignment: .leading, spacing: 4) {
                        Text(foregroundProgress < 1 ? "Uploading…" : "Reading the document…")
                            .font(.brand(.caption))
                            .foregroundStyle(theme.textSecondary)
                        MeterBar(fraction: foregroundProgress, color: theme.accent)
                    }
                    // The bar is drawn for the eye and hidden; the percentage is said instead.
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(
                        foregroundProgress < 1 ? "\(Int(foregroundProgress * 100)) percent" : "")
                }
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.sm + 2)
            .background(theme.surface)
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.separator).frame(height: 0.5)
            }
        }
    }
}

/// The upload panel: what is being sent, how fast, how long is left, and what the server made
/// of each file — the web's upload tray, laid out for a phone. Every figure and every word comes
/// from `UploadBatch`; this only places them.
struct UploadBatchPanel: View {
    @Environment(\.theme) private var theme
    let batch: UploadBatch
    let onDismiss: () -> Void

    /// The countdown over a clean batch; `nil` while there is nothing to count down to.
    @State private var autoClose: UploadAutoClose?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(batch.title)
                        .font(.brand(.subheadline, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                    Text(batch.subtitle)
                        .font(.brand(.caption))
                        .foregroundStyle(theme.textSecondary)
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)
                if let autoClose {
                    UploadAutoCloseLabel(countdown: autoClose)
                }
                // Only once nothing is still being sent or read: closing a running batch would
                // hide an upload that is still going.
                if !batch.isActive {
                    UploadPanelCloseButton(hint: "Clears the finished uploads") {
                        onDismiss()
                    }
                }
            }
            // A batch that finished cleanly closes its own panel after a few seconds, as the web's
            // tray does. Keyed on the rule rather than on time: a failure or a new upload turns
            // `finishedCleanly` false, which cancels this task and takes the label away.
            .task(id: batch.finishedCleanly) {
                await runAutoClose()
            }

            if let speedLine = batch.speedLine {
                Text(speedLine)
                    .font(.brand(.caption))
                    .foregroundStyle(theme.textSecondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHint(UploadProgressFormat.speedExplanation)
            }

            ForEach(batch.groups) { group in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .font(.brand(.caption2))
                            .foregroundStyle(theme.textTertiary)
                            .accessibilityHidden(true)
                        Text(group.title)
                            .font(.brand(.caption, weight: .medium))
                            .foregroundStyle(theme.textSecondary)
                            .dynamicLineLimit(1)
                        Spacer(minLength: 0)
                        Text(group.count)
                            .font(.brand(.caption2))
                            .foregroundStyle(theme.textTertiary)
                            .monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)

                    ForEach(group.files) { file in
                        UploadFileRow(file: file)
                    }
                }
            }

            if batch.isSending {
                Text("Uploads continue if you leave the app.")
                    .font(.brand(.caption2))
                    .foregroundStyle(theme.textTertiary)
            }

            if let notice = batch.completionNotice {
                Text(notice)
                    .font(.brand(.caption, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Counts down once a second, then clears the batch. Ends quietly when cancelled — which is
    /// what happens when the batch stops being clean, or the panel leaves the screen.
    private func runAutoClose() async {
        guard batch.finishedCleanly else {
            autoClose = nil
            return
        }
        var countdown = UploadAutoClose()
        autoClose = countdown
        while !countdown.isDue {
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                autoClose = nil
                return
            }
            countdown.tick()
            autoClose = countdown
        }
        autoClose = nil
        onDismiss()
    }
}

/// "Closing in 3s", beside the panel's close button. Read once by VoiceOver rather than on every
/// tick, and never animated — a number changing by itself is enough movement.
struct UploadAutoCloseLabel: View {
    @Environment(\.theme) private var theme
    let countdown: UploadAutoClose

    var body: some View {
        Text(countdown.label)
            .font(.brand(.caption2))
            .foregroundStyle(theme.textTertiary)
            .monospacedDigit()
            .padding(.top, 4)
            .accessibilityLabel(countdown.accessibilityLabel)
    }
}

/// One file in the upload panel: its name, size and estimate, the figure at the end, a bar, and
/// why it failed when it did.
struct UploadFileRow: View {
    @Environment(\.theme) private var theme
    let file: UploadBatch.File

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(DisplayText.fileName(file.name))
                .font(.brand(.caption, weight: .medium))
                .foregroundStyle(theme.textPrimary)
                .dynamicLineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(file.detail)
                    .font(.brand(.caption2))
                    .foregroundStyle(theme.textTertiary)
                    .monospacedDigit()
                    .lineLimit(2)
                Spacer(minLength: 0)
                Text(file.trailing)
                    .font(.brand(.caption2, weight: .semibold))
                    .foregroundStyle(trailingColor)
                    .monospacedDigit()
            }
            // The bar stays once a file has finished, so a finished row keeps the height of a
            // running one and the list does not reflow as files land.
            MeterBar(fraction: file.fraction, color: barColor)
            if let error = file.error {
                Text(error)
                    .font(.brand(.caption2))
                    .foregroundStyle(theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // The bar is for the eye; the row is said as one sentence.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(DisplayText.fileName(file.name))
        .accessibilityValue(spokenValue)
    }

    private var spokenValue: String {
        var parts: [String] = []
        parts.append(file.isSending ? "\(file.percent) percent" : file.trailing)
        if !file.detail.isEmpty { parts.append(file.detail) }
        if let error = file.error { parts.append(error) }
        return parts.joined(separator: ", ")
    }

    private var trailingColor: Color {
        if file.needsAttention { return theme.danger }
        if file.isSent { return theme.success }
        return theme.accentText
    }

    private var barColor: Color {
        if file.needsAttention { return theme.danger }
        if file.isSent { return theme.success }
        return theme.accent
    }
}

/// The panel's small cross, with a full-size target.
struct UploadPanelCloseButton: View {
    @Environment(\.theme) private var theme
    let hint: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.brand(.caption, weight: .semibold))
                .foregroundStyle(theme.textTertiary)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss")
        .accessibilityHint(hint)
    }
}

/// The system share sheet, for a document fetched from the library.
///
/// A `ShareLink` needs its file before it is drawn, and a document's bytes are only fetched once
/// the user asks to share it — so the sheet is presented after the fetch instead.
struct ActivityView: UIViewControllerRepresentable {
    let url: URL
    var onComplete: () -> Void = {}

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in onComplete() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
