import Foundation

/// The eight banner presets a matter can wear (docs/projects.md → banner presets), each two
/// colours for a diagonal gradient — the web's `ProjectBanner` pairs, unchanged.
///
/// Nothing on a banner relies on the gradient for contrast: anything laid over it sits on its own
/// dark plate, which is also what keeps it legible over an uploaded picture.
enum BannerPreset: String, CaseIterable, Identifiable, Sendable {
    case navy, slate, indigo, teal, forest, wine, gold, sand

    var id: String { rawValue }

    /// The gradient's two ends, `#RRGGBB`, from the top-left corner to the bottom-right.
    var hexColors: (from: String, to: String) {
        switch self {
        case .navy: return ("#252A47", "#464E85")
        case .slate: return ("#343A4F", "#6B7187")
        case .indigo: return ("#464E85", "#8B95CC")
        case .teal: return ("#24555C", "#6F9AC0")
        case .forest: return ("#22463A", "#5C8569")
        case .wine: return ("#4A2034", "#8B4A64")
        case .gold: return ("#6A4C14", "#C29A48")
        case .sand: return ("#7E6E55", "#D2C2A2")
        }
    }

    /// The preset nearest each folder colour, so "the amber folder" is the gold banner rather
    /// than an unrelated second colour for the same matter.
    static let presetForColor: [String: BannerPreset] = [
        "indigo": .indigo, "violet": .indigo, "fuchsia": .wine, "rose": .wine,
        "amber": .gold, "green": .forest, "teal": .teal, "sky": .navy,
    ]

    /// The web's `bannerPresetOf`: the matter's own preset, else the one nearest its folder
    /// colour, else navy. An `image` banner resolves the same way — the gradient is drawn under
    /// the picture, and instead of it when the picture cannot be shown.
    static func preset(for project: Project?) -> BannerPreset {
        if let banner = project?.banner, let preset = BannerPreset(rawValue: banner) { return preset }
        if let color = project?.color, let preset = presetForColor[color] { return preset }
        return .navy
    }

    /// One `#RRGGBB` as three components in 0…1, for a view to build a colour from.
    static func components(_ hex: String) -> (red: Double, green: Double, blue: Double)? {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }
}

/// A picture for a matter's banner, as `POST /project-banner` takes it: a PNG, JPEG or WebP data
/// URL of at most 2 MB.
///
/// The size is checked here, before anything is sent. The view shrinks a photo first (to at most
/// 1,600 pixels wide, as a JPEG) — that needs UIKit, so it is not done in the core.
enum BannerImage {
    static let maxBytes = 2 * 1024 * 1024
    static let acceptedTypes = ["image/png", "image/jpeg", "image/webp"]

    /// The data URL for these bytes, or a worded refusal.
    static func dataURL(data: Data, mime: String) throws -> String {
        var type = mime.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if type == "image/jpg" { type = "image/jpeg" }
        guard acceptedTypes.contains(type) else {
            throw APIError.server(status: 400, message: "The banner has to be a PNG, JPEG or WebP image.")
        }
        guard !data.isEmpty else {
            throw APIError.server(status: 400, message: "That image could not be read.")
        }
        guard data.count <= maxBytes else {
            let megabytes = (Double(data.count) / 1_048_576 * 10).rounded() / 10
            throw APIError.server(
                status: 413,
                message: "That image is \(String(format: "%.1f", megabytes)) MB — a banner can be up to 2 MB.")
        }
        return "data:\(type);base64,\(data.base64EncodedString())"
    }

    /// The widest a banner picture is drawn at before it is sent.
    static let maxWidth = 1600.0

    /// The JPEG qualities the view tries in turn until the picture fits under `maxBytes`.
    static let jpegQualities = [0.85, 0.75, 0.6, 0.45, 0.3]

    /// The size, in pixels, to draw a picture of this size at: no wider than `maxWidth`, never
    /// enlarged, the proportions kept.
    static func targetSize(width: Double, height: Double) -> (width: Double, height: Double)? {
        guard width > 0, height > 0 else { return nil }
        let scale = min(1, maxWidth / width)
        return ((width * scale).rounded(), max(1, (height * scale).rounded()))
    }
}
