import Foundation

/// An Indian mobile number as people type it, and as the platform stores it.
///
/// A port of the platform's `src/lib/phone.js`, which the server uses to accept a number at
/// sign-up (`isValidIndianMobile`) and to store it (`phoneForApi`, `+91XXXXXXXXXX`). The app has
/// to agree with it on every shape a person types — spaces, dashes, `+91`, a trunk `0`, digits
/// from a full-width or Devanagari keyboard — so `IndianMobileTests` checks this against cases
/// produced by running that file (`scripts/generate-phone-fixtures.mjs`).
///
/// A number is stored local (ten digits) while typing and sent international. Shorter input is
/// kept, not padded or refused, while it is being typed: the field's job is to hold what the
/// person means; `isValid` is for the moment it is submitted.
enum IndianMobile {

    static let countryCode = "91"

    /// The ten digits kept from what was typed — or fewer, while it is still being typed.
    static func normalize(_ input: String?) -> String {
        guard let input else { return "" }
        // The platform reads at most 64 UTF-16 units, so a pasted paragraph cannot be scanned
        // forever; the same limit here keeps the two in step on absurd input.
        var text = String(decoding: Array(input.utf16.prefix(64)), as: UTF16.self)
        text = String(String.UnicodeScalarView(text.unicodeScalars.map(asciiDigit)))

        var digits = digitsOnly(text)
        guard !digits.isEmpty else { return "" }

        // The country code goes only when it is written as one — after "+", as "00", or ahead of
        // a full ten digits. A mobile can itself begin 91 ("91234 56789"), and must keep both.
        let written = String(input.drop(while: { $0.isWhitespace }))
        if digits.hasPrefix("00" + countryCode) { digits.removeFirst(2) }
        let marked = written.hasPrefix("+") || digitsOnly(written).hasPrefix("00")
        if digits.hasPrefix(countryCode)
            && (marked || digits.count >= countryCode.count + 10) {
            digits.removeFirst(countryCode.count)
        }

        // "09876543210" is how a local number is written in India: the trunk 0 goes.
        if digits.count > 10 && digits.hasPrefix("0") {
            digits = String(digits.drop(while: { $0 == "0" }))
        }
        return String(digits.prefix(10))
    }

    /// A complete Indian mobile number: ten digits beginning 6–9.
    static func isValid(_ input: String?) -> Bool {
        let digits = normalize(input)
        guard digits.count == 10, let first = digits.first else { return false }
        return "6789".contains(first)
    }

    /// What is sent and stored: `+91XXXXXXXXXX`, or empty for no digits at all.
    static func international(_ input: String?) -> String {
        let digits = normalize(input)
        return digits.isEmpty ? "" : "+" + countryCode + digits
    }

    /// The field's display: "98765 43210" — grouped in fives, the way every Indian form writes
    /// it, without the country code, which the field shows beside itself. A partial number
    /// stays ungrouped so the caret does not jump while typing.
    static func local(_ input: String?) -> String {
        let digits = normalize(input)
        guard digits.count >= 6 else { return digits }
        return String(digits.prefix(5)) + " " + String(digits.dropFirst(5))
    }

    // MARK: - Plumbing

    /// JavaScript's `\d` without the `u` flag: ASCII digits only.
    static func digitsOnly(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { (48...57).contains($0.value) }))
    }

    /// Full-width (０–９) and Devanagari (०–९) digits, as ASCII.
    private static func asciiDigit(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        switch scalar.value {
        case 0xFF10...0xFF19: return Unicode.Scalar(scalar.value - 0xFEE0) ?? scalar
        case 0x0966...0x096F: return Unicode.Scalar(scalar.value - 0x0966 + 0x30) ?? scalar
        default: return scalar
        }
    }
}
