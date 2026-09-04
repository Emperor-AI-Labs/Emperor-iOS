import Foundation
import SwiftUI

/// Uploads that keep going after the user leaves the app.
///
/// The foreground path in `UploadService` is an `AsyncThrowingStream` driven by a `Task`. That
/// is the right shape for attaching a two-page order and watching it land, and the wrong shape
/// for the case this type exists for: a 200-page paperbook, scanned at a registry counter, on a
/// connection that drops every time the lift moves. The task is suspended the moment the app
/// goes to the background and killed if the system wants the memory, and the user comes back to
/// a progress bar that quietly reset.
///
/// A background `URLSession` is handed to the system instead. It transfers with the app
/// suspended, survives the app being terminated, and **relaunches the app** to deliver the
/// result. That last part is what shapes everything here:
///
/// - **Nothing may live only in memory.** On relaunch there is no view model, no stream, no
///   closure — only a task and its `taskDescription`. Which upload a chunk belongs to has to be
///   recoverable from disk, which is `UploadManifestStore`.
/// - **Bodies must be files.** A background session refuses `httpBody` outright; it takes
///   `uploadTask(with:fromFile:)` and nothing else. Each chunk's multipart body is written out
///   before the transfer starts.
/// - **The document must be copied first.** The picker hands over a security-scoped URL that is
///   revoked when the sheet closes — long before a large upload finishes.
///
/// ## Why every chunk goes at once
///
/// The server writes each chunk at `chunkIndex * chunkSize` as long as `chunkSize` is sent, so
/// order does not matter. Every chunk is therefore enqueued immediately rather than chained,
/// and the system schedules and retries them as it sees fit. A chain would be the more obvious
/// design and would break in the middle every time the app was killed, because the completion
/// that was supposed to enqueue the successor never ran.
///
/// ## What is not proven
///
/// The arithmetic, the manifest and the body encoding are covered by `BackgroundUploadTests`
/// and `UploadPersistenceTests` on Linux. **The lifecycle below is not tested anywhere.** A
/// simulator does not evict apps the way a phone under memory pressure does, and the relaunch
/// path in particular cannot be exercised without a device. Treat the delegate callbacks as
/// unverified until someone has watched a real scan survive a real backgrounding.
@MainActor
@Observable
final class BackgroundUploader {

    /// One instance per process. A background session is bound to its identifier, and
    /// constructing a second with the same one is a runtime error — so the session, and
    /// therefore this, has to be a single shared thing rather than something a view creates.
    static let shared = BackgroundUploader()

    /// Stable across launches: this string is how the system finds the session belonging to
    /// this app when it relaunches it. Changing it strands every transfer already in flight.
    static let sessionIdentifier = "com.emperorailabs.emperor.upload"

    /// Uploads still going, newest first. Read by the library screen.
    private(set) var inFlight: [UploadManifest] = []

    /// Set by the app delegate when the system relaunches us to deliver events, and called once
    /// the session says it has finished delivering them. Not calling it makes the system
    /// consider the app unresponsive and stop relaunching it.
    var backgroundCompletionHandler: (() -> Void)?

    private let store: UploadManifestStore
    private var session: URLSession!
    private let delegate = Delegate()

    /// Set by the app once the user is signed in, because a chunk request needs the token and
    /// the caller id and this object outlives any one screen.
    var client: APIClient?

    private init(store: UploadManifestStore = UploadManifestStore(directory: UploadManifestStore.defaultDirectory())) {
        self.store = store

        self.session = URLSession(
            configuration: Self.makeConfiguration(), delegate: delegate, delegateQueue: nil)
        delegate.owner = self

        self.inFlight = store.all().filter { !$0.isComplete }
    }

    private static func makeConfiguration() -> URLSessionConfiguration {
        #if DEBUG
        // A background session ignores `URLProtocol`, so the UI tests' stub transport cannot
        // intercept it — a real background configuration under test would put real requests on
        // the wire and leave real state in the shared session store, which then leaks into the
        // next run. An ephemeral configuration keeps the object usable (the library screen
        // reads `inFlight` on every appearance) while nothing escapes.
        if UITestSupport.isActive { return .ephemeral }
        #endif

        let configuration = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
        // The user pressed a button and is watching. Discretionary would let the system defer
        // the whole thing to a charging window overnight, which is not what "upload this" means.
        configuration.isDiscretionary = false
        // Without this the app is never relaunched to hear about a transfer that finished while
        // it was dead, and the upload completes on the server while the app still shows it as
        // in progress forever.
        configuration.sessionSendsLaunchEvents = true
        // A large scan on a poor connection may take many hours. The default seven days is more
        // than generous, but the per-request default is not, and this session's requests are
        // the long ones.
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        return configuration
    }

    // MARK: - Starting

    enum StartError: LocalizedError {
        case notSignedIn
        case unreadable

        var errorDescription: String? {
            switch self {
            case .notSignedIn: return "You are signed out. Sign in and try again."
            case .unreadable: return "That document could not be read."
            }
        }
    }

    /// Copies the document somewhere the app controls, records a manifest, and hands every
    /// chunk to the system.
    ///
    /// - Parameter source: the picked file. Assumed to be inside a
    ///   `startAccessingSecurityScopedResource` pair already — the copy taken here is what the
    ///   upload actually reads, so the original may be revoked immediately afterwards.
    @discardableResult
    func start(source: URL, fileName: String, folderName: String) async throws -> UploadManifest {
        guard let client, let credentials = await client.currentCredentials() else {
            throw StartError.notSignedIn
        }

        let id = UUID().uuidString
        let payload = store.payloadDirectory(for: id)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)

        // Copy before anything else. Everything after this point reads only the copy, so the
        // picker's scoped access can end the moment this returns.
        let copy = payload.appendingPathComponent("source.bin")
        do {
            try FileManager.default.copyItem(at: source, to: copy)
        } catch {
            try? FileManager.default.removeItem(at: payload)
            throw StartError.unreadable
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: copy.path)[.size] as? Int) ?? nil
        guard let totalBytes = size else {
            try? FileManager.default.removeItem(at: payload)
            throw StartError.unreadable
        }

        let manifest = UploadManifest(
            id: id,
            fileName: fileName,
            folderName: folderName,
            totalBytes: totalBytes,
            // A phone on a courtroom connection retries a failed chunk from the start of that
            // chunk, so smaller chunks lose less on each drop.
            chunkSize: UploadService.constrainedChunkSize,
            sourcePath: copy.path,
            createdAt: Date())

        try store.save(manifest)
        inFlight.insert(manifest, at: 0)

        try await enqueue(manifest.pending, of: manifest, credentials: credentials)
        return manifest
    }

    // MARK: - Resuming

    /// Called on launch and whenever the app becomes active.
    ///
    /// Three jobs: re-enqueue anything the system dropped, poll for ingestion on uploads whose
    /// bytes all landed while the app was away, and clear out the residue of crashes. The last
    /// matters more than it sounds — every abandoned upload is a copy of a client's document
    /// sitting on the device.
    func resume() async {
        store.discardOrphanedPayloads()
        store.discardExpired(now: Date())

        let manifests = store.all()
        inFlight = manifests.filter { !$0.isComplete }

        guard let client, let credentials = await client.currentCredentials() else { return }

        // Anything the system already has in hand must not be enqueued twice.
        let running = Set(
            await session.allTasks.compactMap {
                UploadManifest.parseTaskDescription($0.taskDescription).map { "\($0.id)#\($0.index)" }
            })

        for manifest in manifests {
            if manifest.isComplete {
                await finish(manifest)
                continue
            }
            let missing = manifest.pending.filter {
                !running.contains(manifest.taskDescription(for: $0))
            }
            try? await enqueue(missing, of: manifest, credentials: credentials)
        }
    }

    // MARK: - Enqueuing

    private func enqueue(
        _ indices: [Int], of manifest: UploadManifest, credentials: Credentials
    ) async throws {
        guard let client else { throw StartError.notSignedIn }
        let source = URL(fileURLWithPath: manifest.sourcePath)

        for index in indices {
            let boundary = MultipartChunk.boundary()
            let fields = MultipartChunk.Fields(
                userID: credentials.userIDString,
                fileName: manifest.fileName,
                folderName: manifest.folderName,
                uploadID: manifest.id,
                chunkIndex: index,
                chunkCount: manifest.chunkCount,
                chunkSize: manifest.chunkSize,
                totalBytes: manifest.totalBytes)

            let bodyURL = store.chunkBodyURL(for: manifest.id, index: index)
            do {
                try MultipartChunk.write(
                    chunkAt: manifest.range(of: index), from: source, to: bodyURL,
                    fields: fields, boundary: boundary)
            } catch {
                // The copy is gone or truncated. Nothing further will work for this upload, and
                // continuing would send chunks that place bytes at the wrong offsets.
                store.discard(id: manifest.id)
                inFlight.removeAll { $0.id == manifest.id }
                throw error
            }

            var request = try await client.makeRequest(
                "POST", "/upload-chunk", requiresAuth: true)
            request.setValue(
                MultipartChunk.contentType(boundary: boundary),
                forHTTPHeaderField: "Content-Type")
            request.setValue(manifest.id, forHTTPHeaderField: "x-upload-id")
            request.setValue(String(manifest.totalBytes), forHTTPHeaderField: "x-total-bytes")

            let task = session.uploadTask(with: request, fromFile: bodyURL)
            // The only thing that survives into a relaunched process. Without it a delivered
            // chunk cannot be attributed to anything and the upload stalls at 99%.
            task.taskDescription = manifest.taskDescription(for: index)
            task.resume()
        }
    }

    // MARK: - Delegate callbacks

    fileprivate func chunkFinished(id: String, index: Int, error: Error?, statusCode: Int?) async {
        let succeeded = error == nil && (statusCode.map { (200..<300).contains($0) } ?? false)

        guard succeeded else {
            // Left pending deliberately. The system retries transport failures on its own, and
            // anything it gives up on is re-enqueued by `resume()` next time the app opens —
            // which is the right moment to try again anyway, since the user is present and
            // probably back on a usable connection.
            return
        }

        try? FileManager.default.removeItem(
            at: store.chunkBodyURL(for: id, index: index))

        guard let updated = store.recordCompletion(id: id, index: index) else { return }
        if let position = inFlight.firstIndex(where: { $0.id == id }) {
            if updated.isComplete {
                inFlight.remove(at: position)
            } else {
                inFlight[position] = updated
            }
        }

        if updated.isComplete { await finish(updated) }
    }

    /// Every chunk has landed. The bytes are on the server; the document is not yet usable.
    ///
    /// Assembly, text extraction and indexing all run after the last response closed, and a
    /// failure in any of them produces no HTTP error at all — so this polls, exactly as the
    /// foreground path does. Doing it here rather than in a view model matters: the screen that
    /// started the upload may never be opened again.
    private func finish(_ manifest: UploadManifest) async {
        defer { store.discard(id: manifest.id) }
        guard let client else { return }
        _ = try? await UploadService(client: client).waitForIngestion(
            fileName: manifest.fileName, folderName: manifest.folderName)
        NotificationCenter.default.post(name: .emperorUploadDidFinish, object: manifest.id)
    }

    fileprivate func finishedDeliveringEvents() {
        // The system gives roughly thirty seconds after this before it stops being patient.
        backgroundCompletionHandler?()
        backgroundCompletionHandler = nil
    }

    // MARK: - The delegate itself

    /// Separate from the observable object because `URLSession` retains its delegate for the
    /// life of the session and calls it on its own queue, neither of which fits a `@MainActor`
    /// type. Everything here does nothing but hop back.
    private final class Delegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        weak var owner: BackgroundUploader?

        func urlSession(
            _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
        ) {
            guard let parsed = UploadManifest.parseTaskDescription(task.taskDescription) else { return }
            let status = (task.response as? HTTPURLResponse)?.statusCode
            Task { @MainActor [owner] in
                await owner?.chunkFinished(
                    id: parsed.id, index: parsed.index, error: error, statusCode: status)
            }
        }

        func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
            Task { @MainActor [owner] in owner?.finishedDeliveringEvents() }
        }
    }
}

extension Notification.Name {
    /// Posted when a background upload has been ingested, so a library already on screen can
    /// re-read itself rather than showing a document that is not there yet.
    static let emperorUploadDidFinish = Notification.Name("EmperorUploadDidFinish")
}
