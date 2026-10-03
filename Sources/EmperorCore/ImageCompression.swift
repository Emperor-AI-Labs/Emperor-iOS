import Foundation

/// Bringing an image down to a target size — the platform's `/tools/compress-image`.
///
/// A port of `compressToTarget` (`src/pages/tools/CompressImage.jsx:35-59`). `ImageCompressionTests`
/// holds it to the web call for call: the fixture records every encode the web's search makes
/// against a size model, and the Swift search must make the same encodes in the same order.
///
/// ## The search
///
/// Quality is spent before resolution. At each size the lowest useful quality is tried first; if
/// even that overshoots, the image is shrunk by 15% and tried again. Once something fits, nine
/// rounds of bisection find the highest quality that still fits at that size. Fourteen sizes are
/// tried before giving up — and giving up still returns the smallest file made, marked as missing
/// the target, because refusing to produce anything is less useful than an honest result.
///
/// The encoder is a parameter so this runs here without UIKit: the app passes one that draws
/// onto a white canvas (JPEG has no alpha, so transparency is flattened as the web flattens it)
/// and encodes a JPEG.
enum ImageCompression {

    /// The quick picks under the target field (`CompressImage.jsx:8`).
    static let presetsKB = [50, 100, 200, 500]
    static let defaultTargetKB = 100
    /// Larger sources are refused outright (`CompressImage.jsx:10-11`).
    static let maxSourceBytes = 1024 * 1024 * 1024

    static let sizeAttempts = 14
    static let qualityRounds = 9
    static let lowestQuality = 0.05
    static let highestQuality = 0.96
    static let shrinkFactor = 0.85

    struct Result: Equatable, Sendable {
        let data: Data
        let width: Int
        let height: Int
        let quality: Double
        /// False when even the smallest attempt overshot — the result is the smallest made.
        let hitTarget: Bool
    }

    /// What the screen shows after a run: the source's size beside the result's.
    struct Report: Equatable, Sendable {
        let originalWidth: Int
        let originalHeight: Int
        let result: Result
    }

    enum Failure: LocalizedError, Equatable {
        case unreadable
        case encodingFailed
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .unreadable: return "That image could not be opened. It may be damaged or in a format this phone cannot read."
            case .encodingFailed: return "The image could not be re-encoded."
            case .tooLarge: return "This image is larger than the 1 GB per-file limit and cannot be compressed."
            }
        }
    }

    /// - Parameter encode: draws the source at the given pixel size and returns it as a JPEG at
    ///   the given quality, or `nil` if it could not.
    static func search(
        width: Int, height: Int, targetBytes: Int,
        encode: (_ width: Int, _ height: Int, _ quality: Double) throws -> Data?
    ) throws -> Result {
        func attempt(_ w: Int, _ h: Int, _ q: Double) throws -> Data {
            guard let data = try encode(w, h, q) else { throw Failure.encodingFailed }
            return data
        }

        var scale = 1.0
        var smallest: Result?
        for _ in 0..<sizeAttempts {
            // `Math.round` rounds half up; for these positive values `.toNearestOrAwayFromZero`
            // is the same rule.
            let w = max(1, Int((Double(width) * scale).rounded(.toNearestOrAwayFromZero)))
            let h = max(1, Int((Double(height) * scale).rounded(.toNearestOrAwayFromZero)))

            let floor = try attempt(w, h, lowestQuality)
            if smallest == nil || floor.count < smallest!.data.count {
                smallest = Result(data: floor, width: w, height: h, quality: lowestQuality, hitTarget: false)
            }
            if floor.count > targetBytes {
                scale *= shrinkFactor
                continue
            }

            var low = lowestQuality
            var high = highestQuality
            var best = floor
            var bestQuality = lowestQuality
            for _ in 0..<qualityRounds {
                let quality = (low + high) / 2
                let candidate = try attempt(w, h, quality)
                if candidate.count <= targetBytes {
                    best = candidate
                    bestQuality = quality
                    low = quality
                } else {
                    high = quality
                }
            }
            return Result(data: best, width: w, height: h, quality: bestQuality, hitTarget: true)
        }
        guard let smallest else { throw Failure.encodingFailed }
        return smallest
    }

    /// `name.replace(/\.[^.]+$/, '') + '_compressed.jpg'` (`CompressImage.jsx:104`).
    static func outputName(for sourceName: String) -> String {
        ToolFileName.removingExtension(sourceName) + "_compressed.jpg"
    }

    /// `Math.max(0, Math.round((1 - compressed / original) * 100))` (`CompressImage.jsx:171`).
    static func percentSmaller(original: Int, compressed: Int) -> Int {
        guard original > 0 else { return 0 }
        let percent = (1 - Double(compressed) / Double(original)) * 100
        // Half up, as `Math.round` does — including for negatives, which the clamp then floors.
        return max(0, Int((percent + 0.5).rounded(.down)))
    }

    /// The target the user typed, in bytes, or `nil` if it is not a positive whole number of KB.
    static func targetBytes(kilobytes text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let kilobytes = Int(trimmed), kilobytes > 0, kilobytes <= maxSourceBytes / 1024 else {
            return nil
        }
        return kilobytes * 1024
    }
}
