import Foundation
#if canImport(Darwin)
import Observation
#endif

// MARK: - Connected services

/// A drive's sign-in page, while it is on screen.
struct CloudConsentPage: Identifiable, Equatable, Sendable {
    let drive: CloudDrive
    let url: URL

    var id: String { drive.rawValue + "|" + url.absoluteString }
}

/// You → Connected services: the web's Settings card of the same name
/// (`src/pages/Settings.jsx`, "Connected services").
///
/// ## Why the browser is closed by hand
///
/// Connecting is the drive's own consent page, and it ends where the server sends it: the drive
/// redirects to the platform, which keeps the token and then shows the **web** app's Settings
/// page (`/settings?cloud=…&connected=1`). It never redirects to this app, and there is no way to
/// ask it to. So the page is shown in an in-app Safari view (Google refuses its sign-in inside an
/// embedded web view, and an authentication session would wait for a callback that never
/// comes); the person closes it when the drive says they are done, and `browserDidClose`
/// reads the connections again. That read is the only honest signal: the row turns to
/// "Connected as …" if the token landed, and stays on Connect if they backed out.
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class CloudConnectionsViewModel {

    enum Copy {
        static let notConfigured = "Not configured on this server."
        static let invitation = "Save files to it, and import documents from it."
        static let footer =
            "Files you save go to your own drive; files you import are copied into your Emperor storage and read like an upload. The connection belongs to your account, so it works on the web too, and Disconnect ends it."
        static let howToConnect =
            "Connecting opens the drive's sign-in page. When it says you're done — it may finish on Emperor's web page — close it, and this screen checks again."
        static let loadFailed = "Your connected services couldn't be loaded."

        static func connected(_ connection: CloudDriveConnection) -> String {
            connection.email.map { "Connected as \($0)" } ?? "Connected"
        }
    }

    private(set) var connections: [CloudDriveConnection] = []
    private(set) var state: LoadState = .idle
    /// The drive a Connect or Disconnect is running for; its button waits.
    private(set) var busy: CloudDrive?
    /// What the last action came to, for one line on the screen. Cleared by the next action.
    private(set) var notice: String?
    /// The sign-in page to show. The view presents it and calls `browserDidClose` once it goes.
    var consentPage: CloudConsentPage?

    private let service: any CloudDriveProviding

    init(service: any CloudDriveProviding) {
        self.service = service
    }

    // MARK: - Presentation

    var connectedDrives: [CloudDrive] { connections.filter(\.connected).map(\.drive) }

    /// The line under a drive's name.
    func status(of connection: CloudDriveConnection) -> String {
        if !connection.configured { return Copy.notConfigured }
        if connection.connected { return Copy.connected(connection) }
        return Copy.invitation
    }

    func isBusy(_ drive: CloudDrive) -> Bool { busy == drive }

    // MARK: - Loading

    func load() async {
        if connections.isEmpty { state = .loading }
        do {
            connections = try await service.connections()
            state = .loaded
        } catch {
            // The rows already shown stay: a failed re-check must not blank a screen that was
            // right a moment ago.
            state = .failed(LoadFailure(error))
        }
    }

    // MARK: - Connecting

    /// Fetches the drive's sign-in page for the view to open. The server's refusal — a drive not
    /// set up here, a plan without it — becomes the notice.
    func connect(_ drive: CloudDrive) async {
        guard busy == nil else { return }
        busy = drive
        notice = nil
        defer { busy = nil }
        do {
            consentPage = CloudConsentPage(drive: drive, url: try await service.connectURL(for: drive))
        } catch {
            notice = CloudDriveWording.message(for: error)
        }
    }

    /// The sign-in page has gone — closed, or finished. Reads the connections again and says how
    /// the drive stands.
    func browserDidClose(_ drive: CloudDrive) async {
        consentPage = nil
        let wasConnected = connections.first { $0.drive == drive }?.connected ?? false
        await load()
        guard case .loaded = state,
              let now = connections.first(where: { $0.drive == drive }) else { return }
        if now.connected, !wasConnected {
            notice = "\(now.label) is connected."
        } else if !now.connected {
            notice = "\(now.label) is not connected. If you finished signing in, check again in a moment."
        }
    }

    func disconnect(_ drive: CloudDrive) async {
        guard busy == nil else { return }
        busy = drive
        notice = nil
        defer { busy = nil }
        do {
            try await service.disconnect(drive)
            notice = "\(drive.label) is disconnected."
        } catch {
            notice = CloudDriveWording.message(for: error)
        }
        await load()
    }
}

// MARK: - My Files: which drives, and Save to …

/// What My Files needs to know about the drives: which are connected — the Import entry and each
/// "Save to …" action are offered only for those — and the export itself.
///
/// Read quietly. My Files works the same with no drive, so a failed read leaves the actions as
/// they were and says nothing; a stale "connected" is answered by the server's own sentence when
/// the action is tried.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class CloudFileActionsViewModel {

    private(set) var connectedDrives: [CloudDrive] = []
    /// The path of the document being saved, so its row can say so.
    private(set) var exportingPath: String?
    /// "Order.pdf saved to Google Drive." Shown once, then cleared.
    var notice: String?
    /// The reason a save failed, for an alert.
    var failure: CloudExportFailure?

    private let service: any CloudDriveProviding

    init(service: any CloudDriveProviding) {
        self.service = service
    }

    var offersImport: Bool { !connectedDrives.isEmpty }

    /// "Import from Google Drive" with one drive connected; "Import from a drive" with both,
    /// since the sheet then asks which.
    var importTitle: String {
        connectedDrives.count == 1 ? "Import from \(connectedDrives[0].label)" : "Import from a drive"
    }

    func refresh() async {
        guard let rows = try? await service.connections() else { return }
        connectedDrives = rows.filter(\.connected).map(\.drive)
    }

    var isExporting: Bool { exportingPath != nil }

    func export(_ file: FileNode.StoredFile, to drive: CloudDrive) async {
        guard exportingPath == nil else { return }
        exportingPath = file.path
        notice = nil
        failure = nil
        defer { exportingPath = nil }
        do {
            _ = try await service.export(fileName: file.name, folderName: file.folderPath, to: drive)
            notice = "\(DisplayText.fileName(file.name)) saved to \(drive.label)."
        } catch {
            failure = CloudExportFailure(drive: drive, message: CloudDriveWording.message(for: error))
        }
    }
}

/// A save to a drive that did not happen, and why, in the server's words.
struct CloudExportFailure: Identifiable, Equatable, Sendable {
    let drive: CloudDrive
    let message: String

    var id: String { drive.rawValue + "|" + message }
    var title: String { "Couldn't save to \(drive.label)" }
}

// MARK: - Import

/// How one chosen file fared.
enum CloudImportOutcome: Equatable, Sendable {
    case waiting
    case importing
    /// Stored, under the name the server gave it.
    case imported(storedName: String)
    case failed(String)
    /// Not tried: an earlier file was refused for a reason that would refuse this one too.
    case skipped(String)
}

/// My Files → Import from a drive: the web's import modal (`src/pages/MyFilesPage.jsx`,
/// `openImport` / `doImport`).
///
/// Pick a connected drive, tick files from its recent fifty, choose a folder, and import. The
/// files go **one at a time**, as on the web: each import downloads the whole file on the server
/// and writes it, so firing them together would only queue them there. Every file's outcome is
/// kept and shown, not just the first failure.
///
/// - Important: a **coded** refusal — the plan has no cloud sync, or this month's documents or
///   the storage are used up — stops the run, and the files after it are marked not tried. The
///   same refusal would come back for each of them (`ChunkOutcome` makes the same call for
///   uploads).
///
/// The folder list is My Files' own, and the top level is not offered: the web's dialog offers
/// it, but a document there is invisible in the web's own My Files view, which is why uploads
/// from this app never go there either (`MyFilesViewModel.uploadDestination`).
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class CloudImportViewModel {

    enum Copy {
        static let notConfigured = "Google Drive and OneDrive aren't set up on this server yet."
        static let notConnected =
            "No drive is connected. Connect Google Drive or OneDrive under \(CloudDriveWording.place), then import from here."
        /// The web's own explanation for an empty list.
        static let empty =
            "No importable files in this drive. Google's own Docs and Sheets can't be downloaded as files, so they are left out."
        static let listNote = "The fifty most recently changed files."
    }

    /// Why the sheet has nothing to list, when no drive can be used.
    enum Unavailable: Equatable, Sendable {
        case notConfigured
        case notConnected

        var message: String {
            switch self {
            case .notConfigured: return Copy.notConfigured
            case .notConnected: return Copy.notConnected
            }
        }
    }

    private(set) var drives: [CloudDrive] = []
    private(set) var drive: CloudDrive?
    private(set) var unavailable: Unavailable?
    private(set) var files: [CloudDriveFile] = []
    private(set) var state: LoadState = .idle
    private(set) var selected: Set<String> = []
    /// The folder the files go into — one of `destinations`.
    var destination: String
    let destinations: [String]
    private(set) var outcomes: [String: CloudImportOutcome] = [:]
    private(set) var isImporting = false
    /// Set once a run has finished.
    private(set) var summary: String?

    private let service: any CloudDriveProviding

    /// - Parameters:
    ///   - destinations: folder paths, `/`-joined, in the order to list them.
    ///   - initialDestination: where the files go unless the person chooses otherwise — the open
    ///     folder, or at the top level the same folder an upload would use.
    init(service: any CloudDriveProviding, destinations: [String], initialDestination: String) {
        self.service = service
        var paths = destinations.filter { !FileBrowser.normalized($0).isEmpty }
        let start = FileBrowser.normalized(initialDestination)
        let initial = start.isEmpty ? FileLibraryViewModel.uploadFolder : start
        if !paths.contains(initial) { paths.append(initial) }
        self.destinations = paths
        self.destination = initial
    }

    // MARK: - Presentation

    var presentation: ListPresentation { ListPresentation(state: state, isEmpty: files.isEmpty) }

    var title: String { drive.map { "Import from \($0.label)" } ?? "Import from a drive" }

    var hasRun: Bool { summary != nil }

    var canImport: Bool { !isImporting && !hasRun && !chosen.isEmpty && drive != nil }

    /// The chosen files, in the drive's order.
    var chosen: [CloudDriveFile] { files.filter { selected.contains($0.id) } }

    /// "Import 3", or "Import" with nothing ticked — the web's button.
    var importButtonTitle: String {
        if isImporting { return "Importing…" }
        return selected.isEmpty ? "Import" : "Import \(selected.count)"
    }

    func isSelected(_ file: CloudDriveFile) -> Bool { selected.contains(file.id) }

    func outcome(of file: CloudDriveFile) -> CloudImportOutcome? { outcomes[file.id] }

    /// "Bakshi / 2025 / Writs".
    nonisolated static func label(forFolder path: String) -> String {
        path.split(separator: "/").map { DisplayText.fileName(String($0)) }.joined(separator: " / ")
    }

    /// "1.2 MB · 3 Oct 2026", or whichever of the two is known.
    func detail(for file: CloudDriveFile, now: Date = Date()) -> String? {
        let parts = [file.sizeLabel, file.modifiedDate.map { FileBrowser.dayLabel(for: $0, now: now) }]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Loading

    /// Finds the connected drives — Google first when both are, as the web chooses — and lists
    /// the first.
    func load() async {
        state = .loading
        let rows: [CloudDriveConnection]
        do {
            rows = try await service.connections()
        } catch {
            state = .failed(LoadFailure(error))
            return
        }
        drives = rows.filter(\.connected).map(\.drive)
        guard let first = drives.first else {
            unavailable = rows.contains(where: \.configured) ? .notConnected : .notConfigured
            drive = nil
            files = []
            state = .loaded
            return
        }
        unavailable = nil
        await list(drive.flatMap { drives.contains($0) ? $0 : nil } ?? first)
    }

    /// Switches drive. What was ticked in the other one is let go: ids belong to a drive.
    func choose(_ drive: CloudDrive) async {
        guard drives.contains(drive), drive != self.drive, !isImporting else { return }
        await list(drive)
    }

    private func list(_ drive: CloudDrive) async {
        self.drive = drive
        selected = []
        outcomes = [:]
        summary = nil
        files = []
        state = .loading
        do {
            let listed = try await service.files(in: drive)
            guard self.drive == drive else { return }
            files = listed
            state = .loaded
        } catch {
            guard self.drive == drive else { return }
            state = .failed(LoadFailure(message: CloudDriveWording.message(for: error), error: error))
        }
    }

    // MARK: - Choosing

    func toggle(_ file: CloudDriveFile) {
        guard !isImporting, !hasRun else { return }
        if selected.contains(file.id) {
            selected.remove(file.id)
        } else {
            selected.insert(file.id)
        }
    }

    // MARK: - Importing

    /// Imports the ticked files in order and reports each. Returns how many arrived, so the
    /// caller knows whether My Files needs reading again.
    @discardableResult
    func importSelected() async -> Int {
        guard canImport, let drive else { return 0 }
        let batch = chosen
        let folder = destination
        isImporting = true
        defer { isImporting = false }
        for file in batch { outcomes[file.id] = .waiting }

        var imported = 0
        var stop: String?
        for file in batch {
            if let stop {
                outcomes[file.id] = .skipped(stop)
                continue
            }
            outcomes[file.id] = .importing
            do {
                let result = try await service.importFile(file, from: drive, into: folder)
                let stored = result.fileName.flatMap { $0.isEmpty ? nil : $0 } ?? file.name
                outcomes[file.id] = .imported(storedName: stored)
                imported += 1
            } catch {
                let message = CloudDriveWording.message(for: error)
                outcomes[file.id] = .failed(message)
                if (error as? APIError)?.refusal != nil {
                    stop = "Not tried — \(message)"
                }
            }
        }
        summary = Self.summary(imported: imported, of: batch.count, into: folder)
        return imported
    }

    /// The web's "Imported 3 files — making them searchable now", and what did not arrive.
    nonisolated static func summary(imported: Int, of total: Int, into folder: String) -> String {
        let place = label(forFolder: folder)
        let noun = imported == 1 ? "file" : "files"
        if imported == total {
            return "Imported \(imported) \(noun) into \(place) — making them searchable now."
        }
        if imported == 0 {
            return total == 1 ? "The file wasn't imported." : "None of the \(total) files were imported."
        }
        return "Imported \(imported) of \(total) files into \(place) — making them searchable now. The rest are marked below."
    }
}

extension LoadFailure {
    /// A failure classified from `error`, but worded with `message`.
    init(message: String, error: Error) {
        self.init(error)
        self.message = message
    }
}
