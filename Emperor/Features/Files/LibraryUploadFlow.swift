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
    /// - Returns: the first failure, worded for the user, or `nil` if every one started.
    static func upload(_ files: [(url: URL, fileName: String)], into folder: String) async -> String? {
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
                    source: file.url, fileName: file.fileName, folderName: folder)
            } catch {
                failure = failure ?? DisplayText.message(for: error)
            }
        }
        return failure
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

    private var inFlight: [UploadManifest] { BackgroundUploader.shared.inFlight }
    /// Uploads the server declined and that were stopped, until the person dismisses them.
    private var refused: [BackgroundUploader.Refused] { BackgroundUploader.shared.refused }

    var body: some View {
        if !inFlight.isEmpty || !refused.isEmpty || foregroundProgress != nil {
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
                                .lineLimit(1)
                            Text(notice.message)
                                .font(.brand(.caption))
                                .foregroundStyle(theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Button {
                            BackgroundUploader.shared.dismissRefusal(notice.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.brand(.caption, weight: .semibold))
                                .foregroundStyle(theme.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss")
                    }
                    .accessibilityElement(children: .contain)
                }

                ForEach(inFlight) { upload in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Uploading \(upload.fileName)")
                            .font(.brand(.caption))
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                        ProgressView(value: upload.progress)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        "Uploading \(upload.fileName), \(Int(upload.progress * 100)) percent. "
                        + "This continues if you leave the app.")
                }
                if let foregroundProgress {
                    // Ingestion runs after the upload's 200, so this stays up until the server
                    // reports the file readable — not until the bytes land.
                    VStack(alignment: .leading, spacing: 4) {
                        Text(foregroundProgress < 1 ? "Uploading…" : "Reading the document…")
                            .font(.brand(.caption))
                            .foregroundStyle(theme.textSecondary)
                        ProgressView(value: foregroundProgress)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(theme.surface)
        }
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
