import XCTest
@testable import EmperorCore

/// The app's mobile-number rules, checked against the platform's own `src/lib/phone.js`.
///
/// `Resources/phone.json` is produced by running that file under Node
/// (`scripts/generate-phone-fixtures.mjs`). The server accepts and stores a number with those
/// functions, so a case where the two disagree is a sign-up the server would refuse, or a number
/// it would store differently from what the person typed.
final class IndianMobileTests: XCTestCase {

    private struct Case: Decodable {
        let input: String
        let normalized: String
        let valid: Bool
        let api: String
        let local: String
    }

    private func cases() throws -> [Case] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "phone", withExtension: "json"))
        return try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
    }

    func testEveryShapeAgreesWithThePlatform() throws {
        let all = try cases()
        XCTAssertGreaterThan(all.count, 30)
        for c in all {
            XCTAssertEqual(IndianMobile.normalize(c.input), c.normalized, "normalise \(c.input)")
            XCTAssertEqual(IndianMobile.isValid(c.input), c.valid, "valid \(c.input)")
            XCTAssertEqual(IndianMobile.international(c.input), c.api, "api \(c.input)")
            XCTAssertEqual(IndianMobile.local(c.input), c.local, "local \(c.input)")
        }
    }

    /// The bug fixed on both sides: a mobile that itself begins 91 keeps both digits.
    func testANumberBeginning91IsNotMistakenForTheCountryCode() {
        XCTAssertEqual(IndianMobile.normalize("91234 56789"), "9123456789")
        XCTAssertTrue(IndianMobile.isValid("91234 56789"))
        XCTAssertEqual(IndianMobile.normalize("+91 91234 56789"), "9123456789")
    }

    func testNothingTypedIsNothingSent() {
        XCTAssertEqual(IndianMobile.international(""), "")
        XCTAssertEqual(IndianMobile.international(nil), "")
        XCTAssertFalse(IndianMobile.isValid(""))
    }
}
