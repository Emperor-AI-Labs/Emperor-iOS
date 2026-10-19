import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One document a draft cites as an annexure — "Annexure P-1", "R-3" — as the platform's filing
/// registry holds it.
///
/// The model cites a document while drafting with an inline mention token
/// (`<@file.pdf:P-1>`, parsed here by `StreamContent`), and the platform records each one in the
/// registry as the turn is stored (`lib/filing/registry.js`). This client only **reads** that
/// registry: it never registers, re-marks or reorders an annexure.
///
/// The row's source path is deliberately not modelled. It is a storage location on the server,
/// and nothing on the phone has any use for it — every read is by chat and mark.
struct FilingAnnexure: Decodable, Equatable, Identifiable, Sendable {

    /// How the annexure goes into a filing.
    enum Treatment: String, Equatable, Sendable {
        /// The original document's own pages are attached — an order, a photograph, an ID.
        case original = "append"
        /// A true typed copy is prepared from the document's text — a faded or handwritten page.
        case typed
    }

    /// The registry's row id, as text. A number on the wire today; kept as text so a change of
    /// key type is not a decoding failure that hides every annexure.
    let id: String
    /// "P-1", "R-2". The key every other read is made by.
    let mark: String
    let title: String
    let treatment: Treatment
    /// `"n/a"`, `"pending"` or `"verified"` — whether a typed copy's text has been checked.
    let verifyStatus: String?
    let sortOrder: Int
    /// The pages of the source file this mark covers, when it covers only some of them.
    let pageFrom: Int?
    let pageTo: Int?
    /// Set when an earlier mark cites the very same file and page range — the same document
    /// cited twice. Its pages are attached once, under the earlier mark.
    let duplicateOf: String?

    var isTypedCopy: Bool { treatment == .typed }

    /// What the row's second line says: the form the annexure takes in the filing.
    var formLabel: String { isTypedCopy ? "Typed copy" : "Original" }

    /// "Pages 3–5", "Page 3", or nil for a whole document.
    var pageLabel: String? {
        guard let from = pageFrom else { return nil }
        guard let to = pageTo, to != from else { return "Page \(from)" }
        return "Pages \(from)–\(to)"
    }

    init(
        id: String, mark: String, title: String, treatment: Treatment,
        verifyStatus: String? = nil, sortOrder: Int = 0,
        pageFrom: Int? = nil, pageTo: Int? = nil, duplicateOf: String? = nil
    ) {
        self.id = id
        self.mark = mark
        self.title = title
        self.treatment = treatment
        self.verifyStatus = verifyStatus
        self.sortOrder = sortOrder
        self.pageFrom = pageFrom
        self.pageTo = pageTo
        self.duplicateOf = duplicateOf
    }

    private enum CodingKeys: String, CodingKey {
        case id, mark, title, treatment
        case verifyStatus = "verify_status"
        case sortOrder = "sort_order"
        case pageFrom = "page_from"
        case pageTo = "page_to"
        case duplicateOf = "duplicate_of"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mark = try c.decode(String.self, forKey: .mark)
        if let number = try? c.decode(Int.self, forKey: .id) {
            id = String(number)
        } else {
            id = (try? c.decode(String.self, forKey: .id)) ?? mark
        }
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        // The web treats anything that is not `typed` as an original (`ToolWorkspace.jsx`), so
        // an unknown treatment is read the same way rather than failing the whole list.
        let raw = (try? c.decodeIfPresent(String.self, forKey: .treatment)) ?? nil
        treatment = raw.flatMap(Treatment.init(rawValue:)) ?? .original
        verifyStatus = try? c.decodeIfPresent(String.self, forKey: .verifyStatus)
        sortOrder = Self.integer(c, .sortOrder) ?? 0
        pageFrom = Self.integer(c, .pageFrom)
        pageTo = Self.integer(c, .pageTo)
        duplicateOf = try? c.decodeIfPresent(String.self, forKey: .duplicateOf)
    }

    private static func integer(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int? {
        if let value = try? c.decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? c.decodeIfPresent(Double.self, forKey: key), value.isFinite {
            return Int(value)
        }
        return nil
    }

    // MARK: - Order

    /// The order the List of Annexures is read in: the registry's own order, then the mark.
    ///
    /// Marks compare by side and then by number, so P-2 comes before P-10 — the order a
    /// registry clerk reads them in, not the order a string sort puts them in.
    static func sorted(_ rows: [FilingAnnexure]) -> [FilingAnnexure] {
        rows.sorted { a, b in
            if a.sortOrder != b.sortOrder { return a.sortOrder < b.sortOrder }
            return markPrecedes(a.mark, b.mark)
        }
    }

    static func markPrecedes(_ a: String, _ b: String) -> Bool {
        let pa = parseMark(a), pb = parseMark(b)
        if let pa, let pb {
            if pa.side != pb.side { return pa.side < pb.side }
            if pa.number != pb.number { return pa.number < pb.number }
        }
        return a.uppercased() < b.uppercased()
    }

    /// "P-12" → ("P", 12). Nil for anything not shaped like a side and a number.
    static func parseMark(_ mark: String) -> (side: String, number: Int)? {
        let parts = mark.uppercased().split(separator: "-", maxSplits: 1)
        guard parts.count == 2, let number = Int(parts[1]), !parts[0].isEmpty else { return nil }
        return (String(parts[0]), number)
    }
}

/// One annexure's typed copy, as the platform renders it from the document's text.
enum TypedCopy: Equatable, Sendable {
    /// A ready HTML fragment, headed "TRUE TYPED COPY OF ANNEXURE …".
    case html(String)
    /// No typed copy for this mark — it is attached as an original. The reason is the
    /// platform's own sentence.
    case skipped(reason: String)
}

/// Every typed copy in a chat, concatenated in mark order by the platform.
struct TypedCopies: Equatable, Sendable {
    var html: String
    var marks: [String]
}

/// The pages of one original, as images — what a Word document can carry.
enum OriginalPages: Equatable, Sendable {
    /// Each page as image bytes (JPEG for a PDF's pages; the file itself for a photograph).
    case pages([Data])
    /// The same file and page range as an earlier mark, which already carries the pages.
    case duplicate(of: String)
}

/// Why an annexure could not be read, worded for the person holding the phone.
enum FilingAnnexureError: LocalizedError, Equatable {
    /// Declined on purpose — a plan that does not include filing. See `Refusal`.
    case refused(Refusal)
    /// This kind of file has no preview or page rendering. Persistent; trying again will not help.
    case unsupportedFile(mark: String)
    /// The registry declined, in a sentence written for a person — a typed copy whose document
    /// has not been read yet, a mark that is not in this chat.
    case declined(mark: String?, message: String)
    /// Anything else, with a sentence that says which annexure.
    case unavailable(mark: String?, message: String)

    var errorDescription: String? {
        switch self {
        case .refused(let refusal):
            return DisplayText.message(for: refusal)
        case .unsupportedFile(let mark):
            return "Annexure \(mark) is a kind of file that can't be shown or attached here."
        case .declined(_, let message), .unavailable(_, let message):
            return message
        }
    }

    var refusal: Refusal? {
        if case .refused(let refusal) = self { return refusal }
        return nil
    }

    /// Recasts whatever a read threw as this type, in words that name the annexure.
    ///
    /// The registry's own refusals (`FilingError`, answered as a 400) are written for a person —
    /// "no typed-copy text available for Annexure P-2 …" — so a 400's sentence is shown. Other
    /// statuses carry wording meant for a log, and are replaced.
    static func from(_ error: Error, mark: String?) -> FilingAnnexureError {
        if let own = error as? FilingAnnexureError { return own }
        let label = mark.map { "Annexure \($0)" } ?? "The list of annexures"
        guard let api = error as? APIError else {
            return .unavailable(mark: mark, message: "\(label) could not be read. \(error.localizedDescription)")
        }
        switch api {
        case .refused(let refusal):
            return .refused(refusal)
        case .server(let status, let message):
            switch status {
            case 400:
                return .declined(mark: mark, message: sentence(message, fallback: "\(label) could not be read."))
            case 404:
                return .unavailable(
                    mark: mark,
                    message: "\(label)'s document is no longer in your files. It may have been moved or deleted.")
            case 415:
                return mark.map { .unsupportedFile(mark: $0) }
                    ?? .unavailable(mark: nil, message: "That kind of file can't be shown here.")
            default:
                return .unavailable(mark: mark, message: "\(label) could not be prepared just now. Try again shortly.")
            }
        case .transport(let message), .maintenance(let message):
            return .unavailable(mark: mark, message: message)
        case .decoding:
            return .unavailable(mark: mark, message: "\(label) came back in a form this app could not read.")
        case .notAuthenticated, .invalidCredentials:
            return .unavailable(mark: mark, message: api.errorDescription ?? "Please sign in again.")
        }
    }

    /// The server's sentence with its first letter raised and a full stop, or the fallback.
    private static func sentence(_ text: String, fallback: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        let raised = trimmed.prefix(1).uppercased() + trimmed.dropFirst()
        return raised.hasSuffix(".") ? raised : raised + "."
    }
}

/// Reading a chat's annexures from the platform's filing registry.
protocol FilingAnnexureProviding: Sendable {
    /// Every annexure the chat's drafts cite, in the registry's order.
    func annexures(chatID: String) async throws -> [FilingAnnexure]
    /// The original document behind a mark, sliced to its page range: PDF bytes, or the image
    /// itself for a photograph. A Word original arrives already converted to PDF.
    func original(chatID: String, mark: String) async throws -> Data
    /// One mark's typed copy, or why it has none.
    func typedCopy(chatID: String, mark: String) async throws -> TypedCopy
    /// Every typed copy in the chat, as one block.
    func typedCopies(chatID: String) async throws -> TypedCopies
    /// One original's pages as images, for a Word document.
    func originalPages(chatID: String, mark: String) async throws -> OriginalPages
}

/// `FilingAnnexureProviding` against the platform (`lib/filing/index.js`).
///
/// Every route here is part of Filing Ready, which is outside the Free plan; such an account is
/// refused with a coded 402 (`FEATURE_NOT_IN_PLAN`) that arrives as `FilingAnnexureError.refused`.
struct FilingAnnexureService: FilingAnnexureProviding {
    let client: APIClient

    private struct ListBody: Decodable {
        var success: Bool?
        var annexures: [FilingAnnexure]?
        var error: String?
    }

    private struct TypedCopyBody: Decodable {
        var success: Bool?
        var html: String?
        var skipped: Bool?
        var reason: String?
        var marks: [String]?
        var error: String?
    }

    private struct PagesBody: Decodable {
        struct Page: Decodable { var base64: String?; var mime: String? }
        var success: Bool?
        var pages: [Page]?
        var duplicateOf: String?
        var error: String?

        enum CodingKeys: String, CodingKey {
            case success, pages, error
            case duplicateOf = "duplicate_of"
        }
    }

    func annexures(chatID: String) async throws -> [FilingAnnexure] {
        do {
            let request = try await client.makeRequest(
                "GET", "/filing/annexures", query: ["chatId": chatID])
            let body = try await client.send(request, as: ListBody.self)
            guard body.success != false else {
                throw APIError.server(status: 400, message: body.error ?? "")
            }
            return FilingAnnexure.sorted(body.annexures ?? [])
        } catch {
            throw FilingAnnexureError.from(error, mark: nil)
        }
    }

    func original(chatID: String, mark: String) async throws -> Data {
        do {
            let request = try await client.makeRequest(
                "GET", "/filing/annexures/original", query: ["chatId": chatID, "mark": mark])
            let (data, response) = try await client.perform(request)
            guard (200..<300).contains(response.statusCode) else {
                let error = APIError.classify(status: response.statusCode, body: data)
                if let refusal = error.refusal { await client.noteRefusal(refusal) }
                throw error
            }
            // A success that is a JSON envelope rather than a document is read as what it says.
            let type = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            if type.contains("json") {
                let body = try? JSONDecoder().decode(TypedCopyBody.self, from: data)
                throw APIError.server(status: 400, message: body?.error ?? "")
            }
            guard !data.isEmpty else {
                throw FilingAnnexureError.unavailable(
                    mark: mark, message: "Annexure \(mark) came back empty.")
            }
            return data
        } catch {
            throw FilingAnnexureError.from(error, mark: mark)
        }
    }

    func typedCopy(chatID: String, mark: String) async throws -> TypedCopy {
        do {
            let request = try await client.makeRequest(
                "GET", "/filing/annexures/typed-copy", query: ["chatId": chatID, "mark": mark])
            let body = try await client.send(request, as: TypedCopyBody.self)
            guard body.success != false else {
                throw APIError.server(status: 400, message: body.error ?? "")
            }
            if body.skipped == true {
                return .skipped(reason: body.reason ?? "Annexure \(mark) is attached as an original.")
            }
            guard let html = body.html, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FilingAnnexureError.unavailable(
                    mark: mark, message: "Annexure \(mark) has no typed copy yet.")
            }
            return .html(html)
        } catch {
            throw FilingAnnexureError.from(error, mark: mark)
        }
    }

    func typedCopies(chatID: String) async throws -> TypedCopies {
        do {
            let request = try await client.makeRequest(
                "GET", "/filing/annexures/typed-copies", query: ["chatId": chatID])
            let body = try await client.send(request, as: TypedCopyBody.self)
            guard body.success != false else {
                throw APIError.server(status: 400, message: body.error ?? "")
            }
            return TypedCopies(html: body.html ?? "", marks: body.marks ?? [])
        } catch {
            throw FilingAnnexureError.from(error, mark: nil)
        }
    }

    func originalPages(chatID: String, mark: String) async throws -> OriginalPages {
        do {
            let request = try await client.makeRequest(
                "GET", "/filing/annexures/original-pages", query: ["chatId": chatID, "mark": mark])
            let body = try await client.send(request, as: PagesBody.self)
            guard body.success != false else {
                throw APIError.server(status: 400, message: body.error ?? "")
            }
            if let earlier = body.duplicateOf, !earlier.isEmpty { return .duplicate(of: earlier) }
            let pages = (body.pages ?? []).compactMap { page in
                page.base64.flatMap { Data(base64Encoded: $0) }
            }
            guard !pages.isEmpty else {
                throw FilingAnnexureError.unavailable(
                    mark: mark, message: "Annexure \(mark) has no pages to attach.")
            }
            return .pages(pages)
        } catch {
            throw FilingAnnexureError.from(error, mark: mark)
        }
    }
}

/// What an original's bytes are, read from the bytes rather than a declared type.
enum AnnexureFileKind: Equatable, Sendable {
    case pdf
    case image
    case unknown

    static func of(_ data: Data) -> AnnexureFileKind {
        let head = [UInt8](data.prefix(1024))
        // A PDF may carry a few bytes of junk before its header; readers tolerate up to 1 KB.
        let marker: [UInt8] = Array("%PDF-".utf8)
        if head.count >= marker.count {
            for start in 0...(head.count - marker.count) where Array(head[start..<start + marker.count]) == marker {
                return .pdf
            }
        }
        if EmbeddedImage.read(data) != nil { return .image }
        // WebP: "RIFF....WEBP". Not packable into Word, but drawable on the phone.
        if head.count >= 12, Array(head[0..<4]) == Array("RIFF".utf8), Array(head[8..<12]) == Array("WEBP".utf8) {
            return .image
        }
        return .unknown
    }
}
