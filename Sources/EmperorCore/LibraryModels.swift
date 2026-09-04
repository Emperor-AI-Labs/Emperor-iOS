import Foundation

/// One tab of the reference library — bare acts, case law, rules.
struct LibraryCategory: Codable, Equatable, Identifiable, Sendable {
    let key: String
    var label: String?
    /// How many documents this tab holds. **Zero is meaningful** — see `LibraryService`.
    var count: Int?
    /// `"state"`, `"court"`, … or absent when the tab has no sub-filter.
    var subFilterType: String?

    var id: String { key }
    var displayLabel: String { label ?? key.replacingOccurrences(of: "-", with: " ").capitalized }
    var hasSubFilters: Bool { (subFilterType?.isEmpty == false) }
}

/// A document in the reference library.
struct LibraryDocument: Codable, Equatable, Identifiable, Sendable {
    let id: Int
    var title: String?
    var fileSize: Int?
    /// `pdf`, `txt`, … Used to decide how to present it.
    var ext: String?
    /// `COALESCE(downloaded_at, created_at)`, so the encoding follows whichever wrote it.
    var added: String?

    var displayTitle: String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Untitled document" : trimmed
    }

    var addedDate: Date? { WireDate.parseAny(added) }
    var isPDF: Bool { (ext ?? "").lowercased() == "pdf" }

    enum CodingKeys: String, CodingKey {
        case id, title, ext, added
        case fileSize = "file_size"
    }
}

/// How a browse is ordered. These are the exact wire values the server accepts
/// (`lib/referenceLibrary.js:181-188`); anything else silently falls back to title order.
enum LibrarySort: String, CaseIterable, Sendable {
    case titleAscending = "title_asc"
    case newest = "date_desc"
    case oldest = "date_asc"
    case largest = "size_desc"

    var label: String {
        switch self {
        case .titleAscending: return "Title"
        case .newest: return "Newest"
        case .oldest: return "Oldest"
        case .largest: return "Largest"
        }
    }
}

// MARK: - Envelopes

struct LibraryCategoriesResponse: Codable, Sendable {
    var success: Bool?
    var categories: [LibraryCategory]?
    var error: String?
}

struct LibrarySubFiltersResponse: Codable, Sendable {
    var success: Bool?
    var subFilters: [String]?
    var error: String?
}

struct LibraryBrowseResponse: Codable, Sendable {
    var success: Bool?
    var items: [LibraryDocument]?
    /// The full result count, not the page size — the route pages server-side.
    var total: Int?
    var error: String?
}
