import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The two drives the platform can reach (`CLOUD_PROVIDERS` in `sync-server.js`).
///
/// `rawValue` is the key every `/cloud/*` route takes as `provider`, and the key under
/// `providers` in `GET /cloud/connections`.
enum CloudDrive: String, CaseIterable, Codable, Identifiable, Sendable {
    case google
    case microsoft

    var id: String { rawValue }

    /// The server's own label, repeated so a row can be drawn before the first answer arrives.
    var label: String {
        switch self {
        case .google: return "Google Drive"
        case .microsoft: return "OneDrive"
        }
    }
}

/// One drive's row of `GET /cloud/connections`.
///
/// The connection belongs to the account, not to this phone: the token is held by the server, so
/// a drive connected on the web reads as connected here, and Disconnect here ends it there too.
struct CloudDriveConnection: Equatable, Identifiable, Sendable {
    let drive: CloudDrive
    /// The server's label, or the drive's own when the server sent none.
    let label: String
    /// Whether this server has the drive's sign-in set up at all. When it does not, connecting
    /// cannot work, so the row says so rather than offering a button.
    let configured: Bool
    /// Whether the account holds a token for it.
    let connected: Bool
    /// The drive account's address, when the sign-in carried one.
    let email: String?

    var id: String { drive.rawValue }
}

/// One file in a drive, as `GET /cloud/list` describes it: the fifty most recently changed,
/// folders and Google's own Docs and Sheets already left out by the server (they cannot be
/// downloaded as bytes, so an import of one would only fail).
///
/// Built by `lib/googleDrive.js` and `lib/onedrive.js` `listFiles`: `{id, name, mime, size,
/// modified}`. OneDrive sends `mime: null`; `size` is `0` when the drive did not say.
struct CloudDriveFile: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    var mime: String?
    var size: Int?
    /// ISO 8601, from the drive.
    var modified: String?

    var modifiedDate: Date? { WireDate.parse(modified) }

    /// "1.2 MB", or `nil` when the drive gave no size — the web's `fmtSize` in
    /// `src/pages/MyFilesPage.jsx`, which prints nothing for zero.
    var sizeLabel: String? { CloudDriveFile.sizeLabel(size ?? 0) }

    /// `fmtSize`: bytes under 1 KB, whole KB (`Math.round`) under 1 MB, then MB to one place
    /// (`toFixed(1)`). In integers, so both platforms round half up exactly as JavaScript does —
    /// a byte count over a power of two is exact, so there is nothing for a double to blur.
    static func sizeLabel(_ bytes: Int) -> String? {
        guard bytes > 0 else { return nil }
        if bytes < 1024 { return "\(bytes) B" }
        let mb = 1024 * 1024
        if bytes < mb { return "\((bytes * 2 + 1024) / 2048) KB" }
        let tenths = (bytes * 20 + mb) / (mb * 2)
        return "\(tenths / 10).\(tenths % 10) MB"
    }
}

/// What `POST /cloud/export` answers: the new file's id and name in the drive, and a link to it.
struct CloudDriveExport: Codable, Equatable, Sendable {
    var success: Bool?
    var error: String?
    var id: String?
    var name: String?
    var url: String?
}

/// What `POST /cloud/import` answers once the bytes are on disk: the name it was stored under
/// (sanitised by the server, so it may differ from the drive's), the folder, and the size.
/// Reading — text, OCR, indexing — carries on in the background, as after an upload.
struct CloudDriveImport: Codable, Equatable, Sendable {
    var success: Bool?
    var error: String?
    var fileName: String?
    var folderName: String?
    var size: Int?
}

/// The seam the Connected services screen, the import sheet and the "Save to …" action are
/// built against.
protocol CloudDriveProviding: Sendable {
    /// Every drive, in `CloudDrive` order, whether set up on this server or not.
    func connections() async throws -> [CloudDriveConnection]
    /// The drive's own sign-in page, for a browser.
    func connectURL(for drive: CloudDrive) async throws -> URL
    func disconnect(_ drive: CloudDrive) async throws
    /// Copies one stored document into the drive. `folderName` is the document's folder, `""`
    /// for the top level.
    func export(fileName: String, folderName: String, to drive: CloudDrive) async throws
        -> CloudDriveExport
    func files(in drive: CloudDrive) async throws -> [CloudDriveFile]
    /// Copies one drive file into My Files, into `folderName`.
    func importFile(_ file: CloudDriveFile, from drive: CloudDrive, into folderName: String)
        async throws -> CloudDriveImport
}

/// The six `/cloud/*` routes behind Settings → Connected services and My Files' Import on the
/// web (`src/lib/api.js`, "Cloud Drive").
///
/// ## The refusal is the message
///
/// Every refusal on these routes is a sentence written for the person — "Google Drive is not
/// connected — connect it in Settings → Connected services", "Google Drive read access was not
/// granted — Disconnect and reconnect Google Drive in Settings" — sent as `{success:false,error}`
/// with a 4xx (409 for a drive that is not ready, 404 for a document that is not there). The web
/// shows it as it is (`cloudJson`), and so does this client, through `APIError.server` — except
/// that it names this app's way to the screen (`CloudDriveWording.forPhone`). The plan refusals
/// these routes share with uploads (`FEATURE_NOT_IN_PLAN`, `DOCUMENT_LIMIT`, `STORAGE_LIMIT`)
/// arrive coded and are worded by `DisplayText` like every other.
///
/// Identity goes as everywhere else: the bearer token always, `userId` in the query of the reads
/// (added by `APIClient.makeRequest`) and in the body of the writes.
struct CloudDriveService: CloudDriveProviding {
    let client: APIClient

    private struct ConnectionsBody: Decodable {
        struct Row: Decodable {
            var label: String?
            var configured: Bool?
            var connected: Bool?
            var email: String?
        }
        var success: Bool?
        var error: String?
        var providers: [String: Row]?
    }

    func connections() async throws -> [CloudDriveConnection] {
        let body = try await withRetry {
            let request = try await client.makeRequest("GET", "/cloud/connections")
            return try await client.send(request, as: ConnectionsBody.self)
        }
        if body.success == false {
            try CaseService.throwIfUnsuccessful(success: body.success, error: body.error)
        }
        let rows = body.providers ?? [:]
        return CloudDrive.allCases.map { drive in
            let row = rows[drive.rawValue]
            let label = row?.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let email = row?.email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return CloudDriveConnection(
                drive: drive,
                label: label.isEmpty ? drive.label : label,
                configured: row?.configured ?? false,
                connected: row?.connected ?? false,
                email: email.isEmpty ? nil : email)
        }
    }

    private struct ConnectBody: Decodable {
        var success: Bool?
        var error: String?
        var url: String?
    }

    /// - Important: the page this opens finishes on the platform's **web** app — the drive sends
    ///   the browser back to the server, which keeps the token and then shows the web's Settings
    ///   page. Nothing comes back to the app, so the caller learns the outcome by reading
    ///   `connections()` again once the browser is closed.
    func connectURL(for drive: CloudDrive) async throws -> URL {
        let request = try await client.makeRequest(
            "GET", "/cloud/connect", query: ["provider": drive.rawValue])
        let body = try await client.send(request, as: ConnectBody.self)
        try CaseService.throwIfUnsuccessful(success: body.success ?? (body.url != nil), error: body.error)
        // Only ever a web page: anything else is not something to hand a browser.
        guard let raw = body.url?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: raw), url.scheme?.lowercased() == "https", url.host != nil
        else {
            throw APIError.decoding("The server sent no sign-in page for \(drive.label).")
        }
        return url
    }

    private struct DisconnectPayload: Encodable {
        let userId: String
        let provider: String
    }

    func disconnect(_ drive: CloudDrive) async throws {
        let userID = try await currentUserID()
        let request = try await client.makeRequest(
            "POST", "/cloud/disconnect",
            body: DisconnectPayload(userId: userID, provider: drive.rawValue))
        let response = try await client.send(request, as: WriteResponse.self)
        try CaseService.throwIfUnsuccessful(success: response.success, error: response.error)
    }

    private struct ExportPayload: Encodable {
        let userId: String
        let provider: String
        let folderName: String
        let fileName: String
    }

    /// The top level goes as `"."`, as the web sends it (`item.folderName || '.'`).
    func export(fileName: String, folderName: String, to drive: CloudDrive) async throws
        -> CloudDriveExport {
        let userID = try await currentUserID()
        let request = try await client.makeRequest(
            "POST", "/cloud/export",
            body: ExportPayload(
                userId: userID, provider: drive.rawValue,
                folderName: Self.wireFolder(folderName), fileName: fileName))
        let response = try await client.send(request, as: CloudDriveExport.self)
        try CaseService.throwIfUnsuccessful(success: response.success, error: response.error)
        return response
    }

    private struct ListBody: Decodable {
        var success: Bool?
        var error: String?
        var files: [CloudDriveFile]?
    }

    func files(in drive: CloudDrive) async throws -> [CloudDriveFile] {
        let request = try await client.makeRequest(
            "GET", "/cloud/list", query: ["provider": drive.rawValue])
        let body = try await client.send(request, as: ListBody.self)
        try CaseService.throwIfUnsuccessful(success: body.success, error: body.error)
        return (body.files ?? []).filter { !$0.id.isEmpty }
    }

    private struct ImportPayload: Encodable {
        let userId: String
        let provider: String
        let fileId: String
        let fileName: String
        let folderName: String
    }

    func importFile(_ file: CloudDriveFile, from drive: CloudDrive, into folderName: String)
        async throws -> CloudDriveImport {
        let userID = try await currentUserID()
        let request = try await client.makeRequest(
            "POST", "/cloud/import",
            body: ImportPayload(
                userId: userID, provider: drive.rawValue, fileId: file.id,
                fileName: file.name, folderName: Self.wireFolder(folderName)))
        let response = try await client.send(request, as: CloudDriveImport.self)
        try CaseService.throwIfUnsuccessful(success: response.success, error: response.error)
        return response
    }

    /// `""` (the top level) as `"."`, which is how the web spells it to both writes.
    static func wireFolder(_ folder: String) -> String {
        let trimmed = FileBrowser.normalized(folder)
        return trimmed.isEmpty ? "." : trimmed
    }

    private func currentUserID() async throws -> String {
        guard let credentials = await client.currentCredentials() else {
            throw APIError.notAuthenticated
        }
        return credentials.userIDString
    }
}

/// The server's sentences, pointed at this app's screens.
///
/// The refusals on `/cloud/*` send the person to "Settings → Connected services" or "Settings",
/// which is where the web keeps the card. Here it lives under You. Only those words change; the
/// rest is the server's own.
enum CloudDriveWording {
    static let place = "You → Connected services"

    static func forPhone(_ message: String) -> String {
        var text = message.replacingOccurrences(of: "Settings → Connected services", with: place)
        for ending in [" in Settings.", " in Settings"] where text.hasSuffix(ending) {
            text = String(text.dropLast(ending.count)) + " under \(place)"
                + (ending.hasSuffix(".") ? "." : "")
            break
        }
        return text
    }

    /// What to show for a failure on one of these routes.
    static func message(for error: Error) -> String {
        forPhone(DisplayText.message(for: error))
    }
}
