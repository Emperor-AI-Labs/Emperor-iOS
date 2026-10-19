import Foundation

/// A sheet of paper the web offers (`PAGE_SIZES` in `src/lib/pageSetup.js`), in millimetres,
/// always **portrait** — orientation is applied when it is read, never stored pre-swapped, so the
/// two numbers can never drift apart.
struct DocumentPageSize: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let widthMM: Double
    let heightMM: Double

    static let a4 = DocumentPageSize(id: "a4", label: "A4", widthMM: 210, heightMM: 297)
    static let letter = DocumentPageSize(id: "letter", label: "Letter", widthMM: 215.9, heightMM: 279.4)
    static let legal = DocumentPageSize(id: "legal", label: "Legal", widthMM: 215.9, heightMM: 355.6)
    static let a3 = DocumentPageSize(id: "a3", label: "A3", widthMM: 297, heightMM: 420)
    static let a5 = DocumentPageSize(id: "a5", label: "A5", widthMM: 148, heightMM: 210)

    /// In the web's order (`PAGE_SIZE_LIST`).
    static let all: [DocumentPageSize] = [.a4, .letter, .legal, .a3, .a5]

    static func withID(_ id: String?) -> DocumentPageSize? { all.first { $0.id == id } }

    /// "210 × 297mm" — the web's menu shows the dimensions so Legal and Letter are not a guess.
    var dimensionsLabel: String {
        "\(DocumentPageSetup.number(widthMM)) × \(DocumentPageSetup.number(heightMM))mm"
    }
}

enum DocumentPageOrientation: String, CaseIterable, Identifiable, Codable, Sendable {
    case portrait, landscape

    var id: String { rawValue }

    var label: String {
        switch self {
        case .portrait: return "Portrait"
        case .landscape: return "Landscape"
        }
    }
}

/// Margins in millimetres.
struct DocumentPageMargins: Equatable, Codable, Sendable {
    var top: Double
    var right: Double
    var bottom: Double
    var left: Double

    /// The web's `DEFAULT_MARGINS`, which it chose to match what its Word exporter already wrote.
    static let `default` = DocumentPageMargins(top: 25, right: 20, bottom: 25, left: 25)
}

/// The page a drafted document is laid out on: size, orientation and margins — the web's
/// `pageSetup` (`src/lib/pageSetup.js`), the one geometry both the Word file and the PDF follow.
///
/// ## Normalised on the way in
///
/// Whatever is stored is put through the web's `normalizePageSetup`: an unknown size is A4, any
/// orientation but `landscape` is portrait, and a margin that is not a finite, non-negative number
/// takes its default — a string `"20"` included, because the web tests `typeof v === 'number'`.
/// The `Decodable` conformance *is* that rule, so a stored value from a later build, or a broken
/// one, cannot produce a sheet the exporters were never meant to draw. `PageSetupGoldenTests`
/// runs it against the web's own answers (`Resources/composer/page-setup.json`, from
/// `scripts/generate-page-setup-fixtures.mjs`).
///
/// ## Where it goes
///
/// - Word: `<w:pgSz>` takes the oriented sheet in twips with `w:orient="landscape"` when it is,
///   and `<w:pgMar>` the margins — what the web's `htmlToDocx.js` has the docx library write.
/// - PDF: the oriented sheet and the margins in points (72 to the inch), for `AnswerPDF`.
///
/// Remembered for the account on this device, as the web keeps it in the browser.
struct DocumentPageSetup: Equatable, Sendable {
    var size: DocumentPageSize
    var orientation: DocumentPageOrientation
    var margins: DocumentPageMargins

    init(
        size: DocumentPageSize = .a4,
        orientation: DocumentPageOrientation = .portrait,
        margins: DocumentPageMargins = .default
    ) {
        self.size = size
        self.orientation = orientation
        self.margins = margins
    }

    /// `DEFAULT_PAGE_SETUP`: A4, portrait, the default margins.
    static let `default` = DocumentPageSetup()

    var isLandscape: Bool { orientation == .landscape }

    // MARK: Millimetres

    /// The sheet with orientation applied — `pageDimensions`.
    var widthMM: Double { isLandscape ? size.heightMM : size.widthMM }
    var heightMM: Double { isLandscape ? size.widthMM : size.heightMM }

    /// The printable box inside the margins — `pageMetrics().mm.contentWidth/Height`.
    var contentWidthMM: Double { max(0, widthMM - margins.left - margins.right) }
    var contentHeightMM: Double { max(0, heightMM - margins.top - margins.bottom) }

    /// "A4 · Portrait" — `pageSizeLabel`.
    var label: String { "\(size.label) · \(orientation.label)" }

    // MARK: Points (PDF)

    /// 72 points to the inch, 25.4 millimetres to the inch.
    static let pointsPerMM = 72 / 25.4

    static func points(_ mm: Double) -> Double { mm * pointsPerMM }

    var widthPoints: Double { Self.points(widthMM) }
    var heightPoints: Double { Self.points(heightMM) }

    /// The margins in points, for a print renderer's insets.
    var marginPoints: (top: Double, left: Double, bottom: Double, right: Double) {
        (Self.points(margins.top), Self.points(margins.left),
         Self.points(margins.bottom), Self.points(margins.right))
    }

    // MARK: Twips (Word)

    /// The web's `mmTwip`: `Math.round((mm / 25.4) * 1440)`. Every value is non-negative, where
    /// JavaScript's rounding and Swift's agree.
    static func twips(_ mm: Double) -> Int { Int(((mm / 25.4) * 1440).rounded()) }

    /// The oriented sheet in twips. The web hands the docx library the *portrait* twips and the
    /// orientation, and the library swaps them for landscape; rounding each portrait side first
    /// and then swapping is what lands in the file, so that is the order here too.
    var sheetTwips: (width: Int, height: Int) {
        let w = Self.twips(size.widthMM), h = Self.twips(size.heightMM)
        return isLandscape ? (h, w) : (w, h)
    }

    var marginTwips: (top: Int, right: Int, bottom: Int, left: Int) {
        (Self.twips(margins.top), Self.twips(margins.right),
         Self.twips(margins.bottom), Self.twips(margins.left))
    }

    /// The width a table or a picture has to fit, in twips.
    var contentWidthTwips: Int {
        max(0, sheetTwips.width - marginTwips.left - marginTwips.right)
    }

    /// The section properties for `word/document.xml`, as the docx library spells them: the
    /// sheet with `w:orient` only when landscape (portrait is Word's default), the four margins,
    /// and its default header and footer distances.
    var docxSectionProperties: String {
        let sheet = sheetTwips, m = marginTwips
        let orient = isLandscape ? " w:orient=\"landscape\"" : ""
        return "<w:sectPr><w:pgSz w:w=\"\(sheet.width)\" w:h=\"\(sheet.height)\"\(orient)/>"
            + "<w:pgMar w:top=\"\(m.top)\" w:right=\"\(m.right)\" w:bottom=\"\(m.bottom)\" "
            + "w:left=\"\(m.left)\" w:header=\"708\" w:footer=\"708\" w:gutter=\"0\"/></w:sectPr>"
    }

    // MARK: Editing

    /// Margins are typed in a sheet; this is the range it accepts. Wider than any real filing
    /// needs, and narrow enough that a slip cannot leave no page at all — the web normalises a
    /// negative to the default, and so does `with(margins:)`.
    static let marginRange: ClosedRange<Double> = 0...80

    /// These margins, each outside `marginRange` or not finite replaced by its default — the same
    /// fallback the web's normaliser applies to a stored negative.
    func with(margins proposed: DocumentPageMargins) -> DocumentPageSetup {
        func clean(_ value: Double, _ fallback: Double) -> Double {
            value.isFinite && Self.marginRange.contains(value) ? value : fallback
        }
        var copy = self
        copy.margins = DocumentPageMargins(
            top: clean(proposed.top, DocumentPageMargins.default.top),
            right: clean(proposed.right, DocumentPageMargins.default.right),
            bottom: clean(proposed.bottom, DocumentPageMargins.default.bottom),
            left: clean(proposed.left, DocumentPageMargins.default.left))
        return copy
    }

    // MARK: Storage

    static func key(forUser userID: Int?) -> String {
        "document.page-setup.v1.\(userID.map(String.init) ?? "anonymous")"
    }

    static func stored(in store: any PreferenceStore, userID: Int?) -> DocumentPageSetup {
        guard let raw = store.string(for: key(forUser: userID)),
              let setup = try? JSONDecoder().decode(DocumentPageSetup.self, from: Data(raw.utf8))
        else { return .default }
        return setup
    }

    func save(to store: any PreferenceStore, userID: Int?) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        store.setString(String(decoding: data, as: UTF8.self), for: Self.key(forUser: userID))
    }

    /// `210`, not `210.0`; `215.9` as it is. One decimal place is all any size here carries.
    static func number(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }
}

// MARK: - Codable, as the web's normaliser

extension DocumentPageSetup: Codable {
    private enum Keys: String, CodingKey { case size, orientation, margins }
    private enum MarginKeys: String, CodingKey { case top, right, bottom, left }

    init(from decoder: Decoder) throws {
        // `normalizePageSetup(null)` is the default: a top-level null or non-object decodes too.
        guard let container = try? decoder.container(keyedBy: Keys.self) else {
            self = .default
            return
        }
        let sizeID = try? container.decodeIfPresent(String.self, forKey: .size)
        let orientationID = try? container.decodeIfPresent(String.self, forKey: .orientation)
        let fallback = DocumentPageMargins.default
        var margins = fallback
        if let m = try? container.nestedContainer(keyedBy: MarginKeys.self, forKey: .margins) {
            // The web's `num`: a finite number at or above zero, or the default. A string, a
            // boolean, a null or a negative all take the default.
            func num(_ key: MarginKeys, _ otherwise: Double) -> Double {
                guard let value = try? m.decodeIfPresent(Double.self, forKey: key),
                      value.isFinite, value >= 0
                else { return otherwise }
                return value
            }
            margins = DocumentPageMargins(
                top: num(.top, fallback.top), right: num(.right, fallback.right),
                bottom: num(.bottom, fallback.bottom), left: num(.left, fallback.left))
        }
        self.init(
            size: DocumentPageSize.withID(sizeID ?? nil) ?? .a4,
            orientation: (orientationID ?? nil) == "landscape" ? .landscape : .portrait,
            margins: margins)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(size.id, forKey: .size)
        try container.encode(orientation.rawValue, forKey: .orientation)
        try container.encode(margins, forKey: .margins)
    }
}
